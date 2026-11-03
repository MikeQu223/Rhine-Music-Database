#pragma once
#include "DesktopLyricsLayout.h"
#include <QObject>
#include <QString>

class Host;

// 桌面歌词开关与外观
class DesktopLyricsSettings : public QObject {
    Q_OBJECT
  public:
    explicit DesktopLyricsSettings(Host *host, QObject *parent = nullptr);
    bool enabled() const;
    DesktopLyrics::Style style() const;
    void setEnabled(bool enabled);

  signals:
    void enabledChanged(bool enabled);
    void appearanceChanged();

  private:
    void applyPreference(const QString &key, const QString &value);

    Host *m_host;
    bool m_enabled = false;
    DesktopLyrics::Appearance m_appearance;
};
