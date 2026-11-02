#include "render/SceneTransformHistory.h"
#include <QMatrix4x4>
#include <QVector4D>
#include <cstdio>
#include <cstring>

namespace {
int failures = 0;
void check(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "%s\n", message);
        ++failures;
    }
}
QByteArray matrixBytes(float x, float y) {
    QMatrix4x4 matrix;
    matrix.translate(x, y, 0);
    return QByteArray(reinterpret_cast<const char *>(matrix.constData()), 64);
}
float previousX(const char *bytes) {
    float value = 0;
    if (bytes) {
        std::memcpy(&value, bytes + 48, sizeof(value));
    }
    return value;
}
}

/** 覆盖渲染器真实使用的帧历史：移动、重排、可见集合增删、截断和设备重置。 */
int main() {
    RhineRender::SceneTransformHistory history;
    QMatrix4x4 view;
    view.translate(3, 4, 0);
    QMatrix4x4 projection;
    projection.scale(2, 3, 1);
    SceneDrawBuffers buffers;
    buffers.insert(10, {matrixBytes(1, 0) + matrixBytes(2, 0), {}, {11, 22}});
    buffers.insert(20, {matrixBytes(8, 0), {}});
    check(!history.previousMatrix(10, 0, {11, 22}), "首帧不能读取历史");
    history.commit(buffers, view, projection);
    check(previousX(history.previousMatrix(10, 0, {22, 11})) == 2, "重排后须按实例 ID 取上一帧");
    check(previousX(history.previousMatrix(10, 1, {33, 11, 22})) == 1, "条数增加不能丢掉已有实例历史");
    check(!history.previousMatrix(10, 0, {33, 11, 22}), "新增实例没有历史");
    check(previousX(history.previousMatrix(10, 0, {22})) == 2, "条数减少仍按 ID 匹配");
    check(previousX(history.previousMatrix(20, 0, {})) == 8, "单体平移通过 draw ID 保持身份");
    check(!history.previousMatrix(10, 0, {}), "多实例缺少 ID 时不能按位置猜测");
    check(!history.previousMatrix(10, -1, {11}), "负下标必须拒绝");
    check(!history.previousMatrix(10, 1, {11}), "越界 ID 必须拒绝");
    const auto projected = history.viewProjection() * QVector4D(1, 1, 0, 1);
    check(projected == QVector4D(8, 15, 0, 1), "相机矩阵须先 view 再 projection");
    buffers[10] = {matrixBytes(4, 0) + matrixBytes(9, 0), {}, {22, 11}};
    history.commit(buffers, view, projection);
    check(previousX(history.previousMatrix(10, 1, {22, 11})) == 9, "下一代使用实际提交的新矩阵");
    buffers[10] = {matrixBytes(5, 0), {}, {22, 11}};
    history.commit(buffers, view, projection);
    check(!history.previousMatrix(10, 0, {11}), "截断的矩阵块不能越界读取");
    buffers[10] = {matrixBytes(5, 0) + matrixBytes(7, 0), {}, {22, 11}};
    history.commit(buffers, view, projection);
    check(previousX(history.previousMatrix(10, 0, {11})) == 7, "矩阵块恢复后不能复用截断时期的不完整索引");
    buffers.remove(20);
    history.commit(buffers, view, projection);
    check(!history.previousMatrix(20, 0, {}), "消失的 draw 不能残留历史");
    const QJsonObject focused{{"musicSelected", true}, {"instanced", false}};
    const QJsonObject cellA{{"lane", 2}, {"row", 12}};
    const QJsonObject cellB{{"lane", 2}, {"row", 13}};
    const auto idsA = RhineRender::motionInstanceIds(focused, {}, cellA);
    const auto idsB = RhineRender::motionInstanceIds(focused, {}, cellB);
    check(idsA != idsB, "聚焦 draw ID 复用不能串到上一张唱片的身份");
    buffers[20] = {matrixBytes(8, 0), {}, idsA};
    history.commit(buffers, view, projection);
    check(history.previousMatrix(20, 0, idsA), "同一聚焦唱片移动仍应保留历史");
    check(!history.previousMatrix(20, 0, idsB), "下一张唱片不能读取旧聚焦唱片的历史");
    check(RhineRender::motionInstanceIds(focused, {2}, cellA) == idsA &&
              RhineRender::motionInstanceIds(focused, {2}, cellB) == idsB,
          "原生聚焦角色 ID 复用时仍须按网格身份隔离切歌");
    check(RhineRender::motionInstanceIds({}, {123}, cellA) == QVector<quint32>{123},
          "非聚焦对象仍保留原生实例身份");
    const QVector<quint32> sharedIds{11, 22};
    buffers[30] = {matrixBytes(1, 0) + matrixBytes(2, 0), {}, sharedIds};
    buffers[31] = {matrixBytes(3, 0) + matrixBytes(4, 0), {}, sharedIds};
    history.commit(buffers, view, projection);
    check(previousX(history.previousMatrix(30, 0, {22})) == 2 &&
              previousX(history.previousMatrix(31, 0, {22})) == 4,
          "共享 ID 序列的部件仍读取各自的矩阵块");
    buffers[31].matrices = matrixBytes(3, 0);
    history.commit(buffers, view, projection);
    check(!history.previousMatrix(31, 0, {22}) && previousX(history.previousMatrix(30, 0, {22})) == 2,
          "共享 ID 序列不能掩盖某个部件的矩阵截断");
    check(RhineRender::motionInstanceIds({}, {}, cellA).isEmpty(), "普通单体仍由 draw ID 保持身份");
    history.reset();
    check(!history.valid() && !history.previousMatrix(10, 0, {22}), "重置后历史全部失效");
    return failures == 0 ? 0 : 1;
}
