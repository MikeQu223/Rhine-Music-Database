#include "ResponsiveHudLayout.h"
#include <QJsonArray>
#include <QStringList>
#include <QVector>
#include <algorithm>

namespace {
QString replyText(const QJsonObject &reply) {
    auto prefix = reply["nickname"].toString();
    const auto target = reply["replyTo"].toString();
    if (!target.isEmpty()) {
        prefix += QStringLiteral(" 回复 @") + target;
    }
    return prefix + QStringLiteral("：") + reply["content"].toString();
}
}

/** 移动评论页：与歌词页相同的整页形态，内容使用 393 pt 设计坐标。 */
double ResponsiveHudLayout::commentsPage(ResponsiveHudCanvas &c, const QJsonObject &source) {
    const auto comments = source["comments"].toObject();
    const auto items = comments["items"].toArray();
    const auto status = comments["status"].toString();
    const auto sort = comments["sort"].toString("hot");
    double y = 158 - m_scroll;

    QString sourceLine = comments["sourceName"].toString(source["providerName"].toString());
    if (source["provider"] == "siren") {
        const auto matched = comments["sourceLabel"].toString();
        if (!matched.isEmpty()) {
            sourceLine += QStringLiteral(" · 已匹配 ") + matched;
        } else if (status == "loading") {
            sourceLine += QStringLiteral(" · 正在匹配歌曲…");
        } else {
            sourceLine += QStringLiteral(" · 未匹配到歌曲");
        }
    }
    const auto totalLabel = comments["totalLabel"].toString();
    if (!totalLabel.isEmpty() && totalLabel != "0") {
        sourceLine += QStringLiteral(" · ") + totalLabel + QStringLiteral(" 条评论");
    }
    c.text(sourceLine, 20, y, 11, 353, "regular", c.muted);
    y += 26;

    c.chip({20, y, 84, 36}, "热门", "comments:sort:hot", sort == "hot");
    if (sort == "hot") {
        c.fill({20, y + 36, 84, 3}, c.amber);
    }
    c.chip({110, y, 84, 36}, "最新", "comments:sort:new", sort == "new");
    if (sort == "new") {
        c.fill({110, y + 36, 84, 3}, c.amber);
    }
    c.text("刷新 ↻", 313, y + 12, 12, 60, "regular", c.muted);
    c.hit({305, y, 72, 44}, "comments:refresh", "刷新评论");
    y += 54;

    if (status == "loading" || status == "idle") {
        const auto message = comments["message"].toString().isEmpty() ? QStringLiteral("正在读取评论…")
                                                                     : comments["message"].toString();
        y = c.paragraph(message, 20, y + 8, 13, 353, c.muted, "regular", 0) + 16;
        return y + m_scroll + 20;
    }
    if (status == "error" || status == "empty") {
        const auto message = comments["message"].toString().isEmpty() ? QStringLiteral("暂无评论")
                                                                     : comments["message"].toString();
        y = c.paragraph(message, 20, y + 8, 13, 353, c.muted, "regular", 0) + 16;
        c.button({20, y, 353, 44}, "重新加载", "comments:retry");
        y += 60;
        return y + m_scroll + 20;
    }

    for (const auto &value : items) {
        const auto item = value.toObject();
        const auto id = item["id"].toString();
        const QRectF avatar{20, y, 30, 30};
        const auto avatarKey = item["avatarKey"].toString();
        if (!avatarKey.isEmpty()) {
            c.image(avatarKey, avatar);
        } else {
            c.fill(avatar, c.raised);
            c.border(avatar, c.line);
            c.centered(item["nickname"].toString().left(1), 35, y + 16, 12, "demibold", c.ink);
        }
        c.text(item["nickname"].toString(), 58, y + 1, 13, 220, "demibold");
        const auto time = item["timeLabel"].toString();
        if (!time.isEmpty()) {
            c.rightText(time, 373, y + 3, 11, "regular", c.muted);
        }

        const auto expanded = item["expanded"].toBool();
        auto lines = c.wrap(item["content"].toString(), 315, 13);
        const bool truncated = !expanded && lines.size() > 6;
        const int shown = truncated ? 6 : int(lines.size());
        double contentY = y + 24;
        for (int index = 0; index < shown; ++index) {
            c.text(lines.at(index), 58, contentY, 13, 315);
            contentY += 23;
        }
        double metaY = contentY + 5;
        c.text(QStringLiteral("♥ ") + item["likedLabel"].toString(), 58, metaY, 12, 90, "regular",
               c.muted);
        const auto replyCount = item["replyCount"].toInt();
        const auto repliesExpanded = item["repliesExpanded"].toBool();
        if (replyCount > 0) {
            const auto label = repliesExpanded ? QStringLiteral("收起回复 ↑")
                                               : QString::number(replyCount) + QStringLiteral(" 条回复 ↓");
            c.text(label, 152, metaY, 12, 130, "regular", c.muted);
            c.hit({144, metaY - 12, 150, 44}, "comments:replies:" + id, label);
        }
        if (truncated || expanded) {
            const auto label = expanded ? QStringLiteral("收起") : QStringLiteral("展开全文");
            c.text(label, 313, metaY, 12, 60, "regular", c.muted);
            c.hit({305, metaY - 12, 68, 44}, "comments:expand:" + id, label);
        }

        double afterMeta = metaY + 24;
        const auto replies =
            repliesExpanded ? item["replies"].toArray() : item["inlineReplies"].toArray();
        if (!replies.isEmpty() || item["repliesLoading"].toBool() ||
            !item["repliesError"].toString().isEmpty()) {
            const double blockTop = afterMeta + 2;
            QVector<QStringList> wrapped;
            double blockHeight = 12;
            for (const auto &replyValue : replies) {
                const auto replyLines = c.wrap(replyText(replyValue.toObject()), 297, 12);
                wrapped.append(replyLines);
                blockHeight += replyLines.size() * 20 + 6;
            }
            QString statusText;
            QString statusAction;
            if (item["repliesLoading"].toBool()) {
                statusText = QStringLiteral("正在加载回复…");
            } else if (!item["repliesError"].toString().isEmpty()) {
                statusText = QStringLiteral("回复加载失败，点击重试");
                statusAction = "comments:replies:" + id;
            } else if (replyCount > replies.size() && !repliesExpanded) {
                statusText = QStringLiteral("查看全部 %1 条回复 ↓").arg(replyCount);
                statusAction = "comments:replies:" + id;
            } else if (repliesExpanded && item["repliesHasMore"].toBool()) {
                statusText = QStringLiteral("查看更多回复 ↓");
                statusAction = "comments:replies-more:" + id;
            }
            if (!statusText.isEmpty()) {
                blockHeight += 24;
            }
            c.fill({58, blockTop, 315, blockHeight}, c.surface);
            double replyY = blockTop + 8;
            for (const auto &replyLines : wrapped) {
                for (const auto &line : replyLines) {
                    c.text(line, 68, replyY, 12, 297, "regular", c.muted);
                    replyY += 20;
                }
                replyY += 6;
            }
            if (!statusText.isEmpty()) {
                c.text(statusText, 68, replyY + 1, 12, 293, "regular", c.muted);
                if (!statusAction.isEmpty()) {
                    c.hit({58, replyY - 12, 315, 40}, statusAction, statusText);
                }
            }
            afterMeta = blockTop + blockHeight + 10;
        }

        const auto rowBottom = afterMeta + 6;
        c.fill({20, rowBottom, 353, .6}, c.line);
        y = rowBottom + 12;
    }

    if (comments["hasMore"].toBool()) {
        if (comments["loadingMore"].toBool()) {
            c.centered("正在加载更多…", 196.5, y + 22, 12, "regular", c.muted);
        } else {
            c.button({20, y, 353, 44}, "加载更多评论 ↓", "comments:load-more");
        }
        y += 56;
    } else if (!items.isEmpty()) {
        c.centered("END OF COMMENTS / 评论到底了", 196.5, y + 22, 10, "regular", c.muted);
        y += 56;
    }
    return y + m_scroll + 20;
}
