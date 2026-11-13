#include "AudioTransitionAnalysis.h"
#import <AVFoundation/AVFoundation.h>

namespace {
/** 在工作线程仅读取文件首尾；原始声道保留到能量计算，避免立体声反相抵消。 */
AudioWindow readWindow(const QUrl &url, bool tail, const std::atomic_bool &cancelled) {
    NSURL *fileUrl = [NSURL fileURLWithPath:url.toLocalFile().toNSString()];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileUrl
                                            options:@{
                                                AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                                            }];
    const auto duration = CMTimeGetSeconds(asset.duration);
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count != 1 || !std::isfinite(duration) || duration < 8 || duration > 24 * 3600) {
        return {};
    }
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nullptr];
    AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                   outputSettings:@{
                                                       AVFormatIDKey : @(kAudioFormatLinearPCM),
                                                       AVLinearPCMBitDepthKey : @32,
                                                       AVLinearPCMIsFloatKey : @YES,
                                                       AVLinearPCMIsNonInterleaved : @NO
                                                   }];
    if (!reader || ![reader canAddOutput:output] || cancelled.load()) {
        return {};
    }
    [reader addOutput:output];
    output.alwaysCopiesSampleData = NO;
    const auto windowLength = std::min(duration, double(windowSeconds));
    const auto offset = tail ? duration - windowLength : 0;
    reader.timeRange =
        CMTimeRangeMake(CMTimeMakeWithSeconds(offset, 1000000), CMTimeMakeWithSeconds(windowLength, 1000000));
    if (![reader startReading]) {
        return {};
    }

    WindowAnalyzer analyzer(qRound64(duration * 1000));
    std::vector<float> samples;
    while (!cancelled.load()) {
        CMSampleBufferRef raw = [output copyNextSampleBuffer];
        if (!raw) {
            break;
        }
        const auto release = [](CMSampleBufferRef value) { CFRelease(value); };
        const std::unique_ptr<std::remove_pointer_t<CMSampleBufferRef>, decltype(release)> buffer(raw,
                                                                                                  release);
        const auto *format =
            CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(raw));
        const auto frames = CMSampleBufferGetNumSamples(raw);
        const auto data = CMSampleBufferGetDataBuffer(raw);
        if (!format || frames <= 0 || !data || format->mChannelsPerFrame < 1 ||
            format->mChannelsPerFrame > maximumAnalysisChannels ||
            format->mBytesPerFrame != format->mChannelsPerFrame * sizeof(float)) {
            return {};
        }
        samples.resize(size_t(frames) * format->mChannelsPerFrame);
        if (CMBlockBufferCopyDataBytes(data, 0, samples.size() * sizeof(float), samples.data()) != noErr ||
            !analyzer.append(samples.data(), qsizetype(samples.size()), qRound(format->mSampleRate),
                             int(format->mChannelsPerFrame),
                             CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(raw)) * 1000)) {
            return {};
        }
    }
    if (cancelled.load()) {
        [reader cancelReading];
        return {};
    }
    return reader.status == AVAssetReaderStatusCompleted ? analyzer.finish() : AudioWindow{};
}
}

AppleTransitionPlan AppleTransitionPlan::analyze(const QUrl &outgoing, const QUrl &incoming,
                                                 const std::atomic_bool &cancelled) {
    @autoreleasepool {
        return analyzeTransitionFiles(outgoing, incoming, cancelled);
    }
}
