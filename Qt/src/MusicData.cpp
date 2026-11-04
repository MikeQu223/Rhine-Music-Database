#include "MusicData.h"
#include <QCollator>
#include <QDateTime>
#include <QLocale>
#include <QRegularExpression>
#include <QSet>
#include <algorithm>

namespace {
QString identifier(const QJsonValue &value) {
    if (value.isString()) {
        return value.toString();
    }
    if (value.isDouble()) {
        return QString::number(value.toInteger());
    }
    return {};
}
}

namespace MusicData {
QJsonObject item(QString kind, QString id, QString title, QString artist, QString provider) {
    return {{"kind", kind},
            {"id", id},
            {"title", title},
            {"artist", artist},
            {"artists", QJsonArray{}},
            {"creatorID", ""},
            {"albumID", ""},
            {"album", ""},
            {"cover", ""},
            {"description", ""},
            {"wiki", ""},
            {"date", ""},
            {"duration", 0},
            {"trackCount", 0},
            {"provider", provider},
            {"key", provider + ":" + kind + ":" + id}};
}

QJsonObject parse(const QJsonObject &raw, const QString &kind) {
    const auto id = identifier(raw["id"]);
    static const QRegularExpression pattern(QStringLiteral("^[0-9]{1,20}$"));
    if (!pattern.match(id).hasMatch() || !raw["name"].isString()) {
        return {};
    }
    auto artists = raw["ar"].toArray();
    if (raw["ar"].isNull() || raw["ar"].isUndefined()) {
        artists = raw["artists"].toArray();
        if ((raw["artists"].isNull() || raw["artists"].isUndefined()) && raw["artist"].isObject()) {
            artists = QJsonArray{raw["artist"]};
        }
    }
    const auto creator = raw["creator"].toObject();
    const auto album = raw["al"].isObject() ? raw["al"].toObject() : raw["album"].toObject();
    QStringList names;
    QJsonArray entries;
    for (const auto &value : artists) {
        const auto artist = value.toObject();
        if (artist["name"].isString()) {
            names.append(artist["name"].toString());
            entries.append(QJsonObject{{"id", identifier(artist["id"])}, {"name", artist["name"]}});
        }
    }
    auto value = item(kind, id, raw["name"].toString(),
                      kind == "playlist" ? creator["nickname"].toString("暂无创建者") : names.join(" / "));
    value["artists"] = entries;
    value["creatorID"] = identifier(creator["userId"]);
    value["albumID"] = identifier(album["id"]);
    value["album"] = album["name"].toString();
    value["cover"] = raw["picUrl"].toString(raw["coverImgUrl"].toString(album["picUrl"].toString()));
    value["duration"] = raw["dt"].toDouble(raw["duration"].toDouble());
    if (kind == "song" && (raw.contains("mv") || raw.contains("mvid"))) {
        const auto mv = identifier(raw.contains("mv") ? raw["mv"] : raw["mvid"]);
        value["mvID"] = mv == "0" ? QString() : mv;
    }
    value["trackCount"] = raw["trackCount"].toDouble(raw["size"].toDouble());
    value["description"] = raw["description"].toString(raw["briefDesc"].toString());
    if (raw["publishTime"].toDouble() > 0) {
        value["date"] =
            QDateTime::fromMSecsSinceEpoch(raw["publishTime"].toInteger()).date().toString("yyyy-MM-dd");
    }
    return value;
}

QJsonArray unique(const QJsonArray &existing, const QJsonArray &values) {
    QSet<QString> keys;
    for (const auto &value : existing) {
        keys.insert(value.toObject()["key"].toString());
    }
    auto result = existing;
    for (const auto &value : values) {
        const auto key = value.toObject()["key"].toString();
        if (!keys.contains(key)) {
            keys.insert(key);
            result.append(value);
        }
    }
    return result;
}

QJsonArray ordered(const QJsonArray &ids, const QJsonArray &songs) {
    QHash<QString, QJsonObject> entries;
    for (const auto &value : songs) {
        const auto song = value.toObject();
        const auto id = song["id"].toString();
        if (!entries.contains(id)) {
            entries.insert(id, song);
        }
    }
    QJsonArray result;
    for (const auto &id : ids) {
        if (entries.contains(id.toString())) {
            result.append(entries[id.toString()]);
        }
    }
    return result;
}

QJsonArray slice(const QJsonArray &values, qsizetype start, qsizetype count) {
    QJsonArray result;
    const auto end = std::min(values.size(), start + count);
    for (auto i = std::max(qsizetype(0), start); i < end; ++i) {
        result.append(values.at(i));
    }
    return result;
}

int indexOf(const QJsonArray &values, const QJsonValue &value) {
    for (qsizetype i = 0; i < values.size(); ++i) {
        if (values.at(i) == value) {
            return int(i);
        }
    }
    return -1;
}

int indexOfId(const QJsonArray &values, const QString &id) {
    for (qsizetype i = 0; i < values.size(); ++i) {
        if (values.at(i).toObject()["id"].toString() == id) {
            return int(i);
        }
    }
    return -1;
}

int cursor(const QJsonArray &songs, const QJsonArray &ids) {
    const auto index = songs.isEmpty() ? -1 : indexOf(ids, songs.last().toObject()["id"]);
    return index < 0 ? int(songs.size()) : index + 1;
}

QString pad(int value, int width) {
    return QString::number(value).rightJustified(width, QLatin1Char('0'));
}

QString time(const QJsonObject &track) {
    const auto duration = track["duration"].toDouble();
    if (duration <= 0) {
        return QStringLiteral("暂无");
    }
    return pad(int(duration / 60000)) + ":" + pad(int(duration / 1000) % 60);
}
}

/** 返回稳定的显示索引；空名称排在末尾，相同名称保留接口原序，不改写原始曲目。 */
QVector<int> MusicData::sortOrder(const QJsonArray &values, const QString &field) {
    QVector<int> indices;
    for (int index = 0; index < values.size(); ++index) {
        indices.append(index);
    }
    if (!QStringList{"title", "album", "artist"}.contains(field)) {
        return indices;
    }
    QCollator collator(QLocale("zh_CN"));
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    collator.setNumericMode(true);
    QStringList names;
    for (const auto &value : values) {
        names.append(value.toObject()[field].toString().trimmed());
    }
    std::stable_sort(indices.begin(), indices.end(), [&names, &collator](int left, int right) {
        if (names[left].isEmpty() != names[right].isEmpty()) {
            return !names[left].isEmpty();
        }
        return collator.compare(names[left], names[right]) < 0;
    });
    return indices;
}
