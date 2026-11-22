#include "NativeHud.h"
#include "MacMenuBar.h"
#include "MacMenuBarSettings.h"
#include <algorithm>

namespace {
const QString ActionPrefix = QStringLiteral("menu-bar-lyrics:");
constexpr double RowHeight = 66;
constexpr double RowStep = 76;
constexpr double ControlWidth = 360;
}

void NativeHud::menuBarLyricsPanel(double x, double y, double width) {
    const auto enabled = MacMenuBar::isEnabled(m_host->preference(MacMenuBar::EnabledPreference));
    const auto storedLayout = MacMenuBar::parseLayout(m_host->preference(MacMenuBar::LayoutPreference));
    const auto controlsPreference = m_host->preference(MacMenuBar::ControlsPreference);
    const auto iconPreference = m_host->preference(MacMenuBar::IconPreference);
    const auto layout = MacMenuBar::effectiveLayout(storedLayout, true, controlsPreference, iconPreference);
    const bool showsControls = layout.contains(MacMenuBar::Component::Controls) ||
                               layout.contains(MacMenuBar::Component::Favorite);
    const auto visibleLayout =
        enabled ? layout : MacMenuBar::effectiveLayout(storedLayout, false, controlsPreference, iconPreference);
    const bool showsIcon = visibleLayout.contains(MacMenuBar::Component::Icon);
    const int lyricWidth = MacMenuBar::parseLyricWidth(m_host->preference(MacMenuBar::WidthPreference));

    const double left = x + 54;
    const double right = x + width - 54;
    double top = y + DesktopLyricsViewportTop;
    auto line = ink();
    line[3] = 0.25;
    auto muted = ink();
    muted[3] = 0.55;
    const QJsonArray soft = dark ? QJsonArray{1, 1, 1, 0.05} : QJsonArray{0, 0, 0, 0.04};
    const QJsonArray gold{0.835, 0.639, 0.282, 1};

    const auto frame = [&](const QRectF &rect) {
        fill(rect.left(), rect.top(), rect.width(), rect.height(), soft);
        fill(rect.left(), rect.top(), rect.width(), 1, line);
        fill(rect.left(), rect.bottom() - 1, rect.width(), 1, line);
        fill(rect.left(), rect.top(), 1, rect.height(), line);
        fill(rect.right() - 1, rect.top(), 1, rect.height(), line);
    };
    const auto row = [&](const QString &title, const QString &description, const auto &drawControl) {
        text(title, left, top + 10, 17, "demibold");
        text(description, left, top + 34, 13, "regular", 0, muted);
        drawControl(QRectF(right - ControlWidth, top + 9, ControlWidth, 48));
        fill(left, top + RowHeight - 1, right - left, 1, line);
        top += RowStep;
    };
    const auto segments = [&](const QRectF &control, const QString &name, const QString &title, bool isOn) {
        constexpr double gap = 6;
        const double segmentWidth = (control.width() - gap) / 2;
        for (const bool on : {true, false}) {
            const double segmentX = on ? control.left() : control.left() + segmentWidth + gap;
            const QRectF rect(segmentX, control.top() + 4, segmentWidth, control.height() - 8);
            const auto label = on ? QStringLiteral("开启") : QStringLiteral("关闭");
            frame(rect);
            if (on == isOn) {
                fill(rect.left(), rect.top(), 3, rect.height(), gold);
            }
            centeredText(label, rect.center().x(), rect.center().y(), 13,
                         on == isOn ? "demibold" : "regular", true);
            hit(rect.left(), rect.top(), rect.width(), rect.height(),
                ActionPrefix + name + (on ? ":on" : ":off"), title + QStringLiteral(" ") + label);
        }
    };

    const auto enabledTitle = QStringLiteral("显示菜单栏歌词");
    const auto controlsTitle = QStringLiteral("显示播放控件");
    const auto iconTitle = QStringLiteral("显示 Logo");
    row(enabledTitle, QStringLiteral("关闭后仅在「显示 Logo」开启时保留图标"), [&](const QRectF &control) {
        segments(control, QStringLiteral("enabled"), enabledTitle, enabled);
    });
    row(controlsTitle, QStringLiteral("上一首、播放 / 暂停、下一首、喜爱"), [&](const QRectF &control) {
        segments(control, QStringLiteral("controls"), controlsTitle, showsControls);
    });
    row(iconTitle, QStringLiteral("点击 Logo 可打开主窗口"), [&](const QRectF &control) {
        segments(control, QStringLiteral("icon"), iconTitle, showsIcon);
    });
    row(QStringLiteral("歌词宽度"), QStringLiteral("调整歌词文字在菜单栏占用的空间"), [&](const QRectF &control) {
        frame(control);
        text(QString::number(lyricWidth) + QStringLiteral(" pt"), control.left() + 16, control.top() + 15,
             15, "demibold");
        for (const bool increase : {false, true}) {
            const QRectF rect(control.right() - (increase ? 40 : 84), control.top() + 8, 32, 32);
            const int next = lyricWidth + (increase ? MacMenuBar::LyricWidthStep : -MacMenuBar::LyricWidthStep);
            frame(rect);
            centeredText(increase ? QStringLiteral("＋") : QStringLiteral("−"), rect.center().x(),
                         rect.center().y(), 17, "regular", true);
            if (next >= MacMenuBar::MinimumLyricWidth && next <= MacMenuBar::MaximumLyricWidth) {
                hit(rect.left(), rect.top(), rect.width(), rect.height(),
                    ActionPrefix + QStringLiteral("width:") + QString::number(next),
                    increase ? QStringLiteral("加宽歌词") : QStringLiteral("缩窄歌词"));
            }
        }
    });
}

void NativeHud::applyMenuBarLyricsAction(const QString &value) {
    const auto command = value.mid(ActionPrefix.size());
    if (command == "open" && modal == "settings") {
        settingsReturnScroll = settingsScroll;
        openModal("menu-bar-lyrics");
        return;
    }
    if (modal != "menu-bar-lyrics" || closing) {
        return;
    }
    if (command == "back") {
        openModal("settings");
        settingsScroll = std::clamp(settingsReturnScroll, 0.0, settingsScrollMaximum());
        return;
    }

    const auto separator = command.indexOf(':');
    if (separator < 0) {
        return;
    }
    const auto name = command.left(separator);
    const auto argument = command.mid(separator + 1);
    if (name == "width") {
        bool valid = false;
        argument.toInt(&valid);
        if (valid) {
            const int width = MacMenuBar::parseLyricWidth(argument);
            m_host->setPreference(MacMenuBar::WidthPreference, QString::number(width));
        }
    } else if (argument == "on" || argument == "off") {
        if (name == "enabled") {
            m_host->setPreference(MacMenuBar::EnabledPreference, argument);
        } else if (name == "controls") {
            m_host->setPreference(MacMenuBar::ControlsPreference, argument);
        } else if (name == "icon") {
            m_host->setPreference(MacMenuBar::IconPreference, argument);
        }
    }
    m_host->invalidate();
}
