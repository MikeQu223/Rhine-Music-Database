#include "AppleAudioPlayer.h"
#include "PlatformFeatures.h"

#import <AVFoundation/AVFoundation.h>
#ifdef Q_OS_IOS
#import <AVFAudio/AVFAudio.h>
#endif

#include <QJsonObject>
#include <QUrl>
#include <atomic>
#include <cmath>

namespace {
static_assert(PlatformFeatures::SpatialAudio);

qint64 milliseconds(CMTime time) {
    const double seconds = CMTimeGetSeconds(time);
    return std::isfinite(seconds) && seconds > 0 && seconds < 1e9 ? qRound64(seconds * 1000) : 0;
}

struct AudioTrackFormat {
    std::atomic_int sampleRateHz = 0;
    std::atomic_int channels = 0;
    std::atomic_uint codec = 0;
};

/** 只观测源音轨；异步元数据读取不阻塞起播，也不改变 AVPlayer 选择的音轨。 */
void observeTrackFormat(AVURLAsset *asset, std::shared_ptr<AudioTrackFormat> format) {
    [asset loadTracksWithMediaType:AVMediaTypeAudio
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *) {
                   if (tracks.count != 1) {
                       return;
                   }
                   AVAssetTrack *track = tracks.firstObject;
                   [track loadValuesAsynchronouslyForKeys:@[ @"formatDescriptions" ]
                                        completionHandler:^{
                                          if ([track statusOfValueForKey:@"formatDescriptions"
                                                                   error:nullptr] != AVKeyValueStatusLoaded ||
                                              track.formatDescriptions.count != 1) {
                                              return;
                                          }
                                          const auto *description =
                                              CMAudioFormatDescriptionGetStreamBasicDescription(
                                                  (__bridge CMAudioFormatDescriptionRef)
                                                      track.formatDescriptions.firstObject);
                                          if (description) {
                                              format->sampleRateHz = qRound(description->mSampleRate);
                                              format->channels = int(description->mChannelsPerFrame);
                                              format->codec = description->mFormatID;
                                          }
                                        }];
                 }];
}

}

struct AppleAudioPlayer::Session {
    AVPlayerItem *item = nil;
    AVPlayer *player = nil;
    id endObserver = nil;
    id failureObserver = nil;
    std::shared_ptr<std::atomic_bool> ended = std::make_shared<std::atomic_bool>(false);
    std::shared_ptr<std::atomic_bool> failed = std::make_shared<std::atomic_bool>(false);
    std::shared_ptr<AudioTrackFormat> trackFormat = std::make_shared<AudioTrackFormat>();
    bool activationFailed = false;
    // 每次跳转独立持有结果，已取消的旧回调无法覆盖新跳转。
    std::shared_ptr<std::atomic_int> seekResult;
    qint64 seekPositionMs = 0;
    bool paused = true;
};

AppleAudioPlayer::AppleAudioPlayer() : session(std::make_unique<Session>()) {
}

/** 保留来源选择的码流与 URL 编码，由 AVFoundation 负责解码、缓冲和系统输出。 */
std::unique_ptr<AppleAudioPlayer> AppleAudioPlayer::open(const QUrl &url) {
    NSURL *assetUrl = [NSURL URLWithString:QString::fromLatin1(url.toEncoded()).toNSString()];
    if (!assetUrl) {
        return {};
    }
    auto playback = std::unique_ptr<AppleAudioPlayer>(new AppleAudioPlayer);
    auto &state = *playback->session;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetUrl options:nil];
    state.item = [AVPlayerItem playerItemWithAsset:asset];
    // 允许系统处理普通立体声和原生多声道。系统控制中心决定实际空间化模式。
    state.item.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMonoStereoAndMultichannel;
    state.item.preferredPeakBitRate = 0;
    state.item.preferredForwardBufferDuration = 0;
    state.player = [AVPlayer playerWithPlayerItem:state.item];
    state.player.automaticallyWaitsToMinimizeStalling = YES;
    observeTrackFormat(asset, state.trackFormat);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    const auto ended = state.ended;
    const auto failed = state.failed;
    state.endObserver = [center addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                            object:state.item
                                             queue:nil
                                        usingBlock:^(NSNotification *) {
                                          ended->store(true);
                                        }];
    state.failureObserver = [center addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                                object:state.item
                                                 queue:nil
                                            usingBlock:^(NSNotification *) {
                                              failed->store(true);
                                            }];
    return playback;
}

AppleAudioPlayer::~AppleAudioPlayer() {
    [session->player pause];
    [session->item cancelPendingSeeks];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:session->endObserver];
    [center removeObserver:session->failureObserver];
    [session->player replaceCurrentItemWithPlayerItem:nil];
    [session->item.asset cancelLoading];
}

AppleAudioPlayer::Status AppleAudioPlayer::status() const {
    if (session->item.status == AVPlayerItemStatusFailed || session->player.status == AVPlayerStatusFailed ||
        session->failed->load() || session->activationFailed ||
        (session->seekResult && session->seekResult->load() < 0)) {
        return Status::Failed;
    }
    if (session->item.status != AVPlayerItemStatusReadyToPlay) {
        return Status::Loading;
    }
    if (!isSeeking() && session->ended->load() && (duration() == 0 || position() >= duration() - 50)) {
        return Status::Ended;
    }
    return Status::Ready;
}

bool AppleAudioPlayer::isPlaying() const {
    return session->player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
}

bool AppleAudioPlayer::isSeeking() const {
    return session->seekResult && session->seekResult->load() == 0;
}

qint64 AppleAudioPlayer::duration() const {
    return milliseconds(session->item.duration);
}

qint64 AppleAudioPlayer::position() const {
    if (isSeeking() || (session->seekResult && session->seekResult->load() < 0)) {
        return session->seekPositionMs;
    }
    return milliseconds(session->player.currentTime);
}

void AppleAudioPlayer::seek(qint64 positionMs) {
    setPaused(true);
    [session->item cancelPendingSeeks];
    session->ended->store(false);
    session->seekPositionMs = positionMs;
    const auto result = std::make_shared<std::atomic_int>(0);
    session->seekResult = result;
    [session->player seekToTime:CMTimeMake(positionMs, 1000)
                toleranceBefore:kCMTimeZero
                 toleranceAfter:kCMTimeZero
              completionHandler:^(BOOL finished) {
                result->store(finished ? 1 : -1);
              }];
}

void AppleAudioPlayer::setPaused(bool paused) {
    if (session->paused == paused) {
        return;
    }
    session->paused = paused;
    if (paused) {
        [session->player pause];
    } else {
#ifdef Q_OS_IOS
        AVAudioSession *audio = [AVAudioSession sharedInstance];
        const bool playbackCategory = [audio.category isEqualToString:AVAudioSessionCategoryPlayback] ||
                                      [audio setCategory:AVAudioSessionCategoryPlayback error:nullptr];
        if (!playbackCategory || ![audio setActive:YES error:nullptr]) {
            session->activationFailed = true;
            return;
        }
#endif
        [session->player play];
    }
}

void AppleAudioPlayer::setVolume(float volume) {
    session->player.volume = volume;
}

bool AppleAudioPlayer::isSeekable() const {
    return session->item.status == AVPlayerItemStatusReadyToPlay &&
           (duration() > 0 || session->item.seekableTimeRanges.count > 0);
}

QJsonObject AppleAudioPlayer::diagnosticState() const {
    const auto time = session->player.currentTime;
    qint64 bufferedMs = 0;
    for (NSValue *rangeValue in session->item.loadedTimeRanges) {
        const CMTimeRange range = rangeValue.CMTimeRangeValue;
        if (CMTimeRangeContainsTime(range, time)) {
            bufferedMs = milliseconds(CMTimeSubtract(CMTimeRangeGetEnd(range), time));
            break;
        }
    }
    const auto &format = *session->trackFormat;
    NSError *error = session->item.error;
    if (!error) {
        error = session->player.error;
    }
    QJsonObject values{
        {"sourceSampleRateHz", format.sampleRateHz.load()},
        {"sourceChannels", format.channels.load()},
        {"sourceCodecFourCC", double(format.codec.load())},
        {"nativeBufferedMs", double(bufferedMs)},
        {"nativeErrorCode", double(error.code)},
    };
#ifdef Q_OS_IOS
    AVAudioSession *audio = [AVAudioSession sharedInstance];
    AVAudioSessionPortDescription *port = audio.currentRoute.outputs.firstObject;
    if (port) {
        values["routeSampleRateHz"] = audio.sampleRate;
        values["routeChannels"] = int(audio.outputNumberOfChannels);
        values["routeSpatialAudioEnabled"] = bool(port.spatialAudioEnabled);
    }
#endif
    return values;
}
