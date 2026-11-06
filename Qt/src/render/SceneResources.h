#pragma once

#include "../CrashDiagnostics.h"

#include <QByteArray>
#include <rhi/qrhi.h>
#include <algorithm>
#include <memory>
#include <vector>

namespace RhineRender {
/** MetalFX 运动输入的资源所有权及动态矩阵缓冲复用；不改变原材质资源池。 */
class SceneResources {
  public:
    explicit SceneResources(QRhi *device) : rhi(device) {
    }
    QRhi *rhi;
    QRhiResourceUpdateBatch *updates = nullptr;
    quint64 generation = 0;
    std::vector<std::unique_ptr<QRhiResource>> resources;
    std::vector<std::unique_ptr<QRhiResource>> sized;
    std::vector<std::unique_ptr<QRhiResource>> transient;
    struct BufferState {
        QRhiBuffer *buffer = nullptr;
        QByteArray bytes;
        quint64 used = 0;
    };
    template <class T> T *own(T *value, bool resize = false, bool temporary = false) {
        if (temporary) {
            transient.emplace_back(value);
        } else if (resize) {
            sized.emplace_back(value);
        } else {
            resources.emplace_back(value);
        }
        return value;
    }
    template <class T> T *create(T *value, std::source_location source = std::source_location::current()) {
        CrashRenderScope diagnosticScope("resource.create", source);
        CrashDiagnostics::recordResource(value);
        if (!value->create()) {
            qFatal("RHI resource allocation failed");
        }
        return value;
    }
    QRhiTexture *texture(QSize s, QRhiTexture::Format format, QRhiTexture::Flags flags = {},
                         bool resize = false) {
        return create(own(rhi->newTexture(format, s, 1, flags), resize));
    }
    void retire(QRhiResource *texture) {
        if (!texture) {
            return;
        }
        auto it =
            std::find_if(resources.begin(), resources.end(), [&](auto &v) { return v.get() == texture; });
        if (it != resources.end()) {
            it->release()->deleteLater();
            resources.erase(it);
        }
    }
    QRhiBuffer *dynamicBuffer(BufferState &state, const QByteArray &bytes, QRhiBuffer::UsageFlags usage) {
        if (!state.buffer || state.buffer->size() < bytes.size()) {
            retire(state.buffer);
            const int capacity = qMax(256, int(bytes.size()) * 2);
            state.buffer = create(own(rhi->newBuffer(QRhiBuffer::Dynamic, usage, capacity)));
            state.bytes.clear();
        }
        if (state.bytes != bytes) {
            // 单个连续区间覆盖实际变化；容量增长之外不再创建每帧临时 GPU 对象。
            qsizetype first = 0, last = bytes.size();
            if (state.bytes.size() == bytes.size()) {
                while (first < last && state.bytes[first] == bytes[first]) {
                    ++first;
                }
                while (last > first && state.bytes[last - 1] == bytes[last - 1]) {
                    --last;
                }
            }
            first = (first / 4) * 4;
            last = qMin(bytes.size(), ((last + 3) / 4) * 4);
            if (last > first) {
                updates->updateDynamicBuffer(state.buffer, int(first), int(last - first),
                                             bytes.constData() + first);
            }
            state.bytes = bytes;
        }
        state.used = generation;
        return state.buffer;
    }
};
} // namespace RhineRender
