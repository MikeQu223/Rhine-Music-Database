#pragma once
#include <QByteArray>
#include <QHash>
#include <QJsonObject>
#include <QVector>
#include <QtGlobal>

struct SceneDrawData {
    QByteArray matrices;
    QByteArray themes;
    // 逐实例稳定 id，与 matrices 的 64 字节条目一一对应；为空表示该 draw 没有实例身份，
    // 运动矢量只能退回按平移列配对。存 QVector<quint32> 而不是紧凑字节串：
    // 条数可直接与实例数比较、重排能复用矩阵那套按 index 取值的写法，
    // 也不会出现矩阵条数与字节数不整除时残留半截 id 的情况。
    QVector<quint32> ids;
};
using SceneDrawBuffers = QHash<int, SceneDrawData>;

/**
 * 被聚焦的主体：详情页与查看封面页只有焦点唱片用玻璃壳与主光。
 *
 * 详情页背景仍是同一批卡片，它们与焦点卡片一样是逐卡的非实例化 draw（每张
 * count=1、instanced=false），所以不能只靠"非实例化"来判定——那样背景卡也会
 * 被一起加上玻璃壳和主光，表现为归位过程里整片卡片发亮。这里再按
 * musicSelected 收一次：查看封面页只有一张卡，直接全放行。
 */
inline bool isFocusedSceneCard(const QJsonObject &draw, bool detailMode, bool viewer) {
    return detailMode && !draw["instanced"].toBool() && (viewer || draw["musicSelected"].toBool());
}
