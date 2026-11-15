#include "EmbeddedSceneHost.h"

#include "Engine.h"
#include "FrameProfiler.h"

#include <QCoreApplication>
#include <QDebug>
#include <QGuiApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickView>
#include <QQuickWindow>

#if defined(Q_OS_ANDROID)
#include <QJniEnvironment>
#include <QJniObject>
#include <QPointer>
#include <QtCore/qcoreapplication.h>
#include <jni.h>
#endif

namespace {
Engine *g_engine = nullptr;
FrameProfiler *g_profiler = nullptr;
QString g_fontFamily = QStringLiteral("sans-serif");
} // namespace

namespace RhineEmbedded {

bool requested()
{
    return qEnvironmentVariableIntValue("RHINE_QT_EMBEDDED") == 1;
}

void publish(Engine *engine, FrameProfiler *profiler, const QString &fontFamily)
{
    g_engine = engine;
    g_profiler = profiler;
    g_fontFamily = fontFamily;
}

Engine *engine()
{
    return g_engine;
}

FrameProfiler *profiler()
{
    return g_profiler;
}

QString fontFamily()
{
    return g_fontFamily;
}

} // namespace RhineEmbedded

#if defined(Q_OS_ANDROID)
namespace {
// 只保留最近一次创建的场景视图：重复挂载（PlatformView 重建）时先销毁旧的，
// 避免同一进程里堆出第二个场景/第二套事件循环。
QPointer<QQuickView> g_sceneView;

void destroySceneView()
{
    if (!g_sceneView)
        return;
    QQuickView *view = g_sceneView.data();
    g_sceneView.clear();
    // 先让内核停手再拆窗口：隐藏期间不创建 GPU 资源，也不再有 resize/setVisible 打到将死的窗口上。
    if (Engine *engine = RhineEmbedded::engine()) {
        engine->setVisible(false);
        engine->setWindow(nullptr);
    }
    view->hide();
    view->deleteLater();
}

void createSceneView(const QJniObject &javaView, jlong parentWindowReference, jint width, jint height)
{
    auto *parentWindow = reinterpret_cast<QWindow *>(parentWindowReference);
    if (!parentWindow) {
        qWarning("RHINE_QT_EMBEDDED: null parent window");
        return;
    }
    destroySceneView();

    auto *view = new QQuickView(parentWindow);
    g_sceneView = view;
    view->setResizeMode(QQuickView::SizeRootObjectToView);
    view->setColor(QColor(Qt::transparent));
    view->setWidth(width);
    view->setHeight(height);
    // 尺寸变化（旋转/分屏/键盘）不重建图形设备和场景缓存，场景状态留在原处。
    view->setPersistentSceneGraph(true);
    view->setPersistentGraphics(true);

    QQmlEngine *engine = view->engine();
    engine->rootContext()->setContextProperty(QStringLiteral("rhineFontFamily"), RhineEmbedded::fontFamily());
    engine->rootContext()->setContextProperty(QStringLiteral("rhine"), RhineEmbedded::engine());
    engine->rootContext()->setContextProperty(QStringLiteral("profiler"), RhineEmbedded::profiler());
    QObject::connect(engine, &QQmlEngine::quit, QCoreApplication::instance(), &QCoreApplication::quit);

    // Qt 自己的 QtQuickView 就是把子窗口的 Java QtWindow 交给 QtView.addQtWindow；
    // 这里沿用同一条路：把 winId()（QAndroidPlatformWindow 里就是 QtWindow jobject）
    // 连同视图指针和父窗口一起交给 Java 侧的 QtView。
    if (Engine *engine = RhineEmbedded::engine()) {
        engine->setWindow(view);
        view->installEventFilter(engine);
    }
    if (RhineEmbedded::profiler())
        RhineEmbedded::profiler()->attach(view);

    QJniEnvironment env;
    jclass viewClass = env->GetObjectClass(javaView.object());
    jmethodID addQtWindow = env->GetMethodID(viewClass, "addQtWindow",
                                             "(Lorg/qtproject/qt/android/QtWindow;JJ)V");
    if (!addQtWindow) {
        qWarning("RHINE_QT_EMBEDDED: QtView.addQtWindow not found");
        env->DeleteLocalRef(viewClass);
        return;
    }
    env->CallVoidMethod(javaView.object(), addQtWindow, reinterpret_cast<jobject>(view->winId()),
                        static_cast<jlong>(reinterpret_cast<qintptr>(view)), parentWindowReference);
    env->DeleteLocalRef(viewClass);
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        qWarning("RHINE_QT_EMBEDDED: addQtWindow threw");
        return;
    }

    view->loadFromModule(QStringLiteral("RhineMusic"), QStringLiteral("Embedded"));
    if (view->status() == QQuickView::Error) {
        for (const auto &error : view->errors())
            qWarning().noquote() << "RHINE_QT_EMBEDDED qml:" << error.toString();
    } else if (Engine *engine = RhineEmbedded::engine()) {
        // Embedded.qml 的 Component.onCompleted 也会 setVisible(true)；这里再确认一次，
        // 免得视图被销毁重建后内核停在被上一次 destroySceneView 设成的隐藏状态。
        engine->setVisible(true);
    }
    qInfo("RHINE_QT_EMBEDDED_SCENE_READY %dx%d", int(width), int(height));
}
} // namespace

extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtView_createEmbeddedScene(JNIEnv *env, jobject thiz,
                                                             jlong parentWindowReference, jint width,
                                                             jint height)
{
    if (!env || !thiz)
        return;
    // QJniObject 持全局引用，可以安全地跨线程（Qt 主线程）传递。
    const QJniObject javaView(thiz);
    QMetaObject::invokeMethod(
        qApp,
        [javaView, parentWindowReference, width, height] {
            createSceneView(javaView, parentWindowReference, width, height);
        },
        Qt::AutoConnection);
}

extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtView_destroyEmbeddedScene(JNIEnv *, jobject)
{
    QMetaObject::invokeMethod(qApp, [] { destroySceneView(); }, Qt::AutoConnection);
}
#endif // Q_OS_ANDROID
