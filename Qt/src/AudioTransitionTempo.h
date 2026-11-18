#pragma once
#include <QtGlobal>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <limits>

namespace AudioTransitionTempo {
struct TempoCurve {
    double initial = 1.0;
    double overlap = 0;
    double ramp = 0;

    double progress(double time) const {
        return std::clamp((time - overlap) / ramp, 0.0, 1.0);
    }

    double tempo(double time) const {
        const auto phase = progress(time);
        return std::lerp(initial, 1.0, phase * phase * (3.0 - 2.0 * phase));
    }

    // 对速度曲线积分，得到输出位置对应的原始输入位置。
    double sourceOffset(double time) const {
        const auto phase = progress(time);
        const auto integral = phase * phase * phase * (1.0 - 0.5 * phase);
        return initial * std::min(time, overlap + ramp) + (1.0 - initial) * ramp * integral +
               std::max(0.0, time - overlap - ramp);
    }
};

inline int strongestChannel(const float *const *input, int channels, int frames) {
    int channel = 0;
    double peakPower = -1;
    for (int index = 0; index < channels; ++index) {
        double power = 0;
        const auto *samples = input[index];
        for (int frame = 0; frame < frames; frame += 32) {
            power += double(samples[frame]) * samples[frame];
        }
        if (power > peakPower) {
            peakPower = power;
            channel = int(index);
        }
    }
    return channel;
}

/** 在名义时间附近找相位最接近的 PCM 帧，各声道共用同一个偏移。 */
inline int matchingFrame(const float *reference, const float *samples, int length, int nominal, int search,
                         int lastStart, int stride) {
    int best = nominal;
    double bestScore = -std::numeric_limits<double>::infinity();
    for (int candidate = std::max(0, nominal - search); candidate <= std::min(lastStart, nominal + search);
         candidate += stride) {
        double dot = 0;
        double previousPower = 0;
        double nextPower = 0;
        for (int frame = 0; frame < length; frame += stride * 2) {
            const auto left = double(reference[frame]);
            const auto right = double(samples[candidate + frame]);
            dot += left * right;
            previousPower += left * left;
            nextPower += right * right;
        }
        if (previousPower <= 1e-10 || nextPower <= 1e-10) {
            continue;
        }
        const auto distancePenalty = 0.035 * std::abs(candidate - nominal) / std::max(1, search);
        const auto score = dot / std::sqrt(previousPower * nextPower) - distancePenalty;
        if (score > bestScore) {
            bestScore = score;
            best = candidate;
        }
    }
    return best;
}

/** 重叠拼接短波形块，改变块间步距以保留音高；末段收敛到原始样本坐标。 */
inline bool stretch(const float *const *input, float *const *output, int inputFrames, int outputFrames,
                    int channels, int sampleRate, const TempoCurve &curve, int sourceEnd,
                    const std::atomic_bool &cancelled) {
    const int hop = qRound(sampleRate * 0.016);
    const int radius = qRound(sampleRate * 0.008);
    const int stride = std::max(1, sampleRate / 16000);
    const int channel = strongestChannel(input, channels, inputFrames);
    if (inputFrames < hop * 2 || outputFrames < hop * 2) {
        return false;
    }
    for (int index = 0; index < channels; ++index) {
        std::copy_n(input[index], hop * 2, output[index]);
    }
    for (int target = hop; target < outputFrames; target += hop) {
        if (cancelled.load()) {
            return false;
        }
        const int remaining = outputFrames - target;
        const int block = std::min(hop * 2, remaining);
        const int overlap = std::min(hop, block);
        const int lastStart = int(inputFrames) - block;
        const auto source =
            qRound(curve.sourceOffset(double(target) * 1000 / sampleRate) * sampleRate / 1000);
        int start = std::clamp(source, 0, lastStart);
        if (remaining <= 2 * hop) {
            start = sourceEnd - remaining;
        } else {
            const auto search = std::min(radius, (remaining - 2 * hop) / 4);
            start = matchingFrame(output[channel] + target, input[channel], overlap, start, search, lastStart,
                                  stride);
        }
        for (int index = 0; index < channels; ++index) {
            auto *destination = output[index] + target;
            const auto *samples = input[index] + start;
            for (int frame = 0; frame < overlap; ++frame) {
                const auto phase = double(frame) / std::max(1, overlap - 1);
                const auto gain = float(phase * phase * (3.0 - 2.0 * phase));
                destination[frame] = std::lerp(destination[frame], samples[frame], gain);
            }
            std::copy_n(samples + overlap, block - overlap, destination + overlap);
        }
    }
    return true;
}

}
