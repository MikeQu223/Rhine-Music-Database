package rhine.music.database.qt

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.qtproject.qt.android.RhineQtViews

private const val TAG = "QtSceneChannel"

/**
 * Dart ↔ Qt 场景的通道（PARITY NATIVE-RECOVERY-132R）。
 *
 * 只有两个方法/回调，语义尽量窄：
 *   Dart → 原生 `state`  {viewId:int, json:String}：渲染状态快照（主题/模式/选中行/身份键）。
 *   Dart → 原生 `pointer` {viewId:int, type:String, x:double, y:double}：原始指针（舞台单位），
 *       仅在 Android 原生派发到不了 Qt 子树时作为搬运通道（同一套 NativeSceneInput 逻辑）。
 *   Dart → 原生 `wheel`   {viewId:int, x:double, y:double, delta:double}：双指捏合换算成滚轮。
 *   原生 → Dart `action` {viewId:int, action:String}：Qt 场景里产生的动作（目前只有 "select:<i>"，
 *       即用户在 3D 场景里点中/拖到某张唱片）。
 *
 * 播放权威不在这里：Qt 只说"画面该长什么样"，不说"该播什么"。
 */
object QtSceneChannel {
    const val CHANNEL = "rhine.music/qt_scene"

    private var channel: MethodChannel? = null
    private val pushers = LinkedHashMap<Int, (String) -> Boolean>()
    private var activeViewId: Int? = null

    /**
     * Activity 销毁时必须调用：本对象是伴生 object（静态），只要它还握着 MethodChannel
     * 就等于握着 FlutterEngine，而 FlutterEngine 握着 PlatformViewsController 里创建过的
     * 平台视图 —— 旧 RhineQtView → 旧 Activity 就永远不会回收（生命周期探针全 false）。
     * 通道是"每引擎一份"的，engine 销毁后必须显式断开。
     */
    fun uninstall() {
        pushers.clear()
        activeViewId = null
        RhineQtViews.setSceneActionSink(null)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    fun install(engine: FlutterEngine) {
        if (channel != null) {
            return
        }
        val methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result -> handle(call, result) }
        RhineQtViews.setSceneActionSink { action -> dispatchAction(action) }
        Log.i(TAG, "qt scene channel installed")
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> {
                val arguments = call.arguments as? Map<*, *>
                val viewId = (arguments?.get("viewId") as? Number)?.toInt()
                val json = arguments?.get("json") as? String
                val push = viewId?.let { pushers[it] }
                if (push == null || json == null) {
                    result.success(false)
                    return
                }
                try {
                    // 把原生侧"是否受理"如实回给 Dart：false 时 Dart 会清掉去重记录，
                    // 下一次状态变化会重发（首帧早于 qApp 的老问题）。
                    result.success(push(json))
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
                if (type == null || x == null || y == null || viewId !in pushers) {
                    result.success(false)
                    return
                }
                RhineQtViews.pushScenePointer(type, x, y)
                result.success(true)
            }
            "wheel" -> {
                val arguments = call.arguments as? Map<*, *>
                val x = (arguments?.get("x") as? Number)?.toDouble()
                val y = (arguments?.get("y") as? Number)?.toDouble()
                val delta = (arguments?.get("delta") as? Number)?.toDouble()
                val viewId = (arguments?.get("viewId") as? Number)?.toInt()
                if (x == null || y == null || delta == null || viewId !in pushers) {
                    result.success(false)
                    return
                }
                RhineQtViews.pushSceneWheel(x, y, delta)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** 视图创建后登记自己的推送入口；同一时刻只有一个场景视图会被派发动作。 */
    fun register(viewId: Int, push: (String) -> Boolean) {
        pushers[viewId] = push
        activeViewId = viewId
    }

    fun unregister(viewId: Int) {
        pushers.remove(viewId)
        if (activeViewId == viewId) {
            activeViewId = pushers.keys.lastOrNull()
        }
    }

    /** 原生 → Dart 的动作转发。**当前无生产者**：见 RhineQtViews.emitSceneAction 的说明。 */
    private fun dispatchAction(action: String) {
        val viewId = activeViewId
        val methodChannel = channel
        if (viewId == null || methodChannel == null) {
            Log.w(TAG, "scene action without a live view: $action")
            return
        }
        // 这里在 Qt 主线程（= Android UI 线程），可以直接调用 MethodChannel。
        methodChannel.invokeMethod("action", mapOf("viewId" to viewId, "action" to action))
    }
}
