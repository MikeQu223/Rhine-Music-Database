#pragma once
#include <QJsonObject>
#include <QJsonArray>
#include <QRectF>
#include <QString>
#include <QVector>

// 辅助弹层与设置扩展区的旧命令端口适配；主要页面使用明确的设计版式。
namespace ResponsiveHudContent {
struct Item {
    QRectF source;
    QString action;
    QString title;
    QString subtitle;
    QString image;
    QString field;
    bool primary = false;
};
QVector<Item> legacy(const QJsonArray &commands, const QJsonArray &hits, const QJsonObject &state);
}
