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
    /// 两份命令流逐条相同。调用方可以拿它代替 `before != after` 的第二次深比较。
    bool equal = false;
};

namespace hud_dirty {

/// save/restore 作用域：只管裁剪区，脏不脏由调用方按"中间段整体重画"决定。
struct Scope {
    QRectF clip;
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

/// 从流首走到 prefix 结束，重建 save/restore 与裁剪栈。出现变换命令就放弃（无法映射坐标）。
inline bool seedClips(const QJsonArray &commands, qsizetype end, QVector<Scope> *stack) {
    for (qsizetype i = 0; i < end; ++i) {
        const QJsonArray command = commands.at(i).toArray();
        if (command.isEmpty()) {
            return false;
        }
        const auto op = command.at(0).toString();
        if (op == QLatin1String("save")) {
            stack->append(stack->last());
        } else if (op == QLatin1String("restore")) {
            if (stack->size() < 2) {
                return false;
            }
            stack->removeLast();
        } else if (op == QLatin1String("clip")) {
            stack->last().clip = intersectClip(stack->last().clip, command);
        } else if (op == QLatin1String("translate") || op == QLatin1String("scale") ||
                   op == QLatin1String("rotate")) {
            return false;
        }
    }
    return true;
}

/// 把 [begin, end) 这一段所有命令的包围盒并进 rect。这一段整体当成脏的。
inline bool collectRange(const QJsonArray &commands, qsizetype begin, qsizetype end,
                         QVector<Scope> stack, QRectF *rect) {
    for (qsizetype i = begin; i < end; ++i) {
        const QJsonArray command = commands.at(i).toArray();
        if (command.isEmpty()) {
            return false;
        }
        const auto op = command.at(0).toString();
        if (op == QLatin1String("save")) {
            stack.append(stack.last());
            continue;
        }
        if (op == QLatin1String("restore")) {
            if (stack.size() < 2) {
                return false;
            }
            stack.removeLast();
            continue;
        }
        if (op == QLatin1String("alpha")) {
            continue;
        }
        if (op == QLatin1String("translate") || op == QLatin1String("scale") ||
            op == QLatin1String("rotate")) {
            return false;
        }
        if (op == QLatin1String("clip")) {
            stack.last().clip = intersectClip(stack.last().clip, command);
            merge(rect, stack.last().clip);
            continue;
        }
        QRectF box;
        if (!bounds(command, stack.last().clip, &box)) {
            return false;
        }
        merge(rect, box);
    }
    return true;
}

} // namespace hud_dirty

/**
 * 比对前后两份 HUD 命令流，算出真正需要重画与重传纹理的舞台矩形。
 *
 * 为什么要自己算：Hud 是 QQuickPaintedItem，一条命令流画满整张画布，每帧都要重新
 * 栅格化 2880x1800 并整张上传（docs/ANDROID.md「滑动列表掉帧」）。QPainter 只能靠
 * clip 省栅格化，纹理要省带宽就得先知道"哪块变了"。
 *
 * 对齐方式用**公共前缀 + 公共后缀**，不再按下标一一配对：
 * 滚动文字（`save/alpha/clip/text/restore`）与数字化滚动会在动画中增删命令，
 * 按下标配对会从插入点开始全部错位，一路撞到 save/restore 结构变化就退回全屏重画
 * ——切歌动画（0.64s 的 ReelCurve + 数字滚动）正好每帧都在增删命令。
 * 前缀/后缀夹出"中间段"后，中间段整体当脏，两端各自的裁剪栈都由前缀重放得到。
 *
 * 安全优先：中间段里出现 translate/scale/rotate、未登记命令、或 save/restore 不平衡，
 * 一律 `full = true` 退回整块重画——宁可多画一帧，也不能留残影。
 */
inline HudDirtyResult hudDirtyRect(const QJsonArray &before, const QJsonArray &after, const QSizeF &stage) {
    using namespace hud_dirty;
    HudDirtyResult result;
    result.full = false;
    result.rect = QRectF();
    const qsizetype oldSize = before.size();
    const qsizetype newSize = after.size();
    const qsizetype shortest = qMin(oldSize, newSize);
    qsizetype prefix = 0;
    while (prefix < shortest && before.at(prefix) == after.at(prefix)) {
        ++prefix;
    }
    if (prefix == oldSize && prefix == newSize) {
        result.equal = true;
        return result; // 逐条相同：没有任何像素需要重画。
    }
    qsizetype suffix = 0;
    while (suffix < shortest - prefix &&
           before.at(oldSize - 1 - suffix) == after.at(newSize - 1 - suffix)) {
        ++suffix;
    }
    const QRectF root(0, 0, stage.width() > 0 ? stage.width() : 1920, 1080);
    QVector<Scope> stack{Scope{root}};
    if (!seedClips(before, prefix, &stack)) {
        result.full = true;
        return result;
    }
    QRectF rect;
    if (!collectRange(before, prefix, oldSize - suffix, stack, &rect) ||
        !collectRange(after, prefix, newSize - suffix, stack, &rect)) {
        result.full = true;
        return result;
    }
    result.rect = rect;
    return result;
}

} // namespace RhineRender
