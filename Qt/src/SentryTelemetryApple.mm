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

NSDictionary<NSString *, id> *attributes(NSString *category, NSString *name) {
    return @{
        @"rhine.category" : category,
        @"rhine.name" : name,
        @"rhine.process" : processName,
        @"user.id" : userId
    };
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
        exception.value = isPlaybackFailure ? @"Playback failed" : @"Native exception";
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

    // 每条语义日志使用独立事件事务；强制采样并绑定到日志，
    // 保证 Log 可跳转到对应 Trace 和 Span。
    std::lock_guard<std::mutex> lock(eventMutex);
    SentryObjCSpan *transaction = nil;
    if (eventTracingEnabled.load(std::memory_order_relaxed)) {
        NSString *traceName = [@"rhine." stringByAppendingFormat:@"%@.%@", categoryName, eventName];
        NSString *operation = [@"rhine." stringByAppendingString:categoryName];
        auto *context = [[SentryObjCTransactionContext alloc] initWithName:traceName
                                                                 operation:operation
                                                                   sampled:SentryObjCSampleDecisionYes
                                                                sampleRate:nil
                                                                sampleRand:nil];
        transaction = [SentryObjCSDK startTransactionWithContext:context bindToScope:YES];
    }
    [SentryObjCSDK.logger info:eventName attributes:attributes(categoryName, eventName)];
    if (transaction) {
        [transaction finishWithStatus:SentryObjCSpanStatusOk];
    }
}

void failure() {
    // 失败日志和异常事件共享同一条事件事务，
    // 保留用户、日志、Span 与错误之间的关联。
    std::lock_guard<std::mutex> lock(eventMutex);
    SentryObjCSpan *transaction = nil;
    if (eventTracingEnabled.load(std::memory_order_relaxed)) {
        auto *context = [[SentryObjCTransactionContext alloc] initWithName:@"rhine.playback.failure"
                                                                 operation:@"rhine.playback"
                                                                   sampled:SentryObjCSampleDecisionYes
                                                                sampleRate:nil
                                                                sampleRand:nil];
        transaction = [SentryObjCSDK startTransactionWithContext:context bindToScope:YES];
    }
    [SentryObjCSDK.logger error:@"playback_failed" attributes:attributes(@"playback", @"failure")];
    auto *event = [[SentryObjCEvent alloc] initWithLevel:SentryObjCLevelError];
    auto *exception = [[SentryObjCException alloc] initWithValue:@"Playback failed" type:@"RhinePlaybackError"];
    auto *mechanism = [[SentryObjCMechanism alloc] initWithType:@"generic"];
    mechanism.handled = @YES;
    exception.mechanism = mechanism;
    event.exceptions = @[exception];
    [SentryObjCSDK captureEvent:event];
    if (transaction) {
        [transaction finishWithStatus:SentryObjCSpanStatusInternalError];
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
