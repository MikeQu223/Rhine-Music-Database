#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QRectF>
#include <functional>

namespace PlaybackQueueCard {
constexpr int VisibleRows = 7;
// 允许最后一首置顶，尾页不足七行时保留空白。
int maximumOffset(int trackCount);
struct Model {
    QRectF bounds;
    QJsonArray tracks;
    QJsonObject current;
    QString cover;
    QString mode;
    QString status;
    int currentIndex = -1;
    int offset = 0;
    bool playing = false;
    bool dark = false;
};
struct Canvas {
    std::function<void(double, double, double, double, QJsonArray)> fill;
    std::function<void(QString, double, double, double, QString, QJsonArray)> text;
    std::function<QString(QString, double, double, QString)> fit;
    std::function<void(double, double, double, double, QString, QString)> hit;
    std::function<void(QString, double, double, double, double)> image;
};
void paint(const Model &model, const Canvas &canvas);
}
