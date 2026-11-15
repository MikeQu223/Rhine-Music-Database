package rhine.music.database

import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import rhine.music.database.basic.BasicAudioChannel
import rhine.music.database.porting.MediaSessionChannel
import rhine.music.database.porting.QtPlatformViewHost
import rhine.music.database.qt.QT_SCENE_VIEW_TYPE
import rhine.music.database.qt.QtSceneViewFactory

private const val TAG = "RhineMainActivity"

/**
 * Android 宿主 Activity：返回键路由（DEDUP-37）。
 *
 * 为什么返回键必须由宿主自己排序：
 *  - Qt 的返回处理在 QtInputDelegate.onKeyDown（QtInputDelegate.java:503、:524、:544），
 *    由 QtActivityBase.dispatchKeyEvent/onKeyDown 送进去（QtActivityBase.java:271、:291-297）。
 *    QtActivityBase 只存在于 Qt 自己的 Activity 层级；本 Activity 继承 FlutterActivity，
 *    QtInputDelegate 又是包内可见类，宿主拿不到入口。
 *  - QtWindow.java 完全不处理按键（没有 onKeyDown/onKeyUp/dispatchKeyEvent），
 *    所以"合成一个 KEYCODE_BACK 派发进 Qt 视图树"也到不了 Qt 的输入层，
 *    只能走宿主自己的控制通道 verb（QtPlatformViewHost.dispatchBackVerb）。
 *
 * 顺序是契约：IME 可见 → 先隐 IME 并消费；否则向已挂载的 Qt 宿主视图"询问"一次 back
 * verb，只有对面明确认领（回复 Boolean true）才算消费；未挂载、未就绪、对面返回
 * null/false/error、通道未实现或 250ms 内没有回复，一律视为未认领并立即落回 Flutter
 * 默认返回（delegate → engine → Dart Navigator）。返回动作从不盲消费，也从不自行
 * 结束 Activity：业务页只能由 Flutter 的 Navigator 关闭。
 *
 * 现状（本原子交付时）：Dart 侧还没有 METHOD_BACK 的 handler（lib/platform/qt_platform_view.dart
 * 不在本原子的文件域，按 ARCH 候选 A 另开原子接）。平台通道对没有 handler 的方法回
 * "成功 + null"，按认领协议等于未认领，所以端到端行为是安全回落 Flutter 默认返回；
 * Qt 认领分支在 Dart 落地前不可达，本原子不声称端到端验证过。
 */
class MainActivity : FlutterActivity() {

    /**
     * API 33+ 的返回回调槽位。低版本为 null，系统仍调 [onBackPressed]。
     */
    private val hostBackDispatcher: HostBackDispatcher? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            HostBackDispatcher(this, ::dispatchHostBack)
        } else {
            null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 注册放在 super.onCreate 之后，而不是之前：Activity 恢复时 Flutter 会在
        // super.onCreate 内部先调一次 setFrameworkHandlesBack
        // （FlutterActivity.java:637-642），被本类的空覆盖挡住；即使将来绕开覆盖，
        // 同优先级只有"后注册者先派发"（OnBackInvokedDispatcher.java:96-97），
        // 宿主晚一步注册才排在 Flutter 之前，先隐 IME、再问 Qt 视图这两步才轮得到。
        // 注册本身是防御式的：失败只降级，不崩。
        hostBackDispatcher?.install()
        // 窗口形态放在 super.onCreate 之后：Flutter 在 super 内会按自己的状态栏策略改一次
        // systemUiVisibility，宿主最后写才算数；与返回回调的注册顺序无关。
        applyImmersiveSticky()
    }

    /**
     * 媒体会话通道接线（T25）。
     *
     * 必须在 super 之后：FlutterActivity.configureFlutterEngine 会先让 engine 完成
     * 默认插件装配，这里再挂自己的两个通道，避免被后续装配覆盖。传给 install 的是
     * activityProvider = { this } 而不是 this：通道层只在 ensureStarted 时现取 Activity，
     * 不把 Activity 存成长期字段（见 MediaSessionChannel.install 的注释）。
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MediaSessionChannel.install(
            flutterEngine.dartExecutor.binaryMessenger,
            { this },
            applicationContext,
        )
        // 两条注册都不碰上面 MediaSession 的顺序与语义。
        //  BasicAudioChannel 是真实音频的唯一权威（android.media.MediaPlayer）；MediaSession 只做
        //  通知/会话/焦点，不产生声音。QtSceneViewFactory 是 3D 场景 PlatformView 的工厂
        //  （view type "rhine/qt_scene"）：那个视图里跑的是本仓库 Qt 自己的 QQuickView，
        //  与 Flutter 在同一个进程里，不是第二个播放器、也不是另一个 Activity。
        //  两者都只在 engine 装配完成后各装一次：重复 install 会接管旧 channel
        //  （BasicAudioChannel.install 先 detach 再替换），不会叠出第二个实例。
        BasicAudioChannel.install(flutterEngine.dartExecutor.binaryMessenger) { this }
        flutterEngine.platformViewsController.registry.registerViewFactory(
            QT_SCENE_VIEW_TYPE,
            QtSceneViewFactory(),
        )
    }

    override fun onResume() {
        super.onResume()
        // 上滑预览、通知栏下拉、锁屏或权限对话框都可能把系统栏还回来；沉浸式只在
        // onCreate / onResume 两处重放（Qt/src/AndroidWindow.cpp:85-91 也是回到前台重放），
        // 不额外注册监听器，避免为一个窗口形态引入生命周期噪声。
        applyImmersiveSticky()
    }

    override fun onDestroy() {
        hostBackDispatcher?.remove()
        super.onDestroy()
    }

    /**
     * 返回键槽位归宿主所有，**故意不链到 super**。
     *
     * FlutterActivity 唯一的注册入口就是这个回调（FlutterActivity.java:730-736），
     * 而"先隐 IME、再交给 Qt 视图"必须排在任何 Flutter 返回动作之前。同优先级回调按
     * 注册逆序派发（OnBackInvokedDispatcher.java:96-97），谁最后注册谁先收到——把这里
     * 截断，Flutter 就永远注册不上，宿主的顺序不会被后来的注册挤到队尾。
     * 没人消费时宿主回调调用 super.onBackPressed()，终点与 Flutter 自己注册的非动画回调
     * 完全一致（FlutterActivity.java:701-726、:940-943 → delegate.onBackPressed → engine）。
     *
     * 代价与取舍：API 34+ 的预测式返回动画不再由 Flutter 的 OnBackAnimationCallback 驱动
     * （宿主注册的是普通 OnBackInvokedCallback）。Qt 侧本来就没有预测式返回
     * （QtInputDelegate 只在 onKeyDown 里处理已成事实的返回），所以这不是与 Qt 的偏离，
     * 而是为了保证返回顺序。frameworkHandlesBack 只表达"Dart 侧还能不能 pop"，
     * 不影响宿主的注册状态：交回时仍走同一条 super.onBackPressed() 默认路径。
     */
    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        // 注册/注销都由宿主的 hostBackDispatcher 负责（见 onCreate/onDestroy）；
        // 这里不转调 super：这是 Flutter 唯一会注册 PRIORITY_DEFAULT 回调的地方，
        // 放行一次就等于把宿主的 pre-hook 作废（同优先级后注册者先派发）。
    }

    /**
     * 低版本（< API 33）与系统未走 dispatcher 时的返回入口。
     *
     * 两个入口都只是"发起一次路由"，不做同步判定：Qt 那边的认领是异步回复，
     * 未认领时由 [dispatchHostBack] 里的回调补上 Flutter 默认返回。
     */
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        dispatchHostBack()
    }

    /**
     * 统一返回路由，顺序即契约：
     *  1. IME 可见 → 先隐 IME 并消费，不再往下问；
     *  2. 否则向挂载中的 Qt 宿主视图发 back verb 询问。只有对面回 Boolean true 才算
     *     认领/消费；null、false、error、通道未实现、engine 已 detach 或 250ms 超时都
     *     算未认领，立刻落回 Flutter 默认返回；
     *  3. 落回终点是 super.onBackPressed()（FlutterActivity.java:940-943 →
     *     delegate.onBackPressed → engine → Dart），与本类不接管时的行为完全一致。
     *
     * 不盲消费的理由：平台通道对"对面没有 handler"回的是成功 + null，宿主无法把它和
     * "处理了但没说话"区分开；把 null 当消费会让返回键静默失效。认领协议要求对面显式
     * 回 true，才把这次返回算作已处理。
     */
    @Suppress("DEPRECATION")
    private fun dispatchHostBack() {
        if (hideImeIfVisible()) return
        QtPlatformViewHost.dispatchBackVerb { claimed ->
            if (claimed) return@dispatchBackVerb
            fallBackToFlutter()
        }
    }

    /**
     * 交回 Flutter 默认返回。Activity 已经在收尾时不再补发，避免对已销毁的引擎投递。
     */
    @Suppress("DEPRECATION")
    private fun fallBackToFlutter() {
        if (isFinishing || isDestroyed) return
        // 与 Flutter 非动画回调同一终点：delegate.onBackPressed → engine → Dart。
        super.onBackPressed()
    }

    /**
     * IME 可见就只收起键盘并消费这次返回。
     *
     * 可见性判据按 SDK 分两支：API 30+ 读 WindowInsets.Type.ime()，更低版本用
     * 可见显示区与根视图高度差（>15%）的启发式——两处都不引第三方依赖。
     */
    private fun hideImeIfVisible(): Boolean {
        // getDecorView() 的平台类型是 View!：Kotlin 允许按可空接收，这里的判空是纯防御。
        val decor = window.decorView ?: return false
        if (!isImeVisible(decor)) return false
        val imm = getSystemService(InputMethodManager::class.java)
        val hidden = imm?.hideSoftInputFromWindow(decor.windowToken, 0) == true
        if (!hidden) {
            Log.i(TAG, "IME reported visible but hideSoftInputFromWindow had nothing to hide; consuming back")
        }
        // 收起键盘的那一次返回必须被消费：否则同一次返回还会被当成"再退一层"，
        // 键盘刚收起页面就跟着退掉。
        return true
    }

    private fun isImeVisible(decor: View): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val insets = decor.rootWindowInsets ?: return false
            return insets.isVisible(WindowInsets.Type.ime())
        }
        val visibleFrame = Rect()
        decor.getWindowVisibleDisplayFrame(visibleFrame)
        val hostHeight = decor.rootView.height
        if (hostHeight <= 0) return false
        return hostHeight - visibleFrame.bottom > hostHeight * IME_HEIGHT_FRACTION
    }

    /**
     * DEDUP-39：沉浸式全屏窗口形态。
     *
     * 对照 Qt/src/AndroidWindow.cpp:18 的 kWindowFlags（FLAG_FULLSCREEN |
     * FLAG_KEEP_SCREEN_ON）、:22 的 kImmersiveSticky，以及 :44-47 的
     * window.addFlags + decorView.setSystemUiVisibility。
     *
     * 与 Qt 的两点差异都是刻意的：
     *  1. 不搬 :38 的 setRequestedOrientation(kSensorLandscape)：DEDUP-39 bindingRuling
     *     要求竖屏响应式，方向锁会把竖屏 UI 拧成横屏。这里只有窗口形态，没有任何方向
     *     请求，Manifest 也不写 android:screenOrientation。
     *  2. API 30+ 走 WindowInsetsController（Qt 注释里承认这是官方推荐，只是它选了不分叉）。
     *     本卡按 SDK 分支，两条分支都不引第三方依赖。
     */
    private fun applyImmersiveSticky() {
        // Qt kWindowFlags 里的 KEEP_SCREEN_ON：播放页常亮属于窗口形态的一部分。
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            applyEdgeToEdgeImmersive()
        } else {
            applyLegacyImmersiveSticky()
        }
    }

    /** API 30+：WindowInsetsController 取代 systemUiVisibility（平台能力，无新依赖）。 */
    @Suppress("NewApi")
    private fun applyEdgeToEdgeImmersive() {
        window.setDecorFitsSystemWindows(false)
        val controller = window.insetsController ?: return
        controller.systemBarsBehavior =
            WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
    }

    /** API 28-29：legacy systemUiVisibility 的 IMMERSIVE_STICKY 组合。 */
    @Suppress("DEPRECATION")
    private fun applyLegacyImmersiveSticky() {
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        window.decorView.systemUiVisibility = IMMERSIVE_STICKY_FLAGS
    }

    private companion object {
        /**
         * API 29 及以下的 IME 高度启发式阈值。键盘高度在各类设备上都远大于 15%，
         * 而状态栏/导航栏的差值只有几个百分点，用比例而不是像素是为了不写死设备尺寸。
         */
        const val IME_HEIGHT_FRACTION = 0.15f

        /**
         * Qt/src/AndroidWindow.cpp:22 kImmersiveSticky 的逐位对应：
         * IMMERSIVE_STICKY | HIDE_NAVIGATION | FULLSCREEN | LAYOUT_STABLE |
         * LAYOUT_HIDE_NAVIGATION | LAYOUT_FULLSCREEN。
         */
        const val IMMERSIVE_STICKY_FLAGS: Int =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_FULLSCREEN
    }
}

/**
 * API 33+ 的返回回调登记器。
 *
 * 单独立类是为了把 OnBackInvokedCallback / OnBackInvokedDispatcher 这两个 API 33 类型
 * 收在一个 [Suppress] 作用域里：MainActivity 的字段只见得到本类，不给整个 Activity
 * 打 NewApi 抑制；本模块的依赖里也没有任何 androidx 构件（只用框架 API，
 * 同 MediaSessionHost.kt:320 的约定），所以不使用 androidx 的 @RequiresApi。
 *
 * 重复登记同一个实例是静默的"注销后重登"（OnBackInvokedDispatcher.java:100-102），
 * IllegalArgumentException 只在 priority 为负时抛（:103-104），所以这里的 catch 纯属
 * 防御。真失败时保持未注册：API 33+ 且 framework 开关打开时系统会走默认返回动作，
 * API 32- 仍回到 Activity.onBackPressed()——两条路都不崩，只是丢掉 IME/Qt 的 pre-hook。
 */
@Suppress("NewApi")
private class HostBackDispatcher(
    private val activity: FlutterActivity,
    private val onBack: () -> Unit,
) {
    private val callback = OnBackInvokedCallback { onBack() }
    private var registered = false

    fun install() {
        if (registered) return
        try {
            activity.onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                callback,
            )
            registered = true
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "host back callback not registered; falling back to Activity.onBackPressed", error)
        }
    }

    fun remove() {
        if (!registered) return
        registered = false
        try {
            activity.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback)
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "host back callback unregister rejected by the dispatcher", error)
        }
    }
}
