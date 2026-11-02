#pragma once

#include "../SceneTypes.h"
#include <QMatrix4x4>
#include <utility>

namespace RhineRender {

/** 聚焦对象的 draw ID 会复用于下一张唱片；用网格身份隔离换曲前后的单体历史。 */
inline QVector<quint32> motionInstanceIds(const QJsonObject &draw, const QVector<quint32> &nativeIds,
                                          const QJsonObject &selectedCell) {
    const bool focusedCell = draw["musicSelected"].toBool() && !draw["instanced"].toBool() &&
                             selectedCell["lane"].isDouble() && selectedCell["row"].isDouble();
    if (focusedCell) {
        // 聚焦角色的原生 ID 也会复用；网格身份必须先于角色 ID，归位对象仍用自己的稳定 ID。
        const quint32 lane = quint16(selectedCell["lane"].toInt());
        const quint32 row = quint16(selectedCell["row"].toInt());
        return {(lane << 16) | row};
    }
    return nativeIds;
}

/**
 * 保存上一张实际渲染帧的实例矩阵与相机；按稳定 ID 配对，避免列表重排和增删污染运动矢量。
 * 字节块采用隐式共享，只构建 ID 到偏移的索引，不为每个实例复制一份矩阵。
 */
class SceneTransformHistory {
  public:
    void reset() {
        m_buffers.clear();
        m_indices.clear();
        m_valid = false;
    }

    bool valid() const {
        return m_valid;
    }

    const QMatrix4x4 &viewProjection() const {
        return m_viewProjection;
    }

    const char *previousMatrix(int drawId, int index, const QVector<quint32> &currentIds) const {
        if (!m_valid || index < 0) {
            return nullptr;
        }
        const auto draw = m_buffers.constFind(drawId);
        if (draw == m_buffers.constEnd()) {
            return nullptr;
        }
        int previousIndex = -1;
        if (!currentIds.isEmpty()) {
            if (index >= currentIds.size()) {
                return nullptr;
            }
            const auto indices = m_indices.constFind(drawId);
            if (indices != m_indices.constEnd()) {
                previousIndex = indices->value(currentIds[index], -1);
            }
        } else if (draw->ids.isEmpty() && draw->matrices.size() == 64 && index == 0) {
            // 单体由 drawId 唯一识别；平移变化不改变身份，多实例没有 ID 时不猜测对应关系。
            previousIndex = 0;
        }
        if (previousIndex < 0 || (qsizetype(previousIndex) + 1) * 64 > draw->matrices.size()) {
            return nullptr;
        }
        return draw->matrices.constData() + qsizetype(previousIndex) * 64;
    }

    /** 只在主几何完成后提交；下一帧读取的历史因此与上一张颜色和深度保持同一代。 */
    void commit(const SceneDrawBuffers &buffers, const QMatrix4x4 &view, const QMatrix4x4 &projection) {
        QHash<int, QHash<quint32, int>> nextIndices;
        nextIndices.reserve(buffers.size());
        // 背景部件共享同一份实例包；一帧内每份 ID 序列只建一次索引。
        QHash<QPair<quintptr, qsizetype>, QHash<quint32, int>> sharedIndices;
        for (auto draw = buffers.constBegin(); draw != buffers.constEnd(); ++draw) {
            if (draw->ids.isEmpty()) {
                continue;
            }
            const auto records = qMin(draw->ids.size(), draw->matrices.size() / 64);
            const auto sharedKey = qMakePair(quintptr(draw->ids.constData()), records);
            const auto shared = sharedIndices.constFind(sharedKey);
            if (shared != sharedIndices.constEnd()) {
                nextIndices.insert(draw.key(), *shared);
                continue;
            }
            const auto previous = m_buffers.constFind(draw.key());
            if (previous != m_buffers.constEnd() && previous->ids == draw->ids &&
                previous->matrices.size() == draw->matrices.size()) {
                const auto indices = m_indices.value(draw.key());
                sharedIndices.insert(sharedKey, indices);
                nextIndices.insert(draw.key(), indices);
                continue;
            }
            QHash<quint32, int> indices;
            indices.reserve(draw->ids.size());
            for (int index = 0; index < draw->ids.size(); ++index) {
                if ((qsizetype(index) + 1) * 64 > draw->matrices.size()) {
                    break;
                }
                indices.insert(draw->ids[index], index);
            }
            sharedIndices.insert(sharedKey, indices);
            nextIndices.insert(draw.key(), std::move(indices));
        }
        m_indices = std::move(nextIndices);
        m_buffers = buffers;
        m_viewProjection = projection * view;
        m_valid = true;
    }

  private:
    SceneDrawBuffers m_buffers;
    QHash<int, QHash<quint32, int>> m_indices;
    QMatrix4x4 m_viewProjection;
    bool m_valid = false;
};

} // namespace RhineRender
