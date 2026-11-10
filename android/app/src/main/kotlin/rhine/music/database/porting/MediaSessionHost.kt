package rhine.music.database.porting

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.session.MediaSession
import android.os.Build
import android.util.Log

/**
 * 原生媒体会话后端的共享状态与静态入口（Qt Android → Flutter 的 1:1 移植）。
 *
 * 真值源：Qt/android/src/rhine/music/database/RhineMediaService.java
 *   35-41    常量（CHANNEL_ID / NOTIFICATION_ID / ACTION_PLAY|PAUSE|NEXT|PREV|SEEK）
 *   46-61    静态状态（instance / session / audioManager / focusRequest / noisyReceiver /
 *            playing / title / artist / album / positionMs / durationMs / coverPath /
 *            coverBitmap / notifiedKey）
 *   63-70    start(Context)：instance 非空早退，否则拉起前台服务
 *   72-99    update(...)：落状态 + 封面按路径变化重解码 + 播放时申请焦点 + publish
 *   101-114  stop()：清播放态 + 释放焦点 + publish（服务保活，不结束前台）
 *   226-254  acquireFocus / releaseFocus / onFocusChange
 *
 * 与 Java 源的结构差异（三处，均为 Flutter 侧必要改动）：
 *   1. 静态 native mediaAction(String)（Java:44）与其 JNI 入口
 *      （Qt/src/AndroidMediaSession.cpp:74-90）→ 注入式 sink：install(context, dispatch)
 *      保存 app context 与回调，enqueue(action) 把动作串交给 sink。
 *      与 Qt 的差别只在"装 sink 之前"这段窗口：Qt 在 Host 构造时就 platformMediaCommands(...)
 *      装好回调（Host.cpp:68-72），cpp:86 的 "media action dropped" 分支实际不可达；Flutter 侧
 *      服务可能先于 Dart 装 sink 起来（START_STICKY 复活、通知按钮、耳机键与焦点回调都可能在
 *      引擎 attach 之前到达），照抄那行 return 会丢第一条媒体动作。因此这里改成进程内 handoff：
 *      sink 未安装时把动作按到达顺序留在 pendingActions，install 后原序补投；每条只尝试交付
 *      一次（不清队列、不设容量上限、不去重、不合并）。本文件不声明任何 native/external
 *      方法，也不调用 System.loadLibrary。
 *   2. minSdk 24 守卫：Qt 侧 minSdk 28；Flutter 侧 compileSdk=targetSdk=36 而 minSdk=24，
 *      所以 startForegroundService（API 26）、AudioFocusRequest（API 26）、
 *      POST_NOTIFICATIONS（API 33）都必须走版本分支，低版本用等价路径（不是静默跳过）。
 *   3. 类名/FQCN 变更：rhine.music.database.RhineMediaService →
 *      rhine.music.database.porting.MediaSessionHost（共享状态与静态入口）
 *      + rhine.music.database.porting.MediaPlaybackService（Service 实例）。
 *      Java 把"静态帧状态"和"Service 实例"塞在同一个类里；这里把帧状态收进本 object
 *      作为单一真源，Service 侧只保留本来就靠 this 才能拿到的对象与方法。
 *
 * ARCH_BLOCKED：Dart ↔ Kotlin 的通道接线属 T21；本文件只暴露 install / ensureStarted /
 * update / stop 四个门面与内部 enqueue，不含任何 MethodChannel，也不改 MainActivity。
 *
 * 线程约定（Java:26-28）：所有入口、MediaSession 回调、通知按钮与音频焦点回调都在主线程，
 * 所以状态不加锁，也不引入协程/后台线程。pendingActions 与 draining 同样只允许主线程访问：
 * 这是调用契约，不是靠同步兑现的保证；跨线程调用仍是违约（与 Java 源同一约定）。
 * 交付是同步的：drainPending 直接在调用者（主线程）栈上调用 sink，不像 Qt 那样再经
 * QueuedConnection 跳一次事件循环；两者顺序一致（FIFO，重入追加到队尾）。
 */
object MediaSessionHost {

    private const val TAG = "RhineMediaSession"

    /** POST_NOTIFICATIONS 的请求码；Qt 侧由框架分配（AndroidMediaSession.cpp:44-46），这里自带一个。 */
    private const val REQUEST_CODE_POST_NOTIFICATIONS = 0x52484831

    // —— Java:35-41 ——
    const val CHANNEL_ID = "playback"
    const val NOTIFICATION_ID = 1
    const val ACTION_PLAY = "rhine.media.PLAY"
    const val ACTION_PAUSE = "rhine.media.PAUSE"
    const val ACTION_NEXT = "rhine.media.NEXT"
    const val ACTION_PREV = "rhine.media.PREV"
    const val ACTION_SEEK = "rhine.media.SEEK"

    // —— Java:46-61 静态状态（全进程唯一一份，Service 只读/写这里） ——
    internal var instance: MediaPlaybackService? = null
    internal var session: MediaSession? = null
    internal var audioManager: AudioManager? = null
    internal var focusRequest: AudioFocusRequest? = null
    internal var noisyReceiver: BroadcastReceiver? = null
    internal var playing = false
    internal var title = ""
    internal var artist = ""
    internal var album = ""
    internal var positionMs = 0L
    internal var durationMs = 0L
    /** 封面由调用方下载到应用私有目录后传路径过来；路径变化才重新解码位图。 */
    internal var coverPath = ""
    internal var coverBitmap: Bitmap? = null
    /** 通知内容只在变化时重建；进度走 PlaybackState，锁屏/手环会自己读，不必每秒 notify。 */
    internal var notifiedKey = ""

    /**
     * 音频焦点是否已持有。Java:228 用 focusRequest != null 判定，但 minSdk 24 下 API < 26 没有
     * AudioFocusRequest 对象；用这个标志统一两条路径的"已持有"语义，避免重复申请或漏释放。
     */
    private var focusHeld = false

    /** 是否已尝试申请 POST_NOTIFICATIONS（镜像 AndroidMediaSession.cpp:35-39 的 static bool requested）。 */
    private var permissionRequested = false

    private var appContext: Context? = null
    private var commandSink: ((String) -> Unit)? = null

    /**
     * sink 安装前到达、尚未尝试交付的动作，严格按到达顺序保存（进程内、仅主线程访问）。
     *
     * 刻意不设容量上限、不去重、不合并：容量阈值必然在某个真实场景下丢弃合法动作，
     * 而 play/pause/seek 之间没有能保持语义的合并方式（连按两次暂停与一次暂停不等价，
     * seek 的目标位置也不同）。窗口只覆盖"服务已起、Dart 尚未 install"这一段，
     * 动作来源与 Qt 相同（用户按键/通知按钮/系统回调），规模有限。
     */
    private val pendingActions = ArrayDeque<String>()

    /** 排空进行中：sink 内重入 enqueue/install 时不再递归排空，交由外层循环按 FIFO 继续。 */
    private var draining = false

    /**
     * 安装/更新动作出口（替代 Java:44 的 static native mediaAction，对应 Qt 侧
     * AndroidMediaSession::setCommandCallback，cpp:50-52）。
     *
     * 幂等：重复调用不产生副作用（不注册广播、不拉起服务、不建会话），只刷新 sink 闭包，
     * 然后立刻补投安装前积压的动作。重复 install（替换 sink）不会重投已尝试过的动作：
     * 只有仍在 pendingActions 里的动作会交给新 sink，因此换 sink 不会产生重复交付。
     */
    fun install(context: Context, dispatch: (String) -> Unit) {
        if (appContext == null) {
            appContext = context.applicationContext
        }
        commandSink = dispatch
        drainPending()
    }

    /**
     * 动作串的唯一入口。Java 侧是 JNI 回调（cpp:74-90），这里改成"入队 + 排空"：
     * 到达顺序即交付顺序，sink 未安装时动作留在队列里而不是丢弃（见文件头差异 1）。
     */
    internal fun enqueue(action: String) {
        pendingActions.addLast(action)
        drainPending()
    }

    /**
     * 把队列里的动作按 FIFO 逐条交给当前 sink。
     *
     * 交付语义是 at-most-once attempt：动作在调用 sink 之前就出队，sink 抛异常也不会重投。
     * 只能保证"每条动作至多被尝试交付一次"，不能声称业务副作用"恰好完成一次"——
     * 回调内部可能已经做了一半才抛，是否真正生效在本层不可判定，所以宁可少投也不重复
     * 施加副作用（重复 pause/seek 对播放器是真实的状态跳变）。
     *
     * 异常：
     *   - Exception：记录（含堆栈）后继续排空，后面的动作不会被一个坏回调拖住；
     *     失败的那条已按"尝试过一次"处理，不回到队列。
     *   - Error（OOM/断言/栈溢出）：记录后原样抛出，不吞；draining 在 finally 复位，
     *     剩余动作仍留在队列里，下一次 enqueue/install 继续补投——不永久卡死。
     * 队列本身在任何异常路径上都不清空、不丢弃（只移走已尝试过的那一条）。
     *
     * sink 在排空过程中被 install 替换时，剩余动作交付给新 sink（每条在交付前才读取
     * commandSink）；已尝试过的动作不会再出现在新 sink 上。
     */
    private fun drainPending() {
        val sinkReady = commandSink != null
        if (draining) {
            return
        }
        if (!sinkReady) {
            if (pendingActions.isNotEmpty()) {
                // Qt 在这里是 "media action dropped"（cpp:86）；Flutter 侧保留并等 install。
                Log.i(TAG, "media action held until dispatcher install: pending=" + pendingActions.size)
            }
            return
        }
        draining = true
        try {
            while (pendingActions.isNotEmpty()) {
                val sink = commandSink
                if (sink == null) {
                    // 现阶段没有反安装入口，仅为可空性兜底：把剩余动作留在队列里。
                    Log.w(TAG, "media action held: command sink cleared: pending=" + pendingActions.size)
                    return
                }
                val action = pendingActions.removeFirst()
                // 对应 cpp:79 的排障锚点：确认媒体动作真的交给了 Kotlin 侧出口。
                Log.i(TAG, "media action via host: " + action)
                try {
                    sink(action)
                } catch (error: Error) {
                    Log.e(TAG, "media action delivery attempt failed with error: " + action, error)
                    throw error
                } catch (exception: Exception) {
                    Log.e(TAG, "media action delivery attempt failed: " + action, exception)
                }
            }
        } finally {
            draining = false
        }
    }

    /**
     * Java:63-70 的 start(Context)，并合入 Qt 侧"先申请通知权限再启动"的流程
     * （AndroidMediaSession.cpp:27-56）。幂等：服务已实例化时早退。
     */
    fun ensureStarted(context: Context) {
        if (instance != null) {
            return
        }
        requestNotificationPermissionOnce(context)
        startForegroundServiceCompat(context)
    }

    /** minSdk 24 守卫①：API 26 起必须 startForegroundService，否则随后 startForeground 会抛异常。 */
    private fun startForegroundServiceCompat(context: Context) {
        val intent = Intent(context, MediaPlaybackService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    /**
     * Java:73-99 的 update：上报播放状态与元数据。
     * title 为空或时长为 0 表示播放已清空（转待机），由调用方判定后改走 stop()
     * （Qt/src/PlatformAndroid.cpp:62-72）。
     *
     * 参数可空以忠实对应 Java 的引用参数；null 一律落成空串（Java:78-82）。
     */
    fun update(
        playingNow: Boolean,
        position: Long,
        duration: Long,
        mediaTitle: String?,
        mediaArtist: String?,
        mediaAlbum: String?,
        mediaCoverPath: String?,
    ) {
        playing = playingNow
        positionMs = position
        durationMs = duration
        title = mediaTitle ?: ""
        artist = mediaArtist ?: ""
        album = mediaAlbum ?: ""
        // 只在路径变化时重新解码；文件由调用方保证先落盘，可能比元数据晚一拍（缺失则无封面）。
        val nextCover = mediaCoverPath ?: ""
        if (nextCover != coverPath) {
            coverPath = nextCover
            val decoded = if (coverPath.isEmpty()) null else BitmapFactory.decodeFile(coverPath)
            val previous = coverBitmap
            if (previous != null && previous !== decoded) {
                previous.recycle()
            }
            coverBitmap = decoded
        }
        if (playing) {
            acquireFocus()
        }
        instance?.publish()
    }

    /**
     * Java:101-114 的 stop：播放被清空（切页/停止）。服务与通知保持前台待机——这是应用保活的根：
     * 前台服务 + mediaPlayback 类型让系统在无播放时也不回收进程，下次打开立即可续播。
     * 只释放音频焦点（暂停/空闲时占着焦点会拦住其它应用出声）。
     */
    fun stop() {
        playing = false
        positionMs = 0L
        releaseFocus()
        instance?.publish()
    }

    /**
     * minSdk 24 守卫⑤：POST_NOTIFICATIONS 是 API 33 起的运行时权限；被拒不阻塞——
     * 通知不显示，但 MediaSession 与耳机按键仍然可用（AndroidMediaSession.cpp:32-33）。
     * 只用框架 API（Activity.requestPermissions），不引 androidx。
     *
     * 与 Qt 的差异：cpp:35-39 用 std::exchange 在第一次调用就吃掉申请机会（Qt 恒有 QtActivity）。
     * Flutter 侧首次调用可能来自非 Activity 上下文，照抄会永久失去申请机会，因此这里只在
     * 真正发出请求时置位——语义仍是"至多弹一次对话框"，且任何情况下都不阻塞启动。
     */
    private fun requestNotificationPermissionOnce(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (permissionRequested) {
            return
        }
        val activity = findActivity(context)
        if (activity == null) {
            Log.w(TAG, "POST_NOTIFICATIONS not requested: no Activity in the context chain")
            return
        }
        permissionRequested = true
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE_POST_NOTIFICATIONS,
        )
    }

    /** 从 Context 链里找 Activity（Flutter 传入的可能是包装过的应用上下文）。 */
    private fun findActivity(context: Context): Activity? {
        var current: Context? = context
        while (current is ContextWrapper) {
            if (current is Activity) {
                return current
            }
            current = current.baseContext
        }
        return null
    }

    /** 焦点回调只构造一次，两条 API 路径共用（Java:236 用方法引用，语义等价）。 */
    private val focusListener = object : AudioManager.OnAudioFocusChangeListener {
        override fun onAudioFocusChange(change: Int) {
            MediaSessionHost.onFocusChange(change)
        }
    }

    /**
     * Java:226-239：播放时申请独占焦点；被其它应用抢占时暂停，与系统播放器行为一致。
     * Java 的守卫是 focusRequest != null；这里用 focusHeld 统一两条路径（见字段注释）。
     */
    internal fun acquireFocus() {
        val manager = audioManager ?: return
        if (focusHeld) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            manager.requestAudioFocus(request)
        } else {
            requestLegacyFocus(manager)
        }
        focusHeld = true
    }

    /** minSdk 24 守卫③（<26 分支）：AudioFocusRequest 不可用，回落到流类型版申请。 */
    @Suppress("DEPRECATION")
    private fun requestLegacyFocus(manager: AudioManager) {
        manager.requestAudioFocus(
            focusListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN,
        )
    }

    /** Java:241-246。 */
    internal fun releaseFocus() {
        if (!focusHeld) {
            return
        }
        val manager = audioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest
            if (request != null && manager != null) {
                manager.abandonAudioFocusRequest(request)
            }
            focusRequest = null
        } else if (manager != null) {
            abandonLegacyFocus(manager)
        }
        focusHeld = false
    }

    /** minSdk 24 守卫③（<26 分支）：与申请路径成对释放，保证不重复申请也不漏释放。 */
    @Suppress("DEPRECATION")
    private fun abandonLegacyFocus(manager: AudioManager) {
        manager.abandonAudioFocus(focusListener)
    }

    /** Java:248-254。 */
    private fun onFocusChange(change: Int) {
        if (change == AudioManager.AUDIOFOCUS_LOSS
            || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
        ) {
            enqueue("pause")
        }
        // AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK 不暂停：音乐应用被语音导航压低音量即可。
    }
}
