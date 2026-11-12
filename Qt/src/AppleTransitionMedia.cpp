#include "AppleTransitionMedia.h"

#include <QBuffer>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QTemporaryFile>
#include <QTimer>
#include <algorithm>

namespace {
constexpr qint64 maximumMediaBytes = 96LL * 1024 * 1024;
constexpr qint64 maximumPlaylistBytes = 512 * 1024;
constexpr int maximumSegments = 256;

struct Fetch {
    QUrl url;
    QString contentType;
};

struct Budget {
    QElapsedTimer elapsed;
    int timeoutMs;
    const std::atomic_bool &cancelled;

    int remaining() const {
        return cancelled.load() ? 0 : int(std::max<qint64>(0, timeoutMs - elapsed.elapsed()));
    }
};

/** 读取原始播放地址或媒体分片，所有跳转经过同一份平台媒体策略。 */
Fetch fetch(QNetworkAccessManager &network, const QUrl &url, const AppleTransitionMedia::AllowsUrl &allowsUrl,
            QIODevice &destination, qint64 maximumBytes, const Budget &budget) {
    if (!allowsUrl(url) || budget.remaining() <= 0 || maximumBytes <= 0) {
        return {};
    }
    QNetworkRequest request(url);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::UserVerifiedRedirectPolicy);
    request.setTransferTimeout(budget.remaining());
    auto *reply = network.get(request);
    reply->setReadBufferSize(512 * 1024);
    QEventLoop wait;
    QTimer checkBudget;
    checkBudget.setInterval(50);
    qint64 written = 0;
    bool usable = true;
    const auto abort = [&] {
        usable = false;
        reply->abort();
    };
    const auto copyBytes = [&] {
        if (!usable || !reply->bytesAvailable()) {
            return;
        }
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto bytes = reply->readAll();
        if (status != 200) {
            return;
        }
        if (written + bytes.size() > maximumBytes || destination.write(bytes) != bytes.size()) {
            abort();
            return;
        }
        written += bytes.size();
    };
    QObject::connect(reply, &QNetworkReply::redirected, &wait, [&](const QUrl &target) {
        const bool downgrade = reply->url().scheme() == "https" && target.scheme() != "https";
        if (!downgrade && allowsUrl(target)) {
            emit reply->redirectAllowed();
        } else {
            abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::metaDataChanged, &wait, [&] {
        if (reply->header(QNetworkRequest::ContentLengthHeader).toLongLong() > maximumBytes) {
            abort();
        }
    });
    QObject::connect(reply, &QIODevice::readyRead, &wait, copyBytes);
    QObject::connect(reply, &QNetworkReply::finished, &wait, &QEventLoop::quit);
    QObject::connect(&checkBudget, &QTimer::timeout, &wait, [&] {
        if (budget.remaining() <= 0) {
            abort();
        }
    });
    checkBudget.start();
    if (!reply->isFinished()) {
        wait.exec();
    }
    copyBytes();
    const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const bool finished = usable && !budget.cancelled.load() && reply->error() == QNetworkReply::NoError &&
                          status == 200 && written > 0;
    const Fetch result =
        finished ? Fetch{reply->url(), reply->header(QNetworkRequest::ContentTypeHeader).toString()}
                 : Fetch{};
    delete reply;
    return result;
}

QString attribute(const QString &line, const QString &name) {
    const QRegularExpression expression("(?:[:,])\\s*" + name + "=\"([^\"]+)\"");
    return expression.match(line).captured(1);
}

QUrl audioVariant(const QStringList &lines, const QUrl &base) {
    for (const auto &line : lines) {
        if (line.startsWith("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO")) {
            const auto uri = attribute(line, "URI");
            if (!uri.isEmpty()) {
                return base.resolved(QUrl(uri));
            }
        }
    }
    QUrl first;
    for (qsizetype index = 0; index + 1 < lines.size(); ++index) {
        const auto &line = lines[index];
        const auto &uri = lines[index + 1];
        if (!line.startsWith("#EXT-X-STREAM-INF:") || uri.isEmpty() || uri.startsWith('#')) {
            continue;
        }
        const auto variant = base.resolved(QUrl(uri));
        const auto codecs = attribute(line, "CODECS");
        if (codecs.startsWith("mp4a.") && !codecs.contains(',')) {
            return variant;
        }
        if (first.isEmpty()) {
            first = variant;
        }
    }
    return first;
}

std::shared_ptr<const QString> retain(QTemporaryFile &file) {
    if (!file.flush()) {
        return {};
    }
    file.setAutoRemove(false);
    file.close();
    return std::shared_ptr<const QString>(new QString(file.fileName()), [](const QString *path) {
        QFile::remove(*path);
        delete path;
    });
}

/** 只组合普通完整点播分片，保留容器的原始时间戳；加密和不连续流交回 AVPlayer。 */
std::shared_ptr<const QString> copyPlaylist(QNetworkAccessManager &network, QByteArray playlist, QUrl base,
                                            const AppleTransitionMedia::AllowsUrl &allowsUrl,
                                            const Budget &budget) {
    QStringList lines;
    for (int depth = 0; depth < 3; ++depth) {
        if (playlist.size() > maximumPlaylistBytes || !playlist.trimmed().startsWith("#EXTM3U")) {
            return {};
        }
        lines = QString::fromUtf8(playlist).split('\n', Qt::SkipEmptyParts);
        for (auto &line : lines) {
            line = line.trimmed();
        }
        const auto variant = audioVariant(lines, base);
        if (variant.isEmpty()) {
            break;
        }
        playlist.clear();
        QBuffer buffer(&playlist);
        buffer.open(QIODevice::WriteOnly);
        const auto result = fetch(network, variant, allowsUrl, buffer, maximumPlaylistBytes, budget);
        if (result.url.isEmpty()) {
            return {};
        }
        base = result.url;
    }
    if (!lines.contains("#EXT-X-ENDLIST")) {
        return {};
    }

    QUrl initialization;
    QList<QUrl> segments;
    for (const auto &line : lines) {
        if ((line.startsWith("#EXT-X-KEY:") && !line.endsWith("METHOD=NONE")) ||
            line.startsWith("#EXT-X-BYTERANGE:") || line == "#EXT-X-DISCONTINUITY" || line == "#EXT-X-GAP") {
            return {};
        }
        if (line.startsWith("#EXT-X-MAP:")) {
            const auto uri = attribute(line, "URI");
            if (uri.isEmpty() || line.contains("BYTERANGE") || !initialization.isEmpty()) {
                return {};
            }
            initialization = base.resolved(QUrl(uri));
        } else if (!line.isEmpty() && !line.startsWith('#')) {
            segments.append(base.resolved(QUrl(line)));
        }
    }
    if (segments.isEmpty() || segments.size() > maximumSegments) {
        return {};
    }
    const auto suffix = initialization.isEmpty() ? ".ts" : ".m4a";
    if (!initialization.isEmpty()) {
        segments.prepend(initialization);
    }
    QTemporaryFile audio(QDir::tempPath() + "/rhine-transition-XXXXXX" + suffix);
    if (!audio.open()) {
        return {};
    }
    for (const auto &segment : segments) {
        const auto result =
            fetch(network, segment, allowsUrl, audio, maximumMediaBytes - audio.size(), budget);
        if (result.url.isEmpty()) {
            return {};
        }
    }
    return retain(audio);
}
}

std::shared_ptr<const QString> AppleTransitionMedia::copy(QNetworkAccessManager &network, const QUrl &url,
                                                          const AllowsUrl &allowsUrl, int timeoutMs,
                                                          const std::atomic_bool &cancelled) {
    Budget budget{{}, timeoutMs, cancelled};
    budget.elapsed.start();
    const auto extension = QFileInfo(url.path()).suffix().toLower();
    const auto suffix =
        QRegularExpression("^[a-z0-9]{1,6}$").match(extension).hasMatch() ? "." + extension : QString();
    QTemporaryFile file(QDir::tempPath() + "/rhine-transition-XXXXXX" + suffix);
    if (!file.open()) {
        return {};
    }
    const auto maximumBytes = extension == "m3u8" ? maximumPlaylistBytes : maximumMediaBytes;
    const auto result = fetch(network, url, allowsUrl, file, maximumBytes, budget);
    if (result.url.isEmpty() || !file.seek(0)) {
        return {};
    }
    if (result.contentType.contains("mpegurl", Qt::CaseInsensitive) ||
        file.peek(32).trimmed().startsWith("#EXTM3U")) {
        if (file.size() > maximumPlaylistBytes) {
            return {};
        }
        return copyPlaylist(network, file.readAll(), result.url, allowsUrl, budget);
    }
    return retain(file);
}
