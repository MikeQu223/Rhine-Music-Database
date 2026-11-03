#include "MvController.h"
#include "MusicPlayer.h"
#include <QGuiApplication>
#include <QJsonDocument>
#include <QScreen>
#include <QVideoFrame>
#include <QImage>
#include <algorithm>
#include <cmath>

MvController::MvController(Host *host, MusicPlayer *music, QObject *parent, Resolve resolve, Resolve versions)
    : QObject(parent), m_host(host), m_music(music), m_api(host), m_resolve(std::move(resolve)),
      m_versionsResolve(std::move(versions)) {
    if (!m_resolve) {
        if (!m_versionsResolve) {
            m_versionsResolve = [this](const QJsonObject &track, MusicApi::Reply reply) {
                m_api.call("mvVersions", {track}, std::move(reply));
            };
        }
        m_resolve = [this](const QJsonObject &track, MusicApi::Reply reply) {
            m_api.call("mv", {track}, std::move(reply));
        };
    }
    // Deliberately no QAudioOutput: the MV must never duplicate the music audio.
    connect(music, &MusicPlayer::changed, this, [this] {
        refresh();
        emit playbackChanged();
    });
    connect(host, &Host::preferenceChanged, this,
            [this](const QString &key, const QString &) { preferencesChanged(key); });
    connect(host, &Host::invalidated, this, [this] {
        if (m_epoch != m_host->epoch) {
            refresh(true);
        }
    });
    connect(host, &Host::audioSpectrumChanged, this, [this](const QJsonArray &levels) {
        if (!m_wallpaperAttached || m_quitting) {
            return;
        }
        m_spectrum.clear();
        for (const auto &value : levels) {
            m_spectrum.append(std::clamp(value.toDouble(), 0., 1.));
        }
        emit spectrumChanged();
    });
    m_timer.setInterval(250);
    connect(&m_timer, &QTimer::timeout, this, &MvController::sync);
    connect(&m_video, &QMediaPlayer::mediaStatusChanged, this, [this] {
        if (m_video.mediaStatus() == QMediaPlayer::LoadedMedia) {
            m_video.setActiveAudioTrack(-1);
            m_video.setPosition(videoPosition(audioPosition(), offset(), m_video.duration()));
            if (!m_music->state["playing"].toBool()) {
                m_video.pause();
            }
        }
        sync();
        updateOutput();
        emit changed();
    });
    connect(&m_video, &QMediaPlayer::hasVideoChanged, this, [this] {
        updateOutput();
        emit changed();
    });
    connect(&m_video, &QMediaPlayer::errorOccurred, this, [this](QMediaPlayer::Error error, const QString &) {
        if (error == QMediaPlayer::NoError) {
            return;
        }
        m_error = true;
        m_timer.stop();
        m_status = QStringLiteral("MV 播放失败，请重试；音乐播放不受影响");
        updateOutput();
        emit changed();
    });
    const auto displayChanged = [this] {
        QTimer::singleShot(0, this, [this] {
            applyPresentation();
            emit screensChanged();
        });
    };
    const auto watchScreen = [this, displayChanged](QScreen *screen) {
        connect(screen, &QScreen::geometryChanged, this, displayChanged);
        connect(screen, &QScreen::logicalDotsPerInchChanged, this, displayChanged);
    };
    for (auto screen : QGuiApplication::screens()) {
        watchScreen(screen);
    }
    connect(qGuiApp, &QGuiApplication::screenAdded, this, [watchScreen, displayChanged](QScreen *screen) {
        watchScreen(screen);
        displayChanged();
    });
    connect(qGuiApp, &QGuiApplication::screenRemoved, this, displayChanged);
    connect(qGuiApp, &QCoreApplication::aboutToQuit, this, &MvController::hideForQuit);
    m_desktopTimer.setInterval(2000);
    connect(&m_desktopTimer, &QTimer::timeout, this, [this] {
        if (!m_wallpaperAttached || !m_desktop.healthy()) {
            applyPresentation();
        }
    });
    m_controlsTimer.setInterval(100);
    connect(&m_controlsTimer, &QTimer::timeout, this, &MvController::updateDesktopControls);
    m_offsets = QJsonDocument::fromJson(host->preference("mv-offsets").toUtf8()).object();
    preferencesChanged("mv-opacity");
    m_selections = QJsonDocument::fromJson(host->preference("mv-versions").toUtf8()).object();
    m_wallpaper = wallpaperSupported() && host->preference("mv-mode") == "wallpaper";
    m_screenName = host->preference("mv-screen");
    preferencesChanged("mv-auto");
}

MvController::~MvController() {
    m_controlsTimer.stop();
    m_desktopTimer.stop();
    m_desktop.detach();
    m_timer.stop();
    disconnect(&m_video, nullptr, this, nullptr);
    m_video.stop();
    m_video.setVideoSink(nullptr);
}

void MvController::setWindow(QWindow *window) {
    m_window = window;
    if (relativeUnlock() && m_unlockWindow) {
        m_unlockWindow->setParent(window);
    }
    window->setOpacity(m_opacity);
    placeWindow();
    window->setVisible(m_enabled && !m_wallpaper);
}

bool MvController::relativeUnlock() const {
    return QGuiApplication::platformName().startsWith("wayland");
}

void MvController::registerUnlockWindow(QWindow *window) {
    m_unlockWindow = window;
    // Wayland does not expose global top-level positioning; a subsurface uses parent coordinates.
    if (relativeUnlock() && m_window) {
        window->setParent(m_window);
    }
}

void MvController::attachVideo(QVideoSink *sink) {
    m_previewSink = sink;
    updateOutput();
}

void MvController::setWallpaperWindow(QWindow *window) {
    m_wallpaperWindow = window;
    connect(window, &QWindow::widthChanged, this, &MvController::desktopGeometryChanged);
    connect(window, &QWindow::heightChanged, this, &MvController::desktopGeometryChanged);
    applyPresentation();
}

void MvController::attachWallpaperVideo(QVideoSink *sink) {
    m_wallpaperSink = sink;
    updateOutput();
}

void MvController::hideForQuit() {
    m_quitting = true;
    ++m_generation;
    m_desktopTimer.stop();
    m_controlsTimer.stop();
    m_desktop.detach();
    m_wallpaperAttached = false;
    if (m_window) {
        m_window->hide();
    }
    m_timer.stop();
    m_video.stop();
}

int MvController::offset() const {
    return std::clamp(m_offsets.value(m_mvID).toInt(), -60000, 60000);
}

void MvController::setEnabled(bool enabled) {
    if (m_enabled == enabled) {
        return;
    }
    m_enabled = enabled;
    m_host->setPreference("mv-auto", enabled ? "on" : "off");
    if (m_window) {
        if (enabled) {
            placeWindow();
        }
        m_window->setVisible(enabled);
    }
    refresh(true);
    applyPresentation();
    emit changed();
}

void MvController::setOpacity(double opacity) {
    if (!std::isfinite(opacity)) {
        return;
    }
    m_opacity = std::clamp(opacity, .2, 1.);
    if (m_window) {
        m_window->setOpacity(m_opacity);
    }
    if (m_wallpaperWindow) {
        m_wallpaperWindow->setOpacity(m_opacity);
    }
    m_host->setPreference("mv-opacity", QString::number(qRound(m_opacity * 100)));
    if (m_wallpaper && m_enabled) {
        applyPresentation();
    }
    emit changed();
}

void MvController::preferencesChanged(const QString &key) {
    if (key == "mv-auto") {
        setEnabled(m_host->preference(key) == "on");
    } else if (key == "mv-opacity") {
        bool ok = false;
        const auto value = m_host->preference(key).toInt(&ok);
        m_opacity = ok ? std::clamp(value / 100., .2, 1.) : 1.;
        if (m_window) {
            m_window->setOpacity(m_opacity);
        }
        if (m_wallpaperWindow) {
            m_wallpaperWindow->setOpacity(m_opacity);
        }
        if (m_wallpaper && m_enabled) {
            applyPresentation();
        }
        emit changed();
    } else if (key == "mv-mode") {
        setWallpaper(m_host->preference(key) == "wallpaper");
    } else if (key == "mv-screen") {
        m_screenName = m_host->preference(key);
        applyPresentation();
        emit screensChanged();
    }
}

QScreen *MvController::wallpaperScreen() const {
    for (auto screen : QGuiApplication::screens()) {
        if (screen->name() == m_screenName) {
            return screen;
        }
    }
    return QGuiApplication::primaryScreen();
}

QStringList MvController::screenLabels() const {
    QStringList labels{QStringLiteral("自动（主屏）")};
    for (auto screen : QGuiApplication::screens()) {
        labels.append(
            QStringLiteral("%1 · %2 × %3%4")
                .arg(screen->name())
                .arg(screen->geometry().width())
                .arg(screen->geometry().height())
                .arg(screen == QGuiApplication::primaryScreen() ? QStringLiteral(" · 主屏") : QString()));
    }
    return labels;
}

int MvController::screenIndex() const {
    if (m_screenName.isEmpty()) {
        return 0;
    }
    const auto screens = QGuiApplication::screens();
    for (int i = 0; i < screens.size(); ++i) {
        if (screens[i]->name() == m_screenName) {
            return i + 1;
        }
    }
    return 0;
}

void MvController::setScreenIndex(int index) {
    const auto screens = QGuiApplication::screens();
    if (index < 0 || index > screens.size()) {
        return;
    }
    m_screenName = index == 0 ? QString() : screens[index - 1]->name();
    m_host->setPreference("mv-screen", m_screenName);
    applyPresentation();
    emit screensChanged();
}

void MvController::setWallpaper(bool enabled) {
    if (enabled && !wallpaperSupported()) {
        m_presentationStatus = QStringLiteral("当前系统不支持桌面壁纸模式");
        emit changed();
        return;
    }
    if (m_wallpaper == enabled) {
        return;
    }
    m_wallpaper = enabled;
    if (enabled) {
        setLocked(false);
    }
    m_host->setPreference("mv-mode", enabled ? "wallpaper" : "window");
    if (enabled && m_window && m_window->visibility() == QWindow::FullScreen) {
        m_window->showNormal();
    }
    applyPresentation();
    if (!enabled && m_enabled && m_window) {
        m_window->showNormal();
    }
}

void MvController::applyPresentation() {
    if (m_quitting) {
        return;
    }
    const auto previousStatus = m_presentationStatus;
    m_presentationStatus.clear();
    if (m_wallpaper && m_enabled && m_wallpaperWindow) {
        m_wallpaperWindow->setOpacity(m_opacity);
        m_wallpaperAttached = m_desktop.attach(m_wallpaperWindow, wallpaperScreen(), &m_presentationStatus);
        if (!m_wallpaperAttached) {
            m_desktop.detach();
            if (m_window && previousStatus != m_presentationStatus) {
                m_window->showNormal();
            }
        }
        m_desktopTimer.start();
        if (m_wallpaperAttached && !m_desktop.setInteractive(true)) {
            m_presentationStatus = QStringLiteral("桌面控件暂不可用，可从 MV 设置窗口退出壁纸");
            if (m_window && previousStatus != m_presentationStatus) {
                m_window->showNormal();
            }
        }
        m_controlsTimer.start();
        if (m_wallpaperAttached && !m_screenName.isEmpty() && screenIndex() == 0) {
            m_presentationStatus = QStringLiteral("原显示器已断开，壁纸已移至主屏");
        }
    } else {
        m_controlsTimer.stop();
        m_desktopTimer.stop();
        m_desktop.detach();
        m_wallpaperAttached = false;
    }
    updateOutput();
    emit desktopGeometryChanged();
    m_host->mediaControl("spectrum", m_wallpaperAttached ? 1 : 0);
    if (!m_wallpaperAttached) {
        m_spectrum.clear();
        emit spectrumChanged();
    }
    emit changed();
}

void MvController::updateOutput() {
    QVideoSink *sink =
        m_wallpaperAttached && m_enabled && !m_quitting ? m_wallpaperSink.data() : m_previewSink.data();
    if (m_video.videoSink() != sink) {
        const auto frame = m_video.videoSink() ? m_video.videoSink()->videoFrame() : QVideoFrame();
        m_video.setVideoSink(sink);
        if (sink && frame.isValid()) {
            // Separate Qt Quick windows may use different RHI devices. A CPU copy preserves
            // the paused picture across a mode change without sharing the previous GPU texture.
            const auto image = frame.toImage();
            if (!image.isNull()) {
                sink->setVideoFrame(QVideoFrame(image));
            }
        }
    }
    m_desktop.setVisible(m_wallpaperAttached && ready() && !m_quitting);
    updateDesktopControls();
}

void MvController::updateDesktopControls() {
    const bool visible = m_wallpaperAttached && ready() && !m_quitting;
    // The permanent controls are part of the wallpaper scene, never a separate native window.
    if (visible) {
        emit playbackChanged();
    }
}

double MvController::duration() const {
    return std::max(0., m_music->state["duration"].toDouble());
}
double MvController::position() const {
    return std::clamp(audioPosition(), 0., duration());
}
double MvController::progress() const {
    return duration() > 0 ? position() / duration() : 0;
}
bool MvController::playing() const {
    return m_music->state["playing"].toBool();
}
bool MvController::seekable() const {
    return duration() > 0 && m_music->state["seekable"].toBool();
}
void MvController::toggleMusic() {
    m_music->toggle();
}
void MvController::seekMusic(double fraction) {
    if (seekable() && std::isfinite(fraction)) {
        m_music->seek(std::clamp(fraction, 0., 1.));
    }
}
void MvController::exitWallpaper() {
    setEnabled(false);
}

void MvController::setPinned(bool value) {
    if (m_pinned == value) {
        return;
    }
    m_pinned = value;
    emit changed();
}

void MvController::setLocked(bool value) {
    if (m_locked == value || (value && m_wallpaper)) {
        return;
    }
    m_locked = value;
    emit changed();
}

void MvController::openWindow() {
    setLocked(false);
    setWallpaper(false);
    setEnabled(true);
    showSettings();
}

void MvController::showSettings() {
    if (m_window && m_enabled) {
        m_window->showNormal();
        m_window->requestActivate();
    }
}

QStringList MvController::versionLabels() const {
    QStringList labels;
    for (const auto &value : m_versions) {
        const auto version = value.toObject();
        auto label =
            version["associated"].toBool() ? QStringLiteral("[歌曲关联] ") : QStringLiteral("[搜索结果] ");
        label += version["title"].toString();
        if (!version["artist"].toString().isEmpty()) {
            label += " · " + version["artist"].toString();
        }
        label += " · #" + version["id"].toString();
        labels.append(label);
    }
    return labels;
}

int MvController::versionIndex() const {
    const auto id = m_selections.value(m_key).toString(m_requestedMvID.isEmpty() ? m_mvID : m_requestedMvID);
    for (int i = 0; i < m_versions.size(); ++i) {
        if (m_versions[i].toObject()["id"].toString() == id) {
            return i;
        }
    }
    return -1;
}

void MvController::setVersionIndex(int index) {
    if (index < 0 || index >= m_versions.size()) {
        return;
    }
    const auto id = m_versions[index].toObject()["id"].toString();
    const bool same = index == versionIndex();
    if (same && m_selections.value(m_key).toString() == id) {
        return;
    }
    m_selections[m_key] = id;
    while (m_selections.size() > 256) {
        auto oldest = m_selections.begin();
        if (oldest.key() == m_key) {
            ++oldest;
        }
        m_selections.erase(oldest);
    }
    m_host->setPreference("mv-versions",
                          QString::fromUtf8(QJsonDocument(m_selections).toJson(QJsonDocument::Compact)));
    if (same) {
        emit changed();
    } else {
        refresh(true);
    }
}

void MvController::placeWindow() {
    const auto screens = QGuiApplication::screens();
    if (!m_window || screens.isEmpty()) {
        return;
    }
    auto target = m_window->screen();
    if (!target || !screens.contains(target)) {
        target = QGuiApplication::primaryScreen();
    }
    const bool fullscreen = m_window->visibility() == QWindow::FullScreen;
    if (fullscreen) {
        m_window->showNormal();
    }
    m_window->setScreen(target);
    const auto area = target->availableGeometry();
    const int width = std::min(960, qRound(area.width() * .8));
    const int height = std::max(m_window->minimumHeight(),
                                std::min(qRound(width * 9. / 16) + 250, qRound(area.height() * .8)));
    m_window->setGeometry(QRect(area.center() - QPoint(width / 2, height / 2), QSize(width, height)));
    if (fullscreen) {
        m_window->showFullScreen();
    }
}

void MvController::toggleFullscreen() {
    if (m_window && !m_wallpaper) {
        if (m_window->visibility() == QWindow::FullScreen) {
            m_window->showNormal();
        } else {
            m_window->showFullScreen();
        }
    }
}

qint64 MvController::videoPosition(double audioPosition, int offset, qint64 duration) {
    const auto position = std::isfinite(audioPosition) ? std::max(0., audioPosition + offset) : 0.;
    return qint64(std::min(position, duration > 0 ? double(duration) : 1.e12));
}

void MvController::saveOffset(int value) {
    if (m_mvID.isEmpty()) {
        return;
    }
    m_offsets[m_mvID] = std::clamp(value, -60000, 60000);
    while (m_offsets.size() > 256) {
        m_offsets.remove(m_offsets.begin().key());
    }
    m_host->setPreference("mv-offsets",
                          QString::fromUtf8(QJsonDocument(m_offsets).toJson(QJsonDocument::Compact)));
    m_video.setPosition(videoPosition(audioPosition(), offset(), m_video.duration()));
    emit changed();
}

void MvController::adjustOffset(int milliseconds) {
    saveOffset(offset() + std::clamp(milliseconds, -1000, 1000));
}
void MvController::resetOffset() {
    saveOffset(0);
}
void MvController::retry() {
    refresh(true);
}

void MvController::refresh(bool force) {
    const auto track = m_music->current;
    const auto key = track["provider"].toString() + ':' + track["id"].toString();
    if (!force && key == m_key && m_epoch == m_host->epoch) {
        sync();
        return;
    }
    const auto generation = ++m_generation;
    if (key != m_key || m_epoch != m_host->epoch) {
        m_versions = {};
    }
    m_versionStatus.clear();
    m_key = key;
    m_epoch = m_host->epoch;
    m_timer.stop();
    m_video.stop();
    m_video.setSource({});
    updateOutput();
    emit videoCleared();
    m_error = false;
    m_mvID.clear();
    m_requestedMvID.clear();
    m_audioPosition = -1;
    m_audioPlaying = false;
    m_title = track["title"].toString();
    m_status = track.isEmpty() ? QStringLiteral("播放网易云歌曲后，将自动查找关联 MV")
                               : QStringLiteral("当前仅支持网易云歌曲的关联 MV");
    if (!m_enabled || track.isEmpty() || track["provider"] != "netease") {
        emit changed();
        return;
    }
    m_status = QStringLiteral("正在查找歌曲关联 MV…");
    emit changed();
    const int epoch = m_epoch;
    auto requestTrack = track;
    const auto selected = m_selections.value(m_key).toString();
    if (!selected.isEmpty()) {
        requestTrack["videoID"] = selected;
    }
    resolveVideo(requestTrack, generation, epoch);
    if (m_versionsResolve) {
        m_versionStatus = QStringLiteral("正在查找视频版本…");
        m_versionsResolve(track, [owner = QPointer(this), generation, epoch, track](MusicReply reply) {
            if (!owner || owner->m_generation != generation || owner->m_host->epoch != epoch ||
                !owner->m_enabled) {
                return;
            }
            if (reply.ok() && reply.value.isObject()) {
                owner->m_versions = reply.value.toObject()["versions"].toArray();
                owner->m_versionStatus = reply.value.toObject()["warning"].toString();
                const auto selected = owner->m_selections.value(owner->m_key).toString(owner->m_mvID);
                if (!selected.isEmpty() && owner->versionIndex() < 0) {
                    owner->m_versions.prepend(
                        QJsonObject{{"id", selected}, {"title", QStringLiteral("已选版本 · ") + selected}});
                }
                if (owner->m_selections.value(owner->m_key).toString().isEmpty() &&
                    !owner->m_versions.isEmpty() &&
                    !owner->m_versions.first().toObject()["associated"].toBool()) {
                    auto selectedTrack = track;
                    selectedTrack["videoID"] = owner->m_versions.first().toObject()["id"];
                    owner->resolveVideo(selectedTrack, generation, epoch);
                }
                if (owner->m_versions.isEmpty() && owner->m_versionStatus.isEmpty()) {
                    owner->m_versionStatus = QStringLiteral("未找到其他视频版本");
                }
            } else {
                owner->m_versionStatus = QStringLiteral("视频版本加载失败，可重试");
            }
            emit owner->changed();
        });
    }
}

void MvController::resolveVideo(QJsonObject track, quint64 generation, int epoch) {
    const auto sourceGeneration = ++m_sourceGeneration;
    m_requestedMvID = track.value("videoID").toString();
    m_status = QStringLiteral("正在加载视频版本…");
    emit changed();
    m_resolve(track, [owner = QPointer(this), generation, epoch, sourceGeneration](MusicReply reply) {
        if (!owner || owner->m_generation != generation || owner->m_sourceGeneration != sourceGeneration ||
            owner->m_host->epoch != epoch || !owner->m_enabled) {
            return;
        }
        if (!reply.ok()) {
            owner->m_status = QStringLiteral("MV 加载失败：") + reply.error;
        } else if (!reply.value.isObject()) {
            owner->m_status = QStringLiteral("此歌曲没有关联 MV，可手动选择视频版本");
        } else {
            const auto mv = reply.value.toObject();
            const QUrl url(mv["url"].toString());
            if ((url.scheme() != "http" && url.scheme() != "https") || url.host().isEmpty() ||
                !url.userInfo().isEmpty()) {
                owner->m_status = QStringLiteral("MV 播放地址无效");
                emit owner->changed();
                return;
            }
            owner->m_mvID = mv["id"].toString();
            owner->m_title = mv["title"].toString(owner->m_title);
            owner->m_status = QStringLiteral("静音跟随音乐 · %1p").arg(mv["resolution"].toInt());
            owner->m_video.setSource(url);
            owner->m_timer.start();
            owner->sync();
        }
        emit owner->changed();
    });
}

double MvController::audioPosition() const {
    return m_audioPosition + (m_audioPlaying && m_audioClock.isValid() ? m_audioClock.elapsed() : 0);
}

void MvController::sync() {
    const double position = m_music->state["position"].toDouble();
    const bool playing = m_music->state["playing"].toBool() && !m_music->state["buffering"].toBool() &&
                         !m_music->loading && !m_music->failed;
    if (position != m_audioPosition || playing != m_audioPlaying) {
        m_audioPosition = position;
        m_audioPlaying = playing;
        m_audioClock.restart();
    }
    if (!m_enabled || m_error || m_video.source().isEmpty()) {
        return;
    }
    const double audio = audioPosition();
    const auto target = videoPosition(audio, offset(), m_video.duration());
    if (std::abs(m_video.position() - target) > (playing ? 400 : 100)) {
        m_video.setPosition(target);
    }
    const bool beforeEnd = m_video.duration() <= 0 || target < m_video.duration() - 100;
    if (playing && audio + offset() >= 0 && beforeEnd) {
        if (!m_video.isPlaying()) {
            m_video.play();
        }
    } else if (m_video.isPlaying()) {
        m_video.pause();
    }
}
