#pragma once

#include <QImage>
#include <QPainter>
#include <QSGTexture>
#include <rhi/qrhi.h>
#include <cstring>
#include <atomic>
#include <functional>

namespace RhineRender {

struct HudUploadCounters {
    std::atomic<quint64> bytes{0};
    std::atomic<quint64> uploads{0};
};
inline HudUploadCounters &hudUploadCounters() {
    static HudUploadCounters counters;
    return counters;
}

/** 保留完整 HUD 像素，只上传实际变化的区域；对象随场景图在渲染线程销毁。 */
class HudUploadTexture final : public QSGTexture {
  public:
    ~HudUploadTexture() override {
        if (texture) {
            texture->deleteLater();
        }
    }
    qint64 comparisonKey() const override {
        return texture ? qint64(texture) : qint64(this);
    }
    QRhiTexture *rhiTexture() const override {
        return texture;
    }
    QSize textureSize() const override {
        return canvas.size();
    }
    bool hasAlphaChannel() const override {
        return true;
    }
    bool hasMipmaps() const override {
        return false;
    }
    void paint(QSize pixels, const std::function<void(QPainter &)> &draw) {
        const bool resized = canvas.size() != pixels;
        if (resized) {
            canvas = QImage(pixels, QImage::Format_RGBA8888_Premultiplied);
        }
        canvas.fill(Qt::transparent);
        QPainter painter(&canvas);
        painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing |
                               QPainter::SmoothPixmapTransform);
        draw(painter);
        painter.end();
        findDirtyPixels(resized);
    }
    /** 上传批次持有独立小图，下一次绘制不会触发整张画布的隐式共享分离。 */
    void commitTextureOperations(QRhi *rhi, QRhiResourceUpdateBatch *updates) override {
        if (!texture || texture->pixelSize() != canvas.size()) {
            if (texture) {
                texture->deleteLater();
            }
            texture = rhi->newTexture(QRhiTexture::RGBA8, canvas.size(), 1);
            if (!texture->create()) {
                qFatal("Cannot allocate HUD texture");
            }
            texture->setName("Rhine HUD partial upload");
            dirty = canvas.rect();
        }
        if (dirty.isEmpty()) {
            return;
        }
        QRhiTextureSubresourceUploadDescription patch(canvas.copy(dirty));
        patch.setDestinationTopLeft(dirty.topLeft());
        updates->uploadTexture(texture, QRhiTextureUploadDescription{QRhiTextureUploadEntry(0, 0, patch)});
        uploadedBytes += quint64(dirty.width()) * dirty.height() * 4;
        ++uploads;
        hudUploadCounters().bytes.fetch_add(quint64(dirty.width()) * dirty.height() * 4);
        hudUploadCounters().uploads.fetch_add(1);
        static const bool probe = qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1;
        if (probe && uploads % 30 == 0) {
            qInfo("HUD partial upload: %llu uploads, %llu bytes, last %dx%d / %dx%d",
                  static_cast<unsigned long long>(uploads), static_cast<unsigned long long>(uploadedBytes),
                  dirty.width(), dirty.height(), canvas.width(), canvas.height());
        }
        dirty = {};
    }

  private:
    /** 镜像独占 CPU 字节，逐行比较；只有变化区间回写镜像，不复制整张旧图。 */
    void findDirtyPixels(bool resized) {
        if (resized || mirror.size() != canvas.sizeInBytes()) {
            mirror = QByteArray(reinterpret_cast<const char *>(canvas.constBits()), canvas.sizeInBytes());
            dirty = canvas.rect();
            return;
        }
        auto previousBytes = mirror.data();
        const int width = canvas.width();
        QRect changes;
        for (int y = 0; y < canvas.height(); ++y) {
            const auto current = reinterpret_cast<const quint32 *>(canvas.constScanLine(y));
            auto previous = reinterpret_cast<quint32 *>(previousBytes + y * canvas.bytesPerLine());
            if (std::memcmp(current, previous, size_t(width) * 4) == 0) {
                continue;
            }
            int first = 0;
            int last = width;
            while (first < last && current[first] == previous[first]) {
                ++first;
            }
            while (last > first && current[last - 1] == previous[last - 1]) {
                --last;
            }
            std::memcpy(previous + first, current + first, size_t(last - first) * 4);
            changes = changes.united(QRect(first, y, last - first, 1));
        }
        dirty = dirty.united(changes);
    }
    QImage canvas;
    QByteArray mirror;
    QRhiTexture *texture = nullptr;
    QRect dirty;
    quint64 uploadedBytes = 0;
    quint64 uploads = 0;
};
} // namespace RhineRender
