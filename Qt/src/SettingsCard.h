#pragma once
#include "SettingsSchema.h"
#include <QJsonArray>
#include <QRectF>
#include <QString>
#include <QVector>
#include <functional>

/** 设置页的纯布局绘制层 */
namespace SettingsCard {
struct RowModel {
    const SettingsSchema::SettingDescriptor *descriptor = nullptr;
    SettingsSchema::SettingsValue value;
    QString label;
    QVector<SettingsSchema::SettingChoice> choices;
    QString targetValue;
    QString decrementValue;
    QString incrementValue;
    QVector<int> numericValues;
    bool enabled = true;
    bool expanded = false;
};

struct SectionModel {
    const SettingsSchema::SettingsSection *meta = nullptr;
    QVector<RowModel> rows;
};

struct Model {
    QRectF viewport;
    double scroll = 0;
    double textScale = 1;
    QString expandedId;
    QVector<SectionModel> sections;
};

struct RowLayout {
    const RowModel *row = nullptr;
    double textScale = 1;
    QRectF bounds;
    QRectF control;
    QRectF options;
    double optionsHeight = 0;
};

struct SectionLayout {
    const SectionModel *section = nullptr;
    double textScale = 1;
    QRectF header;
    QRectF body;
    double height = 0;
    QVector<RowLayout> rows;
};

struct Layout {
    QRectF viewport;
    double contentHeight = 0;
    double maximumScroll = 0;
    QVector<SectionLayout> sections;
};

struct Colors {
    QJsonArray ink;
    QJsonArray muted;
    QJsonArray faint;
    QJsonArray line;
    QJsonArray soft;
    QJsonArray gold;
    QJsonArray panel;
};

struct Canvas {
    std::function<void(double, double, double, double, QJsonArray)> fill;
    std::function<void(QString, double, double, double, QString, double, QJsonArray)> text;
    std::function<QString(QString, double, double, QString)> fit;
    std::function<void(double, double, double, double, QString, QString)> hit;
    std::function<void(const QRectF &, QJsonArray)> stroke;
    std::function<void(QString, double, double, double, QString, bool)> centered;
    std::function<void(QString, const QRectF &, double)> custom;
};

Layout layout(const Model &model);
void paint(const Model &model, const Layout &layout, const Colors &colors, const Canvas &canvas);
}
