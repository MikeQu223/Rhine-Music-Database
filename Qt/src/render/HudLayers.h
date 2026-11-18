#pragma once

#include <QJsonArray>
#include <QString>
#include <QVector>
#include <QtGlobal>
#include <cmath>

namespace RhineRender {

/**
 * HUD 分层：把一条命令流切成「静态前缀」与「动态后缀」，各自一张纹理、两个节点合成。
 *
 * 为什么可以拆：HUD 的全部绘制命令都是 source-over（`Glyphs::renderCommands` 里没有
 * 破坏性合成，Android 上的 `right-mask` 也是渐变 fillRect），而 source-over 可结合：
 * `(D over S) over B == D over (S over B)`。所以把前缀画进静态纹理、后缀画进动态纹理，
 * 再按「静态在前、动态在后」合成，与在单张画布上顺序画完再合成是同一套混合运算。
 * 唯一的差别是 GPU 混合多了一道 8 位舍入（只有半透明边缘可能出现 ±1/255），
 * 每个像素的来源与绘制顺序都不是估的——见 docs/ANDROID.md §4.4「分层实现」。
 *
 * 切分点的前提（不满足就不分层，退回单层）：
 *   - 落在一个完整作用域边界上：前缀里 save/restore 平衡、alpha 收敛回 1；
 *   - 前缀里没有在作用域 0 上开裁剪（否则动态层会被继承的裁剪区裁掉，像素就变了）；
 *   - 前缀非空且后缀非空，否则分层没有收益。
 */
struct HudLayerSplit {
    bool layered = false;       ///< 能否安全分层
    qsizetype split = 0;        ///< 静态前缀长度
    QJsonArray staticCommands;  ///< [0, split)
    QJsonArray dynamicCommands; ///< [split, size)
};

/**
 * 前缀能否自成作用域：save/restore 平衡、alpha 收敛到 1、没有顶层裁剪。
 *
 * 这里只看「会不会改变后缀的绘制结果」，不做与像素有关的判断：`fill`/`text` 这些
 * 绘制命令先画后画都一样（source-over 可结合），但 `alpha`/`clip` 是状态命令，
 * 跨过切分点就会把静态层的透明度或裁剪区带进动态层。
 */
inline bool hudPrefixIsSelfContained(const QJsonArray &commands, qsizetype end) {
    int depth = 0;
    double alpha = 1.0;
    QVector<double> savedAlpha;
    for (qsizetype i = 0; i < end; ++i) {
        const auto command = commands.at(i).toArray();
        if (command.isEmpty()) {
            continue;
        }
        const auto op = command.at(0).toString();
        if (op == QLatin1String("save")) {
            ++depth;
            savedAlpha.append(alpha);
        } else if (op == QLatin1String("restore")) {
            if (depth == 0) {
                return false; // 前缀里多了一个 restore：作用域本来就错位，不能拿它当边界
            }
            --depth;
            alpha = savedAlpha.takeLast();
        } else if (op == QLatin1String("alpha")) {
            alpha *= command.at(1).toDouble();
        } else if (op == QLatin1String("clip") && depth == 0) {
            return false;
        }
    }
    return depth == 0 && std::abs(alpha - 1.0) < 1e-9;
}

/**
 * 按 `staticCount` 切分命令流。`staticCount` 由命令流的产出方给出
 * （`NativeHud::staticCommandCount()`：遮罩 / 品牌 / 导航 / footer 之后的下标），
 * 不是按内容猜的——产出方才知道哪一段是「只在换页、换主题、改名时才变」的。
 */
inline HudLayerSplit hudSplitLayers(const QJsonArray &commands, int staticCount) {
    HudLayerSplit result;
    const qsizetype total = commands.size();
    const auto split = qsizetype(qBound(0, staticCount, int(total)));
    result.split = split;
    if (split <= 0 || split >= total || !hudPrefixIsSelfContained(commands, split)) {
        return result;
    }
    result.staticCommands = commands.mid(0, split);
    result.dynamicCommands = commands.mid(split);
    result.layered = true;
    return result;
}

} // namespace RhineRender
