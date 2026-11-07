#pragma once
#include "AudioPlayer.h"
#include "PlatformFeatures.h"
#include "PlaybackDiagnostics.h"
#include "AppUpdater.h"
#include <QCache>
#include <QImage>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include "BridgeProcess.h"
#include "PlaybackConnection.h"
#include <QQueue>
#include <QTemporaryDir>
#include <QTimer>
#include <functional>

// 系统边界：只通过管道调用锁定的上游；凭据不进入参数、环境或日志。
class Host : public QObject {
    Q_OBJECT
  public:
    using JsonReply = std::function<void(QJsonObject, QString)>;
    using TextReply = std::function<void(QString)>;
    explicit Host(QString root, bool offline = false, QObject *parent = nullptr, bool playbackOnly = false,
                  PlaybackConnection *connection = nullptr);
    ~Host() override;
    void requestJson(QString route, QJsonObject params, JsonReply callback);
    void schedule(int ms, std::function<void()> callback);
    void loadCover(QString url, TextReply callback, int maximumDimension = 1024, bool allowPlaybackOnly = false);
    void playOfficial(QString id, TextReply callback);
    Q_INVOKABLE void invalidate() {
        emit invalidated();
    }
    Q_INVOKABLE bool authenticated() const;
    Q_INVOKABLE bool hasCredential(QString value) const;
    Q_INVOKABLE QString saveCredential();
    Q_INVOKABLE void logout();
    Q_INVOKABLE void setProvider(QString provider);
    Q_INVOKABLE void setKugouEdition(QString edition);
    Q_INVOKABLE void acceptCookies(QString json, int responseEpoch, QString credentialKey = {});
    Q_INVOKABLE QString fromLink(QString input) const;
    Q_INVOKABLE QString qr(QString key);
    Q_INVOKABLE QString qrImage(QString data);
    Q_INVOKABLE void mediaMetadata(QString title, QString artist, QString album,
                                   const QString &coverUrl = {});
    Q_INVOKABLE bool mediaLoad(QString url, bool alternative = false, double position = 0,
                               bool paused = false);
    Q_INVOKABLE void mediaControl(QString action, double value = 0);
    Q_INVOKABLE QVariantMap mediaState() const;
    Q_INVOKABLE void copy(QString text);
    Q_INVOKABLE void open(QString url);
    Q_INVOKABLE QString modifierKey() const {
#ifdef Q_OS_DARWIN
        return QStringLiteral("⌘");
#else
        return QStringLiteral("Ctrl");
#endif
    }
    Q_INVOKABLE bool systemDark() const;
    Q_INVOKABLE void invalidateMetadata();
    Q_INVOKABLE void clearCache();
    Q_INVOKABLE QString preference(QString key) const;
    Q_INVOKABLE void setPreference(QString key, QString value);
    // 设置 Schema 与回归测试共用同一份偏好键白名单。
    static bool isPreferenceKey(const QString &key);
    Q_INVOKABLE bool activates() const;
    Q_INVOKABLE void setActivates(bool value);
    Q_INVOKABLE QString asset(QString name) const;
    Q_INVOKABLE QString read(QString name) const;
    QImage image(const QString &key) const;
    void fixtureImage(const QString &key, const QImage &image);
    PlaybackDiagnostics playbackDiagnostics;
    void enablePlaybackDiagnostics(bool enabled);
    QJsonObject playbackSnapshot() const;
    AppUpdater updater;
    QString root;
    bool offline;
    std::function<QJsonObject(QString, QJsonObject)> fixture;
    QJsonObject cookies;
    int epoch = 0;
    int interval = 1200;
    static int lifetime(const QString &route);
    static QString cacheKey(QString scope, QString route, QJsonObject params);
    void shutdown();
    PlaybackConnection *playbackConnection() const {
        return remote;
    }
    void trimMemory(const QStringList &retainedImages);
    void restoreMemoryBudget() {
        images.setMaxCost(32 * 1024);
    }

  signals:
    void preferenceChanged(QString key, QString value);
    void mediaAction(QString action);
    void mediaChanged();
    void audioSpectrumChanged(QJsonArray levels);
    void playbackDiagnostic(QString event, QJsonObject values);
    void invalidated();

  private:
    friend class AudioPlayerRegression;
    struct Waiter {
        JsonReply callback;
        int epoch;
    };
    struct CoverWaiter {
        TextReply callback;
        int epoch;
    };
    struct Work {
        QString id, route, key;
        QJsonObject params, cookies;
        QList<Waiter> waiters;
        bool disk = false;
        int cacheRevision = 0;
    };
    struct Entry {
        qint64 expiry;
        QJsonObject body;
    };
    QHash<QString, QList<CoverWaiter>> coverFlights;
    QHash<QString, Entry> cache;
    QHash<QString, Work> flights;
    QHash<QString, QString> pending;
    QQueue<QString> queue;
    BridgeProcess child;
    std::unique_ptr<AudioPlayer> audio;
    std::unique_ptr<QTemporaryDir> temporary;
    QByteArray buffer;
    QString mediaTitle, mediaArtist, mediaAlbum;
    /** 系统媒体控件的封面：URL 是 QML 上报的原始地址，Path 是下载到私有缓存的落盘结果。 */
    QString mediaCoverUrl, mediaCoverPath;
    void refreshMediaCover();
    int metadataRevision = 0;
    mutable qint64 lastMediaUpdate = 0;
    QNetworkAccessManager network;
    mutable QCache<QString, QImage> images{32 * 1024};
    qint64 lastStart = 0;
    QHash<QString, qint64> blockedUntil;
    QHash<QString, QJsonObject> privateCredentials;
    QString provider = "netease";
    QString kugouEdition = "standard";
    QString active;
    bool stopped = false;
    bool audioDiagnosticsEnabled = false;
    bool audioSpectrumEnabled = false;
    PlaybackConnection *remote = nullptr;
    mutable QHash<QString, QString> remotePreferences;
    bool playbackOnly = false;
    int diagnosticRequestSerial = 0;
    void pump();
    void recordPlaybackDiagnostic(const QString &event, const QJsonObject &values);
    void send(QString key);
    void finish(QString key, QJsonObject response, QString error = {});
    void respond(const Waiter &waiter, QJsonObject response, QString error);
    QString diskPath(QString key) const;
};
QByteArray platformCredential();
QString platformSaveCredential(const QByteArray &data);
void platformDeleteCredential();
QImage platformQR(const QString &text);
void platformPlay(const QString &id, bool activate, std::function<void(QString)> done);
bool platformActivates();
void platformSetActivates(bool value);

void platformMediaCommands(std::function<void(QString)> callback);
void platformMediaInfo(QString title, QString artist, QString album, QVariantMap state,
                       const QString &coverPath = {});
#ifdef Q_OS_MACOS
void platformInterfaceMediaCommands(std::function<void(QString)> callback);
void platformInterfaceMediaInfo(bool hasTrack);
#endif
