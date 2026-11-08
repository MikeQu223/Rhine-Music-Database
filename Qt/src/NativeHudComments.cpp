#include "NativeHud.h"
#include "CommentsController.h"
#include <QStringList>
#include <QVector>
#include <algorithm>
#include <cmath>

namespace {
const QJsonArray Amber{0.835, 0.639, 0.282, 1};
constexpr double ListTop = 452;
constexpr double ListBottom = 944;
constexpr double AvatarSize = 46;
constexpr double ContentX = 62;
constexpr double ContentSize = 21;
constexpr double ContentLine = 38;
constexpr double MetaSize = 17;
constexpr double ReplySize = 17;
constexpr double ReplyLine = 30;

QJsonArray inkColor(bool dark) {
    return dark ? QJsonArray{0.92, 0.93, 0.88, 1} : QJsonArray{0.133, 0.165, 0.145, 1};
}

QJsonArray muted(const QJsonArray &value) {
    auto color = value;
    color[3] = 0.62;
    return color;
}

QJsonArray soft(bool dark) {
    return dark ? QJsonArray{0.18, 0.22, 0.18, 1} : QJsonArray{0.898, 0.906, 0.855, 1};
}
}

void NativeHud::commentsPanel(double x, double width) {
    auto &comments = m_music->comments;
    const auto foreground = inkColor(dark);
    const auto secondary = muted(foreground);
    const auto maximum = std::max(0., commentsContentBottom - ListTop - (ListBottom - ListTop));
    commentsScroll = std::clamp(commentsScroll, 0., maximum);

    // 与歌曲档案共用同一条顶部结构线，评论页只替换卡片内容。
    fill(x - 24, 260, width + 48, 3, foreground);
    fill(x, 282, 8, 8, Amber);
    text("COMMENT ARCHIVE / 评论档案", x + 18, 278, 15, "demibold", 0, secondary);
    text("歌曲评论", x, 300, 40, "bold");
    const auto titleWidth = m_glyphs->width("歌曲评论", 40, "bold");
    text("Comments", x + titleWidth + 14, 314, 20, "regular", 0, secondary);
    button("关闭", x + width - 80, 276, 80, 48, "comments:close", 18);

    QString sourceHead = QStringLiteral("网易云音乐");
    QString sourceRest;
    if (m_music->provider == "siren") {
        if (!comments.sourceLabel.isEmpty()) {
            sourceRest = QStringLiteral(" · 已匹配 ") + comments.sourceLabel;
        } else if (comments.status == "loading") {
            sourceRest = QStringLiteral(" · 正在匹配歌曲…");
        } else {
            sourceRest = QStringLiteral(" · 未匹配到歌曲");
        }
    }
    if (comments.total > 0) {
        sourceRest += QStringLiteral(" · ") + CommentsController::compactCount(comments.total) +
                      QStringLiteral(" 条评论");
    }
    const auto sourceHeadWidth = m_glyphs->width(sourceHead, 18, "demibold");
    text(sourceHead, x, 358, 18, "demibold");
    if (!sourceRest.isEmpty()) {
        text(fit(sourceRest, 18, width - sourceHeadWidth - 12), x + sourceHeadWidth + 6, 358, 18,
             "regular", 0, secondary);
    }

    const auto chip = [&](const QString &label, const QString &action, bool active, double cx) {
        constexpr double chipWidth = 102;
        if (active) {
            auto tint = Amber;
            tint[3] = 0.16;
            fill(cx, 390, chipWidth, 40, tint);
            fill(cx, 427, chipWidth, 3, Amber);
        }
        text(label, cx + 12, 400, 18, active ? "demibold" : "regular", 0,
             active ? foreground : secondary);
        hit(cx - 4, 386, chipWidth + 8, 48, action, label);
    };
    chip(QStringLiteral("热门"), QStringLiteral("comments:sort:hot"), comments.sort == "hot", x);
    chip(QStringLiteral("最新"), QStringLiteral("comments:sort:new"), comments.sort == "new", x + 110);
    const auto refreshWidth = m_glyphs->width("刷新 ↻", 17, "regular");
    text("刷新 ↻", x + width - refreshWidth, 400, 17, "regular", 0, secondary);
    hit(x + width - refreshWidth - 10, 386, refreshWidth + 20, 48, "comments:refresh", "刷新评论");

    save();
    clip(x - 4, ListTop, width + 8, ListBottom - ListTop);
    double y = ListTop - commentsScroll;
    if (comments.status == "loading" || comments.status == "idle") {
        const auto message = comments.message.isEmpty() ? QStringLiteral("正在读取评论…") : comments.message;
        const auto lines = m_glyphs->wrap(message, width - 24, 18);
        for (int index = 0; index < int(lines.size()); ++index) {
            text(lines.at(index), x, y + 24 + index * 30, 18, "regular", 0, secondary);
        }
        y += 24 + lines.size() * 30 + 16;
    } else if (comments.status == "error" || comments.status == "empty") {
        const auto message = comments.message.isEmpty() ? QStringLiteral("暂无评论") : comments.message;
        const auto lines = m_glyphs->wrap(message, width - 24, 18);
        for (int index = 0; index < int(lines.size()); ++index) {
            text(lines.at(index), x, y + 24 + index * 30, 18, "regular", 0, secondary);
        }
        y += 24 + lines.size() * 30 + 16;
        button("重新加载", x, y, 150, 48, "comments:retry", 18);
        y += 66;
    } else {
        for (const auto &item : comments.items) {
            const auto id = item["id"].toString();
            const auto avatarUrl = item["avatarUrl"].toString();
            comments.ensureAvatar(avatarUrl);
            const auto avatarKey = comments.avatar(avatarUrl);
            if (!avatarKey.isEmpty()) {
                image(avatarKey, x, y, AvatarSize, AvatarSize);
            } else {
                auto placeholder = secondary;
                placeholder[3] = 0.12;
                fill(x, y, AvatarSize, AvatarSize, placeholder);
                const auto initial = item["nickname"].toString().trimmed().left(1);
                centeredText(initial, x + AvatarSize / 2, y + AvatarSize / 2, 18, "demibold", true);
            }
            limited(item["nickname"].toString(), x + ContentX, y - 2, 20, width - ContentX - 104, "demibold");
            const auto time = CommentsController::relativeTime(item["time"].toDouble());
            if (!time.isEmpty()) {
                text(time, x + width - 92, y + 2, 16, "regular", 0, secondary);
            }
            const auto expanded = item["expanded"].toBool();
            auto lines = m_glyphs->wrap(item["content"].toString(), width - ContentX, ContentSize);
            const bool truncated = !expanded && lines.size() > 6;
            if (!expanded && lines.size() > 6) {
                lines = lines.mid(0, 6);
            }
            double rowY = y + 36;
            for (const auto &line : lines) {
                text(line, x + ContentX, rowY, ContentSize, "regular");
                rowY += ContentLine;
            }
            const double metaY = rowY + 12;
            const auto liked = QStringLiteral("♥ ") + CommentsController::compactCount(item["likedCount"].toInt());
            text(liked, x + ContentX, metaY, MetaSize, "regular", 0, secondary);
            const auto replyCount = item["replyCount"].toInt();
            const auto repliesExpanded = item["repliesExpanded"].toBool();
            if (replyCount > 0) {
                const auto label = repliesExpanded
                                       ? QStringLiteral("收起回复 ↑")
                                       : QString::number(replyCount) + QStringLiteral(" 条回复 ↓");
                const auto replyX = x + ContentX + m_glyphs->width(liked, MetaSize, "regular") + 24;
                limited(label, replyX, metaY, MetaSize, width - (replyX - x) - 14, "regular");
                hit(replyX - 10, metaY - 14, 180, 48, "comments:replies:" + id, label);
            }
            if (truncated || expanded) {
                const auto label = expanded ? QStringLiteral("收起") : QStringLiteral("展开全文");
                limited(label, x + width - 84, metaY, MetaSize, 84, "regular");
                hit(x + width - 94, metaY - 14, 96, 48, "comments:expand:" + id, label);
            }
            double afterMeta = metaY + 36;
            const auto replies = repliesExpanded ? item["replies"].toArray() : item["inlineReplies"].toArray();
            if (!replies.isEmpty() || item["repliesLoading"].toBool() ||
                !item["repliesError"].toString().isEmpty()) {
                const double blockTop = afterMeta + 8;
                const double innerX = x + ContentX + 16;
                const double innerWidth = width - ContentX - 32;
                struct ReplyBlock {
                    QString prefix;
                    double prefixWidth = 0;
                    QStringList lines;
                };
                QVector<ReplyBlock> blocks;
                double blockHeight = 32;
                for (const auto &replyValue : replies) {
                    const auto reply = replyValue.toObject();
                    auto prefix = reply["nickname"].toString();
                    const auto target = reply["replyTo"].toString();
                    if (!target.isEmpty()) {
                        prefix += QStringLiteral(" 回复 @") + target;
                    }
                    prefix += QStringLiteral("：");
                    const auto text = prefix + reply["content"].toString();
                    ReplyBlock block;
                    block.prefix = prefix;
                    block.prefixWidth = m_glyphs->width(prefix, ReplySize, "demibold");
                    block.lines = m_glyphs->wrap(text, innerWidth, ReplySize);
                    blocks.append(block);
                    blockHeight += block.lines.size() * ReplyLine + 10;
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
                    blockHeight += 34;
                }
                fill(x + ContentX, blockTop, width - ContentX, blockHeight, soft(dark));
                double replyY = blockTop + 16;
                for (const auto &block : blocks) {
                    const bool inlineName = block.prefixWidth < innerWidth - 48;
                    if (inlineName) {
                        text(block.prefix, innerX, replyY, ReplySize, "demibold");
                    }
                    for (int line = 0; line < block.lines.size(); ++line) {
                        auto value = block.lines.at(line);
                        auto lineX = innerX;
                        if (inlineName && line == 0) {
                            value = value.mid(block.prefix.size());
                            lineX += block.prefixWidth;
                        }
                        if (!value.isEmpty()) {
                            text(value, lineX, replyY + line * ReplyLine, ReplySize, "regular", 0,
                                 secondary);
                        }
                    }
                    replyY += block.lines.size() * ReplyLine + 10;
                }
                if (!statusText.isEmpty()) {
                    limited(statusText, innerX, replyY + 4, ReplySize, innerWidth, "regular");
                    if (!statusAction.isEmpty()) {
                        hit(x + ContentX, replyY - 6, width - ContentX, 42, statusAction, statusText);
                    }
                }
                afterMeta = blockTop + blockHeight + 12;
            }
            const auto rowBottom = afterMeta + 10;
            auto divider = foreground;
            divider[3] = 0.14;
            fill(x, rowBottom, width, 1, divider);
            y = rowBottom + 28;
        }
        if (comments.hasMore) {
            if (comments.loadingMore) {
                centeredText("正在加载更多…", x + width / 2, y + 26, 17, "regular", true);
            } else {
                centeredText("加载更多评论 ↓", x + width / 2, y + 26, 17, "regular", true);
                hit(x, y, width, 56, "comments:load-more", "加载更多评论");
            }
            y += 64;
        } else if (!comments.items.isEmpty()) {
            centeredText("END OF COMMENTS / 评论到底了", x + width / 2, y + 26, 14, "regular", true);
            y += 64;
        }
    }
    restore();
    // y 是叠加了本次滚动偏移的绘制坐标；内容总高度必须去掉偏移，
    // 否则越往下滚可滚范围越小，滚轮会被反复夹回造成抽搐。
    commentsContentBottom = y + commentsScroll;
}
