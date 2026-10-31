#pragma once
#include <QtGlobal>

namespace RhineRender {
/**
 * C04：用「发布／消费」序号判断一次完整 step 是否还会被看到。
 *
 * 背景：引擎按自己的定时器推进，呈现由 Qt Quick 的渲染线程消费。渲染线程还没取走上一份
 * 快照时，再跑一次完整 step 只会覆盖掉中间结果——这部分 CPU 在任何一帧上都看不到。
 * 原来的 `blockedNs > 2ms` 判断在 tick() 内部量不到呈现阻塞，实际上恒走 1ms 空转。
 *
 * 这个类只做纯逻辑：不读时钟、不接 Qt 事件循环、不碰场景。调用方负责喂"现在几点"、
 * 发布了哪个序号、渲染线程确认消费了哪个序号，它只回答这一次该 step、该跳过还是该休眠。
 *
 *   · 输入（按键、滚轮、指针）永远优先：有待处理输入时即使渲染线程还没消费也立刻 step，
 *     否则输入响应会被消费反馈拖慢一帧以上。
 *   · 有工作但渲染线程还没消费上一份快照 → 跳过这次完整 step，并计数。
 *   · 渲染线程迟迟不消费（窗口被遮挡、Qt 跳过了这次绘制）→ 超过看门狗时长后照常 step，
 *     不能把动画永久挂住。看门狗只是兜底，不参与正常节奏。
 *   · 没有待办工作 → 休眠。
 */
class FramePacingPolicy {
  public:
    /// 看门狗：发布后这么久仍没等到消费，就允许继续 step。
    static constexpr qint64 DefaultWatchdogMs = 250;

    enum class Action {
        Step,  ///< 现在跑一次完整 step
        Skip,  ///< 有工作，但上一份快照还没被消费：合并掉这次 step
        Sleep, ///< 没有待办工作：可以让引擎休眠
    };
    struct Decision {
        Action action = Action::Sleep;
        /// 这次 step 是看门狗逼出来的（用于诊断，正常节奏下应为 false）。
        bool forced = false;
        /// 发布到现在的等待时长；未发布过时为 0。
        qint64 waitedMs = 0;
    };

    /// 发布一份视觉快照。序号必须单调递增；小于等于当前发布号的重复值忽略。
    void publish(quint64 sequence, qint64 nowMs) {
        if (sequence == 0 || sequence <= m_published) {
            return;
        }
        m_published = sequence;
        m_publishedMs = nowMs;
        ++m_publishCount;
    }
    /// 渲染线程确认消费了哪个序号。旧序号、重复序号与从未发布过的序号都不改变状态。
    void consume(quint64 sequence) {
        if (sequence == 0 || sequence <= m_consumed || sequence > m_published) {
            return;
        }
        m_consumed = sequence;
        ++m_consumeCount;
    }
    /// 渲染线程是否已经把最近一次发布取走。
    bool awaitingConsumption() const {
        return m_published > m_consumed;
    }
    Decision decide(bool workPending, bool inputPending, qint64 nowMs) const {
        Decision decision;
        if (!workPending && !inputPending) {
            return decision;
        }
        if (inputPending) {
            decision.action = Action::Step;
            return decision;
        }
        if (!awaitingConsumption()) {
            decision.action = Action::Step;
            return decision;
        }
        decision.waitedMs = nowMs - m_publishedMs;
        if (decision.waitedMs >= DefaultWatchdogMs) {
            // 兜底：渲染线程可能根本没在出帧（遮挡、最小化、Qt 认为内容没变）。继续跑，
            // 否则动画会停在一个中间状态。
            decision.action = Action::Step;
            decision.forced = true;
            return decision;
        }
        decision.action = Action::Skip;
        return decision;
    }
    /// 记账：真的跑了一次 step。
    void noteStep(bool skipped) {
        if (skipped) {
            ++m_skipped;
        } else {
            ++m_steps;
        }
    }
    void reset() {
        m_published = m_consumed = 0;
        m_publishedMs = 0;
        m_publishCount = m_consumeCount = m_steps = m_skipped = 0;
    }
    quint64 published() const {
        return m_published;
    }
    quint64 consumed() const {
        return m_consumed;
    }
    quint64 steps() const {
        return m_steps;
    }
    quint64 skipped() const {
        return m_skipped;
    }
    quint64 publishCount() const {
        return m_publishCount;
    }
    quint64 consumeCount() const {
        return m_consumeCount;
    }
    qint64 publishedMs() const {
        return m_publishedMs;
    }

  private:
    quint64 m_published = 0;
    quint64 m_consumed = 0;
    qint64 m_publishedMs = 0;
    quint64 m_publishCount = 0;
    quint64 m_consumeCount = 0;
    quint64 m_steps = 0;
    quint64 m_skipped = 0;
};
} // namespace RhineRender
