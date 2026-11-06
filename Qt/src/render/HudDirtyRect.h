#pragma once

#include <QJsonArray>
#include <QRectF>
#include <QSizeF>
#include <QString>
#include <QVector>
#include <QtGlobal>

namespace RhineRender {

/** 命令流两帧之间的差异区域；`full` 为真时调用方必须整块重画。 */
struct HudDirtyResult {
    QRectF rect;
    bool full = true;
};

namespace hud_dirty {

/// save/restore 作用域：裁剪区 + 作用域内的状态是否变过。
struct Scope {
    QRectF clip;
    bool dirty = false;
};

/**
 * 单条绘制命令在舞台坐标（1080 高度、原点左上）里的保守包围盒。
 *
 * 能精确算的用参数算；文字与艺术字宽度不可知，直接取当前裁剪区的整幅宽度，
 * 只把纵向压到这一行——保守但足够紧，因为被重画的区域本来也就在裁剪区里。
 * 路径类（fill-path / path / arc）解析要重写一遍 path 语法，一律用裁剪区兜底。
 */
inline bool bounds(const QJsonArray &command, const QRectF &clip, QRectF *out) {
    if (command.isEmpty()) {
        return false;
    }
    const auto op = command.at(0).toString();
    const auto n = [&command](int i) { return command.at(i).toDouble(); };
    if (op == QLatin1String("fill") || op == QLatin1String("ellipse")) {
        *out = QRectF(n(2), n(3), n(4), n(5));
        return true;
    }
    if (op == QLatin1String("image")) {
        *out = QRectF(n(2), n(3), n(4), n(5));
        return true;
    }
    if (op == QLatin1String("right-mask")) {
        // 与 Glyphs::renderCommands 一致：从 start 铺到 endX，纵向 0..height。
        *out = QRectF(n(2), 0, n(4) - n(2), n(5));
        return true;
    }
    if (op == QLatin1String("text") || op == QLatin1String("art")) {
        const double size = n(4);
        // 基线上下各留余量：y 是基线，上到 1.35 em，下到 0.5 em 足够覆盖降部与描边。
        *out = QRectF(clip.left(), n(3) - size * 1.35, clip.width(), size * 1.85);
        return true;
    }
    if (op == QLatin1String("fill-path") || op == QLatin1String("path") || op == QLatin1String("arc")) {
        *out = clip;
        return true;
    }
    // gradient 是整屏铺底，其余命令未登记：都按"无法定位"处理。
    return false;
}

inline void merge(QRectF *box, const QRectF &piece) {
    if (piece.isNull()) {
        return;
    }
    *box = box->isNull() ? piece : box->united(piece);
}

/// clip 命令的语义是 IntersectClip，与 Glyphs::renderCommands 保持一致。
inline QRectF intersectClip(const QRectF &clip, const QJsonArray &command) {
    const QRectF rect(command.at(1).toDouble(), command.at(2).toDouble(), command.at(3).toDouble(),
                      command.at(4).toDouble());
    return rect.isNull() ? clip : clip.intersected(rect);
}

} // namespace hud_dirty

/**
 * 比对前后两份 HUD 命令流，算出真正需要重画与重传纹理的舞台矩形。
 *
 * 为什么要自己算：Hud 是 QQuickPaintedItem，一条命令流画满整张画布，滑动时
 * 每帧都要重新栅格化 2880x1800 并整张上传（docs/ANDROID.md「滑动列表掉帧」）。
 * QPainter 只能靠 clip 省栅格化，纹理要省带宽就得先知道"哪块变了"。
 *
 * 安全优先：save/restore 结构变化、出现 translate/scale/rotate、命令条数变化、
 * 或者遇到不认识的命令，一律 `full = true` 退回整块重画——宁可多画一帧，
 * 也不能留残影。正常 HUD 只有启动动画用变换，代价可以接受。
 */
inline HudDirtyResult hudDirtyRect(const QJsonArray &before, const QJsonArray &after, const QSizeF &stage) {
    using namespace hud_dirty;
    HudDirtyResult result;
    result.full = false;
    result.rect = QRectF();
    const QRectF root(0, 0, stage.width() > 0 ? stage.width() : 1920, 1080);
    QVector<Scope> oldStack{Scope{root, false}};
    QVector<Scope> newStack{Scope{root, false}};
    const qsizetype count = qMax(before.size(), after.size());
    for (qsizetype i = 0; i < count; ++i) {
        const QJsonArray a = i < before.size() ? before.at(i).toArray() : QJsonArray();
        const QJsonArray b = i < after.size() ? after.at(i).toArray() : QJsonArray();
        const bool changed = a != b;
        const auto op = (b.isEmpty() ? a : b).at(0).toString();
        if (op == QLatin1String("save")) {
            if (changed) {
                result.full = true;
                return result;
            }
            oldStack.append(oldStack.last());
            newStack.append(newStack.last());
            continue;
        }
        if (op == QLatin1String("restore")) {
            if (changed || oldStack.size() < 2 || newStack.size() < 2) {
                result.full = true;
                return result;
            }
            oldStack.removeLast();
            newStack.removeLast();
            continue;
        }
        if (op == QLatin1String("translate") || op == QLatin1String("scale") ||
            op == QLatin1String("rotate")) {
            result.full = true;
            return result;
        }
        if (op == QLatin1String("clip")) {
            const QRectF oldBefore = oldStack.last().clip;
            const QRectF newBefore = newStack.last().clip;
            oldStack.last().clip = intersectClip(oldBefore, a);
            newStack.last().clip = intersectClip(newBefore, b);
            if (changed) {
                // 裁剪变了：旧裁剪区里可能有"现在不该显示"的残留，新裁剪区里
                // 可能有"现在才该出现"的内容。四块都算脏，交给重绘覆盖。
                merge(&result.rect, oldBefore);
                merge(&result.rect, newBefore);
                merge(&result.rect, oldStack.last().clip);
                merge(&result.rect, newStack.last().clip);
                oldStack.last().dirty = true;
                newStack.last().dirty = true;
            }
            continue;
        }
        if (op == QLatin1String("alpha")) {
            // 透明度作用到整个作用域，几何不变但像素会变：作用域内全部算脏。
            if (changed) {
                oldStack.last().dirty = true;
                newStack.last().dirty = true;
            }
            continue;
        }
        if (a.isEmpty() || b.isEmpty()) {
            result.full = true;
            return result;
        }
        if (!changed && !oldStack.last().dirty && !newStack.last().dirty) {
            continue;
        }
        QRectF oldBox;
        QRectF newBox;
        if (!bounds(a, oldStack.last().clip, &oldBox) || !bounds(b, newStack.last().clip, &newBox)) {
            result.full = true;
            return result;
        }
        merge(&result.rect, oldBox);
        merge(&result.rect, newBox);
    }
    return result;
}

} // namespace RhineRender
