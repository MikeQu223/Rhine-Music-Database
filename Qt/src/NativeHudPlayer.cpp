#include "NativeHud.h"
#include "MusicData.h"
#include "PlayerBar.h"
#include "PlaybackQueueCard.h"
#include <algorithm>

/** 适配播放业务快照；状态栏组件不感知账号、歌词页面或播放器生命周期。 */
void NativeHud::playerBar(double x, double y, double width) {
    const auto &player = m_music->player;
    PlayerBar::State state;
    state.title = player.current.value("title").toString();
    state.artist = player.current.value("artist").toString();
    state.album = player.current.value("album").toString();
    state.cover = player.coverImage;
    state.status = player.status;
    state.mode = player.mode;
    state.positionMs = player.state["position"].toDouble();
    state.durationMs = player.state["duration"].toDouble();
    state.volume = player.state["volume"].toDouble();
    state.playing = player.state["playing"].toBool();
    state.loading = player.loading;
    state.failed = player.failed;
    state.hasTrack = !player.current.isEmpty();
    const auto liked = m_music->songLiked(player.current);
    state.liked = liked.value_or(false);
    state.likeKnown = liked.has_value();
    state.canLike = state.hasTrack && (m_music->isSiren() || !m_music->uid.isEmpty()) &&
                    !m_music->writeLoading && m_music->canMutate("/like") &&
                    player.current.value("provider").toString(m_music->provider) == m_music->provider;
    state.seekable = player.state["seekable"].toBool();
    state.applicationVolume = PlatformFeatures::ApplicationVolume;
    if (m_responsive.compact()) {
        m_responsive.setPlayer(state);
        return;
    }
    const auto drawing = PlayerBar::render(state, {x, y, width, PlayerBar::RowHeight}, dark, *m_glyphs);
    for (const auto &command : drawing.commands) {
        commands.append(command);
    }
    for (const auto &target : drawing.hits) {
        hits.append(target);
    }
    playerBounds = drawing.inputBounds;
    playerSeekRect = drawing.seek;
    playerVolumeRect = drawing.volume;
}

/** 队列面板 */
void NativeHud::playerPanel(double x, double y, double width) {
    const auto &player = m_music->player;
    queueOffset = std::clamp(queueOffset, 0, PlaybackQueueCard::maximumOffset(player.queue.size()));
    PlaybackQueueCard::Model model;
    model.bounds = {x, y, width, 836};
    model.tracks = player.queue.items();
    model.current = player.current;
    model.cover = player.coverImage;
    model.mode = player.mode;
    model.status = player.status;
    model.currentIndex = player.queue.indexOf(player.current);
    model.offset = queueOffset;
    model.playing = player.state["playing"].toBool();
    model.dark = dark;
    PlaybackQueueCard::Canvas canvas;
    canvas.fill = [this](double left, double top, double w, double h, QJsonArray color) {
        fill(left, top, w, h, color);
    };
    canvas.text = [this](QString value, double left, double top, double size, QString weight,
                         QJsonArray color) { text(value, left, top, size, weight, 0, color); };
    canvas.fit = [this](QString value, double size, double w, QString weight) {
        return fit(value, size, w, weight);
    };
    canvas.hit = [this](double left, double top, double w, double h, QString action, QString label) {
        hit(left, top, w, h, action, label);
    };
    canvas.image = [this](QString key, double left, double top, double w, double h) {
        image(key, left, top, w, h);
    };
    if (m_responsive.compact()) {
        m_responsive.setQueue(model);
        return;
    }
    PlaybackQueueCard::paint(model, canvas);
}
