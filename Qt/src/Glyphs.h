#pragma once
#include <QCache>
#include <QHash>
#include <QFile>
#include <memory>
#include <vector>
#include <QImage>
#include <QJsonArray>
#include <QMutex>
#include <QObject>
#include <QPainter>
#include <QPainterPath>
#include <QRawFont>
#include <QStringList>
#include <QVariantMap>
class Glyphs : public QObject {
    Q_OBJECT
  public:
    explicit Glyphs(const QString &root);
    ~Glyphs() override;
    struct Glyph {
        double advance = 1;
        QPainterPath path;
    };
    Q_INVOKABLE double width(QString text, double size, QString weight = "regular", double tracking = 0);
    Q_INVOKABLE QVariantMap bounds(QString text, double size, QString weight = "regular");
    Q_INVOKABLE double inset(QString text, double size, QString weight = "regular");
    Q_INVOKABLE QStringList wrap(QString text, double width, double size, QString weight = "regular");
    Q_INVOKABLE double artWidth(QString key, double size, double tracking = 0, int count = -1);
    void text(QPainter &ctx, QString text, double x, double y, double size, QString weight, double tracking,
              QColor color);
    void art(QPainter &ctx, QString key, double x, double y, double size, int count, double tracking);
    QPainterPath path(const QString &svg);
    void commands(QPainter &ctx, const QJsonArray &commands, std::function<QImage(QString)> image);
#ifdef Q_OS_DARWIN
    void commands(QPainter &ctx, const QJsonArray &commands, std::function<QImage(QString)> image,
                  bool cacheText);
    void clearRasterCache();
    int rasterCacheBytes();
    quint64 rasterCacheHits();
#endif
    QImage label(const QJsonObject &item);

  private:
    // 字体只读映射必须晚于 QRawFont 析构，避免后端仍引用输入字节。
    std::vector<std::unique_ptr<QFile>> mappedFonts;
    QRawFont loadFont(const QString &filename);
    QRecursiveMutex mutex;
    QHash<QString, Glyph> glyphs;
    QHash<QString, QList<Glyph>> lettering;
    QHash<QString, QRawFont> fonts;
    QCache<QString, QPainterPath> paths{1024};
    QCache<QString, double> widths{1024};
    QCache<QString, QStringList> wrapped{128 * 1024};
    QList<int> applicationFonts;
    QHash<QString, QString> layoutFamilies;
    QCache<QString, Glyph> shapedText{32 * 1024};
#if defined(Q_OS_ANDROID)
    /// 整段文本 / 整串字形合并成一条路径后的缓存（em 单位，与字号无关）。
    /// 见 docs/ANDROID.md「滑动列表掉帧」：Android 上 QPainter 是软件栅格，逐字形
    /// fillPath 每次都要重做「变换 + 抗锯齿扫描线」，实测 HUD 重绘占单帧 sync 的绝大部分。
    QPainterPath textRunPath(const QString &value, const QString &weight, double trackingEm);
    QPainterPath artRunPath(const QString &key, int count, double trackingEm);
    bool drawCachedMask(QPainter &ctx, const QJsonArray &command);
    static bool runCacheEnabled();
    QCache<QString, QPainterPath> runPaths{512 * 1024};
    QCache<QString, QImage> maskGradients{8 * 1024};
#endif
    QCache<QString, bool> layoutRequired{1024};
    /// 命令分发的唯一实现；cacheText 只在 Apple 栅格缓存可用时生效，其他平台恒为 false。
    void renderCommands(QPainter &ctx, const QJsonArray &commands, std::function<QImage(QString)> image,
                        bool cacheText);
#ifdef Q_OS_DARWIN
    struct RasterText {
        QImage image;
        QImage background;
        QPoint origin;
    };
    QCache<QByteArray, RasterText> rasterText{32 * 1024 * 1024};
    QCache<QByteArray, bool> rasterCandidates{512 * 1024};
    QImage rasterScratch;
    quint64 rasterHits = 0;
    QRect rasterCommandBounds(const QJsonArray &command, const QTransform &transform);
    std::unique_ptr<RasterText> rasterizeCommand(QPainter &ctx, const QJsonArray &command,
                                                 const QImage &image, int pixelBudget);
    bool drawRasterCommand(QPainter &ctx, const QJsonArray &command);

#endif
    bool needsLayout(const QString &text, const QString &weight);
    Glyph layoutText(const QString &text, const QString &weight, double spacing);
    Glyph glyph(QString ch, QString weight);
};

void saveImageNative(const QImage &image, const QString &path);
