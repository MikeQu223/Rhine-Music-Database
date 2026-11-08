#include "ResponsiveHudLayout.h"
#include "MusicData.h"
#include <algorithm>
#include <cmath>

void ResponsiveHudLayout::resize(double stageWidth) {
    m_fields = {};
    m_song.reset();
    m_collection.reset();
    m_discover.reset();
    m_settings.reset();
    m_settingsCustom.clear();
    m_auxiliary.clear();
    if (!std::isfinite(stageWidth) || stageWidth <= 0) {
        return;
    }
    const bool next = stageWidth < 1080;
    if (next != m_compact) {
        m_scroll = 0;
        m_scope.clear();
    }
    m_compact = next;
    m_unit = stageWidth / 393;
    m_height = 1080 / m_unit;
}
/** 先复位页面滚动，再构建可见模型，避免新页按上一页的偏移取错窗口。 */
void ResponsiveHudLayout::prepare(const QString &scope, bool home) {
    if (scope == m_scope) {
        return;
    }
    m_scope = scope;
    m_scopeChanged = true;
    if (!home) {
        m_scroll = 0;
    }
    m_queueModesExpanded = false;
    m_songOptionsExpanded = false;
}

void ResponsiveHudLayout::arrange(QJsonArray &commands, QJsonArray &hits, const QJsonObject &source,
                                  const QString &scope, Glyphs &glyphs) {
    if (!m_compact) {
        return;
    }
    const auto modal = source["modal"].toString();
    const bool lyric = source["lyricsMode"].toBool() && modal.isEmpty();
    const bool comments = source["commentsMode"].toBool() && modal.isEmpty();
    const bool home = modal.isEmpty() && source["mode"] == "archive" && !lyric && !comments;
    prepare(scope, home);
    const bool newScope = m_scopeChanged;
    m_scopeChanged = false;
    ResponsiveHudCanvas c(glyphs, m_unit, m_height, source["dark"].toBool());
    if (source["viewer"].toBool()) {
        c.header("封面查看", true);
        for (int index = 0; index < c.hits.size(); ++index) {
            auto hit = c.hits[index].toObject();
            if (hit["action"] == "close-modal") {
                hit["action"] = "viewer:close";
                c.hits[index] = hit;
            }
        }
        auto wash = c.paper;
        wash[3] = .85;
        c.fill({0, m_height - 150, 393, 150}, wash);
        c.button({20, m_height - 132, 172, 44}, "清晰", "viewer:clear");
        c.button({201, m_height - 132, 172, 44}, "磨砂", "viewer:frosted");
        c.button({20, m_height - 76, 172, 44}, "原始视角", "viewer:reset");
        c.button({201, m_height - 76, 172, 44}, "封面正面", "music:cover-front");
        c.field("playerBounds", {0, m_height - 150, 393, 150});
        c.finish();
        m_fields = c.fields;
        commands = c.commands;
        hits = c.hits;
        return;
    }
    m_lyricsPage = lyric;
    m_archiveActive = home;
    if (!home) {
        m_archiveListY = 0;
    }
    if (newScope) {
        m_followLyrics = true;
        m_lyricTarget.reset();
        m_lyricCurve.reset();
        m_lyricScroll = 0;
    }
    const bool songPage = m_song.has_value() && modal.isEmpty() && !lyric && !comments;
    const bool immersive = modal == "player" || lyric;
    const bool hud = home || m_song || m_collection || m_discover || lyric || comments || modal == "saved";
    c.contentBottom = songPage ? m_height
                               : m_height - BottomGestureInset -
                                     (lyric       ? 250
                                      : immersive ? 172
                                                  : 110);
    const bool terminalPage = modal == "discover" || modal == "search" || modal == "settings";
    if (terminalPage || lyric || comments || !hud) {
        c.fill({0, 0, 393, m_height}, c.paper);
    } else if (!songPage && !home) {
        // 保留真实场景。主界面 tab 列表不加遮罩，其余页面沿用纵向阅读渐变。
        for (int y = 0; y < int(m_height); y += 8) {
            auto color = c.paper;
            const QVector<QPointF> stops{{0, .93}, {.42, .86}, {.75, .66}, {1, .95}};
            const double fraction = y / m_height;
            for (int index = 1; index < stops.size(); ++index) {
                if (fraction <= stops[index].x()) {
                    const double blend =
                        (fraction - stops[index - 1].x()) / (stops[index].x() - stops[index - 1].x());
                    color[3] = stops[index - 1].y() + (stops[index].y() - stops[index - 1].y()) * blend;
                    break;
                }
            }
            c.fill({0, double(y), 393, 8}, color);
        }
    }
    QString title = modal == "player"     ? "播放队列"
                    : modal == "search"   ? "音乐检索"
                    : modal == "saved"    ? "我的音乐"
                    : modal == "settings" ? "设置"
                    : modal == "discover" ? "发现音乐"
                    : lyric               ? "歌词"
                    : comments            ? "歌曲评论"
                    : m_song              ? "歌曲档案"
                    : m_collection        ? (m_collection->kind == "album"    ? "专辑详情"
                                             : m_collection->kind == "artist" ? "歌手档案"
                                                                              : "歌单详情")
                                          : "音乐档案";
    if (modal == "discover" && m_discover) {
        if (m_discover->tab == "history") {
            title = "播放历史";
        }
        if (m_discover->tab == "daily") {
            title = "每日推荐";
        }
        if (m_discover->tab == "artists") {
            title = "收藏歌手";
        }
    }
    if (modal == "saved" && !m_savedOverview) {
        title = source["collectionTitle"].toString("我的音乐");
    }
    if (songPage) {
        c.icon("close", 181.5, 62, 30);
        c.hit({168.5, 49, 56, 56}, "back", "关闭播放页面");
    } else if (lyric) {
        c.fill({176, 64, 41, 4}, c.line);
        c.hit({160, 60, 73, 20}, "player:lyrics-close", "关闭歌词");
        const QRectF cover{20, 86, 56, 56};
        if (!m_player.cover.isEmpty()) {
            c.image(m_player.cover, cover);
        } else {
            c.fill(cover, c.raised);
            c.border(cover, c.line);
        }
        c.text(m_player.title, 88, 90, 17, 208, "demibold");
        c.text(m_player.artist, 88, 114, 11, 208, "regular", c.muted);
        c.icon(m_player.liked ? "heart-filled" : "heart", 310, 98, 20, m_player.liked ? c.ink : c.muted);
        if (m_player.canLike) {
            c.hit({298, 86, 44, 44}, "music:like-current", m_player.liked ? "取消喜欢" : "喜欢");
        }
        c.icon("more", 352, 98, 20);
        c.hit({340, 86, 44, 44}, "mobile:song-options", "歌曲更多操作");
    } else if (terminalPage) {
        // 左右品牌信息与主页相同，中央为灵动岛保留完整留白。
        c.text("RHINE LAB", 23, 22, 17, 115, "bold");
        c.text("AUDIO TERMINAL", 23, 43, 7, 115, "regular", c.muted);
        c.rightText("RL–004", 370, 29, 7, "regular", c.muted);
        c.text(title, 20, 66, 23, 290, "demibold");
        QString code = "03";
        QString identifier = "SETTINGS / 终端配置";
        if (modal == "discover") {
            code = "01";
            identifier = "DISCOVER / 音乐观察";
        } else if (modal == "search") {
            code = "02";
            identifier = "SEARCH / 档案检索";
        }
        c.fill({20, 101, 25, 14}, c.amber);
        c.centered(code, 32.5, 108, 8, "demibold", c.ink);
        c.text(identifier, 53, 104, 7, 265, "regular", c.muted);
        c.fill({20, 120, 353, .6}, c.ink);
        // 边缘坐标刻度不进入正文，用于贯穿各研究终端页面的视觉定位。
        auto calibration = c.line;
        calibration[3] = .6;
        for (double tick = 132; tick < c.contentBottom; tick += 16) {
            c.fill({8, tick, 4, .5}, calibration);
        }
    } else if (!home) {
        c.header(title, modal != "search" && (modal != "saved" || !m_savedOverview) && modal != "discover",
                 m_collection.has_value(), !comments);
        if (comments) {
            c.text("COMMENT ARCHIVE / 评论档案", 20, 126, 8, 353, "regular", c.muted);
        }
    }
    if (modal == "saved" && !m_savedOverview) {
        for (int index = 0; index < c.hits.size(); ++index) {
            auto hit = c.hits[index].toObject();
            if (hit["action"] == "close-modal") {
                hit["action"] = "mobile:mine";
                c.hits[index] = hit;
            }
        }
    }
    if (!home && modal.isEmpty()) {
        // 详情返回现有资料库路由，不使用弹窗关闭动作。
        for (int i = 0; i < c.hits.size(); ++i) {
            auto h = c.hits[i].toObject();
            if (h["action"] == "close-modal") {
                h["action"] = lyric ? "player:lyrics-close"
                              : comments ? "music:comments-close"
                                         : "back";
                c.hits[i] = h;
            }
        }
    }
    double end = c.contentBottom;
    if (home) {
        end = archive(c, source);
        m_maximum = std::max(0., end - c.contentBottom);
        m_scroll = std::clamp(m_scroll, 0., m_maximum);
    } else {
        c.beginContent(terminalPage ? 130 : lyric || comments ? 158 : songPage ? 118 : 158);
        if (modal == "player") {
            end = queue(c, newScope, source);
        } else if (m_settings && modal == "settings") {
            end = settings(c, source);
        } else if (modal == "search" || modal == "saved") {
            end = library(c, source);
        } else if (lyric) {
            end = lyrics(c, source);
        } else if (comments) {
            end = commentsPage(c, source);
        } else if (m_discover && modal == "discover") {
            end = discover(c);
        } else if (m_song && modal.isEmpty()) {
            end = song(c, source);
        } else if (m_collection && modal.isEmpty()) {
            end = collection(c);
        } else {
            // 登录、确认、音质等辅助弹层沿用其现有动作；主页面均有明确的设计版式。
            double y = 158 - m_scroll;
            for (const auto &entry : m_auxiliary) {
                if (!entry.field.isEmpty()) {
                    c.fill({20, y, 353, 50}, c.surface);
                    c.border({20, y, 353, 50}, c.line);
                    c.field(entry.field, {20, y, 353, 50});
                    y += 62;
                } else if (!entry.action.isEmpty()) {
                    c.button({20, y, 353, 44}, entry.title, entry.action, entry.primary);
                    y += 54;
                } else if (!entry.image.isEmpty()) {
                    c.image(entry.image, {20, y, 180, 180});
                    y += 194;
                } else {
                    y = c.paragraph(entry.title, 20, y, 13, 353, c.muted) + 14;
                }
            }
            end = y + m_scroll + 20;
        }
        c.endContent();
        m_maximum = std::max(0., end - c.contentBottom);
        m_scroll = std::clamp(m_scroll, 0., m_maximum);
    }
    if (songPage) {
        const double visibleTop = c.fields.value("songPanelTop").toDouble() * m_height;
        c.field("playerBounds", {0, visibleTop, 393, m_height - visibleTop});
    } else if (lyric) {
        lyricsPlayer(c, source);
    } else {
        player(c, immersive,
               home                  ? "home"
               : modal == "discover" ? "discover"
               : modal == "search"   ? "search"
               : modal == "saved"    ? "saved"
               : modal == "settings" ? "settings"
                                     : "");
    }
    if (m_songOptionsExpanded && (m_song || m_lyricsPage)) {
        optionsSheet(c, source);
    }
    c.finish();
    m_fields = c.fields;
    commands = c.commands;
    hits = c.hits;
}
void ResponsiveHudLayout::player(ResponsiveHudCanvas &c, bool immersive, const QString &active) {
    const double top = c.contentBottom;
    c.fill({0, top, 393, m_height - top}, c.paper);
    c.fill({0, top, 393, .6}, c.line);
    const double fraction =
        m_player.durationMs > 0 ? std::clamp(m_player.positionMs / m_player.durationMs, 0., 1.) : 0;
    if (immersive) {
        c.fill({26, top + 19, 341, 2}, c.line);
        c.fill({26, top + 19, 341 * fraction, 2}, c.amber);
        if (m_player.seekable) {
            c.field("seek", {26, top + 9, 341, 24});
        }
        c.text(MusicData::time(QJsonObject{{"duration", m_player.positionMs}}), 26, top + 32, 10, 100,
               "regular", c.muted);
        c.text(MusicData::time(QJsonObject{{"duration", m_player.durationMs}}), 337, top + 32, 10, 40,
               "regular", c.muted);
        const QStringList icons{m_player.liked ? "heart-filled" : "heart", "prev",
                                m_player.playing ? "pause" : "play", "next", "queue"};
        const QStringList routes{"music:like-current", "player:prev", "player:toggle", "player:next",
                                 "player:open"};
        for (int index = 0; index < 5; ++index) {
            const double x = 26 + index * 73;
            if (index == 2) {
                c.fill({x - 4, top + 64, 52, 52}, c.amber);
            }
            c.icon(icons[index], x + 10, top + 79, 23, index == 2 ? c.paper : c.ink);
            if (index != 0 || m_player.canLike) {
                c.hit({x, top + 65, 44, 52}, routes[index],
                      QStringList{"喜欢", "上一首", m_player.playing ? "暂停" : "播放", "下一首",
                                  "队列"}[index]);
            }
        }
    } else {
        // 普通页只保留当前歌曲摘要、播放/暂停和下一首；完整控制集中到歌曲页。
        c.fill({0, top, 393 * fraction, 2}, c.amber);
        if (!m_player.cover.isEmpty()) {
            c.image(m_player.cover, {20, top + 15, 34, 34});
        } else {
            c.border({20, top + 15, 34, 34}, c.line);
        }
        c.text(m_player.title.isEmpty() ? "等待音轨" : m_player.title, 65, top + 13, 13, 202, "demibold");
        c.text(m_player.loading || m_player.failed ? m_player.status : m_player.artist, 65, top + 35, 10, 202,
               "regular", c.muted);
        c.hit({60, top + 8, 207, 48}, "player:detail", "打开当前歌曲播放页面");
        c.icon(m_player.loading ? "more" : m_player.playing ? "pause" : "play", 285, top + 24, 20);
        c.hit({273, top + 12, 44, 44}, "player:toggle", m_player.playing ? "暂停" : "播放");
        c.icon("next", 341, top + 24, 20);
        c.hit({329, top + 12, 44, 44}, "player:next", "下一首");
        const double nav = top + 67, cellWidth = 393. / 4;
        const double navHeight = std::max(0., m_height - BottomGestureInset - nav);
        c.fill({0, nav, 393, .7}, c.line);
        const QStringList routesNav{"home", "discover", "search", "settings"};
        const QStringList titles{"资料库", "发现", "搜索", "设置"};
        const QStringList captions{"ARCHIVE", "DISCOVER", "SEARCH", "SETTINGS"};
        const int activeIndex = routesNav.indexOf(active);
        if (activeIndex >= 0) {
            c.fill({tabIndicator("navigation", activeIndex * cellWidth + 12), nav, cellWidth - 24, 2},
                   c.amber);
        }
        for (int index = 0; index < 4; ++index) {
            const QRectF cell(index * cellWidth, nav, cellWidth, navHeight);
            const bool selected = active == routesNav[index];
            if (index > 0) {
                c.fill({cell.x(), nav + 10, .6, 23}, c.line);
            }
            c.centered(titles[index], cell.center().x(), nav + 15, 13, selected ? "demibold" : "regular",
                       selected ? c.ink : c.muted);
            c.centered(captions[index], cell.center().x(), nav + 31, 7, "regular", c.muted);
            c.hit(cell, routesNav[index], titles[index]);
        }
    }
    c.field("playerBounds", {0, top, 393, m_height - top});
}
QJsonObject ResponsiveHudLayout::state(QJsonObject s) const {
    if (!m_compact) {
        return s;
    }
    s["compactLayout"] = true;
    s["compactUnit"] = m_unit;
    s["archiveListY"] = m_archiveListY;
    s["songPanelTop"] = m_fields.value("songPanelTop");
    s["songPanelTransition"] = m_fields.value("songPanelTransition");
    s["modalOffset"] = 0;
    for (const auto &name : {"playerBounds", "seek", "volume"}) {
        s[name] = m_fields.contains(name) ? m_fields.value(name) : QJsonValue(QJsonValue::Null);
    }
    s["searchListWidth"] = 0;
    s["searchListHeight"] = 0;
    auto input = m_fields.value("input").toObject();
    if (input.isEmpty()) {
        for (const auto &name : {"account", "captcha", "submit"}) {
            if (m_fields.contains(name)) {
                input = m_fields[name].toObject();
                break;
            }
        }
    }
    s["inputX"] = input["x"];
    s["inputY"] = input["y"];
    s["inputWidth"] = input["width"];
    s["inputHeight"] = input["height"];
    s["compactInputVisible"] = !input.isEmpty();
    for (const auto &name : {QString("account"), QString("captcha"), QString("submit")}) {
        s["compact" + name] = m_fields.value(name);
    }
    if (s["editingSetting"].toBool()) {
        const auto setting = m_fields["setting"].toObject();
        s["editingSetting"] = !setting.isEmpty();
        s["editingSettingX"] = setting["x"];
        s["editingSettingY"] = setting["y"];
        s["editingSettingWidth"] = setting["width"];
        s["editingSettingHeight"] = setting["height"];
    }
    return s;
}
/** 接近移动内容末尾时交回原控制器续载，不把分页状态复制到布局层。 */
bool ResponsiveHudLayout::nearEnd() const {
    if (m_archiveActive) {
        return m_archiveOffset >= std::max(0., (m_archiveCount - 3) * ArchiveRowHeight);
    }
    return m_scroll >= std::max(0., m_maximum - 160);
}

bool ResponsiveHudLayout::scroll(double distance) {
    if (!m_compact || !std::isfinite(distance)) {
        return false;
    }
    // 主界面列表保留连续位移；拖动结束后由绘制阶段吸附到最近一行。
    if (m_archiveActive) {
        const double maximum = std::max(0., (m_archiveCount - 1) * ArchiveRowHeight);
        m_archiveCurve.reset();
        m_archiveLastScroll = m_time;
        m_archiveOffset = std::clamp(m_archiveOffset + distance / m_unit, 0., maximum);
        const int selected = int(std::lround(m_archiveOffset / ArchiveRowHeight));
        if (selected != m_archiveSelected) {
            m_archiveSelected = selected;
            m_archiveSelection = selected;
        }
        return true;
    }
    // 跟随播放时先接管当前动画位置，拖动不会跳回旧偏移。
    if (m_lyricsPage && m_followLyrics) {
        m_scroll = m_lyricScroll;
        m_followLyrics = false;
    }
    const double next = std::clamp(m_scroll + distance / m_unit, 0., m_maximum);
    m_scroll = next;
    return true;
}
bool ResponsiveHudLayout::handleAction(const QString &action) {
    if (!m_compact) {
        return false;
    }
    if (action == "mobile:archive-begin") {
        m_archiveDragging = true;
        m_archiveCurve.reset();
        m_archiveReleaseRequested = false;
        return true;
    }
    if (action == "mobile:archive-release") {
        m_archiveDragging = false;
        m_archiveReleaseRequested = !m_reduced;
        if (m_reduced) {
            m_archiveOffset = std::round(m_archiveOffset / ArchiveRowHeight) * ArchiveRowHeight;
            m_archiveCurve.reset();
        }
        return true;
    }
    // 主界面列表点选：直接对齐到固定槽位，再由 takeArchiveSelection 交给音乐层。
    if (m_archiveActive && action.startsWith("mobile:archive:")) {
        const int index = action.mid(15).toInt();
        const double maximum = std::max(0., (m_archiveCount - 1) * ArchiveRowHeight);
        m_archiveOffset = std::clamp(index * ArchiveRowHeight, 0., maximum);
        m_archiveCurve.reset();
        m_archiveSelection = index;
        m_archiveSelected = index;
        return true;
    }
    if (action == "mobile:mine") {
        m_savedOverview = true;
        m_scroll = 0;
        return true;
    }
    if (action == "saved") {
        m_savedOverview = true;
    }
    if (action.startsWith("music:collection:")) {
        m_savedOverview = false;
        m_scroll = 0;
    }
    if (action == "mobile:song-options") {
        m_songOptionsExpanded = !m_songOptionsExpanded;
        return true;
    }
    if (action.startsWith("music:") || action.startsWith("tab:")) {
        m_songOptionsExpanded = false;
    }
    if (action == "mobile:queue-modes") {
        m_queueModesExpanded = !m_queueModesExpanded;
        return true;
    }
    if (action.startsWith("player:mode:")) {
        m_queueModesExpanded = false;
    }
    if (action == "player:lyrics-follow") {
        m_followLyrics = true;
        m_lyricTarget.reset();
    }
    return false;
}

QPair<int, int> ResponsiveHudLayout::resultWindow(int count, bool search, bool gallery, bool liked) const {
    const double top = search ? 266 : liked ? 413 : gallery ? 211 : 294;
    const int columns = gallery ? 2 : 1;
    const double stride = gallery ? 224 : 68;
    const int rows = (count + columns - 1) / columns;
    const int first = std::clamp(int(std::floor((m_scroll + (search ? 130 : 158) - top) / stride)), 0, rows);
    const int last = std::clamp(
        int(std::ceil((m_scroll + m_height - BottomGestureInset - 110 - top) / stride)), first, rows);
    return {first * columns, std::min(count, last * columns)};
}

QVector<int> ResponsiveHudLayout::discoverVisibleIndices(const DiscoverMusicCard::Model &model) const {
    QVector<int> result;
    const double start = 130 + ((model.tabs.size() + 3) / 4) * 44 + 12;
    const double bottom = m_height - BottomGestureInset - 110;
    const auto range = [&](double top, double stride, int count) {
        const int first = std::clamp(int(std::floor((m_scroll + 130 - top) / stride)), 0, count);
        const int last = std::clamp(int(std::ceil((m_scroll + bottom - top) / stride)), first, count);
        return QPair<int, int>{first, last};
    };
    if (model.tab == "playlists") {
        if (model.loadedCount > 0 && start + 116 >= m_scroll + 130 && start <= m_scroll + bottom) {
            result.append(0);
        }
        const auto [first, last] = range(start + 157, 196, model.loadedCount / 2);
        for (int row = first; row < last; ++row) {
            for (int column = 0; column < 2; ++column) {
                const int index = 1 + row * 2 + column;
                if (index < model.loadedCount) {
                    result.append(index);
                }
            }
        }
    } else {
        const auto [first, last] =
            range(start + ((model.tools.size() + 1) / 2) * 44 + 12, 68, model.loadedCount);
        for (int index = first; index < last; ++index) {
            result.append(index);
        }
    }
    return result;
}

/** 指示条共享位置插值；再次点击时从当前画面位置接续，不会跳回上一格。 */
double ResponsiveHudLayout::tabIndicator(const QString &group, double target) {
    if (!m_indicators.contains(group)) {
        m_indicators[group] = {target, target, m_time - .24};
    }
    auto &indicator = m_indicators[group];
    const auto sample = [&] {
        const double progress = std::clamp((m_time - indicator.start) / .24, 0., 1.);
        return indicator.from + (indicator.target - indicator.from) * (1 - std::pow(1 - progress, 3));
    };
    if (target != indicator.target) {
        indicator.from = sample();
        indicator.target = target;
        indicator.start = m_time;
    }
    return m_reduced ? target : sample();
}

bool ResponsiveHudLayout::animating(double time) const {
    if (m_reduced || !m_compact) {
        return false;
    }
    for (const auto &indicator : m_indicators) {
        if (time < indicator.start + .24) {
            return true;
        }
    }
    if (m_lyricsPage && m_followLyrics && m_lyricCurve &&
        time < m_lyricCurve->start + m_lyricCurve->duration) {
        return true;
    }
    const bool unsettled =
        std::abs(m_archiveOffset - std::round(m_archiveOffset / ArchiveRowHeight) * ArchiveRowHeight) > .01;
    return m_archiveActive &&
           (m_archiveReleaseRequested || m_archiveCurve.has_value() || (!m_archiveDragging && unsettled));
}
