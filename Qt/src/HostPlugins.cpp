#include "Host.h"
#if RHINE_SENTRY
#include "SentryTelemetry.h"
#endif
#include "AppStorage.h"
#include "PluginInstaller.h"
#include "ProviderRegistry.h"
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QUuid>
#include <utility>

QString Host::pluginRoot() const {
    return AppStorage::dataDirectory() + "/plugins";
}

QJsonObject Host::pluginControlRequest(const QString &control) const {
    const auto userRoot = pluginRoot();
    return {{"control", control},
            {"root", QDir(root).absolutePath()},
            {"userRoot", QFileInfo(userRoot).isSymLink() ? QString() : userRoot},
            {"disabled", QJsonArray::fromStringList(disabledPlugins())}};
}

void Host::refreshPluginCatalog(bool reloadService) {
    m_pluginCatalog = {};
    m_pluginRuntimeProblems = {};
    QString error;
    if (remote) {
        const auto method =
            reloadService ? QStringLiteral("host.reloadPlugins") : QStringLiteral("host.pluginCatalog");
        m_pluginCatalog = remote->call(method, {}, 10000);
        m_pluginRuntimeProblems = m_pluginCatalog.take("runtimeProblems").toObject();
        error = remote->error();
    } else if (!installedPluginManifests().isEmpty()) {
        m_pluginCatalog =
            PluginInstaller::runSynchronously(root, pluginControlRequest("plugins.discover"), error);
    }
    if (!error.isEmpty()) {
        m_pluginCatalog["error"] = error;
    }
    ProviderRegistry::instance().load(root, m_pluginCatalog["accepted"].toArray());
#if RHINE_SENTRY
    RhineSentry::pluginVersions();
#endif
}

QJsonObject Host::pluginCatalog() const {
    auto result = m_pluginCatalog;
    result["runtimeProblems"] = m_pluginRuntimeProblems;
    return result;
}

void Host::markPluginRuntimeFailure(const QString &id, const QString &reason) {
    if (!PluginInstaller::validId(id) || m_pluginRuntimeProblems.contains(id)) {
        return;
    }
    const auto message = reason.isEmpty() ? QStringLiteral("插件初始化失败") : reason.left(250);
    m_pluginRuntimeProblems[id] = message;
    emit pluginRuntimeFailed(id, message);
    emit invalidated();
}

QString Host::pluginProblem(const QString &id) const {
    if (m_pluginRuntimeProblems.contains(id)) {
        return m_pluginRuntimeProblems[id].toString();
    }
    for (const auto &value : m_pluginCatalog["problems"].toArray()) {
        const auto problem = value.toObject();
        const auto problemId = problem["id"].toString(problem["directory"].toString());
        if (problemId == id && problem["code"].toString() != "plugin.disabled") {
            return problem["message"].toString();
        }
    }
    return m_pluginCatalog["error"].toString();
}

QString Host::pluginDirectory(const QString &id) const {
    if (!PluginInstaller::validId(id)) {
        return {};
    }
    const auto user = pluginRoot() + "/" + id;
    if (QFileInfo(user).isDir() && !QFileInfo(user).isSymLink()) {
        return user;
    }
    const auto bundled = QDir(root).absoluteFilePath("MusicBridge/local-plugins/" + id);
    return QFileInfo(bundled).isDir() && !QFileInfo(bundled).isSymLink() ? bundled : QString();
}

void Host::updateMarketplaceComparisons() {
    QJsonObject pairs;
    QHash<QString, QString> installed;
    for (const auto &value : installedPluginManifests()) {
        const auto manifest = value.toObject();
        installed.insert(manifest["id"].toString(), manifest["version"].toString());
    }
    for (const auto &value : marketplacePlugins) {
        const auto item = value.toObject();
        const auto id = item["id"].toString();
        if (installed.contains(id)) {
            pairs.insert(id, QJsonArray{item["version"], installed.value(id)});
        }
    }
    m_marketComparisons = {};
    if (!pairs.isEmpty()) {
        QString error;
        const auto result = PluginInstaller::runSynchronously(
            root, {{"control", "plugins.compare"}, {"pairs", pairs}}, error);
        m_marketComparisons = result["comparisons"].toObject();
    }
}

QJsonArray Host::installedPluginManifests() const {
    QMap<QString, QJsonObject> byId;
    const QStringList roots{pluginRoot(), QDir(root).absoluteFilePath("MusicBridge/local-plugins")};
    for (const auto &directory : roots) {
        QDir plugins(directory);
        if (!plugins.exists() || QFileInfo(directory).isSymLink()) {
            continue;
        }
        for (const auto &entry : plugins.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
            if (entry.fileName().startsWith('.') || entry.isSymLink()) {
                continue;
            }
            QFile manifestFile(entry.absoluteFilePath() + "/manifest.json");
            if (QFileInfo(manifestFile).isSymLink() || !manifestFile.open(QIODevice::ReadOnly) ||
                manifestFile.size() > 1024 * 1024) {
                continue;
            }
            auto manifest = QJsonDocument::fromJson(manifestFile.readAll()).object();
            const auto id = manifest["id"].toString(entry.fileName());
            if (!PluginInstaller::validId(id) || byId.contains(id)) {
                continue;
            }
            manifest["id"] = id;
            byId.insert(id, manifest);
        }
    }
    QJsonArray values;
    for (const auto &manifest : byId) {
        values.append(manifest);
    }
    return values;
}
QStringList Host::disabledPlugins() const {
    QFile file(AppStorage::dataDirectory() + "/plugins-state.json");
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    const auto document = QJsonDocument::fromJson(file.readAll()).object();
    const auto disabled = document["disabled"].toArray();
    QStringList values;
    for (const auto &value : disabled) {
        if (value.isString()) {
            values.append(value.toString());
        }
    }
    return values;
}
bool Host::writeDisabledPlugins(const QStringList &disabled) {
    const auto directory = AppStorage::dataDirectory();
    if (!QDir().mkpath(directory)) {
        return false;
    }
    QSaveFile file(directory + "/plugins-state.json");
    if (!file.open(QIODevice::WriteOnly) || !file.setPermissions(QFile::ReadOwner | QFile::WriteOwner)) {
        return false;
    }
    const auto bytes = QJsonDocument(QJsonObject{{"disabled", QJsonArray::fromStringList(disabled)}})
                           .toJson(QJsonDocument::Compact);
    return file.write(bytes) == bytes.size() && file.commit();
}
QJsonArray Host::pluginManagerState() const {
    QHash<QString, QString> marketVersions;
    for (const auto &entry : marketplacePlugins) {
        const auto value = entry.toObject();
        marketVersions.insert(value["id"].toString(), value["version"].toString());
    }
    QJsonArray values;
    for (const auto &manifest : installedPluginManifests()) {
        const auto value = manifest.toObject();
        const auto id = value["id"].toString();
        const auto version = value["version"].toString();
        const auto marketVersion = marketVersions.value(id);
        values.append(QJsonObject{
            {"id", id},
            {"name", value["display"].toObject()["name"].toString(id)},
            {"version", version},
            {"marketVersion", marketVersion},
            {"updateAvailable", m_marketComparisons[id].toInt() > 0},
            {"publisher", value["publisher"].toString()},
            {"license", value["license"].toString()},
            {"enabled", pluginEnabled(id)},
            {"compatibilityProblem", pluginProblem(id)},
            {"userInstalled", QDir(AppStorage::dataDirectory() + "/plugins/" + id).exists()},
        });
    }
    return values;
}
QJsonObject Host::pluginDetail(QString id) const {
    for (const auto &manifest : installedPluginManifests()) {
        const auto value = manifest.toObject();
        if (value["id"].toString() == id) {
            auto result = value;
            result["enabled"] = pluginEnabled(id);
            result["compatibilityProblem"] = pluginProblem(id);
            result["installed"] = true;
            result["userInstalled"] = QDir(AppStorage::dataDirectory() + "/plugins/" + id).exists();
            for (const auto &entry : marketplacePlugins) {
                const auto market = entry.toObject();
                if (market["id"].toString() == id) {
                    result["marketVersion"] = market["version"].toString();
                    result["updateAvailable"] = m_marketComparisons[id].toInt() > 0;
                    break;
                }
            }
            return result;
        }
    }
    for (const auto &entry : marketplacePlugins) {
        const auto value = entry.toObject();
        if (value["id"].toString() == id) {
            auto result = value;
            result["enabled"] = true;
            result["installed"] = false;
            result["updateAvailable"] = false;
            return result;
        }
    }
    return {};
}
QString Host::marketplaceUrl() const {
    static const QString fallback =
        QStringLiteral("https://raw.githubusercontent.com/MikeQu223/Rhine-Plugin-Market/main/index.json");
    const auto configured = qEnvironmentVariable("RHINE_PLUGIN_MARKETPLACE_URL");
    return configured.isEmpty() ? fallback : configured;
}
QJsonObject Host::pluginMarketplaceState() const {
    QHash<QString, QString> installedVersions;
    for (const auto &manifest : installedPluginManifests()) {
        const auto value = manifest.toObject();
        installedVersions.insert(value["id"].toString(), value["version"].toString());
    }
    QJsonArray plugins;
    int updatesAvailable = 0;
    for (const auto &entry : marketplacePlugins) {
        auto value = entry.toObject();
        const auto id = value["id"].toString();
        const auto installedVersion = installedVersions.value(id);
        const auto updateAvailable = m_marketComparisons[id].toInt() > 0;
        value["installedVersion"] = installedVersion;
        value["updateAvailable"] = updateAvailable;
        if (updateAvailable) {
            ++updatesAvailable;
        }
        plugins.append(value);
    }
    return {{"url", marketplaceUrl()},
            {"loading", marketplaceLoading},
            {"installing", marketplaceInstalling},
            {"installId", marketplaceInstallId},
            {"installFile", marketplaceInstallFile},
            {"installFilesDone", marketplaceInstallFilesDone},
            {"installFilesTotal", marketplaceInstallFilesTotal},
            {"installBytes", double(marketplaceInstallBytes)},
            {"installSpeed", marketplaceInstallSpeed},
            {"installProgress", marketplaceInstallProgress},
            {"updatesAvailable", updatesAvailable},
            {"status", marketplaceStatus},
            {"plugins", plugins}};
}
void Host::updateMarketplaceInstallProgress(bool force) {
    if (!marketplaceInstalling) {
        return;
    }
    const auto now = QDateTime::currentMSecsSinceEpoch();
    const auto elapsed = qMax<qint64>(1, now - marketplaceInstallStartedAt);
    marketplaceInstallSpeed = marketplaceInstallBytes * 1000.0 / elapsed;
    const double current =
        marketplaceInstallFileTotal > 0
            ? qBound(0.0, double(marketplaceInstallFileBytes) / marketplaceInstallFileTotal, 1.0)
            : 0.0;
    marketplaceInstallProgress =
        marketplaceInstallFilesTotal > 0
            ? qBound(0.0, (marketplaceInstallFilesDone + current) / marketplaceInstallFilesTotal, 1.0)
            : 0.0;
    if (force || now - marketplaceInstallLastEmit >= 200) {
        marketplaceInstallLastEmit = now;
        emit invalidated();
    }
}
bool Host::pluginUpdateAvailable(QString id) const {
    return m_marketComparisons[id].toInt() > 0;
}
void Host::checkPluginUpdates() {
    if (installedPluginManifests().isEmpty()) {
        return;
    }
    refreshPluginMarketplace();
}
void Host::refreshPluginMarketplace() {
    const auto url = marketplaceUrl();
    if (offline && !QUrl(url).isLocalFile()) {
        marketplaceStatus = QStringLiteral("离线模式，可导入本地插件包");
        emit invalidated();
        return;
    }
    if (url.isEmpty()) {
        marketplaceStatus = QStringLiteral("未配置插件市场地址");
        emit invalidated();
        return;
    }
    if (marketplaceLoading) {
        return;
    }
    marketplaceLoading = true;
    marketplaceStatus = QStringLiteral("正在读取插件市场…");
    emit invalidated();
    const auto apply = [this](const QByteArray &bytes) {
        const auto document = QJsonDocument::fromJson(bytes).object();
        QJsonArray plugins;
        for (const auto &entry : document["plugins"].toArray()) {
            const auto value = entry.toObject();
            const auto id = value["id"].toString();
            const auto path = value["path"].toString();
            if (!value["id"].isString() || !PluginInstaller::validId(id) || !value["path"].isString() ||
                !PluginInstaller::relativePath(path)) {
                continue;
            }
            plugins.append(value);
        }
        marketplacePlugins = plugins;
        updateMarketplaceComparisons();
        int updatesAvailable = 0;
        for (const auto &entry : plugins) {
            const auto value = entry.toObject();
            if (m_marketComparisons[value["id"].toString()].toInt() > 0) {
                ++updatesAvailable;
            }
        }
        marketplaceStatus =
            QStringLiteral("已载入 ") + QString::number(plugins.size()) + QStringLiteral(" 个插件");
        if (updatesAvailable > 0) {
            marketplaceStatus +=
                QStringLiteral(" · 发现 ") + QString::number(updatesAvailable) + QStringLiteral(" 个更新");
        }
        marketplaceLoading = false;
        emit invalidated();
    };
    if (url.startsWith("file:")) {
        QFile file(QUrl(url).toLocalFile());
        if (!file.open(QIODevice::ReadOnly)) {
            marketplaceLoading = false;
            marketplaceStatus = QStringLiteral("插件市场读取失败");
            emit invalidated();
            return;
        }
        if (file.size() >= 8 * 1024 * 1024) {
            marketplaceLoading = false;
            marketplaceStatus = QStringLiteral("插件市场索引超出大小限制");
            emit invalidated();
            return;
        }
        apply(file.readAll());
        return;
    }
    QNetworkRequest request{QUrl(url)};
    request.setTransferTimeout(20000);
    auto reply = network.get(request);
    reply->setReadBufferSize(8 * 1024 * 1024);
    connect(reply, &QNetworkReply::readyRead, reply, [reply] {
        if (reply->bytesAvailable() >= 8 * 1024 * 1024) {
            reply->abort();
        }
    });
    QTimer::singleShot(20000, reply, [reply] {
        if (!reply->isFinished()) {
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, apply] {
        const auto bytes = reply->readAll();
        const auto ok = reply->error() == QNetworkReply::NoError &&
                        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200 &&
                        bytes.size() < 8 * 1024 * 1024;
        reply->deleteLater();
        marketplaceLoading = false;
        if (!ok) {
            marketplaceStatus = QStringLiteral("插件市场读取失败");
            emit invalidated();
            return;
        }
        apply(bytes);
    });
}
namespace {
QString copyPluginFile(QIODevice &source, QSaveFile &destination, qint64 limit) {
    qint64 total = 0;
    QByteArray buffer(128 * 1024, Qt::Uninitialized);
    while (!source.atEnd()) {
        const auto bytes = source.read(buffer.data(), buffer.size());
        if (bytes <= 0 || bytes > limit - total) {
            return QStringLiteral("插件文件读取失败或超出大小限制");
        }
        if (destination.write(buffer.constData(), bytes) != bytes) {
            return QStringLiteral("写入插件文件失败");
        }
        total += bytes;
    }
    return {};
}
}

void Host::downloadPluginFile(const QUrl &url, const QString &path, qint64 limit, TextReply done) {
    if (!QDir().mkpath(QFileInfo(path).path())) {
        done(QStringLiteral("无法创建插件暂存目录"));
        return;
    }
    auto output = std::make_shared<QSaveFile>(path);
    if (!output->open(QIODevice::WriteOnly)) {
        done(QStringLiteral("无法写入插件暂存文件"));
        return;
    }
    if (url.isLocalFile()) {
        QFile source(url.toLocalFile());
        if (!source.open(QIODevice::ReadOnly) || source.size() > limit) {
            done(QStringLiteral("插件文件缺失或超出大小限制"));
            return;
        }
        auto error = copyPluginFile(source, *output, limit);
        if (error.isEmpty() && !output->commit()) {
            error = QStringLiteral("写入插件文件失败");
        }
        if (error.isEmpty()) {
            marketplaceInstallFileBytes = source.size();
            marketplaceInstallFileTotal = source.size();
            marketplaceInstallBytes += source.size();
            updateMarketplaceInstallProgress(true);
        }
        done(error);
        return;
    }
    QNetworkRequest request{url};
    request.setTransferTimeout(30000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    auto *reply = network.get(request);
    reply->setReadBufferSize(256 * 1024);
    auto failure = std::make_shared<QString>();
    const auto drain = [this, reply, output, failure, limit] {
        while (reply->bytesAvailable() > 0 && failure->isEmpty()) {
            const auto bytes = reply->read(128 * 1024);
            if (bytes.isEmpty() || bytes.size() > limit - marketplaceInstallFileBytes) {
                *failure = QStringLiteral("插件下载超出大小限制");
                return;
            }
            if (output->write(bytes) != bytes.size()) {
                *failure = QStringLiteral("写入插件文件失败");
                return;
            }
            marketplaceInstallFileBytes += bytes.size();
            marketplaceInstallBytes += bytes.size();
        }
        updateMarketplaceInstallProgress();
    };
    connect(reply, &QNetworkReply::downloadProgress, reply,
            [this, limit, reply, failure](qint64, qint64 total) {
                if (total > limit) {
                    *failure = QStringLiteral("插件下载超出大小限制");
                    reply->abort();
                } else if (total > 0) {
                    marketplaceInstallFileTotal = total;
                }
            });
    connect(reply, &QNetworkReply::readyRead, this, [reply, drain, failure] {
        drain();
        if (!failure->isEmpty()) {
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [reply, output, failure, drain, done] {
        if (reply->error() == QNetworkReply::NoError) {
            drain();
        }
        const bool ok = reply->error() == QNetworkReply::NoError &&
                        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200;
        reply->deleteLater();
        if (failure->isEmpty() && (!ok || !output->commit())) {
            *failure = QStringLiteral("插件下载或写入失败");
        }
        done(*failure);
    });
    QTimer::singleShot(120000, reply, [reply] {
        if (!reply->isFinished()) {
            reply->abort();
        }
    });
}

void Host::downloadPluginFiles(QStringList files, QUrl base, QString directory, TextReply done) {
    auto step = std::make_shared<std::function<void(int)>>();
    const std::weak_ptr<std::function<void(int)>> next(step);
    *step = [this, files = std::move(files), base = std::move(base), directory = std::move(directory), next,
             done = std::move(done)](int index) {
        if (index >= files.size()) {
            done({});
            return;
        }
        const auto name = files.at(index);
        marketplaceInstallFile = name;
        marketplaceInstallFileBytes = 0;
        marketplaceInstallFileTotal = 0;
        updateMarketplaceInstallProgress(true);
        const auto limit =
            qMin(PluginInstaller::MaxFileBytes, PluginInstaller::MaxExtractedBytes - marketplaceInstallBytes);
        QUrl relative;
        relative.setPath(name);
        downloadPluginFile(base.resolved(relative), directory + "/" + name, limit,
                           [this, continuation = next.lock(), done, index](QString error) {
                               if (!error.isEmpty()) {
                                   done(error);
                                   return;
                               }
                               marketplaceInstallFileBytes = 0;
                               marketplaceInstallFileTotal = 0;
                               ++marketplaceInstallFilesDone;
                               updateMarketplaceInstallProgress(true);
                               (*continuation)(index + 1);
                           });
    };
    (*step)(0);
}

QString Host::beginPluginInstall(const QString &id) {
    if (m_pluginStaging) {
        return QStringLiteral("请先完成当前插件安装");
    }
    const auto directory = pluginRoot();
    if (!QDir().mkpath(directory) || QFileInfo(directory).isSymLink()) {
        return QStringLiteral("无法创建插件目录");
    }
    auto staging = std::make_unique<QTemporaryDir>(directory + "/.staging-XXXXXX");
    if (!staging->isValid()) {
        return QStringLiteral("无法创建插件暂存目录");
    }
    auto lease = std::make_unique<QLockFile>(staging->filePath(".owner.lock"));
    lease->setStaleLockTime(0);
    if (!lease->tryLock()) {
        return QStringLiteral("无法锁定插件暂存目录");
    }
    m_pluginStaging = std::move(staging);
    m_pluginStageLease = std::move(lease);
    marketplaceInstalling = true;
    marketplaceInstallId = id;
    marketplaceInstallFile.clear();
    marketplaceInstallFilesDone = 0;
    marketplaceInstallFilesTotal = 0;
    marketplaceInstallBytes = 0;
    marketplaceInstallFileBytes = 0;
    marketplaceInstallFileTotal = 0;
    marketplaceInstallStartedAt = QDateTime::currentMSecsSinceEpoch();
    marketplaceInstallLastEmit = 0;
    marketplaceInstallSpeed = 0;
    marketplaceInstallProgress = 0;
    marketplaceStatus = QStringLiteral("正在检查插件…");
    updateMarketplaceInstallProgress(true);
    return {};
}

/** 所有来源先生成应用私有候选目录。校验器仅解析数据并返回给确认页。 */
void Host::preparePlugin(QString source, QString kind, QString origin, const QJsonObject &expected) {
    auto request = pluginControlRequest("plugins.validate");
    request["kind"] = kind;
    request["path"] = source;
    request["stagedPath"] = m_pluginStaging->filePath("candidate");
    request["expected"] = expected;
    PluginInstaller::run(this, root, request, [this, origin](QJsonObject result, QString error) {
        const auto manifest = result["manifest"].toObject();
        const auto id = manifest["id"].toString();
        if (!error.isEmpty() || !PluginInstaller::validId(id)) {
            finishPluginInstall(error.isEmpty() ? QStringLiteral("插件校验结果无效") : error);
            return;
        }
        const auto current = pluginDetail(id);
        const auto installed = current["installed"].toBool() ? current["version"].toString() : QString();
        auto action = current["installed"].toBool() ? QStringLiteral("覆盖安装") : QStringLiteral("新安装");
        if (!installed.isEmpty()) {
            const auto compared = PluginInstaller::runSynchronously(
                root,
                {{"control", "plugins.compare"},
                 {"pairs", QJsonObject{{id, QJsonArray{manifest["version"], installed}}}}},
                error);
            if (!error.isEmpty()) {
                finishPluginInstall(error);
                return;
            }
            const auto comparison = compared["comparisons"].toObject()[id].toInt();
            if (comparison > 0) {
                action = QStringLiteral("升级");
            } else if (comparison < 0) {
                action = QStringLiteral("降级");
            }
        }
        m_preparedPlugin = QJsonObject{{"manifest", manifest},
                                       {"origin", origin},
                                       {"action", action},
                                       {"installedVersion", installed},
                                       {"format", result["format"]},
                                       {"compatibility", result["compatibility"]},
                                       {"clientVersion", PluginInstaller::clientVersion()},
                                       {"willEnable", !disabledPlugins().contains(id)}};
        const auto icon = manifest["display"].toObject()["icon"].toString();
        auto imageFormat = QFileInfo(icon).suffix().toLower().toLatin1();
        if (imageFormat == "jpg") {
            imageFormat = "jpeg";
        }
        if (PluginInstaller::relativePath(icon) &&
            QList<QByteArray>{"png", "jpeg", "webp"}.contains(imageFormat)) {
            const auto iconPath = m_pluginStaging->filePath("candidate/" + icon);
            QImageReader reader(iconPath, imageFormat);
            const auto size = reader.size();
            const auto info = QFileInfo(iconPath);
            if (info.size() <= 512 * 1024 && size.isValid() && size.width() <= 512 && size.height() <= 512) {
                const auto image =
                    reader.read().scaled(64, 64, Qt::KeepAspectRatio, Qt::SmoothTransformation);
                if (!image.isNull()) {
                    const auto key = "plugin-preview:" + QUuid::createUuid().toString(QUuid::WithoutBraces);
                    images.insert(key, new QImage(image), qMax(1, int(image.sizeInBytes() / 1024)));
                    m_preparedPlugin["icon"] = key;
                }
            }
        }
        marketplaceInstalling = false;
        marketplaceStatus = QStringLiteral("插件已通过检查，等待确认");
        emit pluginInstallConfirmation(m_preparedPlugin);
        emit invalidated();
    });
}

void Host::finishPluginInstall(const QString &error) {
    m_preparedPlugin = {};
    m_pluginStageLease.reset();
    m_pluginStaging.reset();
    marketplaceInstalling = false;
    if (!error.isEmpty()) {
        marketplaceStatus = error;
    }
    emit pluginInstallFinished(error);
    emit invalidated();
}

void Host::cancelPluginInstall() {
    if (!m_preparedPlugin.isEmpty()) {
        marketplaceStatus = QStringLiteral("已取消插件安装");
        finishPluginInstall({});
    }
}

void Host::confirmPluginInstall() {
    if (!m_pluginStaging || m_preparedPlugin.isEmpty() || marketplaceInstalling) {
        return;
    }
    const auto approval = std::exchange(m_preparedPlugin, {});
    const auto approvedManifest = approval["manifest"].toObject();
    const auto id = approvedManifest["id"].toString();
    const auto path = m_pluginStaging->filePath("candidate");
    const auto expected = QJsonObject{{"id", id},
                                      {"version", approvedManifest["version"]},
                                      {"entry", approvedManifest["entry"].toObject()["file"]}};
    marketplaceInstalling = true;
    marketplaceStatus = QStringLiteral("正在安装插件…");
    emit invalidated();
    auto check = pluginControlRequest("plugins.inspect");
    check["path"] = path;
    check["expected"] = expected;
    check["requireDeclarations"] = approval["format"] == "zip";
    const auto complete = [this, approvedManifest, approval, id, path, check](QJsonObject, QString error) {
        if (error.isEmpty()) {
            error = PluginInstaller::commit(pluginRoot(), id, path, [&] {
                const auto current = pluginDetail(id);
                const auto version =
                    current["installed"].toBool() ? current["version"].toString() : QString();
                if (version != approval["installedVersion"].toString()) {
                    return QStringLiteral("已安装的插件版本发生变化，请重新打开安装包");
                }
                if ((!disabledPlugins().contains(id)) != approval["willEnable"].toBool()) {
                    return QStringLiteral("插件启用状态发生变化，请重新打开安装包");
                }
                QString checkError;
                const auto verified = PluginInstaller::runSynchronously(root, check, checkError);
                if (checkError.isEmpty() && verified["manifest"].toObject() != approvedManifest) {
                    return QStringLiteral("暂存的插件已改变，请重新导入");
                }
                return checkError;
            });
        }
        if (error.isEmpty()) {
            const auto name = approvedManifest["display"].toObject()["name"].toString(id);
            marketplaceInstallProgress = 1;
            marketplaceStatus = QStringLiteral("已安装 ") + name;
            reloadPlugins();
        }
        finishPluginInstall(error);
    };
    if (approval["willEnable"].toBool()) {
        auto request = pluginControlRequest("plugins.initialize");
        request["path"] = path;
        request["scratchPath"] = m_pluginStaging->path();
        request["expected"] = expected;
        request["requireDeclarations"] = approval["format"] == "zip";
        PluginInstaller::run(this, root, request, complete);
    } else {
        complete({}, {});
    }
}

QString Host::installMarketplacePlugin(QString id) {
    QJsonObject entry;
    for (const auto &value : marketplacePlugins) {
        if (value.toObject()["id"].toString() == id) {
            entry = value.toObject();
            break;
        }
    }
    if (!PluginInstaller::validId(id) || entry.isEmpty()) {
        return QStringLiteral("插件市场中没有该插件");
    }
    const auto index = QUrl(marketplaceUrl());
    if (index.scheme() != "https" && !index.isLocalFile()) {
        return QStringLiteral("插件市场地址必须使用 HTTPS");
    }
    const auto entryFile = entry["entry"].toObject()["file"].toString();
    auto expected = QJsonObject{{"id", id}, {"version", entry["version"]}, {"entry", entry["entry"]}};
    if (entry.contains("package")) {
        const auto package = entry["package"].toObject();
        const auto url = index.resolved(QUrl(package["url"].toString()));
        const auto size = package["size"].toInteger();
        static const QRegularExpression sha256(QStringLiteral("\\A[0-9a-f]{64}\\z"));
        if (package["url"].toString().isEmpty() || size <= 0 || size > PluginInstaller::MaxPackageBytes ||
            !sha256.match(package["sha256"].toString()).hasMatch() || !url.userInfo().isEmpty() ||
            (index.isLocalFile() ? !url.isLocalFile() : url.scheme() != "https")) {
            return QStringLiteral("市场插件包地址、大小或摘要无效");
        }
        const auto error = beginPluginInstall(id);
        if (!error.isEmpty()) {
            return error;
        }
        expected["size"] = size;
        expected["sha256"] = package["sha256"];
        const auto archive = m_pluginStaging->filePath("package.rhineplugin");
        marketplaceInstallFilesTotal = 1;
        marketplaceInstallFile = QFileInfo(url.path()).fileName();
        downloadPluginFile(url, archive, size, [this, archive, expected](QString problem) {
            if (!problem.isEmpty()) {
                finishPluginInstall(problem);
                return;
            }
            preparePlugin(archive, "package", QStringLiteral("插件市场"), expected);
        });
        return {};
    }
    const auto folder = entry["path"].toString();
    if (!PluginInstaller::relativePath(folder) || !PluginInstaller::relativePath(entryFile)) {
        return QStringLiteral("插件市场文件路径无效");
    }
    QStringList files{QStringLiteral("manifest.json"), entryFile};
    for (const auto &value : entry["files"].toArray()) {
        const auto name = value.isString() ? value.toString() : value.toObject()["path"].toString();
        if (!PluginInstaller::relativePath(name)) {
            return QStringLiteral("插件市场文件路径无效");
        }
        files.append(name);
    }
    files.removeDuplicates();
    if (files.size() > 512) {
        return QStringLiteral("插件市场文件数量超出限制");
    }
    QSet<QString> normalizedNames;
    for (const auto &file : files) {
        const auto normalized = file.normalized(QString::NormalizationForm_C).toCaseFolded();
        if (normalizedNames.contains(normalized)) {
            return QStringLiteral("插件市场文件名称冲突");
        }
        normalizedNames.insert(normalized);
    }
    const auto error = beginPluginInstall(id);
    if (!error.isEmpty()) {
        return error;
    }
    marketplaceInstallFilesTotal = files.size();
    const auto directory = m_pluginStaging->filePath("download");
    QUrl relative;
    relative.setPath(folder + "/");
    downloadPluginFiles(std::move(files), index.resolved(relative), directory,
                        [this, directory, expected](QString problem) {
                            if (!problem.isEmpty()) {
                                finishPluginInstall(problem);
                                return;
                            }
                            preparePlugin(directory, "directory", QStringLiteral("插件市场"), expected);
                        });
    return {};
}

bool Host::pluginEnabled(QString id) const {
    if (m_pluginRuntimeProblems.contains(id)) {
        return false;
    }
    for (const auto &value : m_pluginCatalog["accepted"].toArray()) {
        if (value.toObject()["manifest"].toObject()["id"] == id) {
            return true;
        }
    }
    return false;
}

QString Host::setPluginEnabled(QString id, bool enabled) {
    if (m_pluginStaging) {
        return QStringLiteral("请先完成当前插件安装");
    }
    const auto directory = pluginDirectory(id);
    if (directory.isEmpty()) {
        return QStringLiteral("插件目录无效");
    }
    if (!QDir().mkpath(pluginRoot()) || QFileInfo(pluginRoot()).isSymLink()) {
        return QStringLiteral("无法创建插件目录");
    }
    QLockFile lock(pluginRoot() + "/.install.lock");
    if (!lock.tryLock()) {
        return QStringLiteral("另一个窗口正在修改插件");
    }
    auto disabled = disabledPlugins();
    if (enabled) {
        QTemporaryDir scratch(pluginRoot() + "/.probe-XXXXXX");
        if (!scratch.isValid()) {
            return QStringLiteral("无法创建插件初始化验证目录");
        }
        auto request = pluginControlRequest("plugins.initialize");
        request["path"] = directory;
        request["scratchPath"] = scratch.path();
        request["expected"] = QJsonObject{{"id", id}};
        QString error;
        PluginInstaller::runSynchronously(root, request, error);
        if (!error.isEmpty()) {
            return error;
        }
        disabled.removeAll(id);
    } else if (!disabled.contains(id)) {
        disabled.append(id);
    }
    if (!writeDisabledPlugins(disabled)) {
        return QStringLiteral("无法保存插件启用状态");
    }
    lock.unlock();
    reloadPlugins();
    return {};
}

QString Host::rollbackPlugin(QString id) {
    if (!PluginInstaller::validId(id)) {
        return QStringLiteral("插件 ID 无效");
    }
    const auto backup = pluginRoot() + "/.backup-" + id;
    if (!QFileInfo(backup).isDir() || QFileInfo(backup).isSymLink()) {
        return QStringLiteral("没有可回滚的版本");
    }
    const auto error = beginPluginInstall(id);
    if (!error.isEmpty()) {
        return error;
    }
    preparePlugin(backup, "directory", QStringLiteral("本地版本备份"), {{"id", id}});
    return {};
}
QString Host::uninstallPlugin(QString id) {
    if (m_pluginStaging) {
        return QStringLiteral("正在安装插件，请稍候");
    }
    if (!PluginInstaller::validId(id)) {
        return QStringLiteral("插件 id 无效");
    }
    if (id == provider) {
        return QStringLiteral("请先切换到其他来源后再卸载插件");
    }
    const auto directory = pluginRoot();
    if (QFileInfo(directory).isSymLink()) {
        return QStringLiteral("插件目录无效");
    }
    QLockFile lock(directory + "/.install.lock");
    if (!lock.tryLock()) {
        return QStringLiteral("无法锁定插件目录");
    }
    const auto target = directory + "/" + id;
    if (!QDir(target).exists() || QFileInfo(target).isSymLink()) {
        return QStringLiteral("内置插件不能卸载");
    }
    if (!QDir(target).removeRecursively()) {
        return QStringLiteral("插件卸载失败");
    }
    QDir(directory + "/.backup-" + id).removeRecursively();
    auto disabled = disabledPlugins();
    disabled.removeAll(id);
    writeDisabledPlugins(disabled);
    lock.unlock();
    marketplaceStatus = QStringLiteral("已卸载 ") + id;
    reloadPlugins();
    return {};
}
QString Host::importPlugin(QString directory) {
    const QFileInfo source(directory);
    const auto canonical = source.canonicalFilePath();
    const auto installedRoot = QFileInfo(pluginRoot()).canonicalFilePath();
    if (!source.isDir() || source.isSymLink() || canonical.isEmpty() ||
        (!installedRoot.isEmpty() &&
         (canonical == installedRoot || canonical.startsWith(installedRoot + "/") ||
          installedRoot.startsWith(canonical + "/")))) {
        return QStringLiteral("请选择安装目录以外的插件文件夹");
    }
    const auto error = beginPluginInstall();
    if (!error.isEmpty()) {
        return error;
    }
    preparePlugin(canonical, "directory", QStringLiteral("本地文件夹"));
    return {};
}

QString Host::importPluginPackage(const QUrl &url) {
    if (!url.isLocalFile() || !url.fileName().endsWith(".rhineplugin", Qt::CaseInsensitive)) {
        return QStringLiteral("请选择 .rhineplugin 插件包");
    }
    // 外部文件提供者的授权只用于复制。后续校验与确认使用沙盒中的快照。
    QFile source(url.toLocalFile());
    if (!source.open(QIODevice::ReadOnly) || source.isSequential() ||
        source.size() > PluginInstaller::MaxPackageBytes) {
        return QStringLiteral("无法读取插件包，或文件超过大小限制");
    }
    const auto error = beginPluginInstall();
    if (!error.isEmpty()) {
        return error;
    }
    const auto archive = m_pluginStaging->filePath("package.rhineplugin");
    QSaveFile snapshot(archive);
    if (!snapshot.open(QIODevice::WriteOnly)) {
        finishPluginInstall(QStringLiteral("无法创建插件包快照"));
        return {};
    }
    const auto problem = copyPluginFile(source, snapshot, PluginInstaller::MaxPackageBytes);
    if (!problem.isEmpty() || !snapshot.commit()) {
        finishPluginInstall(problem.isEmpty() ? QStringLiteral("无法保存插件包快照") : problem);
        return {};
    }
    source.close();
    preparePlugin(archive, "package", QStringLiteral("本地文件 / ") + url.fileName());
    return {};
}
