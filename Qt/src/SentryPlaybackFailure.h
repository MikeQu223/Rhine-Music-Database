#pragma once

#include <QJsonObject>
#include <QJsonValue>
#include <QRegularExpression>
#include <QString>
#include <QStringView>
#include <algorithm>
#include <array>
#include <cmath>

namespace RhineSentry {

enum class PlaybackFailureStage {
    Unknown,
    LocalFileAccess,
    ProviderRequest,
    MissingSource,
    MediaLoad,
    Transport,
    Decode,
    Output,
    NativeBackend,
    PlaybackState
};

struct PlaybackFailure {
    PlaybackFailureStage stage = PlaybackFailureStage::Unknown;
    QString code = QStringLiteral("unknown");
    bool recoverable = false;
    int recoveryAttempt = 0;
    bool localSource = false;
    bool trial = false;
    qint64 attemptElapsedMs = -1;
    QJsonObject details;
};

inline QString playbackFailureStageName(PlaybackFailureStage stage) {
    switch (stage) {
    case PlaybackFailureStage::LocalFileAccess:
        return QStringLiteral("local_file_access");
    case PlaybackFailureStage::ProviderRequest:
        return QStringLiteral("provider_request");
    case PlaybackFailureStage::MissingSource:
        return QStringLiteral("missing_source");
    case PlaybackFailureStage::MediaLoad:
        return QStringLiteral("media_load");
    case PlaybackFailureStage::Transport:
        return QStringLiteral("transport");
    case PlaybackFailureStage::Decode:
        return QStringLiteral("decode");
    case PlaybackFailureStage::Output:
        return QStringLiteral("output");
    case PlaybackFailureStage::NativeBackend:
        return QStringLiteral("native_backend");
    case PlaybackFailureStage::PlaybackState:
        return QStringLiteral("playback_state");
    case PlaybackFailureStage::Unknown:
        return QStringLiteral("unknown");
    }
    return QStringLiteral("unknown");
}

inline QString sanitizedPlaybackFailureCode(QStringView value) {
    static const QRegularExpression allowed(QStringLiteral(R"(^[a-z0-9._-]{1,80}$)"));
    const auto code = value.toString().toLower();
    return allowed.match(code).hasMatch() ? code : QStringLiteral("unknown");
}

inline PlaybackFailureStage playbackFailureStageForBackendCategory(int category) {
    switch (category) {
    case 1:
    case 2:
    case 3:
    case 8:
    case 11:
        return PlaybackFailureStage::Transport;
    case 4:
    case 5:
    case 9:
        return PlaybackFailureStage::Decode;
    case 6:
        return PlaybackFailureStage::Output;
    case 7:
    case 10:
        return PlaybackFailureStage::MediaLoad;
    default:
        return PlaybackFailureStage::PlaybackState;
    }
}

inline QString playbackFailureCodeForBackendCategory(int category) {
    static const std::array<const char *, 12> codes{
        "playback_state_error", "timeout",         "dns_failure",      "connection_reset",
        "invalid_media_data",   "decoder_error",   "output_failure",   "access_denied",
        "tls_failure",          "truncated_media", "source_not_found", "http_error",
    };
    const auto index = std::clamp(category, 0, int(codes.size()) - 1);
    return QString::fromLatin1(codes[static_cast<size_t>(index)]);
}

inline QString playbackSourceKindName(int sourceKind) {
    switch (sourceKind) {
    case 1:
        return QStringLiteral("https");
    case 2:
        return QStringLiteral("http");
    case 3:
        return QStringLiteral("local");
    default:
        return QStringLiteral("unknown");
    }
}

inline void appendSafeFailureString(QJsonObject &result, const QJsonObject &source, const QString &key) {
    static const QRegularExpression allowed(QStringLiteral(R"(^[a-z0-9._-]{1,80}$)"));
    const auto value = source.value(key);
    if (value.isString() && allowed.match(value.toString()).hasMatch()) {
        result.insert(key, value.toString());
    }
}

inline void appendSafeFailureNumber(QJsonObject &result, const QJsonObject &source, const QString &key) {
    const auto value = source.value(key);
    if (value.isDouble() && std::isfinite(value.toDouble()) && std::abs(value.toDouble()) <= 1e12) {
        result.insert(key, value);
    }
}

inline void appendSafeFailureBoolean(QJsonObject &result, const QJsonObject &source, const QString &key) {
    const auto value = source.value(key);
    if (value.isBool()) {
        result.insert(key, value);
    }
}

inline QJsonObject sanitizedPlaybackFailureDetails(const QJsonObject &source, bool includeNested = true) {
    QJsonObject result;
    for (const auto &key :
         {"failureStage", "failureReason", "errorKey", "upstreamErrorKey", "sourceKind", "verification"}) {
        appendSafeFailureString(result, source, QLatin1String(key));
    }
    for (const auto &key : {"code", "retryAfterMs", "upstreamHttpStatus", "upstreamCode",
                            "upstreamGlobalCode", "upstreamSubCode", "errorCode", "backendFailureCategory",
                            "httpStatus", "reportedHttpStatus", "attemptElapsedMs", "mediaStatus"}) {
        appendSafeFailureNumber(result, source, QLatin1String(key));
    }
    for (const auto &key :
         {"retryable", "writeAttempted", "authExpired", "localSource", "trial", "recoverable"}) {
        appendSafeFailureBoolean(result, source, QLatin1String(key));
    }
    static const QRegularExpression attemptId(
        QStringLiteral(R"(^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$)"));
    const auto attempt = source.value(QStringLiteral("attemptId")).toString();
    if (attemptId.match(attempt).hasMatch()) {
        result.insert(QStringLiteral("attemptId"), attempt);
    }
    if (includeNested) {
        for (const auto &key : {"lastFailure", "primaryFailure"}) {
            const auto nested = source.value(QLatin1String(key));
            if (nested.isObject()) {
                const auto safeNested = sanitizedPlaybackFailureDetails(nested.toObject(), false);
                if (!safeNested.isEmpty()) {
                    result.insert(QLatin1String(key), safeNested);
                }
            }
        }
    }
    return result;
}

inline QJsonObject playbackFailureContext(const PlaybackFailure &failure) {
    auto result = sanitizedPlaybackFailureDetails(failure.details);
    result.insert(QStringLiteral("stage"), playbackFailureStageName(failure.stage));
    result.insert(QStringLiteral("code"), sanitizedPlaybackFailureCode(failure.code));
    result.insert(QStringLiteral("recoverable"), failure.recoverable);
    result.insert(QStringLiteral("recoveryAttempt"), std::max(0, failure.recoveryAttempt));
    result.insert(QStringLiteral("localSource"), failure.localSource);
    result.insert(QStringLiteral("trial"), failure.trial);
    if (failure.attemptElapsedMs >= 0) {
        result.insert(QStringLiteral("attemptElapsedMs"), double(failure.attemptElapsedMs));
    }
    return result;
}

}
