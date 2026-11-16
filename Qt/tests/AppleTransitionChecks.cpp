#include "../src/AppleTransitionPlan.h"
#include "TransitionTestTrack.h"
using TransitionTestTrack::writePulseTrack;

#include <QCoreApplication>
#include <QDebug>
#include <QTemporaryDir>
#include <cmath>

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
    const auto bPath = directory.filePath("b.wav");
    const auto cPath = directory.filePath("c.wav");
    const auto extendedPath = directory.filePath("extended.wav");
    if (!check(writePulseTrack(aPath, 120) && writePulseTrack(bPath, 124) && writePulseTrack(cPath, 160) &&
                   writePulseTrack(extendedPath, 147),
               "无法写入合成音轨")) {
        return 1;
    }
    const auto aUrl = QUrl::fromLocalFile(aPath);
    const auto fade = AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(cPath), cancelled);
    if (!check(fade.kind == AppleTransitionPlan::Kind::Fade && fade.overlapMs >= 800 &&
                   fade.incomingRate == 1.0,
               "拍速超出扩展范围且有可听首尾时应选择原速叠播")) {
        return 1;
    }
    const auto extended = AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(extendedPath), cancelled);
    qInfo("扩展变速方案 %d，对齐 %d，叠播 %lld ms，速率 %.4f，相似度 %.3f", int(extended.kind),
          int(extended.alignment), extended.overlapMs, extended.incomingRate, extended.spectralScore);
    if (!check(extended.kind == AppleTransitionPlan::Kind::BeatMatch &&
                   std::abs(extended.incomingRate - 120.0 / 147) < 0.008 && extended.overlapMs <= 2200,
               "约 18% 拍速差且起音证据充分时应使用较短的扩展变速")) {
        return 1;
    }
    const auto plan = AppleTransitionPlan::analyze(aUrl, QUrl::fromLocalFile(bPath), cancelled);
    qInfo("mode=%d outgoing=%lldms incoming=%lldms overlap=%lldms rate=%.5f", int(plan.kind), plan.outgoingMs,
          plan.incomingMs, plan.overlapMs, plan.incomingRate);
    if (!check(plan.kind == AppleTransitionPlan::Kind::BeatMatch &&
                   std::abs(plan.incomingRate - 120.0 / 124) < 0.008 && plan.overlapMs >= 3800 &&
                   plan.overlapMs <= 4200,
               "已知拍点未得到正确的保音高对拍方案")) {
        return 1;
    }
    if (!check(checkAppleTransitionAudio(QUrl::fromLocalFile(directory.filePath("continuous-tone.caf"))),
               "预渲染音频出现静音、跳点、移调或回速接缝异常")) {
        return 1;
    }
    return 0;
}
