#include "NativeHud.h"
#include "PlatformFeatures.h"
#include <algorithm>

void NativeHud::shortcutsPanel(double x, double y, double width) {
    if (!shortcuts || !PlatformFeatures::GlobalShortcuts) {
        return;
    }
    const double left = x + 54, right = x + width - 54;
    const auto line = dark ? QJsonArray{1, 1, 1, 0.18} : QJsonArray{0, 0, 0, 0.18};
    const auto soft = dark ? QJsonArray{1, 1, 1, 0.05} : QJsonArray{0, 0, 0, 0.04};
    const auto muted = dark ? QJsonArray{1, 1, 1, 0.55} : QJsonArray{0, 0, 0, 0.55};
    const QJsonArray gold{0.835, 0.639, 0.282, 1};
    const double top = y + 200;
    button(shortcuts->enabled() ? "● 已启用全局快捷键" : "○ 启用全局快捷键", left, top, 250, 42,
           "shortcuts:enabled", 16);
    limited("窗口隐藏到托盘后也可响应；退出应用后释放绑定。", left + 270, top + 13, 13, right - left - 270);
    const double keyLeft = left + (right - left) * 0.43;
    const double clearLeft = right - 64;
    for (int i = 0; i < GlobalShortcuts::actions().size(); ++i) {
        const auto &action = GlobalShortcuts::actions()[i];
        const double row = top + 58 + i * 62;
        const bool recording = shortcuts->recording() == action.id;
        text(QString::number(i + 1).rightJustified(2, '0'), left, row + 16, 11, "regular", 0.04, muted);
        text(action.label, left + 30, row + 12, 16, "demibold", 0, ink());
        const auto error = shortcuts->error(action.id);
        if (!error.isEmpty()) {
            text(fit(error, 11, keyLeft - left - 40, "regular"), left + 30, row + 35, 11, "regular", 0, gold);
        }
        fill(keyLeft, row + 2, clearLeft - keyLeft - 10, 44, soft);
        fill(keyLeft, row + 2, 3, 44, recording ? gold : line);
        const auto binding = shortcuts->binding(action.id);
        const auto label = recording           ? QStringLiteral("请按下组合键…")
                           : binding.isEmpty() ? QStringLiteral("未设置 · 点击录入")
                                               : binding;
        text(fit(label, 16, clearLeft - keyLeft - 36, "regular"), keyLeft + 14, row + 15, 16, "regular", 0,
             recording ? gold : ink());
        hit(keyLeft, row + 2, clearLeft - keyLeft - 10, 44, "shortcuts:record:" + action.id,
            action.label + "快捷键");
        button("清除", clearLeft, row + 2, 64, 44, "shortcuts:clear:" + action.id, 13);
        fill(left, row + 55, right - left, 1, line);
    }
    button("恢复默认绑定", left, top + 566, 190, 42, "shortcuts:reset", 14);
    const auto message = shortcuts->message().isEmpty()
                             ? QStringLiteral("点击按键框录入；Esc 取消，Backspace / Delete 清除。")
                             : shortcuts->message();
    text(fit(message, 12, right - left - 210, "regular"), left + 210, top + 581, 12, "regular", 0,
         shortcuts->message().isEmpty() ? muted : gold);
}

void NativeHud::applyShortcutAction(const QString &value) {
    if (!shortcuts || !PlatformFeatures::GlobalShortcuts) {
        return;
    }
    const auto rest = value.mid(QStringLiteral("shortcuts:").size());
    if (rest == "open") {
        settingsReturnScroll = settingsScroll;
        openModal("shortcuts");
    } else if (rest == "back") {
        shortcuts->cancelRecording();
        openModal("settings");
        settingsScroll = std::clamp(settingsReturnScroll, 0., settingsScrollMaximum());
    } else if (rest == "enabled") {
        shortcuts->setEnabled(!shortcuts->enabled());
    } else if (rest == "reset") {
        shortcuts->restoreDefaults();
    } else if (rest.startsWith("record:")) {
        shortcuts->beginRecording(rest.mid(7));
    } else if (rest.startsWith("clear:")) {
        shortcuts->cancelRecording();
        shortcuts->setBinding(rest.mid(6), {});
    }
}
