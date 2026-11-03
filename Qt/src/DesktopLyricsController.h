#pragma once
#include "DesktopLyricsLayout.h"
#include <QMetaObject>
#include <QObject>
#include <QRect>
#include <memory>
#include <optional>

class DesktopLyricsSettings;
class DesktopLyricsWindow;
class Engine;

// 桌面悬浮歌词控制器
class DesktopLyricsController : public QObject {
    Q_OBJECT
  public:
    DesktopLyricsController(Engine *engine, DesktopLyricsSettings *settings, QObject *parent = nullptr);
    ~DesktopLyricsController() override;

  private:
    void bindScreen();
    void rebindScreen();
    void refresh();
    void presentEmpty(const QRect &available);
    std::optional<DesktopLyrics::Content> currentContent() const;

    Engine *m_engine = nullptr;
    DesktopLyricsSettings *m_settings = nullptr;
    DesktopLyrics::TextMetrics m_metrics;
    std::unique_ptr<DesktopLyricsWindow> m_window;
    bool m_preview = false;
    bool m_wasVisible = false;
    std::optional<DesktopLyrics::Content> m_lastContent;
    QRect m_lastAvailable;
    DesktopLyrics::Style m_lastStyle;
    QMetaObject::Connection m_screenConnection;
};
