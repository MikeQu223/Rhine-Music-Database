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
 * 帧状态（playing / title / artist / position / duration / cover / notifiedKey）收在本 object
 * 作为单一真源；Service 实例只保留必须靠 this 才能拿到的对象与方法。
 *
 * 与 Java 源的差异：
 *  1. 静态 native 方法与 JNI 入口改成注入式 sink。服务可能先于 Dart 起（START_STICKY
 *     复活、通知按钮、耳机键），所以 sink 未装时动作按到达顺序留在 pendingActions，
 *     install 后补投。
 *  2. 版本守卫按 API 分支保留（minSdk 28，26 的分支已不可达但留作对照）。
 *
 * 线程约定：所有入口与回调都在主线程，状态不加锁；交付是同步的（FIFO，重入追加队尾）。
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
     * 音频焦点是否已持有。Java:228 用 focusRequest != null 判定，但 API < 26 没有
     * AudioFocusRequest 对象（本工程 minSdk 28，这条分支已不可达，保留对照 Java 源）；
     * 用这个标志统一两条路径的"已持有"语义，避免重复申请或漏释放。
     */
    private var focusHeld = false

    /** 是否已尝试申请 POST_NOTIFICATIONS（镜像 AndroidMediaSession.cpp:35-39 的 static bool requested）。 */
    private var permissionRequested = false

    private var appContext: Context? = null
    private var commandSink: ((String) -> Unit)? = null

    /**
     * sink 安装前到达、尚未尝试交付的动作，按到达顺序保存（仅主线程访问）。
     * 不设容量上限、不去重、不合并：这些动作之间没有能保持语义的合并方式。
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
                    // sink 被 uninstall/shutdown 清空后到下一次 install 之间的空窗：
                    // 剩下的动作留在队列里，等新 sink 装好再按原序补投。
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
     * 启动前台服务（幂等：已实例化时早退）。
     *
     * 返回值就是这次请求的结局：true = 系统已受理，false = 被拒绝（后台启动限制等），
     * 此时降级为无通知、无保活，播放照常。true 不代表通知已显示（还要 POST_NOTIFICATIONS）。
     */
    fun ensureStarted(context: Context): Boolean {
        if (instance != null) {
            return true
        }
        requestNotificationPermissionOnce(context)
        return startForegroundServiceCompat(context)
    }

    /**
     * 最近一次 startForegroundServiceCompat 的结局：true = 请求被系统拒绝（服务没起来），
     * false = 请求已发出（或从未请求过）。纯诊断字段，不参与控制流，下一次请求时复位。
     */
    internal var lastStartRejected = false
        private set

    /**
     * API 26 起必须 startForegroundService，否则随后的 startForeground 会抛异常。
     *
     * Android 12 起从非前台上下文调用会抛 ForegroundServiceStartNotAllowedException，
     * 它会一路冒到调用方把保活失败放大成启动崩溃，所以就地拦住：只按父类
     * IllegalStateException 捕获（子类在旧设备上不存在），记 W 级日志并返回 false，
     * 不重试。只允许在 Activity 处于 start/resume 时调用。
     */
    private fun startForegroundServiceCompat(context: Context): Boolean {
        val intent = Intent(context, MediaPlaybackService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            lastStartRejected = false
            true
        } catch (rejected: IllegalStateException) {
            // 不重抛、不重试：只降级为无通知。异常对象进日志，便于区分"被系统拒绝"与"没调用"。
            lastStartRejected = true
            Log.w(TAG, "foreground service start rejected by system: degrading to no notification", rejected)
            false
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
            // 不要 recycle 已交给 MediaMetadata / 通知的位图：SystemUI 仍会读它，
            // recycle 之后就是 use-after-free。丢掉引用交给 GC。
            coverBitmap = decoded
        }
        if (playing) {
            acquireFocus()
        }
        instance?.publish()
    }

    /**
     * 播放被清空（切页/停止）。服务与通知保持前台待机，只释放音频焦点。
     *
     * 同时清掉元数据与封面：只把 playing 置 false 会让通知继续挂着上一首的标题与可点按钮。
     * 清空后 isIdle() 为真，Service 据此上报 STATE_STOPPED。
     */
    fun stop() {
        playing = false
        positionMs = 0L
        clearMetadata()
        releaseFocus()
        instance?.publish()
    }

    /**
     * 会话当前是否为空（没有在播内容）。通知与 PlaybackState 据此撤销全部动作，
     * 而不是留着一个点了没反应的按钮。
     */
    internal fun isIdle(): Boolean = title.isEmpty()

    /**
     * 反安装动作出口（MediaSessionChannel.uninstall 调用）。
     *
     * 只清 sink 与在途队列：appContext 是 application 级的，不随 Engine/Activity 走；
     * 服务实例、会话与通知也不在这里动（它们归 shutdown / Service.onDestroy）。
     * 清队列是有意的：队列里的动作属于已经断开的那个 engine，重投只会打到无人的 DART 侧。
     */
    fun uninstall() {
        commandSink = null
        pendingActions.clear()
    }

    /**
     * 宿主收尾（BasicAudioChannel.uninstall：Activity onDestroy / 最后一个 engine detach）。
     *
     * 与 stop() 的差别是"没有下一个客户端了"：stop 只回到待机（服务保活、通知留着待命），
     * shutdown 把元数据、封面、焦点、通知、服务全部收掉。服务本身只保留 application 级资源。
     */
    fun shutdown() {
        playing = false
        positionMs = 0L
        durationMs = 0L
        clearMetadata()
        // 通知已撤，去重键必须一起复位：否则下次真实 update 可能算出同一个 key 而跳过重发，
        // 表现是"播了但通知再也不出现"。
        notifiedKey = ""
        releaseFocus()
        // 先让会话如实退到待机：isIdle() 已经成立，publish() 会写 STATE_STOPPED 且 actions=0，
        // 锁屏/系统媒体面板里的播放键、切歌键、进度条在这一刻就失效。少了这一次 publish，
        // 从"释放唯一播放器"到 Service.onDestroy 之间，面板仍在展示上一帧的 STATE_PLAYING 与
        // SKIP/SEEK 动作——正是本 lane 明令禁止的"没有播放器却显示可操作"。
        try {
            instance?.publish()
        } catch (e: Exception) {
            // publish 会走 buildNotification/notify，OEM 偶发 SecurityException 之类：
            // 这一次 publish 只是"顺手把面板退成待机"，失败绝不能让下面真正撤通知、
            // 停服务的两行被跳过——否则恰好在收尾时留下可点的旧控件。
            Log.w(TAG, "shutdown publish failed: continuing teardown", e)
        }
        // 没有下一个客户端了：sink 与在途动作一起丢弃（否则残留在 shutdown 后会一直重试）。
        commandSink = null
        pendingActions.clear()
        instance?.stopForHostShutdown()
    }

    /** 清元数据与封面（幂等）。位图只丢引用不 recycle——见 CRASH-146。 */
    private fun clearMetadata() {
        title = ""
        artist = ""
        album = ""
        coverPath = ""
        // 这份位图已经被 publish() 里 setLargeIcon / putBitmap 交出去过，
        // 通知与 QS/锁屏可能在任意线程继续读它，recycle 会变成原生 use-after-free。
        coverBitmap = null
    }

    /**
     * 版本分支⑤（API 33，本工程 minSdk 28 下的活路径）：POST_NOTIFICATIONS 是运行时权限；被拒不阻塞——
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

    /** 版本分支③（<26 分支；minSdk 28 下不可达）：AudioFocusRequest 不可用，回落到流类型版申请。 */
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

    /** 版本分支③（<26 分支；minSdk 28 下不可达）：与申请路径成对释放，保证不重复申请也不漏释放。 */
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
