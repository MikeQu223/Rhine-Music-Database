#pragma once

#include "SentryPlaybackFailure.h"
#include "SentryPluginTelemetry.h"
#include "SentryRenderTelemetry.h"
#include <QString>
#include <QStringView>
#include <functional>

namespace RhineSentry {

inline constexpr auto ConsentKey = "sentry-consent";
inline constexpr auto DisabledPreference = "off";

enum class AudioBackend {
    SeparateProcess,
    QtMultimedia,
    QtFfmpeg,
    Apple,
    WindowsTransition
};

enum class PlaybackAction {
    Play,
    Resume,
    Pause,
    Next,
    Previous
};

struct DiagnosticResult {
    bool connected = false;
    bool captureActive = false;
    bool captureStarted = false;
    int statusCode = 0;
    QString eventId;
    QString error;
    QString activationError;
};

using DiagnosticCallback = std::function<void(DiagnosticResult)>;

bool configured();
QString newConsent();
QString preference();
bool preferenceEnabled(QStringView value);
bool savePreference(const QString &value);
bool active();
bool ownsCrashHandler();
/** verificationMode 仅用于隔离验证，跳过 SDK 重复授权闸门。
 *  应用级授权仍由调用方保证。 */
void start(bool playbackService = false, bool verificationMode = false);
void stop();
void revoke();
void foreground();
void playbackActive();
void playbackAction(PlaybackAction action);
void startup(qint64 milliseconds);
void *beginPlaybackPreparation();
void finishPlaybackPreparation(void *trace, bool prepared);
void page(QStringView mode, QStringView modal, bool lyrics, bool comments, bool viewer);
void action(QStringView value);
void playbackFailure(const PlaybackFailure &failure);
void pluginInstallFailure(const PluginInstallFailure &failure);
void pluginInstallEvent(QStringView value);
void pluginInstallContext(const PluginInstallFailure &failure);
void renderEvent(QStringView value);
void renderContext(const RenderTelemetryState &state);
void renderSettings(QStringView backend);
void renderDevice(QStringView backend, quint64 vendorId, quint64 deviceId, int deviceType,
                  QStringView appleModel);
void audioBackend(AudioBackend backend);
void pluginVersions();
void diagnose(bool allowCaptureStart, DiagnosticCallback callback);

}
