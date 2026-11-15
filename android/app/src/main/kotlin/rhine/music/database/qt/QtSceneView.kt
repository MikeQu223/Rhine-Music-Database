package rhine.music.database.qt

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.platform.PlatformView
import org.qtproject.qt.android.RhineQtViews

private const val TAG = "QtSceneView"

/**
 * Flutter 页面里的 Qt 场景视图（PARITY QT-OVERLAY-128）。
 *
 * 结构：
 *   FrameLayout（本类持有，Flutter 的宿主 View）
 *     └─ org.qtproject.qt.android.RhineQtView（QtView 子类，Qt 侧把 QQuickView 的 Java 对端
 *        挂进这个 ViewGroup）
 *
 * 为什么外面的 FrameLayout 是必要的：QtView.onMeasure() 用
 * setMeasuredDimension(resolveSize(maxChild...)) 按子视图测量自身，尺寸为 0 的子视图
 * 会让它退化成 0×0。Flutter 的 hybrid composition 只保证"我给的外框"，外层 FrameLayout
 * 承担 MATCH_PARENT 的约束传递，QtView 才能拿到真实尺寸并让 QQuickView 跟到同样大小。
 *
 * 触摸：hybrid composition 的输入由 Android 自己派发（QtWindow/QtSurface 是真正的
 * SurfaceView 层级），本类不截获、不代传，也不在 Flutter 侧再叠一层相机手势。
 */
class QtSceneView(context: Context, private val viewId: Int) : PlatformView {

    private val root: FrameLayout = FrameLayout(context).apply {
        // Qt 场景自带底色（RhiScene 的 clearColor），宿主保持透明，避免 Flutter 的底色
        // 在首帧之前透过来又被 Qt 再盖一层。
        setBackgroundColor(Color.TRANSPARENT)
        layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
        )
    }

    private var qtView: View? = null

    init {
        // 顺序是契约：RHINE_QT_EMBEDDED 必须在 Qt 运行时加载之前进环境变量。
        // Qt 的 main() 会在 RhineQtViews.create(context) 的父类构造里就跑起来
        // （QtView.loadQtLibraries → QtEmbeddedLoader → startQtApplication），
        // 之后再设 env 就晚了——main() 会走完整 Qt 应用那条路，创建自己的 Window。
        osSetEnv("RHINE_QT_EMBEDDED", "1")

        val view = RhineQtViews.create(context)
        qtView = view
        root.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        Log.i(TAG, "qt scene view created id=$viewId")
    }

    override fun getView(): View = root

    override fun onFlutterViewAttached(flutterView: View) {
        super.onFlutterViewAttached(flutterView)
        // 重新 attach 时不需要重建 Qt 侧：QQuickView 的生命周期跟着 QtView 的
        // onAttachedToWindow/onDetachedFromWindow 走（QtView 自己处理）。
        Log.i(TAG, "qt scene view attached to flutter view id=$viewId")
    }

    override fun dispose() {
        // 先摘子视图：QtView.onDetachedFromWindow 会销毁 QQuickView 并删除父窗口，
        // 这一步必须发生在 FrameLayout 被丢弃之前。
        val child = qtView
        qtView = null
        if (child != null) {
            root.removeView(child)
        }
        root.removeAllViews()
        Log.i(TAG, "qt scene view disposed id=$viewId")
    }

    /**
     * android.system.Os.setenv 是 API 21 起的公开 API；单独包一层只是为了让
     * @SuppressLint 的作用域最小，不引第三方依赖。
     */
    @SuppressLint("NewApi")
    private fun osSetEnv(key: String, value: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                android.system.Os.setenv(key, value, true)
            }
        } catch (error: Throwable) {
            // 设置失败不抛出：Qt 侧 requested() 读不到就退回整窗口模式，
            // 页面里会显示宿主自己的说明，而不是崩溃。
            Log.w(TAG, "could not set $key for the Qt scene", error)
        }
    }
}
