#pragma once
#include "Host.h"
#include <QJsonArray>
#include <QJsonValue>
#include <QSet>

struct MusicReply {
    QJsonValue value;
    QString error;
    QJsonObject failure;
    bool ok() const {
        return error.isEmpty();
    }
};

class MusicApi : public QObject {
  public:
    using Reply = std::function<void(MusicReply)>;
    using Valid = std::function<bool()>;
    explicit MusicApi(Host *host, QObject *parent = nullptr);
    QString provider;
    void call(QString operation, QJsonArray arguments, Reply callback, Valid valid = [] { return true; });
    static QString providerName(const QString &provider);
    static QJsonObject safeFailure(const QJsonObject &body, bool includePrevious = true);

  private:
    Host *m_host;
    void send(QString route, QJsonObject parameters, bool adapted, Reply callback, Valid valid,
              QSet<int> allowed);
};
