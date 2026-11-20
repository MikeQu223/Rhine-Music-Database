// 评论领域态 → 竖屏评论页视图模型的映射契约（lib/basic/basic_comment_mapper.dart）。
//
// 这里只钉纯函数（不建 widget、不开画布）：映射规则的真值来自
// - Qt/src/ResponsiveComments.cpp:56-70（status 五值：idle/loading/ready/empty/error）
// - Qt/src/CommentsController.cpp:465（loaded 在 Qt 里叫 "ready"）
// - Qt/src/CommentsController.cpp:101-109（compactCount：<10000 原样、否则一位小数 + chop(".0") + " 万"）
// - Qt/src/CommentsController.cpp:664-666（items[*].likedLabel = compactCount(likedCount)）
// - Qt/src/ResponsiveComments.cpp:26（sourceName 空时回落 providerName）

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_comment_mapper.dart';
import 'package:rhine_music_database/domain/comments/comment_controller.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_comments.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';

/// 一条用于行映射的评论（字段都填满，便于逐字段核对）。
ProviderComment _comment({
  String id = 'c1',
  String content = '好听',
  String nickname = '听众甲',
  String avatarUrl = 'https://example.test/a.jpg',
  String timeLabel = '3 天前',
  int likedCount = 0,
  int replyCount = 0,
  String replyTo = '',
  List<ProviderComment> inlineReplies = const <ProviderComment>[],
  bool inlineMore = false,
}) {
  return ProviderComment(
    id: id,
    content: content,
    nickname: nickname,
    avatarUrl: avatarUrl,
    timeLabel: timeLabel,
    likedCount: likedCount,
    replyCount: replyCount,
    replyTo: replyTo,
    inlineReplies: inlineReplies,
    inlineMore: inlineMore,
  );
}

void main() {
  group('status：CommentPhase 全五种的映射', () {
    final Map<CommentPhase, String> cases = <CommentPhase, String>{
      CommentPhase.idle: 'idle',
      CommentPhase.loading: 'loading',
      CommentPhase.loaded: 'ready',
      CommentPhase.empty: 'empty',
      CommentPhase.failed: 'error',
    };
    for (final MapEntry<CommentPhase, String> entry in cases.entries) {
      test('${entry.key.name} → ${entry.value}', () {
        final PortraitCommentsModel model =
            portraitCommentsModelOf(CommentState(phase: entry.key));
        expect(model.status, entry.value, reason: '阶段 ${entry.key.name} 的 status 串');
      });
    }
  });

  group('sort key 与 message 原样透传', () {
    test('sort 取 ProviderCommentSort.id（hot / new）', () {
      expect(
        portraitCommentsModelOf(const CommentState(sort: ProviderCommentSort.hot)).sort,
        'hot',
      );
      expect(
        portraitCommentsModelOf(const CommentState(sort: ProviderCommentSort.newest)).sort,
        'new',
      );
    });

    test('message 等于 state.status；total<=0 时 totalLabel 为空串', () {
      final PortraitCommentsModel model = portraitCommentsModelOf(
        const CommentState(phase: CommentPhase.loaded, status: '找到 3 条评论'),
      );
      expect(model.message, '找到 3 条评论');
      expect(model.totalLabel, '', reason: 'total 缺省 0 ⇒ 不追加 " · N 条评论"');
    });
  });

  group('totalLabel：compactCount 的 0 / <10000 / >=10000 三档', () {
    test('total = 0 → 空串', () {
      expect(portraitCommentsModelOf(const CommentState(total: 0)).totalLabel, '');
    });

    test('total = 7 → 原样十进制（<10000）', () {
      expect(portraitCommentsModelOf(const CommentState(total: 7)).totalLabel, '7');
    });

    test('total = 9999 → 不进"万"档', () {
      expect(portraitCommentsModelOf(const CommentState(total: 9999)).totalLabel, '9999');
    });

    test('total = 10000 → "1 万"（chop 掉 ".0"，不是 "1.0 万"）', () {
      expect(
        portraitCommentsModelOf(const CommentState(total: 10000)).totalLabel,
        '1 万',
      );
      expect(basicCommentCompactCount(10000), '1 万');
    });

    test('total = 12345 → "1.2 万"（一位小数）', () {
      expect(
        portraitCommentsModelOf(const CommentState(total: 12345)).totalLabel,
        '1.2 万',
      );
    });

    test('total = 123456 → "12.3 万"', () {
      expect(basicCommentCompactCount(123456), '12.3 万');
    });

    test('负值/缺省都落到空串（total<=0）', () {
      expect(portraitCommentsModelOf(const CommentState(total: -3)).totalLabel, '');
    });
  });

  group('行映射：expanded / replies 组合', () {
    final ProviderComment comment = _comment(likedCount: 12345, replyCount: 4);

    test('avatarKey=avatarUrl、timeLabel/likedLabel/replyCount 照抄', () {
      final PortraitCommentRow row = portraitCommentRowOf(comment, expanded: false);
      expect(row.id, 'c1');
      expect(row.nickname, '听众甲');
      expect(row.content, '好听');
      expect(row.avatarKey, 'https://example.test/a.jpg');
      expect(row.timeLabel, '3 天前');
      expect(row.likedLabel, '1.2 万', reason: 'likedLabel = compactCount(likedCount)');
      expect(row.replyCount, 4);
      expect(row.expanded, isFalse);
    });

    test('无回复态时：replies 空、hasMore false、不 loading、无 error', () {
      final PortraitCommentRow row = portraitCommentRowOf(comment, expanded: false);
      expect(row.replies, isEmpty);
      expect(row.repliesHasMore, isFalse);
      expect(row.repliesLoading, isFalse);
      expect(row.repliesError, '');
      expect(row.repliesExpanded, isFalse);
    });

    test('expanded=true 原样进 row（不推断折行）', () {
      expect(portraitCommentRowOf(comment, expanded: true).expanded, isTrue);
    });

    test('replies 已加载：列表来自 replies.comments、hasMore 取 replies.hasMore', () {
      final CommentRepliesState replies = CommentRepliesState(
        phase: CommentPhase.loaded,
        status: '找到 2 条回复',
        comments: <ProviderComment>[
          _comment(id: 'r1', nickname: '乙', content: '同感', replyTo: '听众甲'),
          _comment(id: 'r2', nickname: '丙', content: '+1'),
        ],
        hasMore: true,
      );
      final PortraitCommentRow row = portraitCommentRowOf(comment, expanded: true, replies: replies);
      expect(row.replies.length, 2);
      expect(row.replies.first.id, 'r1');
      expect(row.replies.first.nickname, '乙');
      expect(row.replies.first.content, '同感');
      expect(row.replies.first.replyTo, '听众甲', reason: 'replyTo 直接抄 ProviderComment.replyTo');
      expect(row.replies.last.replyTo, '', reason: '顶层回复的 replyTo 为空');
      expect(row.repliesHasMore, isTrue);
      expect(row.repliesLoading, isFalse);
      expect(row.repliesError, '');
    });

    test('行函数只做透传：repliesExpanded/Loading/Error 原样落行', () {
      final PortraitCommentRow row = portraitCommentRowOf(
        comment,
        expanded: false,
        repliesExpanded: true,
        repliesLoading: true,
        repliesError: '网络不可用',
      );
      expect(row.repliesExpanded, isTrue);
      expect(row.repliesLoading, isTrue);
      expect(row.repliesError, '网络不可用');
      expect(row.replies, isEmpty);
    });

    test('模板映射把领域态折成行参数：loading ⇒ repliesLoading', () {
      final CommentState state = CommentState(
        phase: CommentPhase.loaded,
        comments: <ProviderComment>[_comment(id: 'c1')],
        replyState: <String, CommentRepliesState>{
          'c1': const CommentRepliesState(
            phase: CommentPhase.loading,
            status: '正在读取回复…',
          ),
        },
      );
      final PortraitCommentsModel model = portraitCommentsModelOf(state);
      final PortraitCommentRow row = model.items.single;
      expect(row.repliesLoading, isTrue);
      expect(row.repliesError, '', reason: 'loading 不是失败，不画红字');
      expect(row.replies, isEmpty, reason: '加载中还没有回复');
    });

    test('模板映射把领域态折成行参数：failed ⇒ repliesError 取领域 status', () {
      final CommentState state = CommentState(
        phase: CommentPhase.loaded,
        comments: <ProviderComment>[_comment(id: 'c1')],
        replyState: <String, CommentRepliesState>{
          'c1': const CommentRepliesState(
            phase: CommentPhase.failed,
            status: '回复加载失败，点击重试',
          ),
        },
      );
      final PortraitCommentsModel model = portraitCommentsModelOf(state);
      expect(model.items.single.repliesError, '回复加载失败，点击重试');
    });

    test('模板映射把领域态折成行参数：loaded ⇒ 不 loading / 无 error / expanded 跟随', () {
      final CommentState state = CommentState(
        phase: CommentPhase.loaded,
        comments: <ProviderComment>[_comment(id: 'c1')],
        replyState: <String, CommentRepliesState>{
          'c1': const CommentRepliesState(
            phase: CommentPhase.loaded,
            comments: <ProviderComment>[],
            expanded: false,
          ),
        },
      );
      final PortraitCommentRow row = portraitCommentsModelOf(state).items.single;
      expect(row.repliesExpanded, isFalse, reason: 'CommentRepliesState.expanded=false 被透传');
      expect(row.repliesLoading, isFalse);
      expect(row.repliesError, '');
    });
  });

  group('inlineReplies 数量与 replyTo', () {
    test('inlineReplies 逐条映射成 PortraitCommentReply（数量不变）', () {
      final ProviderComment parent = _comment(
        id: 'c9',
        replyCount: 5,
        inlineReplies: <ProviderComment>[
          _comment(id: 'i1', nickname: '丁', content: '好听', replyTo: '听众甲'),
          _comment(id: 'i2', nickname: '戊', content: '确实'),
        ],
      );
      final PortraitCommentRow row = portraitCommentRowOf(parent, expanded: false);
      expect(row.inlineReplies.length, 2);
      expect(row.inlineReplies[0].id, 'i1');
      expect(row.inlineReplies[0].displayText, '丁 回复 @听众甲：好听');
      expect(row.inlineReplies[1].id, 'i2');
      expect(row.inlineReplies[1].displayText, '戊：确实', reason: 'replyTo 为空时不加"回复 @"前缀');
    });

    test('没有内联回复时 inlineReplies 为空列表（不是 null）', () {
      expect(portraitCommentRowOf(_comment(), expanded: false).inlineReplies, isEmpty);
    });
  });

  group('整页映射：items / sourceName 回落 / 回复态串联', () {
    test('items 条数与 expandedIds / replyState 对齐', () {
      final CommentState state = CommentState(
        phase: CommentPhase.loaded,
        total: 12,
        comments: <ProviderComment>[_comment(id: 'a'), _comment(id: 'b')],
        expandedIds: const <String>{'b'},
        replyState: <String, CommentRepliesState>{
          'a': CommentRepliesState(
            phase: CommentPhase.loaded,
            comments: <ProviderComment>[_comment(id: 'a-r1')],
          ),
        },
      );
      final PortraitCommentsModel model = portraitCommentsModelOf(state);
      expect(model.items.length, 2);
      expect(model.items[0].id, 'a');
      expect(model.items[0].expanded, isFalse);
      expect(model.items[0].replies.length, 1);
      expect(model.items[0].repliesExpanded, isTrue, reason: 'CommentRepliesState.expanded 缺省 true');
      expect(model.items[1].id, 'b');
      expect(model.items[1].expanded, isTrue, reason: 'b 在 expandedIds 里');
      expect(model.items[1].replies, isEmpty);
      expect(model.totalLabel, '12');
    });

    test('sourceName 为空时回落 providerName；显式 sourceName 优先', () {
      final PortraitCommentsModel fallback = portraitCommentsModelOf(
        const CommentState(),
        providerName: '塞壬唱片',
        providerId: 'siren',
      );
      expect(fallback.sourceName, '塞壬唱片');

      final PortraitCommentsModel explicit = portraitCommentsModelOf(
        const CommentState(),
        sourceName: '专辑评论',
        providerName: '塞壬唱片',
        sourceLabel: '归舟',
        providerId: 'siren',
      );
      expect(explicit.sourceName, '专辑评论');
      expect(explicit.sourceLabel, '归舟');
      expect(explicit.providerId, 'siren');
      expect(explicit.hasMore, isFalse);
      expect(explicit.items, isEmpty);
    });

    test('hasMore 直取领域态', () {
      expect(portraitCommentsModelOf(const CommentState(hasMore: true)).hasMore, isTrue);
    });
  });
}
