#pragma once
#include "AppleTransitionPlan.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <numeric>
#include <numbers>
#include <type_traits>
#include <utility>
#include <vector>

namespace {
constexpr int frameMs = 10;
constexpr double windowSeconds = AppleTransitionPlan::searchWindowMs / 1000.0;
constexpr int quietFrames = 22;
constexpr float silenceRms = 0.001f;
constexpr int maximumAnalysisChannels = 8;
constexpr double maximumTempoAdjustment = 0.16;
constexpr int localGridFrames = 1400;
using SpectralFrame = std::array<float, 3>;

struct AudioWindow {
    qint64 offsetMs = 0;
    qint64 durationMs = 0;
    std::vector<float> rms;
    std::vector<float> onset;
    std::vector<SpectralFrame> spectralOnset;
    int firstSound = -1;
    int lastSound = -1;
    std::array<double, 12> chroma{};
};

struct BeatGrid {
    double period = 0;
    double firstBeat = -1;
    double firstBar = -1;
    int beatsPerBar = 0;
    bool beatPhaseConfident = false;
};

enum class BeatRegion { Full, Intro, Outro };

struct MusicalKey {
    int tonic = -1;
    bool minor = false;
};

/** 将低频至中频的半音能量折叠到十二个音级；每帧归一化，避免响度支配调性。 */
class ChromaReader {
  public:
    void configure(double sampleRate) {
        m_stride = std::max(1, int(sampleRate / 4096));
        const double reducedRate = sampleRate / m_stride;
        for (size_t note = 0; note < m_coefficients.size(); ++note) {
            const double frequency = 55.0 * std::exp2(double(note) / 12);
            m_coefficients[note] = 2 * std::cos(2 * std::numbers::pi * frequency / reducedRate);
        }
    }

    void add(float sample, std::array<double, 12> &chroma) {
        m_sum += sample;
        if (++m_count < m_stride) {
            return;
        }
        const auto value = m_sum / m_count;
        m_count = 0;
        m_sum = 0;
        const auto weight = 0.5 - 0.5 * std::cos(2 * std::numbers::pi * m_index / m_window.size());
        m_window[m_index++] = value * weight;
        if (m_index == m_window.size()) {
            accumulate(chroma);
            m_index = 0;
        }
    }

  private:
    void accumulate(std::array<double, 12> &chroma) const {
        std::array<double, 12> frame{};
        for (size_t note = 0; note < m_coefficients.size(); ++note) {
            const auto coefficient = m_coefficients[note];
            double previous = 0;
            double older = 0;
            for (const auto sample : m_window) {
                const auto filtered = sample + coefficient * previous - older;
                older = previous;
                previous = filtered;
            }
            const auto power = previous * previous + older * older - coefficient * previous * older;
            // 55 Hz 从 A 开始，音级数组以 C 为零。
            frame[(note + 9) % 12] += std::sqrt(std::max(power, 0.0));
        }
        const auto sum = std::accumulate(frame.begin(), frame.end(), 0.0);
        if (sum < 0.1) {
            return;
        }
        for (size_t pitch = 0; pitch < chroma.size(); ++pitch) {
            chroma[pitch] += frame[pitch] / sum;
        }
    }

    std::array<double, 2048> m_window{};
    std::array<double, 60> m_coefficients{};
    size_t m_index = 0;
    int m_stride = 1;
    int m_count = 0;
    double m_sum = 0;
};

/** 用大小调模板比较音级分布，节拍音或差距过小的结果视作未知。 */
MusicalKey estimateKey(const std::array<double, 12> &chroma) {
    constexpr std::array<double, 12> major{6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                                           2.52, 5.19, 2.39, 3.66, 2.29, 2.88};
    constexpr std::array<double, 12> minor{6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                                           2.54, 4.75, 3.98, 2.69, 3.34, 3.17};
    const double peak = *std::max_element(chroma.begin(), chroma.end());
    if (peak <= 0 || std::count_if(chroma.begin(), chroma.end(),
                                   [peak](double value) { return value > peak * 0.22; }) < 3) {
        return {};
    }
    const double mean = std::accumulate(chroma.begin(), chroma.end(), 0.0) / 12;
    double best = -1;
    double second = -1;
    MusicalKey result;
    for (const auto *profile : {&major, &minor}) {
        const double profileMean = std::accumulate(profile->begin(), profile->end(), 0.0) / 12;
        for (int tonic = 0; tonic < 12; ++tonic) {
            double dot = 0;
            double pitchPower = 0;
            double profilePower = 0;
            for (int pitch = 0; pitch < 12; ++pitch) {
                const auto observed = chroma[(pitch + tonic) % 12] - mean;
                const auto expected = (*profile)[pitch] - profileMean;
                dot += observed * expected;
                pitchPower += observed * observed;
                profilePower += expected * expected;
            }
            const auto score = pitchPower > 0 ? dot / std::sqrt(pitchPower * profilePower) : 0.0;
            if (score > best) {
                second = best;
                best = score;
                result = {tonic, profile == &minor};
            } else {
                second = std::max(second, score);
            }
        }
    }
    return best >= 0.60 && best - second >= 0.025 ? result : MusicalKey{};
}

bool keysCanOverlap(MusicalKey a, MusicalKey b) {
    if (a.tonic < 0 || b.tonic < 0) {
        return true;
    }
    const int interval = (b.tonic - a.tonic + 12) % 12;
    if (a.minor == b.minor) {
        return interval == 0 || interval == 5 || interval == 7;
    }
    return interval == (a.minor ? 3 : 9);
}

void findSound(AudioWindow &window) {
    for (int frame = 0; frame < int(window.rms.size()); ++frame) {
        if (window.rms[frame] > silenceRms) {
            if (window.firstSound < 0) {
                window.firstSound = frame;
            }
            window.lastSound = frame;
        }
    }
}

class WindowAnalyzer {
  public:
    explicit WindowAnalyzer(qint64 duration) {
        window.durationMs = duration;
    }
    bool append(const float *samples, qsizetype count, int rate, int channelCount, double offsetMs) {
        if (rate < 8000 || rate > 192000 || channelCount < 1 || channelCount > maximumAnalysisChannels ||
            count <= 0 || count % channelCount != 0) {
            return false;
        }
        if (sampleRate == 0) {
            sampleRate = rate;
            channels = channelCount;
            window.offsetMs = qRound64(offsetMs);
            chroma.configure(sampleRate);
            samplesPerFrame = qRound(sampleRate * frameMs / 1000.0);
            lowCoefficient = float(1.0 - std::exp(-2 * std::numbers::pi * 170.0 / sampleRate));
            midCoefficient = float(1.0 - std::exp(-2 * std::numbers::pi * 2100.0 / sampleRate));
        } else if (sampleRate != rate || channels != channelCount) {
            return false;
        }
        for (qsizetype sample = 0; sample < count / channels; ++sample) {
            float mono = 0;
            for (int channel = 0; channel < channels; ++channel) {
                const float value = samples[sample * channels + channel];
                if (!std::isfinite(value)) {
                    return false;
                }
                mono += value;
                low[channel] += lowCoefficient * (value - low[channel]);
                lowMid[channel] += midCoefficient * (value - lowMid[channel]);
                const auto middle = lowMid[channel] - low[channel];
                const auto high = value - lowMid[channel];
                fullEnergy += value * value;
                energies[0] += low[channel] * low[channel];
                energies[1] += middle * middle;
                energies[2] += high * high;
            }
            chroma.add(mono / channels, window.chroma);
            if (++frameSamples == samplesPerFrame) {
                const auto valuesPerFrame = channels * samplesPerFrame;
                window.rms.push_back(std::sqrt(fullEnergy / valuesPerFrame));
                float flux = 0;
                SpectralFrame spectrum{};
                constexpr SpectralFrame weights{0.50f, 0.32f, 0.18f};
                for (int band = 0; band < 3; ++band) {
                    const float level = std::log1p(60 * std::sqrt(energies[band] / valuesPerFrame));
                    spectrum[band] = std::max(0.0f, level - previousLevels[band]);
                    flux += weights[band] * spectrum[band];
                    previousLevels[band] = level;
                }
                window.onset.push_back(flux);
                window.spectralOnset.push_back(spectrum);
                energies = {};
                fullEnergy = 0;
                frameSamples = 0;
            }
        }
        return true;
    }
    AudioWindow finish() {
        findSound(window);
        return std::move(window);
    }

  private:
    AudioWindow window;
    int sampleRate = 0, channels = 0, samplesPerFrame = 0, frameSamples = 0;
    float lowCoefficient = 0, midCoefficient = 0, fullEnergy = 0;
    std::array<float, maximumAnalysisChannels> low{}, lowMid{};
    SpectralFrame energies{}, previousLevels{};
    ChromaReader chroma;
};
AudioWindow readWindow(const QUrl &, bool, const std::atomic_bool &);

double correlation(const std::vector<float> &onset, int lag, int first, int last) {
    double dot = 0;
    double left = 0;
    double right = 0;
    for (int frame = first + lag; frame <= last; ++frame) {
        const auto a = onset[frame];
        const auto b = onset[frame - lag];
        dot += a * b;
        left += a * a;
        right += b * b;
    }
    return left > 0 && right > 0 ? dot / std::sqrt(left * right) : 0;
}

double nearOnset(const std::vector<float> &onset, double position) {
    const auto frame = qRound(position);
    double peak = 0;
    for (int index = std::max(0, frame - 2); index <= std::min(int(onset.size()) - 1, frame + 2); ++index) {
        const auto weight = std::max(0.0, 1.0 - std::abs(position - index) / 3.0);
        peak = std::max(peak, weight * onset[index]);
    }
    return peak;
}

/** 在两个半窗验证周期。拍点与四拍重音分别判定，允许只确认拍点。 */
BeatGrid estimateGrid(const AudioWindow &window, BeatRegion region = BeatRegion::Full) {
    const auto &onset = window.onset;
    int first = window.firstSound + 4;
    int last = window.lastSound;
    if (region == BeatRegion::Intro) {
        last = std::min(last, localGridFrames - int(window.offsetMs / frameMs));
    } else if (region == BeatRegion::Outro) {
        first = std::max(first, int((window.durationMs - window.offsetMs) / frameMs) - localGridFrames);
    }
    if (window.firstSound < 0 || last - first < 550) {
        return {};
    }
    const int middle = (first + last) / 2;
    // 对起音包络轻微平滑，允许真实鼓点在相邻帧内抖动。
    auto smoothed = onset;
    for (int frame = first + 2; frame + 2 <= last; ++frame) {
        smoothed[frame] = (onset[frame - 2] + 2 * onset[frame - 1] + 3 * onset[frame] + 2 * onset[frame + 1] +
                           onset[frame + 2]) /
                          9;
    }
    int bestLag = 0;
    double bestScore = 0.25;
    for (int lag = 30; lag <= 100; ++lag) {
        const auto earlyScore = correlation(smoothed, lag, first, middle);
        const auto lateScore = correlation(smoothed, lag, middle, last);
        const auto tempoDistance = std::log2(50.0 / lag);
        const double score = 0.75 * std::min(earlyScore, lateScore) + 0.25 * std::max(earlyScore, lateScore) -
                             0.035 * tempoDistance * tempoDistance;
        if (score > bestScore) {
            bestLag = lag;
            bestScore = score;
        }
    }
    if (!bestLag) {
        return {};
    }
    // 整数采样时二倍周期偶尔会更尖锐。半周期也稳定且更接近常见拍速时采用半周期。
    if (bestLag >= 72) {
        const auto halfScore = [&](int lag) {
            return std::min(correlation(smoothed, lag, first, middle),
                            correlation(smoothed, lag, middle, last));
        };
        const auto lower = bestLag / 2;
        const auto upper = (bestLag + 1) / 2;
        const double lowerScore = halfScore(lower);
        const double upperScore = halfScore(upper);
        if (std::max(lowerScore, upperScore) >= 0.86 * bestScore) {
            bestLag = lowerScore >= upperScore ? lower : upper;
        }
    }
    std::array<double, 4> early{};
    std::array<double, 4> late{};
    double strongestPulse = 0;
    double bestPhase = 0;
    double bestPeriod = bestLag;
    // 整数帧周期累计后会偏离实际起音，围绕粗估结果重新拟合周期与相位。
    for (int step = -14; step <= 14; ++step) {
        const double period = bestLag + step * 0.05;
        for (int phase = 0; phase < qRound(period); ++phase) {
            std::array<double, 4> firstHalf{};
            std::array<double, 4> secondHalf{};
            double strength = 0;
            int count = 0;
            for (double time = first + phase; time <= last; time += period) {
                const auto peak = nearOnset(onset, time);
                auto &accents = time < middle ? firstHalf : secondHalf;
                accents[count % 4] += peak;
                strength += peak;
                ++count;
            }
            if (count > 0 && strength / count > strongestPulse) {
                strongestPulse = strength / count;
                bestPhase = first + phase;
                bestPeriod = period;
                early = firstHalf;
                late = secondHalf;
            }
        }
    }
    const auto firstAccent = std::max_element(early.begin(), early.end());
    const auto secondAccent = std::max_element(late.begin(), late.end());
    const auto hasAccent = [](const auto &values, double maximum) {
        const auto sum = values[0] + values[1] + values[2] + values[3];
        return maximum > 0 && maximum > 0.30 * sum;
    };
    double offbeatStrength = 0;
    int offbeatCount = 0;
    for (double frame = bestPhase + bestPeriod / 2; frame <= last; frame += bestPeriod) {
        offbeatStrength += nearOnset(onset, frame);
        ++offbeatCount;
    }
    if (strongestPulse <= 0) {
        return {bestPeriod};
    }
    const bool confidentPhase = offbeatCount == 0 || strongestPulse >= 1.10 * offbeatStrength / offbeatCount;
    if (!confidentPhase) {
        return {bestPeriod, bestPhase};
    }
    if (firstAccent - early.begin() != secondAccent - late.begin() || !hasAccent(early, *firstAccent) ||
        !hasAccent(late, *secondAccent)) {
        return {bestPeriod, bestPhase, -1, 0, true};
    }
    return {bestPeriod, bestPhase, bestPhase + (firstAccent - early.begin()) * bestPeriod, 4, true};
}

qint64 timeAt(const AudioWindow &window, double frame) {
    return window.offsetMs + qRound64(frame * frameMs);
}

double firstAudibleBar(const AudioWindow &window, const BeatGrid &grid) {
    const double bar = grid.period * grid.beatsPerBar;
    return grid.firstBar + std::ceil((window.firstSound - 4 - grid.firstBar) / bar) * bar;
}

double beatsPerMinute(const BeatGrid &grid) {
    return grid.period > 0 ? 60000.0 / (frameMs * grid.period) : 0;
}

double rmsBetween(const AudioWindow &window, int first, int end) {
    double energy = 0;
    for (int frame = first; frame < end; ++frame) {
        energy += double(window.rms[frame]) * window.rms[frame];
    }
    return std::sqrt(energy / (end - first));
}

struct IncomingCue {
    double beatFrame;
    qint64 startMs;
    qint64 leadMs;
    double skipPenalty;
};

/** 在曲目开头 20 秒内比较拍点，可从拍点切入，也可提前播放拾音。 */
std::vector<IncomingCue> incomingCues(const AudioWindow &window, double firstBeat, double step,
                                      qint64 introMs, double rate) {
    std::vector<IncomingCue> cues;
    for (double beat = firstBeat; beat <= window.lastSound; beat += step) {
        const auto beatMs = timeAt(window, beat);
        if (beatMs < 0) {
            continue;
        }
        if (beatMs > AppleTransitionPlan::searchWindowMs) {
            break;
        }
        const auto skippedMs = beatMs - introMs;
        if (skippedMs <= 120) {
            cues.push_back({beat, beatMs, 0, 0});
            continue;
        }
        const int endFrame = std::clamp(qRound(beat), window.firstSound + 1, window.lastSound + 1);
        const auto pickupLevel = rmsBetween(window, window.firstSound, endFrame);
        const auto penalty = 0.04 * skippedMs / 1000.0 + 0.08 * std::min(1.0, pickupLevel / 0.05);
        cues.push_back({beat, beatMs, 0, penalty});
        cues.push_back({beat, introMs, qRound64(skippedMs / rate), 0});
    }
    return cues;
}

/** 按实际变速换算两条时间轴，比较叠播中低、中、高频的起音变化。 */
double spectralAlignment(const AudioWindow &a, const AudioWindow &b, double aBeat, double bBeat, double rate,
                         qint64 spanMs) {
    constexpr SpectralFrame weights{0.50f, 0.32f, 0.18f};
    double dot = 0;
    double aPower = 0;
    double bPower = 0;
    // 约 1.2 秒已足以覆盖数个相邻起音，避开曲尾余响和下一乐段的影响。
    const auto spanFrames = std::min<qint64>(120, spanMs / frameMs);
    for (int offset = -2; offset < spanFrames; ++offset) {
        const auto aFrame = qRound(aBeat + offset);
        const auto bFrame = qRound(bBeat + offset * rate);
        if (aFrame < 1 || bFrame < 1 || aFrame >= int(a.spectralOnset.size()) - 1 ||
            bFrame >= int(b.spectralOnset.size()) - 1) {
            continue;
        }
        for (size_t band = 0; band < weights.size(); ++band) {
            const auto left = (a.spectralOnset[aFrame - 1][band] + 2 * a.spectralOnset[aFrame][band] +
                               a.spectralOnset[aFrame + 1][band]) *
                              weights[band];
            const auto right = (b.spectralOnset[bFrame - 1][band] + 2 * b.spectralOnset[bFrame][band] +
                                b.spectralOnset[bFrame + 1][band]) *
                               weights[band];
            dot += left * right;
            aPower += left * left;
            bPower += right * right;
        }
    }
    return aPower > 0 && bPower > 0 ? std::clamp(dot / std::sqrt(aPower * bPower), 0.0, 1.0) : 0;
}

qint64 earliestOutgoingCue(const AudioWindow &window) {
    return std::max(window.durationMs - AppleTransitionPlan::searchWindowMs,
                    timeAt(window, window.firstSound));
}

AppleTransitionPlan planBarMatch(const AudioWindow &a, const AudioWindow &b, const BeatGrid &aGrid,
                                 const BeatGrid &bGrid, qint64 aEnd, qint64 bStart) {
    using Kind = AppleTransitionPlan::Kind;
    if (aGrid.beatsPerBar == 0 || bGrid.beatsPerBar == 0) {
        return {};
    }
    const double speed = bGrid.period / aGrid.period;
    const double aBar = aGrid.period * aGrid.beatsPerBar;
    const double bBar = bGrid.period * bGrid.beatsPerBar;
    if (std::abs(speed - 1.0) > maximumTempoAdjustment) {
        return {};
    }
    const double aEndBar = aGrid.firstBar + std::floor((a.lastSound - aGrid.firstBar) / aBar) * aBar;
    AppleTransitionPlan best;
    double bestScore = -1;
    const auto earliestCueMs = earliestOutgoingCue(a);
    const auto targetOverlapMs = qRound64(2 * aBar * frameMs);
    const auto candidates = incomingCues(b, firstAudibleBar(b, bGrid), bBar, bStart, speed);
    for (const auto &cue : candidates) {
        for (int bars = 0;; ++bars) {
            const auto aBeat = aEndBar - bars * aBar;
            const auto out = timeAt(a, aBeat) - cue.leadMs;
            if (out < earliestCueMs) {
                break;
            }
            const auto overlap = aEnd - out;
            const auto alignedSpanMs = overlap - cue.leadMs;
            if (alignedSpanMs < 750 || cue.startMs + overlap * speed >= b.durationMs - 2000) {
                continue;
            }
            const auto spectral = spectralAlignment(a, b, aBeat, cue.beatFrame, speed, alignedSpanMs);
            const auto spanPenalty = 0.16 * std::abs(overlap - targetOverlapMs) / 1000.0;
            const auto score = spectral - spanPenalty - cue.skipPenalty - 0.10 * cue.leadMs / 1000.0;
            if (spectral >= 0.09 && score > bestScore) {
                best = {Kind::BeatMatch, out, cue.startMs, overlap, speed};
                best.alignment = AppleTransitionPlan::Alignment::Bar;
                best.spectralScore = spectral;
                bestScore = score;
            }
        }
    }
    return best;
}

/** 以可靠拍点对齐较短的叠播，兼顾倍拍解释、开头拾音与调性冲突。 */
AppleTransitionPlan planBeatMatch(const AudioWindow &a, const AudioWindow &b, const BeatGrid &aGrid,
                                  const BeatGrid &bGrid, qint64 aEnd, qint64 bStart, bool compatibleKeys) {
    using Kind = AppleTransitionPlan::Kind;
    if (aGrid.firstBeat < 0 || bGrid.firstBeat < 0) {
        return {};
    }
    constexpr std::array<double, 3> tempoFactors{1.0, 0.5, 2.0};
    const qint64 targetOverlapMs = compatibleKeys ? 2250 : 1000;
    const double minimumSpectralScore = aGrid.beatPhaseConfident && bGrid.beatPhaseConfident ? 0.09 : 0.23;
    const auto earliestCueMs = earliestOutgoingCue(a);
    AppleTransitionPlan best;
    double bestScore = -1;
    const auto aLastBeat =
        aGrid.firstBeat + std::floor((a.lastSound - aGrid.firstBeat) / aGrid.period) * aGrid.period;
    const auto bFirstBeat =
        bGrid.firstBeat + std::ceil((b.firstSound - 4 - bGrid.firstBeat) / bGrid.period) * bGrid.period;
    for (const double factor : tempoFactors) {
        const double rate = bGrid.period / aGrid.period * factor;
        if (std::abs(rate - 1.0) > maximumTempoAdjustment) {
            continue;
        }
        for (const auto &cue : incomingCues(b, bFirstBeat, bGrid.period, bStart, rate)) {
            for (int previousBeat = 0;; ++previousBeat) {
                const auto aBeat = aLastBeat - previousBeat * aGrid.period;
                const auto out = timeAt(a, aBeat) - cue.leadMs;
                if (out < earliestCueMs) {
                    break;
                }
                const auto availableMs = aEnd - out;
                const auto overlapMs = compatibleKeys ? availableMs : std::min<qint64>(availableMs, 1500);
                const auto alignedSpanMs = overlapMs - cue.leadMs;
                if (alignedSpanMs < 430 || cue.startMs + overlapMs * rate >= b.durationMs - 2000) {
                    continue;
                }
                const auto spectral = spectralAlignment(a, b, aBeat, cue.beatFrame, rate, alignedSpanMs);
                if (spectral < minimumSpectralScore) {
                    continue;
                }
                const auto spanPenalty = 0.15 * std::abs(overlapMs - targetOverlapMs) / 1000.0;
                const auto cutPenalty = 0.13 * (availableMs - overlapMs) / 1000.0;
                const auto leadPenalty = 0.10 * cue.leadMs / 1000.0;
                const auto spectralWeight = std::min(1.0, alignedSpanMs / 1150.0);
                const auto score = 0.25 + 0.80 * spectral * spectralWeight - spanPenalty - cutPenalty -
                                   leadPenalty - cue.skipPenalty - 0.25 * std::abs(rate - 1.0);
                if (score > bestScore) {
                    best = {Kind::BeatMatch, out, cue.startMs, overlapMs, rate};
                    best.alignment = AppleTransitionPlan::Alignment::Beat;
                    best.spectralScore = spectral;
                    bestScore = score;
                }
            }
        }
    }
    return best;
}

/** 用实际可听区间交叉淡化，曲尾静音只用于定位淡出的终点。 */
AppleTransitionPlan planFade(const AudioWindow &a, const AudioWindow &b, qint64 aEnd, qint64 bStart,
                             bool compatibleKeys) {
    constexpr int energyFrames = 90;
    const int aStartFrame = std::max(a.firstSound, a.lastSound - energyFrames + 1);
    const int bEndFrame = std::min(b.lastSound + 1, b.firstSound + energyFrames);
    const auto aLevel = rmsBetween(a, aStartFrame, a.lastSound + 1);
    const auto bLevel = rmsBetween(b, b.firstSound, bEndFrame);
    const auto peakLevel = std::max(aLevel, bLevel);
    // 高能量区只短暂叠播，安静的首尾给淡化更多时间。
    const auto maximumMs = compatibleKeys ? 2300.0 : 1000.0;
    const auto preferredMs = qRound64(std::clamp(2500.0 - 7800.0 * peakLevel, 800.0, maximumMs));
    const auto tailMs = aEnd - timeAt(a, a.firstSound);
    const auto headMs = timeAt(b, b.lastSound + 1) - bStart;
    const auto overlapMs = std::min({preferredMs, tailMs, headMs});
    if (overlapMs < 500) {
        return {};
    }
    return {AppleTransitionPlan::Kind::Fade, aEnd - overlapMs, bStart, overlapMs};
}

/** 优先用两首的稳定小节首拍切入，再比较普通拍点。 */
AppleTransitionPlan planOnBeat(const AudioWindow &a, const AudioWindow &b, const BeatGrid &aGrid,
                               const BeatGrid &bGrid, qint64 aEnd, qint64 bStart, bool compatibleKeys) {
    using Kind = AppleTransitionPlan::Kind;
    if (compatibleKeys) {
        auto plan = planBarMatch(a, b, aGrid, bGrid, aEnd, bStart);
        if (plan.kind == Kind::BeatMatch) {
            return plan;
        }
    }
    return planBeatMatch(a, b, aGrid, bGrid, aEnd, bStart, compatibleKeys);
}

AppleTransitionPlan planWithoutBeat(const AudioWindow &a, const AudioWindow &b, qint64 aEnd, qint64 bStart,
                                    bool compatibleKeys) {
    using Kind = AppleTransitionPlan::Kind;
    const auto fade = planFade(a, b, aEnd, bStart, compatibleKeys);
    if (fade.kind != Kind::Original) {
        return fade;
    }
    if (a.durationMs - aEnd >= quietFrames * frameMs || bStart >= quietFrames * frameMs) {
        constexpr qint64 trimFadeMs = 160;
        const auto overlapMs = std::min(aEnd, trimFadeMs);
        return {Kind::Trim, aEnd - overlapMs, bStart, overlapMs};
    }
    return {};
}

/** 首尾局部节拍作为全窗节拍的备选，成功时公开真正参与对拍的分析结果。 */
AppleTransitionPlan chooseTransition(const AudioWindow &a, const AudioWindow &b, BeatGrid &aGrid,
                                     BeatGrid &bGrid, bool compatibleKeys) {
    using Kind = AppleTransitionPlan::Kind;
    if (a.firstSound < 0) {
        return {};
    }
    const auto aEnd = std::min(a.durationMs, timeAt(a, a.lastSound + 6));
    const auto bStart =
        std::clamp<qint64>(timeAt(b, b.firstSound - 4), 0, AppleTransitionPlan::searchWindowMs);
    auto plan = planOnBeat(a, b, aGrid, bGrid, aEnd, bStart, compatibleKeys);
    if (plan.kind == Kind::BeatMatch) {
        return plan;
    }
    const auto aLocal = estimateGrid(a, BeatRegion::Outro);
    const auto bLocal = estimateGrid(b, BeatRegion::Intro);
    const std::array gridPairs{std::pair{aLocal, bLocal}, std::pair{aLocal, bGrid}, std::pair{aGrid, bLocal}};
    for (const auto &[outro, intro] : gridPairs) {
        plan = planOnBeat(a, b, outro, intro, aEnd, bStart, compatibleKeys);
        if (plan.kind == Kind::BeatMatch) {
            aGrid = outro;
            bGrid = intro;
            return plan;
        }
    }
    return planWithoutBeat(a, b, aEnd, bStart, compatibleKeys);
}
}

namespace {
AppleTransitionPlan analyzeTransitionFiles(const QUrl &outgoing, const QUrl &incoming,
                                           const std::atomic_bool &cancelled) {

    if (!incoming.isLocalFile() || outgoing == incoming || cancelled.load()) {
        return {};
    }
    const auto b = readWindow(incoming, false, cancelled);
    if (cancelled.load() || b.firstSound < 0) {
        return {};
    }
    const auto a = outgoing.isLocalFile() ? readWindow(outgoing, true, cancelled) : AudioWindow{};
    if (cancelled.load()) {
        return {};
    }
    const auto bKey = estimateKey(b.chroma);
    auto bGrid = estimateGrid(b);
    auto aGrid = estimateGrid(a);
    auto plan = chooseTransition(a, b, aGrid, bGrid, keysCanOverlap(estimateKey(a.chroma), bKey));
    plan.incomingAnalysis.tonic = bKey.tonic;
    plan.incomingAnalysis.minor = bKey.minor;
    plan.outgoingBpm = beatsPerMinute(aGrid);
    plan.incomingAnalysis.bpm = beatsPerMinute(bGrid);
    if (bGrid.beatsPerBar > 0) {
        plan.incomingAnalysis.firstBarMs = std::max<qint64>(0, timeAt(b, firstAudibleBar(b, bGrid)));
        plan.incomingAnalysis.beatsPerBar = bGrid.beatsPerBar;
    }
    return plan;
}
}
