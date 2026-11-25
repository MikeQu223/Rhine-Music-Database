#pragma once
#include <QJsonArray>
#include <QRectF>
#include <QStringList>
#include <QVector>
#include <functional>

// 发现面板的只读显示模型；保留原动作标识，与平台请求、账号和播放器隔离。
namespace DiscoverMusicCard {
struct Choice {
    QString label;
    QString action;
    bool selected = false;
};
struct Entry {
    QString section;
    QString title;
    QString artist;
    QString kind;
    QString image;
    double imageAspect = 1;
    int index = 0;
};
struct Section {
    QString id;
    QString source;
    QString title;
    QString english;
    QString status;
    bool loading = false;
    bool failed = false;
    bool featured = false;
    QVector<Entry> entries;
};
struct Model {
    QRectF bounds;
    bool dark = false;
    QString tab;
    QString status;
    bool loading = false;
    bool more = false;
    QVector<Choice> tabs;
    QVector<Choice> tools;
    QVector<Choice> categories;
    QVector<Entry> entries;
    QVector<Section> sections;
    bool onePage = false;
    double scroll = 0;
    bool categoryPicker = false;
    bool categoriesLoading = false;
    QString categoryStatus;
    int categoryPage = 0;
    int categoryPages = 1;
    int loadedCount = 0;
    double textScale = 1.;
};
struct Canvas {
    std::function<void(double, double, double, double, QJsonArray)> fill;
    std::function<void(QString, double, double, double, QString, QJsonArray)> text;
    std::function<QString(QString, double, double, QString)> fit;
    std::function<QStringList(QString, double, double, QString)> wrap;
    std::function<void(double, double, double, double, QString, QString)> hit;
    std::function<void(QString, double, double, double, double)> image;
    std::function<void(double, double, double, QJsonArray)> circle;
    std::function<double(QString, double, QString)> measure;
    std::function<void(QJsonArray)> command;
};
constexpr int ArchiveColumns = 5;
constexpr double ViewportTop = 230;
constexpr double ViewportBottom = 748;
struct Layout {
    QRectF viewport;
    double tileSize = 0;
    double rowStride = 0;
    double maximumScroll = 0;
};
Layout layout(const QRectF &bounds, int count);
QRectF entryBounds(const QRectF &bounds, int index);
QVector<int> visibleIndices(const QRectF &bounds, int count, double scroll);
void paint(const Model &model, const Canvas &canvas);
}
