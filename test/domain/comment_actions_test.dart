/// 评论命中动作表测试：解析（含前缀歧义）+ 执行（打点网关调用）。
///
/// 真值口径：Qt/src/NativeHudController.cpp:714-746。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/comments/comment_actions.dart';
import 'package:rhine_music_database/domain/comments/comment_controller.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';
import 'provider_gateway_stub.dart';

ProviderComment _comment(String id) =>
    ProviderComment(id: id, content: '正文 $id', nickname: '用户 $id');

class _FakeGateway with ProviderGatewayStub implements ProviderGateway {
  _FakeGateway({this.pages = const <ProviderCommentPage>[]});

  List<ProviderCommentPage> pages;
  ProviderRepliesPage repliesPage = const ProviderRepliesPage(
    comments: <ProviderComment>[],
  );

  final List<int> commentPagesRequested = <int>[];
  final List<ProviderCommentSort> commentsSorts = <ProviderCommentSort>[];
  final List<String> replyIdsRequested = <String>[];
  final List<int> replyPagesRequested = <int>[];

  @override
  String get providerId => 'fake';

  @override
  bool capability(String key, {bool fallback = true}) => true;

  @override
  bool operation(String key, {bool fallback = false}) => false;

  @override
  List<ProviderLoginMethod> get loginMethods => const <ProviderLoginMethod>[];

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
    commentPagesRequested.add(page);
    commentsSorts.add(sort);
    if (pages.isEmpty) {
      return const ProviderCommentPage(comments: <ProviderComment>[]);
    }
    final int index = page < pages.length ? page : pages.length - 1;
    return pages[index];
  }

  @override
  Future<ProviderRepliesPage> replies({required String commentId, required int page}) async {
    replyIdsRequested.add(commentId);
    replyPagesRequested.add(page);
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
  group('解析', () {
    test('非 comments: 前缀一律不认', () {
      expect(isCommentAction('player:lyrics'), isFalse);
      expect(parseCommentAction('player:lyrics'), isNull);
      expect(parseCommentAction(''), isNull);
    });

    test('七种动作逐个对齐 Qt:714-746', () {
      expect(parseCommentAction('comments:close'),
          const CommentActionRequest(CommentActionKind.close));
      expect(parseCommentAction('comments:refresh'),
          const CommentActionRequest(CommentActionKind.refresh));
      expect(parseCommentAction('comments:retry'),
          const CommentActionRequest(CommentActionKind.refresh));
      expect(parseCommentAction('comments:load-more'),
          const CommentActionRequest(CommentActionKind.loadMore));
      expect(parseCommentAction('comments:sort:hot'),
          const CommentActionRequest(CommentActionKind.sort, value: 'hot'));
      expect(parseCommentAction('comments:sort:new'),
          const CommentActionRequest(CommentActionKind.sort, value: 'new'));
      expect(parseCommentAction('comments:expand:c1'),
          const CommentActionRequest(CommentActionKind.expand, value: 'c1'));
      expect(parseCommentAction('comments:replies:c1'),
          const CommentActionRequest(CommentActionKind.toggleReplies, value: 'c1'));
      expect(parseCommentAction('comments:replies-more:c1'),
          const CommentActionRequest(CommentActionKind.loadMoreReplies, value: 'c1'));
    });

    test('replies-more 优先于 replies，不会把 id 切成 "more:c1"', () {
      final CommentActionRequest? request =
          parseCommentAction('comments:replies-more:c9');
      expect(request!.kind, CommentActionKind.loadMoreReplies);
      expect(request.value, 'c9');
    });

    test('id 里含冒号时整段保留（Qt 用 mid(n) 切前缀，不 split）', () {
      expect(parseCommentAction('comments:expand:a:b')!.value, 'a:b');
      expect(parseCommentAction('comments:replies:a:b')!.value, 'a:b');
      expect(parseCommentAction('comments:replies-more:a:b')!.value, 'a:b');
    });

    test('缺参数（空 id / 空排序值）视为坏动作，返回 null', () {
      expect(parseCommentAction('comments:expand:'), isNull);
      expect(parseCommentAction('comments:replies:'), isNull);
      expect(parseCommentAction('comments:replies-more:'), isNull);
      expect(parseCommentAction('comments:sort:'), isNull);
    });

    test('拼写错误不算评论动作', () {
      expect(parseCommentAction('comments:loadmore'), isNull);
      expect(parseCommentAction('comments:refres'), isNull);
    });

    test('排序值 → ProviderCommentSort；未知值回落热门', () {
      expect(commentSortFromValue('hot'), ProviderCommentSort.hot);
      expect(commentSortFromValue('new'), ProviderCommentSort.newest);
      expect(commentSortFromValue('time'), ProviderCommentSort.hot);
    });
  });

  group('执行', () {
    test('未知动作返回 unhandled，控制器不动', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CommentController controller = CommentController(gateway: gateway);
      expect(await dispatchCommentAction('player:lyrics', controller),
          CommentActionResult.unhandled);
      expect(gateway.commentPagesRequested, isEmpty);
    });

    test('load-more 走控制器续页', () async {
      final _FakeGateway gateway = _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c1', content: 'a', nickname: 'n'),
            ],
            hasMore: true,
          ),
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c2', content: 'b', nickname: 'n'),
            ],
            hasMore: false,
          ),
        ],
      );
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');

      expect(await dispatchCommentAction('comments:load-more', controller),
          CommentActionResult.handled);
      expect(gateway.commentPagesRequested, <int>[0, 1]);
      expect(controller.state.comments.map((ProviderComment c) => c.id),
          <String>['c1', 'c2']);
    });

    test('sort:new 触发 setSort 并重放首屏（page 0 + newest）', () async {
      final _FakeGateway gateway = _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c1', content: 'a', nickname: 'n'),
            ],
          ),
        ],
      );
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');

      expect(await dispatchCommentAction('comments:sort:new', controller),
          CommentActionResult.handled);
      expect(controller.state.sort, ProviderCommentSort.newest);
      expect(gateway.commentsSorts.last, ProviderCommentSort.newest);
      expect(gateway.commentPagesRequested.last, 0);
    });

    test('重复点同一个 chip 不发请求（Qt 里只有滚动归零的可见效果）', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');
      final int before = gateway.commentPagesRequested.length;

      expect(await dispatchCommentAction('comments:sort:hot', controller),
          CommentActionResult.handled);
      expect(gateway.commentPagesRequested.length, before);
    });

    test('refresh 与 retry 等价：都重放首屏', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1', trackLabel: '歌名');

      expect(await dispatchCommentAction('comments:refresh', controller),
          CommentActionResult.handled);
      expect(await dispatchCommentAction('comments:retry', controller),
          CommentActionResult.handled);
      expect(gateway.commentPagesRequested, <int>[0, 0, 0]);
    });

    test('expand:<id> 切展开集合', () async {
      final _FakeGateway gateway = _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c1', content: 'a', nickname: 'n'),
            ],
          ),
        ],
      );
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');

      await dispatchCommentAction('comments:expand:c1', controller);
      expect(controller.isExpanded('c1'), isTrue);
      await dispatchCommentAction('comments:expand:c1', controller);
      expect(controller.isExpanded('c1'), isFalse);
      expect(gateway.commentPagesRequested, <int>[0]);
    });

    test('replies:<id> 首屏拉回复，再点只切展开', () async {
      final _FakeGateway gateway = _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c1', content: 'a', nickname: 'n', replyCount: 2),
            ],
          ),
        ],
      );
      gateway.repliesPage = ProviderRepliesPage(comments: <ProviderComment>[_comment('r1')]);
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');

      await dispatchCommentAction('comments:replies:c1', controller);
      expect(gateway.replyIdsRequested, <String>['c1']);
      expect(gateway.replyPagesRequested, <int>[0]);
      expect(controller.state.replyState['c1']!.expanded, isTrue);

      await dispatchCommentAction('comments:replies:c1', controller);
      expect(gateway.repliesPage.comments.length, 1);
      expect(gateway.replyIdsRequested, <String>['c1']);
      expect(controller.state.replyState['c1']!.expanded, isFalse);
    });

    test('replies-more:<id> 追加下一页回复', () async {
      final _FakeGateway gateway = _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c1', content: 'a', nickname: 'n', replyCount: 3),
            ],
          ),
        ],
      );
      gateway.repliesPage = ProviderRepliesPage(
        comments: <ProviderComment>[_comment('r1')],
        hasMore: true,
      );
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');
      await dispatchCommentAction('comments:replies:c1', controller);

      gateway.repliesPage = ProviderRepliesPage(
        comments: <ProviderComment>[_comment('r2')],
        hasMore: false,
      );
      expect(await dispatchCommentAction('comments:replies-more:c1', controller),
          CommentActionResult.handled);
      expect(gateway.replyPagesRequested, <int>[0, 1]);
      expect(controller.state.replyState['c1']!.comments.map((ProviderComment c) => c.id),
          <String>['r1', 'r2']);
      expect(controller.state.replyState['c1']!.hasMore, isFalse);
      expect(controller.state.replyState['c1']!.pages, 2);
    });

    test('没有 hasMore 时 replies-more 不发请求', () async {
      final _FakeGateway gateway = _FakeGateway(
        pages: const <ProviderCommentPage>[
          ProviderCommentPage(
            comments: <ProviderComment>[
              ProviderComment(id: 'c1', content: 'a', nickname: 'n', replyCount: 1),
            ],
          ),
        ],
      );
      gateway.repliesPage = ProviderRepliesPage(comments: <ProviderComment>[_comment('r1')]);
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');
      await dispatchCommentAction('comments:replies:c1', controller);

      await dispatchCommentAction('comments:replies-more:c1', controller);
      expect(gateway.replyPagesRequested, <int>[0]);
    });

    test('close 复位控制器并回报 closed（宿主负责收面板）', () async {
      final _FakeGateway gateway = _FakeGateway();
      final CommentController controller = CommentController(gateway: gateway);
      await controller.load(trackId: 't1');
      expect(controller.state.phase, CommentPhase.empty);

      expect(await dispatchCommentAction('comments:close', controller),
          CommentActionResult.closed);
      expect(controller.state.phase, CommentPhase.idle);
      expect(controller.trackId, '');
    });
  });
}
