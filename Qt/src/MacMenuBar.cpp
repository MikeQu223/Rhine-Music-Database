#include "MacMenuBar.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QSet>

namespace MacMenuBar {
namespace {
const char *name(Component component) {
    switch (component) {
    case Component::Lyrics:
        return "lyrics";
    case Component::Controls:
        return "controls";
    case Component::Favorite:
        return "favorite";
    case Component::Icon:
        return "icon";
    }
    return "";
}

bool component(const QString &value, Component &result) {
    for (const auto candidate : defaultLayout()) {
        if (value == QLatin1String(name(candidate))) {
            result = candidate;
            return true;
        }
    }
    return false;
}
}

Layout defaultLayout() {
    return {Component::Lyrics, Component::Controls, Component::Favorite, Component::Icon};
}

Layout parseLayout(const QString &preference) {
    if (preference.trimmed().isEmpty()) {
        return defaultLayout();
    }
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(preference.toUtf8(), &error);
    if (error.error != QJsonParseError::NoError || !document.isArray()) {
        return defaultLayout();
    }
    Layout layout;
    QSet<QString> seen;
    for (const auto &value : document.array()) {
        if (!value.isString()) {
            return defaultLayout();
        }
        const auto item = value.toString();
        Component parsed;
        if (!component(item, parsed) || seen.contains(item)) {
            return defaultLayout();
        }
        seen.insert(item);
        layout.append(parsed);
    }
    return layout;
}

Layout effectiveLayout(Layout layout, bool enabled, const QString &controlsPreference,
                       const QString &iconPreference) {
    if (layout.isEmpty()) {
        return layout;
    }
    if (!enabled) {
        layout = {Component::Icon};
    } else if (controlsPreference == QLatin1String("off")) {
        layout.removeAll(Component::Controls);
        layout.removeAll(Component::Favorite);
    } else if (controlsPreference == QLatin1String("on")) {
        // 恢复缺少的控件时保留自定义布局已有组件的顺序。
        if (!layout.contains(Component::Controls)) {
            const auto lyricsIndex = layout.indexOf(Component::Lyrics);
            const auto iconIndex = layout.indexOf(Component::Icon);
            if (lyricsIndex >= 0) {
                layout.insert(lyricsIndex + 1, Component::Controls);
            } else if (iconIndex >= 0) {
                layout.insert(iconIndex, Component::Controls);
            } else {
                layout.append(Component::Controls);
            }
        }
        if (!layout.contains(Component::Favorite)) {
            layout.insert(layout.indexOf(Component::Controls) + 1, Component::Favorite);
        }
    }

    if (iconPreference == QLatin1String("off")) {
        layout.removeAll(Component::Icon);
    } else if (iconPreference == QLatin1String("on") && !layout.contains(Component::Icon)) {
        layout.append(Component::Icon);
    }
    return layout;
}

QString serializeLayout(const Layout &layout) {
    QJsonArray values;
    for (const auto item : layout) {
        values.append(QString::fromLatin1(name(item)));
    }
    return QString::fromUtf8(QJsonDocument(values).toJson(QJsonDocument::Compact));
}

QString lyricText(const QJsonObject &document, int index, bool useTranslation) {
    const auto lines = document["lines"].toArray();
    if (index < 0 || index >= lines.size()) {
        return {};
    }
    const auto line = lines.at(index).toObject();
    if (useTranslation) {
        const auto translation = line["translation"].toString().trimmed();
        if (!translation.isEmpty()) {
            return translation;
        }
    }
    const auto text = line["text"].toString().trimmed();
    return text.isEmpty() ? QStringLiteral("•••") : text;
}
}
