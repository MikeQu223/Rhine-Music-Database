#include "UiSoundFeedback.h"
#include "Host.h"
#include "MusicPlayer.h"
#include "PlaybackConnection.h"
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
#include "UiSoundOutputApple.h"
#elif defined(Q_OS_WIN)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mmsystem.h>
#endif
#include <QDeadlineTimer>
#include <QFile>
#include <QGuiApplication>
#include <QPointer>
#include <QRandomGenerator>
#include <QScopeGuard>
#include <QTimer>
#include <array>
#include <atomic>

namespace {
constexpr int MinimumCueIntervalMs = 52;
constexpr int CueExpiryMs = 55;
// 页面开合优先于资料库选中声，留出 261 ms 音频及线程调度的时间。
constexpr int SurfaceQuietMs = 280;
// 两段语音最长 1090 ms，期间保留单声道反馈优先权。
constexpr int StartupQuietMs = 1110;
enum class Clip { Selection, Surface, StartupVoice1, StartupVoice2, Count };
constexpr std::array CueFiles{"archive-select.wav", "window-transition.wav",
                              "startup-voice-1.wav", "startup-voice-2.wav"};
static_assert(CueFiles.size() == size_t(Clip::Count));
}

class UiSoundFeedback::Output : public QObject {
  public:
    ~Output() override {
        stop();
    }

    void preload() {
        for (size_t index = 0; index < CueFiles.size(); ++index) {
            QFile wave(QStringLiteral(":/ui-audio/") + QLatin1String(CueFiles[index]));
            if (!wave.open(QIODevice::ReadOnly)) {
                continue;
            }
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
            m_native.load(index, wave.readAll());
#elif defined(Q_OS_WIN)
            m_waves[index] = wave.readAll();
#endif
        }
    }

    void play(Clip clip) {
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
        m_native.play(size_t(clip));
#elif defined(Q_OS_WIN)
        const auto &wave = m_waves[size_t(clip)];
        if (!wave.isEmpty()) {
            // 异步输出期间系统持有 WAV 指针，由线程在退出前停止并保留缓冲区。
            PlaySoundA(wave.constData(), nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
        }
#else
        Q_UNUSED(clip);
#endif
    }

    void stop() {
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
        m_native.stop();
#elif defined(Q_OS_WIN)
        PlaySoundA(nullptr, nullptr, 0);
#endif
    }

    // GUI 用代数作废待播事件；同时最多保留一个待处理的音效请求。
    std::atomic<quint64> generation{0};
    std::atomic<bool> pending{false};

  private:
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    UiSoundOutputApple m_native{CueFiles.size()};
#elif defined(Q_OS_WIN)
    std::array<QByteArray, CueFiles.size()> m_waves;
#endif
};

UiSoundFeedback::UiSoundFeedback(Host *host, MusicPlayer *player, QObject *parent)
    : QObject(parent), m_host(host), m_player(player) {
    connect(host, &Host::preferenceChanged, this, [this](const QString &key, const QString &value) {
        if (key == "ui-sounds") {
            m_preferenceKnown = true;
            m_enabled = value != "off";
            updateAvailability();
        }
    });
    connect(player, &MusicPlayer::playbackStarting, this, &UiSoundFeedback::cancel);
    if (auto *connection = host->playbackConnection()) {
        // 连接已更新快照时立即取消，避免等待 GUI 播放器的排队同步。
        connect(connection, &PlaybackConnection::snapshotChanged, this, &UiSoundFeedback::updateAvailability);
    } else {
        connect(host, &Host::mediaChanged, this, &UiSoundFeedback::updateAvailability);
        connect(player, &MusicPlayer::loadingChanged, this, &UiSoundFeedback::updateAvailability);
    }
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, &UiSoundFeedback::updateAvailability);
    // 离开应用构造路径后再读偏好，预载始终交给音效线程。
    QTimer::singleShot(0, this, [this] {
        m_host->readPreferenceAsync("ui-sounds", [owner = QPointer(this)](const QString &value) {
            if (owner && !owner->m_preferenceKnown) {
                owner->m_preferenceKnown = true;
                owner->m_enabled = value != "off";
                owner->updateAvailability();
            }
        });
    });
}

UiSoundFeedback::~UiSoundFeedback() {
    m_thread.quit();
    m_thread.wait();
}

bool UiSoundFeedback::isMusicBusy() const {
    return (!m_host->playbackConnection() && m_player->isPreparingPlayback()) ||
           m_host->isMusicPlaybackRequested();
}

void UiSoundFeedback::updateAvailability() {
    const bool allowed = m_enabled && qGuiApp->applicationState() == Qt::ApplicationActive && !isMusicBusy();
    if (m_allowed != allowed) {
        m_allowed = allowed;
        if (!allowed) {
            stopOutput();
        } else if (!m_output) {
            m_output = new Output;
            m_output->moveToThread(&m_thread);
            connect(&m_thread, &QThread::started, m_output, &Output::preload);
            connect(&m_thread, &QThread::finished, m_output, &QObject::deleteLater);
            m_thread.setObjectName(QStringLiteral("RhineUiAudio"));
            m_thread.start();
        }
    }
    tryPlayStartup();
}

void UiSoundFeedback::cancel() {
    m_startupPending = false;
    stopOutput();
}

void UiSoundFeedback::stopOutput() {
    m_startupQuietUntil = {};
    if (m_output) {
        ++m_output->generation;
        QMetaObject::invokeMethod(m_output, &Output::stop, Qt::QueuedConnection);
    }
}

void UiSoundFeedback::observeSelection(const QString &key, bool inArchive) {
    if (key == m_selectedKey) {
        return;
    }
    const bool hadSelection = !m_selectedKey.isEmpty();
    m_selectedKey = key;
    if (inArchive && hadSelection && !key.isEmpty()) {
        play(Cue::Selection);
    }
}

void UiSoundFeedback::playSurface(bool opened) {
    play(opened ? Cue::SurfaceOpen : Cue::SurfaceClose);
}

void UiSoundFeedback::playStartup() {
    m_startupPending = true;
    tryPlayStartup();
}

/** 等待偏好和前台就绪；若排队后短暂失活，在前台恢复时重试未交付的语音。 */
void UiSoundFeedback::tryPlayStartup() {
    if (!m_startupPending) {
        return;
    }
    if ((m_preferenceKnown && !m_enabled) || isMusicBusy()) {
        m_startupPending = false;
        return;
    }
    if (!m_allowed || m_startupQueued) {
        return;
    }
    m_startupQueued = true;
    const auto generation = ++m_output->generation;
    QMetaObject::invokeMethod(
        m_output,
        [this, output = m_output, generation] {
            const bool submitted = output->generation.load() == generation;
            if (submitted) {
                const bool useFirstVoice = QRandomGenerator::global()->bounded(2) == 0;
                output->play(useFirstVoice ? Clip::StartupVoice1 : Clip::StartupVoice2);
            }
            // 析构会等待音效线程退出，回执在 GUI 线程处理并随接收对象销毁。
            QMetaObject::invokeMethod(
                this,
                [this, output, generation, submitted] {
                    m_startupQueued = false;
                    if (submitted) {
                        m_startupPending = false;
                        if (output->generation.load() == generation) {
                            m_startupQuietUntil = QDeadlineTimer(StartupQuietMs, Qt::PreciseTimer);
                        }
                    }
                    tryPlayStartup();
                },
                Qt::QueuedConnection);
        },
        Qt::QueuedConnection);
}

/** 提交一次短音效。超频、过期或尚未预载完成的反馈直接丢弃。 */
void UiSoundFeedback::play(Cue cue) {
    if (!m_allowed || m_startupQueued || !m_startupQuietUntil.hasExpired()) {
        return;
    }
    const bool isSelection = cue == Cue::Selection;
    if (isSelection) {
        if ((m_lastSurfaceCue.isValid() && m_lastSurfaceCue.elapsed() < SurfaceQuietMs) ||
            (m_lastCue.isValid() && m_lastCue.elapsed() < MinimumCueIntervalMs) ||
            m_output->pending.exchange(true)) {
            return;
        }
        m_lastCue.start();
    } else {
        if (cue == m_lastSurface && m_lastSurfaceCue.isValid() &&
            m_lastSurfaceCue.elapsed() < MinimumCueIntervalMs) {
            return;
        }
        m_lastSurface = cue;
        m_lastSurfaceCue.start();
        ++m_output->generation;
    }
    const auto clip = isSelection ? Clip::Selection : Clip::Surface;
    const auto generation = m_output->generation.load();
    const QDeadlineTimer expiry(CueExpiryMs, Qt::PreciseTimer);
    QMetaObject::invokeMethod(
        m_output,
        [output = m_output, clip, isSelection, generation, expiry] {
            const auto clearPending = qScopeGuard([output, isSelection] {
                if (isSelection) {
                    output->pending.store(false);
                }
            });
            if (output->generation.load() == generation && !expiry.hasExpired()) {
                output->play(clip);
            }
        },
        Qt::QueuedConnection);
}
