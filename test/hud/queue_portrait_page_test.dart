/// 竖屏播放队列页（`lib/hud/portrait/portrait_pages_queue.dart`）验收测试。
///
/// 真值：`Qt/src/ResponsiveHudPages.cpp:468-533` 的 `ResponsiveHudLayout::queue()`
/// （当前歌曲卡 / 播放模式按钮 / 四 chip / 分节 + 清空 / 68 高队列行 / 空态 /
/// 尾部说明 / 应用音量 / 返回总高），行与控件走 `Qt/src/ResponsiveHudCanvas.cpp`
/// 的 `row()` / `section()` / `button()` / `chip()`。
///
/// 断言口径：动作串逐字、当前行序号「●」、非当前行才给 `player:remove`、
/// 空队列状态串、模式标签顺序、音量区只在 applicationVolume 时出现。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_queue.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 宽度按字符数估算：本组测试只关心「画了什么 / 发了什么动作」，不校验像素。
PortraitCanvas _canvas({bool dark = true, double gridWidth = 393, double height = 700}) =>
    PortraitCanvas(
      metrics: PortraitMetrics(
        width: (String value, double size, String weight) => value.length * size * .6,
        wrap: (String value, double limit, double size, String weight) => <String>[value],
        bounds: (String value, double size, String weight) =>
            PortraitGlyphBounds(width: value.length * size * .6, height: size),
      ),
      unit: 1,
      gridWidth: gridWidth,
      height: height,
      dark: dark,
    );

Set<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toSet();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command.length >= 2 && command[0] == 'text') command[1]! as String,
];

PortraitQueueRow _row(String title, {String artist = '塞壬唱片', double durationMs = 180000}) =>
    (title: title, artist: artist, stamp: _time(durationMs), image: '');

/// Qt `MusicData::time` 的 mm:ss（时长 <= 0 显示「暂无」，这里只造正时长）。
String _time(double durationMs) {
  final int minutes = (durationMs / 60000).truncate();
  final int seconds = (durationMs / 1000).truncate() % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

double _paint(
  PortraitCanvas c, {
  String title = '在播曲',
  String artist = '塞壬唱片',
  List<PortraitQueueRow>? tracks,
  int currentIndex = 0,
  String mode = 'all',
  bool modesExpanded = false,
  bool applicationVolume = false,
  double volume = .4,
  double? scroll,
}) {
  // 队列页由 shell 调用：contentBottom 已由 paintPortraitShell 设好（= h - 144）。
  c.contentBottom = c.height - 144;
  return paintPortraitQueuePage(
    c,
    title: title,
    artist: artist,
    tracks: tracks ?? <PortraitQueueRow>[_row('甲'), _row('乙'), _row('丙')],
    currentIndex: currentIndex,
    mode: mode,
    modesExpanded: modesExpanded,
    applicationVolume: applicationVolume,
    volume: volume,
    scroll: scroll,
  );
}

void main() {
  group('当前歌曲卡（ResponsiveHudPages.cpp:469-476）', () {
    test('标题/艺人逐字上卡，空标题回落「等待音轨」', () {
      final PortraitCanvas c = _canvas();
      _paint(c, title: 'Kernel Overflow', artist: 'MSR');
      final List<String> texts = _texts(c);
      expect(texts, contains('ON AIR / 当前歌曲'));
      expect(texts, contains('Kernel Overflow'));
      expect(texts, contains('MSR'));

      final PortraitCanvas empty = _canvas();
      _paint(empty, title: '');
      expect(_texts(empty), contains('等待音轨'));
    });
  });

  group('播放模式区（:477-489）', () {
    test('收起态只有展开按钮，动作是 mobile:queue-modes', () {
      final PortraitCanvas c = _canvas();
      _paint(c);
      expect(_actions(c), contains('mobile:queue-modes'));
      expect(_actions(c).where((String a) => a.startsWith('player:mode:'),), isEmpty);
      expect(_texts(c), contains('PLAYBACK MODE / 播放模式'));
    });

    test('展开态四个 chip 动作串固定、标签顺序对齐 Qt，选中项标当前模式', () {
      final PortraitCanvas c = _canvas();
      _paint(c, modesExpanded: true, mode: 'one');
      for (final String value in portraitQueueModes) {
        expect(_actions(c), contains('player:mode:$value'));
      }
      expect(portraitQueueModes, <String>['off', 'all', 'one', 'shuffle']);
      expect(portraitQueueModeLabels,
          <String>['顺序播放', '列表循环', '单曲循环', '随机播放']);
      // 展开按钮文字带当前模式标签（Qt labels.value(indexOf(mode)) + "  ▾"）。
      expect(_texts(c), contains('单曲循环  ▾'));
      // 白名单外回落「顺序播放」（labels.value(-1, "顺序播放")）。
      expect(portraitQueueModeLabel('repeat'), '顺序播放');
    });
  });

  group('队列行命中（:490-510）', () {
    test('每行发 player:queue:<i>；非当前行才有 player:remove:<i>', () {
      // 视口够高才会把三行都排进裁剪区（短视口下行会被 beginContent 裁掉，
      // 那是正确的滚动行为，本组只管动作串）。
      final PortraitCanvas c = _canvas(height: 900);
      // 滚动量交给宿主：0 = 从内容区顶部开始排。
      _paint(c, currentIndex: 1, scroll: 0);
      expect(_actions(c), containsAll(<String>[
        'player:queue:0',
        'player:queue:1',
        'player:queue:2',
        'player:remove:0',
        'player:remove:2',
      ]));
      // 当前行不给移除（Qt 传空串；PlaybackQueue::remove 也拒绝当前项）。
      expect(_actions(c), isNot(contains('player:remove:1')));
    });

    test('当前行序号「●」，其余补零', () {
      final PortraitCanvas c = _canvas(height: 900);
      _paint(c, currentIndex: 1, scroll: 0);
      final List<String> texts = _texts(c);
      expect(texts, contains('●'));
      expect(texts, contains('01'));
      expect(texts, contains('03'));
      expect(texts, isNot(contains('02')));
    });

    test('分节标题带队列长度，清空队列发 player:clear 并贴右缘', () {
      final PortraitCanvas c = _canvas();
      _paint(c);
      expect(_texts(c), contains('播放队列  3'));
      expect(_texts(c), contains('清空队列'));
      expect(_actions(c), contains('player:clear'));
      final HudHit clear = c.hits.firstWhere(
        (HudHit hit) => hit.action == 'player:clear',
      );
      // Qt {291, y-5, 82, 44} 在 393 页宽上收在 373（右缘留 20）。
      expect(clear.x, 393 - 102);
      expect(clear.width, 82);
    });
  });

  group('空队列状态（:511-515）', () {
    test('空队列画「播放队列为空」且没有任何行命中', () {
      final PortraitCanvas c = _canvas();
      _paint(c, tracks: const <PortraitQueueRow>[], currentIndex: -1);
      final List<String> texts = _texts(c);
      expect(texts, contains('播放队列  0'));
      expect(texts, contains('播放队列为空'));
      expect(texts, contains('清空仅移除待播歌曲，当前歌曲继续播放。'));
      expect(_actions(c).where((String a) => a.startsWith('player:queue:')), isEmpty);
      expect(_actions(c).where((String a) => a.startsWith('player:remove:')), isEmpty);
    });
  });

  group('页面几何与音量（:516-532）', () {
    test('默认滚动量：当前行 > 0 时 251 + index*68，否则 0', () {
      final PortraitCanvas first = _canvas();
      final double bottom0 = _paint(first, currentIndex: 0);
      final PortraitCanvas third = _canvas();
      final double bottom3 = _paint(third, currentIndex: 2);
      // 两者总高都盖过「当前行置顶」的封底，但滚动量不同：index 2 的当前歌曲卡
      // 被上移 251+136=387 —— 卡片矩形顶不在原来的 158 上。
      final List<List<Object?>> cards0 = first.commands
          .where((List<Object?> c) => c[0] == 'fill' && c[4] == 353 && c[5] == 102)
          .toList();
      final List<List<Object?>> cards3 = third.commands
          .where((List<Object?> c) => c[0] == 'fill' && c[4] == 353 && c[5] == 102)
          .toList();
      expect(cards0.single[3], 158);
      expect(cards3.single[3], 158 - (251 + 2 * 68));
      // 两者的「最后一首置顶」封底相同（都由 contentBottom 决定），说明总高
      // 取的是 max(y + scroll + 20, 409 + (N-1)*68 + contentBottom - 158)。
      expect(bottom0, bottom3);
      expect(bottom0, greaterThanOrEqualTo(409 + 2 * 68 + (700 - 144) - 158));
    });

    test('手机端不画音量区；applicationVolume 时才画滑轨 + 百分比 + field', () {
      final PortraitCanvas phone = _canvas();
      _paint(phone);
      expect(_texts(phone), isNot(contains('OUTPUT / 音量')));
      expect(phone.fields.containsKey('volume'), isFalse);

      final PortraitCanvas desktop = _canvas();
      _paint(desktop, applicationVolume: true, volume: .62);
      expect(_texts(desktop), contains('OUTPUT / 音量'));
      expect(_texts(desktop), contains('62%'));
      expect(desktop.fields.containsKey('volume'), isTrue);
      // 越界音量被 clamp（Qt std::clamp(volume, 0., 1.)）。
      final PortraitCanvas over = _canvas();
      _paint(over, applicationVolume: true, volume: 3.5);
      expect(_texts(over), contains('100%'));
    });

    test('页宽变宽时右缘跟随 gridWidth（不再写死 393）', () {
      final PortraitCanvas wide = _canvas(gridWidth: 586, height: 900);
      _paint(wide);
      final HudHit clear = wide.hits.firstWhere(
        (HudHit hit) => hit.action == 'player:clear',
      );
      expect(clear.x, 586 - 102);
      // 分节副标题不再有内容（Qt 传空串），标题宽度用 220。
      expect(_texts(wide), contains('播放队列  3'));
    });
  });
}
