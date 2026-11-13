#include "AppleTransitionAudio.h"
#include "AppleTransitionPlan.h"
#include "AudioTransitionTempo.h"

#import <AVFoundation/AVFoundation.h>

#include <QDir>
#include <QTemporaryFile>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <limits>

namespace {
constexpr qint64 preferredRampMs = 1800;
constexpr qint64 minimumRampMs = 500;
constexpr qint64 maximumPcmValues = 12 * 1024 * 1024;

using AudioTransitionTempo::TempoCurve;
bool stretch(AVAudioPCMBuffer *input, AVAudioPCMBuffer *output, const TempoCurve &curve, int sourceEnd,
             const std::atomic_bool &cancelled) {
    const bool result = AudioTransitionTempo::stretch(
        input.floatChannelData, output.floatChannelData, int(input.frameLength), int(output.frameCapacity),
        int(input.format.channelCount), qRound(input.format.sampleRate), curve, sourceEnd, cancelled);
    if (result) {
        output.frameLength = output.frameCapacity;
    }
    return result;
}

AVAssetTrack *singleAudioTrack(AVAsset *asset) {
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    return tracks.count == 1 ? tracks.firstObject : nil;
}

/** 在同一音轨上替换对拍区间，保留切入点前的原曲以支持向前拖动进度。 */
AVComposition *composePreparedTrack(AVAssetTrack *source, AVAssetTrack *intro, CMTime cue, CMTime sourceEnd,
                                    CMTime playbackEnd) {
    AVMutableComposition *composition = [AVMutableComposition composition];
    auto *track = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                           preferredTrackID:kCMPersistentTrackID_Invalid];
    if (cue.value > 0 && ![track insertTimeRange:CMTimeRangeMake(kCMTimeZero, cue)
                                         ofTrack:source
                                          atTime:kCMTimeZero
                                           error:nullptr]) {
        return nil;
    }
    const auto introDuration = CMTimeSubtract(playbackEnd, cue);
    if (![track insertTimeRange:CMTimeRangeMake(kCMTimeZero, introDuration)
                        ofTrack:intro
                         atTime:cue
                          error:nullptr]) {
        return nil;
    }
    const auto tail = CMTimeRangeFromTimeToTime(sourceEnd, CMTimeRangeGetEnd(source.timeRange));
    if (![track insertTimeRange:tail ofTrack:source atTime:playbackEnd error:nullptr]) {
        return nil;
    }
    return [composition copy];
}
}

struct AppleTransitionAudio::Data {
    AVAsset *source = nil;
    AVComposition *composition = nil;
    QString renderedPath;
    TempoCurve curve;
    double cueMs = 0;
    double sourceEndMs = 0;
    double playbackEndMs = 0;
};

AppleTransitionAudio::AppleTransitionAudio() : data(std::make_unique<Data>()) {
}

AppleTransitionAudio::~AppleTransitionAudio() {
    data->composition = nil;
    if (!data->renderedPath.isEmpty()) {
        QFile::remove(data->renderedPath);
    }
}

/** 在分析线程生成有界 PCM 片段，原曲未处理部分保留原来的音频样本。 */
std::shared_ptr<const AppleTransitionAudio> AppleTransitionAudio::render(const QUrl &source,
                                                                         const AppleTransitionPlan &plan,
                                                                         const std::atomic_bool &cancelled) {
    @autoreleasepool {
        if (!source.isLocalFile() || cancelled.load() || !std::isfinite(plan.incomingRate) ||
            plan.incomingRate < 0.80 || plan.incomingRate > 1.20 || plan.overlapMs <= 0 ||
            plan.overlapMs > AppleTransitionPlan::searchWindowMs || plan.incomingMs < 0) {
            return {};
        }
        NSURL *url = [NSURL fileURLWithPath:source.toLocalFile().toNSString()];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                                options:@{
                                                    AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                                                }];
        AVAssetTrack *sourceTrack = singleAudioTrack(asset);
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url
                                                   commonFormat:AVAudioPCMFormatFloat32
                                                    interleaved:NO
                                                          error:nullptr];
        if (!sourceTrack || !file || cancelled.load()) {
            return {};
        }
        const auto format = file.processingFormat;
        const int sampleRate = qRound(format.sampleRate);
        const auto channels = format.channelCount;
        if (sampleRate < 8000 || sampleRate > 192000 || channels == 0 || channels > 8) {
            return {};
        }
        const auto frameAt = [sampleRate](double ms) { return qRound64(ms * sampleRate / 1000); };
        const auto cueFrame = frameAt(plan.incomingMs);
        const auto trackEnd = CMTimeRangeGetEnd(sourceTrack.timeRange);
        const auto trackEndFrame =
            CMTimeConvertScale(trackEnd, sampleRate, kCMTimeRoundingMethod_RoundTowardZero);
        if (!CMTIME_IS_NUMERIC(trackEndFrame) ||
            CMTimeCompare(sourceTrack.timeRange.start, kCMTimeZero) != 0) {
            return {};
        }
        const auto availableFrames = std::min(qint64(file.length), trackEndFrame.value) - cueFrame;
        const auto availableMs = double(availableFrames) * 1000 / sampleRate;
        const auto rampMs =
            std::min<double>(preferredRampMs, (availableMs - plan.overlapMs * plan.incomingRate - 100) /
                                                  ((plan.incomingRate + 1.0) / 2));
        if (rampMs < minimumRampMs) {
            return {};
        }
        const TempoCurve curve{plan.incomingRate, double(plan.overlapMs), rampMs};
        const auto outputFrames = frameAt(curve.overlap + curve.ramp);
        const auto sourceFrames = frameAt(curve.sourceOffset(curve.overlap + curve.ramp));
        const auto inputFrames = std::min(availableFrames, sourceFrames + frameAt(40));
        if ((inputFrames + outputFrames) * channels > maximumPcmValues) {
            return {};
        }
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                                frameCapacity:AVAudioFrameCount(inputFrames)];
        AVAudioPCMBuffer *output =
            [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:AVAudioFrameCount(outputFrames)];
        file.framePosition = cueFrame;
        if (!input || !output || ![file readIntoBuffer:input error:nullptr] ||
            input.frameLength < AVAudioFrameCount(sourceFrames) ||
            !stretch(input, output, curve, int(sourceFrames), cancelled)) {
            return {};
        }

        QTemporaryFile rendered(QDir::tempPath() + "/rhine-tempo-XXXXXX.caf");
        if (!rendered.open()) {
            return {};
        }
        rendered.close();
        NSURL *renderedUrl = [NSURL fileURLWithPath:rendered.fileName().toNSString()];
        NSMutableDictionary *settings = [format.settings mutableCopy];
        settings[AVLinearPCMIsNonInterleaved] = @NO;
        AVAudioFile *writer = [[AVAudioFile alloc] initForWriting:renderedUrl
                                                         settings:settings
                                                     commonFormat:AVAudioPCMFormatFloat32
                                                      interleaved:NO
                                                            error:nullptr];
        if (!writer || ![writer writeFromBuffer:output error:nullptr] || cancelled.load()) {
            return {};
        }
        writer = nil;
        AVURLAsset *intro = [AVURLAsset URLAssetWithURL:renderedUrl options:nil];
        AVAssetTrack *introTrack = singleAudioTrack(intro);
        if (!introTrack) {
            return {};
        }
        auto prepared = std::shared_ptr<AppleTransitionAudio>(new AppleTransitionAudio);
        auto &state = *prepared->data;
        state.source = asset;
        state.curve = curve;
        const auto cue = CMTimeMake(cueFrame, sampleRate);
        const auto sourceEnd = CMTimeMake(cueFrame + sourceFrames, sampleRate);
        const auto playbackEnd = CMTimeMake(cueFrame + outputFrames, sampleRate);
        state.composition = composePreparedTrack(sourceTrack, introTrack, cue, sourceEnd, playbackEnd);
        if (!state.composition || cancelled.load()) {
            return {};
        }
        state.renderedPath = rendered.fileName();
        rendered.setAutoRemove(false);
        state.cueMs = CMTimeGetSeconds(cue) * 1000;
        state.sourceEndMs = CMTimeGetSeconds(sourceEnd) * 1000;
        state.playbackEndMs = CMTimeGetSeconds(playbackEnd) * 1000;
        return prepared;
    }
}

double AppleTransitionAudio::sourceMs(double playbackMs) const {
    if (playbackMs <= data->cueMs) {
        return playbackMs;
    }
    if (playbackMs >= data->playbackEndMs) {
        return data->sourceEndMs + playbackMs - data->playbackEndMs;
    }
    return data->cueMs + data->curve.sourceOffset(playbackMs - data->cueMs);
}

double AppleTransitionAudio::playbackMs(double sourceMs) const {
    if (sourceMs <= data->cueMs) {
        return sourceMs;
    }
    if (sourceMs >= data->sourceEndMs) {
        return data->playbackEndMs + sourceMs - data->sourceEndMs;
    }
    double low = data->cueMs;
    double high = data->playbackEndMs;
    for (int index = 0; index < 18; ++index) {
        const auto middle = (low + high) / 2;
        if (this->sourceMs(middle) < sourceMs) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return (low + high) / 2;
}

double AppleTransitionAudio::tempo(double playbackMs) const {
    if (playbackMs < data->cueMs || playbackMs >= data->playbackEndMs) {
        return 1.0;
    }
    return data->curve.tempo(playbackMs - data->cueMs);
}

double AppleTransitionAudio::rampProgress(double playbackMs) const {
    return data->curve.progress(playbackMs - data->cueMs);
}

double AppleTransitionAudio::restoredAtMs() const {
    return data->sourceEndMs;
}

AVAsset *AppleTransitionAudio::asset() const {
    return data->composition;
}

AVAsset *AppleTransitionAudio::sourceAsset() const {
    return data->source;
}
