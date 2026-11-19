/// 竖屏（compact）歌曲评论页：`Qt/src/ResponsiveComments.cpp`（全 180 行）的 Dart 移植。
///
/// 唯一真值：`ResponsiveHudLayout::commentsPage`（ResponsiveComments.cpp:15-180）。
/// 宿主侧的装配真值：`Qt/src/ResponsiveHudLayout.cpp:40-47`（comments 是独立页态，
/// 与歌词页同级）、`:186-189`（页头不画设置键、标题下追加
/// "COMMENT ARCHIVE / 评论档案"）、`:196`（返回键改写为一条关闭动作）、
/// `:205`（内容自 158 起）、`:238-244`（end = commentsPage(...) 后夹滚动）。
///
/// 坐标约定：Qt 用 393 pt 设计网格，本页所有左缘常量照抄，**右缘一律按
/// `c.gridWidth` 反算**（本机 DPI 适配后页宽比 393 宽，写死会让右栏挤在中间，
/// 与 portrait_pages_song.dart / portrait_pages_library.dart 同一条规矩）。
///
/// 边界：本文件不 import lib/domain（hud 层刻意不依赖领域层，见
/// lib/hud/player/player_bar.dart:7、lib/hud/modals/lyrics_panel.dart:8），
/// 所以页面的数据面是本文件自己的只读视图模型（[PortraitCommentsModel] /
/// [PortraitCommentRow] / [PortraitCommentReply]）。宿主把
/// `lib/domain/comments/comment_controller.dart` 的 `CommentState` 映射进来即可
/// （映射表见最终交付报告）。
///
/// 本页**不**计算滚动上界的所有权：函数返回 [PortraitCommentsLayout]，
/// 宿主据此把 scroll 夹在 `[0, maximumScroll]`（Qt 是布局持有 m_scroll，
/// ResponsiveHudLayout.cpp:238-244 同一处夹取）。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

// ── 冻结几何（逐字照抄 ResponsiveComments.cpp） ────────────────────────────

/// 内容起始 y（ResponsiveHudLayout.cpp:205 的 `lyric || comments ? 158`）。
const double portraitCommentsContentTop = 158.0;

/// 来源行基线（async 后再 +26 到排序 chip）。
const double portraitCommentsSourceY = 158.0;

/// 正文最多显示行数（ResponsiveComments.cpp:113 的 `> 6`）。
const int portraitCommentBodyLines = 6;

/// 正文行距（:118 的 `contentY += 23`）。
const double portraitCommentBodyLine = 23.0;

/// 回复行距（:150 的 `replyY += 20`）。
const double portraitReplyLine = 20.0;

/// 头像边长（:104 的 `{20, y, 30, 30}`）。
const double portraitCommentAvatarSize = 30.0;

/// 排序 chip 宽度（:51 的 `{20, y, 84, 36}`）。
const double portraitCommentsChipWidth = 84.0;

/// 排序 chip 高度。
const double portraitCommentsChipHeight = 36.0;

// ── 只读视图模型（映射自 CommentState） ────────────────────────────────────

/// 一条回复。
class PortraitCommentReply {
  const PortraitCommentReply({
    required this.id,
    required this.nickname,
    required this.content,
    this.replyTo = '',
  });

  /// 回复 id。
  final String id;

  /// 昵称。
  final String nickname;

  /// 正文。
  final String content;

  /// 被回复者昵称（顶层评论为空）。
  final String replyTo;

  /// 页面上的一行展示文本：`昵称 + (" 回复 @"+replyTo) + "：" + 正文`
  /// （ResponsiveComments.cpp:6-16 `replyText`）。
  String get displayText {
    final String prefix = replyTo.isEmpty ? nickname : '$nickname 回复 @$replyTo';
    return '$prefix：$content';
  }
}

/// 一条评论（只带本页要画的字段）。
class PortraitCommentRow {
  const PortraitCommentRow({
    required this.id,
    required this.nickname,
    required this.content,
    this.avatarKey = '',
    this.timeLabel = '',
    this.likedLabel = '',
    this.replyCount = 0,
    this.expanded = false,
    this.inlineReplies = const <PortraitCommentReply>[],
    this.replies = const <PortraitCommentReply>[],
    this.repliesExpanded = false,
    this.repliesHasMore = false,
    this.repliesLoading = false,
    this.repliesError = '',
  });

  /// 评论 id（命中串的后缀）。
  final String id;

  /// 昵称。
  final String nickname;

  /// 正文（未折行；本页按 315 宽自己折）。
  final String content;

  /// 头像键（空则画昵称首字）。
  final String avatarKey;

  /// 时间文案（空则不画）。
  final String timeLabel;

  /// 点赞文案（`♥ ` 之后那段）。
  final String likedLabel;

  /// 平台报告的回复数。
  final int replyCount;

  /// "展开全文"是否已展开。
  final bool expanded;

  /// 折叠时预览的回复（最多 2 条）。
  final List<PortraitCommentReply> inlineReplies;

  /// 已加载的回复。
  final List<PortraitCommentReply> replies;

  /// 回复块是否已展开。
  final bool repliesExpanded;

  /// 回复是否还有下一页。
  final bool repliesHasMore;

  /// 回复是否在加载。
  final bool repliesLoading;

  /// 回复失败文案（非空即画"回复加载失败，点击重试"）。
  final String repliesError;
}

/// 整页数据面（映射自 `CommentState`）。
class PortraitCommentsModel {
  const PortraitCommentsModel({
    this.status = 'idle',
    this.message = '',
    this.sort = 'hot',
    this.totalLabel = '',
    this.hasMore = false,
    this.loadingMore = false,
    this.sourceName = '',
    this.sourceLabel = '',
    this.providerId = '',
    this.items = const <PortraitCommentRow>[],
  });

  /// `idle` / `loading` / `ready` / `empty` / `error`（Qt state()["status"]）。
  final String status;

  /// 状态文案（Qt `message`）。
  final String message;

  /// `hot` / `new`（Qt `sort`）。
  final String sort;

  /// 总条数文案（Qt `totalLabel`，`compactCount(total)`）。
  final String totalLabel;

  /// 是否还有下一页。
  final bool hasMore;

  /// 是否在加载下一页。
  final bool loadingMore;

  /// 评论来源名（Qt `sourceName`）。
  final String sourceName;

  /// 塞壬匹配到的歌曲标签（Qt `sourceLabel`；Flutter 侧恒空）。
  final String sourceLabel;

  /// 曲目所在平台（Qt `source["provider"]`；只有 `siren` 会追加匹配尾巴）。
  final String providerId;

  /// 已加载评论。
  final List<PortraitCommentRow> items;
}

/// 一页排版的结果：内容底边（**不含**滚动偏移）与滚动上界。
class PortraitCommentsLayout {
  const PortraitCommentsLayout({
    required this.contentBottom,
    required this.maximumScroll,
  });

  /// 内容底边（未叠加滚动；Qt `return y + m_scroll + 20` 与
  /// `m_maximum = max(0, end - contentBottom)` 用的是同一个 end）。
  final double contentBottom;

  /// 可滚动的最大值（`max(0, contentBottom - 内容视口高)`）。
  final double maximumScroll;
}

/// 画一页竖屏歌曲评论（返回滚动上界，宿主据此夹 [scroll]）。
///
/// [scroll]：当前滚动偏移（Qt `m_scroll`），页面只做"整体上移"，不自己夹取。
/// [header]：是否画页头（`c.header('歌曲评论', back: true, showSettings: false)`）。
/// 宿主用 `paintPortraitShell(header: ...)` 自己画同一个页头时传 false，避免画两遍。
/// [subtitle]："COMMENT ARCHIVE / 评论档案" 这行英文小标。Qt 的在
/// ResponsiveHudLayout.cpp:187-188 是与 `c.header` 并列的两个独立调用，
/// 所以它**不跟** [header] 走（默认恒画），宿主自画页头时也照样需要它。
///
/// 与 Qt 的差异（全部因为宿主分层不同，不是语义差异）：
/// - Qt 由 `ResponsiveHudLayout::arrange` 先 `c.beginContent(...)` 再调本页、
///   之后 `c.endContent()`；这里本页自己开合裁剪区（Flutter 的 shell 不代管）；
/// - Qt 用 `c.chip(...)` 时选中态再画 3 单位琥珀下划线，这里照抄：
///   `PortraitCanvas.chip` 的边框色差异（selected ? muted : line）与 Qt 相同。
PortraitCommentsLayout paintPortraitCommentsPage(
  PortraitCanvas c, {
  required PortraitCommentsModel model,
  double scroll = 0,
  bool header = true,
  bool subtitle = true,
  String backAction = 'close-modal',
}) {
  final double w = c.gridWidth;
  final double left = 20;
  final double contentWidth = w - 40;
  final double bottom = math.max(portraitCommentsContentTop, c.contentBottom);

  if (header) {
    // ResponsiveHudLayout.cpp:195：comments 页 `c.header(title, true, ..., !comments)`
    // ⇒ 画返回箭头、但不画右上设置键。
    c.header('歌曲评论', back: true, showSettings: false, backAction: backAction);
  }
  if (subtitle) {
    // ResponsiveHudLayout.cpp:187-188：标题区下沿的一行英文小标。
    c.text('COMMENT ARCHIVE / 评论档案', left, 126, size: 8, width: contentWidth, color: c.muted);
  }

  c.beginContent(portraitCommentsContentTop);
  double y = portraitCommentsContentTop - scroll;

  // ── 来源行（ResponsiveComments.cpp:19-39） ──────────────────────────────
  String sourceLine = model.sourceName;
  if (model.providerId == 'siren') {
    if (model.sourceLabel.isNotEmpty) {
      sourceLine += ' · 已匹配 ${model.sourceLabel}';
    } else if (model.status == 'loading') {
      sourceLine += ' · 正在匹配歌曲…';
    } else {
      sourceLine += ' · 未匹配到歌曲';
    }
  }
  if (model.totalLabel.isNotEmpty && model.totalLabel != '0') {
    sourceLine += ' · ${model.totalLabel} 条评论';
  }
  c.text(sourceLine, left, y, size: 11, width: contentWidth, color: c.muted);
  y += 26;

  // ── 排序 chip + 刷新（:41-49） ──────────────────────────────────────────
  final bool hot = model.sort == 'hot';
  final bool fresh = model.sort == 'new';
  c.chip(
    Rect.fromLTWH(left, y, portraitCommentsChipWidth, portraitCommentsChipHeight),
    '热门',
    'comments:sort:hot',
    selected: hot,
  );
  if (hot) {
    c.fill(Rect.fromLTWH(left, y + portraitCommentsChipHeight, portraitCommentsChipWidth, 3), c.amber);
  }
  c.chip(
    Rect.fromLTWH(left + 90, y, portraitCommentsChipWidth, portraitCommentsChipHeight),
    '最新',
    'comments:sort:new',
    selected: fresh,
  );
  if (fresh) {
    c.fill(
      Rect.fromLTWH(left + 90, y + portraitCommentsChipHeight, portraitCommentsChipWidth, 3),
      c.amber,
    );
  }
  c.rightText('刷新 ↻', w - left, y + 12, 12, 'regular', c.muted);
  c.hit(Rect.fromLTWH(w - left - 68, y, 72, 44), 'comments:refresh', '刷新评论');
  y += 54;

  // ── 首屏：loading/idle（:64-71） ────────────────────────────────────────
  if (model.status == 'loading' || model.status == 'idle') {
    final String message = model.message.isEmpty ? '正在读取评论…' : model.message;
    y = c.paragraph(message, left, y + 8, size: 13, width: contentWidth, color: c.muted) + 16;
    c.endContent();
    return _layout(y, bottom, scroll);
  }

  // ── 首屏：error/empty（:72-80） ─────────────────────────────────────────
  if (model.status == 'error' || model.status == 'empty') {
    final String message = model.message.isEmpty ? '暂无评论' : model.message;
    y = c.paragraph(message, left, y + 8, size: 13, width: contentWidth, color: c.muted) + 16;
    c.button(Rect.fromLTWH(left, y, contentWidth, 44), '重新加载', 'comments:retry');
    y += 60;
    c.endContent();
    return _layout(y, bottom, scroll);
  }

  // ── 每条评论（:82-171） ─────────────────────────────────────────────────
  for (final PortraitCommentRow item in model.items) {
    final Rect avatar = Rect.fromLTWH(left, y, portraitCommentAvatarSize, portraitCommentAvatarSize);
    if (item.avatarKey.isNotEmpty) {
      c.image(item.avatarKey, avatar);
    } else {
      c.fill(avatar, c.raised);
      c.border(avatar, c.line);
      // Qt `nickname.left(1)`：UTF-16 首字符（与 Dart substring(0,1) 同义）。
      final String initial = item.nickname.isEmpty ? '' : item.nickname.substring(0, 1);
      c.centered(initial, left + 15, y + 16, 12, 'demibold', c.ink);
    }
    c.text(item.nickname, 58, y + 1, size: 13, width: 220, weight: 'demibold');
    if (item.timeLabel.isNotEmpty) {
      c.rightText(item.timeLabel, w - left, y + 3, 11, 'regular', c.muted);
    }

    final List<String> lines = c.wrap(item.content, contentWidth - 38, 13);
    final bool truncated = !item.expanded && lines.length > portraitCommentBodyLines;
    final int shown = truncated ? portraitCommentBodyLines : lines.length;
    double contentY = y + 24;
    for (int index = 0; index < shown; index++) {
      c.text(lines[index], 58, contentY, size: 13, width: contentWidth - 38);
      contentY += portraitCommentBodyLine;
    }
    double metaY = contentY + 5;
    // Qt `"♥ " + item["likedLabel"]`，而 likedLabel 恒为 `compactCount(likedCount)`
    // （CommentsController.cpp:668-712 的 state()），即最小值是 "0"，不会是空串。
    final String liked = item.likedLabel.isEmpty ? '0' : item.likedLabel;
    c.text('♥ $liked', 58, metaY, size: 12, width: 90, color: c.muted);

    if (item.replyCount > 0) {
      final String label = item.repliesExpanded ? '收起回复 ↑' : '${item.replyCount} 条回复 ↓';
      c.text(label, 152, metaY, size: 12, width: 130, color: c.muted);
      c.hit(Rect.fromLTWH(144, metaY - 12, 150, 44), 'comments:replies:${item.id}', label);
    }
    if (truncated || item.expanded) {
      final String label = item.expanded ? '收起' : '展开全文';
      c.text(label, w - 80, metaY, size: 12, width: 60, color: c.muted);
      c.hit(Rect.fromLTWH(w - 88, metaY - 12, 68, 44), 'comments:expand:${item.id}', label);
    }

    double afterMeta = metaY + 24;
    final List<PortraitCommentReply> replies =
        item.repliesExpanded ? item.replies : item.inlineReplies;
    if (replies.isNotEmpty || item.repliesLoading || item.repliesError.isNotEmpty) {
      final double blockTop = afterMeta + 2;
      final List<List<String>> wrapped = <List<String>>[];
      double blockHeight = 12;
      for (final PortraitCommentReply reply in replies) {
        final List<String> replyLines = c.wrap(reply.displayText, contentWidth - 56, 12);
        wrapped.add(replyLines);
        blockHeight += replyLines.length * portraitReplyLine + 6;
      }
      String statusText = '';
      String statusAction = '';
      if (item.repliesLoading) {
        statusText = '正在加载回复…';
      } else if (item.repliesError.isNotEmpty) {
        statusText = '回复加载失败，点击重试';
        statusAction = 'comments:replies:${item.id}';
      } else if (item.replyCount > replies.length && !item.repliesExpanded) {
        statusText = '查看全部 ${item.replyCount} 条回复 ↓';
        statusAction = 'comments:replies:${item.id}';
      } else if (item.repliesExpanded && item.repliesHasMore) {
        statusText = '查看更多回复 ↓';
        statusAction = 'comments:replies-more:${item.id}';
      }
      if (statusText.isNotEmpty) {
        blockHeight += 24;
      }
      c.fill(Rect.fromLTWH(58, blockTop, contentWidth - 38, blockHeight), c.surface);
      double replyY = blockTop + 8;
      for (final List<String> replyLines in wrapped) {
        for (final String line in replyLines) {
          c.text(line, 68, replyY, size: 12, width: contentWidth - 56, color: c.muted);
          replyY += portraitReplyLine;
        }
        replyY += 6;
      }
      if (statusText.isNotEmpty) {
        c.text(statusText, 68, replyY + 1, size: 12, width: contentWidth - 60, color: c.muted);
        if (statusAction.isNotEmpty) {
          c.hit(Rect.fromLTWH(58, replyY - 12, contentWidth - 38, 40), statusAction, statusText);
        }
      }
      afterMeta = blockTop + blockHeight + 10;
    }

    final double rowBottom = afterMeta + 6;
    c.fill(Rect.fromLTWH(left, rowBottom, contentWidth, .6), c.line);
    y = rowBottom + 12;
  }

  // ── 翻页 / 到底（:173-180） ─────────────────────────────────────────────
  if (model.hasMore) {
    if (model.loadingMore) {
      c.centered('正在加载更多…', w / 2, y + 22, 12, 'regular', c.muted);
    } else {
      c.button(Rect.fromLTWH(left, y, contentWidth, 44), '加载更多评论 ↓', 'comments:load-more');
    }
    y += 56;
  } else if (model.items.isNotEmpty) {
    c.centered('END OF COMMENTS / 评论到底了', w / 2, y + 22, 10, 'regular', c.muted);
    y += 56;
  }

  c.endContent();
  return _layout(y, bottom, scroll);
}

PortraitCommentsLayout _layout(double y, double bottom, double scroll) {
  // Qt：`return y + m_scroll + 20` 与 `m_maximum = max(0, end - c.contentBottom)`。
  final double contentBottom = y + scroll + 20;
  final double viewport = math.max(0, bottom - portraitCommentsContentTop);
  return PortraitCommentsLayout(
    contentBottom: contentBottom,
    maximumScroll: math.max(0, contentBottom - portraitCommentsContentTop - viewport),
  );
}
