#pragma once
#include <QJsonArray>
#include <QString>
#include <QStringList>
#include <QVector>
#include <functional>

// 只描述歌曲卡片的显示值与已有动作，不持有播放器、账号或网络对象。
namespace SongDetailCard {
struct Action {
    QString label;
    QString route;
};
struct Model {
    double x;
    double width;
    bool dark;
    bool local;
    QString id;
    QString title;
    QStringList titleLines;
    QString artist;
    QString album;
    QString duration;
    QString playback;
    QString quality;
    QString badgeKey;
    double badgeWidth = 0;
    QString tab;
    int trackCount = 0;
    bool comments = false;
    QVector<Action> primaryActions;
    QVector<Action> secondaryActions;
};
// 绘图端口由宿主提供；卡片不依赖 HUD 控制器的状态和生命周期。
struct Canvas {
    std::function<void(double, double, double, double, QJsonArray)> fill;
    std::function<void(QString, double, double, double, QString, QJsonArray)> text;
    std::function<void(QString, double, double, double, double, QString)> limited;
    std::function<void(double, double, double, double, QString, QString)> hit;
    std::function<void(QString, double, double, double, double)> image;
};
void paint(const Model &model, const Canvas &canvas);
}
