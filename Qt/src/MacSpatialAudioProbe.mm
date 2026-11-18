#include "Host.h"

#import <AVFoundation/AVFoundation.h>

#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QTimer>
#include <cmath>

/** 在正式 macOS helper 内播放本地样本，以便在控制中心验证系统空间化。 */
int runMacSpatialAudioProbe(const QString &filePath) {
    const QFileInfo file(filePath);
    if (!file.isFile() || !file.isReadable()) {
        qWarning("空间化探针需要可读的本地立体声文件。");
        return 2;
    }

    NSURL *url = [NSURL fileURLWithPath:file.absoluteFilePath().toNSString()];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    item.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMonoAndStereo;
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
    id endObserver = [notifications addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                object:item
                                                 queue:mainQueue
                                            usingBlock:^(NSNotification *) {
                                              QCoreApplication::exit(0);
                                            }];
    id errorObserver = [notifications addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:item
                                                   queue:mainQueue
                                              usingBlock:^(NSNotification *) {
                                                qWarning("空间化探针播放中断。");
                                                QCoreApplication::exit(1);
                                              }];

    constexpr int progressCheckMs = 250;
    constexpr int stallTimeoutMs = 10000;
    constexpr int probeDurationMs = 60000;
    QElapsedTimer progressClock;
    progressClock.start();
    double lastPositionSeconds = 0;
    QTimer progress;
    QObject::connect(&progress, &QTimer::timeout, &progress, [&] {
        if (item.status == AVPlayerItemStatusFailed || player.status == AVPlayerStatusFailed) {
            qWarning("AVPlayer 无法打开空间化探针样本。");
            QCoreApplication::exit(1);
            return;
        }
        const double positionSeconds = CMTimeGetSeconds(player.currentTime);
        if (std::isfinite(positionSeconds) && positionSeconds > lastPositionSeconds) {
            if (lastPositionSeconds == 0) {
                qInfo("AVPlayer 时钟已开始推进，请在 macOS 控制中心验证空间化立体声。");
            }
            lastPositionSeconds = positionSeconds;
            progressClock.restart();
            const double durationSeconds = CMTimeGetSeconds(item.duration);
            if (std::isfinite(durationSeconds) && durationSeconds > 0) {
                const QVariantMap state{
                    {"duration", durationSeconds * 1000},
                    {"position", positionSeconds * 1000},
                    {"playing", true},
                };
                platformMediaInfo(QStringLiteral("Rhine · 空间化立体声测试"), {}, {}, state);
            }
        } else if (progressClock.elapsed() >= stallTimeoutMs) {
            qWarning("空间化探针播放时钟超时。");
            QCoreApplication::exit(1);
        }
    });
    progress.start(progressCheckMs);
    QTimer::singleShot(probeDurationMs, &progress,
                       [&] { QCoreApplication::exit(lastPositionSeconds > 0 ? 0 : 1); });
    [player play];
    const int result = QCoreApplication::exec();

    progress.stop();
    [notifications removeObserver:endObserver];
    [notifications removeObserver:errorObserver];
    [player pause];
    platformMediaInfo({}, {}, {}, {});
    return result;
}
