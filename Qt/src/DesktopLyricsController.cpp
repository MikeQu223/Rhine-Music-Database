#include "DesktopLyricsController.h"
#include "DesktopLyricsSettings.h"
#include "DesktopLyricsWindow.h"
#include "Engine.h"
#include <QGuiApplication>
#include <QScreen>
#include <QTimer>
#include <QtGlobal>

namespace {

DesktopLyrics::TextMetrics makeMetrics(Glyphs *glyphs) {
    return {
        [glyphs](const QString &text, double width, double size, const QString &weight) {
            return glyphs->wrap(text, width, size, weight);
        },
        [glyphs](const QString &text, double size, const QString &weight) {
            return glyphs->width(text, size, weight);
        },
    };
}

DesktopLyrics::Content previewContent() {
    return {QStringLiteral("桌面歌词预览"), QStringLiteral("播放歌曲后显示同步歌词")};
}

}

DesktopLyricsController::DesktopLyricsController(Engine *engine, DesktopLyricsSettings *settings,
                                                 QObject *parent)
    : QObject(parent), m_engine(engine), m_settings(settings), m_metrics(makeMetrics(engine->glyphs())),
      m_window(std::make_unique<DesktopLyricsWindow>(engine->glyphs(), createDesktopLyricsPlatform())),
      m_preview(qEnvironmentVariableIntValue("RHINE_DESKTOP_LYRICS_PREVIEW") == 1) {
    connect(m_settings, &DesktopLyricsSettings::enabledChanged, this, [this] { refresh(); });
    auto &player = m_engine->player();
    connect(&player, &MusicPlayer::changed, this, [this] { refresh(); });
    connect(&player, &MusicPlayer::trackSelected, this, [this] { refresh(); });
    connect(&player.lyrics, &LyricsController::changed, this, [this] { refresh(); });
    connect(qGuiApp, &QGuiApplication::primaryScreenChanged, this, [this] { rebindScreen(); });
    bindScreen();
    // 首次刷新排到事件循环，避免在 FG/主窗口之前初始化第二个 Metal 场景图。
    QTimer::singleShot(0, this, [this] { refresh(); });
}

DesktopLyricsController::~DesktopLyricsController() = default;

void DesktopLyricsController::bindScreen() {
    if (m_screenConnection) {
        QObject::disconnect(m_screenConnection);
    }
    if (auto *screen = QGuiApplication::primaryScreen()) {
        m_screenConnection = connect(screen, &QScreen::availableGeometryChanged, this, [this] { refresh(); });
    }
}

void DesktopLyricsController::rebindScreen() {
    bindScreen();
    refresh();
}

void DesktopLyricsController::refresh() {
    const bool visible = m_preview || (m_settings && m_settings->enabled());
    if (!visible) {
        m_window->hide();
        m_wasVisible = false;
        m_lastContent.reset();
        return;
    }

    auto *screen = QGuiApplication::primaryScreen();
    if (!screen) {
        m_window->hide();
        m_wasVisible = false;
        return;
    }

    const auto available = screen->availableGeometry();
    const auto content =
        m_preview ? std::optional<DesktopLyrics::Content>(previewContent()) : currentContent();
    if (!content) {
        if (m_wasVisible && !m_lastContent && available == m_lastAvailable) {
            return;
        }
        presentEmpty(available);
        return;
    }

    if (m_wasVisible && content == m_lastContent && available == m_lastAvailable) {
        return;
    }

    const auto frame = DesktopLyrics::buildFrame(*content, m_metrics, available.width());
    m_window->present(frame, DesktopLyrics::placeBottomCenter(frame.size, available));
    m_window->show();
    m_lastContent = content;
    m_lastAvailable = available;
    m_wasVisible = true;
}

void DesktopLyricsController::presentEmpty(const QRect &available) {
    const auto frame = DesktopLyrics::emptyFrame();
    m_window->present(frame, DesktopLyrics::placeBottomCenter(frame.size, available));
    m_window->show();
    m_lastContent.reset();
    m_lastAvailable = available;
    m_wasVisible = true;
}

std::optional<DesktopLyrics::Content> DesktopLyricsController::currentContent() const {
    const auto &lyrics = m_engine->player().lyrics;
    return DesktopLyrics::contentAt(lyrics.document(), lyrics.index);
}
