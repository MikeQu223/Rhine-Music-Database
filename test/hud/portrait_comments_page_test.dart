// 竖屏歌曲评论页绘制器（lib/hud/portrait/portrait_pages_comments.dart）的命中与文案测试。
//
// 真值口径全部来自 Qt：
// - Qt/src/ResponsiveComments.cpp:19-39（来源行的四段拼接：来源名 / 塞壬三态 / 总条数）
// - :41-49（热门/最新 chip + 选中下划线 + 刷新）
// - :64-80（loading/idle 与 error/empty 两分支 + 重新加载）
// - :82-171（单条：头像、昵称、时间、正文截 6 行、♥、回复标签、展开标签、回复块状态串、行底分隔线）
// - :173-180（加载更多 / END OF COMMENTS）
// - Qt/src/ResponsiveHudLayout.cpp:186-189（页头下沿的 "COMMENT ARCHIVE / 评论档案"）
// - ResponseiveHudLayout.cpp:238-244（end = commentsPage(...)，maximum = max(0, end - contentBottom)）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_comments.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 宽度按字符数估算、折行按「整段一行」，只为断言文案与命中，不校验像素。
PortraitCanvas _canvas({double gridWidth = 393, double height = 800}) => PortraitCanvas(
  metrics: PortraitMetrics(
    width: (String value, double size, String weight) => value.length * size * .6,
    wrap: (String value, double limit, double size, String weight) => <String>[value],
    bounds: (String value, double size, String weight) =>
        PortraitGlyphBounds(width: value.length * size * .6, height: size),
  ),
  unit: 1,
  gridWidth: gridWidth,
  height: height,
  dark: true,
)..contentBottom = height - 144;

/// 折行按给定宽度真实切段（用于验证"正文截 6 行"与回复块高度）。
PortraitCanvas _wrappingCanvas({
  int chunk = 20,
  double height = 800,
  double gridWidth = 393,
}) => PortraitCanvas(
  metrics: PortraitMetrics(
    width: (String value, double size, String weight) => value.length * size * .6,
    wrap: (String value, double limit, double size, String weight) => <String>[
      for (int start = 0; start < value.length; start += chunk)
        value.substring(start, (start + chunk).clamp(0, value.length)),
    ],
    bounds: (String value, double size, String weight) =>
        PortraitGlyphBounds(width: value.length * size * .6, height: size),
  ),
  unit: 1,
  gridWidth: gridWidth,
  height: height,
  dark: true,
)..contentBottom = height - 144;

List<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toList();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command[0] == 'text') command[1]! as String,
];

List<List<Object?>> _ops(PortraitCanvas c, String op) =>
    c.commands.where((List<Object?> command) => command[0] == op).toList();

HudHit _hit(PortraitCanvas c, String action) =>
    c.hits.firstWhere((HudHit hit) => hit.action == action);

const PortraitCommentReply _reply = PortraitCommentReply(
  id: 'r1',
  nickname: '甲',
  content: '回复正文',
  replyTo: '乙',
);

PortraitCommentRow _row({
  String id = 'c1',
  String nickname = '听众',
  String content = '评论正文',
  String avatarKey = '',
  String timeLabel = '刚刚',
  String likedLabel = '3',
  int replyCount = 0,
  bool expanded = false,
  List<PortraitCommentReply> inlineReplies = const <PortraitCommentReply>[],
  List<PortraitCommentReply> replies = const <PortraitCommentReply>[],
  bool repliesExpanded = false,
  bool repliesHasMore = false,
  bool repliesLoading = false,
  String repliesError = '',
}) => PortraitCommentRow(
  id: id,
  nickname: nickname,
  content: content,
  avatarKey: avatarKey,
  timeLabel: timeLabel,
  likedLabel: likedLabel,
  replyCount: replyCount,
  expanded: expanded,
  inlineReplies: inlineReplies,
  replies: replies,
  repliesExpanded: repliesExpanded,
  repliesHasMore: repliesHasMore,
  repliesLoading: repliesLoading,
  repliesError: repliesError,
);

void main() {
  group('页头与来源行', () {
    test('画页头、副标题，且不画右上设置键；返回命中是关页', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'loading'),
      );

      final List<String> texts = _texts(c);
      expect(texts, contains('歌曲评论'));
      expect(texts, contains('COMMENT ARCHIVE / 评论档案'));
      expect(texts, contains('正在读取评论…'));

      final List<String> actions = _actions(c);
      expect(actions, contains('close-modal'), reason: '页头返回箭头');
      expect(actions, isNot(contains('settings')), reason: 'comments 页不画设置键');
    });

    test('宿主自画页头时不重复画页头（副标题仍画），且仍有排序/刷新命中', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'loading'),
        header: false,
      );
      expect(_texts(c), isNot(contains('歌曲评论')));
      // Qt 里 "COMMENT ARCHIVE" 与 c.header 是并列调用（ResponsiveHudLayout.cpp:187-188），
      // 宿主自画页头时这行仍然要出。
      expect(_texts(c), contains('COMMENT ARCHIVE / 评论档案'));
      final List<String> actions = _actions(c);
      expect(actions, contains('comments:sort:hot'));
      expect(actions, contains('comments:sort:new'));
      expect(actions, contains('comments:refresh'));
    });

    test('塞壬未匹配时来源行补 "未匹配到歌曲"；有 totalLabel 时再补条数', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(
          status: 'empty',
          providerId: 'siren',
          sourceName: '塞壬唱片',
          totalLabel: '0',
        ),
      );
      expect(_texts(c), contains('塞壬唱片 · 未匹配到歌曲'));

      final PortraitCanvas c2 = _canvas();
      paintPortraitCommentsPage(
        c2,
        model: const PortraitCommentsModel(
          status: 'ready',
          providerId: 'siren',
          sourceName: '塞壬唱片',
          sourceLabel: 'TRACK / 艺人',
          totalLabel: '12',
          items: <PortraitCommentRow>[PortraitCommentRow(
            id: 'c1',
            nickname: '听众',
            content: '评论正文',
          )],
        ),
      );
      expect(_texts(c2), contains('塞壬唱片 · 已匹配 TRACK / 艺人 · 12 条评论'));
    });

    test('非塞壬来源不追加匹配尾巴；totalLabel 为 "0" 时也不追加', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(
          status: 'loading',
          sourceName: '塞壬唱片',
          totalLabel: '0',
        ),
      );
      expect(_texts(c), contains('塞壬唱片'));
    });
  });

  group('排序 chip', () {
    test('热门选中时画琥珀下划线，最新不选中', () {
      final PortraitCanvas c = _canvas();
      final PortraitCommentsLayout layout = paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'loading', sort: 'hot'),
      );
      expect(layout.contentBottom, isA<double>());

      final List<List<Object?>> fills = _ops(c, 'fill');
      // 排序 chip 在 y = 158 + 26 = 184 处，下划线 y = 184 + 36 = 220。
      final bool underline = fills.any((List<Object?> fill) =>
          fill[1] is List<Object?> &&
          (fill[1]! as List<Object?>).length == 4 &&
          (fill[1]! as List<Object?>)[0] == 0.780 &&
          fill[3] == 220);
      expect(underline, isTrue, reason: '选中态在 chip 下沿画 3 单位琥珀条');
    });

    test('切换到最新：下划线跟到第二个 chip', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'loading', sort: 'new'),
      );
      final List<List<Object?>> fills = _ops(c, 'fill');
      final bool underline = fills.any((List<Object?> fill) =>
          fill[1] is List<Object?> &&
          (fill[1]! as List<Object?>)[0] == 0.780 &&
          fill[2] == 110.0 &&
          fill[3] == 220);
      expect(underline, isTrue);
    });
  });

  group('首屏状态', () {
    test('error 分支画状态串与重新加载按钮', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'error', message: '离线状态下无法读取评论'),
      );
      expect(_texts(c), contains('离线状态下无法读取评论'));
      expect(_actions(c), contains('comments:retry'));
    });

    test('空 message 时 error/empty 回落 "暂无评论"', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'empty'),
      );
      expect(_texts(c), contains('暂无评论'));
      expect(_actions(c), contains('comments:retry'));
    });

    test('loading 分支不画重新加载按钮', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'idle'),
      );
      expect(_texts(c), contains('正在读取评论…'));
      expect(_actions(c), isNot(contains('comments:retry')));
    });
  });

  group('单条评论', () {
    test('头像空槽画昵称首字；整条命中齐备', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[
            PortraitCommentRow(id: 'c1', nickname: '听众', content: '评论正文'),
          ],
        ),
      );
      expect(_texts(c), contains('听'), reason: '无头像时画昵称首字');
      expect(_texts(c), contains('♥ 0'));
      expect(_actions(c), isNot(contains('comments:expand:c1')), reason: '一行正文不需要展开');
      expect(_actions(c), isNot(contains('comments:replies:c1')), reason: 'replyCount 为 0');
    });

    test('有头像键时发 image 命令而不是画首字', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[
            PortraitCommentRow(
              id: 'c1',
              nickname: '听众',
              content: '评论正文',
              avatarKey: 'https://example.test/a.png',
            ),
          ],
        ),
      );
      final List<List<Object?>> images = _ops(c, 'image');
      expect(images.length, 1);
      expect(images.first[1], 'https://example.test/a.png');
      expect(_texts(c), isNot(contains('听')));
    });

    test('正文超 6 行：截 6 行并发展开命中', () {
      final PortraitCanvas c = _wrappingCanvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(content: '字' * 140)],
        ),
      );
      expect(_actions(c), contains('comments:expand:c1'));
      expect(_texts(c), contains('展开全文'));
      // 7 段（140/20），只画前 6 段。
      expect(_ops(c, 'text').length, greaterThan(6));
      final bool hasSeventh =
          _texts(c).any((String value) => value.startsWith('字' * 20) && value.length > 0);
      expect(hasSeventh, isTrue);
      expect(_texts(c).where((String v) => v.length == 20).length, 6, reason: '正文只画 6 行');
    });

    test('已展开时发"收起"并画全部行', () {
      final PortraitCanvas c = _wrappingCanvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(content: '字' * 140, expanded: true)],
        ),
      );
      expect(_actions(c), contains('comments:expand:c1'));
      expect(_texts(c), contains('收起'));
      expect(_texts(c).where((String v) => v.length == 20).length, 7, reason: '展开后画全部 7 行');
    });

    test('回复数 > 0 时画"N 条回复 ↓"并发热区', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[
            PortraitCommentRow(id: 'c1', nickname: '听众', content: '评论正文', replyCount: 3),
          ],
        ),
      );
      expect(_texts(c), contains('3 条回复 ↓'));
      expect(_actions(c), contains('comments:replies:c1'));
    });

    test('已展开回复时标签变"收起回复 ↑"', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[
            PortraitCommentRow(
              id: 'c1',
              nickname: '听众',
              content: '评论正文',
              replyCount: 3,
              repliesExpanded: true,
              replies: <PortraitCommentReply>[_reply],
            ),
          ],
        ),
      );
      expect(_texts(c), contains('收起回复 ↑'));
    });
  });

  group('回复块', () {
    test('内联预览：画 "昵称 回复 @被回复者：正文" 与"查看全部"热区', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[
            _row(replyCount: 2, inlineReplies: const <PortraitCommentReply>[_reply]),
          ],
        ),
      );
      expect(_texts(c), contains('甲 回复 @乙：回复正文'));
      expect(_texts(c), contains('查看全部 2 条回复 ↓'));
      expect(_actions(c), contains('comments:replies:c1'));
    });

    test('加载中：只画"正在加载回复…"且不发重试热区', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(repliesLoading: true)],
        ),
      );
      expect(_texts(c), contains('正在加载回复…'));
      final List<String> actions = _actions(c);
      expect(actions, isNot(contains('comments:replies:c1')));
      expect(actions, isNot(contains('comments:replies-more:c1')));
    });

    test('失败：画"回复加载失败，点击重试"并发热区', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(repliesError: '回复加载失败')],
        ),
      );
      expect(_texts(c), contains('回复加载失败，点击重试'));
      expect(_actions(c), contains('comments:replies:c1'));
    });

    test('展开后还有更多：画"查看更多回复 ↓"并发热区', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[
            _row(
              replyCount: 3,
              repliesExpanded: true,
              repliesHasMore: true,
              replies: const <PortraitCommentReply>[_reply],
            ),
          ],
        ),
      );
      expect(_texts(c), contains('查看更多回复 ↓'));
      expect(_actions(c), contains('comments:replies-more:c1'));
    });
  });

  group('翻页与滚动上界', () {
    test('hasMore 且未在加载：画"加载更多评论 ↓"按钮', () {
      final PortraitCanvas c = _canvas();
      final PortraitCommentsLayout layout = paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          hasMore: true,
          items: <PortraitCommentRow>[_row()],
        ),
      );
      expect(_texts(c), contains('加载更多评论 ↓'));
      expect(_actions(c), contains('comments:load-more'));
      expect(layout.maximumScroll, greaterThanOrEqualTo(0));
    });

    test('hasMore 且加载中：只画文字不给热区', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          hasMore: true,
          loadingMore: true,
          items: <PortraitCommentRow>[_row()],
        ),
      );
      expect(_texts(c), contains('正在加载更多…'));
      expect(_actions(c), isNot(contains('comments:load-more')));
    });

    test('到底但有内容：画 END OF COMMENTS', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row()],
        ),
      );
      expect(_texts(c), contains('END OF COMMENTS / 评论到底了'));
    });

    test('无内容时不画 END OF COMMENTS', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: const PortraitCommentsModel(status: 'empty', message: '暂无评论'),
      );
      expect(_texts(c), isNot(contains('END OF COMMENTS / 评论到底了')));
    });

    test('contentBottom 不含滚动偏移，maximumScroll 随视口收窄而增大', () {
      final PortraitCanvas tall = _canvas(height: 900);
      final PortraitCommentsLayout tallLayout = paintPortraitCommentsPage(
        tall,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(), _row(id: 'c2'), _row(id: 'c3')],
        ),
        scroll: 40,
      );
      final PortraitCanvas short = _canvas(height: 560);
      final PortraitCommentsLayout shortLayout = paintPortraitCommentsPage(
        short,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(), _row(id: 'c2'), _row(id: 'c3')],
        ),
        scroll: 40,
      );
      expect(tallLayout.contentBottom, shortLayout.contentBottom,
          reason: 'Qt 帧尾去掉滚动偏移，内容高度与视口高无关');
      expect(shortLayout.maximumScroll, greaterThan(tallLayout.maximumScroll));
      expect(tallLayout.maximumScroll, greaterThanOrEqualTo(0));
    });

    test('滚动后命中仍然可点（命中在裁剪区内不丢）', () {
      final PortraitCanvas c = _canvas();
      paintPortraitCommentsPage(
        c,
        model: PortraitCommentsModel(
          status: 'ready',
          hasMore: true,
          items: <PortraitCommentRow>[_row(), _row(id: 'c2')],
        ),
        scroll: 30,
      );
      final HudHit hit = _hit(c, 'comments:refresh');
      expect(hit.label, '刷新评论');
      expect(hit.fixed, isTrue);
    });
  });

  group('宽页适配', () {
    test('右缘按 gridWidth 反算：宽页上展开标签跟着右移', () {
      final PortraitCanvas narrow = _wrappingCanvas(gridWidth: 393);
      paintPortraitCommentsPage(
        narrow,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(content: '字' * 140)],
        ),
      );
      final PortraitCanvas wide = _wrappingCanvas(gridWidth: 586);
      paintPortraitCommentsPage(
        wide,
        model: PortraitCommentsModel(
          status: 'ready',
          items: <PortraitCommentRow>[_row(content: '字' * 140)],
        ),
      );
      final HudHit narrowHit = _hit(narrow, 'comments:expand:c1');
      final HudHit wideHit = _hit(wide, 'comments:expand:c1');
      expect(narrowHit.width, 68);
      expect(wideHit.width, 68);
      // 右缘恒离页右 20：宽页右下移 (586 - 393) 个单位。
      expect(narrowHit.x, 393 - 88);
      expect(wideHit.x, 586 - 88);
      expect(narrow.hits.every((HudHit h) => h.fixed), isTrue);
    });
  });
}
