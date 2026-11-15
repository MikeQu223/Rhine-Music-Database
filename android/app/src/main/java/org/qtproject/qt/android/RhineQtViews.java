package org.qtproject.qt.android;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;

/**
 * Kotlin 侧的取用入口（PARITY QT-OVERLAY-128 / DEVICE-VISUAL-131）。
 *
 * Kotlin 拒绝把"父类是包内可见类"的 Java 类型放进自己的签名——它会尝试解析
 * org.qtproject.qt.android.QtView 并报无法访问。所以创建动作收成一个返回 {@link View}
 * 的静态方法：Kotlin 只看见 View，构造细节留在 Java 的同一个包里。
 *
 * 本类在 org.qtproject.qt.android 包内，可以直接使用 Qt Android 的包内 API。它解决
 * "Qt 运行时嵌在 Flutter 平台视图里"带出来的两件事：
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
 * 这里的做法不是绕过 Qt，而是把宿主 Activity 的真实状态补报给 Qt：
 * 1. 提前建立 QtEmbeddedViewInterfaceFactory 的 delegate（生命周期从此可跟踪）；
 * 2. 用 QtNative.setActivity 让 runAction 认为 UI 线程可达（否则 processActions
 *    重新入队的动作会自旋）；
 * 3. 在 Qt 运行时加载后补报一次 ApplicationActive，把攒下的动作放行。
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
 * 实现：在 Qt 自己的 ActivityLifecycleCallbacks **之前**注册本类的回调（顺序由
 * registerActivityLifecycleCallbacks 的调用顺序决定），在宿主 Activity destroy 的第一时
 * 间把 QtNative.setStarted(false)，让 QtEmbeddedDelegate.onActivityDestroyed 里的
 * `m_stateDetails.isStarted` 判据失效——它因此不会 terminate、不会 setActivity(null)、
 * 不会动那些 jclass。场景视图在 detach 时已经 destroyEmbeddedScene()，GPU 侧不留东西。
 * 等 Qt 的回调轮转过去之后，本类再把死掉的 delegate 从 QtEmbeddedViewInterfaceFactory
 * 摘掉、注销监听并清掉 Activity 引用。
 *
 * 重开时走"复用运行时"分支：先为新的 Activity 建 delegate（它的 m_stateDetails 快照还是
 * isStarted=false），再把 QtNative.setStarted(true) 造出一次 false→true 迁移，让新 delegate
 * 在 onAppStateDetailsChanged 里注册 QtWindow/QtMenu/QtInput backend；然后
 * updateNativeActivity() 把新 Activity 交给原生侧；最后补报 ApplicationActive。此时
 * QtView 构造函数里的 QtNative.startApplication() 因为 isStarted=true 直接 return，
 * 不会重入 main()，也就不会再有那次 NULL jclass 崩溃。
 *
 * 代价（如实记录，不掩盖）：每个被销毁的 Activity 都会留下一个 QtEmbeddedDelegate
 * （它被 Application 的 ActivityLifecycleCallbacks 列表强引用，Qt 没有暴露注销入口），
 * 以及一个 detached 的 QtView（QtView 构造时把自己注册成 app state listener，也从不
 * 注销）。即"每次退出重开泄漏一个已销毁的 Activity 壳"，换来的是不再崩溃、重开立即出图。
 */
public final class RhineQtViews {
    private RhineQtViews() {}

    private static final String TAG = "RhineQtViews";

    /** QtNative ApplicationState 里 resume 时使用的值（QtEmbeddedDelegate 直接传字面量 4）。 */
    private static final int APPLICATION_ACTIVE = 4;

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

    /** Qt 运行时是否已经跨过一次 Activity 销毁（true 时重开走"复用运行时"分支）。 */
    private static boolean sRuntimeRetained;

    /** 上一轮 Qt 运行时已经被 terminate（只可能来自外部 terminate 或库替换后的首启）。 */
    private static boolean sRuntimeTornDown;

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
        sDelegate = QtEmbeddedViewInterfaceFactory.create(activity);

        if (sRuntimeRetained) {
            // 复用活着的 Qt 运行时：造一次 false→true 迁移让新 delegate 注册 backend，
            // 再把新 Activity 交给原生侧。QtView 构造函数里的 startApplication() 会因此
            // 直接 return，不会重入 main()，也就不再触发 NULL jclass 崩溃。
            QtNative.setStarted(true);
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

        // 3) Qt 运行时已加载、main() 已在线程上跑：补报一次 active 并短时兜底重放。
        syncApplicationState();
        MAIN_HANDLER.removeCallbacks(SYNC_STATE_RUNNABLE);
        for (int delayMs : STATE_SYNC_DELAYS_MS) {
            MAIN_HANDLER.postDelayed(SYNC_STATE_RUNNABLE, delayMs);
        }
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

    private static boolean updateNativeActivity() {
        try {
            return QtNative.updateNativeActivity();
        } catch (Throwable error) {
            android.util.Log.w(TAG, "updateNativeActivity threw: " + error);
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
            public void onActivityResumed(Activity activity) {}

            @Override
            public void onActivityPaused(Activity activity) {}

            @Override
            public void onActivityStopped(Activity activity) {}

            @Override
            public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}

            @Override
            public void onActivityDestroyed(final Activity activity) {
                // 配置变更时 Qt 自己不终止运行时，交给 Qt 处理。
                if (activity.isChangingConfigurations()) {
                    return;
                }
                if (QtNative.activity() != activity) {
                    // 不是 Qt 绑定的那个 Activity（例如别的 Activity 被销毁）。
                    return;
                }
                // 关键一步，必须在当前这轮 ActivityLifecycleCallbacks 里同步执行：
                // QtEmbeddedDelegate 的 onActivityDestroyed 判据是
                // `m_activity == activity && m_stateDetails.isStarted && !isChangingConfigurations`，
                // 只有把 isStarted 提前置 false 才能让它跳过 terminateQtNativeApplication()，
                // 从而保住 m_qtActivityClass 等 jclass 与活着的 Qt 运行时。
                QtNative.setStarted(false);
                MAIN_HANDLER.post(new Runnable() {
                    @Override
                    public void run() {
                        onHostActivityDestroyed(activity);
                    }
                });
            }
        });
    }

    /**
     * Qt 自己的 destroy 回调已经轮转过去（被 isStarted=false 挡掉，没有拆运行时）。
     * 这里把死掉的 delegate 摘掉，避免它继续被 BackendRegister 选中，也避免
     * QtEmbeddedViewInterfaceFactory 强引用着已销毁的 Activity。
     */
    private static void onHostActivityDestroyed(Activity activity) {
        if (activity.isChangingConfigurations()) {
            return;
        }
        MAIN_HANDLER.removeCallbacks(SYNC_STATE_RUNNABLE);
        if (sDelegate instanceof QtNative.AppStateDetailsListener) {
            // QtEmbeddedDelegate 同时是 AppStateDetailsListener；注销后它不会再被通知，
            // 重开时的 false→true 迁移只会落到新 delegate 上。
            QtNative.unregisterAppStateListener((QtNative.AppStateDetailsListener) sDelegate);
        }
        sDelegate = null;
        QtEmbeddedViewInterfaceFactory.remove(activity);
        // isStarted 仍是 false，setActivity 不会打到原生侧；只是松开 Java 侧的 Activity 引用。
        QtNative.setActivity(null);
        sRuntimeRetained = true;
        android.util.Log.i(TAG, "kept Qt runtime alive after activity destroy");
    }

    private static void drainPendingCppRunnables(String reason) {
        try {
            QtNative.runPendingCppRunnables();
            android.util.Log.i(TAG, "drained pending Qt runnables (" + reason + ")");
        } catch (Throwable error) {
            android.util.Log.w(TAG, "drain pending Qt runnables failed (" + reason + "): " + error);
        }
    }
}
