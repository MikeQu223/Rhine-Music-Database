#include "ResponsiveHudLayout.h"
#include "MusicData.h"
#include <algorithm>
#include <cmath>

/** 歌词阅读：复用桌面歌词面板的字号、行距、强调与滚动曲线，只把宽度换成手机画布。 */
double ResponsiveHudLayout::lyrics(ResponsiveHudCanvas &c, const QJsonObject &source, double viewTop,
                                   double viewBottom) {
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
                row.translation = c.wrap(translation, width, 15, "bold");
            }
            y += std::max(1, int(row.text.size())) * 30 + int(row.translation.size()) * 20 + 22;
            m_lyricRows.append(row);
        }
        m_lyricContentHeight = y;
        m_lyricLastIndex = source["lyricIndex"].toInt(-1);
        m_lyricLineUpdates = 0;
        m_lyricTarget.reset();
        m_lyricCurve.reset();
        m_lyricScroll = 0;
    }
    const int active = source["lyricIndex"].toInt(-1);
    if (active != m_lyricLastIndex) {
        m_lyricLastIndex = active;
        if (!m_followLyrics && active >= 0 && ++m_lyricLineUpdates >= 2) {
            m_lyricLineUpdates = 0;
            m_followLyrics = true;
            m_lyricTarget.reset();
            m_lyricCurve.reset();
        }
    }
    constexpr double focusOffset = 32.;
    const double activeTop = active >= 0 && active < m_lyricRows.size() ? m_lyricRows[active].top : 0.;
    const double normalMaximum = std::max(0., m_lyricContentHeight - (viewBottom - viewTop) + 60);
    // 末尾没有后续歌词时仍允许继续滚动，让当前句停在阅读区首行。
    const double maximum = std::max(normalMaximum, activeTop);
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
        const double height = std::max(1, int(row.text.size())) * 30 + int(row.translation.size()) * 20;
        if (y + height < viewTop - 12 || y > viewBottom + 12) {
            continue;
        }
        const bool isActive = index == active;
        const double edge =
            std::clamp(std::min((y + height - viewTop) / 36., (viewBottom - y) / 36.), 0., 1.);
        auto color = c.ink;
        color[3] = (isActive ? 1. : .28) * edge;
        const bool future = active >= 0 && index > active;
        for (int lineIndex = 0; lineIndex < row.text.size(); ++lineIndex) {
            if (future) {
                c.blurText(row.text[lineIndex], 20, y + lineIndex * 30, 22, width, "bold", color, 1.8);
            } else {
                c.text(row.text[lineIndex], 20, y + lineIndex * 30, 22, width, "bold", color);
            }
        }
        auto translated = color;
        translated[3] = color.at(3).toDouble() * .65;
        for (int lineIndex = 0; lineIndex < row.translation.size(); ++lineIndex) {
            if (future) {
                c.blurText(row.translation[lineIndex], 20, y + row.text.size() * 30 + lineIndex * 20, 15,
                           width, "bold", translated, 1.2);
            } else {
                c.text(row.translation[lineIndex], 20, y + row.text.size() * 30 + lineIndex * 20, 15, width,
                       "bold", translated);
            }
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
        if (source["commentsAvailable"].toBool()) {
            actions.append(SongDetailCard::Action{"查看评论", "music:comments"});
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
