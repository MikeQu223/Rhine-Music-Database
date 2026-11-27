// 评论命中动作表：把 `comments:*` 的命中串映射成控制器调用。
//
// 真值来自 Qt/src/NativeHudController.cpp:714-746（逐条对应，连 `mid(n)` 的前缀
// 长度都照抄，所以 value 里出现 ':' 也不会被切坏）：
//
//   comments:close               → commentsMode=false; tab 回 commentsReturnTab/overview
//   comments:sort:<value>        → music.comments.setSort(value.mid(14))
//   comments:refresh / :retry    → music.comments.refresh()
//   comments:load-more           → music.comments.loadMore()
//   comments:replies-more:<id>   → music.comments.loadMoreReplies(value.mid(22))
//   comments:replies:<id>        → music.comments.toggleReplies(value.mid(17))
//   comments:expand:<id>         → music.comments.toggleExpanded(value.mid(16))
//
// 本文件只碰控制器，不碰 UI 状态：
// - `comments:close` 在这里只做 `controller.close()`，关闭模态（Qt 的
//   commentsMode=false + commentsScroll=0 + tab 回退）仍由宿主做，因此解析结果
//   是 [CommentActionKind.close]，调用方拿到 [CommentActionResult.closed] 后自己
//   收面板。Qt 里 sort/refresh/retry 还会把 commentsScroll 归零，那份滚动状态也
//   属于宿主，动作表不持有它。
// - 其余动作全部等价于一次控制器方法调用。
library;

import '../../provider/provider_gateway.dart';
import 'comment_controller.dart';

/// 命中动作前缀。
const String commentActionPrefix = 'comments:';

/// `comments:sort:` 之后的部分。
const String commentSortActionPrefix = 'comments:sort:';

/// 一条 `comments:*` 动作解析出来的种类。
enum CommentActionKind {
  /// 关闭评论面板（宿主负责收模态）。
  close,

  /// 切换排序，值见 [CommentActionRequest.value]（`hot` / `new`）。
  sort,

  /// 刷新首屏（`comments:refresh` 与 `comments:retry` 同义，见 Qt:725）。
  refresh,

  /// 追加下一页。
  loadMore,

  /// 展开/收起某条评论的回复。
  toggleReplies,

  /// 追加载某条评论的后续回复。
  loadMoreReplies,

  /// 展开/收起某条评论的正文。
  expand,
}

/// 解析结果。`value` 是排序值或评论 id（[CommentActionKind.close] /
/// [refresh] / [loadMore] 时为空串）。
class CommentActionRequest {
  const CommentActionRequest(this.kind, {this.value = ''});

  /// 动作种类。
  final CommentActionKind kind;

  /// 排序值或评论 id。
  final String value;

  @override
  String toString() => 'CommentActionRequest($kind, $value)';

  @override
  bool operator ==(Object other) =>
      other is CommentActionRequest && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// 动作执行结果。
enum CommentActionResult {
  /// 不是 `comments:*`，调用方继续走自己的分支。
  unhandled,

  /// 已经作用到控制器上。
  handled,

  /// 已经 `close()` 控制器，宿主还需要收起面板并重置滚动。
  closed,
}

/// 是否是评论面板的命中动作（含无法解析的那些，宿主据此吞掉而不是当未知动作）。
bool isCommentAction(String action) => action.startsWith(commentActionPrefix);

/// 把动作串解析成 [CommentActionRequest]；不是 `comments:*` 或缺少必要参数时返回 null。
///
/// 注意前后缀顺序：`comments:replies-more:` 必须在 `comments:replies:` 之前判，
/// 否则 `replies-more:c1` 会被当成 id 为 `more:c1` 的 toggleReplies。
CommentActionRequest? parseCommentAction(String action) {
  if (!isCommentAction(action)) {
    return null;
  }
  if (action == 'comments:close') {
    return const CommentActionRequest(CommentActionKind.close);
  }
  if (action == 'comments:refresh' || action == 'comments:retry') {
    return const CommentActionRequest(CommentActionKind.refresh);
  }
  if (action == 'comments:load-more') {
    return const CommentActionRequest(CommentActionKind.loadMore);
  }
  const String sortPrefix = 'comments:sort:';
  if (action.startsWith(sortPrefix)) {
    final String value = action.substring(sortPrefix.length);
    return value.isEmpty
        ? null
        : CommentActionRequest(CommentActionKind.sort, value: value);
  }
  const String repliesMorePrefix = 'comments:replies-more:';
  if (action.startsWith(repliesMorePrefix)) {
    final String id = action.substring(repliesMorePrefix.length);
    return id.isEmpty
        ? null
        : CommentActionRequest(CommentActionKind.loadMoreReplies, value: id);
  }
  const String repliesPrefix = 'comments:replies:';
  if (action.startsWith(repliesPrefix)) {
    final String id = action.substring(repliesPrefix.length);
    return id.isEmpty
        ? null
        : CommentActionRequest(CommentActionKind.toggleReplies, value: id);
  }
  const String expandPrefix = 'comments:expand:';
  if (action.startsWith(expandPrefix)) {
    final String id = action.substring(expandPrefix.length);
    return id.isEmpty
        ? null
        : CommentActionRequest(CommentActionKind.expand, value: id);
  }
  return null;
}

/// 排序值 → [ProviderCommentSort]；未知值按 Qt `setSort` 的宽松语义回落 `hot`。
ProviderCommentSort commentSortFromValue(String value) {
  for (final ProviderCommentSort sort in ProviderCommentSort.values) {
    if (sort.id == value) {
      return sort;
    }
  }
  return ProviderCommentSort.hot;
}

/// 对控制器执行一条已解析的动作。
Future<CommentActionResult> applyCommentAction(
  CommentActionRequest request,
  CommentController controller,
) async {
  switch (request.kind) {
    case CommentActionKind.close:
      controller.close();
      return CommentActionResult.closed;
    case CommentActionKind.sort:
      if (controller.state.sort == commentSortFromValue(request.value)) {
        // Qt 里重复点同一个 chip 仍会打一次请求，但滚动归零是唯一可见效果；
        // 控制器这边没有滚动状态，重复请求纯属浪费配额，直接忽略。
        return CommentActionResult.handled;
      }
      await controller.setSort(commentSortFromValue(request.value));
      return CommentActionResult.handled;
    case CommentActionKind.refresh:
      await controller.refresh();
      return CommentActionResult.handled;
    case CommentActionKind.loadMore:
      await controller.loadMore();
      return CommentActionResult.handled;
    case CommentActionKind.toggleReplies:
      await controller.toggleReplies(request.value);
      return CommentActionResult.handled;
    case CommentActionKind.loadMoreReplies:
      await controller.loadMoreReplies(request.value);
      return CommentActionResult.handled;
    case CommentActionKind.expand:
      controller.toggleExpanded(request.value);
      return CommentActionResult.handled;
  }
}

/// 一站式入口：解析 + 执行。不是 `comments:*`（或参数残缺）时返回
/// [CommentActionResult.unhandled]，宿主继续走自己的分支。
Future<CommentActionResult> dispatchCommentAction(
  String action,
  CommentController controller,
) async {
  final CommentActionRequest? request = parseCommentAction(action);
  if (request == null) {
    return CommentActionResult.unhandled;
  }
  return applyCommentAction(request, controller);
}
