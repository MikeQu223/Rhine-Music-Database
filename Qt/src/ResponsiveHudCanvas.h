#pragma once
#include "Glyphs.h"
#include <QJsonObject>
#include <QRectF>

// 393 pt 设计坐标；可视区域、命中区域与输入区域由同一次排版产生。
class ResponsiveHudCanvas {
  public:
    ResponsiveHudCanvas(Glyphs &glyphs, double unit, double height, bool dark);
    QJsonArray commands;
    QJsonArray hits;
    QJsonObject fields;
    double height;
    double unit;
    double contentBottom = 693;
    QJsonArray ink;
    QJsonArray muted;
    QJsonArray line;
    QJsonArray paper;
    QJsonArray surface;
    QJsonArray raised;
    QJsonArray amber;
    void fill(QRectF rect, QJsonArray color);
    void border(QRectF rect, QJsonArray color);
    void text(QString value, double x, double y, double size = 14, double width = 353,
              QString weight = "regular", QJsonArray color = {});
    void rightText(QString value, double right, double y, double size, QString weight, QJsonArray color);
    QStringList wrap(QString value, double width, double size, QString weight = "regular");
    double measure(QString value, double size, QString weight = "regular");
    double paragraph(QString value, double x, double y, double size, double width, QJsonArray color = {},
                     QString weight = "regular", int maximumLines = 0, double lineSpacing = 1.5);
    void centered(QString value, double cx, double cy, double size, QString weight = "regular",
                  QJsonArray color = {});
    void icon(QString name, double x, double y, double size = 20, QJsonArray color = {});
    void image(QString key, QRectF rect);
    void hit(QRectF rect, QString action, QString label);
    void field(QString name, QRectF rect);
    void button(QRectF rect, QString title, QString action, bool primary = false, bool selected = false);
    void chip(QRectF rect, QString title, QString action, bool selected = false);
    void section(double y, QString title, QString subtitle = {});
    void row(double y, QString title, QString artist, QString stamp, QString action, QString number = {},
             bool current = false, QString remove = {}, QString playAction = {});
    void indexRow(double y, QString title, QString subtitle, QString action, QString iconName);
    void beginContent(double top = 158);
    void endContent();
    void header(QString title, bool back, bool libraryBack = false);
    void finish();

  private:
    Glyphs &m_glyphs;
    double m_clipTop = 0;
    bool m_content = false;
};
