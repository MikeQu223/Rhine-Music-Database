#include "AppleAudioPlayer.h"
#include "AppleTransitionAudio.h"
#include "PlatformFeatures.h"

#import <AVFoundation/AVFoundation.h>
#ifdef Q_OS_IOS
#import <AVFAudio/AVFAudio.h>
#else
#import <CoreAudio/CoreAudio.h>
#endif

#include <QFile>
#include <QJsonObject>
#include <QUrl>
#include <QtEndian>
#include <algorithm>
#include <atomic>
#include <cmath>

#if !__has_feature(objc_arc)
#error "AppleAudioPlayer 的异步会话必须启用 Objective-C ARC"
#endif

namespace {
static_assert(PlatformFeatures::SpatialAudio);

qint64 milliseconds(CMTime time) {
    const double seconds = CMTimeGetSeconds(time);
    return std::isfinite(seconds) && seconds > 0 && seconds < 1e9 ? qRound64(seconds * 1000) : 0;
}

/** 本地 FLAC 的 STREAMINFO 记录有效样本总数，排除最后一包填充与播放器时钟漂移。 */
CMTime localFlacEnd(const QUrl &url) {
    if (!url.isLocalFile() || !url.path().endsWith(".flac", Qt::CaseInsensitive)) {
        return kCMTimeInvalid;
    }
    QFile file(url.toLocalFile());
    if (!file.open(QIODevice::ReadOnly)) {
        return kCMTimeInvalid;
    }
    // 文件标记 4 字节，元数据块头 4 字节，随后必须是 34 字节 STREAMINFO。
    const auto header = file.read(42);
    if (header.size() != 42 || !header.startsWith("fLaC") || (quint8(header[4]) & 0x7f) != 0 ||
        header[5] != 0 || header[6] != 0 || quint8(header[7]) != 34) {
        return kCMTimeInvalid;
    }
    const auto format = qFromBigEndian<quint64>(header.constData() + 18);
    const auto sampleRate = qint32(format >> 44);
    const auto sampleCount = qint64(format & ((quint64(1) << 36) - 1));
    if (sampleRate <= 0 || sampleCount <= 0) {
        return kCMTimeInvalid;
    }
    return CMTimeMake(sampleCount, sampleRate);
}

struct AudioTrackFormat {
    std::atomic_int sampleRateHz = 0;
    std::atomic_int channels = 0;
    std::atomic_uint codec = 0;
};

/** 只观测源音轨；异步元数据读取不阻塞起播，也不改变 AVPlayer 选择的音轨。 */
void observeTrackFormat(AVAsset *asset, std::shared_ptr<AudioTrackFormat> format) {
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
    std::shared_ptr<const AppleTransitionAudio> transitionAudio;
    CMTime localEnd = kCMTimeInvalid;
    bool isRemote = false;
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
    std::shared_ptr<std::atomic_bool> prerolled;
    bool tempoWasRestored = false;

    double toSourceMs(double playbackMs) const {
        return transitionAudio ? transitionAudio->sourceMs(playbackMs) : playbackMs;
    }

    CMTime toPlaybackTime(double sourceMs) const {
        const auto playbackMs = transitionAudio ? transitionAudio->playbackMs(sourceMs) : sourceMs;
        return CMTimeMakeWithSeconds(playbackMs / 1000, 1000000);
    }

    CMTime flacEnd() const {
        if (CMTIME_IS_NUMERIC(localEnd)) {
            return localEnd;
        }
        if (isRemote && trackFormat->codec.load() == kAudioFormatFLAC) {
            return item.duration;
        }
        return kCMTimeInvalid;
    }
};

AppleAudioPlayer::AppleAudioPlayer() : session(std::make_unique<Session>()) {
}

/** 保留来源选择的码流与 URL 编码，由 AVFoundation 负责解码、缓冲和系统输出。 */
std::unique_ptr<AppleAudioPlayer>
AppleAudioPlayer::open(const QUrl &url, std::shared_ptr<const AppleTransitionAudio> transitionAudio) {
    NSURL *assetUrl = [NSURL URLWithString:QString::fromLatin1(url.toEncoded()).toNSString()];
    if (!assetUrl) {
        return {};
    }
    auto playback = std::unique_ptr<AppleAudioPlayer>(new AppleAudioPlayer);
    auto &state = *playback->session;
    state.transitionAudio = std::move(transitionAudio);
    AVAsset *source = state.transitionAudio ? state.transitionAudio->sourceAsset()
                                            : [AVURLAsset URLAssetWithURL:assetUrl options:nil];
    AVAsset *asset = state.transitionAudio ? state.transitionAudio->asset() : source;
    state.item = [AVPlayerItem playerItemWithAsset:asset];
    state.isRemote = !url.isLocalFile();
    state.localEnd = localFlacEnd(url);
    if (CMTIME_IS_NUMERIC(state.localEnd)) {
        // 部分 FLAC 播完最后一包后仍推进时钟且不报 EOF，显式绑定到有效样本末尾。
        state.item.forwardPlaybackEndTime =
            state.transitionAudio ? state.toPlaybackTime(CMTimeGetSeconds(state.localEnd) * 1000)
                                  : state.localEnd;
    }
    // 允许系统处理普通立体声和原生多声道。系统控制中心决定实际空间化模式。
    state.item.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMonoStereoAndMultichannel;
    state.item.preferredPeakBitRate = 0;
    state.item.preferredForwardBufferDuration = 0;
    state.player = [AVPlayer playerWithPlayerItem:state.item];
    state.player.automaticallyWaitsToMinimizeStalling = YES;
    observeTrackFormat(source, state.trackFormat);
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
    [session->player cancelPendingPrerolls];
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
    const auto currentTime = session->player.currentTime;
    // 在线 FLAC 也可能在音频缓冲耗尽后继续推进时钟，不能依赖迟到的结束通知。
    auto flacEnd = session->flacEnd();
    if (session->transitionAudio && CMTIME_IS_NUMERIC(flacEnd)) {
        flacEnd = session->toPlaybackTime(CMTimeGetSeconds(flacEnd) * 1000);
    }
    const bool reachedFlacEnd = !session->paused && milliseconds(flacEnd) > 0 &&
                                CMTIME_IS_NUMERIC(currentTime) && CMTimeCompare(currentTime, flacEnd) >= 0;
    // 点播流的结尾可能与标称时长略有偏差。系统确认结束且时钟已停时，接受该结束事件。
    const bool nativePaused = session->player.timeControlStatus == AVPlayerTimeControlStatusPaused;
    const bool notifiedEnd =
        session->ended->load() && (nativePaused || duration() == 0 || position() >= duration() - 50);
    if (!isSeeking() && (reachedFlacEnd || notifiedEnd)) {
        return Status::Ended;
    }
    return Status::Ready;
}

bool AppleAudioPlayer::isPlaying() const {
    return session->player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
}

/** 只识别 AVPlayer 在曲尾自行暂停。用户暂停、跳转及等待数据不属于结束。 */
bool AppleAudioPlayer::isPausedAtEnd() const {
    if (session->paused || isSeeking() || session->item.status != AVPlayerItemStatusReadyToPlay ||
        session->player.timeControlStatus != AVPlayerTimeControlStatusPaused || session->player.rate != 0) {
        return false;
    }
    constexpr qint64 endToleranceMs = 200;
    const auto durationMs = duration();
    return durationMs > 0 && position() >= std::max<qint64>(1, durationMs - endToleranceMs);
}

bool AppleAudioPlayer::isSeeking() const {
    return session->seekResult && session->seekResult->load() == 0;
}

qint64 AppleAudioPlayer::duration() const {
    if (CMTIME_IS_NUMERIC(session->localEnd)) {
        return milliseconds(session->localEnd);
    }
    return qRound64(session->toSourceMs(milliseconds(session->item.duration)));
}

qint64 AppleAudioPlayer::position() const {
    if (isSeeking() || (session->seekResult && session->seekResult->load() < 0)) {
        return session->seekPositionMs;
    }
    const auto timeMs = milliseconds(session->player.currentTime);
    const auto positionMs = qRound64(session->toSourceMs(timeMs));
    const auto flacEndMs = milliseconds(session->flacEnd());
    return flacEndMs > 0 ? std::min(positionMs, flacEndMs) : positionMs;
}

double AppleAudioPlayer::playbackOffsetFrom(qint64 sourceMs) const {
    return milliseconds(session->player.currentTime) -
           CMTimeGetSeconds(session->toPlaybackTime(sourceMs)) * 1000;
}

void AppleAudioPlayer::seek(qint64 positionMs) {
    setPaused(true);
    [session->item cancelPendingSeeks];
    session->ended->store(false);
    session->seekPositionMs = positionMs;
    const auto result = std::make_shared<std::atomic_int>(0);
    session->seekResult = result;
    [session->player seekToTime:session->toPlaybackTime(positionMs)
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
        session->player.automaticallyWaitsToMinimizeStalling = YES;
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

/** 识别支持双播放器过渡的系统输出。 */
AppleAudioPlayer::TransitionOutput AppleAudioPlayer::transitionOutput() {
#ifdef Q_OS_IOS
    AVAudioSession *audio = [AVAudioSession sharedInstance];
    const auto outputs = audio.currentRoute.outputs;
    if (outputs.count != 1) {
        return TransitionOutput::Unsupported;
    }
    const auto port = outputs.firstObject.portType;
    if ([port isEqualToString:AVAudioSessionPortBuiltInSpeaker] ||
        [port isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        return TransitionOutput::BuiltIn;
    }
    if ([port isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        [port isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [port isEqualToString:AVAudioSessionPortBluetoothHFP]) {
        return TransitionOutput::Bluetooth;
    }
    if ([port isEqualToString:AVAudioSessionPortHeadphones] ||
        [port isEqualToString:AVAudioSessionPortUSBAudio] ||
        [port isEqualToString:AVAudioSessionPortLineOut] || [port isEqualToString:AVAudioSessionPortHDMI]) {
        return TransitionOutput::Wired;
    }
    return TransitionOutput::Unsupported;
#else
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
                                       kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr ||
        device == kAudioObjectUnknown) {
        return TransitionOutput::Unsupported;
    }
    UInt32 transport = 0;
    size = sizeof(transport);
    address.mSelector = kAudioDevicePropertyTransportType;
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &transport) != noErr) {
        return TransitionOutput::Unsupported;
    }
    if (transport == kAudioDeviceTransportTypeBuiltIn) {
        return TransitionOutput::BuiltIn;
    }
    if (transport == kAudioDeviceTransportTypeBluetooth ||
        transport == kAudioDeviceTransportTypeBluetoothLE) {
        return TransitionOutput::Bluetooth;
    }
    if (transport == kAudioDeviceTransportTypeUSB || transport == kAudioDeviceTransportTypeHDMI ||
        transport == kAudioDeviceTransportTypeDisplayPort ||
        transport == kAudioDeviceTransportTypeThunderbolt) {
        return TransitionOutput::Wired;
    }
    return TransitionOutput::Unsupported;
#endif
}

bool AppleAudioPlayer::preroll() {
    if (status() != Status::Ready || session->player.status != AVPlayerStatusReadyToPlay ||
        session->player.rate != 0) {
        return false;
    }
    const auto ready = std::make_shared<std::atomic_bool>(false);
    session->prerolled = ready;
    [session->player prerollAtRate:1.0f
                 completionHandler:^(BOOL finished) {
                   ready->store(finished);
                 }];
    return true;
}

bool AppleAudioPlayer::isPrerolled() const {
    return session->prerolled && session->prerolled->load() && status() == Status::Ready;
}

/** 读取 A 的时钟安排 B 的起播，避免修改 A 的时间基准或缓冲策略。 */
bool AppleAudioPlayer::synchronizeWith(const AppleAudioPlayer &outgoing, qint64 outgoingMs,
                                       qint64 incomingMs) {
    if (!isPrerolled() || !outgoing.isPlaying()) {
        return false;
    }
    const auto hostClock = CMClockGetHostTimeClock();
    const auto cue = outgoing.session->toPlaybackTime(outgoingMs);
    const auto now = CMClockGetTime(hostClock);
    const auto current = outgoing.session->player.currentTime;
    const auto outgoingRate = outgoing.session->player.rate;
    if (outgoingRate <= 0) {
        return false;
    }
    const auto lead = CMTimeGetSeconds(CMTimeSubtract(cue, current)) / outgoingRate;
    if (!std::isfinite(lead)) {
        return false;
    }
    // 设备时钟与主机时钟未建立映射时，用相邻的主机时间和媒体时间采样推算短距离起播点。
    auto hostTime = CMTimeAdd(now, CMTimeMakeWithSeconds(lead, 1000000000));
    if (const auto timebase = outgoing.session->item.timebase) {
        const auto converted = CMSyncConvertTime(cue, timebase, hostClock);
        const auto error = CMTimeGetSeconds(CMTimeSubtract(converted, hostTime));
        // currentTime 可能停留在上一音频缓冲边界，允许一个缓冲间隔的差异。
        if (std::isfinite(error) && std::abs(error) < 0.080) {
            hostTime = converted;
        }
    }
    const auto scheduledLead = CMTimeGetSeconds(CMTimeSubtract(hostTime, now));
    if (scheduledLead < 0.055 || scheduledLead > 0.550) {
        return false;
    }
    session->player.automaticallyWaitsToMinimizeStalling = NO;
    const auto incomingCue = incomingMs > 0 ? session->toPlaybackTime(incomingMs) : kCMTimeInvalid;
    [session->player setRate:1.0f time:incomingCue atHostTime:hostTime];
    session->paused = false;
    return true;
}

void AppleAudioPlayer::completeTransition() {
    session->player.automaticallyWaitsToMinimizeStalling = YES;
}

bool AppleAudioPlayer::takeTempoRestored() {
    const bool wasRestored = session->tempoWasRestored;
    session->tempoWasRestored =
        session->transitionAudio && isPlaying() && position() >= session->transitionAudio->restoredAtMs();
    return session->tempoWasRestored && !wasRestored;
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
    const auto timebase = session->item.timebase;
    NSError *error = session->item.error;
    if (!error) {
        error = session->player.error;
    }
    const auto *prepared = session->transitionAudio.get();
    const auto playbackMs = milliseconds(time);
    const auto rampProgress = prepared ? prepared->rampProgress(playbackMs) : 0.0;
    const auto tempo = prepared ? prepared->tempo(playbackMs) : 1.0;
    QJsonObject values{
        {"sourceSampleRateHz", format.sampleRateHz.load()},
        {"sourceChannels", format.channels.load()},
        {"sourceCodecFourCC", double(format.codec.load())},
        {"nativeBufferedMs", double(bufferedMs)},
        {"nativeErrorCode", double(error.code)},
        {"nativePlayingRate", double(session->player.rate)},
        {"nativeEffectivePlayingRate", timebase ? CMTimebaseGetRate(timebase) : 0.0},
        {"nativeTimeControlStatus", int(session->player.timeControlStatus)},
        {"nativeRateRestoring", prepared && rampProgress > 0 && rampProgress < 1},
        {"nativeRateRestored", prepared && rampProgress >= 1},
        {"nativeRateRestoreWrites", 0},
        {"nativeRateRestoreCueMs", prepared ? prepared->restoredAtMs() : -1.0},
        {"nativeRateRestoreProgress", rampProgress},
        {"nativeRenderedTempo", tempo},
        {"nativeTempoPrepared", prepared != nullptr},
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
