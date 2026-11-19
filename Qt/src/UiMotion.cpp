#include "UiMotion.h"
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

namespace {
double bezier(double x, double x1, double y1, double x2, double y2) {
    const auto component = [](double t, double a, double b) {
        return 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
    };
    double lower = 0;
    double upper = 1;
    for (int i = 0; i < 24; ++i) {
        const auto t = (lower + upper) / 2;
        if (component(t, x1, x2) < x) {
            lower = t;
        } else {
            upper = t;
        }
    }
    return component((lower + upper) / 2, y1, y2);
}

int wrapIndex(int value, qsizetype length) {
    const auto count = int(length);
    return ((value % count) + count) % count;
}

bool isDigit(const QString &text) {
    return text.size() == 1 && text[0] >= u'0' && text[0] <= u'9';
}

QStringList digits() {
    return {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"};
}

// 保留原 parseInt 的前缀读取，用于判断数字滚动方向，而不是把混合文字转为零。
double leadingInteger(const QString &text) {
    static const QRegularExpression pattern(QStringLiteral("^\\s*([+-]?)(?:(0[xX])([0-9a-fA-F]+)|(\\d+))"));
    const auto match = pattern.match(text);
    if (!match.hasMatch()) {
        return 0;
    }
    double value = 0;
    if (!match.captured(2).isEmpty()) {
        for (const auto ch : match.captured(3)) {
            const auto code = ch.toLower().unicode();
            const auto digit = code <= u'9' ? code - u'0' : code - u'a' + 10;
            value = value * 16 + digit;
        }
    } else {
        value = match.captured(4).toDouble();
    }
    return match.captured(1) == "-" ? -value : value;
}
}

namespace UiMotion {
/**
 * 用固定的 49 个采样点建立滚字与歌词滚动曲线，打断时接续传入速度。
 * 数学表达式和末帧落点沿用旧界面，不引入平台默认动画曲线。
 */
ReelCurve::ReelCurve(double from, double target, double velocity, double startTime, double durationTime)
    : start(startTime), duration(durationTime) {
    const auto displacement = from - target;
    const auto cap = (std::max(std::abs(displacement), 1.) * 12) / duration;
    const auto impulse = std::clamp(velocity, -cap, cap) * duration;
    for (int i = 0; i <= 48; ++i) {
        const auto t = i / 48.;
        m_points[i] = i == 48
                          ? target
                          : target + (displacement + (impulse + 10 * displacement) * t) * std::exp(-10 * t);
    }
}

std::array<double, 2> ReelCurve::sample(double time) const {
    const auto position = std::clamp((time - start) / duration, 0., 1.) * 48;
    if (position >= 48) {
        return {m_points[48], 0};
    }
    const auto index = int(std::floor(position));
    return {m_points[index] + (m_points[index + 1] - m_points[index]) * (position - index),
            ((m_points[index + 1] - m_points[index]) * 48) / duration};
}

void SurfaceMotion::sample(double time) {
    if (duration <= 0) {
        return;
    }
    const auto progress = std::clamp((time - m_start) / duration, 0., 1.);
    const auto amount =
        bezier(progress, m_entering ? 0.22 : 0.4, m_entering ? 1 : 0, m_entering ? 0.36 : 1, 1);
    opacity = m_fromOpacity + (m_targetOpacity - m_fromOpacity) * amount;
    offset = m_fromOffset + (m_targetOffset - m_fromOffset) * amount;
    if (progress >= 1) {
        duration = 0;
    }
}

/** 在改变目标前先采样旧过渡，快速开关弹窗时接续当前透明度和偏移。 */
void SurfaceMotion::set(bool shown, double time, bool reduced, double enterDuration, double exitDuration) {
    sample(time);
    m_fromOpacity = opacity;
    m_fromOffset = offset;
    m_targetOpacity = shown ? 1 : 0;
    m_targetOffset = shown ? 0 : 8;
    m_entering = shown;
    m_start = time;
    if (reduced) {
        duration = 0;
    } else if (shown) {
        duration = enterDuration;
    } else {
        duration = exitDuration;
    }
    if (reduced) {
        opacity = m_targetOpacity;
        offset = m_targetOffset;
    }
}

bool RollingLabel::active(double time) const {
    const auto hasMotion = [time](const Slot &slot) {
        for (const auto *curve : {&slot.position, &slot.x, &slot.width, &slot.alpha}) {
            if (time < curve->start + curve->duration) {
                return true;
            }
        }
        return false;
    };
    return std::any_of(m_slots.begin(), m_slots.end(), hasMotion) ||
           std::any_of(m_retired.begin(), m_retired.end(), hasMotion);
}

/**
 * 持有每个字符的原生动画状态并直接生成绘制命令。
 * 稳定文字只提交整行，字符删除和连续改写仍沿用旧字轮、裁切与淡出顺序。
 */
QJsonArray RollingLabel::render(const QString &next, double x, double y, double size, const QString &weight,
                                double tracking, double time, bool animated, bool numeric,
                                const QJsonArray &ink, const Measure &measure) {
    const auto characters = next.toUcs4();
    const auto oldNumber = leadingInteger(m_value);
    const auto newNumber = leadingInteger(next);
    if (next != m_value || !m_initialized) {
        auto previous = std::move(m_slots);
        QVector<Slot> fresh;
        fresh.reserve(characters.size());
        double cursor = 0;
        for (qsizetype i = 0; i < characters.size(); ++i) {
            const char32_t character = characters[i];
            const auto ch = QString::fromUcs4(&character, 1);
            const auto width = measure(ch, size, weight, tracking) + tracking;
            const auto endX = cursor;
            cursor += width;
            if (i < previous.size() && m_initialized && animated) {
                auto slot = previous[i];
                const auto position = slot.position.sample(time);
                const auto p = position[0];
                const auto velocity = position[1];
                const auto xx = slot.x.sample(time);
                const auto ww = slot.width.sample(time);
                if (slot.wheel[wrapIndex(int(std::floor(p)), slot.wheel.size())] != ch ||
                    std::abs(p - std::round(p)) > 0.00001) {
                    if (numeric && isDigit(ch)) {
                        auto target = std::floor(p / 10) * 10 + ch.toDouble();
                        if (newNumber > oldNumber && target < p) {
                            target += 10;
                        }
                        if (newNumber < oldNumber && target > p) {
                            target -= 10;
                        }
                        while (target < 0) {
                            target += 10;
                        }
                        slot.wheel = digits();
                        slot.position = ReelCurve(p < 0 ? p + 10 : p, target, velocity, time);
                    } else {
                        const auto base = int(std::floor(p));
                        const auto fraction = p - base;
                        QStringList wheel{slot.wheel[wrapIndex(base, slot.wheel.size())]};
                        if (fraction > 0.00001) {
                            wheel.append(slot.wheel[wrapIndex(base + 1, slot.wheel.size())]);
                        }
                        if (wheel.last() != ch) {
                            wheel.append(ch);
                        }
                        const auto target = double(wheel.size() - 1);
                        slot.wheel = wheel;
                        slot.position = ReelCurve(
                            fraction, target,
                            std::min(std::max(0., velocity), ((target - fraction) * 10000) / 460), time);
                    }
                }
                slot.x = ReelCurve(xx[0], endX, xx[1], time);
                slot.width = ReelCurve(ww[0], width, ww[1], time);
                slot.alpha = ReelCurve(slot.alpha.sample(time)[0], 1, 0, time);
                fresh.append(std::move(slot));
            } else {
                const auto digit = numeric && isDigit(ch) ? ch.toDouble() : 0;
                fresh.append({numeric && isDigit(ch) ? digits() : QStringList{ch},
                              ReelCurve(digit, digit, 0, time), ReelCurve(endX, endX, 0, time),
                              ReelCurve(width, width, 0, time),
                              ReelCurve(m_initialized && animated ? 0 : 1, 1, 0, time)});
            }
        }
        m_retired.clear();
        if (animated && previous.size() > characters.size()) {
            for (qsizetype i = characters.size(); i < previous.size(); ++i) {
                auto slot = std::move(previous[i]);
                slot.alpha = ReelCurve(slot.alpha.sample(time)[0], 0, 0, time, 0.46 * 0.65);
                m_retired.append(std::move(slot));
            }
        }
        m_slots = std::move(fresh);
        m_value = next;
        m_initialized = true;
    }
    QJsonArray commands;
    const auto text = [&](const QString &value, double left, double top) {
        commands.append(QJsonArray{"text", value, left, top, size, weight, tracking, ink});
    };
    if (!animated || !active(time)) {
        m_retired.clear();
        text(next, x, y);
        return commands;
    }
    const auto line = size * (numeric ? 1.1 : 1.326);
    const auto draw = [&](const Slot &slot) {
        const auto p = slot.position.sample(time)[0];
        const auto xx = slot.x.sample(time)[0];
        const auto width = slot.width.sample(time)[0];
        const auto alpha = slot.alpha.sample(time)[0];
        if (alpha <= 0.001) {
            return;
        }
        commands.append(QJsonArray{"save"});
        commands.append(QJsonArray{"alpha", alpha});
        commands.append(QJsonArray{"clip", x + xx - size * 0.15, y, width + size * 0.3, line});
        const auto lower = int(std::floor(p));
        const auto upper = std::max(lower, int(std::ceil(p)));
        for (int index = lower; index <= upper; ++index) {
            text(slot.wheel[wrapIndex(index, slot.wheel.size())], x + xx, y + (index - p) * line);
        }
        commands.append(QJsonArray{"restore"});
    };
    for (const auto &slot : m_slots) {
        draw(slot);
    }
    for (const auto &slot : m_retired) {
        draw(slot);
    }
    return commands;
}
}
