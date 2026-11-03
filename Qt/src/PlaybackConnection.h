#pragma once
#include <QtGlobal>
#include "MobileTarget.h"
#include <QHash>
#include <QJsonObject>
#include <QLocalSocket>
#include <QObject>
#include <functional>

/** 用户私有的本地连接；GUI 只保存服务快照，不持有解码器或服务进程。 */
class PlaybackConnection : public QObject {
    Q_OBJECT
  public:
    static constexpr int ProtocolVersion = 3;
    using Reply = std::function<void(QJsonObject, QString)>;
    explicit PlaybackConnection(QObject *parent = nullptr);
    ~PlaybackConnection() override;
    bool connectToService(const QString &endpoint, int timeoutMs = 1000);
    QJsonObject call(const QString &method, QJsonObject arguments = {}, int timeoutMs = 5000);
    void request(const QString &method, QJsonObject arguments, Reply reply);
    const QJsonObject &snapshot() const;
    QString error() const;
    static QString endpoint();
    static QString serviceExecutable();

  signals:
    void snapshotChanged();
    void activateRequested();
    void quitRequested();
#ifdef Q_OS_LINUX
    /// 后台服务要求按新配置重建界面（图形后端切换）：
    /// 收到后界面进程应自行退出，但**不能**通知服务一起退出——服务要靠自己重新拉起新界面。
    void restartRequested();
#endif
    void disconnected();
    void diagnosticEvent(QString event, QJsonObject values);

  private:
    void readMessages();
    void failPending(const QString &message);
    QLocalSocket m_socket;
    QByteArray m_buffer;
    QHash<QString, Reply> m_pending;
    QJsonObject m_snapshot;
    QString m_error;
    quint64 m_serial = 0;
};

#if !RHINE_MOBILE
/**
 * 连接同一用户的唯一服务；没有运行时按需拉起后台 helper，
 * 并校验协议版本，避免新版界面连到旧版服务。
 */
bool connectPlaybackService(PlaybackConnection &connection, const QString &root, QString &error);
#endif
