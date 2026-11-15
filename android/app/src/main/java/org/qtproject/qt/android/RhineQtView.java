package org.qtproject.qt.android;

import android.content.Context;

/**
 * Flutter 内嵌路径上的 Qt 场景视图（PARITY QT-OVERLAY-128）。
 *
 * 为什么必须是这个包里的类：Qt 的 `QtView` 与它的 `addQtWindow(QtWindow, long, long)`
 * 都是包内可见（third_party/qt/qtbase/src/android/jar/src/org/qtproject/qt/android/QtView.java）。
 * 只有同包子类才能复用 Qt 自己的内嵌机制——父窗口由 Qt 的 `createRootWindow` 送进来，
 * `addQtWindow` 把 QQuickView 的 Java 对端（QtWindow）挂进这个 ViewGroup。换包就只能
 * 自己拼一套 SurfaceView，那等于绕开 Qt 的平台适配，本卡不做。
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
                    createEmbeddedScene(parentWindowRef, getWidth(), getHeight());
                }
            });
            return;
        }
        createEmbeddedScene(parentWindowRef, width, height);
    }

    @Override
    protected void onDetachedFromWindow() {
        sceneRequested = false;
        destroyEmbeddedScene();
        super.onDetachedFromWindow();
    }

    private native void createEmbeddedScene(long parentWindowRef, int width, int height);

    private native void destroyEmbeddedScene();
}
