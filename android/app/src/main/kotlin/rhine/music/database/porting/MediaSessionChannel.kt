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
 *      ensureStarted()          -> Boolean true（只表示启动请求已发出）
 *      update(map)              -> null
 *      stop()                   -> null
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
 * 生命周期：install 每个 engine 调用一次（MainActivity.configureFlutterEngine）。重复调用
 * 会替换 messenger 上的 handler；本对象不保存旧 engine 的引用，也不在 onCancel 时停止
 * 服务——服务与通知的存亡只由 MediaSessionHost 决定。
 */
object MediaSessionChannel {

    /** Dart 侧 mediaSessionMethodChannelName 必须与此逐字相同。 */
    const val METHOD_CHANNEL = "rhine.music.database/media_session"

    /** Dart 侧 mediaSessionEventChannelName 必须与此逐字相同。 */
    const val EVENT_CHANNEL = "rhine.music.database/media_session/events"

    private const val METHOD_ENSURE_STARTED = "ensureStarted"
    private const val METHOD_UPDATE = "update"
    private const val METHOD_STOP = "stop"

    /** update 的可空元数据键；Qt 的四个 QString 入参在这里允许 null。 */
    private val OPTIONAL_STRING_KEYS = listOf("title", "artist", "album", "coverPath")

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
    ) {
        val appContext = context.applicationContext

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            handleMethodCall(call, result, activityProvider)
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                /**
                 * 保存本次订阅的 sink，并把动作出口装到 MediaSessionHost。
                 *
                 * install 是幂等的：重复调用只替换 sink，不会重投已经尝试过的动作
                 * （MediaSessionHost.install 的契约）。回调里再校验 activeSink 的身份，
                 * 保证 cancel 之后迟到的动作不会打到已失效的 EventSink。
                 */
                private var activeSink: EventChannel.EventSink? = null

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

            else -> result.notImplemented()
        }
    }

    /**
     * 启动请求：只在前台 Activity 链路调用。
     *
     * MediaSessionHost.ensureStarted 的 lastStartRejected 只记录系统是否拒绝启动；即使为
     * true，这次请求也已经发出，故仍回 success(true)。不伪造通知已显示——通知是否可见
     * 由 POST_NOTIFICATIONS 与系统前台服务策略决定，本通道不查询也不承诺。
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
        MediaSessionHost.ensureStarted(activity)
        result.success(true)
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
