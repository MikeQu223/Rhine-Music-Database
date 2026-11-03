#include "NativeHud.h"
#include "DesktopLyricsAppearance.h"
#include "DesktopLyricsSettingsPage.h"
#include "HudScroll.h"
#include "SettingsCard.h"
#include <QColor>
#include <QJsonArray>
#include <QStringList>
#include <algorithm>
#include <cmath>

namespace {

QJsonArray fade(const QJsonArray &color, double alpha) {
    auto value = color;
    value[3] = alpha;
    return value;
}

}

void NativeHud::refreshDesktopLyricsAppearance() {
    if (!desktopLyricsAppearanceLoaded) {
        desktopLyricsAppearance = DesktopLyrics::readAppearance(m_host);
        desktopLyricsAppearanceLoaded = true;
    }
}

void NativeHud::refreshDesktopLyricsLayout() {
    if (modal != "desktop-lyrics") {
        return;
    }
    refreshDesktopLyricsAppearance();
    const auto bounds = modalBounds(width);
    const QRectF viewport(bounds.x() + 40, bounds.y() + DesktopLyricsViewportTop, bounds.width() - 80,
                          DesktopLyricsViewportBottom - DesktopLyricsViewportTop);
    DesktopLyricsSettingsPage::Model model;
    model.viewport = viewport;
    model.scroll = desktopLyricsScroll;
    model.enabled = m_host->preference(QLatin1String(DesktopLyrics::EnabledKey)) == QLatin1String("on");
    model.appearance = desktopLyricsAppearance;
    model.offsetMs = m_music->player.lyrics.offsetMs;
    model.globalOffsetMs = m_music->player.lyrics.globalOffsetMs();
    const auto layout = DesktopLyricsSettingsPage::measure(model);
    desktopLyricsContentBottom = DesktopLyricsViewportTop + layout.contentHeight;
    desktopLyricsScroll =
        HudScroll::clampOffset(desktopLyricsScroll, desktopLyricsContentBottom - DesktopLyricsViewportTop,
                               DesktopLyricsViewportBottom - DesktopLyricsViewportTop);
}

void NativeHud::desktopLyricsPanel(double x, double y, double width) {
    refreshDesktopLyricsAppearance();
    const QRectF viewport(x + 40, y + DesktopLyricsViewportTop, width - 80,
                          DesktopLyricsViewportBottom - DesktopLyricsViewportTop);
    DesktopLyricsSettingsPage::Model model;
    model.viewport = viewport;
    model.scroll = desktopLyricsScroll;
    model.enabled = m_host->preference(QLatin1String(DesktopLyrics::EnabledKey)) == QLatin1String("on");
    model.appearance = desktopLyricsAppearance;
    model.offsetMs = m_music->player.lyrics.offsetMs;
    model.globalOffsetMs = m_music->player.lyrics.globalOffsetMs();
    const auto layout = DesktopLyricsSettingsPage::measure(model);
    desktopLyricsContentBottom = DesktopLyricsViewportTop + layout.contentHeight;
    desktopLyricsScroll =
        HudScroll::clampOffset(desktopLyricsScroll, desktopLyricsContentBottom - DesktopLyricsViewportTop,
                               DesktopLyricsViewportBottom - DesktopLyricsViewportTop);
    model.scroll = desktopLyricsScroll;

    SettingsCard::Colors colors;
    colors.ink = ink();
    colors.muted = fade(colors.ink, 0.55);
    colors.faint = fade(colors.ink, 0.12);
    colors.line = fade(colors.ink, 0.25);
    colors.soft = dark ? QJsonArray{1, 1, 1, 0.05} : QJsonArray{0, 0, 0, 0.04};
    colors.gold = {0.835, 0.639, 0.282, 1};
    colors.panel = dark ? QJsonArray{0.15, 0.15, 0.15, 1} : QJsonArray{0.929, 0.922, 0.894, 1};

    SettingsCard::Canvas canvas;
    canvas.fill = [this](double left, double top, double width, double height, QJsonArray color) {
        fill(left, top, width, height, color);
    };
    canvas.text = [this](QString value, double left, double top, double size, QString weight, double tracking,
                         QJsonArray color) { text(value, left, top, size, weight, tracking, color); };
    canvas.fit = [this](QString value, double size, double width, QString weight) {
        return fit(value, size, width, weight);
    };
    canvas.hit = [this](double left, double top, double width, double height, QString action, QString label) {
        hit(left, top, width, height, action, label);
    };
    canvas.centered = [this](QString value, double x, double cy, double size, QString weight,
                             bool horizontal) { centeredText(value, x, cy, size, weight, horizontal); };
    canvas.stroke = [this](const QRectF &rect, QJsonArray color) {
        fill(rect.left(), rect.top(), rect.width(), 1, color);
        fill(rect.left(), rect.bottom() - 1, rect.width(), 1, color);
        fill(rect.left(), rect.top(), 1, rect.height(), color);
        fill(rect.right() - 1, rect.top(), 1, rect.height(), color);
    };

    const auto firstHit = hits.size();
    save();
    clip(viewport.x(), viewport.y(), viewport.width(), viewport.height());
    DesktopLyricsSettingsPage::paint(model, colors, canvas);
    restore();
    HudScroll::clipHits(hits, int(firstHit), viewport);

    const auto railX = x + width - 24;
    const auto railTop = y + DesktopLyricsViewportTop + 30;
    const auto railHeight = viewport.height() - 60;
    const auto track = QRectF(railX, railTop, 3, railHeight);
    const auto rail = HudScroll::rail(track, layout.contentHeight, viewport.height(), desktopLyricsScroll);
    fill(track.x(), track.y(), track.width(), track.height(),
         dark ? QJsonArray{1, 1, 1, 0.1} : QJsonArray{0, 0, 0, 0.1});
    if (rail.visible) {
        fill(rail.thumb.x(), rail.thumb.y(), rail.thumb.width(), rail.thumb.height(),
             dark ? QJsonArray{1, 1, 1, 0.45} : QJsonArray{0, 0, 0, 0.4});
    }
    button("↑", railX - 10, y + DesktopLyricsViewportTop, 23, 25, "desktop-lyrics:scroll-up", 14);
    button("↓", railX - 10, y + DesktopLyricsViewportBottom - 25, 23, 25, "desktop-lyrics:scroll-down", 14);
}

void NativeHud::applyDesktopLyricsAction(const QString &value) {
    const auto prefix = QStringLiteral("desktop-lyrics:");
    const auto rest = value.mid(prefix.size());
    const auto parts = rest.split(':');
    const auto name = parts.value(0);
    const auto argument = parts.value(1);

    if (name == QLatin1String("open")) {
        settingsReturnScroll = settingsScroll;
        openModal("desktop-lyrics");
        return;
    }
    if (name == QLatin1String("back")) {
        openModal("settings");
        settingsScroll = std::clamp(settingsReturnScroll, 0.0, settingsScrollMaximum());
        return;
    }
    if (name == QLatin1String("scroll-up") || name == QLatin1String("scroll-down")) {
        const auto movement = name == QLatin1String("scroll-down") ? 120.0 : -120.0;
        desktopLyricsScroll = HudScroll::clampOffset(desktopLyricsScroll + movement,
                                                     desktopLyricsContentBottom - DesktopLyricsViewportTop,
                                                     DesktopLyricsViewportBottom - DesktopLyricsViewportTop);
        return;
    }

    const auto write = [this](const char *key, const QString &text) {
        m_host->setPreference(QString::fromLatin1(key), text);
    };
    const auto writeInteger = [&](const char *key, int minimum, int maximum) {
        bool ok = false;
        const int parsed = argument.toInt(&ok);
        if (ok) {
            write(key, QString::number(std::clamp(parsed, minimum, maximum)));
        }
    };
    const auto writeOutline = [&](const char *key) {
        bool ok = false;
        const double parsed = argument.toDouble(&ok);
        if (ok) {
            const double clamped = std::clamp(parsed, 0.0, DesktopLyrics::MaximumOutline);
            const double rounded =
                std::round(clamped / DesktopLyrics::OutlineStep) * DesktopLyrics::OutlineStep;
            write(key, QString::number(rounded, 'f', 1));
        }
    };
    const auto writeColor = [&](const char *key) {
        const QColor color(argument);
        if (color.isValid()) {
            write(key, color.name(QColor::HexRgb).toLower());
        }
    };
    const auto writeWeight = [&](const char *key) {
        static const QStringList weights{QStringLiteral("light"), QStringLiteral("regular"),
                                         QStringLiteral("demibold"), QStringLiteral("bold")};
        if (weights.contains(argument)) {
            write(key, argument);
        }
    };

    if (name == QLatin1String("enabled")) {
        write(DesktopLyrics::EnabledKey,
              argument == QLatin1String("on") ? QStringLiteral("on") : QStringLiteral("off"));
    } else if (name == QLatin1String("opacity")) {
        writeInteger(DesktopLyrics::OpacityKey, DesktopLyrics::MinimumOpacity, DesktopLyrics::MaximumOpacity);
    } else if (name == QLatin1String("line-size")) {
        writeInteger(DesktopLyrics::LineSizeKey, DesktopLyrics::MinimumLineSize,
                     DesktopLyrics::MaximumLineSize);
    } else if (name == QLatin1String("translation-size")) {
        writeInteger(DesktopLyrics::TranslationSizeKey, DesktopLyrics::MinimumTranslationSize,
                     DesktopLyrics::MaximumTranslationSize);
    } else if (name == QLatin1String("line-weight")) {
        writeWeight(DesktopLyrics::LineWeightKey);
    } else if (name == QLatin1String("translation-weight")) {
        writeWeight(DesktopLyrics::TranslationWeightKey);
    } else if (name == QLatin1String("line-color")) {
        writeColor(DesktopLyrics::LineColorKey);
    } else if (name == QLatin1String("translation-color")) {
        writeColor(DesktopLyrics::TranslationColorKey);
    } else if (name == QLatin1String("line-outline")) {
        writeOutline(DesktopLyrics::LineOutlineKey);
    } else if (name == QLatin1String("translation-outline")) {
        writeOutline(DesktopLyrics::TranslationOutlineKey);
    } else if (name == QLatin1String("line-outline-color")) {
        writeColor(DesktopLyrics::LineOutlineColorKey);
    } else if (name == QLatin1String("translation-outline-color")) {
        writeColor(DesktopLyrics::TranslationOutlineColorKey);
    } else if (name == QLatin1String("offset-earlier")) {
        m_music->player.lyrics.adjustOffset(200);
    } else if (name == QLatin1String("offset-later")) {
        m_music->player.lyrics.adjustOffset(-200);
    } else if (name == QLatin1String("offset-reset")) {
        m_music->player.lyrics.resetOffset();
    } else if (name == QLatin1String("offset-global")) {
        m_music->player.lyrics.applyGlobalOffset();
    } else if (name == QLatin1String("reset-style")) {
        DesktopLyrics::resetAppearance(m_host);
    }
    desktopLyricsAppearanceLoaded = false;
    m_host->invalidate();
}
