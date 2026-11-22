#include "SentryTelemetryPlatform.h"

#include <QJsonDocument>
#include <atomic>
#include <mutex>
#import <SentryObjC/SentryObjC.h>

namespace RhineSentry::Platform {
namespace {
NSURLSession *transportSession = nil;
std::atomic_bool discardReports = false;
std::atomic_bool eventTracingEnabled = false;
std::mutex eventMutex;
NSString *processName = nil;
NSString *userId = nil;

NSDictionary<NSString *, id> *attributes(NSString *category, NSString *name,
                                         NSDictionary<NSString *, id> *extra = nil) {
    NSMutableDictionary<NSString *, id> *result = [@{
        @"rhine.category" : category,
        @"rhine.name" : name,
        @"rhine.process" : processName
    } mutableCopy];
    if (extra) {
        [result addEntriesFromDictionary:extra];
    }
    return result;
}

NSString *safePlaybackFailureStage(NSString *stage) {
    static NSSet<NSString *> *allowedStages =
        [NSSet setWithObjects:@"local_file_access", @"provider_request", @"missing_source",
                              @"media_load", @"transport", @"decode", @"output", @"native_backend",
                              @"playback_state", @"unknown", nil];
    if (stage && [allowedStages containsObject:stage]) {
        return stage;
    }
    return @"unknown";
}

NSString *safePluginInstallToken(NSString *value, NSSet<NSString *> *allowed) {
    if (value && [allowed containsObject:value]) {
        return value;
    }
    return @"unknown";
}

SentryObjCEvent *filterEvent(SentryObjCEvent *event, NSString *userId) {
    if (discardReports.load(std::memory_order_relaxed)) {
        return nil;
    }
    event.request = nil;
    event.user = [[SentryObjCUser alloc] initWithUserId:userId];
    event.extra = nil;
    event.serverName = nil;
    event.message = nil;
    // 原生异常原因可能带入路径、HTTP 错误正文或用户输入，只保留异常类型与堆栈。
    for (SentryObjCException *exception in event.exceptions) {
        const bool isPlaybackFailure = [exception.type isEqualToString:@"RhinePlaybackError"];
        const bool isPluginInstallFailure = [exception.type isEqualToString:@"RhinePluginInstallError"];
        if (isPlaybackFailure) {
            // 播放失败正文只能由受控 stage 重建，不能信任第三方或系统异常正文。
            NSString *stage = safePlaybackFailureStage(event.tags[@"rhine.playback.stage"]);
            exception.value = [@"Playback failed at " stringByAppendingString:stage];
        } else if (isPluginInstallFailure) {
            static NSSet<NSString *> *phases =
                [NSSet setWithObjects:@"package_received", @"validation", @"compatibility", @"staging",
                                      @"activation", @"rollback", @"unknown", nil];
            NSString *phase = safePluginInstallToken(event.tags[@"rhine.plugin.install.phase"], phases);
            NSString *code = event.tags[@"rhine.plugin.install.code"] ?: @"unknown";
            exception.value =
                [NSString stringWithFormat:@"Plugin installation failed at %@: %@", phase, code];
        } else {
            exception.value = @"Native exception";
        }
        exception.mechanism.data = nil;
    }
    return event;
}
}

bool start(const Config &config) {
    discardReports.store(false, std::memory_order_relaxed);
    eventTracingEnabled.store(config.tracesSampleRate > 0.0, std::memory_order_relaxed);
    NSURLSessionConfiguration *transport = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    transport.HTTPCookieStorage = nil;
    transport.HTTPShouldSetCookies = NO;
    transport.URLCredentialStorage = nil;
    transport.timeoutIntervalForRequest = 5;
    transportSession = [NSURLSession sessionWithConfiguration:transport];
    processName = config.role.toNSString();
    userId = config.userId.toNSString();
    [SentryObjCSDK startWithConfigureOptions:^(SentryObjCOptions *options) {
        options.dsn = config.dsn.toNSString();
        options.environment = config.environment.toNSString();
        options.releaseName = config.release.toNSString();
        options.dist = config.version.toNSString();
        options.cacheDirectoryPath = config.databaseDirectory.toNSString();
        options.urlSession = transportSession;
        options.shutdownTimeInterval = 0.5;
        options.sendDefaultPii = NO;
        options.enableCrashHandler = YES;
        options.attachStacktrace = YES;
        options.enableMemoryIntrospection = NO;
        options.enableAutoSessionTracking = YES;
        options.enableLogs = YES;
        options.enableMetrics = YES;
        options.maxBreadcrumbs = 40;
        options.maxCacheItems = 30;
        // 产品页面与操作由 HUD 显式上报，避免 SDK 捕获输入、请求、文件名或视图。
        options.enableSwizzling = NO;
        options.enableAutoBreadcrumbTracking = NO;
        options.enableNetworkBreadcrumbs = NO;
        options.enableCaptureFailedRequests = NO;
        options.tracesSampleRate = @(config.tracesSampleRate);
        options.enableAutoPerformanceTracing = NO;
        options.enableNetworkTracking = NO;
        options.tracePropagationTargets = @[];
        options.enableAppHangTracking = NO;
        options.enableWatchdogTerminationTracking = NO;
        options.attachScreenshot = NO;
        options.attachViewHierarchy = NO;
        options.sessionReplay.sessionSampleRate = 0;
        options.sessionReplay.onErrorSampleRate = 0;
        options.beforeSend = ^SentryObjCEvent *(SentryObjCEvent *event) {
            return filterEvent(event, userId);
        };
        options.beforeSendMetric = ^SentryObjCMetric *(SentryObjCMetric *metric) {
            auto *attributes = [metric.attributes mutableCopy];
            [attributes removeObjectForKey:@"user.id"];
            metric.attributes = attributes;
            return metric;
        };
        options.initialScope = ^SentryObjCScope *(SentryObjCScope *scope) {
            [scope setUser:[[SentryObjCUser alloc] initWithUserId:userId]];
            [scope setTagValue:processName forKey:@"rhine.process"];
            [scope setAttributeValue:processName forKey:@"rhine.process"];
            return scope;
        };
    }];
    if (!SentryObjCSDK.isEnabled) {
        stop(true);
        return false;
    }
    return true;
}

void stop(bool revoked) {
    std::lock_guard<std::mutex> lock(eventMutex);
    if (revoked) {
        // 先取消专用会话的待发和在途请求，再让 SDK 关闭 crash handler 及缓存。
        discardReports.store(true, std::memory_order_relaxed);
        [transportSession invalidateAndCancel];
    }
    [SentryObjCSDK close];
    if (!revoked) {
        [transportSession finishTasksAndInvalidate];
    }
    transportSession = nil;
}

void record(const char *category, const char *name) {
    NSString *categoryName = [NSString stringWithUTF8String:category];
    NSString *eventName = [NSString stringWithUTF8String:name];
    auto *crumb = [[SentryObjCBreadcrumb alloc] initWithLevel:SentryObjCLevelInfo
                                                     category:[@"rhine." stringByAppendingString:categoryName]];
    crumb.message = eventName;
    [SentryObjCSDK addBreadcrumb:crumb];

    // 普通语义日志只保留可搜索记录，不为每个操作制造独立 Trace。
    std::lock_guard<std::mutex> lock(eventMutex);
    [SentryObjCSDK.logger info:eventName attributes:attributes(categoryName, eventName)];
}

void failure(const QString &stage, const QString &code, const QJsonObject &details) {
    // 失败日志和异常事件共享同一条事件事务，
    // 保留用户、日志、Span 与错误之间的关联。
    std::lock_guard<std::mutex> lock(eventMutex);
    NSString *failureStage = stage.toNSString();
    NSString *failureCode = code.toNSString();
    SentryObjCSpan *transaction = nil;
    if (eventTracingEnabled.load(std::memory_order_relaxed)) {
        auto *context = [[SentryObjCTransactionContext alloc] initWithName:@"rhine.playback.failure"
                                                                 operation:@"rhine.playback"
                                                                   sampled:SentryObjCSampleDecisionYes
                                                                sampleRate:nil
                                                                sampleRand:nil];
        transaction = [SentryObjCSDK startTransactionWithContext:context bindToScope:YES];
        transaction.status = SentryObjCSpanStatusInternalError;
    }
    NSDictionary<NSString *, id> *failureAttributes = @{
        @"rhine.playback.stage" : failureStage,
        @"rhine.playback.code" : failureCode
    };
    [SentryObjCSDK.logger error:@"playback_failed"
                     attributes:attributes(@"playback", @"failure", failureAttributes)];
    auto *event = [[SentryObjCEvent alloc] initWithLevel:SentryObjCLevelError];
    NSString *failureMessage = [@"Playback failed at " stringByAppendingString:failureStage];
    auto *exception = [[SentryObjCException alloc] initWithValue:failureMessage type:@"RhinePlaybackError"];
    auto *mechanism = [[SentryObjCMechanism alloc] initWithType:@"generic"];
    mechanism.handled = @YES;
    exception.mechanism = mechanism;
    event.exceptions = @[exception];
    event.tags = @{
        @"rhine.playback.stage" : failureStage,
        @"rhine.playback.code" : failureCode
    };
    event.fingerprint = @[@"rhine.playback", failureStage, failureCode];
    const auto detailJson = QJsonDocument(details).toJson(QJsonDocument::Compact);
    NSData *detailData = [NSData dataWithBytes:detailJson.constData() length:detailJson.size()];
    NSDictionary<NSString *, id> *failureContext =
        [NSJSONSerialization JSONObjectWithData:detailData options:0 error:nil];
    event.context = @{@"rhine_playback_failure" : failureContext ?: @{}};
    [SentryObjCSDK captureEvent:event];
    if (transaction) {
        [transaction finish];
    }
}

void pluginInstallFailure(const QString &phase, const QString &code, const QJsonObject &details) {
    std::lock_guard<std::mutex> lock(eventMutex);
    NSString *installPhase = phase.toNSString();
    NSString *installCode = code.toNSString();
    SentryObjCSpan *transaction = nil;
    if (eventTracingEnabled.load(std::memory_order_relaxed)) {
        auto *context = [[SentryObjCTransactionContext alloc] initWithName:@"rhine.plugin.install.failure"
                                                                 operation:@"rhine.plugin.install"
                                                                   sampled:SentryObjCSampleDecisionYes
                                                                sampleRate:nil
                                                                sampleRand:nil];
        transaction = [SentryObjCSDK startTransactionWithContext:context bindToScope:YES];
        transaction.status = SentryObjCSpanStatusInternalError;
    }
    NSDictionary<NSString *, id> *failureAttributes = @{
        @"rhine.plugin.install.phase" : installPhase,
        @"rhine.plugin.install.code" : installCode
    };
    [SentryObjCSDK.logger error:@"plugin_install_failed"
                     attributes:attributes(@"plugin", @"install_failure", failureAttributes)];
    auto *event = [[SentryObjCEvent alloc] initWithLevel:SentryObjCLevelError];
    NSString *failureMessage =
        [NSString stringWithFormat:@"Plugin installation failed at %@: %@", installPhase, installCode];
    auto *exception =
        [[SentryObjCException alloc] initWithValue:failureMessage type:@"RhinePluginInstallError"];
    auto *mechanism = [[SentryObjCMechanism alloc] initWithType:@"generic"];
    mechanism.handled = @YES;
    exception.mechanism = mechanism;
    event.exceptions = @[exception];
    event.tags = @{
        @"rhine.plugin.install.phase" : installPhase,
        @"rhine.plugin.install.code" : installCode
    };
    event.fingerprint = @[@"rhine.plugin.install", installPhase, installCode];
    const auto detailJson = QJsonDocument(details).toJson(QJsonDocument::Compact);
    NSData *detailData = [NSData dataWithBytes:detailJson.constData() length:detailJson.size()];
    NSDictionary<NSString *, id> *installContext =
        [NSJSONSerialization JSONObjectWithData:detailData options:0 error:nil];
    event.context = @{@"rhine_plugin_install" : installContext ?: @{}};
    [SentryObjCSDK captureEvent:event];
    if (transaction) {
        [transaction finish];
    }
}

void startup(qint64 milliseconds) {
    auto *options = [[SentryObjCMetricOptions alloc] init];
    options.unit = SentryObjCUnit.millisecond;
    [SentryObjCSDK.metrics distribution:@"rhine.startup.ready" value:milliseconds options:options];
}

void *beginTrace(const char *name, const char *operation) {
    auto *transaction = [SentryObjCSDK startTransactionWithName:[NSString stringWithUTF8String:name]
                                                     operation:[NSString stringWithUTF8String:operation]
                                                   bindToScope:NO];
    return (__bridge_retained void *)transaction;
}

void finishTrace(void *trace, bool completed, bool successful) {
    auto *transaction = (__bridge_transfer SentryObjCSpan *)trace;
    if (completed) {
        [transaction finishWithStatus:successful ? SentryObjCSpanStatusOk : SentryObjCSpanStatusInternalError];
    }
}

void setContext(const char *key, const QJsonObject &value) {
    const auto json = QJsonDocument(value).toJson(QJsonDocument::Compact);
    NSData *data = [NSData dataWithBytes:json.constData() length:json.size()];
    NSDictionary *context = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
    if (context) {
        NSString *name = [NSString stringWithUTF8String:key];
        [SentryObjCSDK configureScope:^(SentryObjCScope *scope) {
            [scope setContextValue:context forKey:name];
        }];
    }
}

}
