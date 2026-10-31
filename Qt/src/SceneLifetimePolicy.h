#pragma once

#include <QtCore/QtGlobal>

#include <cmath>

/**
 * E04：归位演出（returning）的寿命策略。
 *
 * 每次换格都会把旧主体复制成一份"归位"，按 lift/rotation 收敛后删除。这里把三条
 * 判据收成纯函数，好让离线用例证明"无输入必定收敛、积压有上界"，也让运行期与用例
 * 用同一套阈值——否则两处各写一个 0.0001，改一处就悄悄失效。
 */
namespace SceneLifetime {

/// 收敛阈值：lift（米）与 rotation.y（弧度）都落在这个量级以下即视为归位完成。
constexpr double ConvergedLift = 0.0001;
constexpr double ConvergedRotation = 0.0001;

/// 归位主体是否已经收敛（可以删除）。
inline bool returningConverged(double lift, double rotation)
{
    return std::abs(lift) < ConvergedLift && std::abs(rotation) < ConvergedRotation;
}

/**
 * 回正角度的单步衰减：指数收敛，落到 0.001 弧度以内直接归零。
 *
 * 与 `SceneMotion::returnStep` 同一实现（那边只是转发），用例直接调这里。
 */
inline double returnAngleStep(double angle, double seconds, bool reduced)
{
    if (seconds <= 0) {
        return angle;
    }
    const auto next = angle * std::exp(-seconds * (reduced ? 35 : 7));
    return std::abs(next) <= 0.001 ? 0 : next;
}

/**
 * 归位落位（lift → 0）的单步衰减。
 *
 * 原实现用 `Spring::damp(0, 4.5, seconds)`：它的每步乘子是 (1+rate·h)·e^{-rate·h}，
 * 在 h=1/60 时约 0.9973，等效时间常数 ≈ 6 秒，还会随帧率变化（帧越低衰减越快）。
 * 结果是快速滚动后归位卡片要滞留近一分钟，它引用的音乐键、标签、封面、实例也就跟着
 * 一直留在活动集合里。这里改成与帧率无关的指数衰减，标称速率仍是 4.5（减弱时 35）。
 */
inline double returningLiftStep(double value, double seconds, bool reduced)
{
    if (seconds <= 0) {
        return value;
    }
    const auto next = value * std::exp(-seconds * (reduced ? 35.0 : 4.5));
    return std::abs(next) < ConvergedLift ? 0 : next;
}

} // namespace SceneLifetime
