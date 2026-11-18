#pragma once
#include <QtGlobal>
#include "MusicPlayer.h"
#include "InterfaceSession.h"
#include <QLocalServer>
#include <QLocalSocket>
#include <QTimer>
#include <QPointer>
#include <memory>

/** 音频与协议的唯一所有者；此对象不创建窗口、QML 引擎、场景或图形设备。 */
class PlaybackService : public QObject {
    Q_OBJECT
  public:
    PlaybackService(QString root, QString guiExecutable, bool offline, QObject *parent = nullptr);
    ~PlaybackService() override;
    bool listen(const QString &endpoint);
    void showInterface();
    void shutdown();

  private:
    class SessionWriter;
    struct Client {
        QByteArray buffer;
        QJsonObject previous;
    };
    Host m_host;
    MusicApi m_api;
    MusicPlayer m_player;
    StorageCoordinator m_storage;
    QLocalServer m_server;
    QHash<QLocalSocket *, Client> m_clients;
    QPointer<QLocalSocket> m_gui;
#ifdef Q_OS_LINUX
    /// 当前界面进程启动时解析出的图形后端；与本次启动的解析结果不同即需要重建界面。
    QString m_guiBackend;
    bool m_restartingInterface = false;
#endif
    InterfaceSession m_interfaceSession;
    QTimer m_poll;
    QTimer m_save;
    // 会话落盘可能被慢盘或病毒扫描拖到数百毫秒，不能占用音频泵所在线程。
    std::unique_ptr<SessionWriter> m_sessionWriter;
    QElapsedTimer m_clock;
    int m_selectionSerial = 0;
    QJsonObject m_selectedTrack;
    bool m_stopping = false;
    void read(QLocalSocket *socket);
    void dispatch(QLocalSocket *socket, const QJsonObject &request);
    QJsonObject hostCommand(const QString &method, const QJsonObject &arguments, bool &known);
    bool playerCommand(const QString &method, const QJsonObject &arguments);
    bool lyricsCommand(const QString &method, const QJsonObject &arguments);
    void send(QLocalSocket *socket, const QJsonObject &message);
    void publish();
    void restoreSession();
    void saveSession();
};
