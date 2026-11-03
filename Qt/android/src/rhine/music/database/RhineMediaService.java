package rhine.music.database;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.IBinder;

/**
 * 系统媒体控件的后端：MediaSession + MediaStyle 通知 + 音频焦点。
 *
 * 只用 framework API（minSdk 28 起全部可用），不引 androidx——Qt 生成的 Gradle 工程里
 * 加第三方依赖要走另一条路，没必要为一个通知引一串传递依赖。
 *
 * 线程约定：C++ 侧（Qt 主线程 = Android 主线程）通过 start/update/stop 三个静态方法驱动，
 * MediaSession 回调、通知按钮与音频焦点回调也都在主线程，所以静态状态不需要加锁。
 * 回到 C++ 用 native mediaAction()，由 C++ 侧队列到 Qt 事件循环。
 *
 * 通知按钮的命令通过 PendingIntent.getService 发回本服务，在 onStartCommand 里
 * 转成与 iOS MPRemoteCommandCenter 相同的动作字符串（resume/pause/next/prev），
 * 经 native mediaAction() 交给 Host::mediaAction，最终走与桌面快捷键完全相同的通路。
 */
public class RhineMediaService extends Service {
    private static final String CHANNEL_ID = "playback";
    private static final int NOTIFICATION_ID = 1;
    private static final String ACTION_PLAY = "rhine.media.PLAY";
    private static final String ACTION_PAUSE = "rhine.media.PAUSE";
    private static final String ACTION_NEXT = "rhine.media.NEXT";
    private static final String ACTION_PREV = "rhine.media.PREV";
    private static final String ACTION_SEEK = "rhine.media.SEEK";

    /** 由 C++ 实现（AndroidMediaSession.cpp），把动作队列回 Qt 事件循环。 */
    private static native void mediaAction(String action);

    private static RhineMediaService instance;
    private static MediaSession session;
    private static AudioManager audioManager;
    private static AudioFocusRequest focusRequest;
    private static BroadcastReceiver noisyReceiver;
    private static boolean playing;
    private static String title = "";
    private static String artist = "";
    private static String album = "";
    private static long positionMs;
    private static long durationMs;
    /** 封面由 C++ 下载到应用私有目录后传路径过来；路径变化才重新解码位图。 */
    private static String coverPath = "";
    private static android.graphics.Bitmap coverBitmap;
    /** 通知内容只在变化时重建；进度走 PlaybackState，锁屏/手环会自己读，不必每秒 notify。 */
    private static String notifiedKey = "";

    /** C++ 侧入口：确保前台服务已启动。重复调用无害。 */
    public static void start(Context context) {
        if (instance != null) {
            return;
        }
        Intent intent = new Intent(context, RhineMediaService.class);
        context.startForegroundService(intent);
    }

    /** C++ 侧入口：上报播放状态与元数据。title 为空或时长为 0 表示播放已清空（转待机）。 */
    public static void update(boolean playingNow, long position, long duration, String mediaTitle,
            String mediaArtist, String mediaAlbum, String mediaCoverPath) {
        playing = playingNow;
        positionMs = position;
        durationMs = duration;
        title = mediaTitle == null ? "" : mediaTitle;
        artist = mediaArtist == null ? "" : mediaArtist;
        album = mediaAlbum == null ? "" : mediaAlbum;
        // 只在路径变化时重新解码；文件由 C++ 侧保证先落盘，可能比元数据晚一拍（缺失则无封面）。
        String nextCover = mediaCoverPath == null ? "" : mediaCoverPath;
        if (!nextCover.equals(coverPath)) {
            coverPath = nextCover;
            android.graphics.Bitmap decoded =
                    coverPath.isEmpty() ? null : android.graphics.BitmapFactory.decodeFile(coverPath);
            if (coverBitmap != null && coverBitmap != decoded) {
                coverBitmap.recycle();
            }
            coverBitmap = decoded;
        }
        if (playing) {
            acquireFocus();
        }
        RhineMediaService service = instance;
        if (service != null) {
            service.publish();
        }
    }

    /**
     * C++ 侧入口：播放被清空（切页/停止）。服务与通知保持前台待机——这是应用保活的根：
     * 前台服务 + mediaPlayback 类型让系统在无播放时也不回收进程，下次打开立即可续播。
     * 只释放音频焦点（暂停/空闲时占着焦点会拦住其它应用出声）。
     */
    public static void stop() {
        playing = false;
        positionMs = 0;
        releaseFocus();
        RhineMediaService service = instance;
        if (service != null) {
            service.publish();
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);

        session = new MediaSession(this, "RHINE MUSIC DATABASE");
        session.setCallback(new MediaSession.Callback() {
            @Override
            public void onPlay() {
                mediaAction("resume");
            }

            @Override
            public void onPause() {
                mediaAction("pause");
            }

            @Override
            public void onSkipToNext() {
                mediaAction("next");
            }

            @Override
            public void onSkipToPrevious() {
                mediaAction("prev");
            }

            @Override
            public void onSeekTo(long pos) {
                // 进度条拖动（锁屏/通知栏/穿戴设备）：毫秒经动作字符串直达播放器。
                mediaAction(ACTION_SEEK + ":" + Math.max(0, pos));
            }
        });
        // 耳机/蓝牙按键的媒体按钮由会话接管。
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
                | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        session.setActive(true);

        noisyReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                // 拔掉耳机/断开蓝牙：外放突然响起很扰人，直接暂停。
                mediaAction("pause");
            }
        };
        registerReceiver(noisyReceiver, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));

        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_ID, "播放",
                NotificationManager.IMPORTANCE_LOW));

        // startForeground 的权限缺失会让 onCreate 直接抛 SecurityException 并杀掉整个
        // 应用（真机已实测）。媒体控件是锦上添花的能力：失败只降级为无通知，播放与会话
        // 控制不受影响。
        try {
            startForeground(NOTIFICATION_ID, buildNotification());
        } catch (Exception e) {
            stopSelf();
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && intent.getAction() != null) {
            switch (intent.getAction()) {
                case ACTION_PLAY:
                    mediaAction("resume");
                    break;
                case ACTION_PAUSE:
                    mediaAction("pause");
                    break;
                case ACTION_NEXT:
                    mediaAction("next");
                    break;
                case ACTION_PREV:
                    mediaAction("prev");
                    break;
                case ACTION_SEEK:
                    mediaAction(ACTION_SEEK + ":" + intent.getLongExtra("position", 0));
                    break;
                default:
                    break;
            }
        }
        // START_STICKY：被系统/厂商管控击杀后自动复活（intent 为 null，仅恢复待机态）。
        // 配合 START_NOT_STICKY 的旧语义变化：复活后的服务没有可播放内容，publish 待机。
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (noisyReceiver != null) {
            unregisterReceiver(noisyReceiver);
            noisyReceiver = null;
        }
        releaseFocus();
        if (session != null) {
            session.release();
            session = null;
        }
        instance = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /** 播放时申请独占焦点；被其它应用抢占时暂停，与系统播放器的行为一致。 */
    private static void acquireFocus() {
        if (focusRequest != null || audioManager == null) {
            return;
        }
        focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setOnAudioFocusChangeListener(RhineMediaService::onFocusChange)
                .build();
        audioManager.requestAudioFocus(focusRequest);
    }

    private static void releaseFocus() {
        if (focusRequest != null && audioManager != null) {
            audioManager.abandonAudioFocusRequest(focusRequest);
            focusRequest = null;
        }
    }

    private static void onFocusChange(int change) {
        if (change == AudioManager.AUDIOFOCUS_LOSS
                || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            mediaAction("pause");
        }
        // AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK 不暂停：音乐应用被语音导航压低音量即可。
    }

    /** 同步 PlaybackState、MediaMetadata 与通知；必须与 update 同线程（主线程）。 */
    private void publish() {
        if (session == null) {
            return;
        }
        android.media.MediaMetadata.Builder metadata = new android.media.MediaMetadata.Builder()
                .putString(android.media.MediaMetadata.METADATA_KEY_TITLE,
                        title.isEmpty() ? "未在播放" : title)
                .putString(android.media.MediaMetadata.METADATA_KEY_ARTIST, artist)
                .putString(android.media.MediaMetadata.METADATA_KEY_ALBUM, album)
                .putLong(android.media.MediaMetadata.METADATA_KEY_DURATION, durationMs);
        if (coverBitmap != null && !coverBitmap.isRecycled()) {
            // MediaStyle 通知与锁屏的大图都从会话元数据里取，这里给位图即可。
            metadata.putBitmap(android.media.MediaMetadata.METADATA_KEY_ALBUM_ART, coverBitmap);
        }
        session.setMetadata(metadata.build());

        long actions = PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
                | PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_SKIP_TO_NEXT
                | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO;
        session.setPlaybackState(new PlaybackState.Builder()
                .setActions(actions)
                .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
                        positionMs, playing ? 1f : 0f)
                .build());

        // 通知内容（标题/歌手/封面/播放态）变化才重建；进度刷新由 PlaybackState 承载。
        String key = (playing ? "1" : "0") + "|" + title + "|" + artist + "|" + album + "|"
                + coverPath;
        if (!key.equals(notifiedKey)) {
            notifiedKey = key;
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE))
                    .notify(NOTIFICATION_ID, buildNotification());
        }
    }

    private Notification buildNotification() {
        // 跳转回应用本体：QtActivity 是 manifest 里的入口，点通知回到面板。
        Intent contentIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent contentPending = PendingIntent.getActivity(this, 0, contentIntent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        // 待机（title 空）时保持前台通知，ongoing 恒为 true：可滑掉的通知会被系统视为
        // 用户不再需要前台服务，随即将进程降级回收——与保活目标相反。
        Notification.Builder builder = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(getApplicationInfo().icon)
                .setContentTitle(title.isEmpty() ? "未在播放" : title)
                .setContentText(title.isEmpty()
                        ? "点按回到面板"
                        : (artist.isEmpty() ? album
                                            : artist + (album.isEmpty() ? "" : " · " + album)))
                .setContentIntent(contentPending)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .addAction(actionNotification(ACTION_PREV, "上一曲", android.R.drawable.ic_media_previous))
                .addAction(playing
                        ? actionNotification(ACTION_PAUSE, "暂停", android.R.drawable.ic_media_pause)
                        : actionNotification(ACTION_PLAY, "播放", android.R.drawable.ic_media_play))
                .addAction(actionNotification(ACTION_NEXT, "下一曲", android.R.drawable.ic_media_next))
                .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()));
        return builder.build();
    }

    private Notification.Action actionNotification(String action, String label, int icon) {
        Intent intent = new Intent(this, RhineMediaService.class).setAction(action);
        PendingIntent pending = PendingIntent.getService(this, action.hashCode(), intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        // Icon 版构造器替代了 API 23 起过时的资源 id 版本。
        return new Notification.Action.Builder(Icon.createWithResource(this, icon), label, pending)
                .build();
    }
}
