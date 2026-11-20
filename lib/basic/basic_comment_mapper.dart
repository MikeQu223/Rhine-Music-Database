/// 评论领域状态 → 竖屏评论页只读视图模型的映射层（纯 Dart，不 import flutter/widgets）。
///
/// 分工（三层各自的边界都是既有约定，不要在本文件里打穿）：
/// - 领域层 `lib/domain/comments/comment_controller.dart` 持有真实状态（首屏/续页/
///   排序/展开/回复），不 import flutter；
/// - 竖屏页 `lib/hud/portrait/portrait_pages_comments.dart:13-18` 明确「不 import
///   lib/domain」，页面数据面是它自己的只读视图模型（[PortraitCommentsModel] /
///   [PortraitCommentRow] / [PortraitCommentReply]）；
/// - 本文件就是这个缺口的唯一翻译层，放在宿主装配层 `lib/basic/`。
///
/// 口径来源（**不新造文案、不新造计数规则**）：
/// - `Qt/src/ResponsiveComments.cpp:17-180`：竖屏页消费的 `comments` JSON 字段
///   （`status`/`sort`/`totalLabel`/`items[*].avatarKey|likedLabel|expanded|…`）；
/// - `Qt/src/CommentsController.cpp:101-109`：`compactCount(int)`；
/// - `Qt/src/CommentsController.cpp:659-680`：`state()` 里 `items[*]` 的
///   `likedLabel = compactCount(likedCount)`、顶层 `totalLabel = compactCount(total)`、
///   `status` 取 `idle|loading|ready|empty|error`（`:465` 的 `ready`）；
/// - `lib/hud/modals/comments_modal.dart:536-549`：横屏面板既有的同义实现
///   `commentPanelCompactCount`（本文件的计数实现逐字对齐它）；
/// - `Qt/src/ResponsiveComments.cpp:26` 与 `Qt/src/NativeHudComments.cpp:51`：
///   `sourceName` 为空时回落 `providerName`。
///
/// 刻意**不**映射的字段（都有页面侧的既有口径，映射进来反而会分叉）：
/// - `loadingMore`：领域层 `CommentState` 没有这个字段（Qt 的 CommentsController 有，
///   Flutter 的 CommentController 的 `loadMore` 不动 `phase`），模型留 `false`；
///   宿主若自己有"追加中"态，直接构造 [PortraitCommentsModel] 或后续扩展参数；
/// - `truncated`：竖屏页按折行数自己判断（`portrait_pages_comments.dart:330-332`），
///   [PortraitCommentRow] 也没有该字段；
/// - `inlineMore`：页面用 `replyCount > replies.length && !repliesExpanded` 判断
///   （`portrait_pages_comments.dart:374-376`），不用平台的那个布尔；
/// - 头像像素：hud 层只认字符串 key（`lib/hud/modals/comments_modal.dart:112-113`
///   的 avatarKey 约定），所以 [PortraitCommentRow.avatarKey] 直接用 `avatarUrl`。
library;

import '../../domain/comments/comment_controller.dart';
import '../../provider/provider_gateway.dart';
import '../hud/portrait/portrait_pages_comments.dart';

/// Qt `CommentsController::compactCount(int)`（`Qt/src/CommentsController.cpp:101-109`）。
///
/// 规则（逐字照抄，**不是**「>=10000 就 (n/10000).toStringAsFixed(1) 万」的变体）：
/// - `< 10000`：`QString::number(value)`，即十进制原样；
/// - 否则：`QString::number(value / 10000.0, 'f', 1)` 一位小数，结尾 `.0` 时
///   `chop(2)` 去掉，再拼 `" 万"`。
///
/// 依据文件与行号：`lib/hud/modals/comments_modal.dart:540-549` 的
/// `commentPanelCompactCount` 是这份 Qt 规则的既有 Flutter 实现（其 doc 注释
/// :536 把出处记成 CommentsController.cpp:131-143，本仓库该文件的真实行号是
/// :101-109，规则本身一致）；竖屏页
/// `lib/hud/portrait/portrait_pages_comments.dart:339-341` 同样注明
/// `likedLabel` 恒为该函数的结果。这里照它的规则再实现一份，避免两套「万」。
///
/// 例：`9999 → '9999'`、`10000 → '1 万'`（不是 `'1.0 万'`）、
/// `12345 → '1.2 万'`、`123456 → '12.3 万'`。
String basicCommentCompactCount(int value) {
  if (value < 10000) {
    return '$value';
  }
  String text = (value / 10000.0).toStringAsFixed(1);
  if (text.endsWith('.0')) {
    text = text.substring(0, text.length - 2);
  }
  return '$text 万';
}

/// [CommentPhase] → 竖屏页 `status` 串。
///
/// 对应 `Qt/src/ResponsiveComments.cpp:56-70` 判的那五个值：
/// `idle` / `loading` / `ready` / `empty` / `error`；领域层的 `loaded` 就是 Qt 的
/// `ready`（`Qt/src/CommentsController.cpp:465` 的 `status = items.isEmpty() ?
/// "empty" : "ready"`），其余一一同名。
String basicCommentStatusOf(CommentPhase phase) {
  return switch (phase) {
    CommentPhase.idle => 'idle',
    CommentPhase.loading => 'loading',
    CommentPhase.loaded => 'ready',
    CommentPhase.empty => 'empty',
    CommentPhase.failed => 'error',
  };
}

/// 一条 [ProviderComment] → 竖屏页的 [PortraitCommentReply]。
///
/// 字段同名直取（`replyTo` 也直接抄，页面用它拼 `昵称 回复 @xxx：正文`，
/// 见 `portrait_pages_comments.dart:79-84`）。
PortraitCommentReply portraitCommentReplyOf(ProviderComment comment) {
  return PortraitCommentReply(
    id: comment.id,
    nickname: comment.nickname,
    content: comment.content,
    replyTo: comment.replyTo,
  );
}

/// 一条评论 → 竖屏页的一行 [PortraitCommentRow]。
///
/// 参数即真值，本函数**不做隐藏推导**（每条字段只有一个来源，便于单测钉死）：
/// - [repliesExpanded] / [repliesLoading] / [repliesError] 原样落行；它们与
///   [replies] 的领域态是同一件事的两条通道，选哪条由调用方决定——
///   [portraitCommentsModelOf] 总是把 `replies.expanded` / `phase` / `status`
///   折算好再传进来（那里才是「领域态 → 行」的真映射）；
/// - `replies`（列表）只来自 `replies.comments`，`repliesHasMore` 只来自
///   `replies.hasMore`（缺省 false，对应 Qt item 的 `repliesHasMore` 缺省）；
/// - 其余字段：`avatarKey = avatarUrl`（hud 层只存字符串 key）、
///   `likedLabel = basicCommentCompactCount(likedCount)`（Qt `state()` :666
///   同口径）、`timeLabel` 原样（平台已格式化）、`expanded` 由调用方给
///   （领域层 `CommentState.expandedIds` 是否命中该 id）。
PortraitCommentRow portraitCommentRowOf(
  ProviderComment comment, {
  required bool expanded,
  CommentRepliesState? replies,
  bool repliesExpanded = false,
  bool repliesLoading = false,
  String repliesError = '',
}) {
  return PortraitCommentRow(
    id: comment.id,
    nickname: comment.nickname,
    content: comment.content,
    avatarKey: comment.avatarUrl,
    timeLabel: comment.timeLabel,
    likedLabel: basicCommentCompactCount(comment.likedCount),
    replyCount: comment.replyCount,
    expanded: expanded,
    inlineReplies: <PortraitCommentReply>[
      for (final ProviderComment reply in comment.inlineReplies)
        portraitCommentReplyOf(reply),
    ],
    replies: <PortraitCommentReply>[
      for (final ProviderComment reply in replies?.comments ?? const <ProviderComment>[])
        portraitCommentReplyOf(reply),
    ],
    repliesExpanded: repliesExpanded,
    repliesHasMore: replies?.hasMore ?? false,
    repliesLoading: repliesLoading,
    repliesError: repliesError,
  );
}

/// 一整页 [CommentState] → 竖屏页 [PortraitCommentsModel]。
///
/// 逐条对应本任务的映射规则：
/// - `status`：见 [basicCommentStatusOf]（`loaded → 'ready'`）；
/// - `message = state.status` 原样（失败串里已带原因，页面空串时才用兜底文案）；
/// - `sort = state.sort.id`（`hot` / `new`，与 Qt `comments["sort"]`、命中串
///   `comments:sort:<id>` 同一份值；`ProviderCommentSort` 的展示名在 `label`，
///   平台参数值才是 `id`）；
/// - `totalLabel`：`total <= 0` 时空串（Qt `compactCount(0)` 得 `"0"`，页面用
///   `totalLabel != "0"` 再兜一层，见 `portrait_pages_comments.dart:261`），
///   否则 [basicCommentCompactCount]；
/// - `hasMore` 直取；
/// - `sourceName`：空时回落 [providerName]（Qt `ResponsiveComments.cpp:26` /
///   `NativeHudComments.cpp:51` 的 `.toString(providerName)` 口径）；
/// - `sourceLabel` / `providerId` 原样（只有 `providerId == 'siren'` 时页面才拼
///   "已匹配 / 正在匹配歌曲… / 未匹配到歌曲"，见 `portrait_pages_comments.dart:252-260`）；
/// - `items`：每条评论一行，`expanded` 看 `state.expandedIds` 是否含该 id，
///   回复区状态取 `state.replyState[id]`，并在这里把 [CommentRepliesState] 的
///   三个开关折成行参数（[portraitCommentRowOf] 自己不做推导）：
///   `repliesExpanded = replies.expanded`（Qt 取回回复后置 `repliesExpanded = true`，
///   `Qt/src/CommentsController.cpp:624-628`；领域层缺省也是 true）、
///   `repliesLoading = replies.phase == CommentPhase.loading`、
///   `repliesError = replies.phase == CommentPhase.failed ? replies.status : ''`
///   （领域层失败串就是「回复加载失败，点击重试」，见
///   `lib/domain/comments/comment_controller.dart:333-343`）。
///
/// `loadingMore` 恒 false 的原因见文件头注释（领域层没有该字段）。
PortraitCommentsModel portraitCommentsModelOf(
  CommentState state, {
  String sourceName = '',
  String sourceLabel = '',
  String providerId = '',
  String providerName = '',
}) {
  final String totalLabel =
      state.total > 0 ? basicCommentCompactCount(state.total) : '';
  return PortraitCommentsModel(
    status: basicCommentStatusOf(state.phase),
    message: state.status,
    sort: state.sort.id,
    totalLabel: totalLabel,
    hasMore: state.hasMore,
    sourceName: sourceName.isEmpty ? providerName : sourceName,
    sourceLabel: sourceLabel,
    providerId: providerId,
    items: <PortraitCommentRow>[
      for (final ProviderComment comment in state.comments)
        _rowWithReplies(comment, state),
    ],
  );
}

PortraitCommentRow _rowWithReplies(ProviderComment comment, CommentState state) {
  final CommentRepliesState? replies = state.replyState[comment.id];
  return portraitCommentRowOf(
    comment,
    expanded: state.expandedIds.contains(comment.id),
    replies: replies,
    repliesExpanded: replies?.expanded ?? false,
    repliesLoading: replies?.phase == CommentPhase.loading,
    repliesError: replies?.phase == CommentPhase.failed ? replies!.status : '',
  );
}
