/// 播放队列的生产帧接线（`BasicHudFrame.build` 的 `modal == 'queue'`）。
///
/// 两套版面共用同一份动作词表（Qt/src/NativeHudController.cpp 的 player 分派）：
/// `player:queue:<i>` / `player:remove:<i>` / `player:clear` /
/// `player:mode:<off|all|one|shuffle>` / `mobile:queue-modes` / `close-modal`。
///
/// 竖屏走 `paintPortraitShell` + `paintPortraitQueuePage`
/// （Qt ResponsiveHudPages.cpp:468-533）；横屏走共享 `ModalShell`
/// （Qt NativeHudModal.cpp:163-186 的 `modal == "player"`）+ `renderQueueModal`
/// （Qt PlaybackQueueCard.cpp）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/modals/queue_modal.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

SirenSong _song(String id, String title, {String artist = '塞壬唱片'}) => SirenSong(
      id: id,
      title: title,
      artist: artist,
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

List<SirenSong> _queue() => <SirenSong>[
      _song('s1', '第一首'),
      _song('s2', '第二首'),
      _song('s3', '第三首'),
    ];

/// 带队列的三首曲目库：`queueIndex = 1` 让「当前行」与首行可区分。
BasicViewState _playlist({int queueIndex = 1, String queueMode = 'all'}) {
  final List<SirenSong> queue = _queue();
  return BasicViewState(
    phase: BasicPhase.library,
    songs: queue,
    catalogLoaded: true,
    dark: true,
    queue: queue,
    queueIndex: queueIndex,
    queueMode: queueMode,
    playing: queueIndex >= 0,
    playingTrack: queueIndex < 0 ? null : queue[queueIndex],
    playerStatus: queueIndex < 0 ? '队列为空' : '正在播放：第二首',
  );
}

Iterable<String> _actions(BasicHudFrame frame) =>
    frame.hits.map((HudHit hit) => hit.action);

/// 文本命令的形状是 `['text', value, x, y, size, weight, tracking, color]`。
Iterable<String> _texts(BasicHudFrame frame) => <String>[
      for (final List<Object?> command in frame.commands)
        if (command.isNotEmpty && command.first == 'text') command[1]! as String,
    ];

BasicHudFrame _build({
  required bool portrait,
  String modal = 'queue',
  int queueOffset = 0,
  bool queueModesExpanded = false,
  double? queueScroll,
  String queueMode = 'all',
  int queueIndex = 1,
}) {
  return BasicHudFrame.build(
    state: _playlist(queueIndex: queueIndex, queueMode: queueMode),
    ports: _ports(),
    width: portrait ? 1080 : 1920,
    height: portrait ? 1920 : 1080,
    portrait: portrait,
    modal: modal,
    queueOffset: queueOffset,
    queueScroll: queueScroll,
    queueModesExpanded: queueModesExpanded,
  );
}

void main() {
  group('竖屏（paintPortraitShell + paintPortraitQueuePage）', () {
    testWidgets('队列页给出返回、模式区、清空与三行命中', (WidgetTester tester) async {
      // queueScroll: 0 —— 默认规则把当前行（index 1）置顶会滚掉首行，
      // 这里要看三行都可见的版本。
      final BasicHudFrame frame = _build(portrait: true, queueScroll: 0);
      expect(_actions(frame), containsAll(<String>[
        'close-modal',
        'mobile:queue-modes',
        'player:clear',
        'player:queue:0',
        'player:queue:1',
        'player:queue:2',
      ]));
      // 当前行（queueIndex = 1）不给移除；空出的位置补上第 1 行那枚。
      // （第 3 行的 × 落在内容裁剪区之下，被 `beginContent` 裁掉——见
      // portrait_pages_queue 的页面级测试，那里用更高的画布覆盖。）
      expect(_actions(frame), contains('player:remove:0'));
      expect(_actions(frame), isNot(contains('player:remove:1')));
      // 页头文案与行标题都在绘制输出里。
      expect(_texts(frame), contains('播放队列'));
      expect(_texts(frame), contains('第一首'));
      expect(_texts(frame), contains('第二首'));
      // 第三行落在内容区下缘之外：1080×1920 的竖屏 = 393×698.7 网格、
      // contentBottom = 698.7-144 = 554.7，而行从 409 起、步长 68
      // （ResponsiveHudPages.cpp:495-505）—— 第三行 545 被裁，等用户滚动，
      // 与 Qt 一致；行内容本身的排版由 queue_portrait_page_test 覆盖。
      expect(_texts(frame), isNot(contains('第三首')));
    });

    testWidgets('队列页页头不画设置齿轮（只剩底栏那一枚 settings）',
        (WidgetTester tester) async {
      final BasicHudFrame frame = _build(portrait: true, queueScroll: 0);
      // 底栏四个 nav cell 由 shell 画（Qt 队列页同样保留底栏），其中「设置」给
      // 'settings'。页头齿轮若误开，会再多一枚（'settings' 或 'saved'）。
      expect(_actions(frame).where((String a) => a == 'settings').length, 1);
      expect(_actions(frame), isNot(contains('saved')));
    });

    testWidgets('modal 为空时同一条数据仍走首页（队列命中不泄漏到其它页）',
        (WidgetTester tester) async {
      final BasicHudFrame frame = _build(portrait: true, modal: '');
      expect(_actions(frame).where((String a) => a.startsWith('player:queue:')), isEmpty);
      expect(_actions(frame), isNot(contains('player:clear')));
    });

    testWidgets('模式展开后四个 chip 都在，且选中项与 queueMode 一致',
        (WidgetTester tester) async {
      final BasicHudFrame frame = _build(
        portrait: true,
        queueModesExpanded: true,
        queueMode: 'one',
      );
      expect(
        _actions(frame),
        containsAll(<String>[
          'player:mode:off',
          'player:mode:all',
          'player:mode:one',
          'player:mode:shuffle',
        ]),
      );
      expect(_texts(frame), contains('单曲循环  ▾'));
    });

    testWidgets('滚动量由宿主显式给值时按值排版（当前歌曲卡被上移）',
        (WidgetTester tester) async {
      final BasicHudFrame top = _build(portrait: true, queueScroll: 0);
      final BasicHudFrame scrolled = _build(portrait: true, queueScroll: 200);
      // 102 高的当前歌曲卡：fill 命令 [fill, color, x, y, 353, 102]。
      double cardTop(BasicHudFrame frame) => frame.commands
          .firstWhere(
            (List<Object?> c) => c.length >= 6 && c[0] == 'fill' && c[4] == 353 && c[5] == 102,
          )[3]! as double;
      // 竖屏画布以 ['scale', unit, unit] 打头，命令里的坐标仍是 393 网格单位。
      expect(cardTop(top), closeTo(158, 0.01));
      expect(cardTop(scrolled), closeTo(158 - 200, 0.01));
    });

    testWidgets('空队列：画「播放队列为空」且没有行命中与清空按钮',
        (WidgetTester tester) async {
      final BasicHudFrame frame = BasicHudFrame.build(
        state: BasicViewState(
          phase: BasicPhase.library,
          songs: _queue(),
          catalogLoaded: true,
          dark: true,
        ),
        ports: _ports(),
        width: 1080,
        height: 1920,
        portrait: true,
        modal: 'queue',
      );
      expect(_texts(frame), contains('播放队列为空'));
      expect(_actions(frame).where((String a) => a.startsWith('player:queue:')), isEmpty);
      expect(_actions(frame).where((String a) => a.startsWith('player:remove:')), isEmpty);
      // Qt 的「清空队列」文字与命中是无条件画的（ResponsiveHudPages.cpp:493-494），
      // 空队列下同样可点（player.clearUpcoming 在空队列上是空操作）。
      expect(_actions(frame), contains('player:clear'));
      expect(_actions(frame), contains('close-modal'));
    });
  });

  group('横屏（ModalShell + renderQueueModal）', () {
    testWidgets('队列面板给出返回、清空、模式与可见行命中', (WidgetTester tester) async {
      final BasicHudFrame frame = _build(portrait: false);
      expect(_actions(frame), containsAll(<String>[
        'close-modal',
        'player:clear',
        'player:queue:0',
        'player:queue:1',
        'player:queue:2',
        'player:mode:off',
        'player:mode:all',
        'player:mode:one',
        'player:mode:shuffle',
      ]));
      expect(_actions(frame), containsAll(<String>['player:remove:0', 'player:remove:2']));
      expect(_actions(frame), isNot(contains('player:remove:1')));
      expect(_texts(frame), contains('Now Playing'));
      expect(_texts(frame), contains('播放队列 / SESSION TRACKS'));
      expect(_texts(frame), contains('播放队列  3'));
    });

    testWidgets('面板首行由 queueOffset 决定（Qt queueOffset = 当前曲目置顶）',
        (WidgetTester tester) async {
      // 7 首才能看出 offset 的作用（可见行 7，offset 上移到末尾时首行是第 2 首）。
      final List<SirenSong> queue = <SirenSong>[
        for (int i = 0; i < 7; i++) _song('s$i', '第${i + 1}首'),
      ];
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: queue,
        catalogLoaded: true,
        dark: true,
        queue: queue,
        queueIndex: 0,
        playingTrack: queue.first,
      );
      BasicHudFrame frame(int offset) => BasicHudFrame.build(
            state: state,
            ports: _ports(),
            width: 1920,
            height: 1080,
            portrait: false,
            modal: 'queue',
            queueOffset: offset,
          );
      // 行命中的 label 是 '播放 <title>'（PlaybackQueueCard.cpp:106），用它读
      // 「面板此刻可见哪些行」——比整帧文本可靠（资料库与播放条也在同一帧里）。
      Iterable<String> visibleRows(BasicHudFrame frame) => frame.hits
          .map((HudHit hit) => hit.label)
          .where((String label) => label.startsWith('播放 第'));
      // queueModalMaximumOffset(7) = 6；offset=3 时可见首行是第 4 首（下标 3）。
      expect(visibleRows(frame(0)), contains('播放 第1首'));
      expect(visibleRows(frame(3)), contains('播放 第4首'));
      expect(visibleRows(frame(3)), isNot(contains('播放 第1首')));
      // 序号是 queueModalPad(index+1)，跟着 offset 走（第 4 首显示 04）。
      expect(_texts(frame(3)), contains('04'));
    });

    testWidgets('横屏面板压住资料库与播放条：队列面板的返回命中在面板矩形内',
        (WidgetTester tester) async {
      final BasicHudFrame frame = _build(portrait: false);
      final HudHit back = frame.hits.firstWhere((HudHit hit) => hit.action == 'close-modal');
      // Qt modalBounds(1920) = {left 330, top 122, width 1260, height 836}
      // （NativeHud::modalBounds 通用分支）；卡片再按 x+53 / width-106 收缩，
      // 返回按钮钉在 x+width-167 = 330+1260-53-167 = 1370。
      expect(back.x, closeTo(1370, 1));
      expect(back.y, closeTo(122 + 18, 1));
      expect(back.width, closeTo(167, 1));
      expect(back.height, closeTo(54, 1));
    });

    testWidgets('modal 为空时横屏不叠队列面板（没有队列命中/清空）',
        (WidgetTester tester) async {
      final BasicHudFrame frame = _build(portrait: false, modal: '');
      expect(_actions(frame).where((String a) => a.startsWith('player:queue:')), isEmpty);
      expect(_actions(frame), isNot(contains('player:clear')));
      expect(_actions(frame), contains('player:open'));
    });
  });

  group('两份版面的状态串对齐', () {
    testWidgets('queueIndex 越界（-1）时没有当前行高亮、也不发 remove 给空位',
        (WidgetTester tester) async {
      final BasicHudFrame frame = _build(portrait: false, queueIndex: -1);
      // currentIndex = -1 时所有行都可移除，没有一行是当前行。
      expect(_actions(frame), containsAll(<String>[
        'player:remove:0',
        'player:remove:1',
        'player:remove:2',
      ]));
    });

    test('queueModalMaximumOffset 与 VisibleRows=7 一致（Qt PlaybackQueueCard）', () {
      expect(queueModalMaximumOffset(0), 0);
      expect(queueModalMaximumOffset(1), 0);
      expect(queueModalMaximumOffset(7), 6);
      expect(queueModalVisibleRows, 7);
    });
  });
}
