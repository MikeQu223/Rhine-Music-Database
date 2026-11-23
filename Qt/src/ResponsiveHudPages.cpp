#include "ResponsiveHudLayout.h"
#include "MusicData.h"
#include "ProviderRegistry.h"
#include <algorithm>
#include <cmath>
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
    const auto rawIndices = s["archiveRawIndices"].toArray();
    m_archiveSourceIndices.clear();
    for (const auto &value : rawIndices) {
        m_archiveSourceIndices.append(value.toInt());
    }
    const double listTop = archiveListTop();
    const bool playlistDirectory = s["archivePlaylist"].toBool();
    m_archiveListY = listTop * c.unit;
    const int index = s["archiveIndex"].toInt(0);
    const int total = s["archiveTotal"].toInt(int(rows.size()));
    const int selected = rows.isEmpty() ? -1 : std::clamp(index, 0, int(rows.size()) - 1);
    // 歌单工具栏需要更早进入纸色遮罩，避免复杂背景穿透按钮文字。
    const double maskStart = listTop - (playlistDirectory ? 112. : 32.);
    const double maskDistance = playlistDirectory ? 118. : 100.;
    for (double y = maskStart; y < m_height - BottomGestureInset - 110; y += 8) {
        auto paper = c.paper;
        paper[3] = playlistDirectory ? std::clamp((y - maskStart) / maskDistance, 0., 1.) * .88
                                     : std::clamp((y - listTop + 32.) / 100., 0., .88);
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
    const auto countBadge = QString::number(total);
    const double countBadgeWidth =
        playlistDirectory ? std::clamp(c.measure(countBadge, 10, "demibold") + 18., 34., 62.) : 0.;
    const double countBadgeX = 370. - countBadgeWidth;
    c.text(s["archiveName"].toString("音乐档案"), 23, 123, 23, playlistDirectory ? countBadgeX - 35. : 244,
           "bold");
    if (playlistDirectory) {
        c.fill({countBadgeX, 121, countBadgeWidth, 24}, c.ink);
        c.centered(countBadge, countBadgeX + countBadgeWidth / 2., 133, 10, "demibold", c.paper);
    }
    if (!playlistDirectory && s["canPlayArchive"].toBool()) {
        c.icon("play", 288, 126, 15);
        c.text("播放全部", 309, 127, 11, 65);
        c.hit({280, 114, 94, 44}, "mobile:play-archive", "播放全部");
    }

    if (playlistDirectory) {
        constexpr double actionHeight = 54.;
        constexpr double actionGap = 6.;
        constexpr double sideWidth = 90.;
        const double actionTop = listTop - 68.;
        const double playWidth = 353. - sideWidth * 2. - actionGap * 2.;
        const auto sortField = s["archiveSort"].toString();
        QString sortLabel = QStringLiteral("默认");
        if (sortField == "title") {
            sortLabel = QStringLiteral("歌名");
        } else if (sortField == "artist") {
            sortLabel = QStringLiteral("歌手");
        } else if (sortField == "album") {
            sortLabel = QStringLiteral("专辑");
        }
        const bool playEnabled = s["archivePlayEnabled"].toBool();
        const auto playAction = playEnabled ? s["archivePlayAction"].toString() : QString();
        c.actionButton({20, actionTop, playWidth, actionHeight}, "play", "播放全部", playAction, playEnabled,
                       false, playEnabled);
        c.actionButton({20 + playWidth + actionGap, actionTop, sideWidth, actionHeight}, "search", "搜索",
                       "mobile:playlist-search");
        c.actionButton(
            {20 + playWidth + actionGap + sideWidth + actionGap, actionTop, sideWidth, actionHeight}, "sort",
            sortLabel, "mobile:playlist-sort", false, sortField != "none");
    } else {
        const double trackLabelY = listTop - 18.;
        c.text("上下滑动浏览 / TRACK INDEX", 23, trackLabelY, 8, 270, "regular", c.muted);
        c.rightText(total > 0 ? MusicData::pad(std::max(0, index + 1)) + " / " + QString::number(total)
                              : QString("0 / 0"),
                    370, trackLabelY, 9, "regular", c.muted);
    }
    c.fill({23, listTop - 4, 347, .7}, c.ink);
    // 四条槽位之外不绘制或接收列表输入；背景继续展示真实资料库。
    c.contentBottom = listTop + ArchiveRowHeight * 4;
    // 选中槽固定在第二行；内容按行吸附滚动，槽位上的选项立即切换。
    const double maximum = std::max(0., (rows.size() - 1) * ArchiveRowHeight);
    const QString key = s["archiveKey"].toString(s["archiveName"].toString() + ":" +
                                                 QString::number(s["archiveColumnIndex"].toInt()));
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

/** 测量歌曲页的标题与底部固定区域，剩余空间交给 3D 展示区。 */
ResponsiveHudLayout::SongLayout ResponsiveHudLayout::songLayout(Glyphs &glyphs) const {
    SongLayout layout;
    if (!m_song) {
        return layout;
    }
    const int titleLines = std::clamp(int(glyphs.wrap(m_song->title, 310, 30, "demibold").size()), 1, 2);
    // 两行标题预留固定空间，避免切歌时把共享控制区整体上推。
    constexpr double titleReserve = 36.;
    layout.bodyOffset = titleLines > 1 ? titleReserve : 0.;
    layout.infoTop = TopSafeInset + NavigationHitHeight + SongInfoGap;
    layout.lyricsTop = layout.infoTop + SongInfoHeight + SongInfoGap;
    // 保持现有歌曲页比例，只在当前面板内部优化信息、进度与控制区。
    layout.panelTop = std::max(260., m_height - BottomGestureInset - 354. - titleReserve);
    // 播放控制区整体上移，同时把进度行比播放键多上移 10pt，
    // 让播放键上下两侧都获得更充足的呼吸空间。
    layout.progressTop = layout.panelTop + titleReserve + 110.;
    layout.transportTop = layout.panelTop + titleReserve + 183.;
    layout.utilityTop = layout.panelTop + titleReserve + 309.;
    layout.panelTransition = std::clamp(m_height * .052, 40., 56.);
    return layout;
}

/** 以固定的底部功能区为基准布局，标题换行时只压缩 3D 区域。 */
double ResponsiveHudLayout::song(ResponsiveHudCanvas &c, const QJsonObject &s) {
    const auto &model = *m_song;
    double resultBottom = c.contentBottom;
    const bool current = s["selectedSongIsCurrent"].toBool();
    const auto &layout = m_songLayout;
    const double top = layout.panelTop;
    const double lyricProgress = std::clamp(s["playerModeProgress"].toDouble(0.), 0., 1.);
    const bool lyricTarget = s["lyricsMode"].toBool();
    const auto colorGroups = s["lyricsColors"].toObject();
    const auto useGroup = [&](const char *name) {
        if (lyricTarget || lyricProgress > .001) {
            c.setForeground(colorGroups.value(QLatin1String(name)).toObject());
        }
    };
    useGroup("top");
    const double controlsOpacity = lyricTarget
                                        ? std::clamp(s["lyricsControlsOpacity"].toDouble(1.), 0., 1.)
                                        : 1.;
    const double controlsOffset = lyricTarget ? s["lyricsControlsOffset"].toDouble(0.) : 0.;
    const auto smooth = [](double value) {
        const double clamped = std::clamp(value, 0., 1.);
        return clamped * clamped * (3. - 2. * clamped);
    };
    const double infoEase = smooth((lyricProgress - .02) / .78);
    const double infoOut = 1. - smooth((lyricProgress - .02) / .58);
    const double infoIn = smooth((lyricProgress - .28) / .62);
    c.fields["songPanelTop"] = top / m_height;
    c.fields["songPanelTransition"] = layout.panelTransition / m_height;
    const double body = top + layout.bodyOffset;
    const double titleTop = top + 27.;
    c.save();
    c.alpha(infoOut);
    const double titleX = 15. + 65. * infoEase;
    const double titleY = titleTop + (layout.infoTop + 4. - titleTop) * infoEase;
    const double titleSize = 30. + (17. - 30.) * infoEase;
    const double titleWidth = 310. + (252. - 310.) * infoEase;
    c.paragraph(model.title, titleX, titleY, titleSize, titleWidth, {}, "demibold", 2, 1.2);
    const auto liked = s["selectedSongLiked"];
    const double likeSize = 20. + 2. * infoEase;
    const double likeTop = titleY + (titleSize - likeSize) * .5;
    c.icon(liked.toBool() ? "heart-filled" : "heart", 345, likeTop, likeSize,
           liked.toBool() ? c.amber : c.ink);
    if (infoOut > .05) {
        for (const auto &action : model.primaryActions) {
            if (action.route == "music:like") {
                c.hit({327, likeTop - 17., 52, 52}, action.route, action.label);
            }
        }
    }
    const double metaTop = body + 69.;
    const double artistX = 15. + 65. * infoEase;
    const double artistY = metaTop + (layout.infoTop + 28. - metaTop) * infoEase;
    const double artistSize = 12. + (11. - 12.) * infoEase;
    const double artistWidth = 310. + (252. - 310.) * infoEase;
    c.text(model.artist, artistX, artistY, artistSize, artistWidth, "regular", c.ink);
    if (!model.album.isEmpty()) {
        c.text(model.album, 15, metaTop + 16, 9, 310, "regular", c.muted);
    }
    const bool playing = current && m_player.playing;
    const double statusTop = body + 97.;
    c.commands.append(QJsonArray{"ellipse", c.amber, 15, statusTop + 4, 4, 4});
    QString playbackState = "尚未播放";
    if (current) {
        playbackState = "已暂停";
        if (m_player.loading) {
            playbackState = "正在载入";
        } else if (playing) {
            playbackState = "正在播放";
        }
    }
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
    c.text(playbackState, 24, statusTop, 8, 180, "regular", c.muted);
    c.rightText("STEREO", 376, statusTop, 8, "regular", c.muted);
    c.rightText(quality, 320, statusTop, 8, "regular", c.amber);
    c.restore();

    // 歌词模式端点：封面、标题与歌手移动到顶部；专辑和状态信息淡出。
    if (infoIn > .001) {
        c.save();
        c.alpha(infoIn);
        c.translate(0, 10. * (1. - infoIn));
        if (!m_player.cover.isEmpty()) {
            c.roundedImage(m_player.cover, {20, layout.infoTop, 48, 48}, 8);
        } else {
            c.fill({20, layout.infoTop, 48, 48}, c.raised);
            c.border({20, layout.infoTop, 48, 48}, c.line);
        }
        c.text(model.title, 80, layout.infoTop + 4., 17, 252, "demibold", c.ink);
        c.text(model.artist, 80, layout.infoTop + 28., 11, 252, "regular", c.muted);
            c.icon(liked.toBool() ? "heart-filled" : "heart", 345, layout.infoTop + 1., 22,
               liked.toBool() ? c.amber : c.ink);
        if (infoIn > .5) {
            for (const auto &action : model.primaryActions) {
                if (action.route == "music:like") {
                    c.hit({329, layout.infoTop - 4., 52, 52}, action.route, action.label);
                }
            }
        }
        c.restore();
    }
    const double lyricsIn = smooth((lyricProgress - .28) / .72);
    const double controlsTop = layout.progressTop - 14.;
    const double lyricsBottom = controlsTop + (m_height - controlsTop) * (1. - controlsOpacity);
    useGroup("lyrics");
    if (lyricsIn > .001) {
        const double lyricsTop = layout.lyricsTop;
        c.save();
        c.alpha(lyricsIn);
        c.translate(0, 8. * (1. - lyricsIn));
        c.clip({0, lyricsTop, 393, std::max(0., lyricsBottom - lyricsTop)});
        const double lyricsEnd = lyrics(c, s, lyricsTop, lyricsBottom);
        c.restore();
        resultBottom = m_height + std::max(0., lyricsEnd - lyricsBottom);
    }
    if (lyricTarget || lyricProgress > .001) {
        // 控制区完全隐藏时 field() 仍需保留非空边界，
        // 供触摸层把歌词滚动区延伸到屏幕底部。
        const double boundsTop = std::min(lyricsBottom, m_height - .5);
        c.field("playerBounds", {0, boundsTop, 393, std::max(.5, m_height - boundsTop)});
    }
    if (controlsOpacity > .001) {
        useGroup("controls");
        c.save();
        c.alpha(controlsOpacity);
        c.translate(0, controlsOffset);
        const auto time = [](double ms) {
            const int seconds = int(std::max(0., ms) / 1000);
            return MusicData::pad(seconds / 60) + ":" + MusicData::pad(seconds % 60);
        };
        const double progressTop = layout.progressTop;
        const auto utilityInk = c.ink;
        c.text(current ? time(m_player.positionMs) : "00:00", 15, progressTop, 13, 100, "demibold", c.ink);
        auto progressCaption = c.ink;
        progressCaption[3] = .72;
        c.centered("PLAYBACK POSITION", 196.5, progressTop + 5, 8, "demibold", progressCaption);
        c.rightText(current ? time(m_player.durationMs) : model.duration, 376, progressTop, 13, "demibold",
                    c.ink);
        const double fraction = current && m_player.durationMs > 0
                                    ? std::clamp(m_player.positionMs / m_player.durationMs, 0., 1.)
                                    : 0.;
        const double trackY = progressTop + 28.;
        auto trackColor = c.ink;
        trackColor[3] = .38;
        c.fill({15, trackY, 361, 2}, trackColor);
        c.fill({15, trackY, 361 * fraction, 2}, c.amber);
        c.fill({13.5 + 361 * fraction, trackY - 4, 3, 10}, c.ink);
        auto tickColor = c.ink;
        tickColor[3] = .55;
        auto tickLabel = c.ink;
        tickLabel[3] = .78;
        for (int tick = 0; tick <= 20; ++tick) {
            const bool major = tick % 5 == 0;
            c.fill({15 + tick * 18.05, trackY + 7, .6, major ? 8. : 4.}, tickColor);
            const int labelIndex = tick / 5;
            if (major && labelIndex > 0 && labelIndex < 4 && current && m_player.durationMs > 0) {
                const double tickMs = m_player.durationMs * (tick / 20.);
                c.centered(time(tickMs), 15 + 361 * (tick / 20.), trackY + 23, 7, "demibold", tickLabel);
            }
        }
        if (current && m_player.seekable) {
            c.field("seek", {15, trackY - 18, 361, 44});
        }
        // 进度刻度与底部分割线之间的净空间重新取中，避免播放键偏下。
        const double centerY = layout.transportTop + 47.;
        auto ringLine = c.ink;
        ringLine[3] = .72;
        auto ringInner = ringLine;
        ringInner[3] = .56;
        for (const auto &ring : {QRectF(152.5, centerY - 44, 88, 88), QRectF(157.5, centerY - 39, 78, 78)}) {
            const auto color = ring.width() > 80 ? ringLine : ringInner;
            c.ellipseOutline(ring, color, ring.width() > 80 ? 1. : .8);
        }
        auto button = current ? m_player : PlayerBar::State{.boxedPlayButton = m_player.boxedPlayButton};
        // 统一播放页始终使用透明双环，方框播放键偏好只影响桌面播放栏。
        button.boxedPlayButton = false;
        PlayerBar::appendPlayButton(c.commands, button, {196.5, centerY}, 52, c.ink, c.paper);
        c.commands.append(QJsonArray{"ellipse", c.amber, 210.5, centerY - 39, 5, 5});
        c.icon("transport-prev", 101, centerY - 12, 24, c.ink);
        c.icon("transport-next", 268, centerY - 12, 24, c.ink);
        c.hit({92, centerY - 24, 48, 48}, "player:prev", "上一首");
        c.hit({160, centerY - 32, 73, 68}, current ? "player:toggle" : "music:play",
              playing ? "暂停" : "播放");
        c.hit({256, centerY - 24, 48, 48}, "player:next", "下一首");
        const double utilityTop = layout.utilityTop;
        auto divider = c.ink;
        divider[3] = .25;
        c.fill({20, utilityTop - 10, 353, .6}, divider);
        constexpr double ColumnWidth = 353. / 5.;
        const auto utility = [&](int index, const QString &title, const QString &accessibilityLabel,
                                 const QString &route, bool available, const QJsonArray &color) {
            const double x = 20. + index * ColumnWidth;
            const double centerX = x + ColumnWidth / 2.;
            // 五个二字节入口使用同一字号、字重和光学中心。
            c.centered(title, centerX, utilityTop + 22., 14., "demibold", color);
            if (available) {
                c.hit({x, utilityTop, ColumnWidth, 44}, route, accessibilityLabel);
            }
        };
        const bool commentsAvailable = s["commentsAvailable"].toBool();
        utility(0, "歌词", "歌词", "player:lyrics", current,
                lyricProgress > .01 ? c.amber : utilityInk);
        utility(1, "评论", "评论", "music:comments", commentsAvailable, utilityInk);
        QString modeTitle = "顺序";
        QString modeLabel = "顺序播放";
        if (m_player.mode == "shuffle") {
            modeTitle = "随机";
            modeLabel = "随机播放";
        } else if (m_player.mode == "all") {
            modeTitle = "循环";
            modeLabel = "列表循环";
        } else if (m_player.mode == "one") {
            modeTitle = "单曲";
            modeLabel = "单曲循环";
        }
        utility(2, modeTitle, modeLabel, "player:mode", true, m_player.mode == "off" ? utilityInk : c.amber);
        utility(3, "队列", "播放队列", "player:open", true, utilityInk);
        utility(4, "更多", "更多操作", "mobile:song-options", true, utilityInk);
        c.restore();
    }
    return resultBottom;
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
    const bool searchEditing = !m.search.action.isEmpty() && m.searchEditing;
    const bool searchHasValue = !m.clearSearch.action.isEmpty();
    if (searchEditing) {
        c.fill({20, y, 353, 44}, c.surface);
        c.border({20, y, 353, 44}, c.line);
        c.icon("search", 32, y + 13, 18, c.muted);
        c.field("input", {58, y, searchHasValue ? 248.0 : 282.0, 44});
        if (searchHasValue) {
            c.icon("close", 339, y + 13, 18, c.muted);
            c.hit({320, y, 53, 44}, m.clearSearch.action, m.clearSearch.label);
        } else {
            // QML 编辑框在歌单检索态下不绘制占位文本，由原生输入条补足提示。
            c.text(m.search.label, 58, y + 13, 14, 282, "regular", c.muted);
        }
        y += 54;
    }
    QVector<CollectionDetailCard::Choice> tools = m.tabs;
    for (const auto &tool : {m.sort, m.search}) {
        if (!tool.action.isEmpty()) {
            if (searchEditing && tool.action == m.search.action) {
                continue;
            }
            tools.append(tool);
        }
    }
    if (!searchEditing && searchHasValue) {
        tools.append(m.clearSearch);
    }
    for (const auto &tool : {m.rename, m.remove, m.source}) {
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
        const auto image = m.image ? m.image(row.image) : row.image;
        c.row(y + index * 68., row.title, row.artist, row.stamp, row.action, row.number, row.current, {}, {},
              image, !row.image.isEmpty());
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
    // 发现页使用规范中的精确语义色；其它移动页继续沿用各自原有主题值。
    const QJsonArray panel = m.dark ? c.surface : QJsonArray{248. / 255., 247. / 255., 238. / 255., 1.};
    const QJsonArray secondary = m.dark ? c.raised : QJsonArray{229. / 255., 231. / 255., 218. / 255., 1.};
    const QJsonArray ink = m.dark ? c.ink : QJsonArray{34. / 255., 42. / 255., 37. / 255., 1.};
    const QJsonArray muted = m.dark ? c.muted : QJsonArray{98. / 255., 107. / 255., 96. / 255., 1.};
    const QJsonArray line = m.dark ? c.line : QJsonArray{204. / 255., 206. / 255., 192. / 255., 1.};
    const QJsonArray errorText = m.dark ? c.amber : QJsonArray{153. / 255., 67. / 255., 32. / 255., 1.};
    auto separator = ink;
    separator[3] = .3;
    const QRectF contentClip{0, 130, 393, std::max(0., c.contentBottom - 130)};
    const QRectF railViewport{20, 130, 353, std::max(0., c.contentBottom - 130)};
    m_discoverSwipeZones = {};

    const auto zone = [&](const QString &group, const QRectF &rect) {
        const auto visible = rect.intersected(contentClip);
        if (visible.width() >= 8 && visible.height() >= 8) {
            m_discoverSwipeZones.append(QJsonObject{{"group", group},
                                                    {"x", visible.x() * c.unit},
                                                    {"y", visible.y() * c.unit},
                                                    {"width", visible.width() * c.unit},
                                                    {"height", visible.height() * c.unit}});
        }
    };
    const auto visibleHit = [&](const QRectF &rect, const QRectF &clip, const QString &action,
                                const QString &name) {
        const auto target = rect.intersected(clip).intersected(contentClip);
        if (target.width() >= 8 && target.height() >= 8) {
            c.hit(target, action, name);
        }
    };
    const auto horizontal = [&](const QString &group) -> double & { return m_discoverHorizontal[group]; };
    const auto setMaximum = [&](const QString &group, double value) {
        m_discoverHorizontalMaximum[group] = std::max(0., value);
        horizontal(group) = std::clamp(horizontal(group), 0., m_discoverHorizontalMaximum[group]);
    };
    const auto kindName = [](const QString &kind) {
        if (kind == "album") {
            return QStringLiteral("ALBUM / 专辑");
        }
        if (kind == "artist") {
            return QStringLiteral("ARTIST / 歌手");
        }
        if (kind == "song") {
            return QStringLiteral("TRACK / 歌曲");
        }
        return QStringLiteral("PLAYLIST / 歌单");
    };
    const auto drawCover = [&](const DiscoverMusicCard::Entry &entry, const QRectF &frame) {
        c.fill(frame, secondary);
        if (!entry.image.isEmpty()) {
            c.save();
            c.clip(frame);
            const double aspect = std::max(0.1, entry.imageAspect);
            const double target = frame.width() / std::max(1., frame.height());
            QRectF image = frame;
            if (aspect > target) {
                image.setWidth(frame.height() * aspect);
            } else {
                image.setHeight(frame.width() / aspect);
            }
            image.moveCenter(frame.center());
            c.image(entry.image, image);
            c.restore();
        } else {
            c.text(kindName(entry.kind), frame.x() + 12, frame.y() + 12, 8, frame.width() - 24, "regular",
                   muted);
            c.text(MusicData::pad(entry.index + 1), frame.x() + 12, frame.bottom() - 34, 22,
                   frame.width() - 24, "light", muted);
        }
    };
    const auto sectionTitle = [&](double atY, const QString &title, const QString &english) {
        c.text(title, 20, atY + 8, 17, 210, "demibold", ink);
        c.rightText(english, 373, atY + 10, 8, "regular", muted);
        c.fill({20, atY + 30, 353, .8}, line);
    };
    const auto wrapTitle = [&](const DiscoverMusicCard::Entry &entry, double x, double top, double width,
                               double size, int maximum) {
        const auto lines = c.wrap(entry.title, width, size, "demibold");
        for (int index = 0; index < std::min(maximum, int(lines.size())); ++index) {
            QString value = lines.at(index);
            if (index == maximum - 1 && lines.size() > maximum) {
                value += "…";
            }
            c.text(value, x, top + index * (size + 5.), size, width, "demibold", ink);
        }
    };

    double y = 130 - m_scroll;
    for (const auto &section : m.sections) {
        sectionTitle(y, section.title, section.english);
        y += 38;
        if (section.entries.isEmpty()) {
            const auto status = section.loading            ? QStringLiteral("正在读取…")
                                : section.status.isEmpty() ? QStringLiteral("暂无内容")
                                                           : section.status;
            const bool failed = section.failed && !section.loading;
            c.fill({20, y, 353, 52}, panel);
            c.fill({20, y, 3, 52}, failed ? errorText : secondary);
            c.text(status, 32, y + 18, 11, 325, "regular", muted);
            if (failed) {
                c.rightText(QStringLiteral("重试 ↗"), 365, y + 17, 10, "demibold", errorText);
                c.hit({301, y + 4, 72, 44}, "discover:section-retry:" + section.source,
                      QStringLiteral("重新读取") + section.title);
            }
            y += 70;
            continue;
        }

        const double cardWidth = section.featured ? DiscoverFeatureWidth : DiscoverCardWidth;
        const double coverHeight = cardWidth;
        const double metadataHeight = section.featured ? 70. : 64.;
        constexpr double playButtonSize = 44.;
        const double cardHeight = coverHeight + metadataHeight;
        const double gap = section.featured ? DiscoverFeatureGap : DiscoverCardGap;
        const double stride = cardWidth + gap;
        const double contentWidth = section.entries.size() * stride - gap;
        setMaximum(section.id, std::max(0., contentWidth - railViewport.width()));
        const double offset = horizontal(section.id);
        const QRectF clip{20, y, 353, cardHeight};
        c.save();
        c.clip(railViewport);
        for (int position = 0; position < section.entries.size(); ++position) {
            const auto &entry = section.entries.at(position);
            const QRectF card{20 + position * stride - offset, y, cardWidth, cardHeight};
            if (card.right() < railViewport.left() || card.left() > railViewport.right()) {
                continue;
            }
            c.fill(card, panel);
            c.border(card, line);
            drawCover(entry, {card.x(), card.y(), coverHeight, coverHeight});
            c.fill({card.x(), card.y() + coverHeight - .5, card.width(), 1.2}, separator);
            const double textWidth = card.width() - 60.;
            c.text(kindName(entry.kind), card.x() + 12, card.y() + coverHeight + 8, 8, textWidth, "regular",
                   muted);
            wrapTitle(entry, card.x() + 12, card.y() + coverHeight + 21, textWidth,
                      section.featured ? 14 : 12, 2);
            if (entry.kind != "playlist" && !entry.artist.isEmpty()) {
                c.text(entry.artist, card.x() + 12, card.y() + coverHeight + (section.featured ? 55 : 53), 9,
                       textWidth, "regular", muted);
            }
            const auto itemAction = "discover:item:" + entry.section + ":" + QString::number(entry.index);
            visibleHit(card, railViewport, itemAction, "打开 " + entry.title);
            if (entry.kind == "playlist" || entry.kind == "album") {
                const QRectF play{card.right() - playButtonSize - 12,
                                  card.y() + coverHeight + (metadataHeight - playButtonSize) / 2.,
                                  playButtonSize, playButtonSize};
                c.fill({play.x() + 8, play.y() + 8, 28, 28}, secondary);
                c.icon("play", play.x() + 14, play.y() + 14, 16, ink);
                const auto playAction =
                    "mobile:play-discover:" + entry.section + ":" + QString::number(entry.index);
                visibleHit(play, railViewport, playAction, "播放全部 " + entry.title);
            }
        }
        c.restore();
        zone(section.id, clip);
        y += cardHeight + 18;
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
        const auto cover = track["cover"].toString();
        const auto image = m_queue.image ? m_queue.image(cover) : cover;
        c.row(y + index * 68., track["title"].toString(), track["artist"].toString(), MusicData::time(track),
              "player:queue:" + QString::number(index),
              index == m_queue.currentIndex ? "●" : MusicData::pad(index + 1), index == m_queue.currentIndex,
              index == m_queue.currentIndex ? QString() : "player:remove:" + QString::number(index), {},
              image, !cover.isEmpty());
    }
    y += m_queue.tracks.size() * 68.;
    if (m_queue.tracks.isEmpty()) {
        c.text("播放队列为空", 20, y + 20, 17, 353);
        y += 70;
    }
    y = c.paragraph("清空仅移除待播歌曲，当前歌曲继续播放。", 20, y + 14, 12, 353, c.muted) + 24;
    if (m_player.applicationVolume) {
        const auto volume = std::clamp(m_player.volume, 0., 1.);
        c.text("OUTPUT / 音量", 20, y, 9, 353, "regular", c.muted);
        c.fill({20, y + 31, 300, 2}, c.line);
        c.fill({20, y + 31, 300 * volume, 2}, c.ink);
        c.text(QString::number(int(std::lround(volume * 100))) + "%", 328, y + 25, 11, 45, "regular",
               c.muted);
        c.field("volume", {20, y + 16, 300, 32});
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
    // 平台卡固定为 01，后续设置分组从 02 开始。
    int sectionNumber = 2;
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
            double rowHeight = 56;
            c.text(d->titleZh, 20, y + 19, 12, 170);
            const auto hint = d->showDescription ? d->description : d->restartHint;
            if (!hint.isEmpty()) {
                const double noteBottom = c.paragraph(hint, 20, y + 34, 12, 165, c.muted, "regular", 0, 1.5);
                rowHeight = std::max(rowHeight, noteBottom - y + 5.);
            }
            c.fill({20, y + rowHeight - 1, 353, .6}, c.line);
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
            y += rowHeight;
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
    terminalSection(c, y, "01", "插件市场", "MARKETPLACE");
    y += 26;
    if (s["pluginPackageAvailable"].toBool()) {
        c.button({20, y, 172, 44}, "导入插件包", "plugin:import-package");
        c.button({201, y, 172, 44}, "刷新", "plugin:refresh");
        if (s["pluginImportAvailable"].toBool()) {
            c.button({20, y + 50, 172, 44}, "导入文件夹", "plugin:import");
            y += 50;
        }
    } else if (s["pluginImportAvailable"].toBool()) {
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
        const auto current = value["installedVersion"].toString();
        const auto canUpdate = value["updateAvailable"].toBool();
        const bool busy = installing && marketplace["installId"].toString() == id;
        if (busy) {
            c.fill({20, y, 353, 78}, c.raised);
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
        QString label = QStringLiteral("重新安装");
        if (busy) {
            label = QStringLiteral("安装中…");
        } else if (current.isEmpty()) {
            label = QStringLiteral("安装");
        } else if (canUpdate) {
            label = QStringLiteral("更新");
        }
        c.button({261, y + 10, 112, 40}, label, busy ? QString() : "plugin:market:" + id,
                 !busy && (current.isEmpty() || canUpdate));
        c.fill({20, y + 76, 353, .6}, c.line);
        y += 78;
    }
    y += 12;
    terminalSection(c, y, "02", "已安装", "INSTALLED / " + QString::number(installed.size()));
    y += 26;
    if (installed.isEmpty()) {
        c.text("尚未安装插件", 20, y + 4, 14, 353, "demibold");
        c.paragraph("可从上方市场安装插件。", 20, y + 28, 10, 353, muted, "regular",
                    2);
        y += 76;
    }
    for (const auto &value : installed) {
        const auto entry = value.toObject();
        const auto id = entry["id"].toString();
        const bool enabled = entry["enabled"].toBool();
        const bool userInstalled = entry["userInstalled"].toBool();
        c.text(entry["name"].toString(id), 20, y + 10, 14, 250, "demibold");
        const auto state = enabled ? QStringLiteral("已启用") :
                           entry["compatibilityProblem"].toString().isEmpty() ?
                               QStringLiteral("已禁用") : QStringLiteral("暂停加载");
        c.rightText(state, 373, y + 10, 9, "regular", enabled ? c.ink : muted);
        c.fill({373 - c.measure(state, 9) - 11, y + 14, 5, 5},
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

double ResponsiveHudLayout::pluginInstallPage(ResponsiveHudCanvas &c, const QJsonObject &s) {
    double y = 158 - m_scroll;
    const auto preview = s["pluginInstall"].toObject();
    const auto manifest = preview["manifest"].toObject();
    const auto id = manifest["id"].toString();
    const auto name = manifest["display"].toObject()["name"].toString(id);
    const QRectF artwork{20, y, 56, 56};
    if (preview["icon"].toString().isEmpty()) {
        c.fill(artwork, c.raised);
        c.centered(name.left(1), artwork.center().x(), y + 25, 18, "demibold");
    } else {
        c.roundedImage(preview["icon"].toString(), artwork, 8);
    }
    c.text(name, 88, y + 6, 20, 285, "demibold");
    c.text(id, 88, y + 36, 10, 285, "regular", c.muted);
    y += 77;
    for (const auto &line : s["pluginInstallLines"].toArray()) {
        y = c.paragraph(line.toString(), 20, y, 13, 353, c.ink, "regular", 4) + 13;
    }
    const auto label = preview["willEnable"].toBool() ? QStringLiteral("确认安装并启用") :
                                                       QStringLiteral("确认安装");
    c.button({20, y + 6, 172, 44}, label, "plugin:confirm-install", true);
    c.button({201, y + 6, 172, 44}, "取消", "close-modal");
    return y + m_scroll + 70;
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
    if (!detail["compatibilityProblem"].toString().isEmpty()) {
        y = c.paragraph(detail["compatibilityProblem"].toString(), 20, y, 12, 353, muted) + 12;
    }
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
    const bool scopedPlaylistSearch = search && s["playlistSearchScoped"].toBool();
    if (scopedPlaylistSearch) {
        c.fill({20, y, 353, 32}, c.surface);
        c.border({20, y, 353, 32}, c.line);
        c.fill({20, y, 3, 32}, c.amber);
        c.text("PLAYLIST SCOPE / 歌单内搜索", 32, y + 6, 8, 226, "regular", c.muted);
        c.text(s["playlistSearchTitle"].toString(), 32, y + 17, 10, 226, "demibold");
        QString scopeState = QStringLiteral("部分载入");
        if (s["playlistSearchLoading"].toBool()) {
            scopeState = QStringLiteral("读取中 ") + QString::number(s["playlistSearchLoaded"].toInt()) +
                         QStringLiteral(" / ") + QString::number(s["playlistSearchTotal"].toInt());
        } else if (s["playlistSearchComplete"].toBool()) {
            scopeState = QStringLiteral("完整歌单");
        }
        c.rightText(scopeState, 360, y + 12, 8, "regular", c.muted);
        y += 53;
    }
    const QStringList labels = search ? QStringList{"歌曲", "歌手", "专辑", "歌单"}
                                      : QStringList{columns[1].toString(), columns[2].toString(),
                                                    columns[3].toString(), columns[4].toString()};
    const QVector<int> order = search ? QVector<int>{0, 3, 1, 2} : QVector<int>{1, 2, 3, 4};
    int selectedType = 0;
    if (!scopedPlaylistSearch) {
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
    }
    terminalSection(c, y, "01", search ? "检索结果" : "音乐档案",
                    (scopedPlaylistSearch && s["playlistSearchLoading"].toBool()
                         ? QStringLiteral("SEARCHING / ")
                         : QStringLiteral("INDEX / ")) +
                        QString::number(resultCount));
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
        QString emptyTitle;
        QString emptyDetail;
        if (scopedPlaylistSearch) {
            if (s["playlistSearchLoading"].toBool()) {
                emptyTitle = QStringLiteral("正在检索完整歌单");
            } else if (emptyQuery) {
                emptyTitle = QStringLiteral("搜索当前歌单");
            } else {
                emptyTitle = QStringLiteral("没有匹配的歌曲");
            }
            emptyDetail = s["playlistSearchStatus"].toString(
                emptyQuery ? QStringLiteral("输入歌曲、歌手或专辑名称") : QStringLiteral("没有匹配的歌曲"));
        } else {
            if (emptyQuery) {
                emptyTitle = QStringLiteral("检索音乐档案");
                emptyDetail = QStringLiteral("输入歌曲、歌手、专辑或歌单名称");
            } else {
                emptyTitle = QStringLiteral("暂无匹配档案");
                emptyDetail = s["status"].toString();
            }
        }
        c.text(emptyTitle, 60, y + 30, 16, 310, "demibold");
        y = c.paragraph(emptyDetail, 60, y + 60, 11, 308, c.muted) + 24;
        if (!search && !s["loggedIn"].toBool()) {
            c.button({20, y, 353, 44}, "登录音乐平台 →", "music:login");
            y += 60;
        }
    }
    return y + m_scroll + 20;
}
