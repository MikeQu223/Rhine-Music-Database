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

inline bool isFocusedSceneCard(const QJsonObject &draw, bool detailMode, bool viewer) {
    return detailMode && !draw["instanced"].toBool() && (viewer || draw["musicSelected"].toBool());
}
