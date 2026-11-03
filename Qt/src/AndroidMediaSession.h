#pragma once
#include <QString>
#include <functional>

// Android 系统媒体控件（MediaSession + MediaStyle 通知）的 JNI 桥。
// Java 侧是 Qt/android/src/rhine/music/database/RhineMediaService.java，
// 生命周期由这里驱动：ensureStarted() 拉起前台服务，update() 上报状态，stop() 撤下通知。
//
// 动作契约与 iOS 的 MPRemoteCommandCenter 完全一致：
// resume / pause / toggle / next / prev（见 Qt/src/Platform.mm）。
namespace AndroidMediaSession {

/** 注册系统媒体控件的动作回调；由 platformMediaCommands 转发 Host 的回调进来。 */
void setCommandCallback(std::function<void(QString)> callback);

/** 确保前台服务在运行；首次调用会顺带请求通知权限（Android 13+）。 */
void ensureStarted();

/** 上报播放状态与元数据；title 为空或 duration <= 0 表示已清空，撤下通知。 */
void update(bool playing, qint64 positionMs, qint64 durationMs, const QString &title, const QString &artist,
            const QString &album);

/** 播放被清空（切页/退出），撤下通知但保留会话。 */
void stop();

} // namespace AndroidMediaSession
