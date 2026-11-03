#include "AndroidMediaSession.h"
#include <QCoreApplication>
#include <QJniObject>
#include <QMetaObject>
#include <QtGlobal>
#ifdef Q_OS_ANDROID
// QNativeInterface::QAndroidApplication 声明在 qcoreapplication_platform.h，
// 由 <QCoreApplication> 在 Android 构建下无条件拉入，不要单独 include 那个不存在的路径。
#include <QFuture>
#include <QtCore/private/qandroidextras_p.h>
#include <jni.h>
#include <utility>

// Java 类与 native 方法一一对应：
//   Qt/android/src/rhine/music/database/RhineMediaService.java
//     start(Context) / update(...) / stop()          ← 这里调过去
//     private static native void mediaAction(String) ← 这里接回来
// JNI 符号名由「Java_包名_类名_方法名」拼出，包名改动必须同步这里。
namespace {
constexpr auto kServiceClass = "rhine/music/database/RhineMediaService";

std::function<void(QString)> &commandSink() {
    static std::function<void(QString)> sink;
    return sink;
}

void startService() {
    const auto context = QNativeInterface::QAndroidApplication::context();
    QJniObject::callStaticMethod<void>(kServiceClass, "start", "(Landroid/content/Context;)V", context);
}

/** POST_NOTIFICATIONS 是 Android 13 起的运行时权限；被拒不阻塞——
 *  通知不显示，但 MediaSession 与耳机按键仍然可用。 */
void requestPermissionThenStart() {
    static bool requested = false;
    if (std::exchange(requested, true)) {
        startService();
        return;
    }
    if (QNativeInterface::QAndroidApplication::sdkVersion() < 33) {
        startService();
        return;
    }
    auto future =
        QtAndroidPrivate::requestPermission(QStringLiteral("android.permission.POST_NOTIFICATIONS"));
    future.then([](QtAndroidPrivate::PermissionResult) { startService(); });
}
} // namespace

void AndroidMediaSession::setCommandCallback(std::function<void(QString)> callback) {
    commandSink() = std::move(callback);
}

void AndroidMediaSession::ensureStarted() {
    requestPermissionThenStart();
}

void AndroidMediaSession::update(bool playing, qint64 positionMs, qint64 durationMs, const QString &title,
                                 const QString &artist, const QString &album, const QString &coverPath) {
    QJniObject::callStaticMethod<void>(
        kServiceClass, "update",
        "(ZJJLjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
        playing ? JNI_TRUE : JNI_FALSE, static_cast<jlong>(positionMs), static_cast<jlong>(durationMs),
        QJniObject::fromString(title).object<jstring>(), QJniObject::fromString(artist).object<jstring>(),
        QJniObject::fromString(album).object<jstring>(), QJniObject::fromString(coverPath).object<jstring>());
}

void AndroidMediaSession::stop() {
    QJniObject::callStaticMethod<void>(kServiceClass, "stop", "()V");
}

/** Java → C++：系统媒体控件的动作。回调发生在 Android 主线程（= Qt 主线程），
 *  仍用 QueuedConnection 推迟到 Qt 事件循环，避免在 JNI 栈上直接改界面状态。 */
extern "C" JNIEXPORT void JNICALL Java_rhine_music_database_RhineMediaService_mediaAction(JNIEnv *env, jclass,
                                                                                          jstring action) {
    Q_UNUSED(env)
    const QString name = QJniObject(action).toString();
    QMetaObject::invokeMethod(
        QCoreApplication::instance(),
        [name] {
            if (auto sink = commandSink()) {
                sink(name);
            }
        },
        Qt::QueuedConnection);
}
#else
// 非 Android 构建不会链接本文件；这里给空实现以便头文件在共享代码里无顾虑地引用。
void AndroidMediaSession::setCommandCallback(std::function<void(QString)> callback) {
    Q_UNUSED(callback)
}
void AndroidMediaSession::ensureStarted() {
}
void AndroidMediaSession::update(bool, qint64, qint64, const QString &, const QString &, const QString &,
                                 const QString &) {
}
void AndroidMediaSession::stop() {
}
#endif
