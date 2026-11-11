#pragma once
#include <QtGlobal>
#include "MobileTarget.h"
#if !RHINE_MOBILE
#include <QProcess>
using BridgeProcess = QProcess;
#else
#include <QJsonObject>
#include <QObject>

// 移动端没有可执行文件可以 fork：Node 以常驻运行时（iOS 为 NodeMobile.framework，
// Android 为 libnode.so）编进进程，Worker 按会话创建、销毁，不共享模块与环境变量。
class BridgeProcess : public QObject {
    Q_OBJECT
  public:
    enum ProcessState { NotRunning, Starting, Running };
    enum ProcessError { FailedToStart, Crashed, UnknownError };
    explicit BridgeProcess(QObject *parent = nullptr);
    ~BridgeProcess() override;
    void start(const QString &root, const QString &temporary,
               const QJsonObject &environment = QJsonObject{});
    void write(const QByteArray &bytes);
    QByteArray readAllStandardOutput();
    void kill();
    void terminate();
    void closeWriteChannel();
    bool waitForFinished(int);
    ProcessState state() const {
        return m_state;
    }
    ProcessError error() const {
        return m_error;
    }
    void accept(const QJsonObject &message);

  signals:
    void started();
    void errorOccurred(ProcessError error);
    void readyReadStandardOutput();
    void finished();

  private:
    ProcessState m_state = NotRunning;
    ProcessError m_error = UnknownError;
    QString m_session;
    QByteArray m_output;
};
#endif
