#include "SceneMotion.h"
#include "SceneLifetimePolicy.h"
#include <QJsonArray>
#include <algorithm>
#include <cmath>

namespace SceneMotion {
namespace {
double clamp(double value) {
    return std::clamp(value, 0.0, 1.0);
}
double bell(double value, double width) {
    return std::exp(-0.5 * std::pow(value / width, 2));
}
double archiveWave(double row, double lane, double time) {
    const auto elapsed = time - 22;
    if (elapsed <= 0 || elapsed >= 4.35) {
        return 0;
    }
    const auto phase = row + (lane - 2) * 0.65;
    const auto packet = [](double distance) {
        return 2.5 * bell(distance, 3.8) - 0.58 * bell(distance - 6, 3.5);
    };
    return smooth(elapsed / 0.32) *
           (packet(phase - (3 + elapsed * 19)) * (1 - smooth((elapsed - 2.15) / 0.65)) +
            packet(phase - (32 - (elapsed - 2.3) * 24)) * smooth((elapsed - 2.17) / 0.32) *
                (1 - smooth((elapsed - 3.5) / 0.85)));
}
double settlingWave(double distance, double time) {
    const auto age = time - 25.05 - std::abs(distance) * 0.065;
    const auto envelope = std::max(-0.42, 2.15 - 0.17 * (std::sqrt(distance * distance + 1) - 1));
    const auto ring = age > 0 ? std::sin(age * 5.1) * std::exp(-age * 1.3) : 0;
    return envelope * (smooth(age / 0.62) + 0.18 * ring * smooth(age / 0.16));
}
const Curve grow{{34.24, 0},    {34.4, 0.19},  {34.64, 0.57}, {34.96, 0.79},
                 {35.28, 0.92}, {35.6, 0.973}, {36.04, 1}};
const Curve reveal{{38.84, 0}, {38.92, 0.28}, {39, 0.51}, {39.16, 0.74}, {39.32, 0.94}, {39.56, 1}};
const Curve retract{{37.72, 1},    {37.88, 0.72}, {38, 0.38},     {38.12, 0.22},
                    {38.24, 0.14}, {38.4, 0.075}, {38.64, 0.024}, {38.84, 0}};
}

double smooth(double value) {
    value = clamp(value);
    return value * value * value * (10 + value * (-15 + 6 * value));
}
double ease(double value) {
    value = clamp(value);
    return value * value * (3 - 2 * value);
}

/** 单调 Hermite 插值一次定位区间；开场保留端点斜率，解密轨迹端点速度归零。 */
double track(const Curve &keys, double time, bool stationaryEnds) {
    if (keys.isEmpty()) {
        return 0;
    }
    if (time <= keys.first().first) {
        return keys.first().second;
    }
    const auto last = keys.size() - 1;
    if (time >= keys.last().first) {
        return keys.last().second;
    }
    const auto slope = [&keys](int index) {
        return (keys.at(index + 1).second - keys.at(index).second) /
               (keys.at(index + 1).first - keys.at(index).first);
    };
    const auto tangent = [&](int index) {
        if (index == 0 || index == last) {
            if (stationaryEnds) {
                return 0.0;
            }
            return slope(index == 0 ? 0 : last - 1);
        }
        const auto a = slope(index - 1);
        const auto b = slope(index);
        if (a * b <= 0) {
            return 0.0;
        }
        const auto left = keys.at(index).first - keys.at(index - 1).first;
        const auto right = keys.at(index + 1).first - keys.at(index).first;
        const auto w0 = 2 * right + left;
        const auto w1 = right + 2 * left;
        return (w0 + w1) / (w0 / a + w1 / b);
    };
    const auto next = std::lower_bound(keys.cbegin(), keys.cend(), time,
                                       [](const auto &key, double time) { return key.first < time; });
    const auto index = int(next - keys.cbegin()) - 1;
    const auto span = keys.at(index + 1).first - keys.at(index).first;
    const auto amount = (time - keys.at(index).first) / span;
    const auto square = amount * amount;
    const auto cube = square * amount;
    return (2 * cube - 3 * square + 1) * keys.at(index).second +
           (cube - 2 * square + amount) * span * tangent(index) +
           (-2 * cube + 3 * square) * keys.at(index + 1).second + (cube - square) * span * tangent(index + 1);
}

double extraction(double time) {
    // 末段补齐至详情页 4.05 的抬升高度，避免切换模式后再次移动。
    return 0.4 * smooth((time - 25.58) / 0.82) + 2.95 * smooth((time - 27.55) / 1.3) +
           0.7 * smooth((time - 29) / 5);
}
double cinematicField(double row, double lane, double time, double center, double focus) {
    const auto handoff = smooth((time - 24.95) / 0.45);
    const auto selection = smooth((time - 25.4) / 0.95);
    const auto shoulderTime = time + 0.3 * handoff * (1 - selection);
    const auto strength = 1 + (0.25 + 0.75 * bell(lane - focus, 0.55) - 1) * smooth((time - 25.4) / 0.95);
    return archiveWave(row, lane, time) * (1 - handoff) + settlingWave(row - center, shoulderTime) * strength;
}
double returnStep(double angle, double seconds, bool reduced) {
    // E04：与离线用例共用同一实现，阈值只在 SceneLifetimePolicy.h 里出现一次。
    return SceneLifetime::returnAngleStep(angle, seconds, reduced);
}
void Spring::damp(double target, double rate, double seconds) {
    const auto delta = value - target;
    const auto impulse = velocity + rate * delta;
    const auto decay = std::exp(-rate * seconds);
    value = target + (delta + impulse * seconds) * decay;
    velocity = (velocity - rate * impulse * seconds) * decay;
}
QString Cell::key() const {
    return QString::number(lane) + ":" + QString::number(row);
}
double ArchiveField::sample(double row, double lane) const {
    const auto globalRow = row + origin.row;
    const auto globalLane = lane + origin.lane;
    const auto height = archiveWave(globalRow, globalLane, scanTime) * scanBlend;
    const auto strength = 0.25 + 0.75 * bell(lane - laneFocus, 0.55);
    const auto breathing =
        (0.075 * std::sin(time * 3.14159265358979323846 * 2 / 8 + globalRow * 0.3 - globalLane * 0.45) +
         0.027 * std::sin(time * 3.14159265358979323846 * 2 / 13 - globalRow * 0.17 + globalLane * 0.3)) *
        idleGain;
    double ripple = 0;
    if (selectionWave) {
        for (const auto &pulse : pulses) {
            const auto age = time - pulse.time;
            if (age < 0 || age > 3.2) {
                continue;
            }
            const auto distance = std::hypot(row - pulse.cell.row, (lane - pulse.cell.lane) * 2.2);
            const auto phase = distance - age * 8;
            ripple +=
                0.8 * smooth(age / 0.2) * std::exp(-age * 1.15) * std::cos(phase * 0.58) * bell(phase, 3.4);
        }
    }
    return height + settlingWave(row - shoulder, 26.56) * strength + breathing +
           std::clamp(ripple, -0.6, 0.6) * pulseGain;
}

void ThemeWave::set(bool dark, double time, Cell origin, bool immediate) {
    const auto next = dark ? 1 : 0;
    if (next == target && !immediate) {
        return;
    }
    m_backgroundFrom = immediate ? next : background(time);
    m_from = immediate ? QHash<QString, double>() : m_latest;
    target = next;
    m_start = immediate ? time - 10 : time;
    m_origin = origin;
}
double ThemeWave::background(double time) const {
    return m_backgroundFrom + (target - m_backgroundFrom) * ease((time - m_start) / 0.85);
}
void ThemeWave::beginFrame() {
    m_latest.clear();
}
double ThemeWave::sample(Cell cell, double time) {
    if (time - m_start >= 1.18) {
        return target;
    }
    const auto delay =
        std::min(0.6, std::abs(cell.row - m_origin.row) * 0.034 + std::abs(cell.lane - m_origin.lane) * 0.11);
    const auto from = m_from.value(cell.key(), m_backgroundFrom);
    const auto value = from + (target - from) * ease((time - m_start - delay) / 0.58);
    m_latest.insert(cell.key(), value);
    return value;
}

QJsonObject Decryption::sample(double time) {
    const auto growth = track(grow, time, true);
    const auto remaining = track(retract, time, true);
    QJsonArray intervals;
    if (time >= 34.24 && time < 36.04 && growth > 0) {
        intervals.append(QJsonArray{0, growth * 0.5});
        intervals.append(QJsonArray{1 - growth * 0.5, 1});
    } else if (time >= 36.04 && time < 38.84) {
        intervals.append(QJsonArray{0.5 - remaining * 0.5, 0.5 + remaining * 0.5});
    }
    QString phase = "clear";
    if (time < 34.24) {
        phase = "waiting";
    } else if (time < 36.04) {
        phase = "joining";
    } else if (time < 37.72) {
        phase = "connected";
    } else if (time < 38.84) {
        phase = "retracting";
    } else if (time < END) {
        phase = "revealing";
    }
    return {{"time", time},
            {"intervals", intervals},
            {"phase", phase},
            {"markers", smooth((time - 34.2) / 0.12) * (1 - smooth((time - 37.76) / 0.56))},
            {"point", smooth((time - 38.58) / 0.2) * (1 - smooth((time - 39.08) / 0.22))},
            {"label", smooth((time - 34.32) / 0.36) * (1 - smooth((time - 37.68) / 0.24))},
            {"labelValue", smooth((time - 35.64) / 0.56)},
            {"clarity", track(reveal, time, true)}};
}
void Decryption::enter(bool alreadyClear) {
    if (m_active) {
        return;
    }
    m_active = true;
    m_elapsed = alreadyClear ? std::optional<double>((END - START) / 1.5) : std::nullopt;
    if (alreadyClear) {
        finish();
    }
}
void Decryption::leave() {
    m_active = false;
    m_elapsed.reset();
    frame = sample(-1);
}
void Decryption::select(double next) {
    leave();
    clarity = next;
}
void Decryption::finish() {
    m_elapsed = (END - START) / 1.5;
    clarity = 1;
    frame = sample(END);
}
void Decryption::update(double seconds, bool ready, bool reduced, std::optional<double> reference) {
    if (reference) {
        frame = sample(*reference);
        clarity = frame["clarity"].toDouble();
        return;
    }
    if (!m_active) {
        clarity = reduced ? 0 : clarity * std::exp(-std::max(0.0, seconds) * 9);
        if (clarity < 0.0001) {
            clarity = 0;
        }
        frame = sample(-1);
        return;
    }
    if (reduced) {
        finish();
        return;
    }
    if (!m_elapsed && ready) {
        m_elapsed = 0;
    } else if (m_elapsed) {
        m_elapsed = std::min(*m_elapsed + std::max(0.0, seconds), (END - START) / 1.5);
    }
    if (m_elapsed) {
        frame = sample(START + *m_elapsed * 1.5);
        const auto value = frame["clarity"].toDouble();
        if (value > clarity) {
            clarity = value;
        } else if (frame["phase"] == "clear") {
            clarity = 1;
        } else {
            clarity *= std::exp(-std::max(0.0, seconds) * 9);
        }
    }
}
}
