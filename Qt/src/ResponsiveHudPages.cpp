#include "ResponsiveHudLayout.h"
#include "MusicData.h"
#include "ProviderRegistry.h"
#include <algorithm>
#include <QHash>
#include <QJsonDocument>
#include <QUrl>

namespace {
void cover(ResponsiveHudCanvas &c, QString key, QRectF rect) {
    c.fill(rect, c.raised);
    c.image(key, rect);
    c.border(rect, c.line);
}
/** 档案索引页签共用细分隔线与琥珀色选中标记，命中高度独立于字形。 */
void indexTab(ResponsiveHudCanvas &c, QRectF rect, const QString &label, const QString &action,
              bool selected) {
    c.text(label, rect.x() + 7, rect.y() + 12, 11, rect.width() - 14, selected ? "demibold" : "regular",
           selected ? c.ink : c.muted);
    c.fill({rect.x(), rect.bottom() - 5, rect.width() - 7, .6}, c.line);
    c.hit(rect, action, label);
}
/** 将内容分组标成研究档案模块，编号承担导航层级，不额外占用正文高度。 */
void terminalSection(ResponsiveHudCanvas &c, double y, const QString &number, const QString &title,
                     const QString &caption) {
    c.fill({20, y, 23, 18}, c.ink);
    c.centered(number, 31.5, y + 9, 8, "regular", c.paper);
    c.text(title, 51, y + 2, 13, 180, "demibold");
    c.rightText(caption, 373, y + 5, 7, "regular", c.muted);
}
QString collectionPlayRoute(const QJsonObject &item) {
    const auto json = QJsonDocument(item).toJson(QJsonDocument::Compact);
    return "mobile:play-collection:" + QString::fromUtf8(QUrl::toPercentEncoding(QString::fromUtf8(json)));
}
QString settingRoute(const SettingsCard::RowModel &row) {
    return row.descriptor->binding.actionPrefix.isEmpty() ? row.descriptor->binding.action
                                                          : row.descriptor->binding.actionPrefix;
}
}
/** 主界面列表顶部；上方留给页头与真实场景，下方到迷你栏。 */
double ResponsiveHudLayout::archiveListTop() const {
    return std::max(m_height * .5, m_height - BottomGestureInset - 110. - ArchiveRowHeight * 4);
}
/** 竖屏主界面：tab 列表取代资料卡与上下切换，收藏集导航移到页头右侧。 */
double ResponsiveHudLayout::archive(ResponsiveHudCanvas &c, const QJsonObject &s) {
    const auto rows = s["archiveRows"].toArray();
    const double listTop = archiveListTop();
    m_archiveListY = listTop * c.unit;
    const int index = s["archiveIndex"].toInt(0);
    const int total = s["archiveTotal"].toInt(int(rows.size()));
    const int selected = rows.isEmpty() ? -1 : std::clamp(index, 0, int(rows.size()) - 1);
    // 下方阅读区渐入纸色，上方保持真实渲染；不覆盖唱片展示区域。
    for (double y = listTop - 32; y < m_height - BottomGestureInset - 110; y += 8) {
        auto paper = c.paper;
        paper[3] = std::clamp((y - listTop + 32) / 100., 0., .88);
        c.fill({0, y, 393, 8}, paper);
    }
    c.text("RHINE LAB", 23, 22, 17, 235, "bold");
    c.text("MUSIC ARCHIVE / 音乐资料库", 23, 43, 7, 270, "regular", c.muted);
    c.rightText("AUDIO TERMINAL / RL–004", 370, 29, 7, "regular", c.muted);
    c.fill({23, 58, 347, .6}, c.line);
    const auto sources = s["archiveSources"].toArray();
    const double tabWidth = 347. / std::max(1, int(sources.size()));
    double selectedTabX = 23;
    for (int tab = 0; tab < sources.size(); ++tab) {
        const auto source = sources[tab].toObject();
        const double x = 23 + tab * tabWidth;
        const bool active = source["selected"].toBool();
        c.text(source["label"].toString(), x + 2, 76, 10, tabWidth - 5, active ? "demibold" : "regular",
               active ? c.ink : c.muted);
        c.fill({x, 98, tabWidth - 8, .6}, c.line);
        if (active) {
            selectedTabX = x;
        }
        c.hit({x, 59, tabWidth, 44}, "mobile:source:" + QString::number(source["lane"].toInt()),
              source["label"].toString());
    }
    c.fill({tabIndicator("archive", selectedTabX), 98, tabWidth - 8, 2}, c.amber);
    c.text(s["archiveName"].toString("音乐档案"), 23, 123, 23, 244, "bold");
    if (s["canPlayArchive"].toBool()) {
        c.icon("play", 288, 126, 15);
        c.text("播放全部", 309, 127, 11, 65);
        c.hit({280, 114, 94, 44}, "mobile:play-archive", "播放全部");
    }

    c.text("上下滑动浏览 / TRACK INDEX", 23, listTop - 18, 8, 270, "regular", c.muted);
    c.rightText(total > 0 ? MusicData::pad(std::max(0, index + 1)) + " / " + QString::number(total)
                          : QString("0 / 0"),
                370, listTop - 18, 9, "regular", c.muted);
    c.fill({23, listTop - 4, 347, .7}, c.ink);
    // 四条槽位之外不绘制或接收列表输入；背景继续展示真实资料库。
    c.contentBottom = listTop + ArchiveRowHeight * 4;
    // 选中槽固定在第二行；内容按行吸附滚动，槽位上的选项立即切换。
    const double maximum = std::max(0., (rows.size() - 1) * ArchiveRowHeight);
    const QString key = s["archiveName"].toString() + ":" + QString::number(s["archiveColumnIndex"].toInt());
    if (key != m_archiveKey) {
        m_archiveKey = key;
        m_archiveSelection = -1;
        m_archiveCurve.reset();
        m_archiveDragging = false;
        m_archiveReleaseRequested = false;
        m_archiveOffset = std::clamp(selected * ArchiveRowHeight, 0., maximum);
        m_archiveSelected = selected;
    } else if (m_archiveSelection < 0 && selected != m_archiveSelected) {
        // 外部选曲（播放队列、收藏集异步更新）时让该行回到选中槽。
        m_archiveOffset = std::clamp(selected * ArchiveRowHeight, 0., maximum);
        m_archiveCurve.reset();
        m_archiveDragging = false;
        m_archiveReleaseRequested = false;
        m_archiveSelected = selected;
    }
    m_archiveCount = int(rows.size());
    const double targetOffset = std::round(m_archiveOffset / ArchiveRowHeight) * ArchiveRowHeight;
    if (!m_archiveDragging && !m_archiveCurve &&
        (m_archiveReleaseRequested || m_time - m_archiveLastScroll > .12) &&
        std::abs(m_archiveOffset - targetOffset) > .01) {
        m_archiveCurve.emplace(m_archiveOffset, targetOffset, 0, m_time, .24);
    }
    m_archiveReleaseRequested = false;
    if (m_archiveCurve) {
        m_archiveOffset = m_archiveCurve->sample(m_time)[0];
        if (m_time >= m_archiveCurve->start + m_archiveCurve->duration) {
            m_archiveOffset = targetOffset;
            m_archiveCurve.reset();
        }
    }
    const double offsetRows = m_archiveOffset / ArchiveRowHeight;
    const int slot = rows.isEmpty() ? -1 : std::clamp(int(std::lround(offsetRows)), 0, int(rows.size()) - 1);
    const double slotY = listTop + ArchiveRowHeight;
    c.beginContent(listTop);
    if (!rows.isEmpty()) {
        auto highlight = c.amber;
        highlight[3] = .14;
        c.fill({20, slotY + 2, 353, ArchiveRowHeight - 4}, highlight);
        c.fill({20, slotY + 2, 2, ArchiveRowHeight - 4}, c.amber);
    }
    const auto [first, last] =
        c.visibleRows(slotY - offsetRows * ArchiveRowHeight, ArchiveRowHeight, int(rows.size()));
    for (int row = first; row < last; ++row) {
        const double y = slotY + (row - offsetRows) * ArchiveRowHeight;
        if (y + ArchiveRowHeight <= listTop || y >= c.contentBottom) {
            continue;
        }
        const bool current = row == slot;
        const double distance = std::abs(row - offsetRows);
        auto color = current ? c.ink : c.muted;
        if (!current) {
            color[3] = std::clamp(.85 - distance * .13, .2, .85);
        }
        const auto item = rows[row].toObject();
        c.text(MusicData::pad(row + 1), 27, y + 19, 8, 23, "regular", c.muted);
        c.text(item["title"].toString(), 56, y + 14, current ? 18 : 14,
               item["kind"] == "playlist" ? 224 : 290, current ? "demibold" : "regular", color);
        if (current && item["kind"] != "playlist") {
            c.icon("right", 359, y + 16, 16, c.ink);
        }
        const double hitTop = std::max(y, listTop);
        const double hitBottom = std::min(y + ArchiveRowHeight, c.contentBottom);
        if (hitBottom - hitTop > 4) {
            c.hit({0, hitTop, 393, hitBottom - hitTop},
                  current ? "open" : "mobile:archive:" + QString::number(row), item["title"].toString());
            if (item["kind"] == "playlist" && hitBottom - hitTop >= 32) {
                c.text("▶ 全部", 309, y + 18, 10, 64);
                c.hit({302, hitTop, 71, hitBottom - hitTop}, collectionPlayRoute(item), "播放全部");
            }
        }
    }
    c.endContent();
    return c.contentBottom;
}
/** 以确认的控制区为基准布局，标题换行时整体上移，保持底部入口的完整命中区。 */
double ResponsiveHudLayout::song(ResponsiveHudCanvas &c, const QJsonObject &s) {
    const auto &model = *m_song;
    const bool current = s["selectedSongIsCurrent"].toBool();
    const double extra = c.wrap(model.title, 310, 30, "demibold").size() > 1 ? 36. : 0.;
    const double top = std::max(260., m_height - BottomGestureInset - 354. - extra);
    const double body = top + extra;
    c.fields["songPanelTop"] = top / m_height;
    c.fields["songPanelTransition"] = 32. / m_height;
    c.fill({15, top + 3, 5, 5}, c.amber);
    c.text("TRACK RECORD / 唱片档案", 28, top + 2, 7, 250, "regular", c.muted);
    c.rightText(MusicData::pad(s["archiveIndex"].toInt() + 1) + " / " +
                    QString::number(s["archiveTotal"].toInt()),
                376, top + 2, 7, "regular", c.muted);
    c.paragraph(model.title, 15, top + 27, 30, 310, {}, "demibold", 2, 1.2);
    c.text(model.artist + "   /   " + model.album, 15, body + 69, 11, 296, "regular", c.muted);
    const auto liked = s["selectedSongLiked"];
    c.border({343, top + 35, 33, 35}, c.line);
    c.icon(liked.toBool() ? "song-heart-filled" : "song-heart", 352, top + 45, 15);
    for (const auto &action : model.primaryActions) {
        if (action.route == "music:like") {
            c.hit({337, top + 30, 44, 44}, action.route, action.label);
        }
    }
    const bool playing = current && m_player.playing;
    c.commands.append(QJsonArray{"ellipse", c.amber, 15, body + 99, 4, 4});
    QString playbackState = "尚未播放";
    if (current) {
        playbackState = "已暂停";
        if (m_player.loading) {
            playbackState = "正在载入";
        } else if (playing) {
            playbackState = "正在播放";
        }
    }
    c.text(playbackState, 24, body + 97, 8, 180, "regular", c.muted);
    c.rightText("STEREO", 376, body + 97, 8, "regular", c.ink);
    c.rightText("/", 334, body + 97, 8, "regular", c.muted);
    const auto quality = [&] {
        if (!current) {
            return model.quality;
        }
        const auto id = s["playerQuality"].toString();
        const auto provider = s["provider"].toString();
        auto label = ProviderRegistry::instance().qualityDescription(provider, id)["title"].toString();
        if (label.isEmpty()) {
            label = ProviderRegistry::instance().qualityLabel(provider, id, id);
        }
        return label;
    }();
    c.rightText(quality, 320, body + 97, 8, "regular", c.amber);
    const auto time = [](double ms) {
        const int seconds = int(std::max(0., ms) / 1000);
        return MusicData::pad(seconds / 60) + ":" + MusicData::pad(seconds % 60);
    };
    c.text(current ? time(m_player.positionMs) : "00:00", 15, body + 130, 12, 100);
    c.centered("PLAYBACK POSITION", 196.5, body + 137, 7, "regular", c.muted);
    c.rightText(current ? "−" + time(m_player.durationMs - m_player.positionMs) : model.duration, 376,
                body + 130, 12, "regular", c.ink);
    const double fraction = current && m_player.durationMs > 0
                                ? std::clamp(m_player.positionMs / m_player.durationMs, 0., 1.)
                                : 0.;
    c.fill({15, body + 155, 361, 2}, c.line);
    c.fill({15, body + 155, 361 * fraction, 2}, c.amber);
    c.fill({13.5 + 361 * fraction, body + 151, 3, 10}, c.ink);
    for (int tick = 0; tick <= 20; ++tick) {
        c.fill({15 + tick * 18.05, body + 162, .6, 7}, c.line);
        if (tick % 5 == 0) {
            c.text(MusicData::pad(tick / 5), 15 + tick * 17.7, body + 175, 6, 20, "regular", c.muted);
        }
    }
    if (current && m_player.seekable) {
        c.field("seek", {15, body + 146, 361, 25});
    }
    const double centerY = body + 249;
    c.text("TRANSPORT", 15, centerY - 10, 7, 80, "regular", c.muted);
    c.text("播放控制", 15, centerY + 5, 8, 80, "regular", c.muted);
    c.rightText(playing ? "PLAYING" : "PAUSED", 376, centerY - 10, 7, "regular", c.muted);
    c.rightText("音频输出正常", 376, centerY + 5, 8, "regular", c.muted);
    for (const auto &ring : {QRectF(156.5, centerY - 40, 80, 80), QRectF(161.5, centerY - 35, 70, 70)}) {
        c.commands.append(QJsonArray{"ellipse", c.line, ring.x(), ring.y(), ring.width(), ring.height()});
        c.commands.append(QJsonArray{"ellipse", c.paper, ring.x() + .6, ring.y() + .6, ring.width() - 1.2,
                                     ring.height() - 1.2});
    }
    c.commands.append(QJsonArray{"ellipse", c.ink, 167.5, centerY - 29, 58, 58});
    c.commands.append(QJsonArray{"ellipse", c.amber, 210.5, centerY - 33, 5, 5});
    c.icon("transport-prev", 126, centerY - 8, 17);
    QString transportIcon = playing ? "transport-pause" : "play";
    if (current && m_player.loading) {
        transportIcon = "more";
    }
    c.icon(transportIcon, 185.5, centerY - 11, 22, c.paper);
    c.icon("transport-next", 250, centerY - 8, 17);
    c.hit({112, centerY - 22, 44, 44}, "player:prev", "上一首");
    c.hit({164.5, centerY - 32, 64, 64}, current ? "player:toggle" : "music:play", playing ? "暂停" : "播放");
    c.hit({236, centerY - 22, 44, 44}, "player:next", "下一首");
    // 音量整行移除，分隔线后直接进入三个带文字的工具入口。
    c.fill({15, body + 301, 361, .6}, c.line);
    c.icon("lyrics-lines", 15, body + 321, 15, c.muted);
    c.text("歌词", 36, body + 321, 11, 55, "regular", c.muted);
    if (current) {
        c.hit({10, body + 309, 82, 44}, "player:lyrics", "打开全屏歌词");
    }
    c.icon(m_player.mode == "shuffle" ? "shuffle" : "repeat", 104, body + 321, 15, c.muted);
    QString playbackMode = "顺序播放";
    if (m_player.mode == "shuffle") {
        playbackMode = "随机播放";
    } else if (m_player.mode == "one") {
        playbackMode = "单曲循环";
    }
    c.text(playbackMode, 125, body + 321, 10, 69, "regular", c.muted);
    c.hit({98, body + 309, 100, 44}, "player:mode", "切换播放模式");
    c.icon("queue-note", 210, body + 321, 15, c.muted);
    c.text("播放队列", 231, body + 321, 10, 50, "regular", c.muted);
    c.rightText(QString::number(s["playerQueueCount"].toInt()), 302, body + 322, 8, "regular", c.muted);
    c.hit({204, body + 309, 103, 44}, "player:open", "播放队列");
    c.icon("more", 322, body + 321, 15, c.muted);
    c.text("更多", 343, body + 321, 10, 36, "regular", c.muted);
    c.hit({316, body + 309, 67, 44}, "mobile:song-options", "歌曲更多操作");
    return c.contentBottom;
}
double ResponsiveHudLayout::collection(ResponsiveHudCanvas &c) {
    const auto &m = *m_collection;
    double y = 158 - m_scroll;
    cover(c, m.coverKey, {20, y + 4, 113, 113});
    c.text(m.kind.toUpper() + " / " + QString::number(m.totalCount) + " TRACKS", 150, y + 6, 8, 223,
           "regular", c.muted);
    c.paragraph(m.title, 150, y + 29, 20, 145, {}, "demibold", 2, 1.2);
    c.icon("play", 310, y + 30, 14);
    c.text("播放全部", 328, y + 32, 9, 45);
    c.hit({302, y + 19, 71, 44}, m.playAll.action, "播放全部");
    c.text(m.artist, 150, y + 92, 11, 223, "regular", c.muted);
    y += 141;
    c.button({20, y, 172, 44}, m.playAll.label, m.playAll.action, true);
    if (!m.subscribe.action.isEmpty()) {
        c.button({201, y, 172, 44}, m.subscribe.label, m.subscribe.action, false, m.subscribe.selected);
    } else {
        c.button({201, y, 172, 44}, "查看队列", "player:open");
    }
    y += 61;
    c.fill({20, y, 353, .6}, c.line);
    y += 13;
    for (const auto &fact : m.facts) {
        c.text(fact.label, 20, y, 8, 353, "regular", c.muted);
        c.text(fact.value, 20, y + 18, 12, 353);
        y += 43;
    }
    y = c.paragraph(m.quote, 20, y, 12, 353, c.muted) + 14;
    c.fill({20, y, 353, .6}, c.line);
    y += 17;
    QVector<CollectionDetailCard::Choice> tools = m.tabs;
    for (const auto &tool : {m.sort, m.rename, m.remove, m.source}) {
        if (!tool.action.isEmpty()) {
            tools.append(tool);
        }
    }
    for (int i = 0; i < tools.size(); ++i) {
        c.chip({20 + (i % 3) * 120., y + (i / 3) * 44., 113, 36}, tools[i].label, tools[i].action,
               tools[i].selected);
    }
    y += ((tools.size() + 2) / 3) * 44 + 10;
    c.section(y, m.kind == "artist" ? "热门曲目" : "曲目目录", "TRACK INDEX");
    y += 38;
    const int count = m.rowAt ? m.loadedCount : int(m.rows.size());
    const auto [first, last] = c.visibleRows(y, 68, count);
    for (int index = first; index < last; ++index) {
        const auto row = m.rowAt ? m.rowAt(index) : m.rows[index];
        c.row(y + index * 68., row.title, row.artist, row.stamp, row.action, row.number, row.current);
    }
    y += count * 68.;
    if (count == 0) {
        y = c.paragraph(m.emptyMessage, 20, y, 14, 353, c.muted) + 20;
    }
    if (!m.more.action.isEmpty()) {
        c.button({20, y, 353, 44}, m.more.label, m.more.action);
        y += 56;
    }
    return y + m_scroll + 20;
}
double ResponsiveHudLayout::discover(ResponsiveHudCanvas &c) {
    const auto &m = *m_discover;
    double y = 130 - m_scroll;
    int selectedTab = 0;
    for (int i = 0; i < m.tabs.size(); ++i) {
        if (m.tabs[i].selected) {
            selectedTab = i;
        }
        indexTab(c, {20 + (i % 4) * 90., y + (i / 4) * 44., 83, 44}, m.tabs[i].label, m.tabs[i].action,
                 m.tabs[i].selected);
    }
    c.fill({tabIndicator("discover-x", 20 + selectedTab % 4 * 90.),
            y + tabIndicator("discover-y", selectedTab / 4 * 44.) + 39, 76, 2},
           c.amber);
    y += ((m.tabs.size() + 3) / 4) * 44 + 12;
    if (m.categoryPicker) {
        for (int i = 0; i < m.categories.size(); ++i) {
            c.chip({20 + (i % 3) * 120., y + (i / 3) * 44., 113, 36}, m.categories[i].label,
                   m.categories[i].action, m.categories[i].selected);
        }
        y += ((m.categories.size() + 2) / 3) * 44;
    } else if (m.tab == "playlists" && m.loadedCount > 0) {
        const auto hero = std::find_if(m.entries.cbegin(), m.entries.cend(),
                                       [](const auto &entry) { return entry.index == 0; });
        if (hero != m.entries.cend()) {
            const auto &entry = *hero;
            c.fill({20, y, 353, 116}, c.surface);
            c.fill({20, y, 2, 116}, c.amber);
            c.text("FEATURED / 今日档案", 33, y + 12, 8, 225, "regular", c.muted);
            c.paragraph(entry.title, 33, y + 34, 18, 162, {}, "demibold", 2, 1.25);
            c.text(entry.artist, 33, y + 92, 10, 225, "regular", c.muted);
            cover(c, entry.image, {279, y + 16, 80, 80});
            c.hit({20, y, 353, 116}, "discover:item:" + QString::number(entry.index), entry.title);
            if (entry.kind == "playlist") {
                c.text("▶ 全部", 205, y + 45, 10, 62);
                c.hit({199, y + 30, 70, 44}, "mobile:play-discover:" + QString::number(entry.index),
                      "播放全部");
            }
        }
        y += 132;
        terminalSection(c, y, "01", "音乐档案", "SELECTED / " + QString::number(m.loadedCount));
        y += 25;
        for (const auto &tile : m.entries) {
            if (tile.index == 0) {
                continue;
            }
            const int i = tile.index;
            const int col = (i - 1) % 2;
            const int row = (i - 1) / 2;
            const double x = 20 + col * 184.;
            const double top = y + row * 196.;
            c.fill({x, top, 169, 144}, c.surface);
            cover(c, tile.image, {x, top, 144, 144});
            c.text(MusicData::pad(i + 1), x + 150, top + 8, 8, 19, "regular", c.muted);
            c.text(tile.title, x, top + 153, 12, 104, "demibold");
            c.text(tile.artist, x, top + 173, 9, 169, "regular", c.muted);
            // 封面越过底栏时仍允许点击可见部分，命中区不得穿透播放栏。
            const auto visibleTile =
                QRectF(x, top, 169, 186).intersected(QRectF(20, 130, 353, c.contentBottom - 130));
            if (visibleTile.height() >= 8) {
                c.hit(visibleTile, "discover:item:" + QString::number(tile.index), tile.title);
                if (tile.kind == "playlist") {
                    c.text("▶ 全部", x + 114, top + 154, 9, 55);
                    c.hit({x + 110, top + 144, 59, 42}, "mobile:play-discover:" + QString::number(tile.index),
                          "播放全部");
                }
            }
        }
        y += (m.loadedCount / 2) * 196;
    } else {
        for (int i = 0; i < m.tools.size(); ++i) {
            c.chip({20 + (i % 2) * 181., y + (i / 2) * 44., 172, 36}, m.tools[i].label, m.tools[i].action,
                   m.tools[i].selected);
        }
        y += ((m.tools.size() + 1) / 2) * 44 + 12;
        for (const auto &entry : m.entries) {
            c.row(y + entry.index * 68., entry.title, entry.artist, {},
                  "discover:item:" + QString::number(entry.index), MusicData::pad(entry.index + 1), false, {},
                  entry.kind == "playlist" ? "mobile:play-discover:" + QString::number(entry.index)
                                           : QString());
        }
        y += m.loadedCount * 68.;
    }
    if (m.loadedCount == 0 && !m.categoryPicker) {
        y = c.paragraph(m.status, 20, y + 15, 14, 353, c.muted) + 20;
    }
    if (m.more) {
        c.button({20, y, 353, 44}, m.loading ? "载入中…" : "加载更多 ↓", "discover:more");
        y += 56;
    }
    return y + m_scroll + 20;
}
double ResponsiveHudLayout::queue(ResponsiveHudCanvas &c, bool newScope, const QJsonObject &s) {
    if (newScope && m_queue.currentIndex > 0) {
        m_scroll = 251 + m_queue.currentIndex * 68.;
    }
    double y = 158 - m_scroll;
    c.fill({20, y, 353, 102}, c.surface);
    c.border({20, y, 353, 102}, c.line);
    c.text("ON AIR / 当前歌曲", 37, y + 16, 9, 319, "regular", c.muted);
    c.text(m_queue.current["title"].toString("等待音轨"), 37, y + 38, 18, 319, "demibold");
    c.text(m_queue.current["artist"].toString(), 37, y + 72, 11, 319, "regular", c.muted);
    y += 121;
    c.text("PLAYBACK MODE / 播放模式", 20, y, 9, 353, "regular", c.muted);
    y += 24;
    const QStringList modes{"off", "all", "one", "shuffle"},
        labels{"顺序播放", "列表循环", "单曲循环", "随机播放"};
    c.button({20, y, 353, 44}, labels.value(modes.indexOf(m_queue.mode), "顺序播放") + "  ▾",
             "mobile:queue-modes");
    y += 61;
    if (m_queueModesExpanded) {
        for (int i = 0; i < 4; ++i) {
            c.chip({20 + (i % 2) * 181., y + (i / 2) * 44., 172, 36}, labels[i], "player:mode:" + modes[i],
                   m_queue.mode == modes[i]);
        }
        y += 96;
    }
    c.section(y, "播放队列  " + QString::number(m_queue.tracks.size()));
    c.text("清空队列", 310, y + 4, 12, 63, "regular", c.muted);
    c.hit({291, y - 5, 82, 44}, "player:clear", "清空队列");
    y += 45;
    const auto [first, last] = c.visibleRows(y, 68, int(m_queue.tracks.size()));
    for (int index = first; index < last; ++index) {
        const auto track = m_queue.tracks[index].toObject();
        c.row(y + index * 68., track["title"].toString(), track["artist"].toString(), MusicData::time(track),
              "player:queue:" + QString::number(index),
              index == m_queue.currentIndex ? "●" : MusicData::pad(index + 1), index == m_queue.currentIndex,
              index == m_queue.currentIndex ? QString() : "player:remove:" + QString::number(index));
    }
    y += m_queue.tracks.size() * 68.;
    if (m_queue.tracks.isEmpty()) {
        c.text("播放队列为空", 20, y + 20, 17, 353);
        y += 70;
    }
    y = c.paragraph("清空仅移除待播歌曲，当前歌曲继续播放。", 20, y + 14, 12, 353, c.muted) + 24;
    if (m_player.applicationVolume) {
        c.text("OUTPUT / 音量", 20, y, 9, 353, "regular", c.muted);
        c.fill({20, y + 31, 353, 2}, c.line);
        c.fill({20, y + 31, 353 * std::clamp(m_player.volume, 0., 1.), 2}, c.ink);
        c.field("volume", {20, y + 16, 353, 32});
        y += 62;
    }
    return std::max(y + m_scroll + 20,
                    409. + std::max(0, int(m_queue.tracks.size()) - 1) * 68. + c.contentBottom - 158);
}
double ResponsiveHudLayout::settings(ResponsiveHudCanvas &c, const QJsonObject &s) {
    double y = 130 - m_scroll;
    c.fill({20, y, 353, 96}, c.surface);
    c.fill({20, y, 2, 96}, c.amber);
    c.text("ACCESS / 音乐平台", 33, y + 12, 8, 220, "regular", c.muted);
    c.text(s["providerName"].toString(), 33, y + 32, 18, 210, "demibold");
    c.text("切换平台 ↗", 281, y + 15, 10, 83);
    c.hit({269, y, 104, 44}, "provider", "切换音乐平台");
    const bool logged = s["loggedIn"].toBool();
    c.text(logged ? s["userName"].toString() : "尚未登录", 33, y + 71, 10, 205, "regular", c.muted);
    c.text(logged ? "退出登录 ↗" : "登录账号 ↗", 281, y + 71, 10, 83, "regular", c.muted);
    c.hit({269, y + 52, 104, 44}, logged ? "music:logout" : "music:login", logged ? "退出登录" : "登录");
    y += 116;
    int sectionNumber = 1;
    for (const auto &section : m_settings->sections) {
        if (!section.meta->customRenderer.isEmpty()) {
            if (section.meta->customRenderer == "provider-card") {
                continue;
            }
            terminalSection(c, y, MusicData::pad(sectionNumber++), section.meta->titleZh,
                            section.meta->titleEn);
            y += 27;
            for (const auto &item : m_settingsCustom.value(section.meta->customRenderer)) {
                if (!item.field.isEmpty()) {
                    continue;
                }
                if (!item.action.isEmpty()) {
                    c.button({20, y, 353, 44}, item.title, item.action);
                    y += 54;
                } else {
                    y = c.paragraph(item.title, 20, y, 12, 353, c.muted) + 12;
                }
            }
            y += 14;
            continue;
        }
        terminalSection(c, y, MusicData::pad(sectionNumber++), section.meta->titleZh, section.meta->titleEn);
        y += 27;
        for (const auto &row : section.rows) {
            const auto *d = row.descriptor;
            c.fill({20, y + 55, 353, .6}, c.line);
            c.text(d->titleZh, 20, y + 19, 12, 170);
            if (d->showDescription) {
                c.paragraph(d->description, 20, y + 34, 9, 165, c.muted, "regular", 2);
            }
            if (d->kind == SettingsSchema::SettingKind::TextInput && s["editingSettingId"] == d->id) {
                c.fill({201, y + 4, 172, 44}, c.raised);
                c.field("setting", {201, y + 4, 172, 44});
            } else if (d->kind == SettingsSchema::SettingKind::Slider ||
                       d->kind == SettingsSchema::SettingKind::Stepper) {
                c.text(row.label, 201, y + 19, 11, 70, "regular", c.muted);
                c.button({279, y + 4, 44, 44}, "−",
                         row.enabled ? settingRoute(row) + row.decrementValue : QString());
                c.button({329, y + 4, 44, 44}, "+",
                         row.enabled ? settingRoute(row) + row.incrementValue : QString());
            } else {
                const bool choice = d->kind == SettingsSchema::SettingKind::Choice ||
                                    d->kind == SettingsSchema::SettingKind::Switch;
                const QString route = !row.enabled ? QString()
                                      : choice     ? "expand:" + d->id
                                      : d->kind == SettingsSchema::SettingKind::TextInput
                                          ? "setting-edit:" + d->id
                                          : d->binding.action;
                c.fill({201, y + 9, 172, 34}, c.surface);
                c.text(d->actionLabel.isEmpty() ? row.label : d->actionLabel, 211, y + 19, 11, 137, "regular",
                       c.muted);
                c.text(choice ? "⌄" : "↗", 355, y + 18, 12, 16, "regular", c.muted);
                c.hit({195, y + 4, 178, 44}, route, d->titleZh);
            }
            y += 56;
            if (row.expanded) {
                for (const auto &option : row.choices) {
                    c.chip({20, y, 353, 40}, option.label, settingRoute(row) + option.value,
                           option.value == row.value.canonical);
                    y += 48;
                }
            }
        }
        y += 14;
    }
    return y + m_scroll + 20;
}
/** 竖屏音乐平台页 */
double ResponsiveHudLayout::providerPage(ResponsiveHudCanvas &c, const QJsonObject &s) {
    double y = 158 - m_scroll;
    auto muted = c.muted;
    const auto providers = s["providers"].toArray();
    terminalSection(c, y, "01", "音乐平台", "PROVIDER ACCESS");
    y += 26;
    if (providers.isEmpty()) {
        y = c.paragraph("当前没有可用的音乐平台。", 20, y, 12, 353, muted) + 16;
    }
    for (const auto &value : providers) {
        const auto item = value.toObject();
        const auto id = item["id"].toString();
        const auto name = item["name"].toString();
        const bool selected = item["selected"].toBool();
        constexpr double rowHeight = 64;
        if (selected) {
            c.fill({20, y, 353, rowHeight}, c.raised);
            c.fill({20, y, 2, rowHeight}, c.amber);
        }
        c.text(name, 32, y + 10, 15, 208, "demibold");
        c.rightText(item["label"].toString(), 361, y + 13, 8, "regular", muted);
        c.text(item["detail"].toString(), 32, y + 34, 10, 240, "regular", muted);
        c.rightText(selected ? "当前平台" : "切换 →", 361, y + 35, 10, selected ? "demibold" : "regular",
                    selected ? c.amber : muted);
        c.fill({20, y + rowHeight - .6, 353, .6}, c.line);
        c.hit({20, y, 353, rowHeight}, "provider:" + id, "切换到 " + name);
        y += rowHeight;
    }
    y += 18;
    terminalSection(c, y, "02", "第三方平台插件", "PLUGINS");
    y += 26;
    c.indexRow(y, "插件市场", "安装与管理第三方平台插件", "plugins", "database");
    y += 74;
    terminalSection(c, y, "03", "账号与歌单", "ACCOUNT");
    y += 26;
    if (s["localMusic"].toBool()) {
        c.text(s["providerName"].toString(), 20, y + 8, 15, 353, "demibold");
        c.text("本地索引 / 无需账号，文件保留在原目录", 20, y + 30, 10, 353, "regular", muted);
        y += 50;
        c.button({20, y, 353, 44}, "文件夹管理 ＋", "discover");
        y += 58;
    } else if (s["provider"].toString() == "siren") {
        c.text(s["providerName"].toString(), 20, y + 8, 15, 353, "demibold");
        y = c.paragraph("官网曲库 / 无需登录", 20, y + 30, 10, 353, muted) + 14;
    } else {
        const bool logged = s["loggedIn"].toBool();
        c.text(s["providerName"].toString(), 20, y + 8, 15, 240, "demibold");
        c.rightText(logged ? "已登录" : "未登录", 373, y + 11, 10, "regular", logged ? c.ink : muted);
        c.text(logged ? s["userName"].toString() : "登录后可同步收藏与歌单", 20, y + 30, 10, 353, "regular",
               muted);
        y += 50;
        c.button({20, y, 353, 44}, "账号登录 / " + s["providerName"].toString(), "music:login");
        y += 58;
    }
    const auto editors = s["providerPlaylistEditors"].toArray();
    if (!editors.isEmpty()) {
        QStringList names;
        for (const auto &value : editors) {
            names.append(value.toString());
        }
        y = c.paragraph("支持歌单编辑：" + names.join("、"), 20, y, 10, 353, muted) + 10;
    } else {
        y = c.paragraph("平台能力由插件声明。", 20, y, 10, 353, muted) + 10;
    }
    y = c.paragraph("切换平台会停止当前播放，各平台账号与个人音乐独立保存。", 20, y, 10, 353, muted) + 16;
    return y + m_scroll + 20;
}

/** 竖屏插件页：市场与已安装分组排列，操作按钮保持 44 pt 触摸高度。 */
double ResponsiveHudLayout::pluginsPage(ResponsiveHudCanvas &c, const QJsonObject &s) {
    double y = 158 - m_scroll;
    auto muted = c.muted;
    const auto marketplace = s["pluginMarketplace"].toObject();
    const auto market = marketplace["plugins"].toArray();
    const auto installed = s["pluginInstalled"].toArray();
    QHash<QString, QString> installedVersions;
    for (const auto &value : installed) {
        const auto entry = value.toObject();
        installedVersions.insert(entry["id"].toString(), entry["version"].toString());
    }
    terminalSection(c, y, "01", "插件市场", "MARKETPLACE");
    y += 26;
    if (s["pluginImportAvailable"].toBool()) {
        c.button({20, y, 172, 44}, "导入文件夹", "plugin:import");
        c.button({201, y, 172, 44}, "刷新", "plugin:refresh");
    } else {
        c.button({20, y, 353, 44}, "刷新市场", "plugin:refresh");
    }
    y += 56;
    const bool installing = marketplace["installing"].toBool();
    auto status = marketplace["status"].toString("尚未读取插件市场");
    if (installing) {
        status += "  " + QString::number(marketplace["installFilesDone"].toInt()) + "/" +
                  QString::number(marketplace["installFilesTotal"].toInt()) + "  " +
                  QString::number(marketplace["installSpeed"].toDouble() / (1024.0 * 1024.0), 'f', 1) +
                  " MB/s";
    }
    y = c.paragraph(status, 20, y, 10, 353, muted) + 8;
    if (installing) {
        const auto progress = std::clamp(marketplace["installProgress"].toDouble(), 0., 1.);
        c.fill({20, y, 353, 3}, c.line);
        c.fill({20, y, 353 * progress, 3}, c.amber);
        y += 12;
    }
    if (market.isEmpty()) {
        c.fill({20, y, 353, 92}, c.surface);
        c.text("暂无可用插件", 33, y + 16, 14, 327, "demibold");
        c.paragraph(marketplace["url"].toString().isEmpty() ? "设置 RHINE_PLUGIN_MARKETPLACE_URL 后刷新。"
                                                            : "市场索引为空，或当前网络不可用。",
                    33, y + 40, 10, 327, muted, "regular", 2);
        y += 104;
    }
    for (int index = 0; index < market.size(); ++index) {
        const auto value = market.at(index).toObject();
        const auto id = value["id"].toString();
        const auto version = value["version"].toString();
        const auto current = installedVersions.value(id);
        const bool busy = installing && marketplace["installId"].toString() == id;
        const bool canUpdate = !current.isEmpty() && current != version;
        if (busy) {
            c.fill({20, y, 353, 96}, c.raised);
        }
        c.text(value["name"].toString(id), 20, y + 10, 14, 225, "demibold");
        auto meta = id;
        if (!version.isEmpty()) {
            meta += " / 市场版本 " + version;
        }
        if (!current.isEmpty()) {
            meta += " / 已安装 " + current;
        }
        c.text(meta, 20, y + 32, 9, 230, "regular", canUpdate ? c.ink : muted);
        c.paragraph(value["description"].toString(), 20, y + 50, 10, 230, muted, "regular", 2);
        const auto label =
            busy ? QStringLiteral("安装中…")
                 : (current.isEmpty() ? QStringLiteral("安装")
                                      : (canUpdate ? QStringLiteral("更新") : QStringLiteral("重新安装")));
        c.button({261, y + 10, 112, 40}, label, busy ? QString() : "plugin:market:" + id,
                 current.isEmpty() && !busy);
        c.fill({20, y + 94, 353, .6}, c.line);
        y += 96;
    }
    y += 12;
    terminalSection(c, y, "02", "已安装", "INSTALLED / " + QString::number(installed.size()));
    y += 26;
    if (installed.isEmpty()) {
        c.text("尚未安装插件", 20, y + 4, 14, 353, "demibold");
        c.paragraph("从上方市场安装，或使用“导入文件夹”添加本地插件。", 20, y + 28, 10, 353, muted, "regular",
                    2);
        y += 76;
    }
    for (const auto &value : installed) {
        const auto entry = value.toObject();
        const auto id = entry["id"].toString();
        const bool enabled = entry["enabled"].toBool();
        const bool userInstalled = entry["userInstalled"].toBool();
        c.text(entry["name"].toString(id), 20, y + 10, 14, 250, "demibold");
        c.rightText(enabled ? "已启用" : "已禁用", 373, y + 10, 9, "regular", enabled ? c.ink : muted);
        c.fill({373 - c.measure(enabled ? "已启用" : "已禁用", 9) - 11, y + 14, 5, 5},
               enabled ? c.amber : muted);
        c.text(id + " / " + entry["version"].toString() + " / " + entry["publisher"].toString(), 20, y + 31,
               9, 340, "regular", muted);
        if (userInstalled) {
            c.button({20, y + 50, 111, 44}, "详情", "plugin:detail:" + id);
            c.button({131, y + 50, 111, 44}, "卸载", "plugin:uninstall:" + id);
            c.button({242, y + 50, 131, 44}, enabled ? "禁用" : "启用", "plugin:toggle:" + id);
        } else {
            c.button({20, y + 50, 172, 44}, "详情", "plugin:detail:" + id);
            c.button({201, y + 50, 172, 44}, enabled ? "禁用" : "启用", "plugin:toggle:" + id);
        }
        c.fill({20, y + 104, 353, .6}, c.line);
        y += 106;
    }
    auto footer = s["pluginMessage"].toString();
    if (footer.isEmpty()) {
        footer = QStringLiteral("插件下载到应用数据目录；禁用后不会加载。");
    }
    y = c.paragraph(footer, 20, y + 10, 10, 353, muted) + 20;
    return y + m_scroll + 20;
}

/** 竖屏插件详情：字段两列对齐，窄屏上仍保留完整版本、来源与操作。 */
double ResponsiveHudLayout::pluginDetailPage(ResponsiveHudCanvas &c, const QJsonObject &s) {
    double y = 158 - m_scroll;
    auto muted = c.muted;
    const auto detail = s["pluginDetail"].toObject();
    if (detail.isEmpty()) {
        c.text("插件不可用", 20, y, 17, 353, "demibold");
        y = c.paragraph("该插件可能已被卸载，或市场索引已经更新。", 20, y + 30, 10, 353, muted) + 20;
        return y + m_scroll + 20;
    }
    const auto id = detail["id"].toString();
    const bool installed = detail["installed"].toBool();
    const bool enabled = detail["enabled"].toBool();
    const bool userInstalled = detail["userInstalled"].toBool();
    const auto name = detail["display"].toObject()["name"].toString(detail["name"].toString(id));
    y = c.paragraph(name, 20, y, 22, 353, {}, "demibold", 2, 1.2) + 8;
    c.text(id + " / " + detail["version"].toString(), 20, y, 10, 353, "regular", muted);
    y += 24;
    c.fill({20, y, 353, 1}, c.ink);
    y += 16;
    int capabilities = 0;
    const auto values = detail["capabilities"].toObject();
    for (auto it = values.begin(); it != values.end(); ++it) {
        capabilities += it.value().toBool() ? 1 : 0;
    }
    constexpr double colWidth = 169;
    const auto field = [&](const QString &label, const QString &value, double fx, double fy, double width) {
        c.text(label, fx, fy, 8, width, "regular", muted);
        c.text(value.isEmpty() ? QStringLiteral("—") : value, fx, fy + 16, 12, width);
    };
    field("PUBLISHER / 发布者", detail["publisher"].toString(), 20, y, colWidth);
    field("LICENSE / 许可证", detail["license"].toString(), 204, y, colWidth);
    y += 46;
    field("CAPABILITIES / 能力", QString::number(capabilities) + " 项", 20, y, colWidth);
    field("SOURCE / 来源", userInstalled ? QStringLiteral("用户安装") : QStringLiteral("内置"), 204, y,
          colWidth);
    y += 46;
    field("ENTRY / 入口", detail["entry"].toObject()["file"].toString(), 20, y, 353);
    y += 46;
    field("STATE / 状态",
          installed ? (enabled ? QStringLiteral("已安装 / 已启用") : QStringLiteral("已安装 / 已禁用"))
                    : QStringLiteral("未安装"),
          20, y, 353);
    y += 52;
    if (installed) {
        c.button({20, y, 172, 44}, enabled ? "禁用插件" : "启用插件", "plugin:toggle:" + id);
        c.button({201, y, 172, 44}, "回滚上一版本", "plugin:rollback:" + id);
        y += 56;
        if (userInstalled) {
            c.button({20, y, 353, 44}, "卸载插件", "plugin:uninstall:" + id);
            y += 56;
        }
    } else {
        c.button({20, y, 353, 44}, "安装插件", "plugin:market:" + id, true);
        y += 56;
    }
    if (!s["pluginMessage"].toString().isEmpty()) {
        y = c.paragraph(s["pluginMessage"].toString(), 20, y + 8, 10, 353, muted) + 20;
    }
    return y + m_scroll + 20;
}

double ResponsiveHudLayout::library(ResponsiveHudCanvas &c, const QJsonObject &s) {
    double y = (s["modal"] == "search" ? 130 : 158) - m_scroll;
    const bool search = s["modal"] == "search";
    const auto columns = s["collectionLabels"].toArray();
    if (!search && m_savedOverview) {
        c.fill({20, y, 353, 102}, c.surface);
        c.border({20, y, 353, 102}, c.line);
        c.text("PERSONAL MUSIC DATABASE", 37, y + 16, 9, 319, "regular", c.muted);
        c.text("我的音乐", 37, y + 38, 18, 319, "demibold");
        c.text(s["providerName"].toString() + " / " + s["userName"].toString(), 37, y + 73, 11, 319,
               "regular", c.muted);
        y += 126;
        c.section(y, "收藏与档案", "PERSONAL INDEX");
        y += 36;
        for (int lane = 1; lane < columns.size(); ++lane) {
            c.indexRow(y, columns[lane].toString(), lane == 1 ? "PERSONAL TRACKS" : "COLLECTION ARCHIVE",
                       "music:collection:" + QString::number(lane), lane == 1 ? "heart" : "folder");
            y += 68;
        }
        bool hasArtists = false;
        for (const auto &tab : ProviderRegistry::instance().discoverTabs(s["provider"].toString())) {
            if (tab.toObject()["id"].toString() == "artists") {
                hasArtists = true;
                break;
            }
        }
        if (hasArtists) {
            c.indexRow(y, "收藏歌手", "ARTIST RECORDS", "mobile:artists", "user");
            y += 68;
        }
        c.indexRow(y, "播放历史", "RECENT TRACKS", "mobile:history", "compass");
        y += 68;
        c.indexRow(y, "设置", "TERMINAL PREFERENCES", "settings", "settings");
        y += 68;
        if (s["canCreatePlaylist"].toBool()) {
            c.button({20, y, 353, 44}, "+ 创建歌单", "music:create-playlist");
            y += 60;
        }
        return y + m_scroll + 20;
    }
    const auto entries = s["resultRows"].toArray();
    const int resultCount = s["resultTotalCount"].toInt(int(entries.size()));
    if (!search && s["musicCollection"].toInt() == 1) {
        c.text("PERSONAL ARCHIVE / " + QString::number(resultCount) + " TRACKS", 20, y, 9, 353, "regular",
               c.muted);
        y += 25;
        c.border({20, y, 353, 150}, c.line);
        c.text("COLLECTION / 收藏资料库", 32, y + 13, 8, 329, "regular", c.muted);
        c.text("喜欢的歌曲", 32, y + 108, 24, 329, "demibold");
        y += 167;
        c.button({20, y, 172, 44}, "▶ 播放全部", "mobile:play-liked", true);
        c.button({201, y, 172, 44}, "查看队列", "player:open");
        y += 63;
        for (int index = 0; index < entries.size(); ++index) {
            auto entry = entries[index].toObject();
            const int row = entry["index"].toInt(index);
            auto value = entry["value"].toObject();
            c.row(y + row * 68., value["title"].toString(), value["artist"].toString(),
                  MusicData::time(value), entry["action"].toString(), MusicData::pad(row + 1));
        }
        y += resultCount * 68.;
        return y + m_scroll + 20;
    }
    const bool gallery =
        !search && !entries.isEmpty() && entries[0].toObject()["value"].toObject()["kind"] != "song";
    if (gallery) {
        for (int index = 2; index < columns.size(); ++index) {
            c.chip({20 + (index - 2) * 120., y, 113, 36}, columns[index].toString(),
                   "music:collection:" + QString::number(index), s["musicCollection"].toInt() == index);
        }
        y += 53;
        for (int index = 0; index < entries.size(); ++index) {
            auto entry = entries[index].toObject();
            auto value = entry["value"].toObject();
            const int row = entry["index"].toInt(index);
            const double x = 20 + (row % 2) * 184.;
            const double top = y + (row / 2) * 224.;
            cover(c, value["image"].toString(), {x, top, 169, 169});
            c.text(value["title"].toString(), x, top + 179, 13, 104, "demibold");
            c.text(value["artist"].toString(), x, top + 201, 10, 169, "regular", c.muted);
            c.hit({x, top, 169, 217}, entry["action"].toString(), value["title"].toString());
            if (value["kind"] == "playlist") {
                c.text("▶ 全部", x + 114, top + 180, 9, 55);
                c.hit({x + 110, top + 169, 59, 44}, collectionPlayRoute(value), "播放全部");
            }
        }
        return y + m_scroll + ((resultCount + 1) / 2) * 224 + 20;
    }
    c.fill({20, y, 353, 47}, c.surface);
    c.border({20, y, 353, 47}, c.line);
    c.icon("search", 32, y + 15, 17);
    c.field("input", {58, y, 277, 47});
    c.icon("right", 345, y + 15, 17);
    c.hit({329, y, 44, 47}, "mobile:search-submit", "检索");
    y += 54;
    const QStringList labels = search ? QStringList{"歌曲", "歌手", "专辑", "歌单"}
                                      : QStringList{columns[1].toString(), columns[2].toString(),
                                                    columns[3].toString(), columns[4].toString()};
    const QVector<int> order = search ? QVector<int>{0, 3, 1, 2} : QVector<int>{1, 2, 3, 4};
    int selectedType = 0;
    for (int i = 0; i < 4; ++i) {
        if (search && s["searchKind"] == QStringList{"song", "artist", "album", "playlist"}[i]) {
            selectedType = i;
        } else if (!search && s["musicCollection"].toInt() == order[i]) {
            selectedType = i;
        }
        indexTab(c, {20 + i * 90., y, 83, 44}, labels[i],
                 search ? "music:kind:" + QString::number(order[i])
                        : "music:collection:" + QString::number(order[i]),
                 search ? s["searchKind"] == QStringList{"song", "artist", "album", "playlist"}[i]
                        : s["musicCollection"].toInt() == order[i]);
    }
    c.fill({tabIndicator(search ? "search" : "collections", 20 + selectedType * 90.), y + 39, 76, 2},
           c.amber);
    y += 53;
    terminalSection(c, y, "01", search ? "检索结果" : "音乐档案", "INDEX / " + QString::number(resultCount));
    y += 29;
    for (int i = 0; i < entries.size(); ++i) {
        auto entry = entries[i].toObject();
        auto value = entry["value"].toObject();
        const int row = entry["index"].toInt(i);
        c.row(y + row * 68., value["title"].toString(), value["artist"].toString(), MusicData::time(value),
              entry["action"].toString(), MusicData::pad(row + 1));
    }
    y += resultCount * 68.;
    if (resultCount == 0) {
        c.fill({20, y + 8, 353, .6}, c.line);
        c.icon("search", 20, y + 30, 24, c.muted);
        const bool emptyQuery = s["query"].toString().trimmed().isEmpty();
        c.text(emptyQuery ? "检索音乐档案" : "暂无匹配档案", 60, y + 30, 16, 310, "demibold");
        y = c.paragraph(emptyQuery ? "输入歌曲、歌手、专辑或歌单名称" : s["status"].toString(), 60, y + 60,
                        11, 308, c.muted) +
            24;
        if (!search && !s["loggedIn"].toBool()) {
            c.button({20, y, 353, 44}, "登录音乐平台 →", "music:login");
            y += 60;
        }
    }
    return y + m_scroll + 20;
}
