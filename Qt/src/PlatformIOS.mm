#include "AppIdentity.h"
#include "Host.h"
#include <QFileInfo>
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

namespace {
static NSString *const credentialAccount = @"credentials";
NSDictionary *credentialQuery() {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : QString::fromLatin1(AppIdentity::Id).toNSString(),
        (__bridge id)kSecAttrAccount : credentialAccount
    };
}
// 旧版本按平台账户名保存；升级后枚举本应用服务下的条目，迁到统一账户并删除旧项。
NSData *migrateLegacyCredential() {
    NSDictionary *query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : QString::fromLatin1(AppIdentity::Id).toNSString(),
        (__bridge id)kSecReturnData : @YES,
        (__bridge id)kSecReturnAttributes : @YES,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll
    };
    CFTypeRef result = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) {
        return nil;
    }
    for (NSDictionary *item in CFBridgingRelease(result)) {
        NSString *account = item[(__bridge id)kSecAttrAccount];
        NSData *data = item[(__bridge id)kSecValueData];
        if (!data || [account isEqualToString:credentialAccount]) {
            continue;
        }
        NSMutableDictionary *insert = [credentialQuery() mutableCopy];
        insert[(__bridge id)kSecValueData] = data;
        insert[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        if (SecItemAdd((__bridge CFDictionaryRef)insert, nullptr) == errSecSuccess) {
            NSDictionary *remove = @{
                (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService : QString::fromLatin1(AppIdentity::Id).toNSString(),
                (__bridge id)kSecAttrAccount : account
            };
            SecItemDelete((__bridge CFDictionaryRef)remove);
            return data;
        }
    }
    return nil;
}
NSMutableArray *mediaTargets;
NSMutableArray *audioObservers;

// 系统媒体控件封面
MPMediaItemArtwork *mediaArtwork(const QString &coverPath) {
    static QString cachedPath;
    static QDateTime cachedModified;
    static MPMediaItemArtwork *cachedArtwork = nil;
    if (coverPath.isEmpty()) {
        cachedPath.clear();
        cachedArtwork = nil;
        return nil;
    }
    const QFileInfo info(coverPath);
    if (!info.exists()) {
        return nil;
    }
    if (coverPath == cachedPath && info.lastModified() == cachedModified) {
        return cachedArtwork;
    }
    UIImage *image = [UIImage imageWithContentsOfFile:coverPath.toNSString()];
    if (!image) {
        return nil;
    }
    cachedArtwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                                    requestHandler:^UIImage *(CGSize size) {
                                                        return image;
                                                    }];
    cachedPath = coverPath;
    cachedModified = info.lastModified();
    return cachedArtwork;
}
}

QByteArray platformCredential() {
    NSMutableDictionary *query = [credentialQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) {
        NSData *legacy = migrateLegacyCredential();
        return legacy ? QByteArray(static_cast<const char *>(legacy.bytes), legacy.length) : QByteArray();
    }
    NSData *bytes = CFBridgingRelease(result);
    return QByteArray(static_cast<const char *>(bytes.bytes), bytes.length);
}
QString platformSaveCredential(const QByteArray &bytes) {
    NSData *data = [NSData dataWithBytes:bytes.constData() length:bytes.size()];
    auto status = SecItemUpdate((__bridge CFDictionaryRef)credentialQuery(),
                                (__bridge CFDictionaryRef) @{(__bridge id)kSecValueData : data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *query = [credentialQuery() mutableCopy];
        query[(__bridge id)kSecValueData] = data;
        // 锁屏自动下一首仍可能更新凭据，首次解锁后允许访问当前设备的钥匙串。
        query[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)query, nullptr);
    }
    return status == errSecSuccess ? QString() : QStringLiteral("登录成功，但钥匙串当前不可写");
}
void platformDeleteCredential() {
    SecItemDelete((__bridge CFDictionaryRef)credentialQuery());
}
void platformPlay(const QString &, const QJsonObject &, bool, std::function<void(QString)> done) {
    done(QStringLiteral("iOS 仅支持面板内播放"));
}

/** 注册锁屏媒体操作和音频中断；销毁 Host 时移除全部目标，避免悬空回调。 */
void platformMediaCommands(std::function<void(QString)> callback) {
    auto center = [MPRemoteCommandCenter sharedCommandCenter];
    NSArray<MPRemoteCommand *> *commands = @[
        center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand,
        center.previousTrackCommand
    ];
    for (NSUInteger index = 0; index < mediaTargets.count; ++index) {
        [commands[index] removeTarget:mediaTargets[index]];
    }
    for (id observer in audioObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    mediaTargets = [NSMutableArray array];
    audioObservers = [NSMutableArray array];
    const QStringList actions{"resume", "pause", "toggle", "next", "prev"};
    for (NSUInteger index = 0; index < commands.count; ++index) {
        commands[index].enabled = bool(callback);
        if (callback) {
            const auto action = actions[index];
            id target =
                [commands[index] addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                  callback(action);
                  return MPRemoteCommandHandlerStatusSuccess;
                }];
            [mediaTargets addObject:target];
        }
    }
    if (!callback) {
        return;
    }
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error) {
        qWarning("Unable to configure iOS audio session: %ld", long(error.code));
    }
    auto notifications = [NSNotificationCenter defaultCenter];
    id interruption = [notifications
        addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *notification) {
                  const auto type =
                      [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                  if (type == AVAudioSessionInterruptionTypeBegan) {
                      callback("pause");
                  }
                  // 中断结束后的恢复由用户或 Qt 设备恢复处理，避免恢复手动暂停的歌曲。
                }];
    [audioObservers addObject:interruption];
    id route = [notifications
        addObserverForName:AVAudioSessionRouteChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *notification) {
                  const auto reason =
                      [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
                  if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
                      callback("pause");
                  }
                }];
    [audioObservers addObject:route];
}
void platformMediaInfo(QString title, QString artist, QString album, QVariantMap state,
                       const QString &coverPath) {
    auto center = [MPNowPlayingInfoCenter defaultCenter];
    if (title.isEmpty() || state.value("duration").toLongLong() <= 0) {
        center.nowPlayingInfo = nil;
        return;
    }
    const auto playing = state.value("playing").toBool();
    if (playing) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (error) {
            qWarning("Unable to activate iOS audio session: %ld", long(error.code));
        }
    }
    NSMutableDictionary *info = [@{
        MPMediaItemPropertyTitle : title.toNSString(),
        MPMediaItemPropertyArtist : artist.toNSString(),
        MPMediaItemPropertyAlbumTitle : album.toNSString(),
        MPMediaItemPropertyPlaybackDuration : @(state.value("duration").toDouble() / 1000.),
        MPNowPlayingInfoPropertyElapsedPlaybackTime : @(state.value("position").toDouble() / 1000.),
        MPNowPlayingInfoPropertyPlaybackRate : @(playing ? 1. : 0.)
    } mutableCopy];
    if (MPMediaItemArtwork *artwork = mediaArtwork(coverPath)) {
        info[MPMediaItemPropertyArtwork] = artwork;
    }
    center.nowPlayingInfo = info;
}
