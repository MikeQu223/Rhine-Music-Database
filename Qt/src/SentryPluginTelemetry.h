#pragma once

#include <QJsonObject>
#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <QStringView>
#include <algorithm>

namespace RhineSentry {

struct PluginInstallFailure {
    QString phase = QStringLiteral("unknown");
    QString code = QStringLiteral("unknown");
    QString format = QStringLiteral("unknown");
    QString sourceKind = QStringLiteral("unknown");
    QString conflictKind = QStringLiteral("unknown");
    QString rollbackResult = QStringLiteral("unknown");
    QString candidateVersion;
    QString existingVersion;
    int schemaVersion = 0;
    int apiVersion = 0;
    int fileCount = 0;
    qint64 packageBytes = 0;
    bool compatibilityPassed = false;
    bool existingPluginPreserved = false;
    bool retryable = false;
    bool upgrade = false;
};

inline QString sanitizedPluginInstallToken(QStringView value, const QStringList &allowed,
                                           QStringView fallback = u"unknown") {
    const auto token = value.toString();
    return allowed.contains(token) ? token : fallback.toString();
}

inline QString sanitizedPluginVersion(const QString &value) {
    static const QRegularExpression version(QStringLiteral(R"(^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$)"));
    return version.match(value).hasMatch() ? value : QString();
}

inline QJsonObject pluginInstallTelemetryContext(const PluginInstallFailure &failure) {
    static const QStringList phases{"package_received", "validation", "compatibility", "staging",
                                    "activation",       "rollback",   "unknown"};
    static const QStringList formats{"package", "directory", "marketplace", "unknown"};
    static const QStringList sources{"local_file", "local_directory", "marketplace", "backup", "unknown"};
    static const QStringList conflicts{"none",   "provider_id",   "provider_route",  "entrypoint",
                                       "schema", "compatibility", "market_identity", "unknown"};
    static const QStringList rollbacks{"not_needed", "completed", "failed", "unknown"};
    static const QRegularExpression code(QStringLiteral(R"(^[a-z0-9._-]{1,80}$)"));
    const auto safeCode = code.match(failure.code).hasMatch() ? failure.code : QStringLiteral("unknown");
    QJsonObject result{
        {QStringLiteral("phase"), sanitizedPluginInstallToken(failure.phase, phases)},
        {QStringLiteral("code"), safeCode},
        {QStringLiteral("format"), sanitizedPluginInstallToken(failure.format, formats)},
        {QStringLiteral("sourceKind"), sanitizedPluginInstallToken(failure.sourceKind, sources)},
        {QStringLiteral("conflictKind"), sanitizedPluginInstallToken(failure.conflictKind, conflicts)},
        {QStringLiteral("rollbackResult"), sanitizedPluginInstallToken(failure.rollbackResult, rollbacks)},
        {QStringLiteral("schemaVersion"), std::clamp(failure.schemaVersion, 0, 1000)},
        {QStringLiteral("apiVersion"), std::clamp(failure.apiVersion, 0, 1000)},
        {QStringLiteral("fileCount"), std::clamp(failure.fileCount, 0, 512)},
        {QStringLiteral("packageBytes"), double(std::clamp<qint64>(failure.packageBytes, 0, 300000000))},
        {QStringLiteral("compatibilityPassed"), failure.compatibilityPassed},
        {QStringLiteral("existingPluginPreserved"), failure.existingPluginPreserved},
        {QStringLiteral("retryable"), failure.retryable},
        {QStringLiteral("upgrade"), failure.upgrade},
    };
    const auto candidateVersion = sanitizedPluginVersion(failure.candidateVersion);
    if (!candidateVersion.isEmpty()) {
        result.insert(QStringLiteral("candidateVersion"), candidateVersion);
    }
    const auto existingVersion = sanitizedPluginVersion(failure.existingVersion);
    if (!existingVersion.isEmpty()) {
        result.insert(QStringLiteral("existingVersion"), existingVersion);
    }
    return result;
}

}
