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
import java.util.concurrent.atomic.AtomicLong;

/**
 * Kotlin 侧的取用入口：创建动作收成返回 {@link View} 的静态方法，
 * 避免 Kotlin 去解析包内可见的父类。
 *
 * 这个类解决嵌入式路径的三件事：
 * 一、应用状态补报。QtEmbeddedDelegate 在第一个 QtView 构造时才注册生命周期回调，
 *     宿主早已发完 onCreate/onResume，state 停在 0，Qt 主线程卡在 QGuiApplication
 *     构造里，平台视图永远停在占位。
 * 二、运行时归属。Qt 的嵌入式路径假设一个 Activity 对应一次 Qt 进程，销毁后再建
 *     拿不到 JNI_OnLoad 建立的 jclass。所以运行时按进程存活，只把场景视图挂到新 Activity。
 * 三、引用释放。只置 isStarted=false 会跳过 Qt 自己的注销分支，留下
 *     Application → delegate → 已销毁 Activity 的强引用链；这里注销 app-state 监听，
 *     并配合本地补丁版 delegate 摘掉 Application 回调。
 *
 * 顺序要求：本类必须先于 Qt 自己的 delegate 注册回调，才能在其 onActivityDestroyed
 * 之前 setStarted(false)，跳过 terminateQtNativeApplication()。
 *
 * 重开走复用分支：建 delegate → setStarted(true) 触发 false→true 迁移 → 注册 backend →
 * updateNativeActivity() → 补报 ApplicationActive。
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
                // 同步执行，不 post：post 出去的 Runnable 不保证跑，会漏掉 keep-alive，
                // 下一次 Activity 起来就会二次建 QGuiApplication 挂死。
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
        // 可复用 delegate 的静态弱引用也必须断，否则重挂的 QtView 可能把死宿主的
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
        android.util.Log.i(TAG, "kept Qt runtime alive after activity destroy; released host refs");
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
     * 场景世代号计数器（进程级单调）。
     *
     * 谁在用：{@link RhineQtView#createWindow} 每次发起 create 请求取一个号，同一个号也用于
     * 它自己的 destroy；原生侧 Qt/src/EmbeddedSceneHost.cpp 的 SceneEpoch 只 adopt 更大的
     * 号。于是"上一代宿主的 destroy 晚到"会被判成旧世代而整段跳过，不会拆掉新宿主刚建好的
     * 场景（一个进程只有一个嵌入场景，旧代码在这里没有任何世代概念）。
     *
     * 为什么不是每实例一个号：号必须在**发起 create 的那一刻**分配，才保证"建的顺序 =
     * 号的顺序"；挂在构造上时，先构造后 create 的视图会拿到更小的号，它的 destroy 就能
     * 合法地拆掉后建的那一代。
     */
    private static final AtomicLong sSceneGeneration = new AtomicLong(0);

    /** 下一个场景世代号（每次 create 请求一个，单调递增、永不回退）。 */
    static long nextSceneGeneration() {
        return sSceneGeneration.incrementAndGet();
    }

    /**
     * 把 Flutter 的渲染状态快照交给 Qt 场景。只做转交，解析/去重/生效都在 Qt 侧。
     * 异常在这里吞掉并打日志：状态通道坏了不该拖垮原生视图树。
     *
     * @return 原生侧是否受理。false 表示这次没进队列，调用方应清掉去重记录以便重发。
     *     首帧可能早于 Qt 的 qApp，原生侧会缓存到场景就绪再应用。
     */
    public static boolean pushSceneState(String json) {
        return pushSceneState(-1, 0L, json);
    }

    /**
     * 带 origin 的快照推送：([viewId], [context]) 是**产出这份快照的**平台视图与其交互
     * 上下文代次。Qt 侧按它记住"当前画面来源"，之后排队中的输入/动作都要拿 origin 比对，
     * 不再靠"最后一个注册的视图"去猜。
     */
    public static boolean pushSceneState(int viewId, long context, String json) {
        if (json == null) {
            return false;
        }
        try {
            return nativePushSceneState(viewId, context, json);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "pushSceneState failed: " + error);
            return false;
        }
    }

    private static native boolean nativePushSceneState(int viewId, long context, String json);

    /**
     * 把 Flutter 搬过来的原始指针事件交给 Qt 场景。
     *
     * PlatformOverlayView 挡住原生派发，触摸进不了 Qt 子树，所以由 Flutter 只做坐标搬运；
     * 手势语义与相机仍全在 Qt 的 NativeSceneInput 里。坐标是舞台单位。
     */
    public static void pushScenePointer(String type, double x, double y) {
        pushScenePointer(-1, 0L, type, x, y);
    }

    /** 带 origin 的指针搬运：viewId/context 跟着事件一路到 Qt，Qt 只对当前来源生效。 */
    public static void pushScenePointer(int viewId, long context, String type, double x, double y) {
        if (type == null) {
            return;
        }
        try {
            nativePushScenePointer(viewId, context, type, x, y);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "pushScenePointer failed: " + error);
        }
    }

    private static native void nativePushScenePointer(int viewId, long context, String type, double x, double y);

    /** 双指缩放的搬运通道（Qt 侧进 Engine::wheelInput 的 pixelDelta）。 */
    public static void pushSceneWheel(double x, double y, double delta) {
        pushSceneWheel(-1, 0L, x, y, delta);
    }

    public static void pushSceneWheel(int viewId, long context, double x, double y, double delta) {
        try {
            nativePushSceneWheel(viewId, context, x, y, delta);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "pushSceneWheel failed: " + error);
        }
    }

    private static native void nativePushSceneWheel(int viewId, long context, double x, double y, double delta);

    /**
     * Qt 场景 → Flutter 的动作出口（滚动回执 archive-scroll、点选 archive-select、
     * 步进 archive-step）。由 Kotlin 侧注册/注销。
     */
    public interface SceneActionSink {
        /**
         * @param viewId  产出这个动作的平台视图（Qt 在**应用快照时**记下的 origin，恒 {@code >= 0}；
         *                未登记 origin 的动作到不了这里，Kotlin 侧已丢弃）
         * @param context 该视图当时的交互上下文代次（0 表示未登记，同样会被 Kotlin 侧丢弃）
         */
        void onSceneAction(int viewId, long context, String action);
    }

    private static volatile SceneActionSink sSceneActionSink;

    public static void setSceneActionSink(SceneActionSink sink) {
        sSceneActionSink = sink;
    }

    /**
     * 没有 producer origin 的动作出口：**不投递**。
     *
     * viewId/ctx 是动作归属的一半，缺了它只能按「此刻谁在前台」补标签，那正是
     * QUEUED-A-OVER-B 的错源。调用方必须改用 {@link #emitSceneAction(int, long, String)}。
     */
    public static void emitSceneAction(String action) {
        android.util.Log.w(TAG, "scene action without origin dropped: " + action);
    }

    /**
     * 带 producer origin 的动作出口。origin 由 Qt 在**应用快照时**记下（viewId+代次），
     * 这里原样透传；Java 侧不再用"当前前台视图"顶替 origin。
     */
    public static void emitSceneAction(final int viewId, final long context, String action) {
        if (action == null || action.isEmpty()) {
            return;
        }
        final String payload = action;
        // 调用方是 Qt 主循环线程（qtMainLoopThread），而 Flutter 的 MethodChannel
        // 挂在 @UiThread 上：直接在 Qt 线程里调会抛
        // "Methods marked with @UiThread must be executed on the main thread"。
        if (Looper.myLooper() != Looper.getMainLooper()) {
            MAIN_HANDLER.post(new Runnable() {
                @Override
                public void run() {
                    deliverSceneAction(viewId, context, payload);
                }
            });
            return;
        }
        deliverSceneAction(viewId, context, payload);
    }

    private static void deliverSceneAction(int viewId, long context, String action) {
        final SceneActionSink sink = sSceneActionSink;
        if (sink == null) {
            return;
        }
        try {
            sink.onSceneAction(viewId, context, action);
        } catch (Throwable error) {
            android.util.Log.w(TAG, "emitSceneAction failed: " + error);
        }
    }
}
