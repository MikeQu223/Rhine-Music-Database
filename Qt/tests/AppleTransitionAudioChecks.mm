#include "../src/AppleTransitionAudio.h"
#include "../src/AppleTransitionPlan.h"

#import <AVFoundation/AVFoundation.h>

#include <QDebug>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <numbers>

namespace {
constexpr int sampleRate = 16000;
constexpr int sourceFrames = sampleRate * 9;
constexpr double frequency = 440;
constexpr double amplitude = 0.35;

bool writeTone(const QUrl &url) {
    const auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
    auto *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:sourceFrames];
    buffer.frameLength = sourceFrames;
    for (int index = 0; index < sourceFrames; ++index) {
        const auto sample =
            float(amplitude * std::sin(2 * std::numbers::pi * frequency * index / sampleRate));
        buffer.floatChannelData[0][index] = sample;
        buffer.floatChannelData[1][index] = -sample;
    }
    NSURL *fileUrl = [NSURL fileURLWithPath:url.toLocalFile().toNSString()];
    NSMutableDictionary *settings = [format.settings mutableCopy];
    settings[AVLinearPCMIsNonInterleaved] = @NO;
    AVAudioFile *writer = [[AVAudioFile alloc] initForWriting:fileUrl settings:settings error:nullptr];
    return writer && [writer writeFromBuffer:buffer error:nullptr];
}

/** 读取送入播放器的同一条合成音轨，核对采样连续、相位、音高和未处理尾段。 */
bool checkSamples(const AppleTransitionAudio &audio) {
    AVAsset *asset = audio.asset();
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nullptr];
    auto *output =
        [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:asset.tracks
                                                                audioSettings:@{
                                                                    AVFormatIDKey : @(kAudioFormatLinearPCM),
                                                                    AVLinearPCMBitDepthKey : @32,
                                                                    AVLinearPCMIsFloatKey : @YES,
                                                                    AVSampleRateKey : @(sampleRate),
                                                                    AVNumberOfChannelsKey : @2
                                                                }];
    if (!reader || ![reader canAddOutput:output]) {
        return false;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        return false;
    }
    constexpr int energyWindow = sampleRate / 100;
    constexpr int pitchWindow = sampleRate / 4;
    int frames = 0;
    int crossings = 0;
    float previous = 0;
    double energy = 0;
    double minimumRms = 1;
    double largestJump = 0;
    double largestPitchError = 0;
    double tailError = 0;
    double channelError = 0;
    while (auto sampleBuffer = [output copyNextSampleBuffer]) {
        const auto count = int(CMSampleBufferGetNumSamples(sampleBuffer));
        const auto time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        AudioBufferList list{};
        CMBlockBufferRef storage = nullptr;
        const auto status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, nullptr, &list, sizeof(list), nullptr, nullptr, 0, &storage);
        const bool valid = status == noErr && list.mNumberBuffers == 1 && list.mBuffers[0].mData &&
                           list.mBuffers[0].mDataByteSize >= count * 2 * sizeof(float) &&
                           std::abs(CMTimeGetSeconds(time) * sampleRate - frames) <= 1;
        if (!valid) {
            if (storage) {
                CFRelease(storage);
            }
            CFRelease(sampleBuffer);
            return false;
        }
        const auto *samples = static_cast<const float *>(list.mBuffers[0].mData);
        for (int index = 0; index < count; ++index) {
            const auto sample = samples[index * 2];
            channelError = std::max(channelError, double(std::abs(sample + samples[index * 2 + 1])));
            if (frames > 0) {
                largestJump = std::max(largestJump, double(std::abs(sample - previous)));
                crossings += previous <= 0 && sample > 0;
            }
            previous = sample;
            const auto sourceMs = audio.sourceMs(double(frames) * 1000 / sampleRate);
            if (sourceMs > 6500) {
                const auto sourceFrame = qRound64(sourceMs * sampleRate / 1000);
                const auto expected =
                    amplitude * std::sin(2 * std::numbers::pi * frequency * sourceFrame / sampleRate);
                tailError = std::max(tailError, std::abs(expected - sample));
            }
            ++frames;
            energy += double(sample) * sample;
            if (frames % energyWindow == 0) {
                minimumRms = std::min(minimumRms, std::sqrt(energy / energyWindow));
                energy = 0;
            }
            if (frames % pitchWindow == 0) {
                largestPitchError = std::max(largestPitchError, std::abs(4.0 * crossings - frequency));
                crossings = 0;
            }
        }
        CFRelease(storage);
        CFRelease(sampleBuffer);
    }
    qInfo("预渲染 PCM %d 帧，最低 10 ms RMS %.3f，最大相邻幅值差 %.3f，音高偏差 %.1f Hz，尾段误差 %.4f",
          frames, minimumRms, largestJump, largestPitchError, tailError);
    return reader.status == AVAssetReaderStatusCompleted && minimumRms > 0.16 && largestJump < 0.13 &&
           largestPitchError <= 12 && tailError < 0.07 && channelError < 0.0001 &&
           std::abs(audio.sourceMs(double(frames) * 1000 / sampleRate) - 9000) < 1;
}
}

bool checkAppleTransitionAudio(const QUrl &url) {
    @autoreleasepool {
        if (!writeTone(url)) {
            return false;
        }
        const std::atomic_bool cancelled = false;
        for (const double rate : {1.153, 0.858}) {
            const AppleTransitionPlan plan{AppleTransitionPlan::Kind::BeatMatch, 0, 960, 2329, rate};
            const auto audio = AppleTransitionAudio::render(url, plan, cancelled);
            if (!audio || std::abs(audio->tempo(1000) - rate) > 0.001 ||
                std::abs(audio->tempo(4190) - (1.0 + rate) / 2) > 0.001 ||
                std::abs(audio->sourceMs(audio->playbackMs(3800)) - 3800) > 0.1 || !checkSamples(*audio)) {
                return false;
            }
        }
        return true;
    }
}
