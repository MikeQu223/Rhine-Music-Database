// OPS86-A33 / T39-T01：播放条（PlayerBar）固定命中与几何的独立验收测试。
//
// 静态产物：本文件编写时未执行任何 flutter/dart 命令（本卡禁令），断言全部由源码推导。
// 真值来源只有两处：
//   lib/hud/player/player_bar.dart:307-317（hit 的七键）、:348-369（controls）、
//   :372-386（chrome，只画不命中）、:434-462（timeline）、:486-505（playbackMode）、
//   :516-537（output）、:543-578（render 中枢几何）
//   Qt/src/PlayerBar.cpp:46-54 / 67-88 / 89-103 / 141-155 / 174-199 / 208-225 / 229-252
//
// bounds=(40,10,1000,96) 的静态推导（IEEE754 下 1000*0.23 精确等于 230）：
//   right=1040、center=540、centerY=58、favoriteX=270、songWidth=168、
//   outputX=740、volumeX=798、queueX=975。
//
// 命名对照（任务口径 → 实现字符串）：
//   player:volume → 'player:volume-fraction:0'（PlayerBar.cpp:217）
//   player:queue  → 'player:open'（PlayerBar.cpp:224，队列入口）

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/player/player_bar.dart';

// ── 度量替身 ───────────────────────────────────────────────────────────────
/// 只读 GlyphsPort 替身：宽度按 UTF-16 单元数计，bounds 用 0.75 em 顶线。
///
/// PlayerBar 的 hit 矩形完全不读字形，因此该替身只影响 text 命令，
/// 不影响本文件任何几何断言；它的存在只是让 render 可被调用。
class _FixedGlyphs implements GlyphsPort {
  const _FixedGlyphs();

  @override
  double width(String value, double size, String weight) => value.length * 1.0;

  @override
  GlyphBounds bounds(String value, double size, String weight) => GlyphBounds(
        x: 0.0,
        y: -size * 0.75,
        width: value.length * 1.0,
        height: size,
      );
}

// ── 调色板（Qt/src/PlayerBar.cpp:27-31，light） ────────────────────────────
const List<double> _paper = <double>[0.933, 0.937, 0.894, 1.0];
const List<double> _ink = <double>[0.141, 0.161, 0.145, 1.0];

// ── 图标路径（Qt/src/PlayerBar.cpp:70-71、82、161-162、180-181、185-186、193-194）──
const String _heartPath =
    'M 0 11 L -12 -1 L -12 -8 L -7 -13 L -2 -13 L 0 -10 L 2 -13 L 7 -13 L 12 -8 L 12 -1 Z';
const String _prevPath = 'M -57 -9 L -69 0 L -57 9 Z M -73 -10 L -73 10';
const String _nextPath = 'M 57 -9 L 69 0 L 57 9 Z M 73 -10 L 73 10';
const String _playPath = 'M -5 -10 L 9 0 L -5 10 Z';
const String _orderPath =
    'M -12 -8 L -3 -8 M -12 0 L -3 0 M -12 8 L -3 8 M 2 0 L 12 0 M 7 -5 L 12 0 L 7 5';
const String _shufflePath =
    'M -12 -8 L -6 -8 L 6 8 L 12 8 M 8 4 L 12 8 L 8 12 M -12 8 L -6 8 L 6 -8 L 12 -8 M 8 -12 L 12 -8 L 8 -4';
const String _loopPath =
    'M -11 3 L -11 -6 L -7 -9 L 11 -9 M 7 -13 L 11 -9 L 7 -5 M 11 -3 L 11 6 L 7 9 L -11 9 M -7 5 L -11 9 L -7 13';

// ── 基准与读取器 ───────────────────────────────────────────────────────────
const PlayerBarRect _bounds = PlayerBarRect(40.0, 10.0, 1000.0, 96.0);

PlayerBarDrawing _render(
  PlayerBarState state, {
  PlayerBarRect bounds = _bounds,
  PlayerBarSurface surface = PlayerBarSurface.embedded,
}) =>
    renderPlayerBar(state, bounds, false, const _FixedGlyphs(), surface);

List<String> _actions(PlayerBarDrawing drawing) => drawing.hits
    .map((Map<String, Object?> item) => item['action'] as String)
    .toList();

Map<String, Object?> _hit(PlayerBarDrawing drawing, String action) =>
    drawing.hits.firstWhere((Map<String, Object?> item) => item['action'] == action);

List<Map<String, Object?>> _hitsOf(PlayerBarDrawing drawing, String action) =>
    drawing.hits.where((Map<String, Object?> item) => item['action'] == action).toList();

/// 该绘制的非填充图标路径，按命令顺序。
List<String> _strokePaths(PlayerBarDrawing drawing) => drawing.commands
    .where((List<Object?> command) => command[0] == 'path')
    .map((List<Object?> command) => command[1] as String)
    .toList();

/// 命中右缘 / 中心 y，用于断言相对几何（全部取自实际命中，不写死推导式）。
double _right(Map<String, Object?> item) =>
    (item['x'] as double) + (item['width'] as double);

double _centerY(Map<String, Object?> item) =>
    (item['y'] as double) + (item['height'] as double) / 2;

void _expectRect(
  PlayerBarDrawing drawing,
  String action,
  double x,
  double y,
  double width,
  double height,
) {
  final Map<String, Object?> item = _hit(drawing, action);
  expect(
    <Object?>[item['x'], item['y'], item['width'], item['height']],
    <Object?>[x, y, width, height],
    reason: '命中矩形不符：$action',
  );
}

void main() {
  // 有轨 + 可喜欢 + 可 seek 的完整态：十条命中，覆盖全部固定键。
  const PlayerBarState full = PlayerBarState(
    hasTrack: true,
    canLike: true,
    seekable: true,
    durationMs: 2000.0,
    positionMs: 500.0,
  );

  group('命中契约：七键、fixed、顺序', () {
    test('每条命中恰七键，且键序与 Qt QJsonObject 插入序一致', () {
      final PlayerBarDrawing drawing = _render(full);
      expect(drawing.hits, isNotEmpty);
      for (final Map<String, Object?> item in drawing.hits) {
        expect(item.length, 7);
        expect(
          item.keys.toList(),
          <String>['x', 'y', 'width', 'height', 'action', 'label', 'fixed'],
        );
      }
    });

    test('全部命中 fixed=true，矩形为正尺寸，label 非空', () {
      for (final Map<String, Object?> item in _render(full).hits) {
        expect(item['fixed'], isTrue);
        expect(item['width'] as double, greaterThan(0.0));
        expect(item['height'] as double, greaterThan(0.0));
        expect((item['label'] as String).isNotEmpty, isTrue);
      }
    });

    test('完整态命中序列：song 歌词 → like → prev/toggle/next → 词 → mode → seek → volume → open', () {
      expect(_actions(_render(full)), <String>[
        'player:lyrics',
        'music:like-current',
        'player:prev',
        'player:toggle',
        'player:next',
        'player:lyrics',
        'player:mode',
        'player:seek-fraction:0',
        'player:volume-fraction:0',
        'player:open',
      ]);
    });

    test('controls 三键相邻且顺序固定 prev → toggle → next', () {
      final List<String> actions = _actions(_render(full));
      final int prev = actions.indexOf('player:prev');
      expect(prev, isNonNegative);
      expect(actions.sublist(prev, prev + 3),
          <String>['player:prev', 'player:toggle', 'player:next']);
      expect(actions.indexOf('player:prev', prev + 1), -1);
      expect(actions.indexOf('player:toggle'), prev + 1);
      expect(actions.indexOf('player:next'), prev + 2);
    });

    test('三键 label 固定：上一首 / 播放（暂停） / 下一首', () {
      final PlayerBarDrawing idle = _render(full);
      expect(_hit(idle, 'player:prev')['label'], '上一首');
      expect(_hit(idle, 'player:next')['label'], '下一首');
      expect(_hit(idle, 'player:toggle')['label'], '播放');
      final PlayerBarDrawing playing = _render(const PlayerBarState(playing: true));
      expect(_hit(playing, 'player:toggle')['label'], '暂停');
      // playing 只改文案与播放键画法，不改三键矩形。
      _expectRect(playing, 'player:toggle', 517.0, 35.0, 46.0, 46.0);
    });

    test('有轨时 player:lyrics 出现两次（歌曲区 + 词按钮），且都在 controls 之外', () {
      final PlayerBarDrawing drawing = _render(full);
      final List<Map<String, Object?>> lyrics = _hitsOf(drawing, 'player:lyrics');
      expect(lyrics.length, 2);
      expect(lyrics[0]['x'], 68.0); // bounds.x + 28（song 区）
      expect(lyrics[1]['x'], 546.0); // bounds.right - 470 - 24（词按钮）
    });

    test('mode / volume / queue 的 action 与 label 固定', () {
      final PlayerBarDrawing drawing = _render(full);
      expect(_hit(drawing, 'player:mode')['label'], '顺序播放，点击切换播放模式');
      expect(_hit(drawing, 'player:volume-fraction:0')['label'], '音量');
      expect(_hit(drawing, 'player:open')['label'], '播放队列');
      expect(drawing.hits.last['action'], 'player:open');
    });

    test('seek 命中存在且 fixed=true，并与 drawing.seek 同矩形', () {
      final PlayerBarDrawing drawing = _render(full);
      final Map<String, Object?> seek = _hit(drawing, 'player:seek-fraction:0');
      expect(seek['fixed'], isTrue);
      expect(drawing.seek, isNotNull);
      expect(
        <Object?>[drawing.seek!.x, drawing.seek!.y, drawing.seek!.width, drawing.seek!.height],
        <Object?>[seek['x'], seek['y'], seek['width'], seek['height']],
      );
    });

    test('无轨：seek / lyrics / like 全部不出现，只剩六个固定命中', () {
      final PlayerBarDrawing drawing = _render(const PlayerBarState());
      expect(_actions(drawing), <String>[
        'player:prev',
        'player:toggle',
        'player:next',
        'player:mode',
        'player:volume-fraction:0',
        'player:open',
      ]);
      expect(_hitsOf(drawing, 'player:seek-fraction:0'), isEmpty);
      expect(_hitsOf(drawing, 'player:lyrics'), isEmpty);
      expect(_hitsOf(drawing, 'music:like-current'), isEmpty);
      expect(drawing.seek, isNull);
    });

    test('无轨但 seekable+duration>0：只有 seek 回来，lyrics/like 仍缺席', () {
      final PlayerBarDrawing drawing =
          _render(const PlayerBarState(seekable: true, durationMs: 1000.0));
      expect(_hit(drawing, 'player:seek-fraction:0')['fixed'], isTrue);
      expect(_hitsOf(drawing, 'player:lyrics'), isEmpty);
      expect(_hitsOf(drawing, 'music:like-current'), isEmpty);
    });

    test('seekable=true 但 durationMs=0：无 seek 命中，drawing.seek 为 null', () {
      final PlayerBarDrawing drawing = _render(const PlayerBarState(seekable: true));
      expect(_hitsOf(drawing, 'player:seek-fraction:0'), isEmpty);
      expect(drawing.seek, isNull);
    });

    test('applicationVolume=false：无音量命中，drawing.volume 为 null', () {
      final PlayerBarDrawing drawing = _render(const PlayerBarState(applicationVolume: false));
      expect(_hitsOf(drawing, 'player:volume-fraction:0'), isEmpty);
      expect(drawing.volume, isNull);
    });

    test('canLike 开关只影响 like 命中：关时缺席，开时插在 song 歌词与 controls 之间', () {
      final PlayerBarDrawing without = _render(const PlayerBarState(hasTrack: true));
      expect(_hitsOf(without, 'music:like-current'), isEmpty);
      final PlayerBarDrawing withLike =
          _render(const PlayerBarState(hasTrack: true, canLike: true));
      expect(
        _actions(withLike).sublist(0, 3),
        <String>['player:lyrics', 'music:like-current', 'player:prev'],
      );
    });
  });

  group('嵌入式基准几何：bounds=(40,10,1000,96)', () {
    test('controls 三键精确矩形（center=540、centerY=58）', () {
      final PlayerBarDrawing drawing = _render(full);
      _expectRect(drawing, 'player:prev', 451.0, 34.0, 44.0, 48.0);
      _expectRect(drawing, 'player:toggle', 517.0, 35.0, 46.0, 46.0);
      _expectRect(drawing, 'player:next', 585.0, 34.0, 44.0, 48.0);
      // 相对关系取自实际命中：三键共用 centerY，左右各留 22 空隙。
      final Map<String, Object?> prev = _hit(drawing, 'player:prev');
      final Map<String, Object?> toggle = _hit(drawing, 'player:toggle');
      final Map<String, Object?> next = _hit(drawing, 'player:next');
      expect(_centerY(prev), 58.0);
      expect(_centerY(toggle), 58.0);
      expect(_centerY(next), 58.0);
      expect(_right(prev), 495.0);
      expect((toggle['x'] as double) - _right(prev), 22.0);
      expect((next['x'] as double) - _right(toggle), 22.0);
    });

    test('seek 与 row 同 x 同宽，位于 row 上方 6、高 18', () {
      final PlayerBarDrawing drawing = _render(full);
      _expectRect(drawing, 'player:seek-fraction:0', 40.0, 4.0, 1000.0, 18.0);
      expect(drawing.seek, const PlayerBarRect(40.0, 4.0, 1000.0, 18.0));
      // row 本身：x=bounds.x、width=bounds.width，故 seek 与 row 同宽同 x。
      expect(drawing.seek!.x, drawing.inputBounds.x);
      expect(drawing.seek!.width, drawing.inputBounds.width);
      expect(drawing.seek!.y, drawing.inputBounds.y);
    });

    test('inputBounds = row 上扩 6（PlayerBar.cpp:242）', () {
      final PlayerBarDrawing drawing = _render(full);
      expect(drawing.inputBounds, const PlayerBarRect(40.0, 4.0, 1000.0, 102.0));
      expect(drawing.inputBounds.height, playerBarRowHeight + 6.0);
    });

    test('volume 精确矩形（outputX=740、volumeX=798）', () {
      final PlayerBarDrawing drawing = _render(full);
      _expectRect(drawing, 'player:volume-fraction:0', 798.0, 57.0, 100.0, 28.0);
      expect(drawing.volume, const PlayerBarRect(798.0, 57.0, 100.0, 28.0));
    });

    test('queue（player:open）精确矩形（right-65-14=961）', () {
      final PlayerBarDrawing drawing = _render(full);
      _expectRect(drawing, 'player:open', 961.0, 26.0, 54.0, 65.0);
      final Map<String, Object?> open = _hit(drawing, 'player:open');
      expect((open['x'] as double) + 14.0, 975.0); // queueX = right - 65
      expect(_right(open), 1015.0); // queueX - 14 + 54
      // 队列图标三条线（PlayerBar.cpp:220-222）：前两条 19 宽、第三条 13 宽，x 都是 queueX。
      final List<List<Object?>> queueLines = drawing.commands
          .where((List<Object?> command) => command[0] == 'fill' && command[2] == 975.0)
          .toList();
      expect(queueLines, <List<Object?>>[
        <Object?>['fill', _ink, 975.0, 38.0, 19.0, 1.5],
        <Object?>['fill', _ink, 975.0, 44.0, 19.0, 1.5],
        <Object?>['fill', _ink, 975.0, 50.0, 13.0, 1.5],
      ]);
    });

    test('mode / 词 / song 歌词 / like 精确矩形', () {
      final PlayerBarDrawing drawing = _render(full);
      _expectRect(drawing, 'player:mode', 636.0, 34.0, 48.0, 48.0);
      expect(_hitsOf(drawing, 'player:lyrics')[1]['x'], 546.0);
      expect(_hitsOf(drawing, 'player:lyrics')[1]['width'], 48.0);
      _expectRect(drawing, 'player:lyrics', 68.0, 24.0, 168.0, 74.0); // songWidth
      expect(_hitsOf(drawing, 'player:lyrics')[0]['width'], 168.0); // songWidth
      _expectRect(drawing, 'music:like-current', 246.0, 34.0, 48.0, 48.0);
    });

    test('mode 命中以 bounds.right-380 为中心', () {
      final Map<String, Object?> mode = _hit(_render(full), 'player:mode');
      expect((mode['x'] as double) + (mode['width'] as double) / 2, 660.0);
      expect((mode['y'] as double) + (mode['height'] as double) / 2, 58.0);
    });
  });

  group('floating：chrome 不参与命中，行内整体下移 44', () {
    test('命中条数/动作/x 不变，y 逐条加 HeaderHeight', () {
      final PlayerBarDrawing embedded = _render(full);
      final PlayerBarDrawing floating = _render(full, surface: PlayerBarSurface.floating);
      expect(floating.hits.length, embedded.hits.length);
      for (int i = 0; i < embedded.hits.length; i += 1) {
        expect(floating.hits[i]['action'], embedded.hits[i]['action']);
        expect(floating.hits[i]['x'], embedded.hits[i]['x']);
        expect(floating.hits[i]['y'], (embedded.hits[i]['y'] as double) + playerBarHeaderHeight);
      }
      expect(playerBarHeaderHeight, 44.0);
    });

    test('floating 下 prev/toggle/next/seek/volume/queue 的精确 y', () {
      final PlayerBarDrawing drawing = _render(full, surface: PlayerBarSurface.floating);
      _expectRect(drawing, 'player:prev', 451.0, 78.0, 44.0, 48.0);
      _expectRect(drawing, 'player:toggle', 517.0, 79.0, 46.0, 46.0);
      _expectRect(drawing, 'player:next', 585.0, 78.0, 44.0, 48.0);
      _expectRect(drawing, 'player:seek-fraction:0', 40.0, 48.0, 1000.0, 18.0);
      _expectRect(drawing, 'player:volume-fraction:0', 798.0, 101.0, 100.0, 28.0);
      _expectRect(drawing, 'player:open', 961.0, 70.0, 54.0, 65.0);
      expect(drawing.inputBounds, const PlayerBarRect(40.0, 48.0, 1000.0, 102.0));
      expect(drawing.seek, const PlayerBarRect(40.0, 48.0, 1000.0, 18.0));
    });
  });

  group('mode cycling：action/几何不变，图标 path 三态', () {
    test('顺序（空串/未知值）：orderPath，label 顺序播放', () {
      for (final String mode in <String>['', 'off', 'sequential']) {
        final PlayerBarDrawing drawing = _render(PlayerBarState(mode: mode));
        expect(_hit(drawing, 'player:mode')['label'], '顺序播放，点击切换播放模式');
        expect(_hit(drawing, 'player:mode')['action'], 'player:mode');
        expect(_strokePaths(drawing).last, _orderPath);
      }
    });

    test('shuffle：shufflePath，label 随机播放', () {
      final PlayerBarDrawing drawing = _render(const PlayerBarState(mode: 'shuffle'));
      expect(_hit(drawing, 'player:mode')['label'], '随机播放，点击切换播放模式');
      expect(_strokePaths(drawing).last, _shufflePath);
      expect(
        drawing.commands,
        anyElement(equals(<Object?>['path', _shufflePath, 1.5, _ink, <Object?>[], 0])),
      );
    });

    test('all：loopPath，label 列表循环', () {
      final PlayerBarDrawing drawing = _render(const PlayerBarState(mode: 'all'));
      expect(_hit(drawing, 'player:mode')['label'], '列表循环，点击切换播放模式');
      expect(_strokePaths(drawing).last, _loopPath);
      expect(
        drawing.commands,
        anyElement(equals(<Object?>['path', _loopPath, 1.5, _ink, <Object?>[], 0])),
      );
    });

    test('one：loopPath + 居中「1」，label 单曲循环', () {
      final PlayerBarDrawing drawing = _render(const PlayerBarState(mode: 'one'));
      expect(_hit(drawing, 'player:mode')['label'], '单曲循环，点击切换播放模式');
      expect(_strokePaths(drawing).last, _loopPath);
      final List<Object?> one = drawing.commands.firstWhere(
        (List<Object?> command) => command[0] == 'text' && command[1] == '1',
      );
      expect(one[4], 12.0);
      expect(one[5], 'demibold');
      // centeredLabel("1",0,0,12,"demibold")：bounds(0,-9,1,12) → 局部 (-0.5, 3)
      expect(one[2], -0.5);
      expect(one[3], 3.0);
    });

    test('四态之间命中序列与所有矩形完全一致，只有 label 与图标变', () {
      final List<String> baseline = _actions(_render(const PlayerBarState()));
      final Map<String, List<Object?>> rects = <String, List<Object?>>{};
      for (final String mode in <String>['', 'shuffle', 'all', 'one']) {
        final PlayerBarDrawing drawing = _render(PlayerBarState(mode: mode));
        expect(_actions(drawing), baseline, reason: 'mode=$mode 改变了命中序列');
        rects[mode] = drawing.hits
            .expand((Map<String, Object?> item) => <Object?>[
                  item['x'],
                  item['y'],
                  item['width'],
                  item['height'],
                ])
            .toList();
        expect(
          (_hit(drawing, 'player:mode')['label'] as String).endsWith('，点击切换播放模式'),
          isTrue,
        );
      }
      expect(rects['shuffle'], rects['']);
      expect(rects['all'], rects['']);
      expect(rects['one'], rects['']);
    });
  });

  group('泛化：bounds 原点、纯函数性、命令序', () {
    test('bounds.x/y 全程参与：整体平移时全部命中同量平移', () {
      final PlayerBarDrawing origin = _render(full, bounds: const PlayerBarRect(0.0, 0.0, 1000.0, 96.0));
      final PlayerBarDrawing moved =
          _render(full, bounds: const PlayerBarRect(37.5, 123.25, 1000.0, 96.0));
      expect(moved.hits.length, origin.hits.length);
      for (int i = 0; i < origin.hits.length; i += 1) {
        expect(moved.hits[i]['x'], (origin.hits[i]['x'] as double) + 37.5);
        expect(moved.hits[i]['y'], (origin.hits[i]['y'] as double) + 123.25);
        expect(moved.hits[i]['width'], origin.hits[i]['width']);
        expect(moved.hits[i]['height'], origin.hits[i]['height']);
      }
      // 非零原点同样参与派生量：seek.x 跟随 bounds.x，queue 跟随 bounds.right。
      expect(moved.seek, const PlayerBarRect(37.5, 117.25, 1000.0, 18.0));
      expect(_hit(moved, 'player:open')['x'], 37.5 + 1000.0 - 65.0 - 14.0);
    });

    test('render 是纯函数：同输入两次渲染命令与命中逐项相同', () {
      const PlayerBarState state = PlayerBarState(
        title: 'T',
        artist: 'A',
        album: 'B',
        mode: 'shuffle',
        positionMs: 750.0,
        durationMs: 3000.0,
        volume: 0.4,
        hasTrack: true,
        canLike: true,
        seekable: true,
      );
      final PlayerBarDrawing first = _render(state);
      final PlayerBarDrawing second = _render(state);
      expect(second.commands.length, first.commands.length);
      for (int i = 0; i < first.commands.length; i += 1) {
        expect(second.commands[i], first.commands[i], reason: 'command #$i 不稳定');
      }
      expect(second.hits.length, first.hits.length);
      for (int i = 0; i < first.hits.length; i += 1) {
        expect(second.hits[i], first.hits[i], reason: 'hit #$i 不稳定');
      }
      expect(second.inputBounds, first.inputBounds);
      expect(second.seek, first.seek);
      expect(second.volume, first.volume);
    });

    test('controls 帧：save/translate 包裹局部坐标绘制，命中才是绝对值', () {
      final PlayerBarDrawing drawing = _render(full);
      final int translate = drawing.commands.indexWhere(
        (List<Object?> command) =>
            command[0] == 'translate' && command[1] == 540.0 && command[2] == 58.0,
      );
      expect(translate, isNonNegative);
      expect(drawing.commands[translate - 1], <Object?>['save']);
      expect(
        drawing.commands.sublist(translate - 1, translate + 6),
        <List<Object?>>[
          <Object?>['save'],
          <Object?>['translate', 540.0, 58.0],
          <Object?>['path', _prevPath, 1.5, _ink, <Object?>[], 0],
          <Object?>['path', _nextPath, 1.5, _ink, <Object?>[], 0],
          <Object?>['fill', _ink, -23.0, -23.0, 46.0, 46.0],
          <Object?>['fill-path', _playPath, _paper],
          <Object?>['restore'],
        ],
      );
      // 同一帧里的命中是绝对坐标：中心键 517/35 而非局部 -23/-23。
      expect(_hit(drawing, 'player:toggle')['x'], 517.0);
      expect(_hit(drawing, 'player:toggle')['y'], 35.0);
    });

    test('未播放时 path 命令序固定：heart → prev → next → mode', () {
      expect(_strokePaths(_render(full)),
          <String>[_heartPath, _prevPath, _nextPath, _orderPath]);
    });

    test('第五个参数（surface）缺省为 embedded', () {
      final PlayerBarDrawing implicit =
          renderPlayerBar(full, _bounds, false, const _FixedGlyphs());
      expect(_actions(implicit), _actions(_render(full)));
      expect(implicit.inputBounds, _render(full).inputBounds);
    });

    test('首条命令是整块底色 fill，覆盖完整 bounds', () {
      final List<List<Object?>> commands = _render(full).commands;
      expect(commands.first, <Object?>['fill', _paper, 40.0, 10.0, 1000.0, 96.0]);
    });
  });
}
