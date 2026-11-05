#include "NativeHud.h"
#include "PlaybackQueueCard.h"
#include "MusicDiscover.h"
#include "DiscoverMusicCard.h"
#include <algorithm>
#include <cmath>

/** 滚轮优先交给当前面板；歌词使用连续距离，资料库保留合并后的整数步数。 */
void NativeHud::wheel(double x, double y, double delta, std::optional<int> steps,
                      std::optional<double> distance) {
    if (frame.isEmpty() || !std::isfinite(delta)) {
        return;
    }
    if (m_responsive.compact()) {
        const auto bounds = m_responsive.state(sourceState())["playerBounds"].toObject();
        if (y >= bounds["y"].toDouble()) {
            return;
        }
        if (delta == 0 && steps.value_or(0) == 0 && distance.value_or(0.) == 0) {
            return;
        }
        const auto movement = distance.value_or(steps.value_or(delta < 0 ? 1 : -1) * 60.);
        const auto compactState = m_responsive.state(sourceState());
        const bool archive = modal.isEmpty() && compactState["mode"] == "archive";
        const bool listRegion = y >= compactState["archiveListY"].toDouble();
        if (archive && !listRegion) {
            m_scene.pointer("wheel", x, y, -delta * 8);
            return;
        }
        if (archive && listRegion) {
            m_scene.pointer("pointercancel", 0, 0, 0);
        }
        // 场景滚动走原有三维输入，列表手势只移动自己的固定槽位。
        if ((!archive || listRegion) && m_responsive.scroll(movement)) {
            if (modal == "settings" && !editingSettingId.isEmpty()) {
                cancelSettingEdit();
            }
            if (movement > 0 && m_responsive.nearEnd() && !closing) {
                auto &music = *m_music;
                if (modal == "discover" && !categoryPicker && !music.discover->loading &&
                    music.discover->more) {
                    music.discover->load(music.discover->tab, true);
                } else if (modal == "search" && query.trimmed() == music.keyword && !music.sourceLoading() &&
                           music.hasMore[0]) {
                    music.loadMoreSource(0);
                } else if (modal == "saved" && !music.sourceLoading() && music.hasMore[musicCollection]) {
                    music.loadMoreSource(musicCollection);
                } else if (archive && music.directory) {
                    music.loadDirectoryPage();
                } else if (archive && music.hasMore[music.selectedLane] &&
                           music.groupLane != music.selectedLane && !music.sourceLoading()) {
                    music.loadMoreSource(music.selectedLane);
                }
            }
            return;
        }
        return;
    }
    if (playerBounds && playerBounds->contains(x, y)) {
        return;
    }
    const auto step = steps.value_or(delta < 0 ? 1 : -1);
    // 鼠标滚轮按帧平滑时角度增量只在首帧出现，后续只补送连续距离。
    if (delta == 0 && step == 0 && distance.value_or(0.) == 0) {
        return;
    }
    auto &music = *m_music;
    if (modal == "settings") {
        if (!editingSettingId.isEmpty()) {
            cancelSettingEdit();
        }
        const auto bounds = modalBounds(width);
        const auto localY = y - motion.offset;
        if (!closing && x >= bounds.x() + 53 && x <= bounds.right() - 53 &&
            localY >= bounds.top() + SettingsViewportTop && localY <= bounds.top() + SettingsViewportBottom) {
            settingsScroll =
                HudScroll::applyWheel(settingsScroll, settingsContentBottom - SettingsViewportTop,
                                      SettingsViewportBottom - SettingsViewportTop, distance, step, 66.);
        }
        return;
    }
    if (modal == "desktop-lyrics") {
        const auto bounds = modalBounds(width);
        const auto localY = y - motion.offset;
        if (!closing && x >= bounds.x() + 53 && x <= bounds.right() - 53 &&
            localY >= bounds.top() + DesktopLyricsViewportTop &&
            localY <= bounds.top() + DesktopLyricsViewportBottom) {
            desktopLyricsScroll = HudScroll::applyWheel(
                desktopLyricsScroll, desktopLyricsContentBottom - DesktopLyricsViewportTop,
                DesktopLyricsViewportBottom - DesktopLyricsViewportTop, distance, step, 66.);
        }
        return;
    }
    if (frame["viewer"].toBool()) {
        if (delta != 0) {
            m_scene.pointer("wheel", x, y, -delta * 8);
        }
        return;
    }
    if (!modal.isEmpty()) {
        if (modal == "playlist-picker") {
            listOffset = std::clamp(listOffset + step, 0, std::max(0, int(music.lists[2].size()) - 7));
            return;
        }
        if (modal == "discover") {
            const auto bounds = modalBounds(width);
            const auto viewport = DiscoverMusicCard::layout(bounds, music.discover->items.size()).viewport;
            if (!closing && !categoryPicker && viewport.contains(x, y - motion.offset)) {
                const auto movement = distance.value_or(step * 60.);
                discoverScroll =
                    HudScroll::applyWheel(discoverScroll, viewport.height() + discoverScrollMaximum,
                                          viewport.height(), distance, step, 60.);
                // 只在滚动接近已载入内容末尾时续载，绘制过程不发起列表请求。
                if (movement > 0 && discoverScroll >= discoverScrollMaximum - 120 &&
                    !music.discover->loading && music.discover->more) {
                    music.discover->load(music.discover->tab, true);
                }
            }
            return;
        }
        if (modal == "player") {
            queueOffset = std::clamp(queueOffset + step, 0,
                                     PlaybackQueueCard::maximumOffset(music.player.queue.size()));
            return;
        }
        if (modal == "search") {
            if (closing) {
                return;
            }
            const auto bounds = modalBounds(width);
            y -= motion.offset;
            const auto inside = x >= bounds.x() + 53 && x <= bounds.right() - 10 &&
                                y >= bounds.y() + ResultListTop && y <= bounds.y() + ResultListBottom;
            if (!inside) {
                return;
            }
            const auto movement = distance.value_or(step * ResultRowHeight);
            searchScroll =
                HudScroll::applyWheel(searchScroll, searchRowCount * ResultRowHeight,
                                      ResultListBottom - ResultListTop, distance, step, ResultRowHeight);
            // 接近已载入内容末尾时预取下一页；加载标志会阻止连续请求。
            if (movement > 0 && searchScroll >= searchScrollMaximum() - 160 &&
                query.trimmed() == music.keyword && !music.sourceLoading() && music.hasMore[0]) {
                music.loadMoreSource(0);
            }
            return;
        }
        if (modal != "saved" || closing) {
            return;
        }
        const auto bounds = modalBounds(width);
        y -= motion.offset;
        if (x < bounds.x() + 53 || x > bounds.right() - 10 || y < bounds.y() + ResultListTop ||
            y > bounds.y() + ResultListBottom) {
            return;
        }
        const auto movement = distance.value_or(step * ResultRowHeight);
        savedScroll =
            HudScroll::applyWheel(savedScroll, savedRowCount * ResultRowHeight,
                                  ResultListBottom - ResultListTop, distance, step, ResultRowHeight);
        if (movement > 0 && savedScroll >= savedScrollMaximum() - 160 && !music.sourceLoading() &&
            music.hasMore[musicCollection]) {
            music.loadMoreSource(musicCollection);
        }
        return;
    }
    if (lyricsMode && music.current.value("kind") == "song" && x >= width * 0.56 && y >= 360 && y < 889) {
        const auto lastTop = m_lyricsLayout.isEmpty() ? 0 : m_lyricsLayout.constLast().top;
        const auto movement = distance.value_or((-delta / 120) * 65);
        m_lyricsBrowse = std::clamp(m_lyricsBrowse.value_or(m_lyricsScroll) + movement, 0.0, lastTop);
        m_lyricsPlainOffset = std::max(0, m_lyricsPlainOffset + step);
        return;
    }
    if (frame["mode"] == "detail" && music.current.value("kind") != "song") {
        // 平滑帧只补送距离，不改曲目行偏移，也不重复触发分页加载。
        if (step == 0) {
            return;
        }
        const auto layout = containerLayout(width);
        if (x < layout.x || x > layout.x + layout.width || y < layout.rowsY ||
            y > layout.rowsY + layout.rowCount * layout.rowHeight) {
            return;
        }
        const bool albums =
            music.directory && music.directory->item["kind"] == "artist" && artistTab == "albums";
        int count = music.tracks.size();
        if (music.directory) {
            count = albums ? music.directory->albums.size() : music.directory->songs.size();
        }
        trackOffset = std::clamp(trackOffset + step, 0, std::max(0, count - layout.rowCount));
        if (trackOffset + layout.rowCount >= count) {
            if (albums) {
                music.loadArtistAlbums();
            } else if (music.directory) {
                music.loadDirectoryPage();
            } else {
                music.loadTrackPage(trackOffset);
            }
        }
        return;
    }
    if (frame["mode"] == "detail") {
        // 详情正文与历史列表只按行进，平滑帧不重复请求曲目页。
        if (step == 0) {
            return;
        }
        if (tab == "history") {
            trackOffset =
                std::clamp(trackOffset + step, 0, std::max(0, int(music.tracks.size()) - AlbumTrackRowCount));
            music.loadTrackPage(trackOffset + AlbumTrackRowCount - 1);
        } else {
            const auto count = m_glyphs->wrap(body(), width * 0.44 - 59, 16).size();
            bodyOffset = std::clamp(bodyOffset + step, 0, std::max(0, int(count) - 3));
        }
        return;
    }
    if (frame["mode"] == "archive") {
        if (step != 0) {
            music.next(step);
        }
    } else if (delta != 0) {
        m_scene.pointer("wheel", x, y, -delta * 8);
    }
}
