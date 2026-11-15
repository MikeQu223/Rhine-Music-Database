#include "EmbeddedSceneHost.h"

#include "Engine.h"
#include "FrameProfiler.h"
#include "NativeScene.h"

#include <QCoreApplication>
#include <QDebug>
#include <QGuiApplication>
#include <QThread>
#include <QMutexLocker>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
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

namespace {
// 最近一份来自 Flutter 的快照。平台视图可能在 qApp 建好之前就发首帧（QtThread 是异步
// 起的），那时 invokeMethod 会被静默丢掉；而 Dart 侧按 viewId 去重，同一份快照不会再发。
// 所以这里留一份，等场景真正就绪（createSceneView 末尾）再自应用一次。
QMutex g_pendingMutex;
QString g_pendingState;
QString g_appliedMode;
int g_appliedIndex = -2;
int g_appliedDark = -1;
QString g_appliedKey;
} // namespace

void rememberState(const QString &json)
{
    QMutexLocker lock(&g_pendingMutex);
    g_pendingState = json;
}

bool reapplyPendingState()
{
    QString pending;
    {
        QMutexLocker lock(&g_pendingMutex);
        pending = g_pendingState;
    }
    if (pending.isEmpty())
        return false;
    applySceneState(pending);
    return true;
}

void resetAppliedState()
{
    g_appliedMode.clear();
    g_appliedIndex = -2;
    g_appliedDark = -1;
    g_appliedKey.clear();
}

// pointerdown 时只清选中相关：Qt 自己的 NativeSceneInput 可能在这一轮里改了选中，之后
// Flutter 若推来同一份快照必须允许它重新应用，否则高亮与选中会长期漂移。
// 刻意不动 g_appliedMode/g_appliedDark——清掉它们会让下一份快照重跑 setMode()/theme()，
// 而这两个调用都会 reset 指针与动画，等于在手指还按着的瞬间把场景跳一下。
void resetSelectionState()
{
    g_appliedIndex = -2;
    g_appliedKey.clear();
}

void applySceneState(const QString &json)
{
    Engine *engine = g_engine;
    if (!engine) {
        // 还没 publish()/场景还没建：payload 已在 rememberState() 落盘，由
        // createSceneView() 末尾的 reapplyPendingState() 补上。别删那段 replay，
        // 否则首帧快照会重新变成静默丢失。
        qWarning("RHINE_QT_SCENE_STATE ignored: no engine");
        return;
    }
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(json.toUtf8(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) {
        qWarning().noquote() << "RHINE_QT_SCENE_STATE bad json:" << error.errorString();
        return;
    }
    const QJsonObject payload = document.object();
    NativeScene &scene = engine->scene;

    // 逐项比对再应用：Qt 侧 setMode/select 都会 reset 指针与动画，重复应用会把正在
    // 进行的拖拽/旋转打断——这也是"手指还在屏幕上场景却跳一下"的来源。
    // 去重状态是命名空间级的（g_applied*），因为 destroySceneView() 要能清它。
    bool applied = false;

    const QString mode = payload.value("mode").toString();
    if (!mode.isEmpty() && mode != g_appliedMode) {
        g_appliedMode = mode;
        scene.setMode(mode);
        applied = true;
    }

    const bool dark = payload.value("dark").toBool(false);
    if (int(dark) != g_appliedDark) {
        g_appliedDark = int(dark);
        scene.theme(dark);
        applied = true;
    }

    // index 是 Flutter 列表行号；Qt 归档是 5 列 × 8 槽、索引域 0..39。
    // 行号 >39 时**不取模映射**：那会把第 41 行的歌高亮到第 1 行卡片上，而 key 指向的
    // 却是另一首歌（高亮与封面身份互相矛盾）。此时只换封面身份，不动选中。
    const int index = payload.value("index").toInt(-1);
    if (index >= 0 && index != g_appliedIndex) {
        g_appliedIndex = index;
        if (index < 40) {
            scene.select(index);
            applied = true;
        } else {
            qInfo("RHINE_QT_SCENE_STATE index %d beyond archive domain (40): selection untouched",
                  index);
        }
    }

    if (payload.contains("key")) {
        const QString key = payload.value("key").toString();
        if (key != g_appliedKey) {
            g_appliedKey = key;
            if (key.isEmpty())
                scene.musicClear();
            else
                scene.musicIdentity(key);
            applied = true;
        }
    } else if (!g_appliedKey.isEmpty()) {
        // 没有选中就不带 key：清掉上一首的封面/材质身份，避免"打开一首歌的唱片
        // 再返回列表后列表还在显示那张封面"。
        g_appliedKey.clear();
        scene.musicClear();
        applied = true;
    }

    // 只在真的改变了场景时打（S3）：否则每次重连都刷一条全量快照，日志里分不清"收到"
    // 与"应用"。
    if (applied) {
        qInfo("RHINE_QT_SCENE_STATE v=%d mode=%s dark=%d index=%d count=%d key=%s",
              payload.value("v").toInt(0), qPrintable(g_appliedMode), g_appliedDark, index,
              payload.value("count").toInt(0), qPrintable(g_appliedKey));
    }
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
        return; // 二次排队 destroy 在这里早退，也就跳过了下面的 resetAppliedState()；
                // 无害（第一次已经清过），但改动这里的顺序时要记得这条依赖。
    // 去重状态跟着场景一起清（S5）：同进程若重建 Engine（RhineQtViews 的 sRuntimeTornDown
    // 路径），残留的 applied* 会让新场景永远收不到快照。
    RhineEmbedded::resetAppliedState();
    QQuickView *view = g_sceneView.data();
    g_sceneView.clear();
    // 先让内核停手再拆窗口：隐藏期间不创建 GPU 资源，也不再有 resize/setVisible 打到将死的窗口上。
    if (Engine *engine = RhineEmbedded::engine()) {
        engine->setVisible(false);
        engine->setWindow(nullptr);
    }
    view->hide();
    view->deleteLater();
    // 同步把 DeferredDelete 排空：调用方（Java 的 onDetachedFromWindow）返回后 Android 就可能
    // 释放 Surface，如果 QQuickWindow 还活着，渲染线程会在已销毁的 mutex 上 queueBuffer
    // （真机 Abort: "FORTIFY: pthread_mutex_lock called on a destroyed mutex"，栈经
    //  Surface::hook_queueBuffer ← QueuePresentKHR ← QRhi::endFrame）。这里就地析构，
    // QQuickWindow 的析构会与渲染线程同步，返回值即代表窗口已不存在。
    // 只排空这一个窗口的事件：进程级 flush 会把别人的 DeferredDelete 也提前执行。
    QCoreApplication::sendPostedEvents(view, QEvent::DeferredDelete);
    qInfo("RHINE_QT_EMBEDDED_SCENE_DESTROYED");
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
        // 拾取选中回传 Flutter 的通道已经接好（RhineQtViews.emitSceneAction →
        // MethodChannel('rhine.music/qt_scene').action → QtSceneActions.onAction），
        // 但**暂时不发**任何动作：场景里的槽位来自 Assets/android-3d/slots.json 的
        // 40 条占位记录（columns = 搜索结果/喜欢的歌曲/我的歌单/收藏歌单/收藏专辑，
        // records 全是 "音乐槽位"），没有 Siren 曲目身份，而曲库权威在 Flutter。
        // 早先发 "music:index:<i>" 会被 HUD 当成列表下标（basic_app.dart 的
        // music:index 分支），越界就弹“预览中尚未实现”，属于假映射。
        // 真正的动作词表等 lead / 133 定（需要能表达“归档槽位”而不是曲目下标）。
        Q_UNUSED(engine);
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
    // 场景就绪后补应用最后一份快照（M1：首帧可能早于 qApp，被 invokeMethod 丢掉）。
    if (RhineEmbedded::reapplyPendingState())
        qInfo("RHINE_QT_SCENE_STATE replayed on scene ready");
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
    // 不能阻塞：这条 JNI 会被 Java 的 UI 线程调用（视图摘除 / 宿主销毁），而 Qt 的
    // Android QPA 在执行 UI 线程动作时是"Qt 线程等 UI 线程"的方向。UI 线程在这里
    // BlockingQueuedConnection 等 Qt 线程 = 双向等待死锁（真机表现：Activity 销毁后
    // 一声不响地挂住，随后输入派发超时被系统按 ANR 杀掉）。
    // 改成排队执行，但**先同步停掉渲染**：SIGABRT
    // "FORTIFY: pthread_mutex_lock called on a destroyed mutex" 是 QQuickWindow 在
    // Surface 已释放后还 present 造成的，所以禁止 presenting 必须在拆 Surface 之前发生。
    if (!qApp)
        return;
    if (QThread::currentThread() == qApp->thread()) {
        destroySceneView();
        return;
    }
    // 注意：这里**不碰 Engine**。Engine::setVisible 会 flush 指针、发 pointercancel、
    // 停定时器、emit stateChanged()，全都没有锁；从 Java 的 UI 线程直接调就是和 Qt 主
    // 线程/渲染线程抢同一批状态。整件销毁动作都在 Qt 线程上按序做（隐藏窗口 →
    // destroySceneView 里的 engine->setVisible(false) → 拆视图）。
    QMetaObject::invokeMethod(qApp, [] {
        if (QQuickWindow *window = qobject_cast<QQuickWindow *>(g_sceneView.data()))
            window->setVisible(false);
        destroySceneView();
    }, Qt::QueuedConnection);
}

// Flutter → Kotlin(PlatformView) → RhineQtViews.pushSceneState → 这里。
// 入口在 Flutter platform thread，必须切回 Qt 主线程再碰场景。
extern "C" JNIEXPORT jboolean JNICALL
Java_org_qtproject_qt_android_RhineQtViews_nativePushSceneState(JNIEnv *env, jclass, jstring json)
{
    if (!env || !json)
        return JNI_FALSE;
    const char *raw = env->GetStringUTFChars(json, nullptr);
    if (!raw)
        return JNI_FALSE;
    const QString payload = QString::fromUtf8(raw);
    env->ReleaseStringUTFChars(json, raw);
    // 先落盘再投递：即使此刻 qApp 还没建好（首帧竞态）也不会丢，场景就绪时会自应用。
    RhineEmbedded::rememberState(payload);
    if (!qApp)
        return JNI_TRUE; // 已受理（缓存），就绪后补
    QMetaObject::invokeMethod(
        qApp, [payload] { RhineEmbedded::applySceneState(payload); }, Qt::QueuedConnection);
    return JNI_TRUE;
}

// Flutter 搬运来的原始指针事件：只做线程切换 + 直通 Engine::pointer。
// 手势语义（归档拖拽 / 唱片旋转 / 选中 / momentum）完全由 Qt 的
// NativeSceneInput 决定，这里不加任何判断，也不做坐标换算（调用方给的是舞台单位）。
extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtViews_nativePushScenePointer(
    JNIEnv *env, jclass, jstring type, jdouble x, jdouble y)
{
    if (!env || !type)
        return;
    const char *raw = env->GetStringUTFChars(type, nullptr);
    if (!raw)
        return;
    const QString eventType = QString::fromUtf8(raw);
    env->ReleaseStringUTFChars(type, raw);
    if (!qApp)
        return;
    QMetaObject::invokeMethod(
        qApp,
        [eventType, sx = static_cast<double>(x), sy = static_cast<double>(y)] {
            // 手指落下时清掉选中相关的"已应用"记录（S3）；只清 index/key，
            // 不清 mode/dark——见 resetSelectionState() 的注释。
            if (eventType == QLatin1String("pointerdown"))
                RhineEmbedded::resetSelectionState();
            if (Engine *engine = RhineEmbedded::engine())
                engine->pointer(eventType, sx, sy);
        },
        Qt::AutoConnection);
}

// 双指缩放搬运：走 Engine::wheelInput 的 pixelDelta 通路（与 Overlay.qml 的
// PinchHandler 同一个入口），angleDelta 记 0。
extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtViews_nativePushSceneWheel(
    JNIEnv *, jclass, jdouble x, jdouble y, jdouble delta)
{
    if (!qApp)
        return;
    QMetaObject::invokeMethod(
        qApp,
        [sx = static_cast<double>(x), sy = static_cast<double>(y),
         sd = static_cast<double>(delta)] {
            if (Engine *engine = RhineEmbedded::engine())
                engine->wheelInput(sx, sy, sd, 0);
        },
        Qt::AutoConnection);
}
#endif // Q_OS_ANDROID
