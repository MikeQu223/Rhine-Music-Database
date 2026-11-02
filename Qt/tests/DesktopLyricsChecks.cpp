#include "DesktopLyricsLayout.h"
#include <QDebug>
#include <QJsonArray>

/**
 * 桌面悬浮歌词的核心纯逻辑：内容提取、译文排版、底部居中。
 */
int main() {
    bool passed = true;
    const auto check = [&](bool value, const char *name) {
        if (!value) {
            qCritical() << "Desktop lyrics test failed:" << name;
            passed = false;
        }
    };

    const auto untimed = QJsonObject{{"timing", "none"}, {"lines", QJsonArray{QJsonObject{{"text", "x"}}}}};
    check(!DesktopLyrics::contentAt(untimed, 0).has_value(), "timing none");

    const auto document = QJsonObject{
        {"timing", "line"},
        {"lines",
         QJsonArray{
             QJsonObject{{"text", ""}, {"translation", "译"}},
             QJsonObject{{"text", "hello"}},
         }},
    };
    const auto interlude = DesktopLyrics::contentAt(document, 0);
    check(interlude && interlude->text == "•••" && interlude->translation == "译",
          "placeholder and translation");
    check(!DesktopLyrics::contentAt(document, 2).has_value(), "out-of-range index");

    const DesktopLyrics::TextMetrics metrics{
        [](const QString &text, double, double, const QString &) { return QStringList{text}; },
        [](const QString &text, double size, const QString &) { return double(text.size()) * size; },
    };
    const auto frame = DesktopLyrics::buildFrame({"hello", "world"}, metrics, 1000);
    check(frame.lineRows.size() == 1 && frame.translationRows.size() == 1 && frame.size.height() == 116,
          "translation participates in height");

    const auto point = DesktopLyrics::placeBottomCenter(QSizeF(400, 100), QRect(0, 0, 1000, 800));
    check(point == QPoint(300, 636), "bottom center placement");

    return passed ? 0 : 1;
}
