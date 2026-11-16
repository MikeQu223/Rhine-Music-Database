package rhine.music.database.basic

import android.app.Activity
import android.app.Application
import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rhine.music.database.porting.MediaSessionChannel
import rhine.music.database.porting.MediaSessionHost

/**
 * BASIC-89 lane B：真实音频播放的 Android 端（系统 MediaPlayer，唯一播放权威）。
 *
 * 真值源：
 *  - Qt/src/AudioPlayer.cpp:382-429  control(action, value)：pause / resume / stop / seek / volume；
 *    :419-425 的 seek 只在 isSeekable() 时执行，并把目标夹到 [0, duration]。
 *  - Qt/src/AudioPlayer.cpp:430-443  state()：playing / position / duration / seekable / volume /
 *    ended / error / recoverable / requested / buffering 的键集与类型。
 *  - Qt/src/AudioPlayer.cpp:112-124  一次播放结束只让 ended 序号自增一次（EndOfMedia 且 !sourceEnded）。
 *  - Qt/src/MusicPlayer.cpp:301-443  prepare(track, generation, reload)：播放器侧收尾在成功回调里，
 *    迟到回调由 :442 valid(generation) 拦掉；本文件的 generation/epoch 两级令牌是该语义的 Android 版。
 *
 * 与既有 MediaSession（porting/MediaSessionChannel.kt、MediaSessionHost.kt、MediaPlaybackService.kt）
 * 的分工，禁止双播放权威：
 *  - MediaSession 侧只做「系统媒体控件」：MediaSession、MediaStyle 通知、音频焦点、耳机键，
 *    它的 playing/position/duration 是**被喂进来的展示状态**，本身不产生声音。
 *  - 本文件是唯一的音频权威：只有这里 new MediaPlayer() / start() / pause()。它不碰 MediaSession，
 *    也不申请音频焦点；把 BasicAudioState 摘要喂给 MediaSessionChannel.update 是 Dart 侧调用方
 *    （lane A 的 BasicController）的职责，本文件不反向调用。
 *
 * 通道（名字是跨语言契约，Dart 侧 lib/basic/platform_playback.dart 同名常量逐字对应）：
 *  - MethodChannel "rhine.music.database/basic_audio"
 *      prepare(url, generation)     -> 当前状态 map
 *      play(generation)             -> 当前状态 map
 *      pause(generation)            -> 当前状态 map
 *      seekTo(positionMs, generation) -> 当前状态 map
 *      stop()                       -> 当前状态 map（释放实例、位置归零）
 *      dispose()                    -> 当前状态 map（释放实例并摘掉事件出口）
 *      getState()                   -> 当前状态 map（EventChannel 的兜底读法）
 *      未知方法                      -> notImplemented
 *  - EventChannel "rhine.music.database/basic_audio_state"
 *      每次真实状态变化推一份状态 map：playing / buffering / completed / positionMs / durationMs /
 *      generation / error。onListen 时立刻补推一份当前快照，Dart 不必等到下一次事件。
 *
 * 状态 map 的键（七个，Dart 侧 BasicAudioState.tryParse 逐字读取）：
 *   playing(Boolean) buffering(Boolean) completed(Boolean)
 *   positionMs(Number->Long) durationMs(Number->Long) generation(Int) error(String)
 *
 * 两级令牌：
 *  - generation：Dart 传入、跨语言可见。每次 prepare 由调用方递增；play/pause/seekTo 带同代值时
 *    才执行，旧代命令直接丢弃（回当前快照）。推给 Dart 的每份状态也带 generation，Dart 侧再按
 *    代际丢弃迟到的旧事件——与 Qt valid(generation)（MusicPlayer.cpp:442）同一条思路。
 *  - epoch：仅 Kotlin 内部使用。每次 prepare / 释放都 ++，所有 MediaPlayer 回调在入口比对
 *    自己捕获的 token；不匹配即 return。它拦住的是「旧实例的 onPrepared/onError 晚到」这一类
 *    无法靠 generation 区分的情况（同一代里 reset 后再 prepare 也成立）。
 *
 * 位置与时长只从 MediaPlayer 真实读取：
 *  - positionMs 来自 currentPosition，durationMs 来自 duration；
 *  - 播放中按 POSITION_POLL_MS 轮询 currentPosition 并推送，**不做任何算术外推**：没有加时间差，
 *    没有假 timer，也没有「预计位置」；
 *  - 暂停/完成后停轮询，最后一份位置仍是真实读数。
 *
 * 线程：通道回调、Activity 生命周期回调与 MediaPlayer 回调都在平台主线程（MediaPlayer 在哪个
 * 线程 new 的就在哪个线程回调；本文件只在主线程 new），所以状态不加锁、不引协程。
 *
 * 生命周期（与 Qt 的差异写在报告里）：
 *  - 切后台（onStop/onPause）**不释放**正在播放的实例：声音继续，通知与媒体会话仍可用。
 *  - Activity onDestroy 释放：本应用只有一个 Activity（AndroidManifest.xml:25-47，且带
 *    configChanges 所以旋转不重建），Activity 销毁即引擎 detach，此时没有前台服务可以托住
 *    MediaPlayer（Qt 侧由 RhineMediaService 承担），不释放就会留下裸放的实例。
 *  - dispose()（Dart 主动）与 stop() 也释放。onCancel（Dart 取消事件订阅）只清 sink，不释放。
 *  - 重新 install（engine 重建）复用同一个 PlaybackAuthority，不会把正在播放的实例弄丢；
 *    新客户端接管时 generation 归零——代际是**客户端命名空间**，不是进程级计数器
 *    （见 onClientAttached 里关于旧代快照的说明）。
 */
class BasicAudioChannel private constructor(
    private val messenger: BinaryMessenger,
    private val contextProvider: () -> Context?,
    private val authority: PlaybackAuthority,
) {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var activeSink: EventChannel.EventSink? = null
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null

    /**
     * 事件出口只在 onListen 里接、onCancel 里摘；两次回调都带身份校验，保证 cancel 之后
     * 迟到的 emit 打不到已失效的 sink（与 MediaSessionChannel 同一个写法）。
     */
    private val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
            // 重新订阅 = 新客户端接管（同一个 engine 里销毁 controller 再建一个也走这里）：
            // 复位上一次 dispose() 留下的闩锁，否则新客户端 prepare 会全部早退。
            authority.onClientAttached()
            activeSink = sink
            authority.attachPublisher { state ->
                val current = activeSink
                if (current != null && current === sink) {
                    current.success(state)
                }
            }
            // 立刻推一份真实快照：Dart 刚订阅就拿得到当前状态，不必等下一次变化。
            authority.emit()
        }

        override fun onCancel(arguments: Any?) {
            activeSink = null
            authority.attachPublisher(null)
        }
    }

    private fun attach() {
        // 新 engine 接管同一个进程级 authority（见 companion 的 authority 注释）：
        // 复位 dispose 闩锁，否则一次 Dart dispose 会让后续 engine 的 prepare 全部早退。
        authority.onClientAttached()
        methodChannel.setMethodCallHandler { call, result -> handle(call, result) }
        eventChannel.setStreamHandler(streamHandler)
        registerLifecycle()
    }

    private fun detach() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        activeSink = null
        authority.attachPublisher(null)
        unregisterLifecycle()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_PREPARE -> {
                val arguments = call.arguments as? Map<*, *>
                val url = arguments?.get("url") as? String
                val generation = (arguments?.get("generation") as? Number)?.toInt()
                if (url.isNullOrEmpty() || generation == null) {
                    result.error(
                        "invalid_arguments",
                        "prepare requires url(String) and generation(Number)",
                        null,
                    )
                    return
                }
                result.success(authority.prepare(url, generation))
            }

            METHOD_PLAY -> withGeneration(call, result, "play") { generation ->
                authority.play(generation)
            }

            METHOD_PAUSE -> withGeneration(call, result, "pause") { generation ->
                authority.pause(generation)
            }

            METHOD_SEEK, METHOD_SEEK_ALIAS -> {
                val arguments = call.arguments as? Map<*, *>
                val positionMs = (arguments?.get("positionMs") as? Number)?.toDouble()
                val generation = (arguments?.get("generation") as? Number)?.toInt()
                if (positionMs == null || generation == null) {
                    result.error(
                        "invalid_arguments",
                        "seek requires positionMs(Number) and generation(Number)",
                        null,
                    )
                    return
                }
                result.success(authority.seekTo(positionMs, generation))
            }

            METHOD_STOP -> result.success(authority.stop())
            METHOD_DISPOSE -> result.success(authority.dispose())
            METHOD_GET_STATE -> result.success(authority.snapshot())
            else -> result.notImplemented()
        }
    }

    /** play/pause 共用的参数校验：generation 是必需参数，缺了不猜默认值。 */
    private fun withGeneration(
        call: MethodCall,
        result: MethodChannel.Result,
        method: String,
        run: (Int) -> Map<String, Any?>,
    ) {
        val arguments = call.arguments as? Map<*, *>
        val generation = (arguments?.get("generation") as? Number)?.toInt()
        if (generation == null) {
            result.error("invalid_arguments", "$method requires generation(Number)", null)
            return
        }
        result.success(run(generation))
    }

    /**
     * 只在 onDestroy 释放（见文件头「生命周期」）。
     *
     * 本应用是单 Activity：AndroidManifest.xml:25-47 只有 .MainActivity，且 configChanges 覆盖
     * 方向/尺寸/密度，旋转不重建。所以任何一次 onActivityDestroyed 都等价于「宿主要收尾了」。
     */
    private fun registerLifecycle() {
        if (lifecycleCallbacks != null) {
            return
        }
        val application = contextProvider()?.applicationContext as? Application ?: return
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {
                // 兜底路径：正常收尾走 uninstall()（那里的注销发生在本次 dispatch 之前，
                // 所以本回调通常不会触发）。真触发时同样必须一起收尾媒体会话，
                // 否则会留下"没有播放器却可点"的通知。
                authority.releaseForHostShutdown()
                MediaSessionHost.shutdown()
            }
        }
        try {
            application.registerActivityLifecycleCallbacks(callbacks)
            lifecycleCallbacks = callbacks
        } catch (failure: RuntimeException) {
            // 注册失败只降级：音频仍然能播，只是宿主收尾时不会自动释放。
            Log.w(TAG, "audio lifecycle callbacks not registered", failure)
        }
    }

    private fun unregisterLifecycle() {
        val callbacks = lifecycleCallbacks ?: return
        lifecycleCallbacks = null
        val application = contextProvider()?.applicationContext as? Application ?: return
        try {
            application.unregisterActivityLifecycleCallbacks(callbacks)
        } catch (failure: RuntimeException) {
            Log.w(TAG, "audio lifecycle callbacks not unregistered", failure)
        }
    }

    companion object {
        /** Dart 侧 basicAudioChannel 必须与此逐字相同。 */
        const val METHOD_CHANNEL = "rhine.music.database/basic_audio"

        /** Dart 侧 basicAudioStateChannel 必须与此逐字相同。 */
        const val EVENT_CHANNEL = "rhine.music.database/basic_audio_state"

        private const val TAG = "RhineBasicAudio"

        private const val METHOD_PREPARE = "prepare"
        private const val METHOD_PLAY = "play"
        private const val METHOD_PAUSE = "pause"
        private const val METHOD_SEEK = "seekTo"

        /**
         * compat alias, Dart 不发送。
         *
         * 协调者催交消息里写的是 seek{positionMs,generation}，冻结契约 v1 写的是 seekTo；
         * 两个名字都收，但 Dart 侧只发 seekTo（MethodChannelBasicAudio 里的调用点固定是
         * 'seekTo'）。两个名字走同一分支、同一个 boundSeek 夹取，不存在第二条 seek 路径。
         */
        private const val METHOD_SEEK_ALIAS = "seek"
        private const val METHOD_STOP = "stop"
        private const val METHOD_DISPOSE = "dispose"
        private const val METHOD_GET_STATE = "getState"

        /**
         * 进程内唯一播放权威。跨 engine 重装保留：Activity 重建/new engine 不会把正在播放的
         * MediaPlayer 弄丢；真正的释放只走 dispose / stop / onDestroy。
         */
        private var authority: PlaybackAuthority? = null
        private var current: BasicAudioChannel? = null

        /**
         * MainActivity.configureFlutterEngine 调用（每个 engine 一次，主线程）。
         *
         * @param messenger engine 的 binary messenger。
         * @param contextProvider 现取 Context（MainActivity 传 { this }），不把 Activity 存成长期字段。
         */
        fun install(messenger: BinaryMessenger, contextProvider: () -> Context?) {
            val shared = authority ?: PlaybackAuthority().also { authority = it }
            current?.detach()
            current = BasicAudioChannel(messenger, contextProvider, shared).also { it.attach() }
        }

        /**
         * 宿主 Activity 销毁时断开：`current` 握 messenger（→ FlutterEngine → 平台视图 →
         * 旧 Activity）和 `contextProvider`（闭包捕获 Activity），而 `registerLifecycle()`
         * 注册在 Application（进程级单例）上的匿名回调又反向握着本对象——不在这里显式断，
         * 旧 Activity 永远进不了回收（132R 的 cycle 探针 activity=false 就是它）。
         *
         * 前提（写清楚，免得当成 bug 再次踩）：本方法的收尾力度是"整个宿主结束"，不是
         * "换一个 Activity"。它假定 uninstall 之后进程内不再有 live Activity/engine 需要播放——
         * 也就是配置变化都被 AndroidManifest 的 configChanges 吸收（当前覆盖 orientation/
         * screenSize/density/uiMode 等）。若将来出现 configChanges 未覆盖的重建，旧 Activity 的
         * uninstall 会晚于新 Activity 的 install 执行，那时它会把新 engine 的通道一并摘掉并停掉
         * 播放；真要做多 Activity/多 engine 支持，必须改成按 owner 守卫（install 记 owner，
         * uninstall(owner) 在 current !== owner 时直接返回）。
         *
         * 断通道**同时**收尾唯一播放实例与媒体会话（MEDIA-CONTROLS-146）：
         *   - 断完通道就不存在能发命令的客户端了，留着 MediaPlayer 只会是"没有主人的声音"；
         *   - MainActivity.onDestroy 先调本方法、再调 super.onDestroy()，而
         *     Application.dispatchActivityDestroyed 发生在 super 里——registerLifecycle 的回调
         *     此刻已经注销，所以**不能**指望 onActivityDestroyed 兜底（本分支以前就是这么漏的：
         *     Back 之后 MediaPlayer 还在响，通知还停在"播放中"且按钮可点）；
         *   - 服务只保留 application 级资源（MediaSessionHost.appContext），不留 Activity/Engine
         *     闭包，前台通知由 MediaSessionHost.shutdown 撤掉后 stopSelf。
         */
        fun uninstall() {
            current?.detach()
            current = null
            // 先摘两个通道：这一句才真正掐断 Activity/Engine 闭包（MEDIA-CONTROLS-146 之前
            // 通道是 install 里的局部量，只挂在 engine 的 messenger 上；现在它被 object 字段
            // 持有，不显式 uninstall 就会把 Activity + engine 一直钉住），同时清掉 sink 与
            // 在途媒体动作。放在释放播放器之前，保证收尾期间不会再有动作投进旧 engine。
            MediaSessionChannel.uninstall()
            authority?.releaseForHostShutdown()
            // 会话与通知跟随唯一音频实例一起收尾：没有播放器就不该有可点的媒体控件。
            MediaSessionHost.shutdown()
        }
    }
}

/**
 * 播放状态与唯一 MediaPlayer 实例的持有者（主线程独占）。
 *
 * 只在 BasicAudioChannel 内部可见；对外只经通道读写。所有方法返回「执行后的真实状态 map」，
 * 通道层把它当作 MethodChannel 的成功返回值，Dart 侧据此刷新本地快照。
 *
 * ## 职责边界（写死，防止这里长成第二个 controller）
 * 本类**只是音频引擎权威**：持有唯一 MediaPlayer，回答「现在是否在响、走到第几毫秒、
 * 多长、有没有错」。下列内容一律不属于本类，看到它们出现在这里就是越界：
 * - 播放队列 / 下一首上一首 / 随机与循环模式（归 A 的 BasicController）
 * - 歌词、时间轴高亮（归 A 的 BasicController）
 * - 页面导航、选中的专辑/歌曲、搜索状态（归 A 的 BasicController）
 * - 账号、收藏、网络请求、通知文案（通知归 porting/MediaSessionHost）
 * 需要队列信息才能决定的事情，由 Dart 侧算完再用 prepare/play/pause/seekTo/stop 下命令，
 * 本类不向上要数据、不回调业务。
 *
 * 线程：全部方法必须主线程调用（Handler(Looper.getMainLooper())）；回调也都在主线程。
 */
private class PlaybackAuthority {

    private val handler = Handler(Looper.getMainLooper())

    private var player: MediaPlayer? = null

    /** 内部令牌：每次 prepare/释放 ++，用于丢弃旧实例的迟到回调。 */
    private var epoch = 0

    /** 跨语言代际：Dart prepare 时传入，回包与事件原样带回。 */
    private var generation = 0

    private var hasSource = false
    private var prepared = false
    private var playing = false
    private var buffering = false
    private var completed = false
    private var error = ""
    private var positionMs = 0L
    private var durationMs = 0L

    /** play 在 prepare 完成前到达时先记下意图，onPrepared 里真正 start（不做假播放）。 */
    private var playWhenPrepared = false

    /** seek 在 prepare 完成前到达时的目标位置，onPrepared 里兑现。 */
    private var pendingSeekMs: Long? = null

    private var publisher: ((Map<String, Any?>) -> Unit)? = null
    private var disposed = false

    /**
     * 播放中的位置轮询：**只读** MediaPlayer.currentPosition 推给 Dart。
     *
     * 这里没有任何时间差累加：如果实例停了（暂停、错误、播放器自己停下），轮询直接收摊，
     * 位置不会继续走。周期取 250ms 是为了让 Dart 的进度条与真实音频的差不超过一帧量级，
     * 而不是为了产生数字。
     *
     * 生命周期：只在 startPlayer() 里 postDelayed（先 stopTicker 再挂，永不叠加）。
     * pause / stop / dispose / fail(onError) / onCompletion / 换曲 prepare(reset 之前)
     * 六条路径全部 removeCallbacks(ticker)，所以旧实例不可能在新 generation 下继续上报。
     * ticker 自己也在 player == null / !prepared / !isPlaying 时直接 return 不再重挂。
     */
    private val ticker = object : Runnable {
        override fun run() {
            if (disposed) {
                return
            }
            val mp = player ?: return
            if (!prepared) {
                return
            }
            if (!isPlayingOf(mp)) {
                playing = false
                emit()
                return
            }
            positionMs = positionOf(mp)
            emit()
            handler.postDelayed(this, POSITION_POLL_MS)
        }
    }

    fun attachPublisher(next: ((Map<String, Any?>) -> Unit)?) {
        publisher = next
    }

    /**
     * 新客户端接管（engine 重装，或 EventChannel 重新订阅 / 重建 controller）。
     *
     * 两件事一起复位，缺一不可：
     *  - disposed：dispose() 只结束「这一次客户端会话」，不能在进程级单例上留下永久闩锁：
     *    authority 跨 install 复用，而 BasicAudioPort.dispose() 是冻结契约的公开方法，上层销毁
     *    controller 再建一个新的就会踩到。
     *  - generation：代际是**客户端命名空间**。Qt 的 m_generation 属于 MusicPlayer 实例
     *    （MusicPlayer.cpp:148 / :275 / :459），实例换了就从 0 重数；本类却是进程级单例，
     *    Dart 侧每次新建 controller 也从 1 重数。这里不归零，onListen 紧接着补推的 snapshot()
     *    （:109）就会带着上一次会话的旧代，Dart 的 _acceptedGeneration 被抬到旧值后，
     *    新客户端的 prepare(1) 会被当成旧命令丢掉 → 重进 App 后第一首无声、第二首才恢复，
     *    且 error 为空（现场表现与 generation 完全不搭边，排查成本极高）。
     *    归零是安全的：prepare 永远当作「新的一次意图」接受（见 prepare 的注释），
     *    play/pause/seekTo 的等值校验本来也只认当前代。
     * 复位点只有这里，由 attach() 与 EventChannel.onListen 各调一次；除此之外没有任何地方
     * 会把 disposed 改回 false。
     */
    fun onClientAttached() {
        disposed = false
        // 客户端换了，代际命名空间跟着换：旧快照不能再给新客户端的地板砖垫高。
        generation = 0
    }

    fun emit() {
        val publish = publisher ?: return
        publish(snapshot())
    }

    /**
     * 当前真实状态。有实例时每次都回读 currentPosition / duration / isPlaying，
     * 内存里的字段只是缓存，不是「预计值」。
     */
    fun snapshot(): Map<String, Any?> {
        val mp = player
        if (prepared && mp != null) {
            val liveDuration = durationOf(mp)
            if (liveDuration > 0) {
                durationMs = liveDuration
            }
            val livePosition = positionOf(mp)
            if (livePosition >= 0) {
                positionMs = livePosition
            }
            playing = isPlayingOf(mp)
        } else {
            playing = false
        }
        return mapOf(
            "playing" to playing,
            "buffering" to buffering,
            "completed" to completed,
            "positionMs" to positionMs,
            "durationMs" to durationMs,
            "generation" to generation,
            "error" to error,
        )
    }

    fun prepare(url: String, requestedGeneration: Int): Map<String, Any?> {
        if (disposed) {
            return snapshot()
        }
        // 这里**不**做「requestedGeneration 小于当前代就丢弃」的顺序判断，原因是一次真实的
        // 命名空间错位：Qt 的 valid(generation)（定义 MusicPlayer.cpp:225-227，使用 :442）比较的
        // 是**同一个 MusicPlayer 实例**的 m_generation，而每个实例的代际都从 0 自己数
        // （MusicPlayer.cpp:148 / :275 / :459 各自 ++m_generation）——Qt 根本没有跨播放器共享的
        // 单调计数器。本类却是进程级单例（companion 里的 authority，install 复用），而 MainActivity
        // 没有 FlutterEngineCache：Activity 销毁后重开 = 新 engine + 新 Dart isolate，Dart 的
        // generation 从 1 重新数。若按「小于即旧代」拒绝，prepare(1) 会被永远当成旧代返回旧快照，
        // 随后的 play(1) 又被下面的等值校验拒掉 → 同一进程内第二次进 App 全程无声且 error 为空，
        // 只能杀进程恢复。
        // 真正拦旧命令的是三处等值校验（play/pause/seekTo 都要求 requestedGeneration == generation）
        // 加上 Dart 侧的 _acceptedGeneration（Dart 的 prepare 同样不再按代际大小丢弃，见
        // platform_playback.dart 的 prepare 注释）；prepare 则始终当作「新的一次意图」接受。
        // 迟到的旧 prepare 不可能后到：同一个 MethodChannel 有序，且 Dart 在 dispose 后不再下发。

        // 同代重复 prepare：不重放（防止正在播的实例被同一个 generation 意外拆掉）。
        // 例外是失败态：Dart 侧重试同一首时可能沿用同一个 generation，这里允许它真正重来，
        // 否则 error 之后 play() 被 fail-fast 拦住，用户永远点不动。
        // 注意 error.isEmpty() 这半个条件是有意的，不是漏洞：删掉它 = 失败态永久卡死。
        if (requestedGeneration == generation && hasSource && error.isEmpty()) {
            return snapshot()
        }
        generation = requestedGeneration
        releasePlayer()
        hasSource = true
        completed = false
        error = ""
        positionMs = 0L
        durationMs = 0L
        buffering = true
        playWhenPrepared = false
        pendingSeekMs = null
        val token = epoch
        val created = MediaPlayer()
        player = created
        created.setAudioAttributes(AUDIO_ATTRIBUTES)
        created.setOnPreparedListener { mp -> onPrepared(token, mp) }
        created.setOnCompletionListener { onCompletion(token) }
        created.setOnErrorListener { _, what, extra -> onError(token, what, extra) }
        created.setOnInfoListener { _, what, extra -> onInfo(token, what, extra) }
        created.setOnSeekCompleteListener { onSeekComplete(token) }
        try {
            created.setDataSource(url)
            created.prepareAsync()
        } catch (failure: Exception) {
            // setDataSource 的 IOException / prepareAsync 的 IllegalStateException /
            // SecurityException 都落这里：不给 Dart 报「正在加载」，直接是失败态。
            fail(token, "音频地址不可用：" + (failure.message ?: failure.javaClass.simpleName))
        }
        emit()
        return snapshot()
    }

    fun play(requestedGeneration: Int): Map<String, Any?> {
        if (disposed) {
            return snapshot()
        }
        if (requestedGeneration != generation) {
            return snapshot()
        }
        // 已经失败过：必须由新一轮 prepare 重来，不能靠 play 静默复活。
        if (error.isNotEmpty()) {
            return snapshot()
        }
        val mp = player
        if (mp == null || !hasSource) {
            error = "尚未准备音源"
            emit()
            return snapshot()
        }
        playWhenPrepared = true
        if (!prepared) {
            // 还在 prepareAsync 里：记下意图，onPrepared 再 start。播放态永远是 false 直到真的响。
            buffering = true
            emit()
            return snapshot()
        }
        if (completed) {
            completed = false
            positionMs = 0L
            seekSafely(mp, 0L)
        }
        startPlayer()
        return snapshot()
    }

    fun pause(requestedGeneration: Int): Map<String, Any?> {
        if (disposed) {
            return snapshot()
        }
        if (requestedGeneration != generation) {
            return snapshot()
        }
        playWhenPrepared = false
        val mp = player
        if (mp != null && prepared) {
            try {
                if (mp.isPlaying) {
                    mp.pause()
                }
            } catch (failure: IllegalStateException) {
                Log.w(TAG, "MediaPlayer.pause rejected", failure)
            }
            positionMs = positionOf(mp)
        }
        stopTicker()
        playing = false
        buffering = false
        emit()
        return snapshot()
    }

    fun seekTo(targetMs: Double, requestedGeneration: Int): Map<String, Any?> {
        if (disposed) {
            return snapshot()
        }
        if (requestedGeneration != generation) {
            return snapshot()
        }
        val bounded = boundSeek(targetMs, durationMs)
        val mp = player
        if (mp == null || !prepared) {
            pendingSeekMs = bounded
            positionMs = bounded
            emit()
            return snapshot()
        }
        positionMs = bounded
        completed = false
        seekSafely(mp, bounded)
        // 立即回读；MediaPlayer.seekTo 是异步的，真正落点由 onSeekComplete 再推一次。
        emit()
        return snapshot()
    }

    fun stop(): Map<String, Any?> {
        if (disposed) {
            return snapshot()
        }
        releasePlayer()
        hasSource = false
        completed = false
        error = ""
        positionMs = 0L
        durationMs = 0L
        emit()
        return snapshot()
    }

    fun dispose(): Map<String, Any?> {
        if (disposed) {
            return snapshot()
        }
        disposed = true
        releasePlayer()
        hasSource = false
        completed = false
        error = ""
        positionMs = 0L
        durationMs = 0L
        val state = snapshot()
        publisher?.invoke(state)
        publisher = null
        return state
    }

    /**
     * Activity onDestroy：释放实例并回到 idle（有前台服务才能托住播放，见类头注释）。
     * generation 这里不动：此刻已经没有任何客户端会再发命令，下一个客户端接管时
     * onClientAttached() 会把它归零，代际命名空间随客户端切换。
     */
    fun releaseForHostShutdown() {
        if (disposed) {
            return
        }
        releasePlayer()
        hasSource = false
        prepared = false
        playing = false
        buffering = false
        completed = false
        error = ""
        positionMs = 0L
        durationMs = 0L
        emit()
    }

    private fun onPrepared(token: Int, mp: MediaPlayer) {
        if (token != epoch) {
            return
        }
        prepared = true
        buffering = false
        val liveDuration = durationOf(mp)
        if (liveDuration > 0) {
            durationMs = liveDuration
        }
        val pending = pendingSeekMs
        pendingSeekMs = null
        if (pending != null) {
            positionMs = pending
            seekSafely(mp, pending)
        }
        if (playWhenPrepared) {
            startPlayer()
        } else {
            emit()
        }
    }

    private fun startPlayer() {
        val mp = player ?: return
        if (!prepared) {
            return
        }
        try {
            mp.start()
        } catch (failure: IllegalStateException) {
            fail(epoch, "播放启动失败：" + (failure.message ?: "IllegalStateException"))
            return
        }
        playing = true
        buffering = false
        completed = false
        playWhenPrepared = false
        startTicker()
        emit()
    }

    private fun onCompletion(token: Int) {
        if (token != epoch) {
            return
        }
        stopTicker()
        playWhenPrepared = false
        buffering = false
        completed = true
        playing = false
        val mp = player
        if (mp != null) {
            positionMs = positionOf(mp)
            val liveDuration = durationOf(mp)
            if (liveDuration > 0) {
                durationMs = liveDuration
            }
        }
        emit()
    }

    private fun onError(token: Int, what: Int, extra: Int): Boolean {
        if (token != epoch) {
            return true
        }
        fail(token, "播放失败（what=" + what + ", extra=" + extra + "）")
        return true
    }

    private fun onInfo(token: Int, what: Int, extra: Int): Boolean {
        if (token != epoch) {
            return false
        }
        return when (what) {
            MediaPlayer.MEDIA_INFO_BUFFERING_START -> {
                buffering = true
                emit()
                true
            }

            MediaPlayer.MEDIA_INFO_BUFFERING_END -> {
                buffering = false
                emit()
                true
            }

            else -> false
        }
    }

    private fun onSeekComplete(token: Int) {
        if (token != epoch) {
            return
        }
        val mp = player ?: return
        positionMs = positionOf(mp)
        emit()
    }

    /**
     * 失败态：记错误、把坏实例摘下来（之后 play 不会再打到不可用对象），等下一轮 prepare。
     *
     * 这里**不**直接 release：fail 绝大多数时候正跑在 MediaPlayer.onError 的回调栈里，
     * 在自己的回调里 release 自己是 Android 上公认的踩雷点（release 之后回调通道还在用）。
     * 所以先同步 detachPlayer()（epoch 已 ++、监听器已摘，旧回调立刻失效），
     * 再把 release 丢回主线程队列。
     */
    private fun fail(token: Int, message: String) {
        if (token != epoch) {
            return
        }
        error = message
        completed = false
        val dying = detachPlayer()
        emit()
        if (dying != null) {
            handler.post { releaseQuietly(dying) }
        }
    }

    /** 释放当前实例（同步）。所有不在 MediaPlayer 回调栈里的路径都走这里。 */
    private fun releasePlayer() {
        val mp = detachPlayer() ?: return
        releaseQuietly(mp)
    }

    /**
     * 把实例从状态里摘下来：++epoch、停 ticker、摘五个监听器，返回待释放的实例（可能为 null）。
     * 与 releaseQuietly 拆开是为了让 fail() 能在回调栈内先摘、事后再 release。
     */
    private fun detachPlayer(): MediaPlayer? {
        ++epoch
        stopTicker()
        val mp = player
        player = null
        prepared = false
        playing = false
        buffering = false
        playWhenPrepared = false
        pendingSeekMs = null
        if (mp != null) {
            // 先摘监听器再 release：避免 release 过程中还有回调打到本对象。
            mp.setOnPreparedListener(null)
            mp.setOnCompletionListener(null)
            mp.setOnErrorListener(null)
            mp.setOnInfoListener(null)
            mp.setOnSeekCompleteListener(null)
        }
        return mp
    }

    private fun releaseQuietly(mp: MediaPlayer) {
        try {
            mp.release()
        } catch (failure: IllegalStateException) {
            Log.w(TAG, "MediaPlayer.release rejected", failure)
        }
    }

    private fun startTicker() {
        stopTicker()
        handler.postDelayed(ticker, POSITION_POLL_MS)
    }

    private fun stopTicker() {
        handler.removeCallbacks(ticker)
    }

    private fun seekSafely(mp: MediaPlayer, targetMs: Long) {
        try {
            mp.seekTo(targetMs.toInt())
        } catch (failure: IllegalStateException) {
            Log.w(TAG, "MediaPlayer.seekTo rejected", failure)
        }
    }

    private fun positionOf(mp: MediaPlayer): Long = try {
        mp.currentPosition.toLong()
    } catch (failure: IllegalStateException) {
        positionMs
    }

    private fun durationOf(mp: MediaPlayer): Long = try {
        mp.duration.toLong()
    } catch (failure: IllegalStateException) {
        0L
    }

    private fun isPlayingOf(mp: MediaPlayer): Boolean = try {
        mp.isPlaying
    } catch (failure: IllegalStateException) {
        false
    }

    private companion object {
        const val TAG = "RhineBasicAudio"

        /** 位置轮询周期（毫秒）。只控制推送频率，不参与任何位置计算。 */
        const val POSITION_POLL_MS = 250L

        /** Qt 侧 AudioPlayer 的 QAudioOutput 走媒体流；这里用 USAGE_MEDIA + MUSIC 让系统按音乐处理。 */
        val AUDIO_ATTRIBUTES: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        /**
         * seek 目标夹取。Qt/src/AudioPlayer.cpp:419-421 是 clamp(value, 0, duration)，
         * 但 AudioPlayer.cpp:385 对 !std::isfinite 是**直接 return、整次 seek 被忽略**。
         * 这里比 Qt 多一层有限性归一：NaN -> 0，+inf -> duration（时长未知时为 0），
         * -inf/负数 -> 0，超上界 -> duration——归一后的目标总会真的下发给 MediaPlayer，
         * 不会出现「Dart 以为 seek 了、播放器其实没动」的静默分叉。这一层差异是故意的。
         */
        fun boundSeek(targetMs: Double, durationMs: Long): Long {
            val upper = if (durationMs > 0L) durationMs.toDouble() else 0.0
            val bounded = when {
                targetMs.isNaN() -> 0.0
                targetMs == Double.POSITIVE_INFINITY -> upper
                targetMs <= 0.0 -> 0.0
                upper > 0.0 && targetMs > upper -> upper
                else -> targetMs
            }
            return bounded.toLong()
        }
    }
}
