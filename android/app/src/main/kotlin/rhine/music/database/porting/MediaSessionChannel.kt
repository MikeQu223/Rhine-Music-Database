package rhine.music.database.porting

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart 与 Android 的媒体会话桥（T25-S02）。
 *
 * 真值源：Qt/src/AndroidMediaSession.cpp:50-68（setCommandCallback / ensureStarted / update /
 * stop 四个入口）与 MediaSessionHost.kt（静态状态、前台服务、通知、音频焦点的唯一实现）。
 * 本文件只做通道接线与参数校验，不复制播放状态，也不实现播放状态机；Dart 侧门面见
 * lib/platform/media_session.dart。
 *
 * 通道（名字是跨语言契约，Dart 侧同名常量逐字对应）：
 *  - MethodChannel "rhine.music.database/media_session"
 *      ensureStarted()          -> Boolean（true = 平台受理启动请求；false = 被前台服务
 *                                  策略拒绝。两者都不代表通知可见）
 *      update(map)              -> null
 *      stop()                   -> null
 *      cacheDir()               -> String?（平台缓存目录绝对路径；拿不到回 null）
 *      pluginDir()              -> String?（插件根目录绝对路径；见 [pluginDir]）
 *      未知方法                 -> notImplemented
 *  - EventChannel "rhine.music.database/media_session/events"
 *      动作串："pause" / "resume" / "next" / "prev" / "rhine.media.SEEK:<ms>"
 *
 * 两个刻意的边界：
 *  1. 不缓存 Activity：install 只接收 () -> Activity?，每次 ensureStarted 现取。
 *     主线程通道回调不会把 Activity 提升成对象的长期字段；Activity 为空时返回
 *     "no_activity"，绝不退回 application context 去拉起前台服务（后台启动会被系统拒绝）。
 *  2. 动作是单向的：EventChannel 只把 MediaSessionHost 的 enqueue 结果交给 Dart；
 *     收到 action 后不会反向调用 update，避免收到暂停后再上报暂停的双重写。
 *
 * 线程：MethodChannel 与 EventChannel 的回调都在平台主线程；MediaSessionHost 的四个入口
 * 也约定只在主线程调用，所以这里不加锁，也不引入协程。
 *
 * 生命周期：install 每个 engine 调用一次（MainActivity.configureFlutterEngine）；重复调用先摘
 * 旧 handler 再装新的。uninstall（MainActivity.onDestroy，MEDIA-CONTROLS-146 新增）摘掉两个
 * handler 与 EventSink，把 activityProvider 闭包（→ MainActivity）从进程级 object 上断开。
 * onCancel 只清 sink，不停止服务——服务与通知的存亡只由 MediaSessionHost 决定。
 */
object MediaSessionChannel {

    /** Dart 侧 mediaSessionMethodChannelName 必须与此逐字相同。 */
    const val METHOD_CHANNEL = "rhine.music.database/media_session"

    /** Dart 侧 mediaSessionEventChannelName 必须与此逐字相同。 */
    const val EVENT_CHANNEL = "rhine.music.database/media_session/events"

    private const val METHOD_ENSURE_STARTED = "ensureStarted"
    private const val METHOD_UPDATE = "update"
    private const val METHOD_STOP = "stop"

    /**
     * 平台私有缓存目录。通知封面只能是本地文件（MediaSessionHost 用
     * BitmapFactory.decodeFile 读），Dart 侧要把远端封面落盘就必须先问到这个目录。
     */
    private const val METHOD_CACHE_DIR = "cacheDir"

    /**
     * 插件根目录（PLUGIN-1）：`/sdcard/Android/data/<pkg>/file/plugin`。
     *
     * 与 Qt 侧的 `<AppLocalDataLocation>/plugins` 不同——那个是 /data/user/0 下的私有目录，
     * 用户看不到也拷不进去。插件要能被用户直接放进去、也能被文件管理器看到，所以走
     * app-specific 外部目录：`getExternalFilesDir(null)` 的父目录（即 `<pkg>/`）再拼
     * `file/plugin`。父目录拿不到（个别设备没有外部卷）才退回 `filesDir/plugins`，
     * 保证"装不上"永远不会变成"崩溃"。
     *
     * 目录由本方法按需创建；创建失败同样回 null，让 Dart 侧如实显示"无插件目录"。
     */
    private const val METHOD_PLUGIN_DIR = "pluginDir"

    /** update 的可空元数据键；Qt 的四个 QString 入参在这里允许 null。 */
    private val OPTIONAL_STRING_KEYS = listOf("title", "artist", "album", "coverPath")

    /** 最近一次 install 建出来的两个通道；uninstall 用同一对对象摘 handler。 */
    private var installedMethod: MethodChannel? = null
    private var installedEvents: EventChannel? = null

    /**
     * 装了这套通道的宿主 Activity（弱持有）。旧 Activity 的 onDestroy 晚到、而新宿主已经
     * install 时，旧 onDestroy 不能把新宿主的通道拆掉——那会让通知动作全部静默。
     */
    private var host = java.lang.ref.WeakReference<Any>(null)

    /**
     * 当前订阅的 sink。提到 object 层，uninstall 才能先断 sink：之后迟到/在途的媒体动作
     * 不再往已经 detach 的 engine 里推（EventSink 失效后 success() 会抛）。
     */
    private var activeSink: EventChannel.EventSink? = null

    /**
     * 应用级 context，只用于 cacheDir 这类与宿主 Activity 无关的查询。
     *
     * 与 activityProvider 严格分开：这里拿到的绝不能用来拉起前台服务（后台启动会被系统
     * 拒绝），也绝不能是 Activity 本身——那等于把旧宿主钉在进程级的通道对象上。
     */
    private var appContext: Context? = null

    /**
     * 注册两个通道。
     *
     * @param messenger Flutter engine 的 binary messenger（configureFlutterEngine 提供）。
     * @param activityProvider 每次 ensureStarted 时调用；返回 null 表示当前没有可用的前台
     *   Activity，方法以 "no_activity" 失败。
     * @param context 只取 applicationContext 给 MediaSessionHost.install 保存，不用于启动服务。
     */
    fun install(
        messenger: BinaryMessenger,
        activityProvider: () -> Activity?,
        context: Context,
        host: Any? = null,
    ) {
        // 重复 install（新 engine）：先摘上一套 handler 与 sink，再装新的。
        detachChannels()
        if (host != null) {
            this.host = java.lang.ref.WeakReference(host)
        }

        val appContext = context.applicationContext
        this.appContext = appContext

        val method = MethodChannel(messenger, METHOD_CHANNEL)
        val events = EventChannel(messenger, EVENT_CHANNEL)
        installedMethod = method
        installedEvents = events

        method.setMethodCallHandler { call, result ->
            handleMethodCall(call, result, activityProvider)
        }

        events.setStreamHandler(
            object : EventChannel.StreamHandler {
                /**
                 * 保存本次订阅的 sink，并把动作出口装到 MediaSessionHost。
                 *
                 * install 是幂等的：重复调用只替换 sink，不会重投已经尝试过的动作
                 * （MediaSessionHost.install 的契约）。回调里再校验 activeSink 的身份，
                 * 保证 cancel 之后迟到的动作不会打到已失效的 EventSink。
                 */
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    activeSink = sink
                    MediaSessionHost.install(appContext) { action ->
                        val current = activeSink
                        if (current != null && current === sink) {
                            current.success(action)
                        }
                    }
                }

                /** 只清 sink：不重复 install、不取消服务、不改变 MediaSessionHost 的状态。 */
                override fun onCancel(arguments: Any?) {
                    activeSink = null
                }
            },
        )
    }

    /**
     * 反安装（MEDIA-CONTROLS-146 新增）：MainActivity.onDestroy 在 super.onDestroy() 之前调用。
     *
     * 必须断三样，缺一样就是泄漏或"没有接收器的通知"：
     *  1. EventSink：之后 MediaSessionHost 的动作不再推进已死的 engine；
     *  2. MethodChannel handler：闭包捕获 activityProvider（MainActivity 传 { this }）；
     *  3. EventChannel stream handler。
     * 最后清 MediaSessionHost 的动作出口与在途队列；appContext 是 application 级的，保留。
     *
     * 不停止服务、不撤通知：那两件事只由 BasicAudioChannel.uninstall() →
     * MediaSessionHost.shutdown() 决定（唯一播放实例跟着宿主收尾），两个入口不互相踩。
     */
    fun uninstall(host: Any? = null) {
        if (host != null) {
            val current = this.host.get()
            if (current != null && current !== host) {
                // 旧宿主的迟到 onDestroy：新宿主的通道与动作出口必须留着。
                return
            }
        }
        this.host.clear()
        detachChannels()
        MediaSessionHost.uninstall()
    }

    private fun detachChannels() {
        activeSink = null
        val method = installedMethod
        val events = installedEvents
        installedMethod = null
        installedEvents = null
        // setMethodCallHandler(null) / setStreamHandler(null) 是官方反注册方式；已为 null 时空操作。
        method?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        activityProvider: () -> Activity?,
    ) {
        when (call.method) {
            METHOD_ENSURE_STARTED -> ensureStarted(result, activityProvider)
            METHOD_UPDATE -> update(call, result)
            METHOD_STOP -> {
                MediaSessionHost.stop()
                result.success(null)
            }

            METHOD_CACHE_DIR -> {
                // 只回真实目录；拿不到就如实 null，Dart 侧据此放弃封面而不是报错。
                result.success(appContext?.cacheDir?.absolutePath)
            }

            METHOD_PLUGIN_DIR -> result.success(pluginDir())


            else -> result.notImplemented()
        }
    }

    /**
     * 插件根目录：app-specific 外部目录下的 `file/plugin`，退回私有 `files/plugins`。
     *
     * 只做路径解析与 mkdir，不读不写插件内容（安装、校验、启用状态全在 Dart 侧
     * lib/plugin 下）。两次 mkdirs 都失败时回 null——Dart 侧据此显示"插件目录不可用"，
     * 而不是把一个写不进去的路径当成可用路径。
     */
    private fun pluginDir(): String? {
        val application = appContext ?: return null
        val externalParent = application.getExternalFilesDir(null)?.parentFile
        if (externalParent != null) {
            val dir = java.io.File(externalParent, "file/plugin")
            if (dir.isDirectory || dir.mkdirs()) {
                return dir.absolutePath
            }
        }
        val fallback = java.io.File(application.filesDir, "plugins")
        if (fallback.isDirectory || fallback.mkdirs()) {
            return fallback.absolutePath
        }
        return null
    }

    /**
     * 启动请求：只在前台 Activity 链路调用。
     *
     * 返回布尔而不是无条件 true：MediaSessionHost.ensureStarted 现在把这次请求的结局
     * 交回来（系统受理 = true，被前台服务策略拒绝 = false），Dart 侧据此如实报告
     * "没有常驻通知"，而不是把一次被拒的启动冒充成功。
     *
     * 两个刻意不承诺：即使回 true，通知是否**可见**仍取决于 POST_NOTIFICATIONS 授权与
     * 系统策略；回 false 也不代表播放失败，只是没有前台保活。本通道不查询可见性。
     */
    private fun ensureStarted(
        result: MethodChannel.Result,
        activityProvider: () -> Activity?,
    ) {
        val activity = activityProvider()
        if (activity == null) {
            result.error(
                "no_activity",
                "ensureStarted requires a foreground Activity",
                null,
            )
            return
        }
        // 如实回给 Dart：false 表示系统拒绝了前台服务启动（无通知、无保活），
        // 不是"通知已经显示"，也不是播放失败。
        result.success(MediaSessionHost.ensureStarted(activity))
    }

    /**
     * 上报一次媒体状态。字段与 MediaSessionHost.update 的七个入参一一对应：
     * playing(Boolean)、positionMs(Number -> Long)、durationMs(Number -> Long)，
     * title/artist/album/coverPath(String?)。数值只做 Number -> Long，不夹取、不改写；
     * Dart 门面已在构造时断言两个时间轴非负。
     *
     * 参数错误回 "invalid_arguments"，且不触碰 MediaSessionHost（一次 update 最多一次）。
     */
    private fun update(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        if (arguments == null) {
            result.error("invalid_arguments", "update expects a map", null)
            return
        }

        val playing = arguments["playing"] as? Boolean
        val positionMs = (arguments["positionMs"] as? Number)?.toLong()
        val durationMs = (arguments["durationMs"] as? Number)?.toLong()
        if (playing == null || positionMs == null || durationMs == null) {
            result.error(
                "invalid_arguments",
                "update requires playing(Boolean), positionMs(Number) and durationMs(Number)",
                null,
            )
            return
        }

        val metadata = HashMap<String, String?>(OPTIONAL_STRING_KEYS.size)
        for (key in OPTIONAL_STRING_KEYS) {
            val value = arguments[key]
            if (value != null && value !is String) {
                result.error("invalid_arguments", "$key must be a string or null", null)
                return
            }
            metadata[key] = value as String?
        }

        MediaSessionHost.update(
            playingNow = playing,
            position = positionMs,
            duration = durationMs,
            mediaTitle = metadata["title"],
            mediaArtist = metadata["artist"],
            mediaAlbum = metadata["album"],
            mediaCoverPath = metadata["coverPath"],
        )
        result.success(null)
    }
}
