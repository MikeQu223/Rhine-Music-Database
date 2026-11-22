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

QString serializeLayout(const Layout &layout) {
    QJsonArray values;
    for (const auto item : layout) {
        values.append(QString::fromLatin1(name(item)));
    }
    return QString::fromUtf8(QJsonDocument(values).toJson(QJsonDocument::Compact));
}

QString lyricText(const QJsonObject &document, int index) {
    const auto lines = document["lines"].toArray();
    if (index < 0 || index >= lines.size()) {
        return {};
    }
    const auto text = lines.at(index).toObject()["text"].toString().trimmed();
    return text.isEmpty() ? QStringLiteral("•••") : text;
}
}
