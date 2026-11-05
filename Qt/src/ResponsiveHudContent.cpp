#include "ResponsiveHudContent.h"
#include <QTransform>
#include <algorithm>
#include <cmath>
namespace {
struct Text {
    QString value;
    QPointF point;
    double size = 14;
    bool used = false;
};
struct Image {
    QString key;
    QRectF bounds;
};
using Element = ResponsiveHudContent::Item;
QRectF hitRect(const QJsonObject &hit) {
    return {hit["x"].toDouble(), hit["y"].toDouble(), hit["width"].toDouble(), hit["height"].toDouble()};
}
bool navigation(const QString &action) {
    return QStringList{"search", "saved", "discover", "settings"}.contains(action);
}
}

QVector<ResponsiveHudContent::Item> ResponsiveHudContent::legacy(const QJsonArray &commands,
                                                                 const QJsonArray &hits,
                                                                 const QJsonObject &sourceState) {
    QVector<Text> texts;
    QVector<Image> images;

    struct PaintState {
        QTransform transform;
        double opacity = 1;
        QRectF clip{-100000, -100000, 200000, 200000};
    };
    PaintState paint;
    QVector<PaintState> stack;
    for (const auto &value : commands) {
        const auto command = value.toArray();
        const auto type = command[0].toString();
        if (type == "save") {
            stack.append(paint);
        } else if (type == "restore" && !stack.isEmpty()) {
            paint = stack.takeLast();
        } else if (type == "translate") {
            paint.transform.translate(command[1].toDouble(), command[2].toDouble());
        } else if (type == "scale") {
            paint.transform.scale(command[1].toDouble(), command[2].toDouble());
        } else if (type == "alpha") {
            paint.opacity *= command[1].toDouble();
        } else if (type == "clip") {
            paint.clip = paint.clip.intersected(paint.transform.mapRect(QRectF(
                command[1].toDouble(), command[2].toDouble(), command[3].toDouble(), command[4].toDouble())));
        } else if (type == "text") {
            auto point = paint.transform.map(QPointF(command[2].toDouble(), command[3].toDouble()));
            if (paint.opacity < .01 ||
                !paint.clip.intersects(QRectF(point, QSizeF(1, command[4].toDouble()))) ||
                command[7].toArray()[3].toDouble() < .01) {
                continue;
            }
            if (point.y() < 984 && !sourceState["modal"].toString().isEmpty()) {
                point.ry() -= sourceState["modalOffset"].toDouble();
            }
            if (point.y() < 984 && !command[1].toString().trimmed().isEmpty()) {
                texts.append({command[1].toString(), point, command[4].toDouble(), false});
            }
        } else if (type == "image") {
            const auto rect = paint.transform.mapRect(QRectF(command[2].toDouble(), command[3].toDouble(),
                                                             command[4].toDouble(), command[5].toDouble()));
            if (paint.opacity >= .01 && paint.clip.intersects(rect) && rect.top() < 950 &&
                rect.width() >= 40 && rect.height() >= 40) {
                images.append({command[1].toString(), rect});
            }
        }
    }
    QVector<Element> elements;
    for (const auto &value : hits) {
        const auto hit = value.toObject();
        const auto rect = hitRect(hit);
        const auto action = hit["action"].toString();
        if (rect.top() >= 984) {
            continue;
        }
        if (navigation(action) && rect.top() < 200) {
            continue;
        }
        if (rect.width() > 1500 && rect.height() > 500) {
            continue;
        }
        if (rect.bottom() <= 200 || action == "close-modal" || action == "back") {
            continue;
        }
        Element element{rect, action, hit["label"].toString(), {}, {}, {}, action == "music:play"};
        QStringList lines;
        Text *mainText = nullptr;
        for (auto &entry : texts) {
            if (!entry.used && rect.adjusted(-2, -2, 2, 2).contains(entry.point) &&
                (!mainText || entry.size > mainText->size)) {
                mainText = &entry;
            }
        }
        if (mainText) {
            element.title = mainText->value;
            mainText->used = true;
        }
        for (auto &text : texts) {
            if (!text.used && rect.adjusted(-2, -2, 2, 2).contains(text.point)) {
                lines.append(text.value);
                text.used = true;
            }
        }
        if (!lines.isEmpty()) {
            if (!mainText) {
                element.title = lines.takeFirst();
            }
            element.subtitle = lines.join(" / ");
        }
        if (sourceState["modal"] == "settings" && rect.width() < 600) {
            Text *caption = nullptr;
            for (auto &entry : texts) {
                if (!entry.used && entry.point.x() < rect.left() && entry.point.y() >= rect.top() - 10 &&
                    entry.point.y() < rect.bottom() && entry.size >= 16 &&
                    (!caption || entry.point.x() > caption->point.x())) {
                    caption = &entry;
                }
            }
            if (caption) {
                element.subtitle = element.title;
                element.title = caption->value;
                caption->used = true;
                for (auto &entry : texts) {
                    if (entry.point.x() < rect.left() && entry.point.y() >= rect.top() - 10 &&
                        entry.point.y() < rect.bottom()) {
                        entry.used = true;
                    }
                }
            }
        }
        if (!element.title.isEmpty() && element.title != "↑" && element.title != "↓") {
            elements.append(element);
        }
    }
    const bool form = sourceState["modal"] == "playlist-form" ||
                      (sourceState["modal"] == "login" && sourceState["loginMethod"] == "phone");
    const bool search = sourceState["modal"] == "search" || sourceState["modal"] == "saved";
    const auto inputX = sourceState["inputX"].toDouble();
    const auto inputWidth = sourceState["inputWidth"].toDouble();
    if (search) {
        elements.append(
            {{inputX, sourceState["inputY"].toDouble(), inputWidth, 54}, {}, {}, {}, {}, "input"});
    }
    if (sourceState["editingSetting"].toBool()) {
        elements.append(
            {{sourceState["editingSettingX"].toDouble(), sourceState["editingSettingY"].toDouble(),
              sourceState["editingSettingWidth"].toDouble(), sourceState["editingSettingHeight"].toDouble()},
             {},
             {},
             {},
             {},
             "setting"});
    }
    if (form) {
        elements.append({{inputX, 430, inputWidth, 55}, {}, {}, {}, {}, "account"});
        if (sourceState["modal"] == "login") {
            elements.append({{inputX, 541, inputWidth, 55}, {}, {}, {}, {}, "captcha"});
        }
        elements.append({{inputX, sourceState["modal"] == "login" ? 611. : 530., inputWidth, 44},
                         {},
                         {},
                         {},
                         {},
                         "submit"});
    }
    for (auto &text : texts) {
        if (!text.used && text.point.y() >= 200 && text.point.y() < 960 &&
            !text.value.startsWith("RHINE LAB /") && !text.value.startsWith("← 返回") &&
            !(text.value.size() <= 2 && text.value.toInt() > 0)) {
            auto element = Element{{text.point.x(), text.point.y(), 300, text.size + 8}, {}, text.value};
            elements.append(element);
        }
    }
    // 图片作为内容对象参与重排，而非复制整个桌面截图。
    for (const auto &image : images) {
        elements.append({image.bounds, {}, {}, {}, image.key});
    }
    std::stable_sort(elements.begin(), elements.end(), [](const auto &left, const auto &right) {
        const auto leftRow = std::floor(left.source.top() / 12);
        const auto rightRow = std::floor(right.source.top() / 12);
        if (leftRow != rightRow) {
            return leftRow < rightRow;
        }
        return left.source.left() < right.source.left();
    });
    return elements;
}
