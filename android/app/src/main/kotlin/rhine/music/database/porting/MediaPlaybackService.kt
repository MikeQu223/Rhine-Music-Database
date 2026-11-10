package rhine.music.database.porting

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

/**
 * 系统媒体控件的前台服务：MediaSession + MediaStyle 通知 + 音频焦点。
 * （Qt Android → Flutter 的 1:1 移植）
 *
 * 真值源：Qt/android/src/rhine/music/database/RhineMediaService.java
 *   34        类声明
 *   116-176   onCreate：建会话/回调/耳机接收器/通知渠道/startForeground（带降级）
 *   178-204   onStartCommand：通知按钮与 SEEK 的 ACTION_* → 动作串，返回 START_STICKY
 *   206-219   onDestroy：反注册接收器、释放焦点、释放会话、清 instance
 *   221-224   onBind：返回 null
 *   256-290   publish：MediaMetadata + PlaybackState + 通知去重（notifiedKey）
 *   292-326   buildNotification / actionNotification：MediaStyle + 三个 action
 * 常量与帧状态在 MediaSessionHost（Java:35-41、46-61 的静态字段全进程只有一份，禁止两处各存）。
 *
 * 与 Java 源的结构差异（三处）：
 *   1. FQCN：rhine.music.database.RhineMediaService →
 *      rhine.music.database.porting.MediaPlaybackService。AndroidManifest.xml:143-147 的
 *      android:name 必须与本 FQCN 一致（manifest 由父改，本文件只负责类名对齐）。
 *   2. 静态 native mediaAction（Java:44）→ MediaSessionHost.enqueue 的注入 sink
 *      （原因与 sink 契约见 MediaSessionHost 文件头；本文件不声明任何 native 方法）。
 *   3. minSdk 24 守卫：Qt 侧 minSdk 28，这里 minSdk 24 → 通知渠道与带 channel 的 Builder、
 *      startForeground 的类型版都需要版本分支（createNotificationChannelIfNeeded /
 *      newNotificationBuilder / startForegroundCompat），低版本走可用的等价路径。
 *
 * ARCH_BLOCKED：Dart ↔ Kotlin 的通道接线属 T21；本文件不含 MethodChannel，也不改 MainActivity。
 *
 * 线程：入口、通知按钮、会话回调与焦点回调都在主线程（Java:26-28 的约定），不加锁。
 */
class MediaPlaybackService : Service() {

    override fun onCreate() {
        super.onCreate()
        MediaSessionHost.instance = this
        MediaSessionHost.audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        val session = MediaSession(this, "RHINE MUSIC DATABASE")
        // Java:122 在建会话的同一行赋值静态字段（Java:122 `session = new MediaSession(...)`），
        // 这里保持同样的先后：先落 host，再装回调/标志。
        MediaSessionHost.session = session
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                MediaSessionHost.enqueue("resume")
            }

            override fun onPause() {
                MediaSessionHost.enqueue("pause")
            }

            override fun onSkipToNext() {
                MediaSessionHost.enqueue("next")
            }

            override fun onSkipToPrevious() {
                MediaSessionHost.enqueue("prev")
            }

            override fun onSeekTo(pos: Long) {
                // 进度条拖动（锁屏/通知栏/穿戴设备）：毫秒经动作字符串直达播放器。
                // Math.max(0, pos) 是 Java:147 的语义，负数一律夹到 0。
                MediaSessionHost.enqueue(MediaSessionHost.ACTION_SEEK + ":" + Math.max(0L, pos))
            }
        })
        // 耳机/蓝牙按键的媒体按钮由会话接管（Java:151-152）。
        // 这两个 FLAG_ 常量 API 26 起废弃但未移除，Java 源照旧设置。
        @Suppress("DEPRECATION")
        val sessionFlags = MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
            MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        session.setFlags(sessionFlags)
        session.setActive(true)

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                // 拔掉耳机/断开蓝牙：外放突然响起很扰人，直接暂停。
                MediaSessionHost.enqueue("pause")
            }
        }
        // ACTION_AUDIO_BECOMING_NOISY 是系统保留广播：targetSdk 34+ 的两参 registerReceiver
        // 仍然合法（只有非系统广播才强制 RECEIVER_EXPORTED / RECEIVER_NOT_EXPORTED）。
        registerReceiver(receiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        MediaSessionHost.noisyReceiver = receiver

        createNotificationChannelIfNeeded()

        // startForeground 的权限缺失会让 onCreate 直接抛 SecurityException 并杀掉整个应用
        // （真机已实测）。媒体控件是锦上添花的能力：失败只降级为无通知，播放与会话控制不受影响。
        try {
            startForegroundCompat(buildNotification())
        } catch (e: Exception) {
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // intent 为 null 说明是 START_STICKY 复活（Java:178-204 同样允许 action 为空）。
        // 显式判空：Kotlin 不会从 `action != null` 反推 intent 非空，读 extra 需要非空接收者。
        val action = intent?.action
        if (action != null && intent != null) {
            when (action) {
                MediaSessionHost.ACTION_PLAY -> MediaSessionHost.enqueue("resume")
                MediaSessionHost.ACTION_PAUSE -> MediaSessionHost.enqueue("pause")
                MediaSessionHost.ACTION_NEXT -> MediaSessionHost.enqueue("next")
                MediaSessionHost.ACTION_PREV -> MediaSessionHost.enqueue("prev")
                MediaSessionHost.ACTION_SEEK -> MediaSessionHost.enqueue(
                    MediaSessionHost.ACTION_SEEK + ":" + intent.getLongExtra("position", 0L)
                )

                else -> {
                    // 与 Java 的 default 分支一致：未知动作忽略。
                }
            }
        }
        // START_STICKY：被系统/厂商管控击杀后自动复活（intent 为 null，仅恢复待机态）。
        // 复活后的服务没有可播放内容，publish 待机。
        return START_STICKY
    }

    override fun onDestroy() {
        val receiver = MediaSessionHost.noisyReceiver
        if (receiver != null) {
            unregisterReceiver(receiver)
            MediaSessionHost.noisyReceiver = null
        }
        MediaSessionHost.releaseFocus()
        val session = MediaSessionHost.session
        if (session != null) {
            session.release()
            MediaSessionHost.session = null
        }
        MediaSessionHost.instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Java:256-290：同步 PlaybackState、MediaMetadata 与通知；必须与 update 同线程（主线程）。
     * Java 里是 private 成员，这里给 MediaSessionHost 的 update/stop 调用，故为 internal。
     */
    internal fun publish() {
        val session = MediaSessionHost.session ?: return

        val metadata = MediaMetadata.Builder()
            .putString(
                MediaMetadata.METADATA_KEY_TITLE,
                if (MediaSessionHost.title.isEmpty()) "未在播放" else MediaSessionHost.title,
            )
            .putString(MediaMetadata.METADATA_KEY_ARTIST, MediaSessionHost.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, MediaSessionHost.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, MediaSessionHost.durationMs)
        val cover = MediaSessionHost.coverBitmap
        if (cover != null && !cover.isRecycled) {
            // MediaStyle 通知与锁屏的大图都从会话元数据里取，这里给位图即可。
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, cover)
        }
        session.setMetadata(metadata.build())

        val actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (MediaSessionHost.playing) PlaybackState.STATE_PLAYING
                    else PlaybackState.STATE_PAUSED,
                    MediaSessionHost.positionMs,
                    if (MediaSessionHost.playing) 1f else 0f,
                )
                .build()
        )

        // 通知内容（标题/歌手/封面/播放态）变化才重建；进度刷新由 PlaybackState 承载（Java:60-61）。
        val key = (if (MediaSessionHost.playing) "1" else "0") + "|" + MediaSessionHost.title +
            "|" + MediaSessionHost.artist + "|" + MediaSessionHost.album + "|" +
            MediaSessionHost.coverPath
        if (key != MediaSessionHost.notifiedKey) {
            MediaSessionHost.notifiedKey = key
            notificationManager().notify(MediaSessionHost.NOTIFICATION_ID, buildNotification())
        }
    }

    /** Java:292-326。 */
    private fun buildNotification(): Notification {
        // 跳转回应用本体：点通知回到面板。launchIntent 可能为 null（包被改/被禁用），Java 侧直接
        // 交给 PendingIntent 会 NPE；这里跳过 setContentIntent 而不是崩。
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPending = if (launchIntent == null) {
            null
        } else {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        // 待机（title 空）时保持前台通知，ongoing 恒为 true：可滑掉的通知会被系统视为
        // 用户不再需要前台服务，随即将进程降级回收——与保活目标相反。
        val builder = newNotificationBuilder()
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(
                if (MediaSessionHost.title.isEmpty()) "未在播放" else MediaSessionHost.title
            )
            .setContentText(contentText())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                actionNotification(
                    MediaSessionHost.ACTION_PREV,
                    "上一曲",
                    android.R.drawable.ic_media_previous,
                )
            )
            .addAction(
                if (MediaSessionHost.playing) {
                    actionNotification(
                        MediaSessionHost.ACTION_PAUSE,
                        "暂停",
                        android.R.drawable.ic_media_pause,
                    )
                } else {
                    actionNotification(
                        MediaSessionHost.ACTION_PLAY,
                        "播放",
                        android.R.drawable.ic_media_play,
                    )
                }
            )
            .addAction(
                actionNotification(
                    MediaSessionHost.ACTION_NEXT,
                    "下一曲",
                    android.R.drawable.ic_media_next,
                )
            )
        if (contentPending != null) {
            builder.setContentIntent(contentPending)
        }
        // Java 走到这里 session 必非空（onCreate 先建会话；publish 已提前返回）。
        // 判空只是消除可空报警，不改变行为。
        val session = MediaSessionHost.session
        if (session != null) {
            builder.setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken))
        }
        return builder.build()
    }

    /** Java:303-306 的三分支文案。 */
    private fun contentText(): String {
        if (MediaSessionHost.title.isEmpty()) {
            return "点按回到面板"
        }
        if (MediaSessionHost.artist.isEmpty()) {
            return MediaSessionHost.album
        }
        return if (MediaSessionHost.album.isEmpty()) {
            MediaSessionHost.artist
        } else {
            MediaSessionHost.artist + " · " + MediaSessionHost.album
        }
    }

    /** Java:319-326：每个动作经 PendingIntent.getService 回到本服务，由 onStartCommand 转成动作串。 */
    private fun actionNotification(action: String, label: String, icon: Int): Notification.Action {
        val intent = Intent(this, MediaPlaybackService::class.java).setAction(action)
        val pending = PendingIntent.getService(
            this,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Icon 版构造器替代了 API 23 起过时的资源 id 版本。
        return Notification.Action.Builder(Icon.createWithResource(this, icon), label, pending)
            .build()
    }

    /**
     * minSdk 24 守卫②（Builder 侧）：API 26 起通知必须归属渠道，用带 channelId 的构造器；
     * < 26 没有渠道概念，用无 channel 的旧构造器（唯一可用路径）。
     */
    private fun newNotificationBuilder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MediaSessionHost.CHANNEL_ID)
        } else {
            legacyNotificationBuilder()
        }

    @Suppress("DEPRECATION")
    private fun legacyNotificationBuilder(): Notification.Builder = Notification.Builder(this)

    /** minSdk 24 守卫②（渠道侧）：Java:164-166 无条件建渠道，这里只在 API 26+ 建。 */
    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        notificationManager().createNotificationChannel(
            NotificationChannel(
                MediaSessionHost.CHANNEL_ID,
                "播放",
                NotificationManager.IMPORTANCE_LOW,
            )
        )
    }

    /**
     * minSdk 24 守卫④：API 29 起 startForeground 要显式声明前台服务类型
     * （manifest 已声明 foregroundServiceType="mediaPlayback"，类型常量来自 android.content.pm.ServiceInfo）；
     * < 29 只有两参版本。
     */
    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                MediaSessionHost.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(MediaSessionHost.NOTIFICATION_ID, notification)
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
