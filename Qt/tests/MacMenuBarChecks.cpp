#include "MacMenuBar.h"
#include <QDebug>
#include <QJsonArray>

int main() {
    bool ok = true;
    const auto expect = [&ok](bool condition, const char *message) {
        if (!condition) {
            qCritical() << message;
            ok = false;
        }
    };

    const auto defaults = MacMenuBar::defaultLayout();
    expect(MacMenuBar::serializeLayout(defaults) ==
               QStringLiteral("[\"lyrics\",\"controls\",\"favorite\",\"icon\"]"),
           "Default component order without progress");
    expect(MacMenuBar::parseLayout({}) == defaults, "Missing layout must use defaults");
    expect(MacMenuBar::parseLayout(QStringLiteral("not json")) == defaults,
           "Malformed layout must use defaults");
    expect(MacMenuBar::parseLayout(QStringLiteral("[\"icon\",\"controls\",\"favorite\"]")).size() == 3,
           "Custom component count");
    const MacMenuBar::Layout custom{MacMenuBar::Component::Icon, MacMenuBar::Component::Controls,
                                    MacMenuBar::Component::Favorite};
    expect(MacMenuBar::parseLayout(MacMenuBar::serializeLayout(custom)) == custom,
           "Custom order must round-trip");
    expect(MacMenuBar::serializeLayout(custom) == QStringLiteral("[\"icon\",\"controls\",\"favorite\"]"),
           "Serialized component names");
    expect(MacMenuBar::parseLayout(QStringLiteral("[]")).isEmpty(), "An empty array hides every component");
    expect(MacMenuBar::parseLayout(QStringLiteral("[\"icon\",\"icon\"]")) == defaults,
           "Duplicate components must use defaults");
    expect(MacMenuBar::parseLayout(QStringLiteral("[\"unknown\"]")) == defaults,
           "Unknown components must use defaults");
    expect(MacMenuBar::parseLayout(QStringLiteral("[\"progress\"]")) == defaults,
           "Removed progress component must not be restored");
    expect(MacMenuBar::parseLayout(QStringLiteral("[null]")) == defaults,
           "Non-string components must use defaults");

    const QJsonObject document{
        {"lines", QJsonArray{QJsonObject{{"text", " 第一句 "}}, QJsonObject{{"text", "   "}}}}};
    expect(MacMenuBar::lyricText(document, 0) == QStringLiteral("第一句"), "Current lyric text");
    expect(MacMenuBar::lyricText(document, 1) == QStringLiteral("•••"), "Instrumental lyric placeholder");
    expect(MacMenuBar::lyricText(document, -1).isEmpty(), "No active lyric before the first line");
    expect(MacMenuBar::lyricText(document, 2).isEmpty(), "No active lyric after the document");

    if (ok) {
        qInfo() << "macOS menu-bar layout and lyric regressions passed";
    }
    return ok ? 0 : 1;
}
