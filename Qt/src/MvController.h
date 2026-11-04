#pragma once
#include "MusicApi.h"
#include "DesktopWallpaper.h"
#include <QElapsedTimer>
#include <QJsonArray>
#include <QMediaPlayer>
#include <QPointer>
#include <QTimer>
#include <QVideoSink>
#include <QWindow>

class MusicPlayer;

/** GUI-owned, silent companion video. Audio and queue ownership stays in the service. */
class MvController : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY changed)
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(QString title READ title NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(double opacity READ opacity WRITE setOpacity NOTIFY changed)
    Q_PROPERTY(QStringList versionLabels READ versionLabels NOTIFY changed)
    Q_PROPERTY(int versionIndex READ versionIndex WRITE setVersionIndex NOTIFY changed)
    Q_PROPERTY(QString versionStatus READ versionStatus NOTIFY changed)
    Q_PROPERTY(int offset READ offset NOTIFY changed)
    Q_PROPERTY(bool wallpaperSupported READ wallpaperSupported CONSTANT)
    Q_PROPERTY(bool wallpaper READ wallpaper WRITE setWallpaper NOTIFY changed)
    Q_PROPERTY(bool wallpaperActive READ wallpaperActive NOTIFY changed)
    Q_PROPERTY(QString presentationStatus READ presentationStatus NOTIFY changed)
    Q_PROPERTY(QStringList screenLabels READ screenLabels NOTIFY screensChanged)
    Q_PROPERTY(int screenIndex READ screenIndex WRITE setScreenIndex NOTIFY screensChanged)
    Q_PROPERTY(double position READ position NOTIFY playbackChanged)
    Q_PROPERTY(double duration READ duration NOTIFY playbackChanged)
    Q_PROPERTY(double progress READ progress NOTIFY playbackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playbackChanged)
    Q_PROPERTY(bool seekable READ seekable NOTIFY playbackChanged)
    Q_PROPERTY(QRectF desktopControlRect READ desktopControlRect NOTIFY desktopGeometryChanged)
    Q_PROPERTY(QVariantList spectrum READ spectrum NOTIFY spectrumChanged)
    Q_PROPERTY(bool pinned READ pinned WRITE setPinned NOTIFY changed)
    Q_PROPERTY(bool locked READ locked WRITE setLocked NOTIFY changed)
    Q_PROPERTY(bool relativeUnlock READ relativeUnlock CONSTANT)
  public:
    using Resolve = std::function<void(const QJsonObject &, MusicApi::Reply)>;
    MvController(Host *host, MusicPlayer *music, QObject *parent = nullptr, Resolve resolve = {},
                 Resolve versions = {});
    ~MvController() override;
    bool enabled() const {
        return m_enabled;
    }
    bool ready() const {
        return m_enabled && !m_error && !m_video.source().isEmpty() && m_video.hasVideo();
    }
    QString title() const {
        return m_title;
    }
    QString status() const {
        return m_status;
    }
    double opacity() const {
        return m_opacity;
    }
    QStringList versionLabels() const;
    int versionIndex() const;
    QString versionStatus() const {
        return m_versionStatus;
    }
    int offset() const;
    QUrl source() const {
        return m_video.source();
    }
    void setWindow(QWindow *window);
    void setWallpaperWindow(QWindow *window);
    double position() const;
    double duration() const;
    double progress() const;
    bool playing() const;
    bool seekable() const;
    QRectF desktopControlRect() const {
        return m_desktop.controlsRect();
    }
    QVariantList spectrum() const {
        return m_spectrum;
    }
    bool wallpaperSupported() const {
        return DesktopWallpaper::supported();
    }
    bool wallpaper() const {
        return m_wallpaper;
    }
    bool wallpaperActive() const {
        return m_wallpaperAttached;
    }
    QString presentationStatus() const {
        return m_presentationStatus;
    }
    QStringList screenLabels() const;
    int screenIndex() const;
    void setWallpaper(bool enabled);
    void setScreenIndex(int index);
    void setEnabled(bool enabled);
    bool pinned() const {
        return m_pinned;
    }
    bool locked() const {
        return m_locked;
    }
    void setPinned(bool value);
    void setLocked(bool value);
    bool relativeUnlock() const;
    Q_INVOKABLE void registerUnlockWindow(QWindow *window);
    void setOpacity(double opacity);
    void setVersionIndex(int index);
    Q_INVOKABLE void attachVideo(QVideoSink *sink);
    Q_INVOKABLE void attachWallpaperVideo(QVideoSink *sink);
    Q_INVOKABLE void retry();
    Q_INVOKABLE void toggleFullscreen();
    Q_INVOKABLE void adjustOffset(int milliseconds);
    Q_INVOKABLE void resetOffset();
    Q_INVOKABLE void hideForQuit();
    Q_INVOKABLE void toggleMusic();
    Q_INVOKABLE void seekMusic(double fraction);
    Q_INVOKABLE void exitWallpaper();
    Q_INVOKABLE void showSettings();
    Q_INVOKABLE void openWindow();
    static qint64 videoPosition(double audioPosition, int offset, qint64 duration);
  signals:
    void changed();
    void videoCleared();
    void screensChanged();
    void playbackChanged();
    void spectrumChanged();
    void desktopGeometryChanged();

  private:
    void refresh(bool force = false);
    void resolveVideo(QJsonObject track, quint64 generation, int epoch);
    void sync();
    double audioPosition() const;
    void preferencesChanged(const QString &key);
    void placeWindow();
    void saveOffset(int value);
    void applyPresentation();
    void updateOutput();
    void updateDesktopControls();
    QScreen *wallpaperScreen() const;
    Host *m_host;
    MusicPlayer *m_music;
    MusicApi m_api;
    Resolve m_resolve;
    Resolve m_versionsResolve;
    QMediaPlayer m_video;
    QPointer<QWindow> m_window;
    QPointer<QWindow> m_unlockWindow;
    QPointer<QWindow> m_wallpaperWindow;
    QPointer<QVideoSink> m_previewSink, m_wallpaperSink;
    DesktopWallpaper m_desktop;
    QTimer m_desktopTimer;
    QTimer m_controlsTimer;
    QTimer m_timer;
    QElapsedTimer m_audioClock;
    QJsonObject m_offsets;
    QJsonObject m_selections;
    QJsonArray m_versions;
    QVariantList m_spectrum;
    QString m_key, m_mvID, m_title, m_status, m_versionStatus;
    QString m_screenName, m_presentationStatus;
    quint64 m_generation = 0;
    quint64 m_sourceGeneration = 0;
    QString m_requestedMvID;
    int m_epoch = -1;
    double m_audioPosition = -1;
    double m_opacity = 1;
    bool m_enabled = false;
    bool m_audioPlaying = false;
    bool m_error = false;
    bool m_wallpaper = false;
    bool m_wallpaperAttached = false;
    bool m_quitting = false;
    bool m_pinned = false;
    bool m_locked = false;
};
