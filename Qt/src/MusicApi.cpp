#include "MusicApi.h"
#include "ProviderRegistry.h"
#include <QJsonDocument>
#include <QPointer>
#include <QRegularExpression>
#include <cmath>

MusicApi::MusicApi(Host *host, QObject *parent) : QObject(parent), m_host(host) {
}

QString MusicApi::providerName(const QString &provider) {
    const auto name = ProviderRegistry::instance().name(provider);
    return name.isEmpty() ? provider : name;
}

QJsonObject MusicApi::safeFailure(const QJsonObject &body, bool includePrevious) {
    QJsonObject result;
    static const QRegularExpression diagnostic(QStringLiteral("^[a-z.-]{1,80}$"));
    for (const auto &name : {"failureStage", "failureReason", "errorKey", "upstreamErrorKey"}) {
        if (body[name].isString() && diagnostic.match(body[name].toString()).hasMatch()) {
            result[name] = body[name];
        }
    }
    for (const auto &name : {"code", "retryAfterMs", "upstreamHttpStatus", "upstreamCode",
                             "upstreamGlobalCode", "upstreamSubCode"}) {
        if (body[name].isDouble() && std::isfinite(body[name].toDouble())) {
            result[name] = body[name];
        }
    }
    if (includePrevious && body["lastFailure"].isObject()) {
        result["lastFailure"] = safeFailure(body["lastFailure"].toObject(), false);
    }
    if (includePrevious && body["primaryFailure"].isObject()) {
        result["primaryFailure"] = safeFailure(body["primaryFailure"].toObject(), false);
    }
    for (const auto &name : {"retryable", "writeAttempted"}) {
        if (body[name].isBool()) {
            result[name] = body[name];
        }
    }
    if (body["verification"] == "unconfirmed") {
        result["verification"] = "unconfirmed";
    }
    if (body["authExpired"].toBool()) {
        result["authExpired"] = true;
    }
    return result;
}

/** SDK 数据适配运行在 Node 内；原生业务只接收 Qt JSON 值，不创建脚本值或 Promise。 */
void MusicApi::call(QString operation, QJsonArray arguments, Reply callback, Valid valid) {
    if (provider == "local") {
        if (valid()) {
            callback({{}, QStringLiteral("本地模式不提供在线平台操作"), {}});
        }
        return;
    }
    send("/native/" + provider + "/" + operation, {{"args", arguments}}, true, std::move(callback),
         std::move(valid), {200});
}

/**
 * 接收私有 IPC 响应，先验证业务代数与接收对象寿命，再校验状态并接收 Cookie。
 * 换账号、切歌或关闭窗口后的迟到响应不能修改原生业务状态或凭据。
 */
void MusicApi::send(QString route, QJsonObject parameters, bool adapted, Reply callback, Valid valid,
                    QSet<int> allowed) {
    QPointer<MusicApi> owner(this);
    const auto source = provider;
    m_host->requestJson(
        route, parameters,
        [owner, source, adapted, callback = std::move(callback), valid = std::move(valid),
         allowed](QJsonObject response, QString error) {
            if (!owner || !valid()) {
                return;
            }
            if (!error.isEmpty()) {
                callback({{}, error, {}});
                return;
            }
            if (!response["body"].isObject()) {
                callback({{}, QStringLiteral("元数据格式无效"), {}});
                return;
            }
            const auto body = response["body"].toObject();
            const auto code = body["code"].toInt(200);
            if (!allowed.contains(code)) {
                auto message = body["message"].toString(body["msg"].toString("请稍后重试"));
                if (!adapted) {
                    message = providerName(source) + "返回 " + QString::number(code) + "：" + message;
                }
                auto failure = safeFailure(body);
                if (response["authExpired"].toBool()) {
                    failure["authExpired"] = true;
                }
                callback({{}, message, failure});
                return;
            }
            owner->m_host->acceptCookies(
                QString::fromUtf8(
                    QJsonDocument(response["cookies"].toArray()).toJson(QJsonDocument::Compact)),
                response["_epoch"].toInt(), response["_credentialKey"].toString(), source);
            callback({adapted ? body["value"] : QJsonValue(body), {}, {}});
        });
}
