#include "../src/AudioTransitionAnalysis.h"

#include <QCoreApplication>
#include <QDebug>

namespace {
// 本回归只覆盖纯选点函数，不读取真实文件；
// 占位实现用于闭合共享头文件里的分析入口。
AudioWindow readWindow(const QUrl &, bool, const std::atomic_bool &) {
    return {};
}

bool check(bool success, const char *message) {
    if (!success) {
        qCritical("%s", message);
    }
    return success;
}

AudioWindow makeWindow(qint64 offsetMs, int spectralBand, int onsetPeriod = 50) {
    AudioWindow window;
    window.offsetMs = offsetMs;
    window.durationMs = 30000;
    window.firstSound = 20;
    window.lastSound = 1980;
    window.rms.assign(2000, 0.1f);
    window.onset.assign(2000, 0.0f);
    window.spectralOnset.assign(2000, SpectralFrame{});
    for (int frame = 50; frame <= window.lastSound; frame += onsetPeriod) {
        window.onset[frame] = 1.0f;
        window.spectralOnset[frame][spectralBand] = 1.0f;
    }
    return window;
}

BeatGrid makeGrid(bool confident, double period = 50) {
    return {period, 50, confident ? 50.0 : -1.0, confident ? 4 : 0, confident};
}

qint64 outgoingEnd(const AudioWindow &window) {
    return std::min(window.durationMs, timeAt(window, window.lastSound + 6));
}

qint64 incomingStart(const AudioWindow &window) {
    return std::clamp<qint64>(timeAt(window, window.firstSound - 4), 0, AppleTransitionPlan::searchWindowMs);
}
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);

    // 使用互不重叠的低频和高频起音，音色相似度为零；
    // 两首的拍点和小节网格完全一致。
    const auto outgoing = makeWindow(10000, 0);
    const auto incoming = makeWindow(0, 2);
    const auto aEnd = outgoingEnd(outgoing);
    const auto bStart = incomingStart(incoming);
    const auto confident = makeGrid(true);
    const auto beat = planBeatMatch(outgoing, incoming, confident, confident, aEnd, bStart, true);
    if (!check(beat.kind == AppleTransitionPlan::Kind::BeatMatch &&
                   beat.alignment == AppleTransitionPlan::Alignment::Beat && beat.spectralScore < 1e-6,
               "近拍速且相位可靠时不应要求音色相似")) {
        return 1;
    }

    const auto keyClash = planBeatMatch(outgoing, incoming, confident, confident, aEnd, bStart, false);
    if (!check(keyClash.kind == AppleTransitionPlan::Kind::Original,
               "调性冲突且没有起音相似度时不应只凭拍点强行对拍")) {
        return 1;
    }

    const auto uncertain = makeGrid(false);
    const auto fallback = planBeatMatch(outgoing, incoming, uncertain, uncertain, aEnd, bStart, true);
    if (!check(fallback.kind == AppleTransitionPlan::Kind::Original,
               "相位不可靠时仍应拒绝音色不相似的拍点候选")) {
        return 1;
    }

    const auto extendedLowScore =
        planBeatMatch(outgoing, incoming, confident, makeGrid(true, 61), aEnd, bStart, true);
    if (!check(extendedLowScore.kind == AppleTransitionPlan::Kind::Original,
               "扩展变速区间不能在起音证据不足时强行对拍")) {
        return 1;
    }

    const auto extendedIncoming = makeWindow(0, 0, 61);
    const auto extendedStart = incomingStart(extendedIncoming);
    const auto extendedAligned =
        planBeatMatch(outgoing, extendedIncoming, confident, makeGrid(true, 61), aEnd, extendedStart, true);
    if (!check(extendedAligned.kind == AppleTransitionPlan::Kind::BeatMatch,
               "扩展变速区间在相位和起音证据都可靠时应允许对拍")) {
        return 1;
    }
    return 0;
}
