#include "../src/AppleTransitionPlan.h"

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
bool writePulseTrack(const QString &path, int bpm, int chordRoot = -1, bool accentBars = true,
                     double startSeconds = 0.12, double endSeconds = 32.3) {
    constexpr int sampleRate = 16000;
    constexpr int sampleCount = 323 * sampleRate / 10;
    constexpr int channels = 2;
    constexpr quint32 dataBytes = sampleCount * channels * sizeof(qint16);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + dataBytes);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(1) << quint16(channels) << quint32(sampleRate)
           << quint32(sampleRate * channels * sizeof(qint16)) << quint16(channels * sizeof(qint16))
           << quint16(16);
    stream.writeRawData("data", 4);
    stream << dataBytes;
    constexpr std::array majorChord{0, 4, 7};
    std::array<double, majorChord.size()> chordFrequencies{};
    for (size_t index = 0; index < majorChord.size(); ++index) {
        chordFrequencies[index] = 130.813 * std::exp2((chordRoot + majorChord[index]) / 12.0);
    }
    for (int frame = 0; frame < sampleCount; ++frame) {
        const double time = double(frame) / sampleRate - startSeconds;
        const double beats = time * bpm / 60.0;
        const auto beat = int(std::floor(beats));
        const double sinceBeat = (beats - beat) * 60.0 / bpm;
        double sample = 0;
        if (time >= 0 && time < endSeconds && sinceBeat < 0.055) {
            const bool accented = accentBars && beat % 4 == 0;
            const auto amplitude = accented ? 22000.0 : 4500.0;
            sample = amplitude * std::sin(sinceBeat * 2 * std::numbers::pi * 135) * std::exp(-sinceBeat * 60);
        }
        if (chordRoot >= 0) {
            for (const auto frequency : chordFrequencies) {
                sample += 600 * std::sin(time * 2 * std::numbers::pi * frequency);
            }
        }
        stream << qint16(sample) << qint16(sample);
    }
    return stream.status() == QDataStream::Ok;
}

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
