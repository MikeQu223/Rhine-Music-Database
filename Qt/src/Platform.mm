#include "AppIdentity.h"
#include "Host.h"
#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>
#include <QCoreApplication>
#include <QMetaObject>
#import <Security/Security.h>
#include <QFileInfo>

static NSString *const credentialAccount = @"credentials";
static NSDictionary *credentialQuery() {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : QString::fromLatin1(AppIdentity::Id).toNSString(),
        (__bridge id)kSecAttrAccount : credentialAccount
    };
}
// 旧版本按平台账户名保存；升级后枚举本应用服务下的条目，迁到统一账户并删除旧项。
static NSData *migrateLegacyCredential() {
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
        insert[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
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
QByteArray platformCredential() {
    NSMutableDictionary *query = [credentialQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) {
        NSData *legacy = migrateLegacyCredential();
        return legacy ? QByteArray((const char *)legacy.bytes, legacy.length) : QByteArray();
    }
    NSData *data = CFBridgingRelease(result);
    return QByteArray((const char *)data.bytes, data.length);
}
QString platformSaveCredential(const QByteArray &bytes) {
    NSData *data = [NSData dataWithBytes:bytes.constData() length:bytes.size()];
    auto status = SecItemUpdate((__bridge CFDictionaryRef)credentialQuery(),
                                (__bridge CFDictionaryRef) @{(__bridge id)kSecValueData : data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [credentialQuery() mutableCopy];
        insert[(__bridge id)kSecValueData] = data;
        insert[(__bridge id)kSecAttrLabel] = QString::fromLatin1(AppIdentity::DisplayName).toNSString();
        insert[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)insert, nullptr);
    }
    return status == errSecSuccess ? QString() : QStringLiteral("登录成功，但钥匙串当前不可写");
}
void platformDeleteCredential() {
    SecItemDelete((__bridge CFDictionaryRef)credentialQuery());
}
bool platformActivates() {
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:QString::fromLatin1(AppIdentity::PlayerPreference).toNSString()];
}
void platformSetActivates(bool value) {
    [[NSUserDefaults standardUserDefaults]
        setBool:value
         forKey:QString::fromLatin1(AppIdentity::PlayerPreference).toNSString()];
}
void platformPlay(const QString &id, const QJsonObject &config, bool activate,
                  std::function<void(QString)> done) {
    const auto application = config["application"].toObject();
    NSURL *app = nil;
    const auto bundleId = application["bundleId"].toString();
    if (!bundleId.isEmpty()) {
        app = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleId.toNSString()];
        if (!app) {
            done(application["missingMessage"].toString(QStringLiteral("未安装官方客户端")));
            return;
        }
    }
    auto payload = config["payload"].toString();
    payload.replace("{id}", id);
    const auto encoding = config["encoding"].toString();
    QString encoded = payload;
    if (encoding == "base64") {
        encoded = QString::fromLatin1(payload.toUtf8().toBase64());
    } else if (encoding == "percent") {
        encoded = QString::fromLatin1(QUrl::toPercentEncoding(payload));
    }
    const auto scheme = config["scheme"].toString();
    NSURL *url = [NSURL URLWithString:(scheme + "://" + encoded).toNSString()];
    NSWorkspaceOpenConfiguration *openConfig = [NSWorkspaceOpenConfiguration configuration];
    openConfig.activates = activate;
    const auto successMessage =
        config["successMessage"].toString(QStringLiteral("已交给官方客户端"));
    const auto failureMessage = config["failureMessage"].toString(QStringLiteral("交付失败"));
    void (^completion)(NSRunningApplication *, NSError *) =
        ^(NSRunningApplication *, NSError *error) {
          const auto message = error ? failureMessage + "：" + QString::fromNSString(error.localizedDescription)
                                     : successMessage;
          QMetaObject::invokeMethod(
              QCoreApplication::instance(), [done, message] { done(message); }, Qt::QueuedConnection);
        };
    if (app) {
        [[NSWorkspace sharedWorkspace] openURLs:@[ url ]
                           withApplicationAtURL:app
                                  configuration:openConfig
                              completionHandler:completion];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:url configuration:openConfig completionHandler:completion];
    }
}

// Touch Bar 只在支持的机器上由 AppKit 呈现，普通屏幕不增加空白入口。
@interface RhineTouchControls : NSObject <NSTouchBarDelegate> {
  @public
    std::function<void(QString)> action;
}
- (void)previous:(id)sender;
- (void)toggle:(id)sender;
- (void)next:(id)sender;
@end
@implementation RhineTouchControls
- (void)previous:(id)sender {
    if (action) {
        action("prev");
    }
}
- (void)toggle:(id)sender {
    if (action) {
        action("toggle");
    }
}
- (void)next:(id)sender {
    if (action) {
        action("next");
    }
}
- (NSTouchBarItem *)touchBar:(NSTouchBar *)bar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    const BOOL previous = [identifier hasSuffix:@"previous"];
    const BOOL next = [identifier hasSuffix:@"next"];
    NSButton *button = [NSButton buttonWithTitle:previous ? @"◀"
                                                 : next   ? @"▶"
                                                          : @"播放 / 暂停"
                                          target:self
                                          action:previous ? @selector(previous:)
                                                 : next   ? @selector(next:)
                                                          : @selector(toggle:)];
    button.bezelColor = [NSColor colorWithRed:.47 green:.49 blue:.38 alpha:1];
    item.view = button;
    return item;
}
@end
static RhineTouchControls *touchControls;
static NSTouchBar *rhineTouchBar;
static bool isBackgroundService = false;
// 系统媒体按钮仅转发动作；队列和音源由播放核心维护。
static NSMutableArray *mediaTargets;
void platformInterfaceMediaCommands(std::function<void(QString)> callback) {
    if (!touchControls) {
        touchControls = [RhineTouchControls new];
    }
    touchControls->action = callback;
    if (!callback) {
        [NSApp mainWindow].touchBar = nil;
        rhineTouchBar = nil;
    }
}

void platformInterfaceMediaInfo(bool hasTrack) {
    if (hasTrack && touchControls && touchControls->action && !rhineTouchBar && [NSApp mainWindow]) {
        rhineTouchBar = [NSTouchBar new];
        rhineTouchBar.delegate = touchControls;
        rhineTouchBar.defaultItemIdentifiers =
            @[ @"rhine.music.previous", @"rhine.music.toggle", @"rhine.music.next" ];
        [NSApp mainWindow].touchBar = rhineTouchBar;
    }
}

void platformMediaCommands(std::function<void(QString)> callback) {
    if (!isBackgroundService) {
        platformInterfaceMediaCommands(callback);
    }
    auto center = [MPRemoteCommandCenter sharedCommandCenter];
    NSArray<MPRemoteCommand *> *commands = @[
        center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand,
        center.previousTrackCommand
    ];
    for (NSUInteger i = 0; i < mediaTargets.count; ++i) {
        [commands[i] removeTarget:mediaTargets[i]];
    }
    mediaTargets = [NSMutableArray array];
    QStringList actions{"resume", "pause", "toggle", "next", "prev"};
    for (NSUInteger i = 0; i < commands.count; ++i) {
        commands[i].enabled = bool(callback);
        if (callback) {
            const QString action = actions[i];
            id target =
                [commands[i] addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *) {
                  callback(action);
                  return MPRemoteCommandHandlerStatusSuccess;
                }];
            [mediaTargets addObject:target];
        }
    }
}
// 系统媒体控件封面
static MPMediaItemArtwork *mediaArtwork(const QString &coverPath) {
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
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:coverPath.toNSString()];
    if (!image) {
        return nil;
    }
    cachedArtwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                                    requestHandler:^NSImage *(CGSize size) {
                                                        return image;
                                                    }];
    cachedPath = coverPath;
    cachedModified = info.lastModified();
    return cachedArtwork;
}
void platformMediaInfo(QString title, QString artist, QString album, QVariantMap state,
                       const QString &coverPath) {
    if (!isBackgroundService) {
        platformInterfaceMediaInfo(!title.isEmpty());
    }
    auto center = [MPNowPlayingInfoCenter defaultCenter];
    if (title.isEmpty() || state.value("duration").toLongLong() <= 0) {
        center.nowPlayingInfo = nil;
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        return;
    }
    const bool playing = state.value("playing").toBool();
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
    center.playbackState = playing ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
}

/** 后台服务只显示菜单栏图标，避免形成第二个 Dock 应用窗口。 */
void platformBackgroundService() {
    isBackgroundService = true;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}
