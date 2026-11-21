#pragma once

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
void start(bool playbackService = false);
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
void playbackFailure();
void renderSettings(QStringView backend);
void renderDevice(QStringView backend, quint64 vendorId, quint64 deviceId, int deviceType,
                  QStringView appleModel);
void audioBackend(AudioBackend backend);
void pluginVersions();
void diagnose(bool allowCaptureStart, DiagnosticCallback callback);

}
