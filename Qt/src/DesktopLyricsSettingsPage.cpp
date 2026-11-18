#include "DesktopLyricsSettingsPage.h"
#include "HudScroll.h"
#include <QColor>
#include <QJsonArray>
#include <QPair>
#include <QStringList>
#include <QVector>
#include <algorithm>
#include <array>
#include <cmath>

namespace DesktopLyricsSettingsPage {
namespace {

constexpr double ContentInset = 14;
constexpr double HeaderHeight = 40;
constexpr double RowHeight = 66;
constexpr double RowStep = 76;
constexpr double SectionGap = 24;
constexpr double ControlWidth = 360;
constexpr double OffsetHeight = 110;
constexpr double ResetBlockHeight = 90;
constexpr double BottomPad = 28;

constexpr double DisplayHeight = HeaderHeight + RowStep * 2 + SectionGap;
constexpr double LyricHeight = HeaderHeight + RowStep * 5 + SectionGap;
constexpr double TranslationHeight = HeaderHeight + RowStep * 5 + SectionGap;
constexpr double SyncHeight = HeaderHeight + OffsetHeight + SectionGap;
constexpr double ResetHeight = HeaderHeight + ResetBlockHeight + SectionGap;
constexpr double ContentHeight =
    DisplayHeight + LyricHeight + TranslationHeight + SyncHeight + ResetHeight + BottomPad;

struct PaletteEntry {
    const char *label = "";
    const char *value = "";
};

constexpr std::array<PaletteEntry, 10> TextPalette{{
    {"白色", "#f5f6f2"},
    {"纯白", "#ffffff"},
    {"暖白", "#ffe9c7"},
    {"金色", "#f5c76b"},
    {"橙色", "#ff9f6b"},
    {"薄荷", "#8fe3c0"},
    {"青色", "#7fd8e8"},
    {"天蓝", "#8fc7ff"},
    {"粉色", "#ffa6c9"},
    {"紫色", "#d6b4ff"},
}};

constexpr std::array<PaletteEntry, 6> OutlinePalette{{
    {"黑色", "#000000"},
    {"深灰", "#2a2a2a"},
    {"暖黑", "#3a2a1a"},
    {"白色", "#ffffff"},
    {"米白", "#f5f6f2"},
    {"深蓝", "#102030"},
}};

QJsonArray colorArray(const QColor &color) {
    return {color.redF(), color.greenF(), color.blueF(), 1.0};
}

QString action(const char *prefix, const QString &value) {
    return QString::fromLatin1(prefix) + value;
}

}

Layout measure(const Model &model) {
    Layout layout;
    layout.contentHeight = ContentHeight;
    layout.maximumScroll = HudScroll::maximum(layout.contentHeight, model.viewport.height());
    return layout;
}

void paint(const Model &model, const SettingsCard::Colors &colors, const SettingsCard::Canvas &canvas) {
    double y = model.viewport.top() - model.scroll;
    const double left = model.viewport.left() + ContentInset;
    const double width = model.viewport.width() - ContentInset * 2;
    int sectionNumber = 0;
    int rowNumber = 0;

    const auto section = [&](const QString &titleEn, const QString &titleZh) {
        canvas.text(QString::number(++sectionNumber).rightJustified(2, '0'), left, y + 12, 11, "regular",
                    0.05, colors.muted);
        canvas.text(titleEn + " / " + titleZh, left + 26, y + 9, 14, "demibold", 0.06, colors.ink);
        canvas.fill(left, y + HeaderHeight - 1, width, 1, colors.line);
        y += HeaderHeight;
    };

    const auto row = [&](const QString &titleEn, const QString &titleZh, const auto &drawControl) {
        canvas.fill(left, y + RowHeight - 1, width, 1, colors.line);
        canvas.text(QString::number(++rowNumber).rightJustified(2, '0'), left, y + 25, 11, "regular", 0.04,
                    colors.muted);
        canvas.text(titleEn, left + 30, y + 10, 11, "regular", 0.08, colors.muted);
        canvas.text(titleZh, left + 30, y + 25, 17, "demibold", -0.01, colors.ink);
        drawControl(QRectF(left + width - ControlWidth, y + 9, ControlWidth, 48));
        y += RowStep;
    };

    const auto stepper = [&](const QRectF &control, const QString &value, const QString &minus,
                             const QString &plus, const QString &label) {
        canvas.fill(control.left(), control.top(), control.width(), control.height(), colors.soft);
        canvas.stroke(control, colors.line);
        canvas.text(value, control.left() + 16, control.top() + 15, 15, "demibold", 0, colors.ink);
        const QRectF minusRect(control.right() - 84, control.top() + 8, 32, 32);
        const QRectF plusRect(control.right() - 40, control.top() + 8, 32, 32);
        canvas.stroke(minusRect, colors.line);
        canvas.stroke(plusRect, colors.line);
        canvas.centered("−", minusRect.center().x(), minusRect.center().y(), 19, "regular", true);
        canvas.centered("＋", plusRect.center().x(), plusRect.center().y(), 16, "regular", true);
        canvas.hit(minusRect.left(), minusRect.top(), minusRect.width(), minusRect.height(), minus, label);
        canvas.hit(plusRect.left(), plusRect.top(), plusRect.width(), plusRect.height(), plus, label);
    };

    const auto segments = [&](const QRectF &control, const QVector<QPair<QString, QString>> &options,
                              const QString &current, const char *prefix, const QString &label) {
        constexpr double gap = 6;
        const double segmentWidth =
            (control.width() - gap * std::max(0, int(options.size()) - 1)) / std::max(1, int(options.size()));
        for (int index = 0; index < options.size(); ++index) {
            const QRectF rect(control.left() + index * (segmentWidth + gap), control.top() + 4, segmentWidth,
                              control.height() - 8);
            canvas.fill(rect.left(), rect.top(), rect.width(), rect.height(), colors.soft);
            canvas.stroke(rect, colors.line);
            const bool active = options.at(index).first == current;
            if (active) {
                canvas.fill(rect.left(), rect.top(), 3, rect.height(), colors.gold);
            }
            const QString weight = active ? QStringLiteral("demibold") : QStringLiteral("regular");
            const auto shown = canvas.fit(options.at(index).second, 13, rect.width() - 8, weight);
            canvas.centered(shown, rect.center().x(), rect.center().y(), 13, weight, true);
            canvas.hit(rect.left(), rect.top(), rect.width(), rect.height(),
                       action(prefix, options.at(index).first), label);
        }
    };

    const auto palette = [&](const QRectF &control, const auto &entries, const QString &current,
                             const char *prefix) {
        canvas.fill(control.left(), control.top(), control.width(), control.height(), colors.soft);
        canvas.stroke(control, colors.line);
        double x = control.left() + 6;
        for (const auto &entry : entries) {
            const QColor color(QString::fromLatin1(entry.value));
            const QRectF swatch(x, control.center().y() - 11, 22, 22);
            canvas.fill(swatch.left(), swatch.top(), swatch.width(), swatch.height(), colorArray(color));
            canvas.stroke(swatch, colors.line);
            const auto value = QString::fromLatin1(entry.value).toLower();
            if (value == current) {
                canvas.fill(swatch.left() - 2, swatch.top() - 2, swatch.width() + 4, 2, colors.gold);
                canvas.fill(swatch.left() - 2, swatch.bottom(), swatch.width() + 4, 2, colors.gold);
                canvas.fill(swatch.left() - 2, swatch.top(), 2, swatch.height(), colors.gold);
                canvas.fill(swatch.right(), swatch.top(), 2, swatch.height(), colors.gold);
            }
            canvas.hit(swatch.left(), swatch.top(), swatch.width(), swatch.height(), action(prefix, value),
                       QString::fromUtf8(entry.label));
            x += 30;
        }
    };

    section(QStringLiteral("DISPLAY"), QStringLiteral("显示"));
    row(QStringLiteral("ENABLED"), QStringLiteral("显示桌面歌词"), [&](const QRectF &control) {
        const QVector<QPair<QString, QString>> options{
            {QStringLiteral("on"), QStringLiteral("开启")},
            {QStringLiteral("off"), QStringLiteral("关闭")},
        };
        segments(control, options, model.enabled ? QStringLiteral("on") : QStringLiteral("off"),
                 "desktop-lyrics:enabled:", QStringLiteral("显示桌面歌词"));
    });
    row(QStringLiteral("OPACITY"), QStringLiteral("整体透明度"), [&](const QRectF &control) {
        const int current = model.appearance.opacity;
        stepper(
            control, QString::number(current) + "%",
            "desktop-lyrics:opacity:" + QString::number(std::max(DesktopLyrics::MinimumOpacity, current - 5)),
            "desktop-lyrics:opacity:" + QString::number(std::min(DesktopLyrics::MaximumOpacity, current + 5)),
            QStringLiteral("整体透明度"));
    });
    y += SectionGap;

    section(QStringLiteral("LYRIC"), QStringLiteral("正文"));
    row(QStringLiteral("SIZE"), QStringLiteral("字号"), [&](const QRectF &control) {
        const int current = model.appearance.lineSize;
        stepper(control, QString::number(current) + " px",
                "desktop-lyrics:line-size:" +
                    QString::number(std::max(DesktopLyrics::MinimumLineSize, current - 2)),
                "desktop-lyrics:line-size:" +
                    QString::number(std::min(DesktopLyrics::MaximumLineSize, current + 2)),
                QStringLiteral("正文字号"));
    });
    row(QStringLiteral("WEIGHT"), QStringLiteral("字重"), [&](const QRectF &control) {
        const QVector<QPair<QString, QString>> options{
            {QStringLiteral("light"), QStringLiteral("细")},
            {QStringLiteral("regular"), QStringLiteral("常规")},
            {QStringLiteral("demibold"), QStringLiteral("中粗")},
            {QStringLiteral("bold"), QStringLiteral("粗")},
        };
        segments(control, options, model.appearance.lineWeight,
                 "desktop-lyrics:line-weight:", QStringLiteral("正文字重"));
    });
    row(QStringLiteral("COLOR"), QStringLiteral("颜色"), [&](const QRectF &control) {
        palette(control, TextPalette, model.appearance.lineColor, "desktop-lyrics:line-color:");
    });
    row(QStringLiteral("OUTLINE"), QStringLiteral("描边"), [&](const QRectF &control) {
        const double current = model.appearance.lineOutline;
        const auto next = [](double value) { return std::clamp(value, 0.0, DesktopLyrics::MaximumOutline); };
        stepper(control, QString::number(current, 'f', 1) + " px",
                "desktop-lyrics:line-outline:" +
                    QString::number(next(current - DesktopLyrics::OutlineStep), 'f', 1),
                "desktop-lyrics:line-outline:" +
                    QString::number(next(current + DesktopLyrics::OutlineStep), 'f', 1),
                QStringLiteral("正文描边"));
    });
    row(QStringLiteral("OUTLINE COLOR"), QStringLiteral("描边颜色"), [&](const QRectF &control) {
        palette(control, OutlinePalette, model.appearance.lineOutlineColor,
                "desktop-lyrics:line-outline-color:");
    });
    y += SectionGap;

    section(QStringLiteral("TRANSLATION"), QStringLiteral("翻译"));
    row(QStringLiteral("SIZE"), QStringLiteral("字号"), [&](const QRectF &control) {
        const int current = model.appearance.translationSize;
        stepper(control, QString::number(current) + " px",
                "desktop-lyrics:translation-size:" +
                    QString::number(std::max(DesktopLyrics::MinimumTranslationSize, current - 2)),
                "desktop-lyrics:translation-size:" +
                    QString::number(std::min(DesktopLyrics::MaximumTranslationSize, current + 2)),
                QStringLiteral("翻译字号"));
    });
    row(QStringLiteral("WEIGHT"), QStringLiteral("字重"), [&](const QRectF &control) {
        const QVector<QPair<QString, QString>> options{
            {QStringLiteral("light"), QStringLiteral("细")},
            {QStringLiteral("regular"), QStringLiteral("常规")},
            {QStringLiteral("demibold"), QStringLiteral("中粗")},
            {QStringLiteral("bold"), QStringLiteral("粗")},
        };
        segments(control, options, model.appearance.translationWeight,
                 "desktop-lyrics:translation-weight:", QStringLiteral("翻译字重"));
    });
    row(QStringLiteral("COLOR"), QStringLiteral("颜色"), [&](const QRectF &control) {
        palette(control, TextPalette, model.appearance.translationColor, "desktop-lyrics:translation-color:");
    });
    row(QStringLiteral("OUTLINE"), QStringLiteral("描边"), [&](const QRectF &control) {
        const double current = model.appearance.translationOutline;
        const auto next = [](double value) { return std::clamp(value, 0.0, DesktopLyrics::MaximumOutline); };
        stepper(control, QString::number(current, 'f', 1) + " px",
                "desktop-lyrics:translation-outline:" +
                    QString::number(next(current - DesktopLyrics::OutlineStep), 'f', 1),
                "desktop-lyrics:translation-outline:" +
                    QString::number(next(current + DesktopLyrics::OutlineStep), 'f', 1),
                QStringLiteral("翻译描边"));
    });
    row(QStringLiteral("OUTLINE COLOR"), QStringLiteral("描边颜色"), [&](const QRectF &control) {
        palette(control, OutlinePalette, model.appearance.translationOutlineColor,
                "desktop-lyrics:translation-outline-color:");
    });
    y += SectionGap;

    section(QStringLiteral("SYNC"), QStringLiteral("同步"));
    canvas.fill(left, y + OffsetHeight - 1, width, 1, colors.line);
    canvas.text(QStringLiteral("OFFSET"), left, y + 10, 11, "regular", 0.08, colors.muted);
    canvas.text(QStringLiteral("歌词偏移"), left + 30, y + 25, 17, "demibold", -0.01, colors.ink);
    QString offsetText = QStringLiteral("未校准");
    if (model.offsetMs != 0) {
        const auto direction = model.offsetMs > 0 ? QStringLiteral("已提前 ") : QStringLiteral("已延后 ");
        offsetText =
            direction + QString::number(std::abs(model.offsetMs) / 1000.0, 'f', 1) + QStringLiteral(" 秒");
    }
    canvas.text(offsetText, left + 30, y + 48, 13, "regular", 0, colors.muted);
    const auto note = QStringLiteral("与歌词页共用同一偏移；调整后悬浮歌词立即同步。");
    canvas.text(canvas.fit(note, 17, width - 30, "regular"), left + 30, y + 72, 17, "regular", 0,
                colors.muted);
    const QRectF control(left + width - ControlWidth, y + 8, ControlWidth, 48);
    const QStringList offsetLabels{QStringLiteral("提前 0.2s"), QStringLiteral("延后 0.2s"),
                                   QStringLiteral("重置"), QStringLiteral("设为全局")};
    const QStringList offsetActions{
        QStringLiteral("desktop-lyrics:offset-earlier"), QStringLiteral("desktop-lyrics:offset-later"),
        QStringLiteral("desktop-lyrics:offset-reset"), QStringLiteral("desktop-lyrics:offset-global")};
    for (int index = 0; index < offsetLabels.size(); ++index) {
        const QRectF rect(control.left() + 4 + index * 88, control.top() + 4, 84, 40);
        canvas.fill(rect.left(), rect.top(), rect.width(), rect.height(), colors.soft);
        canvas.stroke(rect, colors.line);
        const auto shown = canvas.fit(offsetLabels.at(index), 12, rect.width() - 8, "regular");
        canvas.centered(shown, rect.center().x(), rect.center().y(), 12, "regular", true);
        canvas.hit(rect.left(), rect.top(), rect.width(), rect.height(), offsetActions.at(index),
                   offsetLabels.at(index));
    }
    y += OffsetHeight;
    y += SectionGap;

    section(QStringLiteral("RESET"), QStringLiteral("重置"));
    const QRectF reset(left, y + 8, 300, 48);
    canvas.fill(reset.left(), reset.top(), reset.width(), reset.height(), colors.soft);
    canvas.stroke(reset, colors.line);
    canvas.text(QStringLiteral("恢复默认样式"), reset.left() + 14, reset.top() + 15, 15, "regular", 0,
                colors.ink);
    canvas.hit(reset.left(), reset.top(), reset.width(), reset.height(),
               QStringLiteral("desktop-lyrics:reset-style"), QStringLiteral("恢复默认样式"));
    const auto resetNote = QStringLiteral("恢复字号、颜色、描边与透明度；开关和偏移保持不变。");
    canvas.text(canvas.fit(resetNote, 15, std::max(60.0, width - 316), "regular"), left + 316, y + 20, 15,
                "regular", 0, colors.muted);
    y += ResetBlockHeight;
    y += SectionGap;
}

}
