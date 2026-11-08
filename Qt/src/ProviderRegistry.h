#pragma once
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QPair>
#include <QString>
#include <QStringList>
#include <QVector>

/**
 * Qt 侧只读取插件的纯数据 descriptor；入口、签名和凭据配置不进入 UI。
 * descriptor 在桥启动前从构建产物加载，桥不可用时 UI 仍能启动。
 */
class ProviderRegistry {
  public:
    static ProviderRegistry &instance();
    void load(const QString &root);
    bool loaded() const;
    QStringList ids() const;
    bool contains(const QString &id) const;
    QJsonObject descriptor(const QString &id) const;
    QString name(const QString &id) const;
    QString label(const QString &id) const;
    QString detail(const QString &id) const;
    QString sessionLabel(const QString &id) const;
    QString archivePrefix(const QString &id) const;
    QString nameForVariant(const QString &id, const QString &variant) const;
    QString defaultId() const;
    QString fallbackId(const QString &exclude = {}) const;
    bool capability(const QString &id, const QString &key, bool fallback = true) const;
    QStringList columns(const QString &id) const;
    QVector<int> sourceOrder(const QString &id) const;
    int lanes(const QString &id) const;
    QVector<QPair<QString, QString>> qualityOptions(const QString &id) const;
    QJsonObject qualityDescription(const QString &id, const QString &quality) const;
    QStringList qualityFeatured(const QString &id) const;
    QJsonArray qualityExtras(const QString &id) const;
    QString qualityLabel(const QString &id, const QString &key, const QString &fallback = {}) const;
    bool qualityBadgeBackground(const QString &id) const;
    QString defaultQuality(const QString &id) const;
    int maxQueryLength(const QString &id, int fallback = 100) const;
    QJsonArray discoverTabs(const QString &id) const;
    QJsonArray loginMethods(const QString &id) const;
    QJsonObject loginMethod(const QString &id, const QString &method) const;
    QJsonObject stringTable(const QString &id) const;
    QString text(const QString &id, const QString &key) const;

  private:
    void loadDirectory(const QString &directory);
    void loadManifestFallback(const QString &directory);
    void addBuiltin(const QString &id, const QString &name, const QString &label, const QString &detail,
                    const QString &sessionLabel, int order);
    QHash<QString, QJsonObject> m_descriptors;
    QString m_root;
    bool m_loaded = false;
};
