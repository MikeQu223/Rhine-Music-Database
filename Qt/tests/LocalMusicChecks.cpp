#include "LocalMusicLibrary.h"
#include "MusicLibrary.h"
#include "ProviderRegistry.h"
#include "NativeHud.h"
#include <QCoreApplication>
#include <QDataStream>
#include <QDir>
#include <QFileInfo>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QThread>
#include <QUrl>
#include <cmath>

namespace {
bool waitFor(const std::function<bool()> &ready, int timeout = 10000) {
    QElapsedTimer elapsed;
    elapsed.start();
    while (!ready() && elapsed.elapsed() < timeout) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}
bool write(const QString &path, const QByteArray &content) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(content) == content.size();
}
QByteArray chunk(const char *name, QByteArray payload) {
    QByteArray bytes;
    QDataStream stream(&bytes, QIODevice::WriteOnly);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData(name, 4);
    stream << quint32(payload.size());
    stream.writeRawData(payload.constData(), payload.size());
    if (payload.size() % 2) {
        stream << quint8(0);
    }
    return bytes;
}
/** 生成真实 PCM 与 RIFF INFO 标签，直接验证本地索引和标签解析，不依赖在线音乐或用户文件。 */
QByteArray wave(QString title) {
    QByteArray format;
    QDataStream stream(&format, QIODevice::WriteOnly);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream << quint16(1) << quint16(1) << quint32(8000) << quint32(16000) << quint16(2) << quint16(16);
    QByteArray samples;
    QDataStream pcm(&samples, QIODevice::WriteOnly);
    pcm.setByteOrder(QDataStream::LittleEndian);
    for (int i = 0; i < 32000; ++i) {
        pcm << qint16(800 * std::sin(i * 440.0 * 2 * 3.141592653589793 / 8000));
    }
    const auto info = QByteArray("INFO") + chunk("INAM", title.toUtf8() + '\0') +
                      chunk("IART", QByteArray("Fixture Artist\0", 15)) +
                      chunk("IPRD", QByteArray("Fixture Album\0", 14));
    const auto body =
        QByteArray("WAVE") + chunk("fmt ", format) + chunk("LIST", info) + chunk("data", samples);
    return chunk("RIFF", body);
}
QJsonObject document(QString source = "remote") {
    return {{"version", 1},
            {"source", source},
            {"timing", "line"},
            {"offsetMs", 0},
            {"plainText", ""},
            {"lines", QJsonArray{QJsonObject{{"startMs", 0}, {"text", "one"}},
                                 QJsonObject{{"startMs", 1000}, {"text", "two"}}}}};
}
}

int main(int argc, char **argv) {
    qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    QGuiApplication app(argc, argv);
    if (argc < 2) {
        return 1;
    }
    bool ok = true;
    const auto check = [&](bool result, const char *name) {
        if (!result) {
            qCritical() << "Local music regression:" << name;
            ok = false;
        }
    };
    // 可选真实目录验收始终使用临时索引，不写回或移动用户音乐。
    if (argc >= 3) {
        QTemporaryDir realStorage;
        LocalMusicLibrary real(realStorage.path());
        real.importPaths({app.arguments().at(2)});
        check(waitFor([&] { return !real.busy; }, 120000), "real directory scan completes");
        const auto tracks = real.songs();
        check(!tracks.isEmpty(), "real directory contains valid tracks");
        int covers = 0;
        int lyrics = 0;
        for (const auto &value : tracks) {
            const auto track = value.toObject();
            covers += !track["cover"].toString().isEmpty();
            const auto path = track["path"].toString();
            lyrics += QFileInfo::exists(QFileInfo(path).absolutePath() + '/' +
                                        QFileInfo(path).completeBaseName() + ".lrc");
            check(track["duration"].toInt() > 0 && track["sampleRate"].toInt() > 0,
                  "real track has valid duration and sample rate");
            check(!real.search(track["title"].toString(), "song").isEmpty(), "real local title search");
        }
        real.rescan();
        check(waitFor([&] { return !real.busy; }, 120000) && real.songs() == tracks,
              "real incremental scan preserves index");
        qInfo() << "REAL LIBRARY tracks" << tracks.size() << "covers" << covers << "sidecars" << lyrics
                << real.status;
        return ok ? 0 : 1;
    }
    QTemporaryDir temporary;
    const auto untagged = temporary.filePath("Singer,Guest - Untagged.wav");
    check(write(untagged, wave("")), "create filename fallback fixture");
    LocalMusicLibrary filenameLibrary({}, true);
    filenameLibrary.importPaths({untagged});
    check(waitFor([&] { return !filenameLibrary.busy; }), "filename fixture indexed");
    const auto inferred = filenameLibrary.songs().first().toObject();
    check(inferred["title"] == "Untagged", "missing title inferred from filename");
    const auto root = temporary.filePath("music");
    const auto storage = temporary.filePath("index");
    const auto first = root + "/album/one.wav";
    check(write(first, wave("First Song")), "create tagged fixture");
    check(write(root + "/album/two.wav", wave("Second Song")), "create nested fixture");
    check(write(root + "/album/skipped.wav", wave("Skip")), "create ignored fixture");
    check(write(root + "/album/bad.mp3", "not audio"), "create invalid fixture");
    check(write(root + "/.foliaignore", "**/skipped.wav\n*.wav\n!**/one.wav\n!**/two.wav\n"),
          "create ordered ignore rules");
    QImage cover(64, 64, QImage::Format_RGB32);
    cover.fill(Qt::darkGreen);
    check(cover.save(root + "/album/cover.png"), "create folder cover");
    LocalMusicLibrary local(storage);
    local.importPaths({root, root + "/album"});
    check(waitFor([&] { return !local.busy; }), "background import completes");
    check(local.songs().size() == 2 && local.roots().size() == 2, "recursive import and overlapping dedupe");
    const auto song = local.search("First", "song").first().toObject();
    check(song["title"] == "First Song" && song["artist"] == "Fixture Artist" &&
              song["album"] == "Fixture Album" && song["duration"].toInt() == 4000,
          "real TagLib metadata");
    check(!song["cover"].toString().isEmpty() && local.collections("album").size() == 1 &&
              local.collections("folder").size() == 1 && local.collections("artist").size() == 1,
          "cover asset and distinct collection types");
    qInfo() << "Indexed tracks:" << local.songs().size() << local.status;
    const auto originalId = song["id"];
    local.importPaths({root});
    check(waitFor([&] { return !local.busy; }) && local.roots().size() == 2 &&
              local.status.contains("复用 2"),
          "repeat import reuses unchanged metadata");
    check(write(first, wave("Changed Song")), "modify audio tags");
    check(QFile::remove(root + "/album/two.wav"), "remove fixture file");
    local.rescan();
    check(waitFor([&] { return !local.busy; }) && local.songs().size() == 1 &&
              local.songs().first().toObject()["title"] == "Changed Song" &&
              local.songs().first().toObject()["id"] == originalId,
          "incremental update and deleted file removal preserve path identity");
    LocalMusicLibrary restored(storage);
    check(restored.songs() == local.songs(), "index survives restart");
    check(QDir().rename(root, root + "-away"), "simulate unavailable root");
    local.rescan();
    check(waitFor([&] { return !local.busy; }) && local.songs().size() == 1 &&
              local.status.contains("不可访问"),
          "unavailable root retains old index");
    check(QDir().rename(root + "-away", root), "restore root");
    local.rescan();
    local.cancel();
    check(!local.busy && local.songs().size() == 1, "cancel preserves committed index");
    local.removeRoot(0);
    check(local.songs().size() == 1 && QFileInfo::exists(first), "overlapping root retains referenced song");
    local.removeRoot(0);
    check(local.songs().isEmpty() && QFileInfo::exists(first), "remove only index, retain original audio");

    Host host(app.arguments().at(1), true);
    QFile sceneContent(host.root + "/slots.json");
    check(sceneContent.open(QIODevice::ReadOnly), "load independent scene content");
    MusicLibrary music(&host, QJsonDocument::fromJson(sceneContent.readAll()).object());
    QStringList remoteProviders;
    for (const auto &id : ProviderRegistry::instance().ids()) {
        if (id != "local" && id != "siren") {
            remoteProviders.append(id);
        }
    }
    const auto remoteProvider = remoteProviders.value(0);
    QStringList requests;
    bool missingFirstCover = false;
    host.fixture = [&](QString route, QJsonObject values) {
        requests.append(route);
        if (route == "/local/lyrics") {
            check(values.contains("contentBase64") &&
                      QByteArray::fromBase64(values["contentBase64"].toString().toLatin1())
                          .contains("[00:00.00]"),
                  "sidecar lyrics retain original bytes until bridge decoding");
            return QJsonObject{{"body", QJsonObject{{"code", 200}, {"document", document("local")}}}};
        }
        const auto operation = route.section('/', 3, 3);
        QJsonValue response;
        if (operation == "search") {
            auto candidate = song;
            candidate["provider"] = remoteProvider;
            candidate["id"] = "7";
            candidate["cover"] = missingFirstCover && route.contains(remoteProvider)
                                     ? QString()
                                     : QStringLiteral("https://music.126.net/local-fixture.png");
            response = QJsonObject{{"items", QJsonArray{candidate}}};
        } else if (operation == "lyrics") {
            response = document();
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", response}}}};
    };
    music.switchProvider("local");
    QCoreApplication::processEvents();
    requests.clear();
    host.fixtureImage("https://music.126.net/local-fixture.png", cover);
    music.importLocal({root});
    check(waitFor([&] { return !music.local->busy; }), "library imports local fixture");
    music.search("Changed");
    check(music.lists[0].size() == 1 && requests.isEmpty(),
          "local search and selection issue no online request");
    music.startLogin();
    music.restoreAccount();
    music.restoreIdentityName();
    music.playOfficial();
    check(requests.isEmpty() && !music.editable() && !music.canMutate("/like") && music.provider == "local",
          "local mode disables login, account, writes and official delivery");
    bool rejected = false;
    host.requestJson("/native/" + remoteProvider + "/playback", {},
                     [&](QJsonObject, QString error) { rejected = !error.isEmpty(); });
    check(rejected && requests.isEmpty(), "transport rejects online playback in local mode");
    const auto track = music.lists[0].first().toObject();
    check(write(root + "/album/one.lrc", "[00:00.00]one\n[00:01.00]two\n"), "create sidecar lyrics");
    music.player.play(track);
    check(waitFor([&] { return music.player.lyrics.status == "ready"; }) &&
              requests == QStringList{"/local/lyrics"},
          "local cover and sidecar lyrics suppress matching");
    music.player.stop();
    requests.clear();
    check(QFile::remove(root + "/album/one.lrc"), "remove sidecar lyrics");
    if (!remoteProviders.isEmpty()) {
        missingFirstCover = true;
        auto missing = song;
        missing["cover"] = "";
        missing["localLyrics"] = "";
        QString matchedCover;
        QObject::connect(&music.player.lyrics, &LyricsController::coverMatched, &music,
                         [&](QString, QString url) { matchedCover = url; });
        music.player.lyrics.load(missing);
        const bool fallbackReady =
            waitFor([&] { return music.player.lyrics.status == "ready" && !matchedCover.isEmpty(); });
        const auto remoteSearch = std::any_of(
            requests.begin(), requests.end(), [](const QString &route) {
                return route.startsWith("/native/") && route.endsWith("/search");
            });
        const auto remoteLyrics = std::any_of(
            requests.begin(), requests.end(), [](const QString &route) {
                return route.startsWith("/native/") && route.endsWith("/lyrics");
            });
        check(fallbackReady && remoteSearch && remoteLyrics && !matchedCover.isEmpty(),
              "missing local metadata reuses existing online recording and lyrics matching");
        music.switchProvider(remoteProvider);
        check(music.provider == remoteProvider && !music.columns.isEmpty() &&
                  music.local->songs().size() == 1 && music.player.queue.isEmpty(),
              "switch restores online columns and retains independent local index");
    }
    host.shutdown();
    qInfo() << "Local library, provider isolation and metadata priority:" << ok;
    return ok ? 0 : 1;
}
