#pragma once
#include <QObject>
#include <QString>

class Host;

// 桌面歌词开关
class DesktopLyricsSettings : public QObject {
    Q_OBJECT
  public:
    explicit DesktopLyricsSettings(Host *host, QObject *parent = nullptr);
    bool enabled() const;
    int fontSize() const;
    int opacity() const;
    void setEnabled(bool enabled);

  signals:
    void enabledChanged(bool enabled);
    void appearanceChanged();

  private:
    void applyPreference(const QString &key, const QString &value);

    Host *m_host;
    bool m_enabled = false;
    int m_fontSize = 32;
    int m_opacity = 100;
};
