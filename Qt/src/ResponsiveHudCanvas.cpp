#include "ResponsiveHudCanvas.h"
#include <algorithm>
#include <cmath>

ResponsiveHudCanvas::ResponsiveHudCanvas(Glyphs &glyphs, double scale, double h, bool dark)
    : height(h), unit(scale), m_glyphs(glyphs) {
    ink = dark ? QJsonArray{.925, .933, .886, 1} : QJsonArray{.082, .110, .090, 1};
    muted = dark ? QJsonArray{.63, .68, .60, 1} : QJsonArray{.404, .431, .388, 1};
    line = dark ? QJsonArray{.23, .28, .24, 1} : QJsonArray{.741, .753, .702, 1};
    paper = dark ? QJsonArray{.075, .110, .094, 1} : QJsonArray{.933, .925, .894, 1};
    surface = dark ? QJsonArray{.125, .165, .137, 1} : QJsonArray{.910, .902, .863, 1};
    raised = dark ? QJsonArray{.165, .208, .173, 1} : QJsonArray{.871, .875, .820, 1};
    amber = {.780, .608, .224, 1};
    commands.append(QJsonArray{"save"});
    commands.append(QJsonArray{"scale", unit, unit});
}
QPair<int, int> ResponsiveHudCanvas::visibleRows(double top, double stride, int count) const {
    const int first = std::clamp(int(std::floor((m_clipTop - top) / stride)), 0, count);
    const int last = std::clamp(int(std::ceil((contentBottom - top) / stride)), first, count);
    return {first, last};
}
void ResponsiveHudCanvas::fill(QRectF r, QJsonArray c) {
    if (m_content && (r.bottom() <= m_clipTop || r.top() >= contentBottom)) {
        return;
    }
    commands.append(QJsonArray{"fill", c, r.x(), r.y(), r.width(), r.height()});
}
void ResponsiveHudCanvas::border(QRectF r, QJsonArray c) {
    fill({r.x(), r.y(), r.width(), .7}, c);
    fill({r.x(), r.bottom(), r.width(), .7}, c);
    fill({r.x(), r.y(), .7, r.height()}, c);
    fill({r.right(), r.y(), .7, r.height()}, c);
}
void ResponsiveHudCanvas::text(QString v, double x, double y, double size, double width, QString weight,
                               QJsonArray c) {
    if ((m_content && (y + size < m_clipTop || y > contentBottom)) || v.isEmpty() || width <= 0) {
        return;
    }

    if (m_glyphs.width(v, size, weight) > width) {
        while (!v.isEmpty() && m_glyphs.width(v + "…", size, weight) > width) {
            v.chop(1);
        }
        v += "…";
    }
    commands.append(QJsonArray{"text", v, x, y, size, weight, 0, c.isEmpty() ? ink : c});
}
void ResponsiveHudCanvas::rightText(QString v, double right, double y, double size, QString weight,
                                    QJsonArray color) {
    text(v, right - m_glyphs.width(v, size, weight), y, size, right, weight, color);
}
QStringList ResponsiveHudCanvas::wrap(QString v, double width, double size, QString weight) {
    return m_glyphs.wrap(v, width, size, weight);
}
double ResponsiveHudCanvas::measure(QString v, double size, QString weight) {
    return m_glyphs.width(v, size, weight);
}
double ResponsiveHudCanvas::paragraph(QString v, double x, double y, double size, double width, QJsonArray c,
                                      QString weight, int maximumLines, double lineSpacing) {
    const auto lines = m_glyphs.wrap(v, width, size, weight);
    const int count = maximumLines > 0 ? std::min(maximumLines, int(lines.size())) : lines.size();
    for (int index = 0; index < count; ++index) {
        text(lines[index] + (index == count - 1 && count < lines.size() ? "…" : ""), x, y, size, width,
             weight, c);
        y += size * lineSpacing;
    }
    return y;
}
void ResponsiveHudCanvas::centered(QString value, double cx, double cy, double size, QString weight,
                                   QJsonArray color) {
    const auto bounds = m_glyphs.bounds(value, size, weight);
    text(value, cx - bounds["x"].toDouble() - bounds["width"].toDouble() / 2,
         cy - bounds["y"].toDouble() - bounds["height"].toDouble() / 2, size, 393, weight, color);
}
void ResponsiveHudCanvas::icon(QString name, double x, double y, double size, QJsonArray color) {
    static const QHash<QString, QString> paths{
        {"search", "M 21 21 L 16 16 M 18 10 C 18 14.4 14.4 18 10 18 C 5.6 18 2 14.4 2 10 C 2 5.6 5.6 2 10 2 "
                   "C 14.4 2 18 5.6 18 10 Z"},
        {"settings", "M 4 6 L 20 6 M 4 12 L 20 12 M 4 18 L 20 18 M 8 3 L 8 9 M 16 9 L 16 15 M 10 15 L 10 21"},
        {"back", "M 15 5 L 8 12 L 15 19"},
        {"left", "M 20 12 L 4 12 L 10 6 M 4 12 L 10 18"},
        {"right", "M 4 12 L 20 12 L 14 6 M 20 12 L 14 18"},
        {"up", "M 12 21 L 12 3 L 6 9 M 12 3 L 18 9"},
        {"down", "M 12 3 L 12 21 L 6 15 M 12 21 L 18 15"},
        {"play", "M 8 4 L 21 12 L 8 20 Z"},
        {"pause", "M 8 4 L 8 20 M 16 4 L 16 20"},
        {"prev", "M 5 4 L 5 20 M 20 4 L 8 12 L 20 20 Z"},
        {"next", "M 19 4 L 19 20 M 4 4 L 16 12 L 4 20 Z"},
        {"repeat", "M 3 7 L 19 7 L 15 3 M 19 7 L 19 11 M 21 17 L 5 17 L 9 21 M 5 17 L 5 13"},
        {"shuffle", "M 3 5 L 6 5 C 10 5 14 19 18 19 L 22 19 L 18 15 M 22 19 L 18 23 M 3 19 L 6 19 C 10 19 14 "
                    "5 18 5 L 22 5 L 18 1 M 22 5 L 18 9"},
        {"transport-prev", "M 4 4 L 4 20 M 19 4 Q 21 3 21 6 L 21 18 Q 21 21 19 20 L 8 14 Q 5 12 8 10 Z"},
        {"transport-next", "M 20 4 L 20 20 M 5 4 Q 3 3 3 6 L 3 18 Q 3 21 5 20 L 16 14 Q 19 12 16 10 Z"},
        {"transport-pause", "M 6 4 L 10 4 L 10 20 L 6 20 Z M 15 4 L 19 4 L 19 20 L 15 20 Z"},
        {"song-heart", "M 12 21 C 8 18 2 14 2 8 C 2 2 9 1 12 5 C 15 1 22 2 22 8 C 22 14 16 18 12 21 Z"},
        {"queue-note",
         "M 2 5 L 18 5 M 2 12 L 13 12 M 2 19 L 10 19 M 21 5 L 21 17 C 21 23 13 23 13 19 C 13 15 19 15 21 17"},
        {"lyrics-lines", "M 3 5 L 21 5 M 3 11 L 15 11 M 3 17 L 18 17"},
        {"queue", "M 3 5 L 21 5 M 3 10 L 21 10 M 3 15 L 12 15 M 17 14 L 22 18 L 17 22 Z"},
        {"volume", "M 3 9 L 7 9 L 12 4 L 12 20 L 7 15 L 3 15 Z M 15 8 C 17 10 17 14 15 16 M 18 5 C 22 9 22 "
                   "15 18 19"},
        {"database",
         "M 3 5 C 3 1 21 1 21 5 C 21 9 3 9 3 5 L 3 19 C 3 23 21 23 21 19 L 21 5 M 3 12 C 3 16 21 16 21 12"},
        {"compass", "M 21 12 C 21 24 3 24 3 12 C 3 0 21 0 21 12 Z M 16 7 L 14 14 L 7 17 L 10 10 Z"},
        {"folder", "M 2 6 L 9 6 L 11 8 L 22 8 L 22 21 L 2 21 Z M 2 6 L 2 3 L 9 3 L 11 6 L 21 6"},
        {"heart", "M 12 24 L 0 12 L 0 5 L 5 0 L 10 0 L 12 3 L 14 0 L 19 0 L 24 5 L 24 12 Z"},
        {"close", "M 6 6 L 18 18 M 6 18 L 18 6"},
        {"user", "M 16 6 C 16 12 8 12 8 6 C 8 0 16 0 16 6 Z M 4 22 C 4 12 20 12 20 22"},
        {"more", "M 5 12 L 6 12 M 11 12 L 12 12 M 17 12 L 18 12"}};
    commands.append(QJsonArray{"save"});
    commands.append(QJsonArray{"translate", x, y});
    commands.append(QJsonArray{"scale", size / 24, size / 24});
    if (name == "heart-filled" || name == "song-heart-filled") {
        const QString pathName = name == "song-heart-filled" ? "song-heart" : "heart";
        commands.append(QJsonArray{"fill-path", paths[pathName], color.isEmpty() ? ink : color});
    } else {
        commands.append(
            QJsonArray{"path", paths.value(name, paths["more"]), 1.5, color.isEmpty() ? ink : color});
    }
    commands.append(QJsonArray{"restore"});
}
void ResponsiveHudCanvas::image(QString key, QRectF r) {
    if (!key.isEmpty() && (!m_content || (r.bottom() > m_clipTop && r.top() < contentBottom))) {
        commands.append(QJsonArray{"image", key, r.x(), r.y(), r.width(), r.height()});
    }
}
void ResponsiveHudCanvas::hit(QRectF r, QString action, QString label) {
    if (m_content) {
        r = r.intersected(QRectF(0, m_clipTop, 393, std::max(0., contentBottom - m_clipTop)));
    }
    if (action.isEmpty() || r.isEmpty()) {
        return;
    }
    hits.append(QJsonObject{{"x", r.x() * unit},
                            {"y", r.y() * unit},
                            {"width", r.width() * unit},
                            {"height", r.height() * unit},
                            {"action", action},
                            {"label", label},
                            {"fixed", true}});
}
void ResponsiveHudCanvas::field(QString name, QRectF r) {
    if (m_content) {
        r = r.intersected(QRectF(0, m_clipTop, 393, std::max(0., contentBottom - m_clipTop)));
    }
    if (r.isEmpty()) {
        return;
    }
    fields[name] = QJsonObject{
        {"x", r.x() * unit}, {"y", r.y() * unit}, {"width", r.width() * unit}, {"height", r.height() * unit}};
}
void ResponsiveHudCanvas::button(QRectF r, QString title, QString action, bool primary, bool selected) {
    fill(r, primary ? amber : selected ? raised : surface);
    if (!primary) {
        border(r, line);
    }
    text(title, r.x() + 12, r.y() + (r.height() - 13) / 2 - 1, 13, r.width() - 24,
         primary ? "demibold" : "regular", primary ? QJsonArray{.09, .125, .08, 1} : ink);
    hit(r, action, title);
}
void ResponsiveHudCanvas::chip(QRectF r, QString title, QString action, bool selected) {
    if (selected) {
        fill(r, raised);
    }
    border(r, selected ? muted : line);
    text(title, r.x() + 9, r.y() + 12, 11, r.width() - 18, "regular", selected ? ink : muted);
    hit(r, action, title);
}
void ResponsiveHudCanvas::section(double y, QString title, QString subtitle) {
    text(title, 20, y, 17, 220, "demibold");
    text(subtitle, 245, y + 5, 9, 128, "regular", muted);
}
void ResponsiveHudCanvas::row(double y, QString title, QString artist, QString stamp, QString action,
                              QString number, bool current, QString remove, QString playAction) {
    if (current) {
        fill({20, y, 353, 68}, raised);
        fill({20, y, 2, 68}, amber);
    }
    const double left = number.isEmpty() ? 20 : 54;
    text(number, 25, y + 24, 11, 26, "regular", muted);
    double titleWidth = remove.isEmpty() ? 270 : 260;
    if (!playAction.isEmpty()) {
        titleWidth = 235;
    }
    text(title, left, y + 12, 14, titleWidth, "demibold", current ? QJsonArray{.455, .333, .098, 1} : ink);
    text(artist, left, y + 36, 11, 270, "regular", muted);
    if (remove.isEmpty()) {
        if (playAction.isEmpty()) {
            text(stamp, 333, y + 26, 10, 40, "regular", muted);
        }
    } else {
        icon("close", 342, y + 25, 16);
        hit({329, y + 12, 44, 44}, remove, "移除 " + title);
    }
    fill({20, y + 67, 353, .6}, line);
    hit({20, y, remove.isEmpty() ? 353. : 305., 67}, action, title);
    if (!playAction.isEmpty()) {
        text("▶ 全部", 309, y + 24, 10, 64);
        hit({302, y + 12, 71, 44}, playAction, "播放全部 " + title);
    }
}
void ResponsiveHudCanvas::indexRow(double y, QString title, QString subtitle, QString action,
                                   QString iconName) {
    icon(iconName, 20, y + 24, 20);
    text(title, 52, y + 12, 14, 287, "demibold");
    text(subtitle, 52, y + 36, 11, 287, "regular", muted);
    icon("right", 352, y + 25, 16);
    fill({20, y + 67, 353, .6}, line);
    hit({20, y, 353, 67}, action, title);
}
void ResponsiveHudCanvas::beginContent(double top) {
    m_clipTop = top;
    m_content = true;
    commands.append(QJsonArray{"save"});
    commands.append(QJsonArray{"clip", 0, top, 393, std::max(0., contentBottom - top)});
}
void ResponsiveHudCanvas::endContent() {
    commands.append(QJsonArray{"restore"});
    m_content = false;
}
void ResponsiveHudCanvas::header(QString title, bool back, bool libraryBack, bool showSettings) {
    if (back) {
        icon("back", 28, 88);
        hit({16, 76, 44, 44}, "close-modal", "返回");
    }
    const double x = back ? 74 : 20;
    text("RHINE LAB / AUDIO ARCHIVE", x, 69, 8, libraryBack ? 175 : 240, "regular", muted);
    text(title, x, 87, 25, libraryBack ? 185 : back ? 246 : 300, "demibold");
    if (libraryBack) {
        // 独立资料库里左右切换没有意义，右上角改成显眼返回按钮。
        fill({269, 60, 104, 42}, raised);
        border({269, 60, 104, 42}, line);
        icon("left", 281, 71, 18);
        text("返回", 305, 71, 14, 60, "demibold");
        hit({263, 54, 116, 54}, "back", "返回资料库");
        return;
    }
    if (!showSettings) {
        return;
    }
    icon(title == "设置" ? "user" : "settings", 341, 79);
    hit({329, 66, 44, 44}, title == "设置" ? "saved" : "settings", title == "设置" ? "我的音乐" : "设置");
}
void ResponsiveHudCanvas::finish() {
    commands.append(QJsonArray{"restore"});
}
