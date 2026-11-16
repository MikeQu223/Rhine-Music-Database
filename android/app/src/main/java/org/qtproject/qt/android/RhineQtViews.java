package org.qtproject.qt.android;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;

/**
 * Kotlin 侧的取用入口（PARITY QT-OVERLAY-128 / DEVICE-VISUAL-131）。
 *
 * Kotlin 拒绝把"父类是包内可见类"的 Java 类型放进自己的签名——它会尝试解析
 * org.qtproject.qt.android.QtView 并报无法访问。所以创建动作收成一个返回 {@link View}
 * 的静态方法：Kotlin 只看见 View，构造细节留在 Java 的同一个包里。
 *
 * 本类在 org.qtproject.qt.android 包内，可以直接使用 Qt Android 的包内 API。它解决
 * "Qt 运行时嵌在 Flutter 平台视图里"带出来的三件事：
 *
 * 一、应用状态补报（Qt3D 区域全黑的直接原因）
 * Qt 的嵌入式路径（QtView / QtEmbeddedViewInterfaceFactory）把应用状态跟踪交给
 * QtEmbeddedDelegate，而它是在**第一个 QtView 构造时**才通过
 * Application.registerActivityLifecycleCallbacks 注册的。宿主 Activity 的
 * onCreate/onStart/onResume 早已发完，于是 QtNative.m_stateDetails.state 永远停在 0，
 * QtNative.runAction(action, true) 判定"UI 线程不可达"，把动作塞进
 * BackgroundActionsTracker 却没人 process；QAndroidPlatformClipboard 注册剪贴板管理器时
 * 在 Semaphore.acquire() 上永久等待，Qt 主线程卡在 QGuiApplication 构造函数内部，
 * qApp 一直是空，createRootWindow 的 invokeMethodImpl 全部返回 false 被丢弃，
 * 平台视图永远停在 placeholder（真机表现：Qt3D 区域全黑）。
 *
 * 二、跨 Activity 的运行时归属（退出后重开必然 SIGABRT 的根因）
 * Qt 6.12 的嵌入式路径假设"一个 Activity = 一个 Qt 进程"：
 * QtEmbeddedDelegate.onActivityDestroyed 会调 QtNative.terminateQtNativeApplication()，
 * 原生侧 clearJavaReferences() 把 m_qtActivityClass 等全局 jclass 全部 DeleteGlobalRef
 * 并置空；而它们只在 JNI_OnLoad 里建立。库已经加载过，Activity 重建时
 * QtView.loadQtLibraries → QtNative.startApplication → initAndroidQpaPlugin 不会重新
 * JNI_OnLoad，于是 QPA 插件重新构造时拿到 NULL jclass：
 *
 *   JNI DETECTED ERROR IN APPLICATION: GetMethodID received NULL jclass
 *   in call to GetMethodID
 *   from void org.qtproject.qt.android.QtNative.startQtNativeApplication(java.lang.String)
 *   → QPlatformIntegrationFactory::create → QAndroidPlatformIntegration ctor
 *
 * 真机已复现（devices 526f6b6d，tombstone logs/lifecycle-fix-reopen-full.txt）。同一个
 * 进程里"重启 Qt"在这套 Qt 里走不通，所以本类改成**不拆运行时**：Qt 运行时按进程存活，
 * 只把场景视图挂到新 Activity 上。
 *
 * 三、销毁后的引用释放（DEVICE-VISUAL-131 seq5：泄漏必须收口，不是"已知代价"）
 * 只把 isStarted 置 false 会连 Qt 自己的注销分支一起跳过：QtEmbeddedDelegate 在
 * 构造函数里注册的匿名 Application.ActivityLifecycleCallbacks 只有它自己的
 * onActivityDestroyed 拿得到（unregisterActivityLifecycleCallbacks(this)），于是每轮
 * 退出都会留下 Application→匿名回调→delegate→已销毁 Activity 的强引用链；QtView 也会
 * 在构造时 QtNative.registerAppStateListener(this) 而永不自注销。本类的处理：
 *   - 销毁前把该 Activity 里所有 QtView 从 Qt 的 app-state 监听列表里注销；
 *   - 依赖本地补丁版 QtEmbeddedDelegate（android/app/javapatch：注销自身
 *     Application 回调、注销 app-state 监听、从 factory 摘除，只在原判据成立时才
 *     terminate），使被销毁的宿主不再被 Application 引用；
 *   - 记录 WeakReference 并在下一轮用 System.gc() 后的可回收性做对象根证据
 *     （日志 "released ... activity=true delegate=true view=true"）。
 *
 * 顺序：本类必须在 Qt 自己的 delegate 之前注册回调（registerActivityLifecycleCallbacks
 * 的注册顺序即回调顺序），才能在 QtEmbeddedDelegate.onActivityDestroyed 之前把
 * QtNative.setStarted(false)，让它跳过 terminateQtNativeApplication()，保住
 * m_qtActivityClass 等 jclass 与活着的 Qt 运行时。
 *
 * 重开时走"复用运行时"分支：先为新的 Activity 建 delegate（它的 m_stateDetails 快照还是
 * isStarted=false），再把 QtNative.setStarted(true) 造出一次 false→true 迁移，让新 delegate
 * 在 onAppStateDetailsChanged 里注册 QtWindow/QtMenu/QtInput backend；然后
 * updateNativeActivity() 把新 Activity 交给原生侧；最后补报 ApplicationActive。此时
 * QtView 构造函数里的 QtNative.startApplication() 因为 isStarted=true 直接 return，
 * 不会重入 main()，也就不会再有那次 NULL jclass 崩溃。
 */
public final class RhineQtViews {
    private RhineQtViews() {}

    private static final String TAG = "RhineQtViews";

    /** QtNative ApplicationState 里的取值（与 qnamespace.h / QtEmbeddedDelegate 一致）。 */
    private static final int APPLICATION_ACTIVE = 4;
    private static final int APPLICATION_INACTIVE = 2;
    private static final int APPLICATION_SUSPENDED = 0;

    /** 补报状态的兜底时刻：Qt 线程可能比构造返回更晚才把动作塞进后台队列。 */
    private static final int[] STATE_SYNC_DELAYS_MS = {150, 500, 1200, 2500};

    private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());

    private static final Runnable SYNC_STATE_RUNNABLE = new Runnable() {
        @Override
        public void run() {
            syncApplicationState();
        }
    };

    /** 已经注册过生命周期回调的 Application（进程内只注册一次，且早于任何 Qt delegate）。 */
    private static Application sTrackedApplication;

    /** 当前 Activity 对应的 Qt delegate（QtEmbeddedViewInterfaceFactory 里的那份）。 */
    private static QtEmbeddedViewInterface sDelegate;

    /** 当前绑定到 Qt 的宿主 Activity（只用于判断回调是否属于本轮宿主）。 */
    private static WeakReference<Activity> sHostActivity = new WeakReference<>(null);

    /** 本进程创建过的场景视图（销毁时逐个从 Qt 的 app-state 监听列表注销）。 */
    private static final List<WeakReference<View>> sSceneViews = new ArrayList<>();

    /** 每轮销毁时的对象根探针，下一轮 gc 后检查是否真的被回收。 */
    private static final List<CycleProbe> sCycleProbes = new ArrayList<>();

    /** Qt 运行时是否已经跨过一次 Activity 销毁（true 时重开走"复用运行时"分支）。 */
    private static boolean sRuntimeRetained;

    /** 上一轮 Qt 运行时已经被 terminate（只可能来自外部 terminate 或库替换后的首启）。 */
    private static boolean sRuntimeTornDown;

    /** 对象根探针开关：只在 debuggable 包打开（生产包不强制 GC）。 */
    private static boolean probeEnabled;


    private static final class CycleProbe {
        final int cycle;
        final WeakReference<Activity> activity;
        final WeakReference<Object> delegate;
        final WeakReference<Object> view;

        CycleProbe(int cycle, Activity activity, Object delegate, Object view) {
            this.cycle = cycle;
            this.activity = new WeakReference<>(activity);
            this.delegate = new WeakReference<>(delegate);
            this.view = new WeakReference<>(view);
        }
    }

    /** 创建 Qt 场景视图；首次调用会加载 Qt 运行时并进入本库 main()。 */
    public static View create(Context context) {
        if (!(context instanceof Activity)) {
            return new RhineQtView(context);
        }

        final Activity activity = (Activity) context;

        // 0) 必须在任何 Qt delegate 之前注册：宿主 Activity destroy 时本类的回调要先跑，
        //    才能在 QtEmbeddedDelegate.onActivityDestroyed 之前把 isStarted 置 false。
        registerActivityLifecycle(activity.getApplication());

        // 1) 上一轮运行时确实被 terminate 过（不该发生在本类控制的路径里）：先排空陈旧
        //    的 C++ runnable，避免它们被后面的 setActivity 唤醒后触碰已置空的 jclass。
        if (sRuntimeTornDown) {
            drainPendingCppRunnables("before-create");
            sRuntimeTornDown = false;
        }

        // 2) 为新 Activity 建 delegate：此后它的 pause/resume 都能被 Qt 看到。
        //    幂等：同一 Activity 已经持有 delegate 时复用它。Flutter 侧一次页面重建可能
        //    连续调两次 create()（横竖屏切换 / 同一 Activity 上换场景视图），无条件再建
        //    会在同一个 Application 上叠第二个 delegate，而销毁路径只清 sDelegate 这
        //    一个——剩下那个永远持有 Activity，正是泄漏的一半来源。
        final Object liveDelegate = sDelegate;
        final Activity knownActivity = sHostActivity.get();
        if (liveDelegate == null || knownActivity != activity) {
            if (liveDelegate != null) {
                unregisterDelegate(liveDelegate);
            }
            sDelegate = QtEmbeddedViewInterfaceFactory.create(activity);
            sHostActivity = new WeakReference<>(activity);
        } else {
            android.util.Log.i(TAG, "reusing existing delegate for activity " + activity);
        }

        if (sRuntimeRetained) {
            // 复用活着的 Qt 运行时：造一次 false→true 迁移让新 delegate 注册 backend，
            // 再把新 Activity 交给原生侧。QtView 构造函数里的 startApplication() 会因此
            // 直接 return，不会重入 main()，也就不再触发 NULL jclass 崩溃。
            QtNative.setStarted(true);
            // 重挂必须把**新宿主**写进 QtNative 的 Activity 槽，再交给原生侧：
            // 只调 updateNativeActivity() 时它读的是上一次 setActivity 留下的槽，
            // 而上一轮销毁路径已经把它置成 null —— 结果是原生侧长期没有 Activity，
            // 而真正想清的旧宿主引用（cycle 1）根本没被替换过。
            QtNative.setActivity(activity);
            if (!updateNativeActivity()) {
                android.util.Log.w(TAG, "updateNativeActivity failed after activity reattach");
            }
            android.util.Log.i(TAG, "reattached Qt runtime to activity " + activity);
        } else {
            // 冷启动：只记录宿主 Activity；QtView 构造函数加载完库后会自己调
            // startApplication() 并把 isStarted 置 true。
            QtNative.setActivity(activity);
        }

        final View view = new RhineQtView(context);

        synchronized (sSceneViews) {
            sSceneViews.add(new WeakReference<>(view));
        }

        // 3) Qt 运行时已加载、main() 已在线程上跑：补报一次 active 并短时兜底重放。
        syncApplicationState();
        scheduleStateSync();

        // 4) 上一轮的宿主对象根探针：确认已销毁的 Activity / delegate / view 真的能回收。
        //    只在可调试包、且只在确实攒到待验证的轮次时才跑（首次 create 没有 probe，
        //    直接返回、不 GC）；生产包永不强制 GC。
        probeEnabled = (activity.getApplicationInfo().flags
                & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        verifyPreviousCyclesReleased();
        return view;
    }

    /**
     * 把"宿主 Activity 已在前台"的事实同步给 Qt，并放行 BackgroundActionsTracker
     * 里攒下的动作（QtNative.setApplicationState 在 state==4 时调用 processActions）。
     */
    public static void syncApplicationState() {
        try {
            QtNative.setApplicationState(APPLICATION_ACTIVE);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "syncApplicationState failed: " + error);
        }
    }

    private static void pushApplicationState(int state) {
        try {
            QtNative.setApplicationState(state);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "setApplicationState(" + state + ") failed: " + error);
        }
    }

    private static void scheduleStateSync() {
        MAIN_HANDLER.removeCallbacks(SYNC_STATE_RUNNABLE);
        for (int delayMs : STATE_SYNC_DELAYS_MS) {
            MAIN_HANDLER.postDelayed(SYNC_STATE_RUNNABLE, delayMs);
        }
    }

    private static boolean updateNativeActivity() {
        try {
            return QtNative.updateNativeActivity();
        } catch (Throwable error) {
            android.util.Log.w(TAG, "updateNativeActivity threw: " + error);
            return false;
        }
    }

    private static boolean isHost(Activity activity) {
        Activity host = sHostActivity.get();
        if (host != null && host == activity) {
            return true;
        }
        // 宿主弱引用可能已被回收或尚未写入（冷启动早期），退化用原生侧的 Activity 判定。
        try {
            return QtNative.activity() == activity;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static void registerActivityLifecycle(Application application) {
        if (application == null || application == sTrackedApplication) {
            return;
        }
        sTrackedApplication = application;
        application.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityCreated(Activity activity, Bundle savedInstanceState) {}

            @Override
            public void onActivityStarted(Activity activity) {}

            @Override
            public void onActivityResumed(Activity activity) {
                if (!isHost(activity)) {
                    return;
                }
                // 从后台回来：Qt 在此期间收到的是 Inactive/Suspended，这里恢复 active。
                syncApplicationState();
                scheduleStateSync();
            }

            @Override
            public void onActivityPaused(Activity activity) {
                if (!isHost(activity)) {
                    return;
                }
                // 权威与前台一致：先取消还没跑到的补报，避免"后台里被告知 active"。
                MAIN_HANDLER.removeCallbacks(SYNC_STATE_RUNNABLE);
                pushApplicationState(APPLICATION_INACTIVE);
            }

            @Override
            public void onActivityStopped(Activity activity) {
                if (!isHost(activity)) {
                    return;
                }
                MAIN_HANDLER.removeCallbacks(SYNC_STATE_RUNNABLE);
                pushApplicationState(APPLICATION_SUSPENDED);
            }

            @Override
            public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}

            @Override
            public void onActivityDestroyed(final Activity activity) {
                // 配置变更时 Qt 自己不终止运行时，交给 Qt 处理。
                if (activity.isChangingConfigurations()) {
                    return;
                }
                if (!isHost(activity)) {
                    // 不是 Qt 绑定的那个 Activity（例如别的 Activity 被销毁）。
                    return;
                }
                // 先松开 QtView 的 app-state 监听（QtView 构造时注册，永不注销）。
                final View sceneView = releaseSceneViews(activity);
                // 关键一步，必须在当前这轮 ActivityLifecycleCallbacks 里同步执行：
                // QtEmbeddedDelegate 的 onActivityDestroyed 判据是
                // `m_activity == activity && m_stateDetails.isStarted && !isChangingConfigurations`，
                // 只有把 isStarted 提前置 false 才能让它跳过 terminateQtNativeApplication()，
                // 从而保住 m_qtActivityClass 等 jclass 与活着的 Qt 运行时。
                QtNative.setStarted(false);
                final QtEmbeddedViewInterface delegate = sDelegate;
                // 同步执行，不 post：post 出去的 Runnable 在真机上一次都没跑过（日志里
                // 缺 "kept Qt runtime alive"，导致 sRuntimeRetained 永远是 false，下一次
                // Activity 起来时走 startApplication → 同进程第二次建 QGuiApplication →
                // 挂死 → ANR）。这里只注册/清引用，不碰原生线程，同步是安全的。
                android.util.Log.i(TAG, "host activity destroyed: releasing host refs");
                onHostActivityDestroyed(activity, delegate, sceneView);
            }
        });
    }

    /** 把该 Activity 里的 QtView 从 Qt 的 app-state 监听列表里注销，并返回第一个视图。 */
    private static View releaseSceneViews(Activity activity) {
        List<View> views = new ArrayList<>();
        try {
            View decor = activity.getWindow() == null ? null : activity.getWindow().peekDecorView();
            collectQtViews(decor, views);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "collect scene views failed: " + error);
        }
        synchronized (sSceneViews) {
            for (WeakReference<View> ref : sSceneViews) {
                View view = ref.get();
                if (view != null && view.getContext() == activity && !views.contains(view)) {
                    views.add(view);
                }
            }
            sSceneViews.clear();
        }
        View first = views.isEmpty() ? null : views.get(0);
        for (View view : views) {
            if (view instanceof RhineQtView) {
                // 先把场景窗口从 WindowManager 摘下来，再注销监听：否则新 Activity 起来时
                // mCurrentFocus 仍是 null（旧 QtWindow 还挂在死掉的 View 树上），输入派发超时
                // 会被系统判成 ANR 整进程杀掉。
                try {
                    ((RhineQtView) view).releaseSceneForHostDestroy();
                    android.util.Log.i(TAG, "released Qt scene window for destroyed host " + view);
                } catch (Throwable error) {
                    android.util.Log.w(TAG, "release scene window failed: " + error);
                }
            }
            if (view instanceof QtNative.AppStateDetailsListener) {
                QtNative.unregisterAppStateListener((QtNative.AppStateDetailsListener) view);
                android.util.Log.i(TAG, "released QtView app-state listener " + view);
            }
        }
        return first;
    }

    private static void collectQtViews(View view, List<View> out) {
        if (view == null) {
            return;
        }
        if (view instanceof org.qtproject.qt.android.QtView) {
            out.add(view);
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                collectQtViews(group.getChildAt(i), out);
            }
        }
    }

    /**
     * Qt 自己的 destroy 回调已经轮转过去（被 isStarted=false 挡掉，没有拆运行时）。
     * 这里把死掉的 delegate 摘掉，避免它继续被 BackendRegister 选中，也避免
     * QtEmbeddedViewInterfaceFactory / Application 强引用着已销毁的 Activity。
     */
    private static void onHostActivityDestroyed(Activity activity, QtEmbeddedViewInterface delegate,
                                                View sceneView) {
        if (activity.isChangingConfigurations()) {
            return;
        }
        MAIN_HANDLER.removeCallbacks(SYNC_STATE_RUNNABLE);
        if (delegate instanceof QtNative.AppStateDetailsListener) {
            // QtEmbeddedDelegate 同时是 AppStateDetailsListener；注销后它不会再被通知，
            // 重开时的 false→true 迁移只会落到新 delegate 上。
            QtNative.unregisterAppStateListener((QtNative.AppStateDetailsListener) delegate);
        }
        // 退役身份/代次门禁（139/140）：只有"当前登记的仍是这一个 delegate"时才断开，
        // 一个迟到的旧回调绝不能把已经接手的新宿主清掉。
        final boolean stillCurrentHost = sDelegate == delegate;
        if (stillCurrentHost) {
            sDelegate = null;
            sHostActivity = new WeakReference<>(null);
        }
        QtEmbeddedViewInterfaceFactory.remove(activity);
        // MUST-4：可复用 delegate 的静态弱引用也必须断，否则重挂的 QtView 可能把死宿主的
        // delegate 拿去 addView（弱引用未回收的窗口期内）。
        org.qtproject.qt.android.QtView.clearReusableInterface();
        // isStarted 仍是 false，setActivity 不会打到原生侧；只是松开 Java 侧的 Activity 引用。
        if (stillCurrentHost) {
            QtNative.setActivity(null);
            // 140 已证：setActivity 里的 updateNativeActivity() 被 isStarted 门挡住，所以原生侧
            // g_jActivity 仍然持着已销毁 Activity 的 JNI global ref（137 的 chain C）。这里直接
            // 补一次更新，让 native 侧走 DeleteGlobalRef(old) + 置零；调用是 stock 方法，
            // 不做内存偏移补丁。失败只记日志：这一轮回收不了也不会让运行时崩掉。
            try {
                QtNative.updateNativeActivity();
            } catch (Throwable error) {
                android.util.Log.w(TAG, "updateNativeActivity after host destroy failed: " + error);
            }
        }
        sRuntimeRetained = true;
        synchronized (sCycleProbes) {
            sCycleProbes.add(new CycleProbe(sCycleProbes.size() + 1, activity, delegate, sceneView));
        }
        android.util.Log.i(TAG, "kept Qt runtime alive after activity destroy; released host refs");
    }

    /**
     * 对象根证据：被销毁的 Activity、旧 delegate、旧 QtView 在下一轮是否真的可回收。
     * 只在可调试包、每个进程最多一次 System.gc() + WeakReference 检查，用日志给出
     * 布尔事实（不看 RSS）。生产包不强制 GC。
     */
    /**
     * 只读诊断：列出候选 Qt Android 类里仍指向被销毁宿主的 static 字段。
     *
     * 用途是区分"钉住发生在 Java 静态字段"还是"钉住发生在 native JNI global"——这决定下
     * 一步该改哪里。只读，不修改任何字段，也不影响行为。
     */
    private static void logStaticHolders(String tag, Object activity, Object delegate, Object view) {
        final String[] candidates = new String[] {
            "org.qtproject.qt.android.QtNative",
            "org.qtproject.qt.android.QtClipboardManager",
            "org.qtproject.qt.android.QtEmbeddedViewInterfaceFactory",
            "org.qtproject.qt.android.RhineQtViews",
            "org.qtproject.qt.android.QtEmbeddedDelegate",
            "org.qtproject.qt.android.QtActivityDelegateBase",
        };
        for (String name : candidates) {
            try {
                final Class<?> type = Class.forName(name);
                for (java.lang.reflect.Field field : type.getDeclaredFields()) {
                    if (!java.lang.reflect.Modifier.isStatic(field.getModifiers())) {
                        continue;
                    }
                    field.setAccessible(true);
                    final Object value = field.get(null);
                    if (value == null) {
                        continue;
                    }
                    final boolean hit = value == activity || value == delegate || value == view;
                    if (hit || value instanceof android.app.Activity) {
                        android.util.Log.w(TAG, tag + " static holder " + name + "."
                                + field.getName() + " -> " + value.getClass().getName()
                                + " hitsRetiredHost=" + hit);
                    }
                }
            } catch (Throwable ignored) {
                // 类不在包里或反射被挡住时跳过：这条诊断不影响行为。
            }
        }
    }

    /**
     * 只读诊断（MUST-7 定位第 2 步）：cycle1 仍活着的那一刻，记下已知的"可能钉住"来源。
     *
     * 判读：QtNative.activity() 非空 → 根在 Qt 原生/JNI 侧；Java 侧全空而 Activity 仍可达
     * → 根在 retained delegate 的原生持有者，或 Flutter 侧 retained engine 的 activity
     * attachment。只读，不改任何状态。
     */
    private static void logPinningSources(String tag) {
        String qtActivity = "?";
        String appContext = "?";
        try {
            final android.app.Activity activity = QtNative.activity();
            qtActivity = activity == null ? "null" : activity.getClass().getName();
        } catch (Throwable error) {
            qtActivity = "err:" + error;
        }
        try {
            final android.content.Context context = QtNative.applicationContext();
            appContext = context == null ? "null" : context.getClass().getName();
        } catch (Throwable error) {
            appContext = "err:" + error;
        }
        android.util.Log.i(TAG, tag + " pin sources qtNativeActivity=" + qtActivity
                + " qtApplicationContext=" + appContext
                + " sDelegateNull=" + (sDelegate == null)
                + " sHostActivityNull=" + (sHostActivity.get() == null));
    }

    private static void verifyPreviousCyclesReleased() {
        if (!probeEnabled) {
            // 生产包不跑探针，但也不能让 sCycleProbes 每轮 +1 无界增长。
            synchronized (sCycleProbes) {
                sCycleProbes.clear();
            }
            return;
        }
        if (sCycleProbes.isEmpty()) {
            return;
        }
        final List<CycleProbe> probes;
        synchronized (sCycleProbes) {
            if (sCycleProbes.isEmpty()) {
                return;
            }
            // 不清空：要给同一批探针多次机会（一次 GC 的时点可能正好撞上异步 teardown）。
            probes = new ArrayList<>(sCycleProbes);
        }
        // 2.5s / 5.5s / 9.5s 三次：上一轮 Activity 的 teardown（Flutter engine/PlatformView
        // 的 dispose）是异步的，太早测会把"还没拆完"误当成泄漏；而只测一次也说不清
        // "是延迟释放还是永不释放"。
        for (int attempt = 1; attempt <= 3; attempt++) {
            final int current = attempt;
            // 对照 canary：同一次 GC 后它必须被清空。canary 清了而 Activity 没清，才说明
            // "GC 真跑了、弱引用真会清"，把根因收敛到别处（Java 静态已排除 → 原生 JNI 全局引用）。
            final java.lang.ref.WeakReference<Object> canary =
                    new java.lang.ref.WeakReference<>(new Object());
            MAIN_HANDLER.postDelayed(new Runnable() {
                @Override
                public void run() {
                    System.gc();
                    System.runFinalization();
                    android.util.Log.i(TAG, "root probe attempt " + current + " canaryCleared="
                            + (canary.get() == null));
                    if (current == 1) {
                        logPinningSources("probe");
                    }
                    if (current == 1 && !probes.isEmpty()) {
                        logStaticHolders("probe",
                                probes.get(0).activity.get(),
                                probes.get(0).delegate.get(),
                                probes.get(0).view.get());
                    }
                    for (CycleProbe probe : probes) {
                        android.util.Log.i(TAG, "cycle " + probe.cycle + " attempt " + current
                                + " released activity=" + (probe.activity.get() == null)
                                + " delegate=" + (probe.delegate.get() == null)
                                + " view=" + (probe.view.get() == null));
                    }
                }
            }, attempt * 2500L);
        }
    }

    private static void drainPendingCppRunnables(String reason) {
        try {
            QtNative.runPendingCppRunnables();
            android.util.Log.i(TAG, "drained pending Qt runnables (" + reason + ")");
        } catch (Throwable error) {
            android.util.Log.w(TAG, "drain pending Qt runnables failed (" + reason + "): " + error);
        }
    }

    /** 注销一个 delegate 的 Application 回调（幂等：不是监听器就直接忽略）。 */
    private static void unregisterDelegate(Object delegate) {
        if (delegate instanceof QtNative.AppStateDetailsListener) {
            try {
                QtNative.unregisterAppStateListener((QtNative.AppStateDetailsListener) delegate);
                android.util.Log.i(TAG, "released superseded delegate app-state listener");
            } catch (Throwable error) {
                android.util.Log.w(TAG, "unregister superseded delegate failed: " + error);
            }
        }
    }

    /**
     * 把 Flutter 侧的渲染状态快照交给 Qt 场景（原生 QQuickView 里的 NativeScene）。
     *
     * 只做转交：解析/去重/生效都在 Qt 侧（Qt/src/EmbeddedSceneHost.cpp 的
     * RhineEmbedded::applySceneState）。异常在这里吞掉并打日志——状态通道坏了
     * 不该拖垮原生视图树。
     */
    /**
     * @return 原生侧是否受理。true 表示已排进 Qt 线程队列（或已缓存、等场景就绪后补应用），
     *     此时 Dart 端保持"已发送"去重即可；false 表示这次没被受理，Dart 端应清掉去重记录
     *     以便下一次重发。首帧可能早于 Qt 的 qApp，原生侧会把这份快照缓存到场景就绪。
     */
    public static boolean pushSceneState(String json) {
        if (json == null) {
            return false;
        }
        try {
            return nativePushSceneState(json);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "pushSceneState failed: " + error);
            return false;
        }
    }

    private static native boolean nativePushSceneState(String json);

    /**
     * 把 Flutter 搬过来的**原始**指针事件交给 Qt 场景。
     *
     * 为什么需要：hybrid composition 下 Qt 视图挂在 FlutterView 的子级里，但引擎
     * 为了在平台视图之上绘制 Flutter 内容会加一层 PlatformOverlayView；实测触摸
     * 连原生子树的 dispatchTouchEvent 都进不去（dumpsys activity top 的层级与
     * 探针都证明了这一点）。于是 Flutter 侧只做坐标搬运，语义判定仍然全部在
     * Qt 的 NativeSceneInput 里——这里不解释手势、不改相机。
     *
     * 坐标是**舞台单位**（Qt 的 1080p 舞台）：调用方已经除以 stageScale。
     */
    public static void pushScenePointer(String type, double x, double y) {
        if (type == null) {
            return;
        }
        try {
            nativePushScenePointer(type, x, y);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "pushScenePointer failed: " + error);
        }
    }

    private static native void nativePushScenePointer(String type, double x, double y);

    /** 双指缩放的搬运通道（Qt 侧进 Engine::wheelInput 的 pixelDelta）。 */
    public static void pushSceneWheel(double x, double y, double delta) {
        try {
            nativePushSceneWheel(x, y, delta);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "pushSceneWheel failed: " + error);
        }
    }

    private static native void nativePushSceneWheel(double x, double y, double delta);

    /** Qt 场景 → Flutter 的动作出口（目前只有"选中"）。由 Kotlin 侧注册/注销。 */
    public interface SceneActionSink {
        void onSceneAction(String action);
    }

    private static volatile SceneActionSink sSceneActionSink;

    public static void setSceneActionSink(SceneActionSink sink) {
        sSceneActionSink = sink;
    }

    /** JNI 入口：Qt 主线程 → Flutter。动作词表见 EmbeddedSceneHost.cpp。 */
    /**
     * Qt → Flutter 的动作出口。
     *
     * **当前没有生产者**：Qt 的归档槽位是 40 条占位记录（Assets/android-3d/slots.json），
     * 不带 Siren 身份，用它拼 music:index:<i> 会把界面上别的歌点开（假映射），所以
     * Qt/src/EmbeddedSceneHost.cpp 里的 selection→action 连线已停发。通道基础设施保留，
     * 等权威词表（能表达"归档槽位"）确定后再接。别在这里临时凑映射。
     */
    public static void emitSceneAction(String action) {
        if (action == null || action.isEmpty()) {
            return;
        }
        // 调用方是 Qt 主循环线程（qtMainLoopThread），而 Flutter 的 MethodChannel
        // 挂在 @UiThread 上：直接在 Qt 线程里调会抛
        // "Methods marked with @UiThread must be executed on the main thread"。
        if (Looper.myLooper() != Looper.getMainLooper()) {
            MAIN_HANDLER.post(new Runnable() {
                @Override
                public void run() {
                    deliverSceneAction(action);
                }
            });
            return;
        }
        deliverSceneAction(action);
    }

    private static void deliverSceneAction(String action) {
        final SceneActionSink sink = sSceneActionSink;
        if (sink == null) {
            return;
        }
        try {
            sink.onSceneAction(action);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "emitSceneAction failed: " + error);
        }
    }
}
