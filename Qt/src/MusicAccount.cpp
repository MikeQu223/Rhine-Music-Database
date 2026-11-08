#include "MusicLibrary.h"
#include "MusicDiscover.h"
#include "ProviderRegistry.h"
#include <QDateTime>
#include <QPointer>
#include <QRegularExpression>
#include <algorithm>

namespace {
QString loginFailureMessage(const QJsonObject &details) {
    const auto failure = details["lastFailure"].isObject() ? details["lastFailure"].toObject() : details;
    const auto primary = failure["primaryFailure"].toObject();
    const auto upstreamError = primary["upstreamErrorKey"].toString(failure["upstreamErrorKey"].toString());
    if (failure["upstreamCode"].toInt() == 20279 || primary["upstreamCode"].toInt() == 20279 ||
        upstreamError == "auth.device-limit") {
        return QStringLiteral("登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备");
    }
    if (primary["upstreamCode"].toInt() == 50006) {
        return QStringLiteral("请使用手机 QQ 扫描手机 QQ 通道二维码，再尝试登录");
    }
    if (upstreamError == "auth.rate-limited" || primary["upstreamCode"].toInt() == 104604 ||
        failure["upstreamCode"].toInt() == 104604) {
        return QStringLiteral("QQ 登录操作过于频繁，请等待冷却后重试");
    }
    const QHash<QString, QString> messages{
        {"auth.account-restricted", "账号当前受限，请在 QQ 音乐客户端检查"},
        {"auth.account-banned", "QQ 返回账号被封禁，请在官方客户端核实"},
        {"auth.account-binding", "账号绑定状态异常，请在 QQ 音乐客户端检查"},
    };
    if (messages.contains(upstreamError)) {
        return messages.value(upstreamError);
    }
    if (failure["failureReason"] == "qr-timeout") {
        return QStringLiteral("二维码已过期，请重新生成");
    }
    if (failure["failureReason"] == "user-canceled") {
        return QStringLiteral("已取消扫码登录");
    }
    if (failure["failureStage"] == "credential-validation") {
        return QStringLiteral("登录凭证验证失败，请重试或检查设备管理");
    }
    if (failure["failureStage"] == "credential-exchange") {
        return QStringLiteral("扫码授权交换失败，请重试或检查设备管理");
    }
    if (failure["failureStage"] == "mqtt-listener") {
        return QStringLiteral("扫码连接中断，请检查网络后重试");
    }
    if (failure["failureReason"] == "session-busy") {
        return QStringLiteral("扫码授权仍在处理中，请等待");
    }
    if (details["code"].toInt() == 429 || details["failureReason"] == "local-backoff") {
        return QStringLiteral("扫码登录暂时冷却");
    }
    if (details["code"].toInt() == 401) {
        return QStringLiteral("QQ 登录已失效，请重新扫码");
    }
    return details["code"].toInt() == 800 ? QStringLiteral("二维码会话已失效或登录失败，请重新生成")
                                          : QStringLiteral("扫码登录失败，请稍后重试");
}
}

void MusicLibrary::rememberIdentityName(QString source, QString name) {
    const auto normalized = name.trimmed();
    if (normalized.isEmpty()) {
        return;
    }
    identityNames[source] = normalized;
    const auto key = source == "kugou" ? accountKey() : source;
    host->setPreference("welcome-name-" + key, normalized);
    if (source == provider && !uid.isEmpty()) {
        host->setPreference("account-id-" + key, uid);
    }
}

void MusicLibrary::restoreIdentityName() {
    if (isLocal() || isSiren()) {
        return;
    }
    const auto identities = ProviderRegistry::instance()
                                .descriptor(provider)["library"]
                                .toObject()["identityProviders"]
                                .toArray();
    const auto source = identities.isEmpty() ? QString() : identities.at(0).toString();
    if (source.isEmpty() || !identityNames.value(source).isEmpty() || !host->hasCredential(source)) {
        return;
    }
    m_identityApi.provider = source;
    m_identityApi.call(
        "account", {},
        [this, source](MusicReply result) {
            if (result.ok()) {
                rememberIdentityName(source, result.value.toObject()["nickname"].toString());
                changed();
            }
        },
        valid(m_accountGeneration, &m_accountGeneration));
}

void MusicLibrary::restoreCachedAccount() {
    if (isLocal()) {
        uid.clear();
        nickname = QStringLiteral("本地音乐");
        return;
    }
    if (isSiren()) {
        uid.clear();
        nickname = QStringLiteral("本地收藏");
        return;
    }
    const auto authenticated = host->authenticated();
    uid = authenticated ? host->preference("account-id-" + accountKey()) : QString();
    nickname = authenticated ? identityNames.value(provider) : QStringLiteral("未登录");
    if (authenticated && nickname.isEmpty()) {
        nickname = QStringLiteral("正在恢复登录…");
    }
}

/** 查询当前来源声明的功能与会员信息 */
void MusicLibrary::refreshAccountFeatures() {
    const auto operations = ProviderRegistry::instance().descriptor(provider)["operations"].toObject();
    const auto alive = valid(m_accountGeneration, &m_accountGeneration);
    if (operations["capabilities"].toBool()) {
        api.call(
            "capabilities", {},
            [this](MusicReply result) {
                if (result.ok()) {
                    capabilities = result.value.toObject();
                    changed();
                }
            },
            alive);
    }
    if (host->authenticated() && operations["vip"].toBool()) {
        api.call(
            "vip", {},
            [this](MusicReply result) {
                vipLevel = result.ok() ? result.value.toObject()["vipLevel"].toString("unknown") : "unknown";
                changed();
            },
            alive);
    }
}

void MusicLibrary::restoreAccount(Completion done) {
    if (isLocal() || isSiren()) {
        if (done) {
            done(true);
        }
        return;
    }
    refreshAccountFeatures();
    if (!host->authenticated()) {
        if (done) {
            done(true);
        }
        return;
    }
    restoringAccount = true;
    m_accountError.clear();
    changed();
    api.call(
        "account", {},
        [this, done](MusicReply result) {
            restoringAccount = false;
            if (result.ok()) {
                const auto values = result.value.toObject();
                const auto accountID = values["uid"].toString();
                if (uid != accountID) {
                    ++m_accountGeneration;
                    resetLikeState();
                }
                uid = accountID;
                nickname = values["nickname"].toString();
                rememberIdentityName(provider, nickname);
            } else if (result.failure["code"].toInt() == 401 || result.failure["authExpired"].toBool() ||
                       (provider == "netease" && result.failure["code"].toInt() == 301)) {
                uid.clear();
                nickname = QStringLiteral("登录已失效");
                host->setPreference("account-id-" + accountKey(), "");
                status = QStringLiteral("登录已失效，请重新登录");
            } else {
                status = QStringLiteral("账号验证暂不可用，已保留本机登录记录");
            }
            m_accountError = result.ok() ? QString() : status;
            const auto pending = m_pendingLane;
            m_pendingLane = -1;
            if (result.ok() && pending > 0) {
                loadMoreSource(pending);
            }
            changed();
            if (done) {
                done(result.ok());
            }
        },
        valid(m_accountGeneration, &m_accountGeneration));
}

/** 换来源先隔离旧请求并停止播放，再恢复目标来源的独立凭据和显示状态。 */
void MusicLibrary::switchProvider(QString source, QString edition, Completion done) {
    if (source == "local" && !PlatformFeatures::LocalMusic) {
        if (done) {
            done(false);
        }
        return;
    }
    const auto editionChanged =
        source == "kugou" && QStringList{"standard", "lite"}.contains(edition) && edition != kugouEdition;
    if (!ProviderRegistry::instance().contains(source) ||
        (source == "local" && !PlatformFeatures::LocalMusic) || (source == provider && !editionChanged)) {
        if (done) {
            done(true);
        }
        return;
    }
    cancelLogin();
    ++m_generation;
    ++m_accountGeneration;
    ++m_selectionGeneration;
    ++m_directoryGeneration;
    ++m_wikiGeneration;
    ++m_suggestGeneration;
    discover->cancel();
    player.stop();
    local->cancel();
    emit musicClearRequested();
    provider = source;
    if (editionChanged) {
        kugouEdition = edition;
        host->setKugouEdition(edition);
        host->setPreference("kugou-edition", edition);
        identityNames["kugou"] = host->preference("welcome-name-" + accountKey());
    }
    host->setProvider(source);
    host->setPreference("provider", source);
    api.provider = source;
    restoreCachedAccount();
    restoringAccount = false;
    m_pendingLane = -1;
    m_playLiked = false;
    m_accountError.clear();
    m_sourceErrors.fill({});
    loginStatus.clear();
    loginDiagnostics = {};
    current = {};
    directory.reset();
    groupLane = -1;
    groupName.clear();
    groupIndices.clear();
    details.clear();
    tracks = {};
    trackIDs = {};
    coverImage.clear();
    coverKey.clear();
    for (auto &list : lists) {
        list = {};
    }
    totals.fill(0);
    offsets.fill(0);
    sirenOffsets.fill(0);
    hasMore.fill(true);
    rowMemory.fill(0);
    likedIDs.reset();
    likedCursor = 0;
    sirenCatalogLoading = false;
    m_pendingSirenSearch = false;
    albumCursor = 0;
    playlistCursor = 0;
    searchCursor = 0;
    searchLoading = false;
    personalLoading = false;
    detailLoading = false;
    directoryLoading = false;
    trackLoad = false;
    writeLoading = false;
    subscriptions.clear();
    subscriptionStates.clear();
    capabilities = {};
    vipLevel = "unknown";
    searchKind = "song";
    keyword.clear();
    suggestions.clear();
    selectedPhysical = -1;
    selectedLane = 0;
    privateSelection = false;
    loginMethod = "qr";
    if (isLocal()) {
        refreshLocal();
    } else if (isSiren()) {
        columns = {"搜索结果", "喜欢的歌曲", "我的歌单", "全部歌曲", "全部专辑"};
    } else {
        columns = {"搜索结果", "喜欢的歌曲", "我的歌单", "收藏歌单", "收藏专辑"};
    }
    if (isSiren()) {
        if (!collections) {
            collections = std::make_unique<LocalCollections>(source, QString(), this);
        }
        reloadSirenCollections();
        loadSirenCatalog();
    }
    status = QStringLiteral("已切换至") + providerName();
    changed();
    restoreAccount(done);
}

int MusicLibrary::loginRetrySeconds() const {
    const auto remaining = m_cooldowns.value(provider).deadline - QDateTime::currentMSecsSinceEpoch();
    return int(std::max(qint64(0), (remaining + 999) / 1000));
}

bool MusicLibrary::canRegenerateLogin() const {
    return loginRetrySeconds() == 0 && loginPhase != "preparing" && loginPhase != "confirming";
}

void MusicLibrary::reportLoginFailure(const QJsonObject &details, QString fallback) {
    loginDiagnostics = MusicApi::safeFailure(details);
    const auto message = fallback.isEmpty() ? loginFailureMessage(details) : fallback;
    loginPhase = "failed";
    loginStatus = message;
    const auto retry = std::max(qint64(0), details["retryAfterMs"].toInteger());
    if (retry > 0) {
        const Cooldown cooldown{QDateTime::currentMSecsSinceEpoch() + retry, message, ++m_cooldownGeneration};
        m_cooldowns[provider] = cooldown;
        updateLoginCooldown(provider, cooldown);
    }
    changed();
}

void MusicLibrary::updateLoginCooldown(QString source, Cooldown cooldown) {
    if (!m_cooldowns.contains(source) || m_cooldowns[source].token != cooldown.token) {
        return;
    }
    const auto remaining = cooldown.deadline - QDateTime::currentMSecsSinceEpoch();
    const auto seconds = std::max(qint64(0), (remaining + 999) / 1000);
    if (source == provider && loginPhase == "failed") {
        loginStatus = cooldown.message + (seconds > 0 ? QStringLiteral("（请等待 ") +
                                                            QString::number(seconds) + QStringLiteral(" 秒）")
                                                      : QStringLiteral("，可重新生成"));
        changed();
    }
    if (seconds > 0) {
        host->schedule(1000, [owner = QPointer(this), source, cooldown] {
            if (owner) {
                owner->updateLoginCooldown(source, cooldown);
            }
        });
    }
}

/** 取消旧二维码并建立完成屏障，下一次生成必须等待真正的取消结果。 */
void MusicLibrary::cancelLogin(Completion done) {
    const auto previousKey = qrKey;
    ++m_loginGeneration;
    host->bumpEpoch();
    qrKey.clear();
    qr.clear();
    loginPhase = "idle";
    accountLoading = false;
    if (previousKey.isEmpty()) {
        if (done) {
            done(true);
        }
        return;
    }
    const auto source = provider;
    auto pending = std::make_shared<Cancellation>();
    if (done) {
        pending->waiters.append(done);
    }
    m_cancellations[source] = pending;
    api.call("loginCancel", {previousKey}, [this, source, pending](MusicReply result) {
        if (m_cancellations.value(source) == pending) {
            m_cancellations.remove(source);
        }
        for (const auto &complete : pending->waiters) {
            complete(result.ok());
        }
    });
}

int MusicLibrary::smsRetrySeconds() const {
    const auto remaining = m_smsRetryAtMs - QDateTime::currentMSecsSinceEpoch();
    return int(std::max(qint64(0), (remaining + 999) / 1000));
}

void MusicLibrary::updateSmsCooldown() {
    if (provider == "netease" && loginMethod == "phone") {
        changed();
    }
    if (smsRetrySeconds() > 0) {
        host->schedule(1000, [owner = QPointer(this)] {
            if (owner) {
                owner->updateSmsCooldown();
            }
        });
    }
}

/**
 * 发送短信验证码
 */
void MusicLibrary::sendLoginCode(QString phone) {
    const auto method = ProviderRegistry::instance().loginMethod(provider, "phone");
    if (method.isEmpty() || accountLoading || smsRetrySeconds() > 0) {
        return;
    }
    phone = phone.trimmed();
    const auto pattern = method["phonePattern"].toString("^1[0-9]{10}$");
    if (!QRegularExpression(pattern).match(phone).hasMatch()) {
        loginStatus = QStringLiteral("请输入有效的中国大陆手机号码");
        changed();
        return;
    }
    cancelLogin();
    const auto token = ++m_loginGeneration;
    loginMethod = "phone";
    loginStatus = QStringLiteral("正在发送短信验证码…");
    accountLoading = true;
    // 这是应用侧的 60 秒重发间隔，不改变上游参数或重试策略。
    constexpr qint64 SMS_RESEND_INTERVAL_MS = 60000;
    m_smsRetryAtMs = QDateTime::currentMSecsSinceEpoch() + SMS_RESEND_INTERVAL_MS;
    updateSmsCooldown();
    api.call(
        "loginSms", {phone},
        [this](MusicReply result) {
            accountLoading = false;
            loginStatus = result.ok() ? QStringLiteral("验证码已发送，请查看手机短信") : result.error;
            changed();
        },
        valid(token, &m_loginGeneration));
}

/** 手机号验证码登录 */
void MusicLibrary::captchaLogin(QString phone, QString captcha) {
    const auto method = ProviderRegistry::instance().loginMethod(provider, "phone");
    if (method.isEmpty() || accountLoading) {
        return;
    }
    phone = phone.trimmed();
    captcha = captcha.trimmed();
    const auto pattern = method["phonePattern"].toString("^1[0-9]{10}$");
    if (!QRegularExpression(pattern).match(phone).hasMatch() ||
        !QRegularExpression("^[0-9]{4,8}$").match(captcha).hasMatch()) {
        loginStatus = QStringLiteral("请输入中国大陆手机号码和短信验证码");
        changed();
        return;
    }
    cancelLogin();
    const auto token = ++m_loginGeneration;
    loginMethod = "phone";
    loginStatus = QStringLiteral("正在登录…");
    accountLoading = true;
    changed();
    api.call(
        "loginSubmit", {phone, captcha},
        [this, token](MusicReply result) {
            if (!result.ok()) {
                loginStatus = result.error;
                accountLoading = false;
                changed();
                return;
            }
            confirmLogin(token, true);
        },
        valid(token, &m_loginGeneration));
}

void MusicLibrary::failLogin(const MusicReply &result) {
    loginPhase = "failed";
    accountLoading = false;
    if (provider == "qq" && result.failure.contains("code")) {
        reportLoginFailure(result.failure);
    } else {
        loginStatus = result.error;
        changed();
    }
}

void MusicLibrary::confirmLogin(quint64 token, bool captcha) {
    api.call(
        "account", {},
        [this, captcha](MusicReply result) {
            if (!result.ok()) {
                if (captcha) {
                    loginStatus = result.error;
                    accountLoading = false;
                    changed();
                } else {
                    failLogin(result);
                }
                return;
            }
            const auto error = host->saveCredential();
            if (!error.isEmpty()) {
                if (captcha) {
                    loginStatus = error;
                    accountLoading = false;
                    changed();
                } else {
                    failLogin({{}, error, {}});
                }
                return;
            }
            ++m_accountGeneration;
            host->bumpEpoch();
            restoringAccount = false;
            m_accountError.clear();
            const auto values = result.value.toObject();
            const auto accountID = values["uid"].toString();
            if (uid != accountID) {
                resetLikeState();
            }
            uid = accountID;
            nickname = values["nickname"].toString();
            rememberIdentityName(provider, nickname);
            loginStatus = QStringLiteral("已登录：") + nickname;
            refreshAccountFeatures();
            status = captcha ? loginStatus : QStringLiteral("已登录，可读取我的音乐");
            if (!captcha) {
                qr.clear();
                qrKey.clear();
                loginPhase = "complete";
                m_cooldowns.remove(provider);
            }
            accountLoading = false;
            loadMoreSource(2);
            changed();
        },
        valid(token, &m_loginGeneration));
}

void MusicLibrary::startLogin() {
    if (isLocal() || isSiren()) {
        return;
    }
    if (!canRegenerateLogin()) {
        const auto seconds = loginRetrySeconds();
        if (seconds > 0) {
            loginPhase = "failed";
            loginStatus = m_cooldowns.value(provider).message + QStringLiteral("（请等待 ") +
                          QString::number(seconds) + QStringLiteral(" 秒）");
            changed();
        }
        return;
    }
    loginPhase = "preparing";
    loginDiagnostics = {};
    loginStatus = QStringLiteral("准备二维码…");
    qr.clear();
    accountLoading = true;
    changed();
    cancelLogin([this](bool cancelled) {
        if (!cancelled) {
            failLogin({{}, QStringLiteral("旧二维码取消失败，请稍后重试"), {}});
            return;
        }
        const auto token = ++m_loginGeneration;
        prepareQR(token);
    });
}

void MusicLibrary::prepareQR(quint64 token) {
    const auto alive = valid(token, &m_loginGeneration);
    api.call(
        "loginBegin", {loginMethod},
        [this, token, alive](MusicReply result) {
            if (!result.ok()) {
                failLogin(result);
                return;
            }
            const auto page = result.value.toObject();
            const auto key = page["token"].toString();
            if (key.isEmpty()) {
                failLogin({{}, QStringLiteral("二维码生成失败"), {}});
                return;
            }
            qrKey = key;
            const auto text = page["qrText"].toString();
            const auto image = page["qrImage"].toString();
            qr = !image.isEmpty() ? host->qrImage(image) : (!text.isEmpty() ? host->qr(text) : QString());
            if (qr.isEmpty()) {
                failLogin({{}, providerName() + QStringLiteral("二维码读取失败"), {}});
                return;
            }
            auto hint = ProviderRegistry::instance().text(provider, "scanHint");
            if (hint.isEmpty()) {
                hint = QStringLiteral("请用") + providerName() + QStringLiteral("扫描并确认登录");
            }
            loginPhase = "waiting";
            loginStatus = hint;
            changed();
            pollQR(token, 0);
        },
        alive);
}

void MusicLibrary::pollQR(quint64 token, int count) {
    if (count >= 300) {
        failLogin({{}, QStringLiteral("二维码超时，请重新生成"), {}});
        return;
    }
    const auto alive = valid(token, &m_loginGeneration);
    host->schedule(1000, [this, token, count, alive] {
        if (!alive()) {
            return;
        }
        api.call(
            "loginPoll", {qrKey},
            [this, token, count](MusicReply result) {
                if (!result.ok()) {
                    failLogin(result);
                    return;
                }
                const auto page = result.value.toObject();
                const auto status = page["status"].toString();
                const auto code = page["code"].toInt(800);
                if (status == "expired" || code == 800) {
                    qr.clear();
                    accountLoading = false;
                    const auto failures = ProviderRegistry::instance()
                                              .descriptor(provider)["login"]
                                              .toObject()["failureMessages"]
                                              .toObject();
                    if (!failures.isEmpty()) {
                        reportLoginFailure(page);
                    } else {
                        failLogin({{}, QStringLiteral("二维码已过期，请重新生成"), {}});
                    }
                    return;
                }
                if (status == "scanned" || code == 802) {
                    loginPhase = "confirming";
                    loginStatus = QStringLiteral("已扫描，请在手机上确认");
                    changed();
                }
                if (status == "confirmed" || code == 803) {
                    loginPhase = "confirming";
                    confirmLogin(token);
                    return;
                }
                pollQR(token, count + 1);
            },
            alive);
    });
}

/** 退出只清理当前来源凭据与私有资料，并撤销该账号的全部异步更新。 */
void MusicLibrary::logout() {
    if (isLocal() || isSiren()) {
        return;
    }
    const auto clearSelection = selectedLane > 0 || privateSelection;
    writeLoading = false;
    subscriptions.clear();
    subscriptionStates.clear();
    vipLevel = "unknown";
    discover->cancel();
    player.stop();
    player.clearHistory();
    host->setPreference("play-history", "[]");
    while (directory) {
        leaveDirectory();
    }
    groupLane = -1;
    groupName.clear();
    groupIndices.clear();
    cancelLogin();
    ++m_accountGeneration;
    restoringAccount = false;
    m_pendingLane = -1;
    m_playLiked = false;
    m_accountError.clear();
    m_sourceErrors.fill({});
    host->logout();
    host->setPreference("account-id-" + accountKey(), "");
    uid.clear();
    nickname = QStringLiteral("未登录");
    likedIDs.reset();
    likedCursor = 0;
    playlistCursor = 0;
    albumCursor = 0;
    personalLoading = false;
    details.clear();
    for (int lane = 1; lane < 5; ++lane) {
        lists[lane] = {};
        totals[lane] = 0;
        offsets[lane] = 0;
        hasMore[lane] = true;
    }
    emit musicClearRequested();
    choose(clearSelection ? QJsonObject{} : current);
    privateSelection = false;
    status = QStringLiteral("已退出登录");
    changed();
}
