#include "ProviderRegistry.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QRegularExpression>
#include <algorithm>

namespace {
const QStringList descriptorFields{
    "schemaVersion", "id",        "display",     "variants", "variantPreference",
    "capabilities",  "operations", "library",     "quality",  "login",
    "discover",      "lyrics",     "media",       "externalPlayback", "cache",
    "runtime",       "attribution", "links",      "strings",   "search",
};
bool validDescriptor(const QJsonObject &value) {
    return value["schemaVersion"].toInt(2) == 2 && !value["id"].toString().isEmpty() &&
           value["display"].isObject() && value["capabilities"].isObject();
}
bool compatiblePluginApi(const QString &version) {
    static const QRegularExpression pattern("^(\\d+)\\.(\\d+)$");
    const auto match = pattern.match(version);
    return match.hasMatch() && match.captured(1).toInt() == 2 && match.captured(2).toInt() <= 0;
}
bool safePluginFile(const QString &file) {
    return !file.isEmpty() && !QDir::isAbsolutePath(file) && !file.contains("..") &&
           !file.contains('\\');
}
bool validManifest(const QJsonObject &manifest) {
    if (manifest["schemaVersion"].toInt() != 2 || manifest["version"].toString().isEmpty() ||
        !compatiblePluginApi(manifest["apiVersion"].toString())) {
        return false;
    }
    const auto entry = manifest["entry"].toObject()["file"].toString();
    if (!safePluginFile(entry) || !manifest["display"].isObject() ||
        !manifest["capabilities"].isObject()) {
        return false;
    }
    const auto routes = manifest["routes"].toObject();
    for (const auto *key : {"legacyRoutes", "prefixes"}) {
        const auto values = routes[key];
        if (values.isUndefined()) {
            continue;
        }
        if (!values.isArray()) {
            return false;
        }
        for (const auto &value : values.toArray()) {
            if (!value.isString() || !value.toString().startsWith('/')) {
                return false;
            }
        }
    }
    return true;
}
}

ProviderRegistry &ProviderRegistry::instance() {
    static ProviderRegistry registry;
    return registry;
}

void ProviderRegistry::load(const QString &root, const QString &userRoot, const QStringList &disabled) {
    if (!root.isEmpty()) {
        m_root = root;
    }
    m_descriptors.clear();
    m_manifests.clear();
    m_legacy.clear();
    m_prefixes.clear();
    m_disabled.clear();
    for (const auto &id : disabled) {
        m_disabled.insert(id);
    }
    m_loaded = false;
    // 已安装插件优先；构建期内置 descriptor 不覆盖用户目录中的同 id 插件。
    loadManifestFallback(userRoot);
    loadDirectory(m_root + "/MusicBridge/plugins/descriptors", false);
    loadManifestFallback(m_root + "/MusicBridge/local-plugins");
    indexRoutes();
    // 构建产物缺失时仍保证 core 自带来源可用；插件 descriptor 存在时不会被覆盖。
    addBuiltin("siren", "塞壬唱片", "MONSTER SIREN", "官网曲库", "MONSTER SIREN", 0);
    addBuiltin("local", "本地音乐", "LOCAL", "文件夹管理 · 导入与索引 · 本地检索 · 播放", "LOCAL LIBRARY", 4);
    m_loaded = true;
}

bool ProviderRegistry::loaded() const {
    return m_loaded;
}

QStringList ProviderRegistry::ids() const {
    auto values = m_descriptors.keys();
    std::sort(values.begin(), values.end(), [this](const QString &left, const QString &right) {
        const auto leftOrder = m_descriptors[left]["display"].toObject()["order"].toInt(100);
        const auto rightOrder = m_descriptors[right]["display"].toObject()["order"].toInt(100);
        return leftOrder == rightOrder ? left < right : leftOrder < rightOrder;
    });
    return values;
}

bool ProviderRegistry::contains(const QString &id) const {
    return m_descriptors.contains(id);
}

QJsonObject ProviderRegistry::descriptor(const QString &id) const {
    return m_descriptors.value(id);
}

QJsonObject ProviderRegistry::manifest(const QString &id) const {
    return m_manifests.value(id);
}

QString ProviderRegistry::name(const QString &id) const {
    return nameForVariant(id, {});
}

QString ProviderRegistry::label(const QString &id) const {
    return m_descriptors.value(id)["display"].toObject()["label"].toString(id.toUpper());
}

QString ProviderRegistry::detail(const QString &id) const {
    return m_descriptors.value(id)["display"].toObject()["detail"].toString();
}

QString ProviderRegistry::sessionLabel(const QString &id) const {
    return m_descriptors.value(id)["display"].toObject()["sessionLabel"].toString(label(id) + " SESSION");
}

QString ProviderRegistry::archivePrefix(const QString &id) const {
    return m_descriptors.value(id)["display"].toObject()["archiveIdPrefix"].toString();
}

QString ProviderRegistry::nameForVariant(const QString &id, const QString &variant) const {
    const auto display = m_descriptors.value(id)["display"].toObject();
    if (!variant.isEmpty()) {
        const auto names = display["nameByVariant"].toObject();
        if (names[variant].isString()) {
            return names[variant].toString();
        }
    }
    return display["name"].toString(id);
}

QString ProviderRegistry::defaultId() const {
    for (const auto &id : ids()) {
        if (m_descriptors[id]["display"].toObject()["default"].toBool()) {
            return id;
        }
    }
    return {};
}

QString ProviderRegistry::fallbackId(const QString &exclude) const {
    for (const auto &id : ids()) {
        if (id != exclude) {
            return id;
        }
    }
    return {};
}

bool ProviderRegistry::capability(const QString &id, const QString &key, bool fallback) const {
    const auto value = m_descriptors.value(id)["capabilities"].toObject().value(key);
    return value.isBool() ? value.toBool() : fallback;
}

QStringList ProviderRegistry::columns(const QString &id) const {
    QStringList values;
    for (const auto &column : m_descriptors.value(id)["library"].toObject()["columns"].toArray()) {
        if (column.isString()) {
            values.append(column.toString());
        }
    }
    return values;
}

QVector<int> ProviderRegistry::sourceOrder(const QString &id) const {
    QVector<int> values;
    for (const auto &value : m_descriptors.value(id)["library"].toObject()["sourceOrder"].toArray()) {
        if (value.isDouble()) {
            values.append(value.toInt());
        }
    }
    return values;
}

QVector<int> ProviderRegistry::visibleLanes(const QString &id) const {
    QVector<int> values;
    const auto lanes = m_descriptors.value(id)["library"].toObject()["visibleLanes"].toArray();
    for (const auto &value : lanes) {
        if (value.isDouble()) {
            values.append(value.toInt());
        }
    }
    return values;
}

int ProviderRegistry::lanes(const QString &id) const {
    const auto value = m_descriptors.value(id)["library"].toObject()["lanes"].toInt();
    return value > 0 ? value : columns(id).size();
}

QVector<QPair<QString, QString>> ProviderRegistry::qualityOptions(const QString &id) const {
    QVector<QPair<QString, QString>> values;
    for (const auto &value : m_descriptors.value(id)["quality"].toObject()["options"].toArray()) {
        const auto option = value.toObject();
        const auto quality = option["id"].toString();
        if (!quality.isEmpty()) {
            values.append({quality, option["label"].toString(quality)});
        }
    }
    return values;
}

QString ProviderRegistry::defaultQuality(const QString &id) const {
    return m_descriptors.value(id)["quality"].toObject()["default"].toString();
}

QJsonObject ProviderRegistry::qualityDescription(const QString &id, const QString &quality) const {
    return m_descriptors.value(id)["quality"].toObject()["descriptions"].toObject()[quality].toObject();
}

QStringList ProviderRegistry::qualityFeatured(const QString &id) const {
    QStringList values;
    for (const auto &value : m_descriptors.value(id)["quality"].toObject()["featured"].toArray()) {
        if (value.isString()) {
            values.append(value.toString());
        }
    }
    return values;
}

QJsonArray ProviderRegistry::qualityExtras(const QString &id) const {
    return m_descriptors.value(id)["quality"].toObject()["extras"].toArray();
}

QString ProviderRegistry::qualityLabel(const QString &id, const QString &key, const QString &fallback) const {
    const auto value = m_descriptors.value(id)["quality"].toObject()["labels"].toObject().value(key);
    return value.isString() ? value.toString() : fallback;
}

bool ProviderRegistry::qualityBadgeBackground(const QString &id) const {
    return m_descriptors.value(id)["quality"].toObject()["badgeBackground"].toBool(false);
}

int ProviderRegistry::maxQueryLength(const QString &id, int fallback) const {
    const auto value = m_descriptors.value(id)["search"].toObject().value("maxQueryLength");
    return value.isDouble() ? value.toInt() : fallback;
}

QJsonArray ProviderRegistry::discoverTabs(const QString &id) const {
    return m_descriptors.value(id)["discover"].toObject()["tabs"].toArray();
}

QJsonArray ProviderRegistry::loginMethods(const QString &id) const {
    return m_descriptors.value(id)["login"].toObject()["methods"].toArray();
}

QJsonObject ProviderRegistry::loginMethod(const QString &id, const QString &method) const {
    for (const auto &value : loginMethods(id)) {
        const auto entry = value.toObject();
        if (entry["id"].toString() == method) {
            return entry;
        }
    }
    return {};
}

QJsonObject ProviderRegistry::stringTable(const QString &id) const {
    return m_descriptors.value(id)["strings"].toObject();
}

QString ProviderRegistry::text(const QString &id, const QString &key) const {
    return stringTable(id)[key].toString();
}

QString ProviderRegistry::providerForRoute(const QString &route) const {
    if (route.startsWith("/native/") || route.startsWith("/plugin/")) {
        const auto id = route.section('/', 2, 2);
        return m_descriptors.contains(id) ? id : QString();
    }
    const auto legacy = m_legacy.value(route);
    if (!legacy.isEmpty()) {
        return legacy;
    }
    QString matched;
    QString provider;
    for (auto it = m_prefixes.begin(); it != m_prefixes.end(); ++it) {
        if ((route == it.key() || route.startsWith(it.key() + "/")) && it.key().size() > matched.size()) {
            matched = it.key();
            provider = it.value();
        }
    }
    return provider;
}

QJsonObject ProviderRegistry::cachePolicy(const QString &id) const {
    return m_manifests.value(id)["cache"].toObject();
}

QJsonObject ProviderRegistry::credentialPolicy(const QString &id) const {
    return m_manifests.value(id)["credentials"].toObject();
}

QJsonObject ProviderRegistry::runtimeConfig(const QString &id) const {
    return m_manifests.value(id)["runtime"].toObject();
}

QJsonObject ProviderRegistry::externalPlayback(const QString &id) const {
    const auto manifest = m_manifests.value(id);
    return manifest["externalPlayback"].isObject() ? manifest["externalPlayback"].toObject()
                                                    : m_descriptors.value(id)["externalPlayback"].toObject();
}

QJsonObject ProviderRegistry::mediaPolicy(const QString &id) const {
    const auto manifest = m_manifests.value(id);
    return manifest["media"].isObject() ? manifest["media"].toObject()
                                         : m_descriptors.value(id)["media"].toObject();
}

QJsonArray ProviderRegistry::variants(const QString &id) const {
    const auto manifest = m_manifests.value(id);
    const auto credentials = manifest["credentials"].toObject();
    if (credentials["variants"].isArray()) {
        return credentials["variants"].toArray();
    }
    return m_descriptors.value(id)["variants"].toArray();
}

QString ProviderRegistry::variantPreference(const QString &id) const {
    const auto credentials = m_manifests.value(id)["credentials"].toObject();
    return credentials["variantPreference"].toString(
        m_descriptors.value(id)["variantPreference"].toString());
}

int ProviderRegistry::diagnosticsOrdinal(const QString &id, int fallback) const {
    const auto runtime = m_manifests.value(id)["runtime"].toObject();
    return runtime["diagnosticsOrdinal"].toInt(
        m_descriptors.value(id)["runtime"].toObject()["diagnosticsOrdinal"].toInt(fallback));
}

namespace {
QStringList mediaHosts(const QJsonObject &media, const char *key) {
    QStringList values;
    for (const auto &value : media[key].toArray()) {
        if (value.isString()) {
            values.append(value.toString());
        }
    }
    return values;
}

QStringList allMediaHosts(const QHash<QString, QJsonObject> &descriptors, const char *key) {
    QStringList values;
    for (const auto &descriptor : descriptors) {
        for (const auto &host : mediaHosts(descriptor["media"].toObject(), key)) {
            if (!values.contains(host)) {
                values.append(host);
            }
        }
    }
    return values;
}
}

QStringList ProviderRegistry::coverHosts() const {
    return allMediaHosts(m_descriptors, "coverHosts");
}

QStringList ProviderRegistry::playbackHosts() const {
    return allMediaHosts(m_descriptors, "hosts");
}

QStringList ProviderRegistry::alternativeHosts() const {
    return allMediaHosts(m_descriptors, "alternativeHosts");
}

void ProviderRegistry::indexRoutes() {
    m_legacy.clear();
    m_prefixes.clear();
    for (auto it = m_manifests.begin(); it != m_manifests.end(); ++it) {
        const auto routes = it.value()["routes"].toObject();
        for (const auto &route : routes["legacyRoutes"].toArray()) {
            if (route.isString() && !m_legacy.contains(route.toString())) {
                m_legacy.insert(route.toString(), it.key());
            }
        }
        for (const auto &route : routes["prefixes"].toArray()) {
            if (route.isString() && !m_prefixes.contains(route.toString())) {
                m_prefixes.insert(route.toString(), it.key());
            }
        }
    }
}

void ProviderRegistry::loadDirectory(const QString &directory, bool overwrite) {
    QDir dir(directory);
    if (!dir.exists()) {
        return;
    }
    const auto files = dir.entryInfoList({"*.json"}, QDir::Files, QDir::Name);
    for (const auto &file : files) {
        QFile handle(file.absoluteFilePath());
        if (!handle.open(QIODevice::ReadOnly)) {
            continue;
        }
        const auto value = QJsonDocument::fromJson(handle.readAll()).object();
        if (!validDescriptor(value)) {
            continue;
        }
        const auto id = value["id"].toString();
        if (m_disabled.contains(id)) {
            continue;
        }
        if (overwrite || !m_descriptors.contains(id)) {
            m_descriptors.insert(id, value);
        }
    }
}

void ProviderRegistry::loadManifestFallback(const QString &directory) {
    if (directory.isEmpty()) {
        return;
    }
    QDir dir(directory);
    if (!dir.exists()) {
        return;
    }
    const auto entries = dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const auto &entry : entries) {
        if (entry.fileName().startsWith('.') || entry.fileName() == "sdk" ||
            entry.fileName() == "node_modules") {
            continue;
        }
        QFile handle(entry.absoluteFilePath() + "/manifest.json");
        if (!handle.open(QIODevice::ReadOnly)) {
            continue;
        }
        const auto manifest = QJsonDocument::fromJson(handle.readAll()).object();
        const auto id = manifest["id"].toString();
        if (id.isEmpty() || id == "local" || id == "siren" || m_disabled.contains(id) ||
            !validManifest(manifest) ||
            !QFileInfo(entry.absoluteFilePath() + "/" + manifest["entry"].toObject()["file"].toString())
                 .isFile()) {
            continue;
        }
        if (m_descriptors.contains(id)) {
            if (!m_manifests.contains(id)) {
                m_manifests.insert(id, manifest);
            }
            continue;
        }
        if (!m_manifests.contains(id)) {
            m_manifests.insert(id, manifest);
        }
        QJsonObject value;
        for (const auto &field : descriptorFields) {
            if (!manifest[field].isUndefined()) {
                value[field] = manifest[field];
            }
        }
        value["schemaVersion"] = 2;
        if (validDescriptor(value)) {
            m_descriptors.insert(id, value);
        }
    }
}

void ProviderRegistry::addBuiltin(const QString &id, const QString &name, const QString &label,
                                  const QString &detail, const QString &sessionLabel, int order) {
    if (m_descriptors.contains(id)) {
        return;
    }
    const QJsonObject capabilities{{"search", true}, {"detail", true},   {"playback", true},
                                   {"lyrics", true}, {"account", false}, {"login", false}};
    QJsonArray columns{"搜索结果", "喜欢的歌曲", "我的歌单", "全部歌曲", "全部专辑"};
    QJsonArray qualityOptions{QJsonObject{{"id", "lossless"}, {"label", "官网原始音源"}}};
    QString defaultQuality = "lossless";
    if (id == "local") {
        columns = QJsonArray{"本地检索", "全部歌曲", "文件夹", "本地专辑", "本地歌手"};
        qualityOptions = QJsonArray{QJsonObject{{"id", "original"}, {"label", "本地文件"}}};
        defaultQuality = "original";
    }
    m_descriptors.insert(
        id, QJsonObject{{"schemaVersion", 2},
                        {"id", id},
                        {"display", QJsonObject{{"name", name},
                                                {"label", label},
                                                {"detail", detail},
                                                {"sessionLabel", sessionLabel},
                                                {"order", order},
                                                {"default", false}}},
                        {"capabilities", capabilities},
                        {"library", QJsonObject{{"columns", columns}, {"lanes", 5}}},
                        {"quality", QJsonObject{{"default", defaultQuality}, {"options", qualityOptions}}}});
}
