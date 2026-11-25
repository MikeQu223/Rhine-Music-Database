#pragma once

#include <QDeadlineTimer>
#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QThread>

class Host;
class MusicPlayer;

/** 响应资料库选中项变化和页面开合，音频资源和设备由独立线程持有。 */
class UiSoundFeedback : public QObject {
  public:
    UiSoundFeedback(Host *host, MusicPlayer *player, QObject *parent);
    ~UiSoundFeedback() override;
    void observeSelection(const QString &key, bool inArchive);
    void playSurface(bool opened);
    void playStartup();

  private:
    enum class Cue { Selection, SurfaceOpen, SurfaceClose };
    class Output;
    bool isMusicBusy() const;
    void updateAvailability();
    void tryPlayStartup();
    void cancel();
    void stopOutput();
    void play(Cue cue);

    Host *m_host;
    MusicPlayer *m_player;
    QThread m_thread;
    Output *m_output = nullptr;
    QString m_selectedKey;
    QElapsedTimer m_lastCue;
    QElapsedTimer m_lastSurfaceCue;
    QDeadlineTimer m_startupQuietUntil;
    Cue m_lastSurface = Cue::Selection;
    bool m_startupPending = false;
    bool m_startupQueued = false;
    bool m_preferenceKnown = false;
    bool m_enabled = false;
    bool m_allowed = false;
};
