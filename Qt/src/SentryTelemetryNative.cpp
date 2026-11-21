#include "SentryTelemetryPlatform.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <sentry.h>
#include <cstring>

namespace RhineSentry::Platform {
namespace {

/** Qt 日志仍留在本机。只允许应用显式生成的语义记录进入 Breadcrumbs。 */
sentry_value_t filterBreadcrumb(sentry_value_t crumb, void *) {
    const auto category = sentry_value_as_string(sentry_value_get_by_key(crumb, "category"));
    const auto type = sentry_value_as_string(sentry_value_get_by_key(crumb, "type"));
    if (type && std::strcmp(type, "user") == 0 &&
        category && (std::strcmp(category, "rhine.page") == 0 ||
                     std::strcmp(category, "rhine.action") == 0 ||
                     std::strcmp(category, "rhine.playback") == 0 ||
                     std::strcmp(category, "rhine.lifecycle") == 0)) {
        return crumb;
    }
    sentry_value_decref(crumb);
    return sentry_value_new_null();
}

void identifyUser(sentry_scope_t *scope, void *data) {
    const auto &id = *static_cast<const QByteArray *>(data);
    auto user = sentry_value_new_object();
    sentry_value_set_by_key(user, "id", sentry_value_new_string(id.constData()));
    sentry_scope_set_user(scope, user);
}

sentry_value_t filterTelemetryIdentity(sentry_value_t item, void *) {
    auto attributes = sentry_value_get_by_key(item, "attributes");
    if (!sentry_value_is_null(attributes)) {
        sentry_value_remove_by_key(attributes, "user.id");
    }
    return item;
}

sentry_value_t attributes(const char *category, const char *name) {
    auto values = sentry_value_new_object();
    sentry_value_set_by_key(values, "rhine.category",
                            sentry_value_new_attribute(sentry_value_new_string(category), nullptr));
    sentry_value_set_by_key(values, "rhine.name",
                            sentry_value_new_attribute(sentry_value_new_string(name), nullptr));
    return values;
}
}

bool start(const Config &config) {
    QDir binaries(QCoreApplication::applicationDirPath());
#ifdef Q_OS_WIN
    const auto handler = binaries.filePath(QStringLiteral("sentry-crash.exe"));
#else
    if (config.role == QStringLiteral("playback-service")) {
        binaries.cd(QStringLiteral("../../../../MacOS"));
    }
    const auto handler = binaries.filePath(QStringLiteral("sentry-crash"));
#endif
    if (!QFileInfo(handler).isExecutable()) {
        return false;
    }

    auto *options = sentry_options_new();
    sentry_options_set_dsn(options, config.dsn.toUtf8().constData());
    sentry_options_set_environment(options, config.environment.toUtf8().constData());
    sentry_options_set_release(options, config.release.toUtf8().constData());
    sentry_options_set_dist(options, config.version.toUtf8().constData());
#ifdef Q_OS_WIN
    sentry_options_set_handler_pathw(options, handler.toStdWString().c_str());
    sentry_options_set_database_pathw(options, config.databaseDirectory.toStdWString().c_str());
#else
    sentry_options_set_handler_path(options, QFile::encodeName(handler).constData());
    sentry_options_set_database_path(options, QFile::encodeName(config.databaseDirectory).constData());
#endif
    sentry_options_set_require_user_consent(options, 1);
    sentry_options_set_traces_sample_rate(options, config.tracesSampleRate);
    sentry_options_set_auto_session_tracking(options, config.role == QStringLiteral("interface"));
    sentry_options_set_max_breadcrumbs(options, 40);
    sentry_options_set_cache_keep(options, SENTRY_CACHE_KEEP_NONE);
    sentry_options_set_http_retry(options, 0);
    // Native 崩溃进程也使用此超时，须给首次 HTTPS 请求及其退出留出时间。
    sentry_options_set_shutdown_timeout(options, 5000);
    sentry_options_set_transfer_timeout(options, 4000);
    sentry_options_set_crash_upload_mode(options, SENTRY_CRASH_UPLOAD_MODE_ASYNC);
    sentry_options_set_crash_reporting_mode(options, SENTRY_CRASH_REPORTING_MODE_NATIVE);
    sentry_options_set_thread_stackwalk_mode(options, SENTRY_THREAD_STACKWALK_MODE_CRASHED_ONLY);
    sentry_options_set_before_breadcrumb(options, filterBreadcrumb, nullptr);
    sentry_options_set_before_send_log(options, filterTelemetryIdentity, nullptr);
    sentry_options_set_before_send_metric(options, filterTelemetryIdentity, nullptr);
    auto userId = config.userId.toUtf8();
    sentry_options_set_initial_scope(options, identifyUser, &userId);
    if (sentry_init(options) != 0) {
        return false;
    }
    const auto role = config.role.toUtf8();
    sentry_set_tag("rhine.process", role.constData());
    sentry_set_attribute("rhine.process", sentry_value_new_attribute(sentry_value_new_string(role.constData()), nullptr));
    sentry_user_consent_give();
    return true;
}

void stop(bool revoked) {
    if (revoked) {
        sentry_user_consent_revoke();
    }
    sentry_close();
}

void record(const char *category, const char *name) {
    const auto qualifiedCategory = QByteArrayLiteral("rhine.") + category;
    auto crumb = sentry_value_new_breadcrumb("user", name);
    sentry_value_set_by_key(crumb, "category", sentry_value_new_string(qualifiedCategory.constData()));
    sentry_add_breadcrumb(crumb);
    sentry_log(SENTRY_LEVEL_INFO, name, attributes(category, name));
}

void failure() {
    sentry_log(SENTRY_LEVEL_ERROR, "playback_failed", attributes("playback", "failure"));
    auto event = sentry_value_new_event();
    auto exception = sentry_value_new_exception("RhinePlaybackError", "Playback failed");
    auto mechanism = sentry_value_new_object();
    sentry_value_set_by_key(mechanism, "type", sentry_value_new_string("generic"));
    sentry_value_set_by_key(mechanism, "handled", sentry_value_new_bool(true));
    sentry_value_set_by_key(exception, "mechanism", mechanism);
    sentry_value_set_stacktrace(exception, nullptr, 0);
    sentry_event_set_level(event, SENTRY_LEVEL_ERROR);
    sentry_event_add_exception(event, exception);
    sentry_capture_event(event);
}

void startup(qint64 milliseconds) {
    sentry_metrics_distribution("rhine.startup.ready", milliseconds, SENTRY_UNIT_MILLISECOND,
                                sentry_value_new_null());
}

void *beginTrace(const char *name, const char *operation) {
    return sentry_transaction_start(sentry_transaction_context_new(name, operation), sentry_value_new_null());
}

void finishTrace(void *trace, bool completed, bool successful) {
    auto *transaction = static_cast<sentry_transaction_t *>(trace);
    if (!transaction) {
        return;
    }
    if (!completed) {
        sentry_transaction_discard(transaction);
        return;
    }
    sentry_transaction_set_status(transaction, successful ? SENTRY_SPAN_STATUS_OK : SENTRY_SPAN_STATUS_INTERNAL_ERROR);
    sentry_transaction_finish(transaction);
}

void setContext(const char *key, const QJsonObject &value) {
    const auto json = QJsonDocument(value).toJson(QJsonDocument::Compact);
    sentry_set_context(key, sentry_value_from_json(json.constData(), json.size()));
}

}
