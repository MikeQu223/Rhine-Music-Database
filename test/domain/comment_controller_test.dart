/// 评论控制器测试：逐条覆盖加载/空/失败/排序/续页/展开/回复/复位。
///
/// 假网关只实现被调到的方法，其余一律 `UnimplementedError`——任何越界调用都会直接被
/// 测试炸出来，不用额外断言"没调别的接口"。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/comments/comment_controller.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';
import 'provider_gateway_stub.dart';

ProviderComment _comment(String id, {int replyCount = 0}) => ProviderComment(
      id: id,
      content: '正文 $id',
      nickname: '用户 $id',
      replyCount: replyCount,
    );

class _FakeGateway with ProviderGatewayStub implements ProviderGateway {
  _FakeGateway({
    this.commentsSupported = true,
    this.pages = const <ProviderCommentPage>[],
    this.repliesPage = const ProviderRepliesPage(comments: <ProviderComment>[]),
    this.commentsError = false,
    this.repliesError = false,
  });

  bool commentsSupported;

  /// 按 page 索引返回；越界时退回最后一页。
  List<ProviderCommentPage> pages;
  ProviderRepliesPage repliesPage;
  bool commentsError;
  bool repliesError;

  final List<int> commentPagesRequested = <int>[];
  final List<String> commentsTrackIds = <String>[];
  final List<ProviderCommentSort> commentsSorts = <ProviderCommentSort>[];
  final List<String> replyIdsRequested = <String>[];
  final List<int> replyPagesRequested = <int>[];
  int calls = 0;

  @override
  String get providerId => 'fake';

  @override
  bool capability(String key, {bool fallback = true}) {
    expect(key, 'comments');
    return commentsSupported;
  }

  @override
  bool operation(String key, {bool fallback = false}) => throw UnimplementedError();

  @override
  List<ProviderLoginMethod> get loginMethods => throw UnimplementedError();

  @override
  Future<ProviderAccount> account() => throw UnimplementedError();

  @override
  Future<ProviderLoginSession> beginLogin(String method) => throw UnimplementedError();

  @override
  Future<ProviderLoginPoll> pollLogin(String token) => throw UnimplementedError();

  @override
  Future<void> cancelLogin() => throw UnimplementedError();

  @override
  Future<void> sendLoginCode(String phone, String method) => throw UnimplementedError();

  @override
  Future<void> submitLoginCode(String phone, String code, String method) =>
      throw UnimplementedError();

  @override
  Future<void> logout() => throw UnimplementedError();

  @override
  Future<ProviderCommentPage> comments({
    required String trackId,
    required ProviderCommentSort sort,
    required int page,
    String cursor = '',
  }) async {
    calls++;
    commentPagesRequested.add(page);
    commentsTrackIds.add(trackId);
    commentsSorts.add(sort);
    if (commentsError) {
      throw const ProviderUnavailableError('通道未接通');
    }
    if (pages.isEmpty) {
      return const ProviderCommentPage(comments: <ProviderComment>[]);
    }
    final int index = page < pages.length ? page : pages.length - 1;
    return pages[index];
  }

  @override
  Future<ProviderRepliesPage> replies({required String commentId, required int page}) async {
    calls++;
    replyIdsRequested.add(commentId);
    replyPagesRequested.add(page);
    if (repliesError) {
      throw StateError('boom');
    }
    return repliesPage;
  }

  @override
  Future<List<ProviderMvVersion>> mvVersions({required String trackId}) =>
      throw UnimplementedError();

  @override
  Future<ProviderMvTrack> mv({required String trackId, required String versionId}) => throw UnimplementedError();

  @override
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  }) => throw UnimplementedError();
}

void main() {
  test('不支持评论能力的来源落 failed 并给出拒绝串', () async {
    final _FakeGateway gateway = _FakeGateway(commentsSupported: false);
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1');

    expect(controller.state.phase, CommentPhase.failed);
    expect(controller.state.status, '当前来源不支持评论');
    expect(gateway.calls, 0);
  });

  test('加载成功给出总数串与 loaded 阶段', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[
        ProviderCommentPage(
          comments: <ProviderComment>[ProviderComment(id: 'c1', content: 'a', nickname: 'n')],
          totalCount: 42,
          hasMore: true,
        ),
      ],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1', trackLabel: '歌名');

    expect(controller.state.phase, CommentPhase.loaded);
    expect(controller.state.status, '找到 42 条评论');
    expect(controller.state.comments.length, 1);
    expect(controller.state.total, 42);
    expect(controller.state.hasMore, isTrue);
    expect(controller.state.loadedPages, 1);
    expect(gateway.commentPagesRequested, <int>[0]);
    expect(gateway.commentsTrackIds, <String>['t1']);
    expect(controller.trackLabel, '歌名');
  });

  test('页面没给总数时用本页条数叙述', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[
        ProviderCommentPage(
          comments: <ProviderComment>[
            ProviderComment(id: 'c1', content: 'a', nickname: 'n'),
            ProviderComment(id: 'c2', content: 'b', nickname: 'm'),
          ],
        ),
      ],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1');

    expect(controller.state.status, '找到 2 条评论');
    expect(controller.state.total, 2);
  });

  test('空评论落 empty', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[ProviderCommentPage(comments: <ProviderComment>[])],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1');

    expect(controller.state.phase, CommentPhase.empty);
    expect(controller.state.status, '暂无评论');
    expect(controller.state.comments, isEmpty);
  });

  test('异常失败串带上普通异常文本', () async {
    final CommentController controller = CommentController(gateway: _FakeGateway(commentsError: true));
    await controller.load(trackId: 't1');

    expect(controller.state.phase, CommentPhase.failed);
    expect(controller.state.status, '评论加载失败：通道未接通');
  });

  test('setSort 换排序并重放首屏（保留 trackId）', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[
        ProviderCommentPage(
          comments: <ProviderComment>[ProviderComment(id: 'c1', content: 'a', nickname: 'n')],
          totalCount: 1,
        ),
      ],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1');
    expect(controller.state.sort, ProviderCommentSort.hot);

    await controller.setSort(ProviderCommentSort.newest);

    expect(controller.state.sort, ProviderCommentSort.newest);
    expect(gateway.commentsSorts.last, ProviderCommentSort.newest);
    expect(gateway.commentsTrackIds.last, 't1');
    expect(gateway.commentPagesRequested, <int>[0, 0]);
  });

  test('loadMore 追加第二页并从页面取 hasMore', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[
        ProviderCommentPage(
          comments: <ProviderComment>[ProviderComment(id: 'c1', content: 'a', nickname: 'n')],
          totalCount: 3,
          hasMore: true,
        ),
        ProviderCommentPage(
          comments: <ProviderComment>[
            ProviderComment(id: 'c2', content: 'b', nickname: 'm'),
            ProviderComment(id: 'c3', content: 'c', nickname: 'k'),
          ],
          totalCount: 3,
          hasMore: false,
        ),
      ],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1');
    await controller.loadMore();

    expect(controller.state.comments.map((ProviderComment c) => c.id).toList(), <String>['c1', 'c2', 'c3']);
    expect(controller.state.loadedPages, 2);
    expect(controller.state.hasMore, isFalse);
    expect(controller.state.total, 3);
    expect(gateway.commentPagesRequested, <int>[0, 1]);
  });

  test('hasMore 为 false 时 loadMore 不发请求', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[
        ProviderCommentPage(
          comments: <ProviderComment>[ProviderComment(id: 'c1', content: 'a', nickname: 'n')],
          totalCount: 1,
        ),
      ],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1');
    await controller.loadMore();

    expect(gateway.commentPagesRequested, <int>[0]);
    expect(gateway.calls, 1);
  });

  test('toggleExpanded 往返并反映 isExpanded', () async {
    final CommentController controller = CommentController(gateway: _FakeGateway());
    expect(controller.isExpanded('c1'), isFalse);

    controller.toggleExpanded('c1');
    expect(controller.isExpanded('c1'), isTrue);
    expect(controller.state.expandedIds, <String>{'c1'});

    controller.toggleExpanded('c1');
    expect(controller.isExpanded('c1'), isFalse);
    expect(controller.state.expandedIds, isEmpty);
  });

  test('toggleReplies 首次加载成功，再次调用只切 expanded', () async {
    final _FakeGateway gateway = _FakeGateway(
      repliesPage: const ProviderRepliesPage(
        comments: <ProviderComment>[ProviderComment(id: 'r1', content: 'r', nickname: 'n')],
        hasMore: true,
      ),
    );
    final CommentController controller = CommentController(gateway: gateway);

    await controller.toggleReplies('c1');

    final CommentRepliesState first = controller.state.replyState['c1']!;
    expect(first.phase, CommentPhase.loaded);
    expect(first.comments.length, 1);
    expect(first.hasMore, isTrue);
    expect(first.expanded, isTrue);
    expect(gateway.replyIdsRequested, <String>['c1']);
    expect(gateway.replyPagesRequested, <int>[0]);

    await controller.toggleReplies('c1');
    expect(controller.state.replyState['c1']!.expanded, isFalse);
    expect(gateway.replyIdsRequested, <String>['c1']);
    expect(gateway.calls, 1);
  });

  test('toggleReplies 失败写重试串且可重试', () async {
    final _FakeGateway gateway = _FakeGateway(repliesError: true);
    final CommentController controller = CommentController(gateway: gateway);

    await controller.toggleReplies('c1');

    final CommentRepliesState failed = controller.state.replyState['c1']!;
    expect(failed.phase, CommentPhase.failed);
    expect(failed.status, '回复加载失败，点击重试');

    // 失败后再次调用仍然会重发请求（不是切 expanded）。
    await controller.toggleReplies('c1');
    expect(gateway.replyIdsRequested, <String>['c1', 'c1']);
  });

  test('close 复位为 idle 并清掉歌曲与回复状态', () async {
    final _FakeGateway gateway = _FakeGateway(
      pages: const <ProviderCommentPage>[
        ProviderCommentPage(
          comments: <ProviderComment>[ProviderComment(id: 'c1', content: 'a', nickname: 'n')],
          totalCount: 1,
        ),
      ],
    );
    final CommentController controller = CommentController(gateway: gateway);
    await controller.load(trackId: 't1', trackLabel: '歌名');
    controller.toggleExpanded('c1');

    controller.close();

    expect(controller.state.phase, CommentPhase.idle);
    expect(controller.state.status, '');
    expect(controller.state.comments, isEmpty);
    expect(controller.state.expandedIds, isEmpty);
    expect(controller.state.replyState, isEmpty);
    expect(controller.trackId, '');
  });

  test('onChanged 在每次状态写回时触发', () async {
    final List<CommentPhase> seen = <CommentPhase>[];
    late final CommentController controller;
    controller = CommentController(
      gateway: _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[ProviderComment(id: 'c1', content: 'a', nickname: 'n')],
            totalCount: 1,
          ),
        ],
      ),
      onChanged: () => seen.add(controller.state.phase),
    );

    await controller.load(trackId: 't1');
    expect(seen, <CommentPhase>[CommentPhase.loading, CommentPhase.loaded]);

    controller.close();
    expect(seen.last, CommentPhase.idle);
    expect(seen.length, 3);
  });
}
