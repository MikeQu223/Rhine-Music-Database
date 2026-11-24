// CommentPanel：横屏歌曲评论面板的纯数据命令 / 命中构建器。
//
// 语义逐条移植自 Qt/src/NativeHudComments.cpp（NativeHud::commentsPanel，全 258 行）
// 与其唯一调用点 Qt/src/NativeHudDetail.cpp:45-100（detail 页在 commentsMode 时
// `save(); alpha(opacity); ... commentsPanel(x, usable); restore();`，x = width*0.56、
// usable = width - x - 59）。
//
// 本文件不依赖 Flutter Widget / Material，也不 import lib/domain/*：评论读取、分页、
// 回复加载属领域（lib/domain/comments/comment_controller.dart），本文件只消费注入的
// 只读快照（CommentPanelModel）。
//
// 命令是 Qt 的 flat JSON 形态：同代发布、不排序、不去重、不合并。
// 命中是六字段 x/y/width/height/action/label（NativeHud.cpp:123-134），不写 fixed。
//
// 滚动：Qt 把 commentsScroll 存在 NativeHud 成员里、每帧开头按上一次的
// commentsContentBottom 夹取，帧尾写回 `commentsContentBottom = y + commentsScroll`
// （去掉本次偏移，否则越滚可滚范围越小，滚轮会抽搐）。本文件把这两件事拆成
// 纯函数：cmtClampPanelScroll 与 CommentPanelDrawing.contentBottom。

import 'dart:math' as math;

// ── 冻结常量（逐字照抄 NativeHudComments.cpp:11-19） ────────────────────────

/// 列表视口上沿（Qt constexpr ListTop = 452）。
const double cmtListTop = 452.0;

/// 列表视口下沿（Qt constexpr ListBottom = 944）。
const double cmtListBottom = 944.0;

/// 头像边长（Qt constexpr AvatarSize = 46）。
const double cmtAvatarSize = 46.0;

/// 正文左缩进（Qt constexpr ContentX = 62）。
const double cmtContentX = 62.0;

/// 正文字号（Qt constexpr ContentSize = 21）。
const double cmtContentSize = 21.0;

/// 正文行距（Qt constexpr ContentLine = 38）。
const double cmtContentLine = 38.0;

/// 元信息字号（Qt constexpr MetaSize = 17）。
const double cmtMetaSize = 17.0;

/// 回复字号（Qt constexpr ReplySize = 17）。
const double cmtReplySize = 17.0;

/// 回复行距（Qt constexpr ReplyLine = 30）。
const double cmtReplyLine = 30.0;

/// 正文最多显示行数（NativeHudComments.cpp:124 的 `lines.size() > 6`）。
const int cmtContentMaxLines = 6;

/// Qt `Amber`（NativeHudComments.cpp:10）。
const List<Object?> cmtAmber = <Object?>[0.835, 0.639, 0.282, 1];

/// Qt `inkColor(dark)`（NativeHudComments.cpp:21-24）。
List<Object?> cmtInk(bool dark) =>
    dark ? <Object?>[0.92, 0.93, 0.88, 1] : <Object?>[0.133, 0.165, 0.145, 1];

/// Qt `muted(value)`：直接把 alpha 改成 0.62（:26-30，赋值不是相乘）。
List<Object?> cmtMuted(List<Object?> value) => <Object?>[
  value[0],
  value[1],
  value[2],
  0.62,
];

/// Qt `soft(dark)`（:32-34）。
List<Object?> cmtSoft(bool dark) =>
    dark ? <Object?>[0.18, 0.22, 0.18, 1] : <Object?>[0.898, 0.906, 0.855, 1];

// ── 字形度量端口（Qt Glyphs::width / wrap） ────────────────────────────────

/// 只读度量：面板需要 width（布局与 `♥` 后的回复标签定位）与 wrap（正文/回复折行）。
abstract class CommentPanelGlyphs {
  /// Qt Glyphs::width(value, size, weight)。
  double width(String value, double size, String weight);

  /// Qt Glyphs::wrap(value, limit, size, weight)。
  List<String> wrap(String value, double limit, double size, String weight);
}

// ── 只读视图模型（映射自 CommentState） ────────────────────────────────────

/// 面板的一条评论。
class CommentPanelItem {
  const CommentPanelItem({
    required this.id,
    required this.nickname,
    required this.content,
    this.avatarKey = '',
    this.timeLabel = '',
    this.likedLabel = '',
    this.replyCount = 0,
    this.expanded = false,
    this.inlineReplies = const <CommentPanelReply>[],
    this.replies = const <CommentPanelReply>[],
    this.repliesExpanded = false,
    this.repliesHasMore = false,
    this.repliesLoading = false,
    this.repliesError = '',
  });

  /// 评论 id（命中串后缀）。
  final String id;

  /// 昵称（头像空槽时取其首字）。
  final String nickname;

  /// 正文（未折行；面板按 `width - 62` 自己折）。
  final String content;

  /// 头像键（= 平台头像 URL；像素由宿主 `image` 端口按同一键取）。
  final String avatarKey;

  /// 时间文案（空则不画）。
  final String timeLabel;

  /// 点赞文案（`♥ ` 之后那段，Qt `compactCount(likedCount)`）。
  final String likedLabel;

  /// 平台报告的回复数。
  final int replyCount;

  /// "展开全文"是否已展开。
  final bool expanded;

  /// 折叠时的回复预览（最多 2 条）。
  final List<CommentPanelReply> inlineReplies;

  /// 已加载的回复。
  final List<CommentPanelReply> replies;

  /// 回复块是否已展开。
  final bool repliesExpanded;

  /// 回复是否还有下一页。
  final bool repliesHasMore;

  /// 回复是否在加载。
  final bool repliesLoading;

  /// 回复失败文案（非空即画"回复加载失败，点击重试"）。
  final String repliesError;
}

/// 面板的一条回复。
class CommentPanelReply {
  const CommentPanelReply({
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

  /// 被回复者昵称。
  final String replyTo;

  /// Qt 的 `prefix`：`昵称` 或 `昵称 回复 @被回复者`，末尾再补 `：`（:158-166）。
  String get prefix {
    final String head = replyTo.isEmpty ? nickname : '$nickname 回复 @$replyTo';
    return '$head：';
  }
}

/// 面板的整页数据（映射自 `CommentState` + 宿主上下文）。
class CommentPanelModel {
  const CommentPanelModel({
    required this.x,
    required this.width,
    required this.dark,
    this.status = 'idle',
    this.message = '',
    this.sort = 'hot',
    this.total = 0,
    this.totalLabel = '',
    this.hasMore = false,
    this.loadingMore = false,
    this.sourceName = '',
    this.sourceLabel = '',
    this.providerId = '',
    this.providerName = '',
    this.items = const <CommentPanelItem>[],
  });

  /// 面板左沿（Qt `x = width * 0.56`）。
  final double x;

  /// 面板宽度（Qt `usable = width - x - 59`）。
  final double width;

  /// 深色主题。
  final bool dark;

  /// `idle` / `loading` / `ready` / `empty` / `error`（领域层的 [CommentPhase] 映射）。
  final String status;

  /// 状态文案。
  final String message;

  /// `hot` / `new`。
  final String sort;

  /// 总条数（>0 才在来源行追加 " · N 条评论"）。
  final int total;

  /// 总条数文案（空则按 total 现算 `compactCount`）。
  final String totalLabel;

  /// 是否还有下一页。
  final bool hasMore;

  /// 是否在加载下一页。
  final bool loadingMore;

  /// 评论来源名（空则回落 [providerName]）。
  final String sourceName;

  /// 塞壬匹配标签（Flutter 侧恒空）。
  final String sourceLabel;

  /// 曲目平台（只有 `siren` 会追加匹配尾巴）。
  final String providerId;

  /// 当前平台中文名（Qt `m_music->providerName()`）。
  final String providerName;

  /// 已加载评论。
  final List<CommentPanelItem> items;
}

/// 一帧的绘制产物。
class CommentPanelDrawing {
  CommentPanelDrawing({
    required this.commands,
    required this.hits,
    required this.contentBottom,
  });

  /// flat 命令数组，顺序即 Qt append 顺序。
  final List<List<Object?>> commands;

  /// 命中表；六字段，不带 fixed。
  final List<Map<String, Object?>> hits;

  /// 内容总高度（**不含**本次滚动偏移；Qt 帧尾的 `commentsContentBottom`）。
  final double contentBottom;
}

/// Qt 帧首的滚动夹取（NativeHudComments.cpp:37-41）：
/// `maximum = max(0, contentBottom - ListTop - (ListBottom - ListTop))`，
/// `scroll = clamp(scroll, 0, maximum)`。
double cmtClampPanelScroll(double scroll, double contentBottom) {
  final double maximum = math.max(
    0.0,
    contentBottom - cmtListTop - (cmtListBottom - cmtListTop),
  );
  return math.min(math.max(scroll, 0.0), maximum);
}

// ── 绘制 ───────────────────────────────────────────────────────────────────

/// 画一帧横屏评论面板（Qt `NativeHud::commentsPanel(x, width)`）。
///
/// [scroll]：已夹取过的滚动偏移（调用方先跑 [cmtClampPanelScroll]）。
/// 返回的 [CommentPanelDrawing.contentBottom] 必须回存，供下一帧夹取用。
CommentPanelDrawing paintCommentsPanel(
  CommentPanelModel model,
  CommentPanelGlyphs glyphs, {
  double scroll = 0,
}) {
  final _CommentsPainter p = _CommentsPainter(glyphs: glyphs, dark: model.dark);
  final double x = model.x;
  final double width = model.width;
  final List<Object?> foreground = cmtInk(model.dark);
  final List<Object?> secondary = cmtMuted(foreground);

  // 与歌曲档案共用同一条顶部结构线，评论页只替换卡片内容（:43-52）。
  p.fill(x - 24, 260, width + 48, 3, foreground);
  p.fill(x, 282, 8, 8, cmtAmber);
  p.text('COMMENT ARCHIVE / 评论档案', x + 18, 278, 15, 'demibold', secondary);
  p.text('歌曲评论', x, 300, 40, 'bold', foreground);
  final double titleWidth = glyphs.width('歌曲评论', 40, 'bold');
  p.text('Comments', x + titleWidth + 14, 314, 20, 'regular', secondary);
  p.button('关闭', x + width - 80, 276, 80, 48, 'comments:close', 18);

  // 来源行（:54-74）。
  final String sourceHead = model.sourceName.isEmpty
      ? model.providerName
      : model.sourceName;
  String sourceRest = '';
  if (model.providerId == 'siren') {
    if (model.sourceLabel.isNotEmpty) {
      sourceRest = ' · 已匹配 ${model.sourceLabel}';
    } else if (model.status == 'loading') {
      sourceRest = ' · 正在匹配歌曲…';
    } else {
      sourceRest = ' · 未匹配到歌曲';
    }
  }
  if (model.total > 0) {
    final String label = model.totalLabel.isEmpty
        ? commentPanelCompactCount(model.total)
        : model.totalLabel;
    sourceRest += ' · $label 条评论';
  }
  final double sourceHeadWidth = glyphs.width(sourceHead, 18, 'demibold');
  p.text(sourceHead, x, 358, 18, 'demibold', foreground);
  if (sourceRest.isNotEmpty) {
    p.text(
      p.fit(sourceRest, 18, width - sourceHeadWidth - 12, 'regular'),
      x + sourceHeadWidth + 6,
      358,
      18,
      'regular',
      secondary,
    );
  }

  // 排序 chip（:76-100）：宽 102，选中时琥珀 16% 底 + 3 单位下划线。
  void chip(String label, String action, bool active, double cx) {
    const double chipWidth = 102.0;
    if (active) {
      final List<Object?> tint = <Object?>[
        cmtAmber[0],
        cmtAmber[1],
        cmtAmber[2],
        0.16,
      ];
      p.fill(cx, 390, chipWidth, 40, tint);
      p.fill(cx, 427, chipWidth, 3, cmtAmber);
    }
    p.text(
      label,
      cx + 12,
      400,
      18,
      active ? 'demibold' : 'regular',
      active ? foreground : secondary,
    );
    p.hit(cx - 4, 386, chipWidth + 8, 48, action, label);
  }

  chip('热门', 'comments:sort:hot', model.sort == 'hot', x);
  chip('最新', 'comments:sort:new', model.sort == 'new', x + 110);
  final double refreshWidth = glyphs.width('刷新 ↻', 17, 'regular');
  p.text('刷新 ↻', x + width - refreshWidth, 400, 17, 'regular', secondary);
  p.hit(
    x + width - refreshWidth - 10,
    386,
    refreshWidth + 20,
    48,
    'comments:refresh',
    '刷新评论',
  );

  // 列表（:103-247）。
  p.save();
  p.clip(x - 4, cmtListTop, width + 8, cmtListBottom - cmtListTop);
  double y = cmtListTop - scroll;
  if (model.status == 'loading' || model.status == 'idle') {
    final String message = model.message.isEmpty ? '正在读取评论…' : model.message;
    final List<String> lines = glyphs.wrap(message, width - 24, 18, 'regular');
    for (int index = 0; index < lines.length; index++) {
      p.text(lines[index], x, y + 24 + index * 30, 18, 'regular', secondary);
    }
    y += 24 + lines.length * 30 + 16;
  } else if (model.status == 'error' || model.status == 'empty') {
    final String message = model.message.isEmpty ? '暂无评论' : model.message;
    final List<String> lines = glyphs.wrap(message, width - 24, 18, 'regular');
    for (int index = 0; index < lines.length; index++) {
      p.text(lines[index], x, y + 24 + index * 30, 18, 'regular', secondary);
    }
    y += 24 + lines.length * 30 + 16;
    p.button('重新加载', x, y, 150, 48, 'comments:retry', 18);
    y += 66;
  } else {
    for (final CommentPanelItem item in model.items) {
      // 头像（:133-143）。
      if (item.avatarKey.isNotEmpty) {
        p.image(item.avatarKey, x, y, cmtAvatarSize, cmtAvatarSize);
      } else {
        final List<Object?> placeholder = <Object?>[
          secondary[0],
          secondary[1],
          secondary[2],
          0.12,
        ];
        p.fill(x, y, cmtAvatarSize, cmtAvatarSize, placeholder);
        final String initial = item.nickname.trim().isEmpty
            ? ''
            : item.nickname.trim().substring(0, 1);
        // Qt `centeredText(initial, x + AvatarSize / 2, y + AvatarSize / 2, 18, "demibold", true)`
        // —— 颜色缺省即 ink（NativeHud.cpp:97-101）。
        p.centeredText(
          initial,
          x + cmtAvatarSize / 2,
          y + cmtAvatarSize / 2,
          18,
          'demibold',
          foreground,
        );
      }
      p.limited(
        item.nickname,
        x + cmtContentX,
        y - 2,
        20,
        width - cmtContentX - 104,
        'demibold',
      );
      if (item.timeLabel.isNotEmpty) {
        p.text(item.timeLabel, x + width - 92, y + 2, 16, 'regular', secondary);
      }

      // 正文（:148-156）。
      List<String> lines = glyphs.wrap(
        item.content,
        width - cmtContentX,
        cmtContentSize,
        'regular',
      );
      final bool truncated =
          !item.expanded && lines.length > cmtContentMaxLines;
      if (!item.expanded && lines.length > cmtContentMaxLines) {
        lines = lines.sublist(0, cmtContentMaxLines);
      }
      double rowY = y + 36;
      for (final String line in lines) {
        p.text(
          line,
          x + cmtContentX,
          rowY,
          cmtContentSize,
          'regular',
          foreground,
        );
        rowY += cmtContentLine;
      }

      // 元信息行（:157-186）。
      final double metaY = rowY + 12;
      // Qt `"♥ " + compactCount(item["likedCount"])` —— likedLabel 恒非空，
      // 这里对空串仍兜成 "0"，避免页面画出孤零零的 "♥ "。
      final String likedLabel = item.likedLabel.isEmpty ? '0' : item.likedLabel;
      // 同 song_detail：MiSans 缺 U+2665，字面 ♥ 真机会变成倒三角，改用「点赞 N」。
      final String liked = '点赞 $likedLabel';
      p.text(liked, x + cmtContentX, metaY, cmtMetaSize, 'regular', secondary);
      if (item.replyCount > 0) {
        final String label = item.repliesExpanded
            ? '收起回复 ↑'
            : '${item.replyCount} 条回复 ↓';
        final double replyX =
            x + cmtContentX + glyphs.width(liked, cmtMetaSize, 'regular') + 24;
        p.limited(
          label,
          replyX,
          metaY,
          cmtMetaSize,
          width - (replyX - x) - 14,
          'regular',
        );
        p.hit(
          replyX - 10,
          metaY - 14,
          180,
          48,
          'comments:replies:${item.id}',
          label,
        );
      }
      if (truncated || item.expanded) {
        final String label = item.expanded ? '收起' : '展开全文';
        p.limited(label, x + width - 84, metaY, cmtMetaSize, 84, 'regular');
        p.hit(
          x + width - 94,
          metaY - 14,
          96,
          48,
          'comments:expand:${item.id}',
          label,
        );
      }

      // 回复块（:188-235）。
      double afterMeta = metaY + 36;
      final List<CommentPanelReply> replies = item.repliesExpanded
          ? item.replies
          : item.inlineReplies;
      if (replies.isNotEmpty ||
          item.repliesLoading ||
          item.repliesError.isNotEmpty) {
        final double blockTop = afterMeta + 8;
        final double innerX = x + cmtContentX + 16;
        final double innerWidth = width - cmtContentX - 32;
        final List<_ReplyBlock> blocks = <_ReplyBlock>[];
        double blockHeight = 32;
        for (final CommentPanelReply reply in replies) {
          final String prefix = reply.prefix;
          final List<String> replyLines = glyphs.wrap(
            '$prefix${reply.content}',
            innerWidth,
            cmtReplySize,
            'regular',
          );
          blocks.add(
            _ReplyBlock(
              prefix: prefix,
              prefixWidth: glyphs.width(prefix, cmtReplySize, 'demibold'),
              lines: replyLines,
            ),
          );
          blockHeight += replyLines.length * cmtReplyLine + 10;
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
          blockHeight += 34;
        }
        p.fill(
          x + cmtContentX,
          blockTop,
          width - cmtContentX,
          blockHeight,
          cmtSoft(model.dark),
        );
        double replyY = blockTop + 16;
        for (final _ReplyBlock block in blocks) {
          // 前缀放得下时用 demibold 内联，首行首段切掉（:210-228）。
          final bool inlineName = block.prefixWidth < innerWidth - 48;
          if (inlineName) {
            p.text(
              block.prefix,
              innerX,
              replyY,
              cmtReplySize,
              'demibold',
              foreground,
            );
          }
          for (int line = 0; line < block.lines.length; line++) {
            String value = block.lines[line];
            double lineX = innerX;
            if (inlineName && line == 0) {
              value = value.substring(
                math.min(block.prefix.length, value.length),
              );
              lineX += block.prefixWidth;
            }
            if (value.isNotEmpty) {
              p.text(
                value,
                lineX,
                replyY + line * cmtReplyLine,
                cmtReplySize,
                'regular',
                secondary,
              );
            }
          }
          replyY += block.lines.length * cmtReplyLine + 10;
        }
        if (statusText.isNotEmpty) {
          p.limited(
            statusText,
            innerX,
            replyY + 4,
            cmtReplySize,
            innerWidth,
            'regular',
          );
          if (statusAction.isNotEmpty) {
            p.hit(
              x + cmtContentX,
              replyY - 6,
              width - cmtContentX,
              42,
              statusAction,
              statusText,
            );
          }
        }
        afterMeta = blockTop + blockHeight + 12;
      }

      // 行底分隔线（:237-242）。
      final double rowBottom = afterMeta + 10;
      final List<Object?> divider = <Object?>[
        foreground[0],
        foreground[1],
        foreground[2],
        0.14,
      ];
      p.fill(x, rowBottom, width, 1, divider);
      y = rowBottom + 28;
    }

    // 翻页 / 到底（:244-254）。
    if (model.hasMore) {
      if (model.loadingMore) {
        p.centeredText(
          '正在加载更多…',
          x + width / 2,
          y + 26,
          17,
          'regular',
          secondary,
        );
      } else {
        p.centeredText(
          '加载更多评论 ↓',
          x + width / 2,
          y + 26,
          17,
          'regular',
          secondary,
        );
        p.hit(x, y, width, 56, 'comments:load-more', '加载更多评论');
      }
      y += 64;
    } else if (model.items.isNotEmpty) {
      p.centeredText(
        'END OF COMMENTS / 评论到底了',
        x + width / 2,
        y + 26,
        14,
        'regular',
        secondary,
      );
      y += 64;
    }
  }
  p.restore();

  return CommentPanelDrawing(
    commands: p.commands,
    hits: p.hits,
    // y 是叠加了滚动偏移的绘制坐标；内容总高度必须去掉偏移（:256-258）。
    contentBottom: y + scroll,
  );
}

/// Qt `CommentsController::compactCount(int)`（CommentsController.cpp:131-143）。
///
/// Flutter 侧同语义实现由领域层负责（CommentController 的 `compactCount`），
/// 这里保留一份面板自用的纯函数：`totalLabel` 为空时才走到它。
String commentPanelCompactCount(int value) {
  if (value < 10000) {
    return '$value';
  }
  String text = (value / 10000.0).toStringAsFixed(1);
  if (text.endsWith('.0')) {
    text = text.substring(0, text.length - 2);
  }
  return '$text 万';
}

class _ReplyBlock {
  const _ReplyBlock({
    required this.prefix,
    required this.prefixWidth,
    required this.lines,
  });

  final String prefix;
  final double prefixWidth;
  final List<String> lines;
}

/// Qt NativeHud 原语（NativeHud.cpp:16-134）的薄端口。
class _CommentsPainter {
  _CommentsPainter({required this.glyphs, required this.dark});

  final CommentPanelGlyphs glyphs;
  final bool dark;

  final List<List<Object?>> commands = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  List<Object?> get ink => cmtInk(dark);

  void save() => commands.add(<Object?>['save']);
  void restore() => commands.add(<Object?>['restore']);
  void clip(double x, double y, double width, double height) =>
      commands.add(<Object?>['clip', x, y, width, height]);

  void fill(
    double x,
    double y,
    double width,
    double height,
    List<Object?> color,
  ) => commands.add(<Object?>['fill', color, x, y, width, height]);

  void text(
    String value,
    double x,
    double y,
    double size,
    String weight,
    List<Object?> color,
  ) => commands.add(<Object?>['text', value, x, y, size, weight, 0, color]);

  void image(String key, double x, double y, double width, double height) {
    if (key.isEmpty) {
      return;
    }
    commands.add(<Object?>['image', key, x, y, width, height]);
  }

  void hit(
    double x,
    double y,
    double width,
    double height,
    String action,
    String label,
  ) {
    hits.add(<String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'action': action,
      'label': label,
    });
  }

  void button(
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size,
  ) {
    hit(x, y, width, height, action, label);
    text(label, x, y + (height - size) / 2 - 4, size, 'regular', ink);
  }

  /// Qt NativeHud::centeredText（NativeHud.cpp:97-101）的 horizontal = true 分支。
  void centeredText(
    String value,
    double cx,
    double cy,
    double size,
    String weight,
    List<Object?> color,
  ) {
    // Qt 用 Glyphs::bounds 居中墨迹；本引擎的 centered 语义见
    // lib/hud/portrait/portrait_canvas.dart:160-175（bounds 由宿主度量端口给）。
    // 横屏这里没有 bounds 端口，用省掉墨迹内缩的近似：以字宽居中，
    // 并保持 Qt 的 `cy - height/2` 语义行走基线对齐。
    final double width = glyphs.width(value, size, weight);
    text(value, cx - width / 2, cy - size * 0.5, size, weight, color);
  }

  /// Qt NativeHud::fit（NativeHud.cpp:48-76）：二分最长前缀，截断时 chop(1)+「…」。
  String fit(String value, double size, double width, String weight) {
    int length = value.length;
    if (glyphs.width(value, size, weight) > width) {
      int low = 1;
      int high = length;
      while (low < high) {
        final int middle = (low + high + 1) ~/ 2;
        if (glyphs.width(value.substring(0, middle), size, weight) <= width) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      length = low;
    }
    if (length != value.length) {
      return '${value.substring(0, math.max(0, length - 1))}…';
    }
    return value;
  }

  /// Qt NativeHud::limited（NativeHud.cpp:94-96）：fit 后单行绘制。
  void limited(
    String value,
    double x,
    double y,
    double size,
    double width,
    String weight,
  ) {
    text(fit(value, size, width, weight), x, y, size, weight, ink);
  }
}
