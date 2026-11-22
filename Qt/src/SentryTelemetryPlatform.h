#pragma once

#include <QJsonObject>
#include <QString>

namespace RhineSentry::Platform {

struct Config {
    QString dsn;
    QString environment;
    QString release;
    QString version;
    QString databaseDirectory;
    QString role;
    QString userId;
    double tracesSampleRate;
    bool requireUserConsent = true;
};

bool start(const Config &config);
void stop(bool revoked);
void record(const char *category, const char *name);
void failure(const QString &stage, const QString &code, const QJsonObject &details);
void pluginInstallFailure(const QString &phase, const QString &code, const QJsonObject &details);
void startup(qint64 milliseconds);
void *beginTrace(const char *name, const char *operation);
void finishTrace(void *trace, bool completed, bool successful);
void setContext(const char *key, const QJsonObject &value);

}
