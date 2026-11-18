#include "ResponsiveHudContent.h"

void ResponsiveHudContent::Model::text(QString value) {
    if (!value.trimmed().isEmpty()) {
        items.append({value, {}, {}, {}, false});
    }
}
void ResponsiveHudContent::Model::action(QString title, QString route) {
    if (route.isEmpty()) {
        text(title);
        return;
    }
    items.append({title, route, {}, {}, route == "music:play"});
}
void ResponsiveHudContent::Model::image(QString key) {
    if (!key.isEmpty()) {
        items.append({{}, {}, key, {}, false});
    }
}
void ResponsiveHudContent::Model::field(QString name, QString label) {
    text(label);
    items.append({{}, {}, {}, name, false});
}
