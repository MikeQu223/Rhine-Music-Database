/// 评论控制器：把 [ProviderGateway] 的评论/回复调用收敛成一份可观察状态。
///
/// 契约来源（不写行号，源文件仍在追加片段）：
/// - `Qt/src/CommentsController.cpp`：首屏 page 0、`sort` 为 `hot|new`、
///   续页按已加载页数推进、`hasMore` 为 false 时不再请求；
/// - `MusicBridge/plugins/sdk/port.d.ts` 的 `CommentsPage` / `CommentRepliesPage`：
///   总条数缺失（0）时由调用方退回本页条数。
///
/// 本文件是纯 Dart（不 import flutter），状态串直接给 UI 显示，不做任何翻译层。
library;

import '../../provider/provider_gateway.dart';

/// 评论区的阶段。
enum CommentPhase {
  /// 未开始（或已 [CommentController.close]）。
  idle,

  /// 正在请求。
  loading,

  /// 已加载出评论。
  loaded,

  /// 请求成功但没有任何评论。
  empty,

  /// 请求失败（状态串里带原因）。
  failed,
}

/// 单条评论的回复区状态（内联在 [CommentState.replyState] 里）。
class CommentRepliesState {
  const CommentRepliesState({
    this.phase = CommentPhase.idle,
    this.status = '',
    this.comments = const <ProviderComment>[],
    this.hasMore = false,
    this.expanded = true,
    this.pages = 1,
  });

  /// 阶段。
  final CommentPhase phase;

  /// 状态串（失败时可显示"回复加载失败，点击重试"）。
  final String status;

  /// 已加载的回复。
  final List<ProviderComment> comments;

  /// 是否还有更多回复。
  final bool hasMore;

  /// 回复区是否展开（已加载后只切这个开关，不再请求）。
  final bool expanded;

  /// 已加载的回复页数（下一页就是它的值）。
  final int pages;

  /// 复制并替换字段；**没有**"设回默认值"的语义，`expanded` 一律显式给。
  CommentRepliesState copyWith({
    CommentPhase? phase,
    String? status,
    List<ProviderComment>? comments,
    bool? hasMore,
    bool? expanded,
    int? pages,
  }) {
    return CommentRepliesState(
      phase: phase ?? this.phase,
      status: status ?? this.status,
      comments: comments ?? this.comments,
      hasMore: hasMore ?? this.hasMore,
      expanded: expanded ?? this.expanded,
      pages: pages ?? this.pages,
    );
  }
}

/// 评论区的完整快照（不可变）。
class CommentState {
  const CommentState({
    this.phase = CommentPhase.idle,
    this.status = '',
    this.sort = ProviderCommentSort.hot,
    this.comments = const <ProviderComment>[],
    this.total = 0,
    this.hasMore = false,
    this.loadedPages = 0,
    this.expandedIds = const <String>{},
    this.replyState = const <String, CommentRepliesState>{},
  });

  /// 阶段。
  final CommentPhase phase;

  /// 状态串（UI 直接显示）。
  final String status;

  /// 当前排序。
  final ProviderCommentSort sort;

  /// 已加载的评论（续页追加）。
  final List<ProviderComment> comments;

  /// 总条数（平台没给时为已加载条数）。
  final int total;

  /// 是否还有下一页。
  final bool hasMore;

  /// 已加载页数（下一页就是它的值）。
  final int loadedPages;

  /// 展开全文的评论 id 集合。
  final Set<String> expandedIds;

  /// 每条评论的回复区状态（按评论 id）。
  final Map<String, CommentRepliesState> replyState;

  /// 复制并替换字段。
  CommentState copyWith({
    CommentPhase? phase,
    String? status,
    ProviderCommentSort? sort,
    List<ProviderComment>? comments,
    int? total,
    bool? hasMore,
    int? loadedPages,
    Set<String>? expandedIds,
    Map<String, CommentRepliesState>? replyState,
  }) {
    return CommentState(
      phase: phase ?? this.phase,
      status: status ?? this.status,
      sort: sort ?? this.sort,
      comments: comments ?? this.comments,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      loadedPages: loadedPages ?? this.loadedPages,
      expandedIds: expandedIds ?? this.expandedIds,
      replyState: replyState ?? this.replyState,
    );
  }
}

/// 评论控制器。
///
/// 只保存 `trackId`/`trackLabel` 用来在 [setSort] / [refresh] 时重放首屏请求；
/// 所有副作用都走 [onChanged]（UI 侧据此重绘，不需要监听流）。
class CommentController {
  CommentController({required this.gateway, this.onChanged});

  /// 平台网关（构造后不变）。
  final ProviderGateway gateway;

  /// 状态变化回调（可为空）。
  final void Function()? onChanged;

  CommentState _state = const CommentState();
  String _trackId = '';
  String _trackLabel = '';

  /// 正在追加后续页的评论 id（回复区的"正在读取回复…"不换 phase，
  /// 否则 [toggleReplies] 会把加载中误判成未加载而重放首屏）。
  final Set<String> _replyLoading = <String>{};

  /// 当前快照。
  CommentState get state => _state;

  /// 当前歌曲 id（未加载过时为空串）。
  String get trackId => _trackId;

  /// 当前歌曲标签（未加载过时为空串）。
  String get trackLabel => _trackLabel;

  void _set(CommentState next) {
    _state = next;
    onChanged?.call();
  }

  /// 读取首屏。能力不支持时直接落到 [CommentPhase.failed]。
  Future<void> load({required String trackId, String trackLabel = ''}) async {
    _trackId = trackId;
    _trackLabel = trackLabel;

    if (!gateway.capability('comments')) {
      _set(_state.copyWith(
        phase: CommentPhase.failed,
        status: '当前来源不支持评论',
        comments: const <ProviderComment>[],
        total: 0,
        hasMore: false,
        loadedPages: 0,
      ));
      return;
    }

    _set(_state.copyWith(phase: CommentPhase.loading, status: '正在读取评论…'));
    try {
      final ProviderCommentPage page = await gateway.comments(
        trackId: trackId,
        sort: _state.sort,
        page: 0,
      );
      final List<ProviderComment> comments = page.comments;
      if (comments.isEmpty) {
        _set(_state.copyWith(
          phase: CommentPhase.empty,
          status: '暂无评论',
          comments: const <ProviderComment>[],
          total: page.totalCount > 0 ? page.totalCount : 0,
          hasMore: page.hasMore,
          loadedPages: 1,
        ));
        return;
      }
      final int total = page.totalCount > 0 ? page.totalCount : comments.length;
      _set(_state.copyWith(
        phase: CommentPhase.loaded,
        status: '找到 $total 条评论',
        comments: comments,
        total: total,
        hasMore: page.hasMore,
        loadedPages: 1,
      ));
    } catch (error) {
      _set(_state.copyWith(
        phase: CommentPhase.failed,
        status: '评论加载失败：${_reason(error)}',
        comments: const <ProviderComment>[],
        total: 0,
        hasMore: false,
        loadedPages: 0,
      ));
    }
  }

  /// 切换排序并重放首屏（保留 [trackId]/[trackLabel]）。
  Future<void> setSort(ProviderCommentSort sort) async {
    _set(_state.copyWith(sort: sort));
    await load(trackId: _trackId, trackLabel: _trackLabel);
  }

  /// 重读首屏（排序不变）。
  Future<void> refresh() => load(trackId: _trackId, trackLabel: _trackLabel);

  /// 追加一页；`hasMore` 为 false 时不发请求。
  Future<void> loadMore() async {
    if (!_state.hasMore) {
      return;
    }
    final int page = _state.loadedPages;
    try {
      final ProviderCommentPage next = await gateway.comments(
        trackId: _trackId,
        sort: _state.sort,
        page: page,
      );
      final List<ProviderComment> merged = <ProviderComment>[
        ..._state.comments,
        ...next.comments,
      ];
      _set(_state.copyWith(
        phase: merged.isEmpty ? CommentPhase.empty : CommentPhase.loaded,
        comments: merged,
        total: next.totalCount > 0 ? next.totalCount : _state.total,
        hasMore: next.hasMore,
        loadedPages: page + 1,
      ));
    } catch (error) {
      _set(_state.copyWith(
        phase: CommentPhase.failed,
        status: '评论加载失败：${_reason(error)}',
      ));
    }
  }

  /// 展开/收起"全文"。
  void toggleExpanded(String commentId) {
    final Set<String> next = Set<String>.from(_state.expandedIds);
    if (!next.remove(commentId)) {
      next.add(commentId);
    }
    _set(_state.copyWith(expandedIds: next));
  }

  /// 是否已展开全文。
  bool isExpanded(String id) => _state.expandedIds.contains(id);

  /// 首次点击时加载回复，之后只切换展开/收起。
  Future<void> toggleReplies(String commentId) async {
    final CommentRepliesState? current = _state.replyState[commentId];
    final bool loaded = current != null &&
        (current.phase == CommentPhase.loaded || current.phase == CommentPhase.empty);

    if (loaded) {
      _set(_state.copyWith(
        replyState: <String, CommentRepliesState>{
          ..._state.replyState,
          commentId: current.copyWith(expanded: !current.expanded),
        },
      ));
      return;
    }

    // 首次（或上次失败重试）：先落 loading，再请求 page 0。
    _set(_state.copyWith(
      replyState: <String, CommentRepliesState>{
        ..._state.replyState,
        commentId: const CommentRepliesState(
          phase: CommentPhase.loading,
          status: '正在读取回复…',
        ),
      },
    ));
    try {
      final ProviderRepliesPage page = await gateway.replies(commentId: commentId, page: 0);
      final bool empty = page.comments.isEmpty;
      _set(_state.copyWith(
        replyState: <String, CommentRepliesState>{
          ..._state.replyState,
          commentId: CommentRepliesState(
            phase: empty ? CommentPhase.empty : CommentPhase.loaded,
            status: empty ? '暂无回复' : '找到 ${page.comments.length} 条回复',
            comments: page.comments,
            hasMore: page.hasMore,
            expanded: true,
          ),
        },
      ));
    } catch (error) {
      _set(_state.copyWith(
        replyState: <String, CommentRepliesState>{
          ..._state.replyState,
          commentId: const CommentRepliesState(
            phase: CommentPhase.failed,
            status: '回复加载失败，点击重试',
          ),
        },
      ));
    }
  }

  /// 追加某条评论的后续回复（`comments:replies-more:<id>`）。
  ///
  /// 只有已加载过、且 `hasMore` 为真时才发请求；追加期间 [CommentRepliesState.phase]
  /// 保持不变（只把 `status` 换成"正在读取回复…"），已有的回复照旧显示。
  Future<void> loadMoreReplies(String commentId) async {
    final CommentRepliesState? current = _state.replyState[commentId];
    if (current == null || !current.hasMore || _replyLoading.contains(commentId)) {
      return;
    }
    final int page = current.pages;
    _replyLoading.add(commentId);
    _set(_state.copyWith(
      replyState: <String, CommentRepliesState>{
        ..._state.replyState,
        commentId: current.copyWith(status: '正在读取回复…'),
      },
    ));
    try {
      final ProviderRepliesPage pageData =
          await gateway.replies(commentId: commentId, page: page);
      final List<ProviderComment> merged = <ProviderComment>[
        ...current.comments,
        ...pageData.comments,
      ];
      _set(_state.copyWith(
        replyState: <String, CommentRepliesState>{
          ..._state.replyState,
          commentId: CommentRepliesState(
            phase: merged.isEmpty ? CommentPhase.empty : CommentPhase.loaded,
            status: merged.isEmpty ? '暂无回复' : '找到 ${merged.length} 条回复',
            comments: merged,
            hasMore: pageData.hasMore,
            expanded: current.expanded,
            pages: page + 1,
          ),
        },
      ));
    } catch (_) {
      _set(_state.copyWith(
        replyState: <String, CommentRepliesState>{
          ..._state.replyState,
          commentId: current.copyWith(status: '回复加载失败，点击重试'),
        },
      ));
    } finally {
      _replyLoading.remove(commentId);
    }
  }

  /// 复位到 idle（换歌/关页面时调用）。
  void close() {
    _trackId = '';
    _trackLabel = '';
    _set(const CommentState());
  }

  /// 失败原因：平台不可用直接取中文 message，其它异常退回 toString()。
  String _reason(Object error) =>
      error is ProviderUnavailableError ? error.message : '$error';
}
