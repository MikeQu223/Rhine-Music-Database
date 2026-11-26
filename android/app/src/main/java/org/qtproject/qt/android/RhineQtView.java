package org.qtproject.qt.android;

import android.content.Context;

/**
 * Flutter 内嵌路径上的 Qt 场景视图。
 *
 * 为什么必须是这个包里的类：Qt 的 `QtView` 与它的 `addQtWindow(QtWindow, long, long)`
 * 都是包内可见（third_party/qt/qtbase/src/android/jar/src/org/qtproject/qt/android/QtView.java）。
 * 只有同包子类才能复用 Qt 自己的内嵌机制——父窗口由 Qt 的 `createRootWindow` 送进来，
 * `addQtWindow` 把 QQuickView 的 Java 对端（QtWindow）挂进这个 ViewGroup。换包就只能
 * 自己拼一套 SurfaceView，那等于绕开 Qt 的平台适配，这里不做。
 *
 * 与 Qt 自带 `QtQuickView` 的差异只有一处：`createWindow` 不调用 Qt 的
 * `createQuickView`（它硬编码 qmlUri 且 QAndroidQuickView 没有导出符号），而是回调本库
 * 自己导出的 JNI：`Qt/src/EmbeddedSceneHost.cpp` 在 Qt 主线程上创建 QQuickView、注入
 * rhine/profiler 上下文属性，再调用同一个 `addQtWindow`。场景内容因此仍然是 Qt 原实现
 * （RhiScene 材质/相机/归档布局/触摸都在 Qt 侧），Flutter 只是提供了一个宿主父窗口。
 *
 * 生命周期：视图摘下时先销毁 QQuickView（destroyEmbeddedScene），再由 QtView
 * 的 onDetachedFromWindow 删除父窗口，顺序与 Qt 自己的实现一致。
 */
public class RhineQtView extends QtView {
    /**
     * @param context 宿主 Activity（FlutterActivity）。Qt 的 QtEmbeddedLoader 要求
     *                Context.getBaseContext() 是 Activity 或 Service，否则拒绝启动。
     */
    public RhineQtView(Context context) {
        // 主库名与 Qt/CMakeLists.txt 的 qt_add_executable(RhineMusicDatabase ...) 一致；
        // QtLoader 会按 ABI 拼成 libRhineMusicDatabase_arm64-v8a.so 再加载并进入 main()。
        super(context, "RhineMusicDatabase");
    }

    /** createWindow 已经进来过一次：同一次布局里 Qt 会连发多个根窗口请求，只认第一个。 */
    private boolean sceneRequested = false;

    /**
     * 本次 create 请求的场景世代号（0 = 还没有活着的场景请求）。
     *
     * 为什么需要：一个进程里只有一个嵌入场景，而"旧宿主的 destroy 晚到"会把新宿主刚建好
     * 的场景拆掉（Flutter 侧 Activity 重建时 PlatformView 的 dispose 与新 create 没有
     * 跨端顺序保证）。原生侧按这个号比对，晚到的旧 destroy 会整段跳过。号由
     * {@link RhineQtViews#nextSceneGeneration()} 在**每次 create 请求时**分配（不是在构造
     * 时），保证"建的顺序 = 号的顺序"，也与本视图自己的 destroy 用的是同一个号。
     */
    private long sceneGeneration = 0;

    @Override
    protected void createWindow(final long parentWindowRef) {
        // 由 Qt 的 createRootWindow 在 Qt 线程上回调（QtEmbeddedDelegate 在 onAttachedToWindow
        // 之后 runAction）；parentWindowRef 是宿主 View 的 QWindow（QWindow::fromWinId）。
        //
        // 两个坑都在这一行里：
        // 1. 回调可能早于首帧 layout，此时 getWidth()/getHeight() 是 0×0；而 QtView 的
        //    OnLayoutChangeListener 在 m_windowReference == 0 时直接跳过，等 addQtWindow
        //    置位之后 bounds 往往不再变化，Qt 不会再收到一次 resizeWindow —— 场景会一直
        //    保持 0 尺寸，直到旋转/软键盘等真正改变尺寸。所以量不到尺寸就 post 到 UI 线程
        //    等一次布局完成再建场景。
        // 2. 下面这两个读取只当"是否已经布局"的提示用（0 就是还没布局）；真正要用的尺寸
        //    在 post 出去的 Runnable 里、在 UI 线程上重新取一次。
        if (sceneRequested) {
            // 同一轮布局里 Qt 会重复请求同一个父窗口；重复 createEmbeddedScene 会再建一个
            // QQuickView（连带一份 RHI 上下文），所以只认第一次。
            return;
        }
        sceneRequested = true;
        // 号在"发起请求"这一刻分配：即使下面因为没布局把这帧放弃、之后重挂再来一次，
        // 每一次请求仍然各有一个严格递增的号（原生侧只 adopt 更大的号）。
        final long generation = sceneGeneration = RhineQtViews.nextSceneGeneration();
        final int width = getWidth();
        final int height = getHeight();
        if (width <= 0 || height <= 0) {
            post(new Runnable() {
                @Override
                public void run() {
                    // 等布局的这一帧里视图可能已经被摘下（例如页面立刻切走）。
                    // 此时父窗口正在销毁，再挂 QQuickView 会往死掉的 ViewGroup 里 addView；
                    // 真重挂时 Qt 自己会再回调一次 createWindow，这里直接放弃即可。
                    if (!isAttachedToWindow()) {
                        // 这一帧没建起来：允许重挂时再来一次。
                        sceneRequested = false;
                        return;
                    }
                    createEmbeddedScene(parentWindowRef, getWidth(), getHeight(), generation);
                }
            });
            return;
        }
        createEmbeddedScene(parentWindowRef, width, height, generation);
    }

    /**
     * 宿主 Activity 销毁时由 {@link RhineQtViews} 显式调用。
     *
     * PlatformView 不一定立刻 dispose，残留的 QtWindow 会继续注册输入窗口，
     * 下一个 Activity 拿不到焦点，输入派发超时后整进程被 ANR 杀掉。
     * 这里只摘场景窗口，运行时仍跨 Activity 存活；destroyEmbeddedScene 是排队执行。
     */
    public void releaseSceneForHostDestroy() {
        if (!sceneRequested) {
            return;
        }
        // 允许新宿主重挂时再走一次 createWindow。
        sceneRequested = false;
        retireScene();
    }

    @Override
    protected void onDetachedFromWindow() {
        sceneRequested = false;
        retireScene();
        super.onDetachedFromWindow();
    }

    /**
     * 只拆"自己这一代"场景。
     *
     * sceneGeneration == 0 表示本视图没有活着的场景请求（从没创建成功，或已经拆过），
     * 这时**不发** destroy：原生侧把 0 当成"内部无条件拆"，发出去就会拆掉另一个宿主刚
     * 建好的场景——旧宿主的 onDetachedFromWindow 晚到正是这条路径（进程里只有一个场景）。
     */
    private void retireScene() {
        final long generation = sceneGeneration;
        if (generation == 0) {
            return;
        }
        sceneGeneration = 0;
        destroyEmbeddedScene(generation);
    }

    private native void createEmbeddedScene(long parentWindowRef, int width, int height,
                                            long sceneGeneration);

    private native void destroyEmbeddedScene(long sceneGeneration);
}
