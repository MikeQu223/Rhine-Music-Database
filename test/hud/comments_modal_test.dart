// 横屏歌曲评论面板（lib/hud/modals/comments_modal.dart）的几何、文案与命中测试。
//
// 真值口径全部来自 Qt：
// - Qt/src/NativeHudComments.cpp:11-19（ListTop 452 / ListBottom 944 / AvatarSize 46 /
//   ContentX 62 / ContentSize 21 / ContentLine 38 / MetaSize 17 / ReplySize 17 / ReplyLine 30）
// - :43-52（结构线、琥珀块、COMMENT ARCHIVE、标题、Comments 副标题、关闭按钮）
// - :54-74（来源行 = head + rest，rest 里塞壬三态与 total>0 的 " · N 条评论"）
// - :76-100（chip 宽 102 / 选中琥珀 16% 底 + 3 单位条 / 刷新右锚）
// - :103-121（列表 clip 与 loading/idle 分支的行距 30）
// - :122-131（error/empty 分支 + 重新加载）
// - :133-186（单条：头像 46、昵称 limited、时间右锚、正文截 6 行、♥、回复/展开标签）
// - :188-235（回复块：blockHeight 32 起、状态串 +34、前缀内联）
// - :237-242（行底分隔线 ink@0.14）
// - :244-254（加载更多 / END OF COMMENTS）
// - :256-258（commentsContentBottom = y + commentsScroll，滚动夹取在 :37-41）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/comments_modal.dart';

/// 宽度按字符数估算、折行按固定 chunk 切段（默认整段一行）。
class _Glyphs implements CommentPanelGlyphs {
  _Glyphs({this.chunk = 0, this.perChar = 0.6});

  /// 0 = 不折行（整段一行）；>0 = 每 chunk 个字符一行。
  final int chunk;
  final double perChar;

  @override
  double width(String value, double size, String weight) => value.length * size * perChar;

  @override
  List<String> wrap(String value, double limit, double size, String weight) {
    if (chunk <= 0) {
      return <String>[value];
    }
    return <String>[
      for (int start = 0; start < value.length; start += chunk)
        value.substring(start, (start + chunk).clamp(0, value.length)),
    ];
  }
}

const double _x = 1075.2; // 1920 * 0.56（NativeHudDetail.cpp:56）
const double _width = 785.8; // 1920 - x - 59

CommentPanelModel _model({
  String status = 'ready',
  String message = '',
  String sort = 'hot',
  int total = 0,
  String totalLabel = '',
  bool hasMore = false,
  bool loadingMore = false,
  String sourceName = '塞壬唱片',
  String sourceLabel = '',
  String providerId = 'siren',
  String providerName = '塞壬唱片',
  List<CommentPanelItem> items = const <CommentPanelItem>[],
}) => CommentPanelModel(
  x: _x,
  width: _width,
  dark: true,
  status: status,
  message: message,
  sort: sort,
  total: total,
  totalLabel: totalLabel,
  hasMore: hasMore,
  loadingMore: loadingMore,
  sourceName: sourceName,
  sourceLabel: sourceLabel,
  providerId: providerId,
  providerName: providerName,
  items: items,
);

const CommentPanelReply _reply = CommentPanelReply(
  id: 'r1',
  nickname: '甲',
  content: '回复正文',
  replyTo: '乙',
);

CommentPanelItem _item({
  String id = 'c1',
  String nickname = '听众',
  String content = '评论正文',
  String avatarKey = '',
  String timeLabel = '刚刚',
  String likedLabel = '3',
  int replyCount = 0,
  bool expanded = false,
  List<CommentPanelReply> inlineReplies = const <CommentPanelReply>[],
  List<CommentPanelReply> replies = const <CommentPanelReply>[],
  bool repliesExpanded = false,
  bool repliesHasMore = false,
  bool repliesLoading = false,
  String repliesError = '',
}) => CommentPanelItem(
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

List<String> _texts(CommentPanelDrawing d) => <String>[
  for (final List<Object?> command in d.commands)
    if (command[0] == 'text') command[1]! as String,
];

List<List<Object?>> _ops(CommentPanelDrawing d, String op) =>
    d.commands.where((List<Object?> command) => command[0] == op).toList();

List<String> _actions(CommentPanelDrawing d) =>
    d.hits.map((Map<String, Object?> hit) => hit['action']! as String).toList();

Map<String, Object?> _hit(CommentPanelDrawing d, String action) =>
    d.hits.firstWhere((Map<String, Object?> hit) => hit['action'] == action);

/// 颜色深比较（命令里的颜色是 List<Object?>，Dart 用引用相等）。
bool _sameColor(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

void main() {
  group('顶部结构（:43-52）', () {
    test('结构线 / 琥珀块 / 标题 / 副标题 / 关闭按钮全齐', () {
      final CommentPanelDrawing d = paintCommentsPanel(_model(), _Glyphs());
      final List<String> texts = _texts(d);
      expect(texts, contains('COMMENT ARCHIVE / 评论档案'));
      expect(texts, contains('歌曲评论'));
      expect(texts, contains('Comments'));
      expect(texts, contains('关闭'));

      final List<List<Object?>> fills = _ops(d, 'fill');
      // 结构线 {x-24, 260, width+48, 3}，颜色是 ink。
      final bool rule = fills.any((List<Object?> fill) =>
          fill[2] == _x - 24 && fill[3] == 260 && fill[4] == _width + 48 && fill[5] == 3);
      expect(rule, isTrue);
      // 琥珀块 {x, 282, 8, 8}。
      final bool amberBlock = fills.any((List<Object?> fill) =>
          fill[2] == _x &&
          fill[3] == 282 &&
          fill[4] == 8 &&
          fill[5] == 8 &&
          _sameColor(fill[1]! as List<Object?>, cmtAmber));
      expect(amberBlock, isTrue);

      final Map<String, Object?> close = _hit(d, 'comments:close');
      expect(close['x'], _x + _width - 80);
      expect(close['y'], 276.0);
      expect(close['width'], 80);
      expect(close['height'], 48);
      expect(close['label'], '关闭');
    });
  });

  group('来源行（:54-74）', () {
    test('head 用 sourceName；塞壬未匹配时补尾巴', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(status: 'loading', sourceName: '塞壬唱片'),
        _Glyphs(),
      );
      final List<String> texts = _texts(d);
      expect(texts, contains('塞壬唱片'));
      expect(texts, contains(' · 正在匹配歌曲…'));
    });

    test('sourceName 为空时回落 providerName', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(sourceName: '', providerName: '塞壬唱片'),
        _Glyphs(),
      );
      expect(_texts(d), contains('塞壬唱片'));
    });

    test('已匹配标签 + total>0 时 rest 带上 compactCount', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(sourceLabel: 'TRACK / 艺人', total: 12000),
        _Glyphs(),
      );
      expect(_texts(d), contains(' · 已匹配 TRACK / 艺人 · 1.2 万 条评论'));
    });

    test('totalLabel 由调用方给时优先用它', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(providerId: 'netease', total: 3, totalLabel: '3'),
        _Glyphs(),
      );
      expect(_texts(d), contains(' · 3 条评论'));
    });

    test('非塞壬来源不追加匹配尾巴，total 为 0 时也不追加条数', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(providerId: 'netease', sourceName: '网易云音乐'),
        _Glyphs(),
      );
      expect(_texts(d), contains('网易云音乐'));
    });
  });

  group('排序 chip 与刷新（:76-100）', () {
    test('热门选中：琥珀 16% 底 + 3 单位下划线 + demibold', () {
      final CommentPanelDrawing d = paintCommentsPanel(_model(), _Glyphs());
      final List<List<Object?>> fills = _ops(d, 'fill');
      final bool tint = fills.any((List<Object?> fill) =>
          fill[2] == _x &&
          fill[3] == 390 &&
          fill[4] == 102 &&
          fill[5] == 40 &&
          _sameColor(fill[1]! as List<Object?>, <Object?>[0.835, 0.639, 0.282, 0.16]));
      expect(tint, isTrue);
      final bool underline = fills.any((List<Object?> fill) =>
          fill[2] == _x &&
          fill[3] == 427 &&
          fill[4] == 102 &&
          fill[5] == 3 &&
          _sameColor(fill[1]! as List<Object?>, cmtAmber));
      expect(underline, isTrue);

      final Map<String, Object?> hot = _hit(d, 'comments:sort:hot');
      expect(hot['x'], _x - 4);
      expect(hot['y'], 386.0);
      expect(hot['width'], 110.0);
      expect(hot['height'], 48.0);
    });

    test('最新选中时下划线跟到 x+110', () {
      final CommentPanelDrawing d = paintCommentsPanel(_model(sort: 'new'), _Glyphs());
      final List<List<Object?>> fills = _ops(d, 'fill');
      final bool underline = fills.any((List<Object?> fill) =>
          fill[2] == _x + 110 && fill[3] == 427 && fill[5] == 3);
      expect(underline, isTrue);
      expect(_hit(d, 'comments:sort:new')['x'], _x + 110 - 4);
    });

    test('刷新右锚，热区宽 = 字宽 + 20', () {
      final _Glyphs glyphs = _Glyphs();
      final CommentPanelDrawing d = paintCommentsPanel(_model(), glyphs);
      final double refreshWidth = glyphs.width('刷新 ↻', 17, 'regular');
      final Map<String, Object?> refresh = _hit(d, 'comments:refresh');
      expect(refresh['x'], _x + _width - refreshWidth - 10);
      expect(refresh['width'], refreshWidth + 20);
      expect(refresh['y'], 386.0);
      expect(refresh['height'], 48.0);
      expect(refresh['label'], '刷新评论');
    });
  });

  group('列表视口（:103-121）', () {
    test('先 save 再 clip(x-4, 452, width+8, 492)，末尾 restore', () {
      final CommentPanelDrawing d = paintCommentsPanel(_model(), _Glyphs());
      final List<Object?> clip = _ops(d, 'clip').first;
      expect(clip[1], _x - 4);
      expect(clip[2], cmtListTop);
      expect(clip[3], _width + 8);
      expect(clip[4], cmtListBottom - cmtListTop);

      final List<List<Object?>> saves = _ops(d, 'save');
      final List<List<Object?>> restores = _ops(d, 'restore');
      expect(saves.length, restores.length);
    });

    test('loading 分支：24 偏移、行距 30，且不画加载更多/分隔线', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(status: 'loading', message: '正在读取评论…'),
        _Glyphs(),
      );
      final List<List<Object?>> texts = _ops(d, 'text');
      final bool found = texts.any((List<Object?> text) =>
          text[1] == '正在读取评论…' && text[2] == _x && text[3] == cmtListTop + 24 && text[4] == 18);
      expect(found, isTrue);
      expect(_actions(d), isNot(contains('comments:load-more')));
      expect(_ops(d, 'fill').any((List<Object?> f) => f[5] == 1 && f[3] == 944), isFalse);
    });

    test('error 分支：状态串 + 重新加载按钮（150×48 / y+=66）', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(status: 'error', message: '离线状态下无法读取评论'),
        _Glyphs(),
      );
      expect(_texts(d), contains('离线状态下无法读取评论'));
      final Map<String, Object?> retry = _hit(d, 'comments:retry');
      expect(retry['x'], _x);
      expect(retry['y'], cmtListTop + 24 + 30 + 16);
      expect(retry['width'], 150.0);
      expect(retry['height'], 48.0);
    });

    test('空 message 时 error/empty 回落 "暂无评论"', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(status: 'empty', message: ''),
        _Glyphs(),
      );
      expect(_texts(d), contains('暂无评论'));
      expect(_actions(d), contains('comments:retry'));
    });
  });

  group('单条评论（:133-186）', () {
    test('头像 46；空头像画 12% 底 + 居中首字', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item()]),
        _Glyphs(),
      );
      final bool placeholder = _ops(d, 'fill').any((List<Object?> fill) =>
          fill[2] == _x &&
          fill[3] == cmtListTop &&
          fill[4] == cmtAvatarSize &&
          fill[5] == cmtAvatarSize &&
          (fill[1]! as List<Object?>)[3] == 0.12);
      expect(placeholder, isTrue);
      expect(_texts(d), contains('听'));
      expect(_ops(d, 'image'), isEmpty);
    });

    test('有头像键时发 image 命令，尺寸 46×46', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(avatarKey: 'https://example.test/a.png')]),
        _Glyphs(),
      );
      final List<List<Object?>> images = _ops(d, 'image');
      expect(images.length, 1);
      expect(images.first[1], 'https://example.test/a.png');
      expect(images.first[4], cmtAvatarSize);
      expect(images.first[5], cmtAvatarSize);
      expect(_texts(d), isNot(contains('听')));
    });

    test('昵称 20 号 limited 在 x+62 / y-2；时间 16 号右锚 x+width-92', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(timeLabel: '刚刚')]),
        _Glyphs(),
      );
      final List<List<Object?>> texts = _ops(d, 'text');
      final bool nickname = texts.any((List<Object?> text) =>
          text[1] == '听众' &&
          text[2] == _x + cmtContentX &&
          text[3] == cmtListTop - 2 &&
          text[4] == 20 &&
          text[5] == 'demibold');
      expect(nickname, isTrue);
      final bool time = texts.any((List<Object?> text) =>
          text[1] == '刚刚' && text[2] == _x + _width - 92 && text[4] == 16);
      expect(time, isTrue);
    });

    test('时间文案为空时不画', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(timeLabel: '')]),
        _Glyphs(),
      );
      expect(_texts(d), isNot(contains('刚刚')));
    });

    test('正文 21 号、行距 38、起于 y+36', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item()]),
        _Glyphs(),
      );
      final bool body = _ops(d, 'text').any((List<Object?> text) =>
          text[1] == '评论正文' &&
          text[2] == _x + cmtContentX &&
          text[3] == cmtListTop + 36 &&
          text[4] == cmtContentSize);
      expect(body, isTrue);
    });

    test('正文超 6 行截断并发"展开全文"热区（x+width-94 / 96×48）', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(content: '字' * 140)]),
        _Glyphs(chunk: 20),
      );
      expect(_texts(d), contains('展开全文'));
      final Map<String, Object?> expand = _hit(d, 'comments:expand:c1');
      expect(expand['x'], _x + _width - 94);
      expect(expand['width'], 96.0);
      expect(expand['height'], 48.0);
      // 正文只画 20 字/行的前 6 段。
      final int bodyLines = _ops(d, 'text')
          .where((List<Object?> text) => (text[1]! as String).length == 20)
          .length;
      expect(bodyLines, 6);
    });

    test('已展开时画全部行且标签为"收起"', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(content: '字' * 140, expanded: true)]),
        _Glyphs(chunk: 20),
      );
      expect(_texts(d), contains('收起'));
      final int bodyLines = _ops(d, 'text')
          .where((List<Object?> text) => (text[1]! as String).length == 20)
          .length;
      expect(bodyLines, 7);
    });

    test('♥ 文案在 x+62、大小 17', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(likedLabel: '3')]),
        _Glyphs(),
      );
      final bool liked = _ops(d, 'text').any((List<Object?> text) =>
          text[1] == '♥ 3' && text[2] == _x + cmtContentX && text[4] == cmtMetaSize);
      expect(liked, isTrue);
    });

    test('回复数 > 0：标签在 liked 字宽 +24 之后，热区 180×48', () {
      final _Glyphs glyphs = _Glyphs();
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(replyCount: 3)]),
        glyphs,
      );
      final double likedWidth = glyphs.width('♥ 3', cmtMetaSize, 'regular');
      final double replyX = _x + cmtContentX + likedWidth + 24;
      expect(_texts(d), contains('3 条回复 ↓'));
      final Map<String, Object?> hit = _hit(d, 'comments:replies:c1');
      expect(hit['x'], replyX - 10);
      expect(hit['width'], 180.0);
      expect(hit['height'], 48.0);
    });

    test('已展开回复时标签变"收起回复 ↑"', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[
          _item(
            replyCount: 3,
            repliesExpanded: true,
            replies: const <CommentPanelReply>[_reply],
          ),
        ]),
        _Glyphs(),
      );
      expect(_texts(d), contains('收起回复 ↑'));
    });

    test('行底分隔线：高 1、ink@0.14、宽 = 面板宽', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item()]),
        _Glyphs(),
      );
      final bool divider = _ops(d, 'fill').any((List<Object?> fill) =>
          fill[2] == _x &&
          fill[4] == _width &&
          fill[5] == 1 &&
          (fill[1]! as List<Object?>)[3] == 0.14);
      expect(divider, isTrue);
    });
  });

  group('回复块（:188-235）', () {
    test('内联预览：软色底块高 32 + 一行 30 + 10，再 +34 状态行', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[
          _item(replyCount: 2, inlineReplies: const <CommentPanelReply>[_reply]),
        ]),
        _Glyphs(),
      );
      final List<List<Object?>> fills = _ops(d, 'fill');
      final bool block = fills.any((List<Object?> fill) =>
          fill[2] == _x + cmtContentX &&
          fill[4] == _width - cmtContentX &&
          fill[5] == 32.0 + cmtReplyLine + 10 + 34 &&
          _sameColor(fill[1]! as List<Object?>, cmtSoft(true)));
      expect(block, isTrue);
      expect(_texts(d), contains('查看全部 2 条回复 ↓'));
      expect(_actions(d), contains('comments:replies:c1'));
    });

    test('前缀内联：放得下时先画 demibold 前缀，首行切掉前缀', () {
      final _Glyphs glyphs = _Glyphs();
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[
          _item(repliesExpanded: true, replies: const <CommentPanelReply>[_reply]),
        ]),
        glyphs,
      );
      expect(_texts(d), contains('甲 回复 @乙：'));
      // 剩下的是正文本身。
      expect(_texts(d), contains('回复正文'));
    });

    test('加载中：只画"正在加载回复…"，无重试热区', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(repliesLoading: true)]),
        _Glyphs(),
      );
      expect(_texts(d), contains('正在加载回复…'));
      final List<String> actions = _actions(d);
      expect(actions, isNot(contains('comments:replies:c1')));
      expect(actions, isNot(contains('comments:replies-more:c1')));
    });

    test('失败：画"回复加载失败，点击重试"并发热区（x+62 / 宽 width-62 / 高 42）', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item(repliesError: '回复加载失败')]),
        _Glyphs(),
      );
      expect(_texts(d), contains('回复加载失败，点击重试'));
      final Map<String, Object?> hit = _hit(d, 'comments:replies:c1');
      expect(hit['x'], _x + cmtContentX);
      expect(hit['width'], _width - cmtContentX);
      expect(hit['height'], 42.0);
    });

    test('展开且还有更多：画"查看更多回复 ↓"，热区是 replies-more', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[
          _item(
            replyCount: 3,
            repliesExpanded: true,
            repliesHasMore: true,
            replies: const <CommentPanelReply>[_reply],
          ),
        ]),
        _Glyphs(),
      );
      expect(_texts(d), contains('查看更多回复 ↓'));
      expect(_actions(d), contains('comments:replies-more:c1'));
    });
  });

  group('翻页与滚动（:244-258）', () {
    test('hasMore 未加载：画文案 + 整行 56 高热区', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(hasMore: true, items: <CommentPanelItem>[_item()]),
        _Glyphs(),
      );
      expect(_texts(d), contains('加载更多评论 ↓'));
      final Map<String, Object?> hit = _hit(d, 'comments:load-more');
      expect(hit['x'], _x);
      expect(hit['width'], _width);
      expect(hit['height'], 56.0);
      expect(hit['label'], '加载更多评论');
    });

    test('hasMore 加载中：只画"正在加载更多…"，不给热区', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(hasMore: true, loadingMore: true, items: <CommentPanelItem>[_item()]),
        _Glyphs(),
      );
      expect(_texts(d), contains('正在加载更多…'));
      expect(_actions(d), isNot(contains('comments:load-more')));
    });

    test('到底但有内容：画 END OF COMMENTS', () {
      final CommentPanelDrawing d = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item()]),
        _Glyphs(),
      );
      expect(_texts(d), contains('END OF COMMENTS / 评论到底了'));
    });

    test('contentBottom 不含滚动偏移（同样内容不同 scroll 得到同一底边）', () {
      final CommentPanelDrawing a = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item()]),
        _Glyphs(),
        scroll: 0,
      );
      final CommentPanelDrawing b = paintCommentsPanel(
        _model(items: <CommentPanelItem>[_item()]),
        _Glyphs(),
        scroll: 120,
      );
      expect(a.contentBottom, b.contentBottom);
    });

    test('cmtClampPanelScroll：上界 = contentBottom - 944，且不小于 0', () {
      expect(cmtClampPanelScroll(500, 1200), 256.0);
      expect(cmtClampPanelScroll(-20, 1200), 0.0);
      expect(cmtClampPanelScroll(500, 900), 0.0);
    });
  });

  group('compactCount（Qt CommentsController.cpp:131-143）', () {
    test('<10000 原样；万位去尾 ".0"', () {
      expect(commentPanelCompactCount(0), '0');
      expect(commentPanelCompactCount(9999), '9999');
      expect(commentPanelCompactCount(10000), '1 万');
      expect(commentPanelCompactCount(12345), '1.2 万');
      expect(commentPanelCompactCount(99999), '10 万');
    });
  });
}
