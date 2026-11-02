#include "Glyphs.h"
#include <QGuiApplication>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextBoundaryFinder>
#include <QDebug>
#include <cmath>

/** 直接验证实际绘制、度量和换行，不以业务状态存在代替字符可见。 */
int main(int argc, char **argv) {
    QGuiApplication application(argc, argv);
    const auto root = application.arguments().value(1);
    Glyphs glyphs(root);
    bool passed = true;
    const auto check = [&](bool valid, const QString &name) {
        qInfo() << "Glyph check:" << name << valid;
        passed &= valid;
    };
    QFile source(root + "/misans-glyphs.json");
    check(source.open(QIODevice::ReadOnly), "load baseline glyph metrics");
    const auto regular =
        QJsonDocument::fromJson(source.readAll()).object()["regular"].toObject()["glyphs"].toObject();
    const QString baseline = QStringLiteral("RHINE MUSIC / 2026");
    double expected = 0;
    for (QChar character : baseline) {
        expected += regular[QString(character)].toObject()["advance"].toDouble() * 24;
    }
    check(std::abs(glyphs.width(baseline, 24) - expected) < 0.000001, "existing Latin metrics remain exact");

    const QString korean = QStringLiteral("밤하늘의 별빛을 따라");
    const QStringList samples{QStringLiteral("中文与 English"),
                              QStringLiteral("君の声が聞こえる 髙﨑"),
                              korean,
                              korean.normalized(QString::NormalizationForm_D),
                              QStringLiteral("Cafe\u0301 か\u3099 𠮷野家"),
                              QStringLiteral("مرحبا بالعالم")};
    QImage preview(1100, 440, QImage::Format_ARGB32_Premultiplied);
    preview.fill(Qt::white);
    QPainter painter(&preview);
    painter.setRenderHint(QPainter::Antialiasing);
    for (int row = 0; row < samples.size(); ++row) {
        const auto &text = samples[row];
        const auto bounds = glyphs.bounds(text, 32);
        check(bounds["width"].toDouble() > 0 && bounds["height"].toDouble() > 0,
              QStringLiteral("multilingual text has visible outlines: %1").arg(text));
        const double advance = glyphs.width(text, 32);
        check(std::isfinite(advance) && advance > 0 && advance < 1000,
              "multilingual advance is finite and bounded");
        glyphs.text(painter, text, 30, 20 + row * 65, 32, "regular", 0, Qt::black);
    }
    painter.end();
    int koreanInk = 0;
    for (int y = 150; y < 210; ++y) {
        for (int x = 30; x < 800; ++x) {
            koreanInk += preview.pixelColor(x, y).lightness() < 128;
        }
    }
    check(koreanInk > 100, "Korean lyrics paint visible pixels");
    check(std::abs(glyphs.width(korean, 32) -
                   glyphs.width(korean.normalized(QString::NormalizationForm_D), 32)) < 0.001,
          "composed and decomposed Hangul use consistent metrics");
    const QString clusters = QStringLiteral("e\u0301か\u3099𠮷가");
    const auto lines = glyphs.wrap(clusters, 25, 32);
    check(lines.join(QString()) == clusters, "wrapping preserves all Unicode content");
    for (const auto &line : lines) {
        check(!line.isEmpty() && !line.front().isLowSurrogate() && !line.back().isHighSurrogate() &&
                  !line.front().isMark(),
              "wrapping never splits surrogate pairs or combining sequences");
    }
#ifdef Q_OS_DARWIN
    bool cachedAtLeastOnce = false;
    // 对照真实命令绘制和已命中的缓存，覆盖 DPR、亚像素、裁剪及背景合成。
    for (const auto format : {QImage::Format_ARGB32_Premultiplied, QImage::Format_RGBA8888_Premultiplied}) {
        for (double angle : {0., 13.7}) {
            for (double dpr : {1., 1.5, 2.}) {
                for (const QColor background :
                     {QColor(Qt::transparent), QColor(51, 69, 87, 103), QColor(230, 225, 214)}) {
                    for (double opacity : {1., .73}) {
                        for (bool clipped : {false, true}) {
                            const QJsonArray commands{
                                QJsonArray{"save"},
                                QJsonArray{"translate", 8.125, 3.375},
                                QJsonArray{"scale", .87, .87},
                                QJsonArray{"alpha", opacity},
                                QJsonArray{"right-mask", QJsonArray{.9, .89, .86, .5}, 60.25, 85., 460.,
                                           135.},
                                QJsonArray{"text", baseline, 12.25, 6.875, 22., "regular", .125,
                                           QJsonArray{.12, .2, .32, 1.}},
                                QJsonArray{"text", samples[0], 16.5, 43.25, 24., "demibold", 0.,
                                           QJsonArray{.8, .2, .11, .77}},
                                QJsonArray{"text", samples[5], 14.75, 78.125, 24., "regular", 0.,
                                           QJsonArray{.2, .4, .6, 1.}},
                                QJsonArray{"restore"}};
                            const auto render = [&](bool cached) {
                                QImage image(QSize(480 * dpr, 140 * dpr), format);
                                image.setDevicePixelRatio(dpr);
                                image.fill(background);
                                QPainter painter(&image);
                                if (clipped) {
                                    painter.setClipRect(QRectF(20.25, 13.75, 235.5, 79.25));
                                }
                                painter.rotate(angle);
                                glyphs.commands(painter, commands, [](QString) { return QImage(); }, cached);
                                painter.end();
                                return image;
                            };
                            glyphs.clearRasterCache();
                            const auto reference = render(false);
                            render(true);
                            render(true);
                            check(reference == render(true),
                                  QStringLiteral("raster cache exact: DPR %1 alpha %2 background %3 clip %4")
                                      .arg(dpr)
                                      .arg(opacity)
                                      .arg(background.name(QColor::HexArgb))
                                      .arg(clipped));
                            if (opacity == 1 && !clipped) {
                                check(glyphs.rasterCacheHits() > 0, "pixel comparison exercises a cache hit");
                            }
                            cachedAtLeastOnce |= glyphs.rasterCacheHits() > 0;
                        }
                    }
                }
            }
        }
    }
    check(cachedAtLeastOnce, "repeated text enters bounded raster cache");
    const QJsonArray maskedText{QJsonArray{"right-mask", QJsonArray{.9, .89, .86, .5}, 831, 300, 1920, 984},
                                QJsonArray{"text", "POWERED BY RHINE LAB", 1736.68, 967, 10, "demibold", 0,
                                           QJsonArray{.08, .085, .075, 1., "calibratedRGB"}},
                                QJsonArray{"text", "metal-baseline-s…", 60, 845, 37, "regular", 0,
                                           QJsonArray{.08, .085, .075, 1., "calibratedRGB"}},
                                QJsonArray{"text", "Rendering Reference", 1075.2, 332, 15, "regular", 0,
                                           QJsonArray{.08, .085, .075, 1., "calibratedRGB"}}};
    const auto renderMaskedText = [&](bool cached, QColor background = Qt::transparent) {
        QImage image(2560, 1440, QImage::Format_RGBA8888_Premultiplied);
        image.fill(background);
        QPainter painter(&image);
        painter.scale(1440. / 1080, 1440. / 1080);
        glyphs.commands(painter, maskedText, [](QString) { return QImage(); }, cached);
        painter.end();
        return image;
    };
    const auto maskedReference = renderMaskedText(false);
    renderMaskedText(true);
    renderMaskedText(true);
    check(maskedReference == renderMaskedText(true), "calibrated text over translucent mask remains exact");
    const auto hitsBeforeBackgroundChange = glyphs.rasterCacheHits();
    const QColor changedBackground(30, 60, 80, 91);
    check(renderMaskedText(false, changedBackground) == renderMaskedText(true, changedBackground),
          "background changes preserve pixels through original drawing");
    check(glyphs.rasterCacheHits() == hitsBeforeBackgroundChange,
          "changed background never reuses stale pixels");
    glyphs.clearRasterCache();
    check(glyphs.rasterCacheBytes() == 0, "hidden-window trim releases raster cache");
    {
        // 背景与结果刚好占满像素预算时，键仍需要空间；应在分配临时画布前回退。
        const QJsonArray largeMask{
            QJsonArray{"right-mask", QJsonArray{.9, .89, .86, .5}, 0, 4096, 4096, 1024}};
        QImage image(4096, 1024, QImage::Format_RGBA8888_Premultiplied);
        for (int frame = 0; frame < 3; ++frame) {
            image.fill(Qt::transparent);
            QPainter painter(&image);
            glyphs.commands(painter, largeMask, {}, true);
        }
        check(glyphs.rasterCacheBytes() == 0, "oversized masks avoid repeated scratch allocations");
        glyphs.clearRasterCache();
    }

#endif
    const auto previewPath = application.arguments().value(2);
    if (!previewPath.isEmpty()) {
        QDir().mkpath(QFileInfo(previewPath).absolutePath());
        check(preview.save(previewPath), "save multilingual rendering preview");
    }
    return passed ? 0 : 1;
}
