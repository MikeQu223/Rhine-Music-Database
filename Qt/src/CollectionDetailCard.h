#pragma once
#include <QJsonArray>
#include <QRectF>
#include <QString>
#include <QStringList>
#include <QVector>
#include <functional>

// 专辑/歌单/歌手详情卡的只读显示模型；卡片只绘制传入的数据与动作，不持有播放器、账号或网络对象。
namespace CollectionDetailCard {
struct Choice {
    QString label;
    QString action;
    bool selected = false;
};
struct Fact {
    QString label;
    QString value;
};
struct Row {
    QString number;
    QString title;
    QString artist;
    QString stamp;
    QString action;
    QString label;
    bool current = false;
};
struct Model {
    // 外框与版式沿用宿主原有布局，卡片只在其内部重新排版。
    QRectF bounds;
    double left = 40;
    double sidebar = 250;
    double x = 326;
    double width = 0;
    double rowsY = 434;
    double rowHeight = 54;
    int rowCount = 9;
    bool dark = false;
    QString kind;
    QString provider;
    QString title;
    QString artist;
    QString archiveId;
    QString coverKey;
    double coverSize = 0;
    QVector<Fact> facts;
    QString quote;
    QVector<Choice> tabs;
    Choice playAll;
    Choice sort;
    Choice rename;
    Choice remove;
    Choice subscribe;
    Choice source;
    Choice more;
    int totalCount = 0;
    int loadedCount = 0;
    QVector<Row> rows;
    // 移动端按可见窗口惰性读取；闭包持有只读的 Qt 隐式共享数据。
    std::function<Row(int)> rowAt;
    QString emptyMessage;
    QString hint;
    double scrollFraction = -1;
    double scrollThumb = 0;
};
struct Canvas {
    std::function<void(double, double, double, double, QJsonArray)> fill;
    std::function<void(QString, double, double, double, QString, double, QJsonArray)> text;
    std::function<QString(QString, double, double, QString)> fit;
    std::function<QStringList(QString, double, double, QString)> wrap;
    std::function<double(QString, double, QString)> measure;
    std::function<void(double, double, double, double, QString, QString)> hit;
    std::function<void(QString, double, double, double, double)> image;
};
void paint(const Model &model, const Canvas &canvas);
}
