#include "../src/AppleTransitionPlan.h"
#include "TransitionTestTrack.h"
using TransitionTestTrack::writePulseTrack;

#include <QCoreApplication>
#include <QDataStream>
#include <QDebug>
#include <QFile>
#include <QTemporaryDir>
#include <array>
#include <cmath>
#include <numbers>

bool checkAppleTransitionAudio(const QUrl &url);

namespace {

bool check(bool success, const char *message) {
    if (!success) {
        qCritical("%s", message);
    }
    return success;
}
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    const std::atomic_bool cancelled = false;
    QTemporaryDir directory;
    const auto aPath = directory.filePath("a.wav");
    if (!check(checkAppleTransitionAudio(QUrl::fromLocalFile(directory.filePath("continuous-tone.caf"))),
               "预渲染音频出现静音、跳点、移调或回速接缝异常")) {
        return 1;
    }
    const auto bPath = directory.filePath("b.wav");
    const auto cPath = directory.filePath("c.wav");
    const auto tonicPath = directory.filePath("tonic.wav");
    const auto clashPath = directory.filePath("clash.wav");
    const auto widerTempoPath = directory.filePath("wider-tempo.wav");
    const auto wideOutroPath = directory.filePath("wide-outro.wav");
    const auto lateCuePath = directory.filePath("late-cue.wav");
    const auto silencePath = directory.filePath("silence.wav");
    if (!check(writePulseTrack(aPath, 120) && writePulseTrack(bPath, 124) && writePulseTrack(cPath, 147) &&
                   writePulseTrack(tonicPath, 120, 0) && writePulseTrack(clashPath, 124, 6) &&
                   writePulseTrack(widerTempoPath, 139, -1, false) &&
                   writePulseTrack(wideOutroPath, 120, -1, false, 0.12, 20.8) &&
                   writePulseTrack(lateCuePath, 124, -1, false, 7.2) &&
                   writePulseTrack(silencePath, 124, -1, false, 20.1),
               "无法写入合成音轨")) {
        return 1;
    }
    const auto aUrl = QUrl::fromLocalFile(aPath);
    const auto bUrl = QUrl::fromLocalFile(bPath);
    const auto clash = AppleTransitionPlan::analyze(QUrl::fromLocalFile(tonicPath),
                                                    QUrl::fromLocalFile(clashPath), cancelled);
    qInfo("调性冲突方案 %d，对齐 %d，叠播 %lld ms，BPM %.2f/%.2f，调性 %d/%d", int(clash.kind),
          int(clash.alignment), clash.overlapMs, clash.outgoingBpm, clash.incomingAnalysis.bpm,
          clash.incomingAnalysis.tonic, clash.incomingAnalysis.minor);
    if (!check(clash.kind == AppleTransitionPlan::Kind::BeatMatch &&
                   clash.alignment == AppleTransitionPlan::Alignment::Beat && clash.overlapMs <= 1500 &&
                   clash.incomingAnalysis.tonic == 6 && !clash.incomingAnalysis.minor &&
                   std::abs(clash.incomingAnalysis.bpm - 124) < 1.0,
               "调性冲突时应缩短叠播，即使两首拍速接近")) {
        return 1;
    }
    const auto fade = AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(cPath), cancelled);
    if (!check(fade.kind == AppleTransitionPlan::Kind::Fade && fade.overlapMs >= 800 &&
                   fade.incomingRate == 1.0,
               "拍速不兼容且有可听首尾时应选择原速叠播")) {
        return 1;
    }
    const auto widerTempo =
        AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(widerTempoPath), cancelled);
    if (!check(widerTempo.kind == AppleTransitionPlan::Kind::BeatMatch &&
                   widerTempo.alignment == AppleTransitionPlan::Alignment::Beat &&
                   std::abs(widerTempo.incomingRate - 120.0 / 139) < 0.008,
               "相差约 14% 的稳定拍速应保音高对拍")) {
        return 1;
    }
    const auto plan = AppleTransitionPlan::analyze(aUrl, bUrl, cancelled);
    qInfo("mode=%d outgoing=%lldms incoming=%lldms overlap=%lldms rate=%.5f", int(plan.kind), plan.outgoingMs,
          plan.incomingMs, plan.overlapMs, plan.incomingRate);
    if (!check(plan.kind == AppleTransitionPlan::Kind::BeatMatch &&
                   std::abs(plan.incomingRate - 120.0 / 124) < 0.008 && plan.overlapMs >= 3800 &&
                   plan.overlapMs <= 4200,
               "已知拍点未得到正确的保音高对拍方案")) {
        return 1;
    }
    const auto lateCue = AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(lateCuePath), cancelled);
    const auto wideOutro = AppleTransitionPlan::analyze(QUrl::fromLocalFile(wideOutroPath), bUrl, cancelled);
    const auto silence = AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(silencePath), cancelled);
    qInfo("后移入点 %lld ms，方案 %d，相似度 %.3f，长静音入点 %lld ms", lateCue.incomingMs, int(lateCue.kind),
          lateCue.spectralScore, silence.incomingMs);
    qInfo("扩展曲尾出点 %lld ms，方案 %d，相似度 %.3f", wideOutro.outgoingMs, int(wideOutro.kind),
          wideOutro.spectralScore);
    if (!check(wideOutro.kind == AppleTransitionPlan::Kind::BeatMatch && wideOutro.outgoingMs >= 12300 &&
                   wideOutro.outgoingMs < 22300,
               "应允许在旧曲结束前 10 到 20 秒选择可靠拍点")) {
        return 1;
    }
    if (!check(lateCue.kind == AppleTransitionPlan::Kind::BeatMatch && lateCue.incomingMs > 5000 &&
                   lateCue.incomingMs <= 20000 && silence.kind == AppleTransitionPlan::Kind::Original,
               "应允许新曲 5 到 20 秒的拍点，20 秒之后的起音不参与分析")) {
        return 1;
    }
    return 0;
}
