#include "ResponsiveHudLayout.h"
#include "MusicData.h"
#include <algorithm>
#include <cmath>

namespace {
QString stamp(double milliseconds) {
    const double value = std::max(0., milliseconds);
    return MusicData::pad(int(value / 60000)) + ":" + MusicData::pad(int(value / 1000) % 60);
}
QString qualityLabel(const QString &value) {
    if (value == "lossless" || value == "flac") {
        return "无损";
    }
    if (value == "hires") {
        return "Hi-Res";
    }
    if (value == "exhigh" || value == "higher" || value == "hq") {
        return "高品质";
    }
    if (value == "sq") {
        return "SQ 无损";
    }
    if (value == "standard") {
        return "标准";
    }
    if (value == "320k" || value == "128k") {
        return value;
    }
    return value;
}
}
/** 进度、时间与音质：手机播放页和歌词页共用同一套行高与命中区。 */
void ResponsiveHudLayout::progressRow(ResponsiveHudCanvas &c, double y, bool current,
                                      const QJsonObject &source, QString idleDuration) {
    const double fraction = current && m_player.durationMs > 0
                                ? std::clamp(m_player.positionMs / m_player.durationMs, 0., 1.)
                                : 0;
    c.fill({20, y, 353, 2.5}, c.line);
    c.fill({20, y, 353 * fraction, 2.5}, c.amber);
    for (int tick = 0; tick <= 20; ++tick) {
        c.fill({20 + tick * 17.6, y + 5, .6, tick % 5 == 0 ? 6. : 3.}, c.line);
    }
    if (current && m_player.seekable) {
        c.field("seek", {20, y - 9, 353, 22});
    }
    c.text(current ? stamp(m_player.positionMs) : "00:00", 20, y + 10, 10, 120, "regular", c.muted);
    const bool hasDuration = current ? m_player.durationMs > 0 : !idleDuration.isEmpty();
    const double shownDuration = current ? m_player.durationMs : 0;
    const QString right = !current      ? idleDuration
                          : hasDuration ? "-" + stamp(shownDuration - m_player.positionMs)
                                        : "暂无";
    c.rightText(right, 373, y + 10, 10, "regular", c.muted);
    const QString quality = current ? qualityLabel(source["playerQuality"].toString()) : QString();
    if (!quality.isEmpty()) {
        const double width = c.measure(quality, 9, "regular") + 24;
        c.fill({196.5 - width / 2, y + 6, width, 17}, c.raised);
        c.centered(quality, 196.5, y + 14.5, 9, "regular", c.muted);
    }
}
/** 上一首 / 播放 / 下一首：沿用原图标，按歌词页参考图放大并居中。 */
void ResponsiveHudLayout::transportRow(ResponsiveHudCanvas &c, double y, bool current) {
    c.icon("prev", 99, y + 2, 26);
    c.hit({89, y - 10, 44, 44}, "player:prev", "上一首");
    c.icon(current && m_player.loading   ? "more"
           : current && m_player.playing ? "pause"
                                         : "play",
           176.5, y - 4, 40);
    c.hit({164, y - 16, 64, 64}, current ? "player:toggle" : "music:play",
          current && m_player.playing ? "暂停" : "播放");
    c.icon("next", 264.5, y + 2, 26);
    c.hit({255, y - 10, 44, 44}, "player:next", "下一首");
}
/** 音量行：两端小喇叭与细滑杆，滑杆命中区比视觉高度更宽。 */
void ResponsiveHudLayout::volumeRow(ResponsiveHudCanvas &c, double y) {
    c.icon("volume", 20, y, 16, c.muted);
    c.icon("volume", 357, y, 16, c.muted);
    const double fraction = std::clamp(m_player.volume, 0., 1.);
    c.fill({46, y + 7, 301, 2.5}, c.line);
    c.fill({46, y + 7, 301 * fraction, 2.5}, c.muted);
    c.field("volume", {46, y - 3, 301, 22});
}
/** 底部三个入口：歌词、播放模式、队列，位置与歌词页参考图对齐。 */
void ResponsiveHudLayout::utilityRow(ResponsiveHudCanvas &c, double y, bool current) {
    c.centered("词", 114, y + 10, 18, "demibold", current ? c.ink : c.muted);
    if (current) {
        c.hit({92, y - 12, 44, 44}, "player:lyrics", "打开全屏歌词");
    }
    c.icon(m_player.mode == "shuffle" ? "shuffle"
           : m_player.mode == "off"   ? "right"
                                      : "repeat",
           186.5, y, 20);
    if (m_player.mode == "one") {
        c.centered("1", 196.5, y + 10, 8, "bold");
    }
    c.hit({174.5, y - 12, 44, 44}, "player:mode", "切换播放模式");
    c.icon("queue", 271, y, 20);
    c.hit({259, y - 12, 44, 44}, "player:open", "播放队列");
}

/** 歌词页底部控制区：位置按设计参考固定，滚动只影响歌词区。 */
void ResponsiveHudLayout::lyricsPlayer(ResponsiveHudCanvas &c, const QJsonObject &source) {
    const double top = c.contentBottom;
    progressRow(c, top + 34, m_player.hasTrack, source, {});
    transportRow(c, top + 84, m_player.hasTrack);
    if (m_player.applicationVolume) {
        volumeRow(c, top + 148);
    }
    utilityRow(c, top + 194, m_player.hasTrack);
    c.field("playerBounds", {0, top, 393, m_height - top});
}

/** 歌词阅读：复用桌面歌词面板的字号、行距、强调与滚动曲线，只把宽度换成手机画布。 */
double ResponsiveHudLayout::lyrics(ResponsiveHudCanvas &c, const QJsonObject &source) {
    constexpr double viewTop = 158;
    const double viewBottom = c.contentBottom;
    const double width = 353;
    const auto document = source["lyricDocument"].toObject();
    const auto lines = document["lines"].toArray();
    if (lines.isEmpty()) {
        const auto plain = document["plainText"].toString();
        auto message = source["lyricMessage"].toString();
        if (message.isEmpty()) {
            message = plain.isEmpty() ? "播放歌曲后显示歌词" : plain;
        }
        const auto rows = c.wrap(message, width, plain.isEmpty() ? 15 : 16, "regular");
        double y = viewTop - m_scroll + 24;
        for (const auto &row : rows) {
            if (y + 24 >= viewTop && y <= viewBottom) {
                c.text(row, 20, y, 15, width, "regular", c.muted);
            }
            y += 26;
        }
        if (!source["lyricMessage"].toString().isEmpty()) {
            c.button({20, viewBottom - 52, 353, 42}, "重新查找歌词", "player:lyrics-retry");
        }
        return y + m_scroll + 40;
    }
    if (document != m_lyricDocument) {
        m_lyricDocument = document;
        m_lyricRows.clear();
        double y = 0;
        for (const auto &value : lines) {
            const auto line = value.toObject();
            auto original = line["text"].toString();
            if (original.isEmpty()) {
                original = "•••";
            }
            LyricRow row;
            row.top = y;
            row.text = c.wrap(original, width, 22, "bold");
            const auto translation = line["translation"].toString();
            if (!translation.isEmpty()) {
                row.translation = c.wrap(translation, width, 11, "regular");
            }
            y += std::max(1, int(row.text.size())) * 30 + int(row.translation.size()) * 17 + 22;
            m_lyricRows.append(row);
        }
        m_lyricContentHeight = y;
        m_lyricTarget.reset();
        m_lyricCurve.reset();
        m_lyricScroll = 0;
    }
    const int active = source["lyricIndex"].toInt(-1);
    constexpr double focusOffset = 100.;
    const double maximum = std::max(0., m_lyricContentHeight - (viewBottom - viewTop) + 60);
    if (m_followLyrics) {
        const double target = active >= 0 && active < m_lyricRows.size() ? m_lyricRows[active].top : 0;
        if (!m_lyricTarget || target != *m_lyricTarget) {
            m_lyricTarget = target;
            if (m_reduced) {
                m_lyricScroll = target;
                m_lyricCurve.reset();
            } else {
                const auto sample =
                    m_lyricCurve ? m_lyricCurve->sample(m_time) : std::array<double, 2>{m_lyricScroll, 0};
                m_lyricScroll = sample[0];
                m_lyricCurve.emplace(sample[0], target, sample[1], m_time, .42);
            }
        } else if (m_lyricCurve) {
            m_lyricScroll = m_lyricCurve->sample(m_time)[0];
        }
        m_lyricScroll = std::clamp(m_lyricScroll, 0., maximum);
        m_scroll = m_lyricScroll;
    } else {
        m_lyricScroll = m_scroll;
    }
    const double scroll = m_followLyrics ? m_lyricScroll : m_scroll;
    for (int index = 0; index < m_lyricRows.size(); ++index) {
        const auto &row = m_lyricRows[index];
        const double y = viewTop + row.top - scroll + focusOffset;
        const double height = std::max(1, int(row.text.size())) * 30 + int(row.translation.size()) * 17;
        if (y + height < viewTop - 12 || y > viewBottom + 12) {
            continue;
        }
        const bool isActive = index == active;
        const double edge =
            std::clamp(std::min((y + height - viewTop) / 36., (viewBottom - y) / 36.), 0., 1.);
        auto color = c.ink;
        color[3] = (isActive ? 1. : .28) * edge;
        for (int lineIndex = 0; lineIndex < row.text.size(); ++lineIndex) {
            c.text(row.text[lineIndex], 20, y + lineIndex * 30, 22, width, "bold", color);
        }
        auto translated = color;
        translated[3] = color.at(3).toDouble() * .65;
        for (int lineIndex = 0; lineIndex < row.translation.size(); ++lineIndex) {
            c.text(row.translation[lineIndex], 20, y + row.text.size() * 30 + lineIndex * 17, 11, width,
                   "regular", translated);
        }
        if (m_player.seekable) {
            const double hitTop = std::max(viewTop, y - 7);
            const double hitBottom = std::min(viewBottom, y + height + 14);
            if (hitBottom - hitTop > 8) {
                c.hit({12, hitTop, 369, hitBottom - hitTop}, "player:lyric-line:" + QString::number(index),
                      row.text.join(" "));
            }
        }
    }
    return viewTop + m_lyricContentHeight + 80;
}

/** 右上“更多”面板：歌曲页沿用原歌曲卡片动作，歌词页只保留歌词相关操作。 */
void ResponsiveHudLayout::optionsSheet(ResponsiveHudCanvas &c, const QJsonObject &source) {
    c.fields.remove("seek");
    c.fields.remove("volume");
    c.hit({0, 118, 393, m_height - 118}, "mobile:song-options", "收起操作");
    const double sheetTop = std::max(118., m_height - BottomGestureInset - 416);
    c.fill({0, sheetTop, 393, m_height - sheetTop}, c.surface);
    c.fill({20, sheetTop, 353, 1}, c.line);
    c.text(m_lyricsPage ? "歌词操作" : "歌曲操作", 20, sheetTop + 18, 18, 300, "demibold");
    QVector<SongDetailCard::Action> actions;
    if (m_lyricsPage) {
        actions.append(SongDetailCard::Action{"歌词提前 0.2s", "player:lyrics-earlier"});
        actions.append(SongDetailCard::Action{"歌词延后 0.2s", "player:lyrics-later"});
        actions.append(SongDetailCard::Action{"重置歌词偏移", "player:lyrics-reset"});
        actions.append(SongDetailCard::Action{"重新查找歌词", "player:lyrics-retry"});
        if (m_player.hasTrack && source["provider"] == "local") {
            actions.append(SongDetailCard::Action{"歌词来源", "player:lyrics-sources"});
        }
    } else if (m_song) {
        const auto &m = *m_song;
        for (const auto &action : m.primaryActions) {
            if (!action.route.isEmpty() && action.route != "music:play" && action.route != "music:like") {
                actions.append(action);
            }
        }
        for (const auto &action : m.secondaryActions) {
            if (!action.route.isEmpty()) {
                actions.append(action);
            }
        }
        if (!m.local && source["officialPlayback"].toBool()) {
            actions.append(SongDetailCard::Action{"官方客户端 ↗", "music:official"});
        }
    }
    double y = sheetTop + 56;
    for (int index = 0; index < actions.size(); ++index) {
        c.button({20 + (index % 2) * 181., y + (index / 2) * 52., 172, 44}, actions[index].label,
                 actions[index].route);
    }
    y += ((actions.size() + 1) / 2) * 52 + 12;
    if (m_song) {
        c.text(m_song->album + " / " + m_song->duration, 20, y, 12, 353, "regular", c.muted);
        c.paragraph(source["detailBody"].toString(), 20, y + 25, 12, 353, c.muted, "regular", 4);
    }
}
