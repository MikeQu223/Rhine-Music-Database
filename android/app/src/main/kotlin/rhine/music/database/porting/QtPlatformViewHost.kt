package rhine.music.database.porting

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 本文件的日志标签。放在文件级而不是 object 里：QtPlatformView / QtHostRootView 是
 * 顶层类，引用不了 object 的私有成员，而这几处日志都要用同一个标签。
 */
private const val TAG = "QtPlatformViewHost"

/**
 * 进程单例所有权的纯 Kotlin 登记表（无 Android 依赖，便于 JVM 合同自检）。
 *
 * Qt 的嵌入路径在进程内只有一个 Qt 线程/一个 ApplicationState
 * （QtView.java:140-161 第一次构造时 loadQtLibraries + startQtApplication），
 * 所以第二个宿主视图必须被拒绝，而不是再加载一遍。
 */
internal class QtHostOwnershipRegistry {
    private var owner: Any? = null

    fun claim(candidate: Any): Boolean = synchronized(this) {
        if (owner != null && owner !== candidate) return false
        owner = candidate
        true
    }

    fun release(candidate: Any) {
        synchronized(this) {
            if (owner === candidate) owner = null
        }
    }

    fun current(): Any? = synchronized(this) { owner }
}

/**
 * 构造期的纯决策：这次实例是否应该去抢进程单例。
 *
 * 只对"参数合法 + probe ready + 有 Activity"的实例为真：被拒的第二个实例
 * 绝不能碰 MethodChannel/EventChannel，否则它会把第一个实例的 handler 换掉。
 * 通道安装另有 shouldInstallChannels() 判据（诊断实例允许在无 owner 时上报）。
 */
internal data class QtHostInitPlan(val claimRequested: Boolean)

internal fun planHostInit(
    probeVerdict: String?,
    argErrors: List<String>,
    activityPresent: Boolean,
): QtHostInitPlan = QtHostInitPlan(
    claimRequested = argErrors.isEmpty() && probeVerdict == "ready" && activityPresent,
)

/**
 * 通道 handler 的唯一安装判据（纯函数，便于 JVM 合同自检）。
 *
 * 共享 MethodChannel/EventChannel 只能有一个 handler：
 *  - 参数非法：不装；
 *  - 抢单例失败（已有 owner）：不装——"第二个实例不许换掉第一个"；
 *  - 构造失败：不装（所有权已释放，视图是死的）；
 *  - 抢到单例并构造成功：装；
 *  - 从未抢单例的诊断实例（probe 未 ready / 没有 Activity）：仅当进程里既没有 Qt owner、
 *    也没有别的通道 owner 时装，否则它会覆盖 owner 的 handler（且先装者的 dispose 会把
 *    后装者的通道拆掉）。诊断实例必须能上报，否则 archBlocked 的宿主在 Dart 侧只剩未知状态。
 */
internal fun shouldInstallChannels(
    argErrorsEmpty: Boolean,
    claimAttempted: Boolean,
    claimGranted: Boolean,
    constructionFailed: Boolean,
    anotherOwnerExists: Boolean,
    anotherChannelOwnerExists: Boolean,
): Boolean {
    if (!argErrorsEmpty) return false
    if (claimAttempted && !claimGranted) return false
    if (constructionFailed) return false
    if (claimGranted) return true
    // 诊断实例只在"既没有 Qt owner、也没有别的通道 owner"时上报。
    // 否则它会把前一个诊断/宿主实例的 handler 顶掉（dispose 时还会清掉别人的通道）。
    return !anotherOwnerExists && !anotherChannelOwnerExists
}

/**
 *  候选 A：真实的 Qt/Flutter 平台宿主端口（Android 侧）。
 *
 * 这份代码只做两件事，且都是真的：
 *   1. 用反射去问"本进程里到底有没有 Qt 的 Android 层"，把结果结构化报给 Dart；
 *   2. 只有在探针全绿时才用 QtQuickView 构造真 Qt 视图并挂进 Flutter 的
 *      PlatformView 容器；任何一条前置不满足都如实上报 archBlocked / deviceBlocked。
 *
 * 它**不会**在 Qt 缺失时创建一个"看起来像 Qt"的 View 去糊弄上层。未就绪时容器是空的
 * （透明、不绘制、contentDescription 明说不是 Qt 表面），由 Dart 侧渲染诊断面板。
 *
 * 为什么 QtActivity 不能直接塞进来（计划  第一条要求"证明"）：
 *   - android.app.Activity 是窗口宿主，不是 View；QtActivity 只在 Qt 自己的启动流程里成立。
 *   - Qt 官方给"把 Qt 塞进别人的 View 树"准备的是 QtQuickView（public，继承包内可见的
 *     QtView，两者都在 Qt 的 android jar 里）——见 QtView.java:19 / QtQuickView.java:27。
 *   - 也就是说这条路的可行形态是「QtQuickView 作为 PlatformView 的 child」，
 *     而不是「把 QtActivity 的窗口重父到 Flutter」。后者在 Android 上没有受支持的 API。
 *
 * Qt 侧证据（仓库内 third_party/qt 与 Qt 目录，行号为真实行号）：
 *   QtView.java:19          abstract class QtView extends ViewGroup implements QtNative.AppStateDetailsListener
 *   QtQuickView.java:27     public class QtQuickView extends QtView
 *   QtView.java:50-69       QtView(Context): registerAppStateListener + QtEmbeddedViewInterfaceFactory.create(context)
 *   QtView.java:54-66       addOnLayoutChangeListener → native resizeWindow(ref, left, top, w, h)
 *   QtView.java:77-84       appLibName 为空抛 InvalidParameterException
 *   QtView.java:140-161     getEmbeddedLoader() → loadQtLibraries() → startQtApplication()
 *   QtView.java:214-229     addQtWindow: MATCH_PARENT 插到 index 0，setWindowVisible(true)
 *   QtView.java:239-246     onAppStateDetailsChanged: !isStarted 时把视图从父容器摘掉
 *   QtEmbeddedDelegate.java:33-82   ActivityLifecycleCallbacks → setApplicationState(Active/Inactive/Suspended)
 *   QtLoader.java:73-76     baseContext 不是 Activity/Service 即抛 IllegalArgumentException
 *   QtLoader.java:93-102    initContextInfo: Activity 必须能在 PackageManager 里找到 ComponentInfo
 *   QtLoader.java:159       resolvePreferredAbi: 读 resources array "qt_libs"
 *   QtEmbeddedLoader.java:12-22  构造期就 extractContextMetaData(context)
 *   QtNative.java:224-229   ApplicationState { Suspended=0x0, Hidden=0x1, Inactive=0x2, Active=0x4 }
 *   Qt/src/AndroidWindow.cpp:16,18,22   kSensorLandscape=6 / kWindowFlags / kImmersiveSticky
 *   Qt/src/AndroidWindow.cpp:63-71      configureAndroidAccessibility：installUpdateHandler + setActive(false)
 *   Qt/src/AndroidWindow.cpp:73-119     configureAndroidWindow：media session + 窗口形状 + applicationStateChanged
 *
 * 冻结契约 v2 的观测面（宿主从 QtActivity 换成 FlutterActivity 后真正会变的那几条；行号同样是真实行号）：
 *   QtWindow.java:45-88    构造：setFocusableInTouchMode(true)、setImportantForAccessibility(NO)、
 *                          setVisible(false)（:61）；QtEditText 只在 context instanceof Activity 时创建（:63-71）
 *   QtWindow.java:90-150   registerSafeAreaMarginsListener：:92 的 instanceof QtActivityBase 闸门
 *   QtWindow.java:246-266  onTouchEvent：首次触摸才初始化 m_editText 焦点（:250-256）→ windowFocusChanged
 *                          → onEditTextChanged →
 *                          QtInputDelegate.sendTouchEvent(event, getId()) → m_gestureDetector.onTouchEvent
 *                          → return true。event 的坐标是 MotionEvent 相对本视图的**局部坐标**，
 *                          映射已由 Android 的 View 分发 + QtWindow 命中测试完成，宿主不得自算映射
 *   QtWindow.java:303-325  createSurface(surfaceContainerType==0 → QtSurface(SurfaceView)，否则 QtTextureView)，
 *                          MATCH_PARENT，addView(container, 0)
 *   QtWindow.java:338-345  setGeometry 仅当 getContext() instanceof QtActivityBase 才 setLayoutParams
 *                          → Flutter 宿主（MainActivity extends FlutterActivity）里这条被丢弃
 *   QtView.java:54-66      addOnLayoutChangeListener → native resizeWindow(ref, left, top, w, h)
 *                          → Flutter 宿主里 resize 的唯一真实通路
 *   QtInputDelegate.java:654-708  sendTouchEvent(MotionEvent, int id)（包内可见，宿主不可调）
 *   QtInputDelegate.java:214-240  showSoftwareKeyboard(...)：IME 入口，由 Qt C++ 经 QtInputInterface 调
 *   QtInputDelegate.java:104-133  initInputMethodManager
 *   QtEditText.java:24 / :111-133 QtEditText extends View / onCreateInputConnection（IME 的 Android 端）
 *   QtActivityDelegateBase.java:83-104  initMembers 读 ActivityInfo.softInputMode → setSoftInputMode
 *   QtSurface.java:14 / :18-28    QtSurface extends SurfaceView / setZOrderMediaOverlay + holder.setFormat
 *   QtTextureView.java:14 / :20-29 QtTextureView extends TextureView / setSurfaceTextureListener + setSurfaceTexture
 *   QtEmbeddedDelegate.java:33-82  registerActivityLifecycleCallbacks 自己驱动 Qt application state
 *   Flutter SDK platform_views.dart:131-133  initAndroidView 默认走 TLHC/纹理合成
 *   Flutter SDK platform_views.dart:193-194  initExpensiveAndroidView 强制 Hybrid Composition
 */
object QtPlatformViewHost {

    /**
     * back 询问的兜底时限。平台通道的回复是异步的：engine 已 detach 或
     * Dart 侧正卡在别处时可能永远不回，而返回键不能一直悬着，超时即按"未认领"回落。
     */
    const val BACK_VERB_TIMEOUT_MS = 250L

    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    /** 必须与 lib/platform/qt_platform_view.dart 的 qtPlatformViewType 逐字相同。 */
    const val VIEW_TYPE = "rhine.music.database.porting/qt_platform_view"

    const val CONTROL_CHANNEL = "rhine.music.database/qt_platform_view/control"
    const val EVENT_CHANNEL = "rhine.music.database/qt_platform_view/events"

    /**
     * 出站 back verb 的方法名，与 hostStatus / surfaceSize 同一套控制通道协议：
     * 宿主 Activity 的返回路由在 IME 之后调用 [dispatchBackVerb]，把"这次返回是否属于
     * Qt 视图"作为一次**询问**发给 Dart 侧，由 Dart 决定送进 Qt 输入层并显式回 true 认领；
     * 只回 null/false/error 或干脆不回，都算未认领，Activity 会回落 Flutter 默认返回。
     *
     * 为什么不是合成 KeyEvent：Qt 的返回处理在 QtInputDelegate.onKeyDown
     * （QtInputDelegate.java:503、:524、:544），类包内可见、宿主不可调；
     * QtWindow.java 又不处理任何按键（无 onKeyDown/onKeyUp/dispatchKeyEvent），
     * 合成 KEYCODE_BACK 派发进 Qt 视图树到不了 QtInputDelegate。
     */
    const val METHOD_BACK = "back"

    // —— 冻结契约 v2：8 个新探针 key（必须与 Dart QtProbeKeys 同名常量逐字相同）——
    // 前三个是**观测类**（必须由真实视图树扫描得出），后五个是**静态词表类**（答案只取决于 Qt 源）。
    const val PROBE_QT_WINDOW_ATTACHED = "qtWindowAttached"
    const val PROBE_SURFACE_CONTAINER_KIND = "surfaceContainerKind"
    const val PROBE_VIEW_COMPOSITION_REQUIRED = "viewCompositionRequired"
    const val PROBE_TOUCH_PASSTHROUGH = "touchPassthrough"
    const val PROBE_IME_OWNER = "imeOwner"
    const val PROBE_RESIZE_OWNER = "resizeOwner"
    const val PROBE_SAFE_AREA_OWNER = "safeAreaOwner"
    const val PROBE_ACTIVITY_IS_QT_ACTIVITY_BASE = "activityIsQtActivityBase"

    // —— 冻结契约 v2：词表常量（两侧同一批字符串，不得改写）——
    const val SURFACE_SURFACE_VIEW = "surface-view"
    const val SURFACE_TEXTURE_VIEW = "texture-view"
    const val SURFACE_NONE = "none"
    const val SURFACE_UNKNOWN = "unknown"
    const val IME_OWNER_QT = "qt-input-delegate"
    const val RESIZE_OWNER_QTVIEW = "qtview-layout-listener"
    const val SAFE_AREA_OWNER_QTWINDOW = "qtwindow-safe-area-listener"
    const val SAFE_AREA_OWNER_UNAVAILABLE = "unavailable-no-qactivitybase"

    // —— Qt 侧的类全名：probeQtSubtree 只做字符串比较，不做成员反射 ——
    // QtWindow.java:28  class QtWindow extends QtLayout implements QtSurfaceInterface
    // QtSurface.java:14 class QtSurface extends SurfaceView
    // QtTextureView.java:14 class QtTextureView extends TextureView
    // QtActivityBase.java:30 public class QtActivityBase extends Activity
    const val QT_WINDOW_CLASS = "org.qtproject.qt.android.QtWindow"
    const val QT_SURFACE_CLASS = "org.qtproject.qt.android.QtSurface"
    const val QT_TEXTURE_VIEW_CLASS = "org.qtproject.qt.android.QtTextureView"
    const val QT_ACTIVITY_BASE_CLASS = "org.qtproject.qt.android.QtActivityBase"

    /** 子树扫描深度上限（契约 (6)：≤8）。 */
    const val MAX_SUBTREE_DEPTH = 8

    /** 诊断 key：证明扫描是真跑过的（Dart 不读，只进切片报告）。 */
    const val PROBE_SUBTREE_SCANNED = "qtSubtreeScannedNodes"
    const val PROBE_SUBTREE_DEPTH_LIMITED = "qtSubtreeDepthLimited"

    const val KEY_QUICK_VIEW = "QtQuickView"
    const val KEY_QT_VIEW = "QtView"
    const val KEY_QT_NATIVE = "QtNative"
    const val KEY_EMBEDDED_FACTORY = "QtEmbeddedViewInterfaceFactory"
    const val KEY_EMBEDDED_DELEGATE = "QtEmbeddedDelegate"
    const val KEY_QT_LOADER = "QtLoader"
    const val KEY_QT_APPLICATION = "QtApplication"

    /** Qt 的 Android 类（全限定名）。探针逐个 Class.forName 检查。 */
    val QT_CLASSES: Map<String, String> = linkedMapOf(
        KEY_QUICK_VIEW to "org.qtproject.qt.android.QtQuickView",
        KEY_QT_VIEW to "org.qtproject.qt.android.QtView",
        KEY_QT_NATIVE to "org.qtproject.qt.android.QtNative",
        KEY_EMBEDDED_FACTORY to "org.qtproject.qt.android.QtEmbeddedViewInterfaceFactory",
        KEY_EMBEDDED_DELEGATE to "org.qtproject.qt.android.QtEmbeddedDelegate",
        KEY_QT_LOADER to "org.qtproject.qt.android.QtLoader",
        KEY_QT_APPLICATION to "org.qtproject.qt.android.bindings.QtApplication",
    )

    /** androiddeployqt 生成的 Qt 库清单资源名（QtLoader.java:369-377、:159）。 */
    const val RES_QT_LIBS_ARRAY = "qt_libs"

    /** Qt 侧唯一的库加载总闸：不是 "1" 就直接 Failed（QtLoader.java:379-387、:466-469）。 */
    const val RES_USE_LOCAL_QT_LIBS = "use_local_qt_libs"

    /**
     * Qt 会读的宿主 meta-data，但**不是**硬前置：
     *   - lib_name 只在 m_mainLibName == null 时回退读取（QtLoader.java:524-525），而
     *     QtView.loadQtLibraries 先用构造器参数 setMainLibraryName(appLibName)（QtView.java:150），
     *     所以 QtQuickView 路径不依赖它；
     *   - arguments 由 QtLoader.java:118 读，缺省时 appendApplicationParameters 直接返回
     *     （QtLoader.java:242-245）。
     */
    const val META_LIB_NAME = "android.app.lib_name"
    const val META_ARGUMENTS = "android.app.arguments"

    /**
     * 当前活跃的宿主视图。Qt 的嵌入路径在进程内是单例：
     * QtView.java:140-161 第一次构造时加载 Qt 库并 startQtApplication()，
     * QtNative 里只有一个 Qt 线程/一个 ApplicationState。
     * 因此第二个 PlatformView 必须被拒，而不是悄悄再加载一遍。
     */
    private val ownership = QtHostOwnershipRegistry()

    internal fun claimActiveView(view: QtPlatformView): Boolean = ownership.claim(view)

    internal fun releaseActiveView(view: QtPlatformView) {
        ownership.release(view)
    }

    internal fun hasActiveView(): Boolean = ownership.current() != null

    /**
     * 通道（MethodChannel/EventChannel）是第二份共享资源，跟 Qt 单例所有权分开记：
     *  - 合法 owner 构造成功后可以直接接管通道（把先前诊断实例的 handler 换掉）；
     *  - 诊断实例只在没有任何通道 owner 时装 handler，避免互相顶掉；
     *  - dispose 只允许**当前**通道 owner 清 handler，否则一个早已被接管的诊断实例
     *    会在析构时把后来合法实例的通道拆掉（同一类泄漏）。
     */
    private var channelOwner: QtPlatformView? = null

    internal fun claimChannels(view: QtPlatformView) {
        synchronized(this) { channelOwner = view }
    }

    internal fun releaseChannels(view: QtPlatformView) {
        synchronized(this) {
            if (channelOwner === view) channelOwner = null
        }
    }

    internal fun ownsChannels(view: QtPlatformView): Boolean =
        synchronized(this) { channelOwner === view }

    internal fun hasChannelOwner(): Boolean = synchronized(this) { channelOwner != null }

    /**
     * 宿主 Activity 的返回键入口：向当前通道归属的宿主视图发一次"back 询问"。
     *
     * [onResult] 保证在主线程上**恰好被调用一次**，且 true 只代表一件事：对面明确认领了
     * 这次返回（Dart 侧回了 Boolean true）。false 的每种来源都意味着"这次返回不属于 Qt"，
     * Activity 必须随即回落 Flutter 默认返回，绝不能在这里吞掉返回键：
     *  - 没有通道归属者（没有合法视图，或 dispose 已经交还通道 / engine 已 detach）；
     *  - 归属者的 Qt 视图没建起来（被拒、构造失败），或探针 verdict 还不是 ready；
     *  - 对面回了 null / false / error / 通道未实现；
     *  - [BACK_VERB_TIMEOUT_MS] 内没有回复。
     *
     * 为什么需要认领协议：Dart 侧对没有 handler 的方法回的是"成功 + null"，平台通道不会
     * 抛错也不会走 notImplemented，因此"调用没抛异常"不能当成"已被处理"。只有显式 true
     * 才算消费；否则宁可回落 Flutter，也不能让返回键静默失效。
     */
    internal fun dispatchBackVerb(onResult: (Boolean) -> Unit) {
        val owner = synchronized(this) { channelOwner }
        if (owner == null) {
            onResult(false)
            return
        }

        // 一次性闸门：超时与回复谁先到谁生效，后到的一方被丢弃，保证 onResult 只跑一次。
        val settled = AtomicBoolean(false)
        val timeout = Runnable {
            if (settled.compareAndSet(false, true)) {
                Log.w(TAG, "back verb unclaimed after ${BACK_VERB_TIMEOUT_MS}ms")
                onResult(false)
            }
        }
        mainHandler.postDelayed(timeout, BACK_VERB_TIMEOUT_MS)
        owner.forwardBackVerb { claimed ->
            if (settled.compareAndSet(false, true)) {
                mainHandler.removeCallbacks(timeout)
                onResult(claimed)
            }
        }
    }

    /**
     * 把一个 Context 剥到 Activity。
     *
     * 必要性：QtLoader 的构造器要求 ContextWrapper.getBaseContext() 是 Activity 或 Service
     * （QtLoader.java:73-76），否则抛 IllegalArgumentException；而 Flutter 交给
     * PlatformViewFactory 的 Context 通常是 ContextThemeWrapper / MutableContextWrapper，
     * 直接透传必然踩这条。剥壳是适配器的真实工作，不是包装。
     */
    fun unwrapActivity(context: Context?): Activity? {
        var cursor: Context? = context
        var guard = 0
        while (cursor != null && guard < 16) {
            if (cursor is Activity) return cursor
            cursor = if (cursor is ContextWrapper) cursor.baseContext else null
            guard++
        }
        return null
    }

    private fun classPresent(name: String, context: Context): Boolean = try {
        Class.forName(name, false, context.classLoader)
        true
    } catch (_: Throwable) {
        false
    }

    /** 宿主 Activity 的 manifest 里有没有 android.app.lib_name（QtLoader.java:524-525；android.app.arguments 未查）；仅上报，不参与裁决。 */
    private fun hostMetaDataPresent(activity: Activity?): Boolean {
        if (activity == null) return false
        return try {
            val info = activity.packageManager.getActivityInfo(
                activity.componentName,
                PackageManager.GET_META_DATA,
            )
            val meta = info.metaData ?: return false
            meta.containsKey(META_LIB_NAME)
        } catch (_: Throwable) {
            false
        }
    }

    /** jniLibs 里有没有 Qt 的 native 库：没有它连 QtNative 都起不来。 */
    private fun nativeQtLibsPresent(context: Context): Boolean = try {
        val dir = context.applicationInfo.nativeLibraryDir ?: return false
        java.io.File(dir).listFiles()?.any { it.name.contains("Qt6Core") } == true
    } catch (_: Throwable) {
        false
    }

    /**
     * 结构化探针。返回 Map 直接喂给 Dart 的 QtHostStatus.fromMap。
     * 判定顺序即依赖顺序：类 → 资源 → Activity → native 库；meta-data 只作观测值一并上报，
     * 不参与 verdict（QtView.java:150 先设 mainLibName，QtLoader.java:524-525 只是回退）。
     */
    fun probe(context: Context): MutableMap<String, Any?> {
        val classes = LinkedHashMap<String, Boolean>()
        val missing = ArrayList<String>()
        for ((key, name) in QT_CLASSES) {
            val present = classPresent(name, context)
            classes[key] = present
            if (!present) missing.add(name)
        }

        val activity = unwrapActivity(context)
        val qtLibsArray = try {
            context.resources.getIdentifier(RES_QT_LIBS_ARRAY, "array", context.packageName) != 0
        } catch (_: Throwable) {
            false
        }
        val localQtLibs = try {
            val id = context.resources.getIdentifier(
                RES_USE_LOCAL_QT_LIBS,
                "string",
                context.packageName,
            )
            id != 0 && context.resources.getString(id).toIntOrNull() == 1
        } catch (_: Throwable) {
            false
        }
        val metaData = hostMetaDataPresent(activity)
        val nativeLibs = nativeQtLibsPresent(context)
        val qtActivityBase = contextIsQtActivityBase(context)

        val reasons = ArrayList<String>()
        if (missing.isNotEmpty()) reasons.add("missing Qt android classes: " + missing.joinToString())
        if (!qtLibsArray) reasons.add("missing resources array \"qt_libs\" (androiddeployqt)")
        if (!localQtLibs) reasons.add("resources string \"use_local_qt_libs\" is not 1")
        if (activity == null) reasons.add("context is not an Activity")
        if (!nativeLibs) reasons.add("no Qt native libraries in nativeLibraryDir")

        val verdict = when {
            missing.isNotEmpty() || !qtLibsArray || !localQtLibs || activity == null -> "archBlocked"
            !nativeLibs -> "deviceBlocked"
            else -> "ready"
        }

        return linkedMapOf(
            "verdict" to verdict,
            "reason" to if (reasons.isEmpty()) {
                "all Qt embedding preconditions satisfied"
            } else {
                reasons.joinToString("; ")
            },
            "missing" to missing,
            "qtClassesPresent" to classes,
            "qtLibsArrayPresent" to qtLibsArray,
            "hostMetaDataPresent" to metaData,
            "nativeQtLibsPresent" to nativeLibs,
            "activityContextUsable" to (activity != null),
            // 三个"谁负责"的答案都有 Qt 源证据（字面量，Qt 升级需同步），见文件头注释。
            "surfaceOwner" to "QtQuickView/QtView.addQtWindow (index 0, MATCH_PARENT)",
            "inputOwner" to "QtQuickView 自身触摸路径 (Flutter EagerGestureRecognizer 全量交出)",
            "lifecycleOwner" to "QtEmbeddedDelegate (Application.ActivityLifecycleCallbacks)",
            // —— 冻结契约 v2：8 个新 key ——
            // 观测类：probe(context) 阶段还没有宿主视图树，给缺省值（不是"测过了"）。
            // QtPlatformView 的 init/refreshProbe 会用 probeQtSubtree(root) 的真实扫描结果覆盖。
            PROBE_QT_WINDOW_ATTACHED to false,
            PROBE_SURFACE_CONTAINER_KIND to SURFACE_UNKNOWN,
            PROBE_VIEW_COMPOSITION_REQUIRED to false,
            // 静态词表类：答案只取决于 Qt 源与宿主 Activity 类型，照实填。
            // touchPassthrough=true：QtHostRootView.onInterceptTouchEvent 恒 false +
            // dispatchTouchEvent 原样 super 转发（见该类注释与 QtWindow.java:246-266）。
            PROBE_TOUCH_PASSTHROUGH to true,
            // imeOwner：软键盘唯一入口是 Qt C++ → QtInputInterface(=QtInputDelegate)
            // （QtInputDelegate.java:214-240 / QtEditText.java:111-133），宿主不驱动。
            PROBE_IME_OWNER to IME_OWNER_QT,
            // resizeOwner：QtWindow.setGeometry 被 QtActivityBase 闸门挡住（QtWindow.java:338-345），
            // 真实 resize 只发生在 QtView 的 OnLayoutChangeListener（QtView.java:54-66）。
            PROBE_RESIZE_OWNER to RESIZE_OWNER_QTVIEW,
            // safeAreaOwner：同一道 instanceof 闸门（QtWindow.java:92）。
            PROBE_SAFE_AREA_OWNER to if (qtActivityBase) {
                SAFE_AREA_OWNER_QTWINDOW
            } else {
                SAFE_AREA_OWNER_UNAVAILABLE
            },
            PROBE_ACTIVITY_IS_QT_ACTIVITY_BASE to qtActivityBase,
            "archNotes" to archNotes(),
        )
    }

    /**
     * 传给 QtQuickView 的 Context 是不是 org.qtproject.qt.android.QtActivityBase。
     *
     * Flutter 宿主永远是 false（MainActivity extends FlutterActivity），而这一条不是"元数据"，
     * 它直接决定三个观测面的真实归属：
     *   1. resize：QtWindow.setGeometry 里的 setLayoutParams 被
     *      `if (getContext() instanceof QtActivityBase)` 挡住（QtWindow.java:338-345）→ 被丢弃；
     *      真正生效的是 QtView 构造期注册的 addOnLayoutChangeListener（QtView.java:54-66）→
     *      resizeOwner='qtview-layout-listener'，宿主只提供真实尺寸，不自己算窗口几何。
     *   2. safe area：QtWindow.registerSafeAreaMarginsListener 有同一道闸门（QtWindow.java:92）→
     *      safeAreaOwner='unavailable-no-qactivitybase'，宿主不得假装拿到了 Qt 的边距。
     *   3. 窗口形状/无障碍/媒体会话：全部由 Qt 的 QtActivity 侧驱动
     *      （Qt/src/AndroidWindow.cpp:73-119），Flutter 宿主不会自动继承。
     *
     * 用类名逐级比较而不是 instanceof：Qt 的 android jar 不在本工程 classpath 上，
     * 直接 instanceof 会编译不过；而反射成员会静默失败，所以只比较 Class.getName()。
     */
    fun contextIsQtActivityBase(context: Context?): Boolean {
        val activity = unwrapActivity(context) ?: return false
        var clazz: Class<*>? = activity.javaClass
        var guard = 0
        while (clazz != null && guard < 16) {
            if (clazz.name == QT_ACTIVITY_BASE_CLASS) return true
            clazz = clazz.superclass
            guard++
        }
        return false
    }

    /**
     * 观测类字段的缺省值：只在"根本没有可扫描的宿主观测面"时使用（archBlocked / deviceBlocked /
     * root == null）。语义是"没有观测过"，不是"观测到了没有 Qt 表面"——后者由
     * probeQtSubtree(root) 扫描真实视图树后给出 'none'。
     *
     * 取值与冻结契约 (4) 里 Dart QtHostStatus.fromMap 的缺省一致：
     * false / 'unknown' / false，这样"平台侧没观测"和"平台侧没上报"在 Dart 侧是同一个状态，
     * 不会出现一边 'unknown' 一边 'none' 的对账噪音。
     */
    fun observationDefaults(): MutableMap<String, Any?> = linkedMapOf(
        PROBE_QT_WINDOW_ATTACHED to false,
        PROBE_SURFACE_CONTAINER_KIND to SURFACE_UNKNOWN,
        PROBE_VIEW_COMPOSITION_REQUIRED to false,
    )

    /**
     * 真实子树观测（冻结契约 (6)）：把宿主 View 树按 Class.getName() 分类，得出 Qt 表面到底是什么。
     *
     * 为什么必须扫真实视图树而不是读探针常量：Qt 的 surface 容器是 QtWindow 在 Qt 线程里
     * 通过 runAction 加进来的（QtWindow.java:303-325），只有在 QtQuickView 真的挂上、Qt 应用真的
     * 起来之后才存在。常量只能证明"代码里可能会创建"，扫树才能证明"这一次真的创建了"。
     *
     * 分类规则：
     *   org.qtproject.qt.android.QtWindow      → qtWindowAttached = true
     *   …QtSurface                             → surfaceContainerKind = "surface-view"
     *   …QtTextureView                         → surfaceContainerKind = "texture-view"
     *   两者都没扫到                            → "none"
     *   扫描过程抛异常                          → "unknown"（Qt 侧容器类型不可判定，不许猜）
     *
     * viewCompositionRequired 由 surfaceContainerKind 派生（契约 (3)）：
     *   == "surface-view" → true。理由：QtSurface 是 SurfaceView（QtSurface.java:14），它有自己的
     *   Surface，Flutter 默认的 AndroidView 走 TLHC/纹理合成（platform_views.dart:131-133）拿不到它；
     *   必须走 initExpensiveAndroidView 的 Hybrid Composition（platform_views.dart:193-194）。
     *
     * 只做类名字符串比较，不做成员反射：Qt 的 android jar 不在本工程 classpath 上。
     */
    fun probeQtSubtree(root: View?): MutableMap<String, Any?> {
        // root == null：没有视图树可扫 → 报"未观测"（'unknown'），不是"扫过、没有"（'none'）。
        if (root == null) return observationDefaults()
        var qtWindowAttached = false
        var sawSurfaceView = false
        var sawTextureView = false
        var scanned = 0
        var depthLimited = false
        return try {
            val queue = ArrayDeque<Pair<View, Int>>()
            queue.addLast(root to 0)
            while (queue.isNotEmpty()) {
                val (view, depth) = queue.removeFirst()
                scanned++
                when (view.javaClass.name) {
                    QT_WINDOW_CLASS -> qtWindowAttached = true
                    QT_SURFACE_CLASS -> sawSurfaceView = true
                    QT_TEXTURE_VIEW_CLASS -> sawTextureView = true
                }
                if (depth >= MAX_SUBTREE_DEPTH) {
                    if (view is android.view.ViewGroup && view.childCount > 0) depthLimited = true
                    continue
                }
                if (view is android.view.ViewGroup) {
                    for (index in 0 until view.childCount) {
                        val child = view.getChildAt(index) ?: continue
                        queue.addLast(child to depth + 1)
                    }
                }
            }
            // 同时持有两种容器时按更严格的那条上报（SurfaceView 需要 view composition）。
            val kind = when {
                sawSurfaceView -> SURFACE_SURFACE_VIEW
                sawTextureView -> SURFACE_TEXTURE_VIEW
                else -> SURFACE_NONE
            }
            linkedMapOf(
                PROBE_QT_WINDOW_ATTACHED to qtWindowAttached,
                PROBE_SURFACE_CONTAINER_KIND to kind,
                PROBE_VIEW_COMPOSITION_REQUIRED to (kind == SURFACE_SURFACE_VIEW),
                PROBE_SUBTREE_SCANNED to scanned,
                PROBE_SUBTREE_DEPTH_LIMITED to depthLimited,
            )
        } catch (_: Throwable) {
            linkedMapOf(
                PROBE_QT_WINDOW_ATTACHED to false,
                PROBE_SURFACE_CONTAINER_KIND to SURFACE_UNKNOWN,
                PROBE_VIEW_COMPOSITION_REQUIRED to false,
                PROBE_SUBTREE_SCANNED to scanned,
                PROBE_SUBTREE_DEPTH_LIMITED to depthLimited,
            )
        }
    }

    /** 写进状态里的架构备注：每条都对应一行 Qt 源，方便 review 逐条对账。 */
    fun archNotes(): List<String> = listOf(
        "QtActivity 不能作为普通 View 嵌入：它是 Activity 窗口宿主；可行形态是 " +
            "QtQuickView 作为 PlatformView 的 child（QtView.java:19、QtQuickView.java:27）。",
        "QtView 是包内可见（QtView.java:19 无 public 修饰），外部应用只能实例化其 public 子类 " +
            "QtQuickView（QtQuickView.java:27）。",
        "Context 必须是 Activity：QtLoader 构造器否则抛 IllegalArgumentException（QtLoader.java:73-76），" +
            "QtView.loadQtLibraries 捕获后放弃启动（QtView.java:144-148），视图会建出来但 Qt 起不来。",
        "宿主 meta-data 不是 QtQuickView 路径的硬前置：QtView.loadQtLibraries 先用构造器参数 " +
            "setMainLibraryName(appLibName)（QtView.java:150），QtLoader 仅在 m_mainLibName == null 时" +
            "回退读 android.app.lib_name（QtLoader.java:524-525）；android.app.arguments 可空" +
            "（QtLoader.java:118 → :242-245 提前返回）。",
        "applicationParameters 当前没有注入通道（exactGap）：QtQuickView 只接受 " +
            "(Context, qmlUri, appName[, qmlImportPaths])（QtQuickView.java:59-89），Qt 的应用参数只从 " +
            "manifest meta-data android.app.arguments（QtLoader.java:118）或 debuggable 的 intent extra " +
            "\"applicationArguments\"（QtLoader.java:120-126）读取；Flutter 宿主两条都没接。",
        "库加载总闸是 resources string \"use_local_qt_libs\" 解析为 1（QtLoader.java:379-387、:466-469），" +
            "否则 loadQtLibraries 直接 Failed；库清单来自 androiddeployqt 生成的 array \"qt_libs\"" +
            "（QtLoader.java:369-377，缺失被容忍为空表；:192-194 另有主 ABI 回退），空表意味着 Qt 自身的 .so " +
            "不会被 System.load，随后 loadMainLibrary（QtLoader.java:533-536）必失败 → 仍按 archBlocked 上报，" +
            "理由是缺 androiddeployqt 产物而不是 Qt 的缺陷。",
        "生命周期由 Qt 自己驱动（QtEmbeddedDelegate.java:33-82 ActivityLifecycleCallbacks），" +
            "宿主重复驱动会造成双写；Flutter 侧只做观测对账。",
        "QtQuickView 构造即加载 Qt 库并启动 Qt 应用（QtView.java:140-161），" +
            "进程内单例；第二个宿主视图必须被拒绝。",
        "窗口形状（横屏/全屏/沉浸式）原先由 QtActivity 侧下发（Qt/src/AndroidWindow.cpp:16,18,22）；" +
            "换 Flutter 宿主后不能再由 Qt 抢窗口，需由 Flutter 侧对齐或用 Flutter 的系统 UI 模式。",
        "Qt 无障碍桥默认关闭（Qt/src/AndroidWindow.cpp:63-71：installUpdateHandler + setActive(false)，" +
            "前台滑动 ANR 兜底），QtWindow 自身也设 IMPORTANT_FOR_ACCESSIBILITY_NO（QtWindow.java:54）；" +
            "宿主不得调用任何无障碍 API、不得开启/改写无障碍桥。",
        "Flutter 宿主最小适配面（换宿主的代价，不是 Qt 的缺陷）：" +
            "activityIsQtActivityBase=false（MainActivity extends FlutterActivity）→ " +
            "QtWindow.setGeometry 的 setLayoutParams 被 instanceof 闸门丢弃（QtWindow.java:338-345），" +
            "resize 只能靠 QtView 自己的 addOnLayoutChangeListener（QtView.java:54-66）→ " +
            "resizeOwner='qtview-layout-listener'，宿主只提供真实尺寸、不自己算窗口几何。",
        "safeAreaOwner='unavailable-no-qactivitybase'：QtWindow.registerSafeAreaMarginsListener 有同一道 " +
            "QtActivityBase 闸门（QtWindow.java:92），Flutter 宿主拿不到 Qt 的 safe area 边距，" +
            "不得假装拿到了。",
        "imeOwner='qt-input-delegate'：软键盘由 Qt C++ 侧经 QtInputInterface(=QtInputDelegate) 驱动 " +
            "（QtInputDelegate.java:214-240 showSoftwareKeyboard、QtInputDelegate.java:104-133 " +
            "initInputMethodManager、QtEditText.java:111-133 onCreateInputConnection）；" +
            "宿主不得自行 show/hide 键盘、不得抢设 windowSoftInputMode " +
            "（QtActivityDelegateBase.java:83-104 从 ActivityInfo.softInputMode 读）。",
        "surface：QtWindow.createSurface 在 surfaceContainerType==0 时 new QtSurface（SurfaceView），" +
            "否则 new QtTextureView（QtWindow.java:303-325；QtSurface.java:14、QtTextureView.java:14）。" +
            "Flutter 默认 AndroidView 走 TLHC/纹理合成（platform_views.dart:131-133），SurfaceView 合成不了 → " +
            "surfaceContainerKind=='surface-view' 时 viewCompositionRequired=true，必须用 " +
            "initExpensiveAndroidView 的 Hybrid Composition（platform_views.dart:193-194）。",
        "touch：坐标由 Android View 分发、QtWindow.onTouchEvent 用局部坐标直接调 " +
            "QtInputDelegate.sendTouchEvent(event, getId())（QtWindow.java:246-266）；" +
            "宿主 onInterceptTouchEvent 恒 false、dispatchTouchEvent 原样 super 转发 → touchPassthrough=true；" +
            "宿主不得自算映射，也不得消费事件。",
        "生命周期：QtEmbeddedDelegate 自己 registerActivityLifecycleCallbacks 驱动 Qt application state " +
            "（QtEmbeddedDelegate.java:33-82）；宿主只观测（flutterLifecycle 仅记录），不得双写。",
        "hosting owner：本 atom 不注册 PlatformViewFactory、不改 MainActivity；" +
            "接线归 T16，registerWith 仅作为 patch 建议保留（候选隔离）。",
    )

    /**
     * 反射构造真的 QtQuickView。
     *
     * 用反射而不是编译期依赖：Qt 的 android jar 不在本 Flutter 工程的 classpath 上
     * （本切片也没有把它加进 gradle）。反射让"缺 Qt"变成一条可读的状态，
     * 而不是整个模块编译不过——后者会逼出"先写个占位 View 让它能编"的假实现。
     */
    fun instantiateQtQuickView(activity: Activity, args: QtPlatformViewArgs): Result<View> = runCatching {
        val clazz = Class.forName(QT_CLASSES.getValue(KEY_QUICK_VIEW), true, activity.classLoader)
        val view: View = if (args.qmlImportPaths.isEmpty()) {
            clazz.getConstructor(Context::class.java, String::class.java, String::class.java)
                .newInstance(activity, args.qmlUri, args.qtAppLibraryName) as View
        } else {
            clazz.getConstructor(
                Context::class.java,
                String::class.java,
                String::class.java,
                Array<String>::class.java,
            ).newInstance(
                activity,
                args.qmlUri,
                args.qtAppLibraryName,
                args.qmlImportPaths.toTypedArray(),
            ) as View
        }
        view
    }

    /** 平台视图工厂。装配（注册进 FlutterEngine）由宿主 owner 在接线时做，本文件不调。 */
    fun createFactory(messenger: BinaryMessenger): PlatformViewFactory =
        QtPlatformViewFactory(messenger)

    /**
     * 装配入口（候选隔离，**本文件不调用**）。
     *
     * MainActivity / FlutterEngine 的注册属宿主接线，不在本文件的改动范围里（MainActivity.kt 是共享文件，
     * 这里只读）。这里保留实现是为了给宿主侧一份可直接落地的 patch 建议：
     *
     *   engine.platformViewsController.registry.registerViewFactory(
     *       QtPlatformViewHost.VIEW_TYPE,
     *       QtPlatformViewHost.createFactory(engine.dartExecutor.binaryMessenger),
     *   )
     *
     * 注意两条真实约束：
     *   1. 只在 FlutterActivity 的 `configureFlutterEngine`（或等价 engine 已就绪处）调用，
     *      而不是 Application.onCreate 里（那时 engine 还没起来）；
     *   2. 注册本身**不**证明 Qt 可用：verdict 仍由 probe()/probeQtSubtree() 的真实观测决定，
     *      注册只是让 PlatformView 的创建请求能被路由到 QtPlatformViewFactory。
     */
    fun registerWith(engine: FlutterEngine) {
        engine.platformViewsController.registry.registerViewFactory(
            VIEW_TYPE,
            createFactory(engine.dartExecutor.binaryMessenger),
        )
        Log.i(TAG, "registered platform view factory for $VIEW_TYPE")
    }
}

/** Dart 侧 creationParams 的强类型视图。 */
data class QtPlatformViewArgs(
    val qmlUri: String,
    val qtAppLibraryName: String,
    val qmlImportPaths: List<String>,
    val applicationParameters: String,
) {
    companion object {
        fun from(raw: Any?): QtPlatformViewArgs {
            val map = raw as? Map<*, *> ?: return QtPlatformViewArgs("", "", emptyList(), "")
            val imports = (map["qmlImportPaths"] as? List<*>)
                ?.mapNotNull { it as? String }
                ?: emptyList()
            return QtPlatformViewArgs(
                qmlUri = map["qmlUri"] as? String ?: "",
                qtAppLibraryName = map["qtAppLibraryName"] as? String ?: "",
                qmlImportPaths = imports,
                applicationParameters = map["applicationParameters"] as? String ?: "",
            )
        }
    }

    /** 与 Dart 侧 validate() 同源：复刻 Qt 自己的构造器检查（QtQuickView.java:83-86）。 */
    fun validationErrors(): List<String> {
        val errors = ArrayList<String>()
        if (qmlUri.isBlank()) errors.add("argument 'qmlUri' may not be empty or null")
        if (qtAppLibraryName.isBlank()) errors.add("argument 'appLibName' may not be empty or null")
        if (qmlImportPaths.any { it.isBlank() }) errors.add("qmlImportPaths contains an empty entry")
        return errors
    }
}

class QtPlatformViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        QtPlatformView(context, messenger, viewId, QtPlatformViewArgs.from(args))
}

/**
 * Flutter PlatformView 的真实实现。
 *
 * getView() 返回的容器在未就绪时是**空的**：没有 Qt 画面、没有替身贴图。
 * 输入事件由 Flutter 的 EagerGestureRecognizer 全量交出后落到这里，
 * 就绪时继续向下派发给 QtQuickView（Qt 自己的触摸路径）——QtHostRootView 不拦截、不消费。
 *
 * 状态面（冻结契约 v2）：除既有 verdict/reason/missing/ownership 之外，还带 8 个新 key，
 * 其中 qtWindowAttached / surfaceContainerKind / viewCompositionRequired 由 probeQtSubtree(root)
 * 对**真实视图树**扫描得出（不是常量），每次 refreshProbe 重扫一次。
 * viewCompositionRequired=true 时 Dart 侧必须改用 initExpensiveAndroidView
 * （QtSurface 是 SurfaceView，默认 TLHC/纹理合成拿不到它的像素；platform_views.dart:131-133 vs 193-194）。
 */
class QtPlatformView(
    private val context: Context,
    messenger: BinaryMessenger,
    private val viewId: Int,
    private val args: QtPlatformViewArgs,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val root = QtHostRootView(context)
    private val control = MethodChannel(messenger, QtPlatformViewHost.CONTROL_CHANNEL)
    private val events = EventChannel(messenger, QtPlatformViewHost.EVENT_CHANNEL)

    private var sink: EventChannel.EventSink? = null
    private var qtView: View? = null

    private var status: MutableMap<String, Any?> = linkedMapOf()
    private var lastFlutterLifecycle: String? = null
    private var lastQtObservedState: Int? = null

    init {
        // 顺序是硬约束：先算清"这个实例该不该存在"，再产生任何副作用。
        // 旧实现先 claim 后校验：参数非法或 QtQuickView 构造失败的实例会占着单例所有权
        // 直到 dispose（后续合法视图全被拒），且冲突分支仍安装通道 handler，
        // 会把第一个实例的 MethodChannel/EventChannel handler 换掉。
        val probe = QtPlatformViewHost.probe(context)
        val activity = QtPlatformViewHost.unwrapActivity(context)
        val argErrors = args.validationErrors()

        var verdict = probe["verdict"] as? String ?: "archBlocked"
        var reason = probe["reason"] as? String ?: "probe returned no reason"
        @Suppress("UNCHECKED_CAST")
        val missing = (probe["missing"] as? List<String>)?.toMutableList() ?: mutableListOf()

        val initPlan = planHostInit(
            probeVerdict = verdict,
            argErrors = argErrors,
            activityPresent = activity != null,
        )
        var ownsActiveView = false
        var constructionFailed = false

        if (argErrors.isNotEmpty()) {
            verdict = "archBlocked"
            reason = "invalid creation params: " + argErrors.joinToString("; ")
            missing.addAll(argErrors)
        } else if (initPlan.claimRequested && activity != null) {
            // 只有"参数合法 + probe ready + 有 Activity"的实例才去抢进程单例。
            ownsActiveView = QtPlatformViewHost.claimActiveView(this)
            if (!ownsActiveView) {
                verdict = "archBlocked"
                reason = "another Qt platform view is already active; Qt embedding is a " +
                    "process singleton (QtView.java:140-161 starts the Qt application once)"
                missing.add("single Qt application instance")
            } else {
                // 注意：这里先不装通道 handler。onListen 会立刻 emitStatus，
                // 而此刻 status 还没算完；handler 统一放到 init 末尾（status 组装完之后）。
                QtPlatformViewHost.instantiateQtQuickView(activity, args)
                    .onSuccess { view ->
                        qtView = view
                        root.addView(
                            view,
                            FrameLayout.LayoutParams(
                                FrameLayout.LayoutParams.MATCH_PARENT,
                                FrameLayout.LayoutParams.MATCH_PARENT,
                            ),
                        )
                        verdict = "ready"
                        reason = "QtQuickView constructed from " + args.qtAppLibraryName
                        Log.i(TAG, "QtQuickView attached for viewId=$viewId")
                    }
                    .onFailure { error ->
                        // 如实降级：QtLoader 内部失败通常表现为构造期异常（native 库缺失、
                        // meta-data 解析失败、Qt 线程启动失败）。
                        verdict = "deviceBlocked"
                        reason = "QtQuickView instantiation failed: " +
                            error.javaClass.name + ": " + error.message
                        Log.w(TAG, reason, error)
                        // 失败实例不再持有单例所有权，也不再装通道：否则后续合法视图
                        // 会被永久拒绝，或者它的 handler 被这个死视图覆盖。
                        QtPlatformViewHost.releaseActiveView(this)
                        ownsActiveView = false
                        constructionFailed = true
                    }
            }
        } else if (verdict == "ready") {
            // probe 说 ready，但拿不到 Activity（或 plan 判定不该 claim）：如实降级。
            verdict = "archBlocked"
            reason = "probe reported ready but no Activity context was resolvable"
        }

        root.attachSizeListener { w, h -> emitSurfaceSize(w, h) }
        root.contentDescription = "Qt platform view host (verdict=" + verdict + ")"
        status = probe
        status["verdict"] = verdict
        status["reason"] = reason
        status["missing"] = missing
        status["viewId"] = viewId
        status["qtQuickViewConstructed"] = qtView != null
        // 真实子树观测：只有此刻 QtQuickView/QtWindow/QtSurface 才可能存在。
        // verdict 不是 ready 时退回缺省值（没有观测面可扫，不许把"没扫到"写成"扫到了没有"）。
        mergeObservedSubtree()

        // 通道 handler 放在 init 末尾：EventChannel.setStreamHandler 会同步回调
        // onListen → emitStatus，只有此刻 status 才是完整的探针结果（否则会先发空 map）。
        val claimAttempted = initPlan.claimRequested && activity != null
        val canInstallChannels = shouldInstallChannels(
            argErrorsEmpty = argErrors.isEmpty(),
            claimAttempted = claimAttempted,
            claimGranted = ownsActiveView,
            constructionFailed = constructionFailed,
            anotherOwnerExists = QtPlatformViewHost.hasActiveView(),
            anotherChannelOwnerExists = QtPlatformViewHost.hasChannelOwner(),
        )
        if (canInstallChannels) {
            // 先记通道归属，再装 handler；dispose 只允许当前归属者拆。
            QtPlatformViewHost.claimChannels(this)
            control.setMethodCallHandler(this)
            events.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
                    sink = eventSink
                    emitStatus()
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
        }
    }

    override fun getView(): View = root

    override fun dispose() {
        // 只有当前通道归属者才能拆 handler：被拒/失败的实例没装过；
        // 被后来合法实例接管的诊断实例也不再是 owner，它的 dispose 不能拆别人的通道。
        if (QtPlatformViewHost.ownsChannels(this)) {
            control.setMethodCallHandler(null)
            events.setStreamHandler(null)
            QtPlatformViewHost.releaseChannels(this)
        }
        sink = null
        qtView?.let { view ->
            root.removeView(view)
            // QtView.java:93-97：detach 会走 destroyWindow + 从嵌入接口摘除；
            // 我们只做 removeView，Qt 侧的生命周期由它自己的 listener 管。
        }
        qtView = null
        QtPlatformViewHost.releaseActiveView(this)
        Log.i(TAG, "disposed viewId=$viewId")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "refreshProbe" -> {
                // 冻结契约 (8)：每次 refreshProbe 都用 probeQtSubtree(root) 刷新 8 个新 key。
                // 这不是"再报一次缓存的探针"，而是真的重扫一遍宿主视图树。
                mergeObservedSubtree()
                emitStatus()
                result.success(status)
            }
            "flutterLifecycle" -> {
                // 只记录，不调 QtNative.setApplicationState：状态归 QtEmbeddedDelegate
                // （QtEmbeddedDelegate.java:33-82），宿主双写会让 Qt 看到交替的状态。
                lastFlutterLifecycle = call.argument<String>("flutterState")
                lastQtObservedState = call.argument<Int>("qtAppState")
                emitLifecycleObservation()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 把 back 作为一次"询问"发给控制通道，并用 [onResult] 带回对面是否认领。
     *
     * 只有真的挂着 Qt 视图、且探针判定 ready 的实例才发问：被拒/构造失败/已被接管的诊断
     * 实例没有可返回的 Qt 内容，必须立即回 false 让 Activity 回落 Flutter，而不是发一个
     * 无人接收的 verb。
     *
     * 三条回复路径都收敛到 false，除了显式 true：
     *  - success(null/false)：对面没有 back 分支（Dart 的 default 返回 null）或明确拒绝；
     *  - error：对面处理抛错；
     *  - notImplemented：通道协议层声明未实现。
     * invokeMethod 的同步异常（通道未注册、引擎已 detach）同样按未认领处理，不丢这次返回。
     */
    internal fun forwardBackVerb(onResult: (Boolean) -> Unit) {
        if (qtView == null) {
            onResult(false)
            return
        }
        if (status["verdict"] != "ready") {
            onResult(false)
            return
        }
        val payload = linkedMapOf<String, Any?>(
            "type" to QtPlatformViewHost.METHOD_BACK,
            "viewId" to viewId,
            "source" to "activity-back",
        )
        val reply = object : MethodChannel.Result {
            override fun success(result: Any?) {
                val claimed = result == true
                if (!claimed) {
                    Log.i(TAG, "back verb unclaimed (reply=$result) viewId=$viewId")
                }
                onResult(claimed)
            }

            override fun error(code: String, message: String?, details: Any?) {
                Log.w(TAG, "back verb rejected code=$code viewId=$viewId")
                onResult(false)
            }

            override fun notImplemented() {
                Log.i(TAG, "back verb not implemented on the Dart side viewId=$viewId")
                onResult(false)
            }
        }
        try {
            control.invokeMethod(QtPlatformViewHost.METHOD_BACK, payload, reply)
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "back verb could not be dispatched viewId=$viewId", error)
            onResult(false)
        }
    }

    /**
     * 把"真实子树观测"合进 status。
     *
     * verdict != "ready" 时用 observationDefaults()：archBlocked/deviceBlocked 说明宿主根本没拿到
     * QtQuickView，视图树里不可能有 QtWindow/QtSurface，此时如实写"未观测到"，
     * 而不是保留上一次扫描的残留值。
     */
    private fun mergeObservedSubtree() {
        val verdict = status["verdict"] as? String
        val observed = if (verdict == "ready") {
            QtPlatformViewHost.probeQtSubtree(root)
        } else {
            QtPlatformViewHost.observationDefaults()
        }
        status.putAll(observed)
    }

    private fun emitStatus() {
        // 事件通道送 {type, status}：status 就是同一份扁平 schema，包一层是为了和其它
        // 事件（surfaceSize / lifecycleObservation）的 type 字段对齐。Dart 两种形状都接受。
        val payload = linkedMapOf<String, Any?>(
            "type" to "hostStatus",
            "status" to HashMap(status),
            "viewId" to viewId,
        )
        sink?.success(payload)
        // 同时用一次方法调用兜底：Dart 在 onPlatformViewCreated 里会 refreshProbe，
        // 但事件通道可能还没 onListen。两条路送同一个 schema（方法通道发扁平 status）。
        runCatching {
            control.invokeMethod("hostStatus", status)
        }
    }

    private fun emitLifecycleObservation() {
        val payload = linkedMapOf<String, Any?>(
            "type" to "lifecycleObservation",
            "flutterState" to lastFlutterLifecycle,
            "flutterQtAppState" to lastQtObservedState,
            "note" to "observability only; Qt owns its own application state",
        )
        sink?.success(payload)
    }

    private fun emitSurfaceSize(width: Int, height: Int) {
        // 不是当前通道归属者的实例（参数非法 / 未 ready / 被单例拒绝 / 构造失败 /
        // 已被合法实例接管）不向共享通道发任何东西，否则尺寸事件会落到别人的 Dart 侧。
        if (!QtPlatformViewHost.ownsChannels(this)) return
        val payload = linkedMapOf<String, Any?>(
            "type" to "surfaceSize",
            "width" to width,
            "height" to height,
            "viewId" to viewId,
            "touchEvents" to root.touchEventCount,
            "lastTouchAction" to root.lastTouchAction,
        )
        sink?.success(payload)
        runCatching { control.invokeMethod("surfaceSize", payload) }
    }
}

/**
 * 宿主根容器：**纯透传**，不解释输入、不绘制任何东西（没有 background、没有 child 时就是透明）。
 *
 * 为什么"纯透传"是硬约束（不是风格问题）：
 *   Android 的 View 分发在派发前已经把 MotionEvent 的坐标换算成**目标视图的局部坐标**；
 *   QtWindow.onTouchEvent 直接拿这份局部坐标调用
 *   `QtInputDelegate.sendTouchEvent(event, getId())`（QtWindow.java:246-266），
 *   随后才把同一个 event 交给 m_gestureDetector.onTouchEvent 并 return true。
 *   也就是说坐标映射已经由「Android View 分发 + QtWindow 的命中测试」完成了。
 *   宿主如果再做一次 scale/offset（比如把 Flutter 逻辑坐标乘个 devicePixelRatio 再减个 offset），
 *   就是**二次变换**，会把点击整体挪位；宿主如果消费/拦截事件（onInterceptTouchEvent 返回 true、
 *   或 setOnTouchListener 返回 true），Qt 就收不到完整的 DOWN/MOVE/UP 序列，
 *   长按/拖动（QtWindow.java:76-85 的 GestureDetector.onLongPress（:81 → QtInputDelegate.longPress））
 *   与 QML 的 DragHandler（Qt/qml/TouchInput.qml:19-25）都会坏掉。
 *
 * 所以本类只做两件事，都不改变事件语义：
 *   1. 计数 + 记录 actionMasked（切片要证明"输入真的到了宿主"，而不是靠断言截图）；
 *   2. 报尺寸变化（尺寸真相由 Flutter/Android 给，宿主只转发；resize 逻辑归 QtView 的
 *      OnLayoutChangeListener，QtView.java:54-66）。
 */
class QtHostRootView(context: Context) : FrameLayout(context) {

    var touchEventCount: Int = 0
        private set

    var lastTouchAction: Int = -1
        private set

    private var sizeListener: ((Int, Int) -> Unit)? = null

    fun attachSizeListener(listener: (Int, Int) -> Unit) {
        sizeListener = listener
    }

    /** 冻结契约 (7)：恒 false。宿主不截获任何手势，事件继续向下派发给 QtQuickView/QtWindow。 */
    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = false

    /**
     * 冻结契约 (7)：只计数，然后 return super.dispatchTouchEvent(event)。
     * 不消费、不改坐标、不 setOnTouchListener。
     */
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        touchEventCount++
        lastTouchAction = event.actionMasked
        return super.dispatchTouchEvent(event)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        sizeListener?.invoke(w, h)
    }
}
