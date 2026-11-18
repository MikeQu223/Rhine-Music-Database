#include "AudioTransitionAnalysis.h"
#include "TransitionPcm.h"

#import <AVFoundation/AVFoundation.h>

namespace {
/** 在工作线程仅读取文件首尾；原始声道保留到能量计算，避免立体声反相抵消。 */
AudioWindow readWindowAVFoundation(const QUrl &url, bool tail, const std::atomic_bool &cancelled,
                                   bool &success) {
    @autoreleasepool {
        NSURL *fileUrl = [NSURL fileURLWithPath:url.toLocalFile().toNSString()];
        NSError *error = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:fileUrl
                                                   commonFormat:AVAudioPCMFormatFloat32
                                                    interleaved:NO
                                                          error:&error];
        if (!file) {
            return {};
        }
        AVAudioFormat *format = file.processingFormat;
        const double sampleRate = format.sampleRate;
        const auto channels = int(format.channelCount);
        const double duration = sampleRate > 0 ? double(file.length) / sampleRate : 0;
        if (cancelled.load() || sampleRate < 8000 || sampleRate > 192000 || channels < 1 ||
            channels > maximumAnalysisChannels || !std::isfinite(duration) || duration < 8 ||
            duration > 24 * 3600) {
            return {};
        }

        const auto requestedFrames = std::min<AVAudioFramePosition>(
            file.length, qRound64(std::min(duration, double(windowSeconds)) * sampleRate));
        const auto firstFrame = tail ? file.length - requestedFrames : 0;
        // 损坏或不支持随机定位的编码会让 AVAudioFile 抛 Objective-C 异常，交由 Qt 解码器回退。
        @try {
            file.framePosition = firstFrame;
        } @catch (NSException *) {
            return {};
        }
        WindowAnalyzer analyzer(qRound64(duration * 1000));
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
        if (!buffer) {
            return {};
        }

        std::vector<float> samples;
        AVAudioFramePosition remaining = requestedFrames;
        while (remaining > 0 && !cancelled.load()) {
            const auto wanted = AVAudioFrameCount(std::min<AVAudioFramePosition>(remaining, 4096));
            bool read = false;
            @try {
                read = [file readIntoBuffer:buffer frameCount:wanted error:&error];
            } @catch (NSException *) {
                return {};
            }
            if (!read || buffer.frameLength == 0) {
                return {};
            }
            const auto frames = int(buffer.frameLength);
            samples.resize(size_t(frames) * channels);
            // 分析器按交错采样消费；AVAudioFile 用非交错平面读取，避免额外拷贝整段音频。
            for (int channel = 0; channel < channels; ++channel) {
                const auto *plane = buffer.floatChannelData[channel];
                for (int frame = 0; frame < frames; ++frame) {
                    samples[size_t(frame) * channels + channel] = plane[frame];
                }
            }
            const auto offsetMs = double(firstFrame + requestedFrames - remaining) * 1000 / sampleRate;
            if (!analyzer.append(samples.data(), qsizetype(samples.size()), qRound(sampleRate), channels,
                                 offsetMs)) {
                return {};
            }
            remaining -= frames;
        }
        if (cancelled.load()) {
            return {};
        }
        success = true;
        return analyzer.finish();
    }
}

/** AVFoundation 不支持的编码交给项目 Qt/FFmpeg 后端 */
AudioWindow readWindowQt(const QUrl &source, bool tail, const std::atomic_bool &cancelled) {
    std::unique_ptr<WindowAnalyzer> analyzer;
    std::vector<float> samples;
    qint64 position = 0;
    // 部分高采样率 FLAC 没有声道布局，Qt 回退统一请求标准立体声，避免 FFmpeg 重采样中止。
    QAudioFormat analysisFormat;
    analysisFormat.setSampleRate(48000);
    analysisFormat.setChannelCount(2);
    analysisFormat.setSampleFormat(QAudioFormat::Float);
    analysisFormat.setChannelConfig(QAudioFormat::ChannelConfigStereo);
    const auto success = TransitionPcm::decode(
        source, cancelled, analysisFormat, [&](const QAudioBuffer &buffer, qint64 duration) {
            if (duration < 8000 || duration > 24LL * 3600 * 1000) {
                return TransitionPcm::Action::Fail;
            }
            const auto format = buffer.format();
            const auto rate = format.sampleRate();
            const auto channels = format.channelCount();
            if (rate < 8000 || rate > 192000 || channels < 1 || channels > maximumAnalysisChannels) {
                return TransitionPcm::Action::Fail;
            }
            const auto first =
                tail ? qRound64(std::max<qint64>(0, duration - AppleTransitionPlan::searchWindowMs) * rate /
                                1000.0)
                     : 0;
            const auto last = first + qRound64(AppleTransitionPlan::searchWindowMs * rate / 1000.0);
            const auto at =
                buffer.startTime() >= 0 ? qRound64(buffer.startTime() * rate / 1000000.0) : position;
            position = at + buffer.frameCount();
            const auto begin = std::clamp<qint64>(first - at, 0, buffer.frameCount());
            const auto end = std::clamp<qint64>(last - at, begin, buffer.frameCount());
            if (end > begin) {
                if (!analyzer) {
                    analyzer = std::make_unique<WindowAnalyzer>(duration);
                }
                if (!TransitionPcm::floats(buffer, samples) ||
                    !analyzer->append(samples.data() + begin * channels, (end - begin) * channels, rate,
                                      channels, double(at + begin) * 1000 / rate)) {
                    return TransitionPcm::Action::Fail;
                }
            }
            return position >= last ? TransitionPcm::Action::Complete : TransitionPcm::Action::Continue;
        });
    return success && analyzer ? analyzer->finish() : AudioWindow{};
}

AudioWindow readWindow(const QUrl &url, bool tail, const std::atomic_bool &cancelled) {
    bool nativeSuccess = false;
    auto window = readWindowAVFoundation(url, tail, cancelled, nativeSuccess);
    if (nativeSuccess || cancelled.load()) {
        return window;
    }
    return readWindowQt(url, tail, cancelled);
}
}

AppleTransitionPlan AppleTransitionPlan::analyze(const QUrl &outgoing, const QUrl &incoming,
                                                 const std::atomic_bool &cancelled) {
    @autoreleasepool {
        return analyzeTransitionFiles(outgoing, incoming, cancelled);
    }
}
