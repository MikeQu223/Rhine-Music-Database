package rhine.music.database.qt

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.qtproject.qt.android.RhineQtViews
import java.lang.ref.WeakReference

private const val TAG = "QtSceneChannel"

/**
 * Dart ↔ Qt 场景的通道（PARITY NATIVE-RECOVERY-132R / FINAL-INTEGRATION-150）。
 *
 * 方法/回调：
 *   Dart → 原生 `state`   {viewId:int, ctx:int, json:String}：渲染状态快照（主题/模式/选中行/身份键）。
 *   Dart → 原生 `pointer` {viewId:int, ctx:int, type:String, x:double, y:double}：原始指针（舞台单位），
 *       仅在 Android 原生派发到不了 Qt 子树时作为搬运通道（同一套 NativeSceneInput 逻辑）。
 *   Dart → 原生 `wheel`   {viewId:int, ctx:int, x:double, y:double, delta:double}：双指捏合换算成滚轮。
 *   原生 → Dart `action`  {viewId:int, ctx:int, action:String}：Qt 场景里产生的动作（"select:<i>"、
 *       "archive-scroll:<phase>:<delta>"、"archive-step:<n>" 等）。
 *
 * **origin 是每条消息的一部分**（不是"当前前台视图"的推断）：
 *  - `state` 带来 (viewId, ctx)，本对象按视图登记最后受理的代次；
 *  - `pointer`/`wheel` 必须带同一个 viewId 且 ctx 与该视图登记值一致，否则丢弃——
 *    排队中的旧 A 视图事件不会在 B 接手后落到 B 的场景上；
 *  - `action` 由 Qt 侧带着**它自己记住的** (viewId, ctx) 回传，这里再校验一次：
 *    同 view 换目录（ctx 递增）后，旧代次的动作不交给 Dart 页面。
 *
 * 播放权威不在这里：Qt 只说"画面该长什么样"，不说"该播什么"。
 */
object QtSceneChannel {
    const val CHANNEL = "rhine.music/qt_scene"

    private var channel: MethodChannel? = null

    /** 装过本通道的宿主（FlutterActivity）。弱持有：不能因为诊断记录把 Activity 钉住。 */
    private var owner = WeakReference<Any>(null)

    private val pushers = LinkedHashMap<Int, (String, Int, Long) -> Boolean>()

    /** 每个视图最后受理的状态快照代次；输入事件按它校验 origin。 */
    private val contexts = LinkedHashMap<Int, Long>()

    private var activeViewId: Int? = null

    /**
     * Activity 销毁时必须调用：本对象是伴生 object（静态），只要它还握着 MethodChannel
     * 就等于握着 FlutterEngine，而 FlutterEngine 握着 PlatformViewsController 里创建过的
     * 平台视图 —— 旧 RhineQtView → 旧 Activity 就永远不会回收（生命周期探针全 false）。
     * 通道是"每引擎一份"的，engine 销毁后必须显式断开。
     *
     * [host] 给了就做归属校验：旧 Activity 的 onDestroy 晚到（新宿主已经 install）时不能
     * 把新宿主的通道拆掉——旧 onDestroy 只允许拆自己的那一份。
     */
    fun uninstall(host: Any? = null) {
        if (host != null) {
            val current = owner.get()
            if (current != null && current !== host) {
                Log.i(TAG, "scene channel kept: uninstall from a stale host")
                return
            }
        }
        pushers.clear()
        contexts.clear()
        activeViewId = null
        owner = WeakReference(null)
        RhineQtViews.setSceneActionSink(null)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    fun install(engine: FlutterEngine, host: Any? = null) {
        val messenger = engine.dartExecutor.binaryMessenger
        val existing = channel
        if (existing != null) {
            // 同一引擎重复 install（热重启/重建 Activity）：保持原通道，只更新宿主归属。
            if (host != null) {
                owner = WeakReference(host)
            }
            return
        }
        val methodChannel = MethodChannel(messenger, CHANNEL)
        channel = methodChannel
        if (host != null) {
            owner = WeakReference(host)
        }
        methodChannel.setMethodCallHandler { call, result -> handle(call, result) }
        RhineQtViews.setSceneActionSink { viewId, context, action ->
            dispatchAction(viewId, context, action)
        }
        Log.i(TAG, "qt scene channel installed")
    }

    private fun contextOf(arguments: Map<*, *>?): Long =
        (arguments?.get("ctx") as? Number)?.toLong() ?: 0L

    /**
     * 输入事件的 origin 校验。返回 false 表示这条事件属于已被替换的视图/代次。
     *
     * 只在**已登记**的视图上比较：Dart 侧 ctx=0 表示"还没换代次"，此时按旧行为放行，
     * 不能因为原生多知道一点就把正常拖动拒掉。
     */
    private fun acceptsInput(viewId: Int?, context: Long): Boolean {
        if (viewId == null || viewId !in pushers) {
            return false
        }
        if (context == 0L) {
            return true
        }
        val known = contexts[viewId] ?: return true
        return known == 0L || known == context
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> {
                val arguments = call.arguments as? Map<*, *>
                val viewId = (arguments?.get("viewId") as? Number)?.toInt()
                val json = arguments?.get("json") as? String
                val context = contextOf(arguments)
                val push = viewId?.let { pushers[it] }
                if (push == null || json == null) {
                    result.success(false)
                    return
                }
                // 先登记 origin 再投递：Qt 侧受理这份快照后，就以它为"当前画面来源"。
                if (context != 0L) {
                    contexts[viewId] = context
                }
                activeViewId = viewId
                try {
                    // 把原生侧"是否受理"如实回给 Dart：false 时 Dart 会清掉去重记录，
                    // 下一次状态变化会重发（首帧早于 qApp 的老问题）。
                    result.success(push(json, viewId, context))
                } catch (error: Throwable) {
                    Log.w(TAG, "push scene state failed", error)
                    result.success(false)
                }
            }
            "pointer" -> {
                val arguments = call.arguments as? Map<*, *>
                val type = arguments?.get("type") as? String
                val x = (arguments?.get("x") as? Number)?.toDouble()
                val y = (arguments?.get("y") as? Number)?.toDouble()
                val viewId = (arguments?.get("viewId") as? Number)?.toInt()
                val context = contextOf(arguments)
                if (type == null || x == null || y == null || viewId == null || !acceptsInput(viewId, context)) {
                    if (viewId != null && viewId in pushers) {
                        Log.i(TAG, "pointer dropped: stale origin view=$viewId ctx=$context")
                    }
                    result.success(false)
                    return
                }
                RhineQtViews.pushScenePointer(viewId, context, type, x, y)
                result.success(true)
            }
            "wheel" -> {
                val arguments = call.arguments as? Map<*, *>
                val x = (arguments?.get("x") as? Number)?.toDouble()
                val y = (arguments?.get("y") as? Number)?.toDouble()
                val delta = (arguments?.get("delta") as? Number)?.toDouble()
                val viewId = (arguments?.get("viewId") as? Number)?.toInt()
                val context = contextOf(arguments)
                if (x == null || y == null || delta == null || viewId == null || !acceptsInput(viewId, context)) {
                    if (viewId != null && viewId in pushers) {
                        Log.i(TAG, "wheel dropped: stale origin view=$viewId ctx=$context")
                    }
                    result.success(false)
                    return
                }
                RhineQtViews.pushSceneWheel(viewId, context, x, y, delta)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** 视图创建后登记自己的推送入口；同一时刻只有一个场景视图会被派发动作。 */
    fun register(viewId: Int, push: (String, Int, Long) -> Boolean) {
        pushers[viewId] = push
        activeViewId = viewId
    }

    fun unregister(viewId: Int) {
        pushers.remove(viewId)
        contexts.remove(viewId)
        if (activeViewId == viewId) {
            activeViewId = pushers.keys.lastOrNull()
        }
    }

    /**
     * 原生 → Dart 的动作转发。[viewId]/[context] 是 **Qt 侧记住的 producer origin**
     * （不是这里猜的"当前前台"）。origin 未知（viewId<0，老调用点）时才退回 activeViewId。
     */
    private fun dispatchAction(viewId: Int, context: Long, action: String) {
        val methodChannel = channel
        if (methodChannel == null) {
            Log.w(TAG, "scene action without a live channel: $action")
            return
        }
        val originId = if (viewId >= 0) viewId else activeViewId
        if (originId == null || originId !in pushers) {
            Log.w(TAG, "scene action from a dead view view=$viewId: $action")
            return
        }
        if (viewId >= 0 && context != 0L) {
            val known = contexts[viewId] ?: 0L
            if (known != 0L && known != context) {
                // 同 view 换了目录/所属：旧代次的动作不能驱动新画面。
                Log.i(TAG, "scene action dropped: stale origin view=$viewId ctx=$context known=$known")
                return
            }
        }
        // 这里在 Qt 主线程（= Android UI 线程），可以直接调用 MethodChannel。
        methodChannel.invokeMethod(
            "action",
            mapOf("viewId" to originId, "ctx" to context, "action" to action),
        )
    }
}
