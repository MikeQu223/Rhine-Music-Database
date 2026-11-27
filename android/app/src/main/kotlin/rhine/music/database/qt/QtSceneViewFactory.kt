package rhine.music.database.qt

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 真实 Qt 场景层的 PlatformView 工厂。
 *
 * 这里注册的是一个**Qt 原生子视图**（QQuickView 挂在宿主 Activity 的窗口上），不是
 * WebView、不是截图、也不是 startActivity 起另一个 Qt 页面：视图的父子关系、触摸事件、
 * 尺寸变化全部走 Qt 自己的 view embedding（见 org.qtproject.qt.android.RhineQtView）。
 */
const val QT_SCENE_VIEW_TYPE = "rhine/qt_scene"

class QtSceneViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        QtSceneView(context, viewId)
}
