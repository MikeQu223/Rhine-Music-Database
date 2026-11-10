#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>

namespace MusicData {
QJsonObject item(QString kind, QString id, QString title = "正在读取…", QString artist = "",
                 QString provider = {});
QJsonObject parse(const QJsonObject &raw, const QString &kind);
QJsonArray unique(const QJsonArray &existing, const QJsonArray &values);
QJsonArray ordered(const QJsonArray &ids, const QJsonArray &songs);
QJsonArray slice(const QJsonArray &values, qsizetype start, qsizetype count);
QVector<int> sortOrder(const QJsonArray &values, const QString &field);
int cursor(const QJsonArray &songs, const QJsonArray &ids);
int indexOf(const QJsonArray &values, const QJsonValue &value);
int indexOfId(const QJsonArray &values, const QString &id);
QString pad(int value, int width = 2);
QString time(const QJsonObject &track);
}
