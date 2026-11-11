#pragma once
#include <QString>
#include <QVector>

// 辅助内容的语义端口。渲染器直接交付文字、动作、图片和字段，不解析桌面绘图命令或坐标。
namespace ResponsiveHudContent {
struct Item {
    QString title;
    QString action;
    QString image;
    QString field;
    bool primary = false;
};
class Model {
  public:
    QVector<Item> items;
    void text(QString value);
    void action(QString title, QString route);
    void image(QString key);
    void field(QString name, QString label);
};
}
