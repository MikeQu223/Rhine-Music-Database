#pragma once

#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QThread>

class Host;
class MusicPlayer;

/** 响应资料库实际选中的唱片变化，音频资源和设备由独立线程持有。 */
class UiSoundFeedback : public QObject {
  public:
    UiSoundFeedback(Host *host, MusicPlayer *player, QObject *parent);
    ~UiSoundFeedback() override;
    void observeSelection(const QString &key, bool inArchive);

  private:
    class Output;
    void updateAvailability();
    void cancel();
    void play();

    Host *m_host;
    MusicPlayer *m_player;
    QThread m_thread;
    Output *m_output = nullptr;
    QString m_selectedKey;
    QElapsedTimer m_lastCue;
    bool m_enabled = false;
    bool m_allowed = false;
};
