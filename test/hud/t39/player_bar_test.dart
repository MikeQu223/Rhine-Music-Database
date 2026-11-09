// T39-W1 / PlayerBar 1:1 Qt 语义验收测试（先写后实现，全程不执行）。
//
// 唯一真值来源：Qt/src/PlayerBar.h（State/Surface/Drawing/常量）、
// Qt/src/PlayerBar.cpp（全部绘制与命中，1-253 行）、Qt/src/NativeHudPlayer.cpp:8-42。
// 断言口径：精确命令形状 + 相对顺序 + 精确几何，禁止集合化/排序化比较。
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/player/player_bar.dart';

// ── 调色板：Qt/src/PlayerBar.cpp:19-22（dark）与 27-31（light） ──────────────
const List<double> paper = <double>[0.933, 0.937, 0.894, 1.0];
const List<double> ink = <double>[0.141, 0.161, 0.145, 1.0];
const List<double> muted = <double>[0.4, 0.439, 0.392, 1.0];
const List<double> line = <double>[0.8, 0.816, 0.761, 1.0];
const List<double> amber = <double>[0.863, 0.651, 0.227, 1.0];

const List<double> paperDark = <double>[0.133, 0.161, 0.137, 1.0];
const List<double> inkDark = <double>[0.929, 0.941, 0.875, 1.0];
const List<double> mutedDark = <double>[0.647, 0.678, 0.616, 1.0];
const List<double> lineDark = <double>[0.298, 0.329, 0.282, 1.0];

// ── 图标路径：逐字抄自 Qt/src/PlayerBar.cpp:70-71、82、161-162、180-181、185-186、193-194
const String heartPath =
    'M 0 11 L -12 -1 L -12 -8 L -7 -13 L -2 -13 L 0 -10 L 2 -13 L 7 -13 L 12 -8 L 12 -1 Z';
const String prevPath = 'M -57 -9 L -69 0 L -57 9 Z M -73 -10 L -73 10';
const String nextPath = 'M 57 -9 L 69 0 L 57 9 Z M 73 -10 L 73 10';
const String playPath = 'M -5 -10 L 9 0 L -5 10 Z';
const String orderPath =
    'M -12 -8 L -3 -8 M -12 0 L -3 0 M -12 8 L -3 8 M 2 0 L 12 0 M 7 -5 L 12 0 L 7 5';
const String shufflePath =
    'M -12 -8 L -6 -8 L 6 8 L 12 8 M 8 4 L 12 8 L 8 12 M -12 8 L -6 8 L 6 -8 L 12 -8 M 8 -12 L 12 -8 L 8 -4';
const String loopPath =
    'M -11 3 L -11 -6 L -7 -9 L 11 -9 M 7 -13 L 11 -9 L 7 -5 M 11 -3 L 11 6 L 7 9 L -11 9 M -7 5 L -11 9 L -7 13';

/// 只读度量替身：宽度按 UTF-16 code unit 数线性累加，与 Glyphs::width 逐 QChar
/// 累加同构；bounds 用 size*0.75 的假想 em 顶（真实字形由 Glyphs 提供）。
class UnitGlyphs implements GlyphsPort {
  const UnitGlyphs({this.unit = 1.0, this.ascentRatio = 0.75});

  final double unit;
  final double ascentRatio;

  @override
  double width(String value, double size, String weight) => value.length * unit;

  @override
  GlyphBounds bounds(String value, double size, String weight) => GlyphBounds(
        x: 0,
        y: -size * ascentRatio,
        width: value.length * unit,
        height: size,
      );
}

/// 记录 width 调用的假实现，用于证明省略号 fit 反复度量（含 value+"…" 探测）。
class RecordingGlyphs implements GlyphsPort {
  RecordingGlyphs({this.unit = 1.0});

  final double unit;
  final List<String> widthCalls = <String>[];

  @override
  double width(String value, double size, String weight) {
    widthCalls.add(value);
    return value.length * unit;
  }

  @override
  GlyphBounds bounds(String value, double size, String weight) =>
      GlyphBounds(x: 0, y: -size * 0.75, width: value.length * unit, height: size);
}

// ── 只读便捷读取器 ────────────────────────────────────────────────────────
List<List<Object?>> commandsOf(PlayerBarDrawing drawing, String op) =>
    drawing.commands.where((List<Object?> c) => c[0] == op).toList();

List<String> textValues(PlayerBarDrawing drawing) => drawing.commands
    .where((List<Object?> c) => c[0] == 'text')
    .map((List<Object?> c) => c[1] as String)
    .toList();

Map<String, Object?> hitOf(PlayerBarDrawing drawing, String action) =>
    drawing.hits.firstWhere((Map<String, Object?> h) => h['action'] == action);

List<Map<String, Object?>> hitsOf(PlayerBarDrawing drawing, String action) =>
    drawing.hits.where((Map<String, Object?> h) => h['action'] == action).toList();

/// 深比较：命令里的颜色是 List<double>，Dart 的 List 用引用相等，
/// 直接 != 会把等值颜色判成不等，导致 indexOfCommand 永远返回 -1。
bool _deepEquals(Object? a, Object? b) {
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i += 1) {
      if (!_deepEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

bool _sameList(List<Object?> a, List<Object?> b) => _deepEquals(a, b);

/// 命令在整帧中的下标，用于断言相对顺序。
int indexOfCommand(PlayerBarDrawing drawing, List<Object?> probe) {
  final int index = drawing.commands.indexWhere((List<Object?> c) => _sameList(c, probe));
  expect(index, isNonNegative, reason: 'expected command in frame');
  return index;
}

void main() {
  // 嵌入式基准：bounds=(0,600,1000,96)。1000*0.23=230 在 IEEE754 下精确，
  // 派生几何全部可精确书写（songWidth=168、infoWidth=94、center=500）。
  const PlayerBarRect rowBounds = PlayerBarRect(0.0, 600.0, 1000.0, 96.0);

  group('surface 契约', () {
    test('PlayerBarSurface 仅两个取值，顺序与 Qt 枚举一致', () {
      expect(PlayerBarSurface.values.length, 2);
      expect(PlayerBarSurface.values[0].name, 'embedded');
      expect(PlayerBarSurface.values[1].name, 'floating');
    });

    test('默认 surface 为 embedded（Qt 默认实参 Surface::Embedded）', () {
      final PlayerBarDrawing drawing =
          renderPlayerBar(const PlayerBarState(), rowBounds, false, const UnitGlyphs());
      final PlayerBarDrawing explicit = renderPlayerBar(
        const PlayerBarState(),
        rowBounds,
        false,
        const UnitGlyphs(),
        PlayerBarSurface.embedded,
      );
      expect(drawing.commands, explicit.commands);
      expect(drawing.hits, explicit.hits);
    });
  });

  group('embedded 无轨道整帧', () {
    late PlayerBarDrawing drawing;
    setUp(() {
      drawing = renderPlayerBar(const PlayerBarState(), rowBounds, false, const UnitGlyphs());
    });

    test('整帧 40 条命令按 Qt append 顺序逐条相等', () {
      final List<List<Object?>> expected = <List<Object?>>[
        // render(): 底色
        <Object?>['fill', paper, 0.0, 600.0, 1000.0, 96.0],
        // song(): 无 cover → 6 条 ellipse（PlayerBar.cpp:110-115）
        <Object?>['ellipse', line, 28.0, 621.0, 54.0, 54.0],
        <Object?>['ellipse', paper, 30.0, 623.0, 50.0, 50.0],
        <Object?>['ellipse', line, 38.0, 631.0, 34.0, 34.0],
        <Object?>['ellipse', paper, 39.0, 632.0, 32.0, 32.0],
        <Object?>['ellipse', ink, 51.0, 644.0, 8.0, 8.0],
        <Object?>['ellipse', amber, 65.0, 627.0, 5.0, 5.0],
        // caption / title / detail（infoX=x+74=102，infoWidth=168-74=94）
        <Object?>['text', 'NOW PLAYING / 当前音轨', 102.0, 613.0, 11.0, 'regular', 0, muted],
        <Object?>['text', '尚未播放', 102.0, 632.0, 23.0, 'demibold', 0, ink],
        <Object?>['text', 'RHINE LAB / MUSIC DATABASE', 102.0, 665.0, 13.0, 'regular', 0, muted],
        // favorite(230, 648)：未确认喜欢 → path 用 muted（PlayerBar.cpp:158-172）
        <Object?>['save'],
        <Object?>['translate', 230.0, 649.0],
        <Object?>['path', heartPath, 1.5, muted, <Object?>[], 0],
        <Object?>['restore'],
        // controls(500, 648)：暂停态 → 实心三角（PlayerBar.cpp:67-88）
        <Object?>['save'],
        <Object?>['translate', 500.0, 648.0],
        <Object?>['path', prevPath, 1.5, ink, <Object?>[], 0],
        <Object?>['path', nextPath, 1.5, ink, <Object?>[], 0],
        <Object?>['fill', ink, -23.0, -23.0, 46.0, 46.0],
        <Object?>['fill-path', playPath, paper],
        <Object?>['restore'],
        // lyrics(bounds.right-470=530, 648)：centeredLabel("词",19)
        <Object?>['text', '词', 529.5, 652.75, 19.0, 'regular', 0, ink],
        // playbackMode(bounds.right-380=620, 648)：mode 空 → 顺序播放
        <Object?>['save'],
        <Object?>['translate', 620.0, 648.0],
        <Object?>['path', orderPath, 1.5, ink, <Object?>[], 0],
        <Object?>['restore'],
        // timeline(row)：position=0（durationMs=0），marker clamp 到 row.left
        <Object?>['fill', line, 0.0, 600.0, 1000.0, 3.0],
        <Object?>['fill', amber, 0.0, 600.0, 0.0, 3.0],
        <Object?>['fill', ink, 0.0, 596.0, 3.0, 11.0],
        <Object?>['text', '00:00', 343.0, 642.0, 11.0, 'regular', 0, muted],
        <Object?>['text', '00:00', 610.0, 642.0, 11.0, 'regular', 0, muted],
        // output(700, 600, 1000)：分隔线 + 标题 + 音量 + 队列
        <Object?>['fill', line, 678.0, 623.0, 1.0, 50.0],
        <Object?>['text', 'OUTPUT / 输出', 700.0, 629.0, 11.0, 'regular', 0, muted],
        <Object?>['text', '音量', 700.0, 653.0, 14.0, 'regular', 0, ink],
        <Object?>['fill', line, 758.0, 660.0, 100.0, 3.0],
        <Object?>['fill', ink, 758.0, 660.0, 100.0, 3.0],
        <Object?>['fill', ink, 935.0, 628.0, 19.0, 1.5],
        <Object?>['fill', ink, 935.0, 634.0, 19.0, 1.5],
        <Object?>['fill', ink, 935.0, 640.0, 13.0, 1.5],
        <Object?>['text', '队列', 932.0, 657.0, 11.0, 'regular', 0, ink],
      ];
      expect(drawing.commands.length, expected.length);
      expect(drawing.commands, expected);
    });

    test('hits：controls 三条 + mode + volume + queue，顺序与 Qt 一致', () {
      expect(drawing.hits.length, 6);
      expect(drawing.hits, <Map<String, Object?>>[
        <String, Object?>{
          'x': 411.0,
          'y': 624.0,
          'width': 44.0,
          'height': 48.0,
          'action': 'player:prev',
          'label': '上一首',
          'fixed': true,
        },
        <String, Object?>{
          'x': 477.0,
          'y': 625.0,
          'width': 46.0,
          'height': 46.0,
          'action': 'player:toggle',
          'label': '播放',
          'fixed': true,
        },
        <String, Object?>{
          'x': 545.0,
          'y': 624.0,
          'width': 44.0,
          'height': 48.0,
          'action': 'player:next',
          'label': '下一首',
          'fixed': true,
        },
        <String, Object?>{
          'x': 596.0,
          'y': 624.0,
          'width': 48.0,
          'height': 48.0,
          'action': 'player:mode',
          'label': '顺序播放，点击切换播放模式',
          'fixed': true,
        },
        <String, Object?>{
          'x': 758.0,
          'y': 647.0,
          'width': 100.0,
          'height': 28.0,
          'action': 'player:volume-fraction:0',
          'label': '音量',
          'fixed': true,
        },
        <String, Object?>{
          'x': 921.0,
          'y': 616.0,
          'width': 54.0,
          'height': 65.0,
          'action': 'player:open',
          'label': '播放队列',
          'fixed': true,
        },
      ]);
    });

    test('inputBounds 为行矩形上扩 6（row.adjusted(0,-6,0,0)）', () {
      expect(drawing.inputBounds.x, 0.0);
      expect(drawing.inputBounds.y, 594.0);
      expect(drawing.inputBounds.width, 1000.0);
      expect(drawing.inputBounds.height, 102.0);
      expect(drawing.inputBounds.right, 1000.0);
      expect(drawing.inputBounds.bottom, 696.0);
    });

    test('无轨道时无 seek、无 lyrics hit、无 like hit', () {
      expect(drawing.seek, isNull);
      expect(hitsOf(drawing, 'player:seek-fraction:0'), isEmpty);
      expect(hitsOf(drawing, 'player:lyrics'), isEmpty);
      expect(hitsOf(drawing, 'music:like-current'), isEmpty);
    });

    test('volume 矩形 = (x+58, y+47, 100, 28)', () {
      expect(drawing.volume, isNotNull);
      expect(drawing.volume!.x, 758.0);
      expect(drawing.volume!.y, 647.0);
      expect(drawing.volume!.width, 100.0);
      expect(drawing.volume!.height, 28.0);
    });

    test('embedded 不绘制 chrome：无品牌头、无状态尾', () {
      expect(textValues(drawing), isNot(contains('RHINE LAB')));
      expect(textValues(drawing), isNot(contains('莱茵生命 / 音频终端')));
      expect(textValues(drawing), isNot(contains('AUDIO ARCHIVE / RL–004')));
      expect(textValues(drawing), isNot(contains('播放已暂停')));
      // fill 计数 = 底色 1 + controls 1 + timeline 3 + output 6 = 11？→ 实际 1+1+3+6 = 11
      expect(commandsOf(drawing, 'fill').length, 11);
      expect(commandsOf(drawing, 'fill').first, <Object?>['fill', paper, 0.0, 600.0, 1000.0, 96.0]);
    });
  });

  group('floating 组合 chrome', () {
    const PlayerBarRect floatBounds = PlayerBarRect(0.0, 0.0, 1000.0, 96.0);
    late PlayerBarDrawing drawing;
    setUp(() {
      drawing = renderPlayerBar(
        const PlayerBarState(),
        rowBounds,
        false,
        const UnitGlyphs(),
        PlayerBarSurface.floating,
      );
    });

    test('chrome 六条命令紧跟底色，坐标以 bounds 为准（PlayerBar.cpp:89-103）', () {
      final PlayerBarDrawing floating = renderPlayerBar(
        const PlayerBarState(),
        floatBounds,
        false,
        const UnitGlyphs(),
        PlayerBarSurface.floating,
      );
      expect(floating.commands.take(7).toList(), <List<Object?>>[
        <Object?>['fill', paper, 0.0, 0.0, 1000.0, 96.0],
        <Object?>['text', 'RHINE LAB', 28.0, 6.0, 17.0, 'bold', 0, ink],
        <Object?>['text', '莱茵生命 / 音频终端', 173.0, 10.0, 11.0, 'regular', 0, ink],
        <Object?>['fill', line, 0.0, 43.0, 1000.0, 1.0],
        <Object?>['fill', line, 0.0, 140.0, 1000.0, 1.0],
        <Object?>['text', 'AUDIO ARCHIVE / RL–004', 28.0, 146.0, 11.0, 'regular', 0, muted],
        <Object?>['text', '播放已暂停', 772.0, 146.0, 11.0, 'regular', 0, muted],
      ]);
    });

    test('状态尾优先使用 state.status', () {
      final PlayerBarDrawing withStatus = renderPlayerBar(
        const PlayerBarState(status: '重连中'),
        floatBounds,
        false,
        const UnitGlyphs(),
        PlayerBarSurface.floating,
      );
      expect(textValues(withStatus), contains('重连中'));
      expect(textValues(withStatus), isNot(contains('播放已暂停')));
    });

    test('playing 且 status 空时状态尾为「正在播放」', () {
      final PlayerBarDrawing playing = renderPlayerBar(
        const PlayerBarState(playing: true),
        floatBounds,
        false,
        const UnitGlyphs(),
        PlayerBarSurface.floating,
      );
      expect(textValues(playing), contains('正在播放'));
    });

    test('chrome 分隔线用 line 色，尾部文案用 muted，品牌头用 ink', () {
      final PlayerBarDrawing floating = renderPlayerBar(
        const PlayerBarState(),
        floatBounds,
        false,
        const UnitGlyphs(),
        PlayerBarSurface.floating,
      );
      expect(floating.commands[3][1], line);
      expect(floating.commands[4][1], line);
      expect(floating.commands[5][7], muted);
      expect(floating.commands[6][7], muted);
      expect(floating.commands[1][7], ink);
      expect(floating.commands[2][7], ink);
    });

    test('行整体下移 HeaderHeight=44（在 bounds.y=600 上验证）', () {
      // bounds=(0,600,1000,96)：chrome 顶在 600，行顶在 644
      expect(drawing.inputBounds.y, 638.0);
      expect(drawing.inputBounds.height, 102.0);
      expect(commandsOf(drawing, 'ellipse').first,
          <Object?>['ellipse', line, 28.0, 665.0, 54.0, 54.0]);
      expect(commandsOf(drawing, 'translate').first, <Object?>['translate', 230.0, 693.0]);
      expect(indexOfCommand(drawing, <Object?>['fill', line, 0.0, 644.0, 1000.0, 3.0]),
          isNonNegative);
      expect(indexOfCommand(drawing, <Object?>['fill', line, 678.0, 667.0, 1.0, 50.0]),
          isNonNegative);
      // 状态尾 bottom = 600+44+96 = 740，文案 y = 746
      expect(textValues(drawing).contains('AUDIO ARCHIVE / RL–004'), isTrue);
      expect(indexOfCommand(drawing, <Object?>['text', '播放已暂停', 772.0, 746.0, 11.0, 'regular', 0, muted]),
          isNonNegative);
    });

    test('floating 的 hit 几何随行下移（bounds.y=600 → 行 644，中心 692）', () {
      final Map<String, Object?> toggle = hitOf(drawing, 'player:toggle');
      expect(toggle['y'], 669.0);
      expect(toggle['x'], 477.0);
      expect(hitOf(drawing, 'player:open')['y'], 660.0);
      expect(hitOf(drawing, 'player:prev')['y'], 668.0);
    });
  });

  group('有轨道与封面', () {
    late PlayerBarDrawing drawing;
    setUp(() {
      drawing = renderPlayerBar(
        const PlayerBarState(
          title: 'Song',
          artist: 'Artist',
          album: 'Album',
          cover: 'cover/key.png',
          hasTrack: true,
          playing: true,
          seekable: true,
          durationMs: 180000.0,
          positionMs: 45000.0,
        ),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
    });

    test('cover 非空时只发 image，不发 ellipse', () {
      expect(commandsOf(drawing, 'ellipse'), isEmpty);
      expect(commandsOf(drawing, 'image'),
          <List<Object?>>[<Object?>['image', 'cover/key.png', 28.0, 621.0, 54.0, 54.0]]);
    });

    test('player:lyrics 出现两次：歌曲行 + 词按钮', () {
      final List<Map<String, Object?>> lyricsHits = hitsOf(drawing, 'player:lyrics');
      expect(lyricsHits.length, 2);
      expect(lyricsHits[0]['x'], 28.0);
      expect(lyricsHits[0]['y'], 614.0); // y+14
      expect(lyricsHits[0]['width'], 168.0);
      expect(lyricsHits[0]['height'], 74.0);
      expect(lyricsHits[0]['label'], '当前歌曲歌词');
      expect(lyricsHits[1]['x'], 506.0); // bounds.right-470-24
      expect(lyricsHits[1]['y'], 624.0); // centerY-24
      expect(lyricsHits[1]['width'], 48.0);
      expect(lyricsHits[1]['height'], 48.0);
      expect(lyricsHits[1]['label'], '当前歌曲歌词');
      // 歌曲行 hit 在 image 之后；词按钮 hit 在 mode 命中之前
      expect(indexOfCommand(drawing, <Object?>['image', 'cover/key.png', 28.0, 621.0, 54.0, 54.0]),
          lessThan(indexOfCommand(drawing, <Object?>['save'])));
      expect(drawing.hits.indexOf(lyricsHits[1]),
          lessThan(drawing.hits.indexOf(hitOf(drawing, 'player:mode'))));
    });

    test('detail = artist / album；title 原样', () {
      expect(textValues(drawing), contains('Artist / Album'));
      expect(textValues(drawing), contains('Song'));
      expect(textValues(drawing), contains('NOW PLAYING / 当前音轨'));
    });

    test('只有 artist 时 detail 不带分隔符；只有 album 时保留 " / " 前缀', () {
      final PlayerBarDrawing artistOnly = renderPlayerBar(
        const PlayerBarState(artist: 'A', hasTrack: true),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
      expect(textValues(artistOnly), contains('A'));
      final PlayerBarDrawing albumOnly = renderPlayerBar(
        const PlayerBarState(album: 'B', hasTrack: true),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
      expect(textValues(albumOnly), contains(' / B'));
      expect(textValues(albumOnly), isNot(contains('RHINE LAB / MUSIC DATABASE')));
    });

    test('failed 优先于 loading 改写 caption，且 status 优先于固定文案', () {
      final PlayerBarDrawing failed = renderPlayerBar(
        const PlayerBarState(failed: true, loading: true, hasTrack: true),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
      expect(textValues(failed), contains('音频连接中断'));
      expect(textValues(failed), isNot(contains('BUFFERING / 正在缓冲')));

      final PlayerBarDrawing failedWithStatus = renderPlayerBar(
        const PlayerBarState(failed: true, status: '鉴权失败', hasTrack: true),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
      expect(textValues(failedWithStatus), contains('鉴权失败'));

      final PlayerBarDrawing loading = renderPlayerBar(
        const PlayerBarState(loading: true, hasTrack: true),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
      expect(textValues(loading), contains('BUFFERING / 正在缓冲'));
    });
  });

  group('播放键三态互斥', () {
    PlayerBarDrawing render(PlayerBarState state) =>
        renderPlayerBar(state, rowBounds, false, const UnitGlyphs());

    test('loading 三点（底色方块），不画双条/三角', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(loading: true, playing: true));
      expect(commandsOf(drawing, 'fill'), <List<Object?>>[
        <Object?>['fill', paper, 0.0, 600.0, 1000.0, 96.0],
        <Object?>['fill', ink, -23.0, -23.0, 46.0, 46.0],
        <Object?>['fill', paper, -11.0, -2.0, 4.0, 4.0],
        <Object?>['fill', paper, -2.0, -2.0, 4.0, 4.0],
        <Object?>['fill', paper, 7.0, -2.0, 4.0, 4.0],
        <Object?>['fill', line, 0.0, 600.0, 1000.0, 3.0],
        <Object?>['fill', amber, 0.0, 600.0, 0.0, 3.0],
        <Object?>['fill', ink, 0.0, 596.0, 3.0, 11.0],
        <Object?>['fill', line, 678.0, 623.0, 1.0, 50.0],
        <Object?>['fill', line, 758.0, 660.0, 100.0, 3.0],
        <Object?>['fill', ink, 758.0, 660.0, 100.0, 3.0],
        <Object?>['fill', ink, 935.0, 628.0, 19.0, 1.5],
        <Object?>['fill', ink, 935.0, 634.0, 19.0, 1.5],
        <Object?>['fill', ink, 935.0, 640.0, 13.0, 1.5],
      ]);
      expect(commandsOf(drawing, 'fill-path'), isEmpty);
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[5] == 18.0), isEmpty);
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[5] == 4.0).toList(),
          <List<Object?>>[
            <Object?>['fill', paper, -11.0, -2.0, 4.0, 4.0],
            <Object?>['fill', paper, -2.0, -2.0, 4.0, 4.0],
            <Object?>['fill', paper, 7.0, -2.0, 4.0, 4.0],
          ]);
    });

    test('playing 双条（paper），不画三点/三角', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(playing: true));
      expect(commandsOf(drawing, 'fill-path'), isEmpty);
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[5] == 18.0).toList(),
          <List<Object?>>[
            <Object?>['fill', paper, -6.0, -9.0, 3.0, 18.0],
            <Object?>['fill', paper, 3.0, -9.0, 3.0, 18.0],
          ]);
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[5] == 4.0), isEmpty);
    });

    test('暂停态画实心三角（fill-path，paper）', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState());
      expect(commandsOf(drawing, 'fill-path'),
          <List<Object?>>[<Object?>['fill-path', playPath, paper]]);
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[5] == 18.0), isEmpty);
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[5] == 4.0), isEmpty);
    });

    test('toggle 文案只看 playing，不看 loading', () {
      expect(
        hitOf(render(const PlayerBarState(loading: true, playing: true)), 'player:toggle')['label'],
        '暂停',
      );
      expect(
        hitOf(render(const PlayerBarState(loading: true, playing: false)), 'player:toggle')['label'],
        '播放',
      );
    });
  });

  group('clock 与 timeline 夹取', () {
    PlayerBarDrawing render(PlayerBarState state) =>
        renderPlayerBar(state, rowBounds, false, const UnitGlyphs());

    test('positionMs > durationMs 夹到 1：amber 满宽、marker 贴右', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(durationMs: 10000.0, positionMs: 25000.0));
      expect(indexOfCommand(drawing, <Object?>['fill', amber, 0.0, 600.0, 1000.0, 3.0]),
          isNonNegative);
      expect(indexOfCommand(drawing, <Object?>['fill', ink, 997.0, 596.0, 3.0, 11.0]),
          isNonNegative);
      // 时间标签仍用未夹取的原始 positionMs
      expect(textValues(drawing), containsAll(<String>['00:25', '00:10']));
    });

    test('负 positionMs 夹到 0：amber 零宽、marker 贴左、clock 归零', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(durationMs: 10000.0, positionMs: -5000.0));
      expect(indexOfCommand(drawing, <Object?>['fill', amber, 0.0, 600.0, 0.0, 3.0]),
          isNonNegative);
      expect(indexOfCommand(drawing, <Object?>['fill', ink, 0.0, 596.0, 3.0, 11.0]),
          isNonNegative);
      expect(textValues(drawing), containsAll(<String>['00:00', '00:10']));
    });

    test('durationMs = 0 时 position 恒 0，clock 仍格式化 duration', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(durationMs: 0.0, positionMs: 3600000.0));
      expect(indexOfCommand(drawing, <Object?>['fill', amber, 0.0, 600.0, 0.0, 3.0]),
          isNonNegative);
      expect(textValues(drawing), containsAll(<String>['60:00', '00:00']));
    });

    test('clock：59.999s 截断为 00:59；分钟超两位不截断', () {
      expect(textValues(render(const PlayerBarState(positionMs: 59999.0))), contains('00:59'));
      expect(textValues(render(const PlayerBarState(positionMs: 0.0))), contains('00:00'));
      expect(textValues(render(const PlayerBarState(positionMs: -1.0))), contains('00:00'));
      expect(textValues(render(const PlayerBarState(positionMs: 1000.0))), contains('00:01'));
      expect(textValues(render(const PlayerBarState(positionMs: 600000.0))), contains('10:00'));
      expect(textValues(render(const PlayerBarState(positionMs: 6000000.0))), contains('100:00'));
    });

    test('时间标签几何：center-157 / center+110，y = row.y+42', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(positionMs: 30000.0));
      final List<List<Object?>> texts = commandsOf(drawing, 'text');
      final List<Object?> position = texts.firstWhere((List<Object?> c) => c[1] == '00:30');
      expect(position[2], 343.0);
      expect(position[3], 642.0);
      expect(position[4], 11.0);
      expect(position[5], 'regular');
      expect(position[7], muted);
      final List<Object?> duration = texts.firstWhere((List<Object?> c) => c[1] == '00:00');
      expect(duration[2], 610.0);
    });
  });

  group('seek 命中区', () {
    PlayerBarDrawing render(PlayerBarState state) =>
        renderPlayerBar(state, rowBounds, false, const UnitGlyphs());

    test('seekable && durationMs > 0：seek 矩形 + 命中同时出现', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(seekable: true, durationMs: 180000.0, positionMs: 90000.0));
      expect(drawing.seek, isNotNull);
      expect(drawing.seek!.x, 0.0);
      expect(drawing.seek!.y, 594.0);
      expect(drawing.seek!.width, 1000.0);
      expect(drawing.seek!.height, 18.0);
      final Map<String, Object?> hit = hitOf(drawing, 'player:seek-fraction:0');
      expect(hit['x'], 0.0);
      expect(hit['y'], 594.0);
      expect(hit['width'], 1000.0);
      expect(hit['height'], 18.0);
      expect(hit['label'], '播放进度');
      expect(hit['fixed'], true);
      // seek 命中在 marker 之后、时间标签之前（PlayerBar.cpp:148-154）
      final int marker = indexOfCommand(drawing, <Object?>['fill', ink, 498.5, 596.0, 3.0, 11.0]);
      final int positionLabel = drawing.commands
          .indexOf(commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == '01:30'));
      expect(positionLabel, greaterThan(marker));
    });

    test('seekable 但 durationMs = 0：无 seek、无命中', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(seekable: true));
      expect(drawing.seek, isNull);
      expect(hitsOf(drawing, 'player:seek-fraction:0'), isEmpty);
    });

    test('不可 seek 但有时长：无 seek、无命中', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(durationMs: 180000.0, positionMs: 1000.0));
      expect(drawing.seek, isNull);
      expect(hitsOf(drawing, 'player:seek-fraction:0'), isEmpty);
    });
  });

  group('省略号 fit', () {
    const UnitGlyphs ten = UnitGlyphs(unit: 10.0);

    test('超宽标题按 Qt 规则 chop 后追加 U+2026', () {
      final PlayerBarDrawing drawing = renderPlayerBar(
        const PlayerBarState(title: 'AAAAAAAAAAAAAAAAAAAA', hasTrack: true),
        rowBounds,
        false,
        ten,
      );
      // infoWidth = 94，unit=10：chop 到 8 字符 + "…" = 90 <= 94
      expect(textValues(drawing), contains('AAAAAAAA…'));
      expect(textValues(drawing), contains('NOW PLAY…'));
    });

    test('未超宽时不改写、不加省略号', () {
      final PlayerBarDrawing drawing = renderPlayerBar(
        const PlayerBarState(title: 'ABC', hasTrack: true),
        rowBounds,
        false,
        ten,
      );
      // title 行 size=23，未被 chop
      final List<Object?> title =
          commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == 'ABC');
      expect(title[4], 23.0);
      expect(textValues(drawing), isNot(contains('ABC…')));
    });

    test('宽度连省略号都放不下时仍追加省略号（Qt chop 到空串的语义）', () {
      final PlayerBarDrawing drawing = renderPlayerBar(
        const PlayerBarState(title: 'AB', hasTrack: true),
        const PlayerBarRect(0.0, 600.0, 600.0, 96.0),
        false,
        ten,
      );
      // infoWidth = 76-74 = 2：width("AB…")=30 > 2 → chop 至空 → "…"
      expect(textValues(drawing), contains('…'));
      expect(textValues(drawing), isNot(contains('AB')));
    });

    test('fit 通过 GlyphsPort.width 反复度量（含 value+"…" 探测）', () {
      final RecordingGlyphs glyphs = RecordingGlyphs(unit: 10.0);
      renderPlayerBar(
        const PlayerBarState(title: 'ABCDEFGHIJKLMNOP', hasTrack: true),
        rowBounds,
        false,
        glyphs,
      );
      expect(glyphs.widthCalls, isNot(isEmpty));
      expect(glyphs.widthCalls.any((String v) => v.endsWith('…')), isTrue);
      expect(glyphs.widthCalls, contains('ABCDEFGHIJKLMNOP'));
      // 逐字 chop：每次只去掉一个 UTF-16 code unit
      expect(glyphs.widthCalls, contains('ABCDEFGHIJKLMNO…'));
    });

    test('centeredLabel 用 bounds 反推左上角（Qt PlayerBar.cpp:62-66）', () {
      final PlayerBarDrawing drawing = renderPlayerBar(
        const PlayerBarState(hasTrack: true),
        rowBounds,
        false,
        const UnitGlyphs(unit: 2.0),
      );
      // bounds: x=0, y=-14.25, width=2, height=19；center=(530,648)
      // x = 530-0-1 = 529；y = 648+14.25-9.5 = 652.75
      final List<Object?> word =
          commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == '词');
      expect(word[2], 529.0);
      expect(word[3], 652.75);
      expect(word[4], 19.0);
      expect(word[6], 0);
    });
  });

  group('hits 契约', () {
    late PlayerBarDrawing drawing;
    setUp(() {
      drawing = renderPlayerBar(
        const PlayerBarState(
          title: 'Song',
          hasTrack: true,
          canLike: true,
          liked: true,
          likeKnown: true,
          seekable: true,
          durationMs: 1000.0,
          positionMs: 500.0,
          mode: 'shuffle',
          loading: true,
        ),
        rowBounds,
        false,
        const UnitGlyphs(),
      );
    });

    test('每条 hit 恰为七个键且顺序固定（x/y/width/height/action/label/fixed）', () {
      expect(drawing.hits, isNotEmpty);
      for (final Map<String, Object?> hit in drawing.hits) {
        expect(hit.keys.toList(), <String>[
          'x',
          'y',
          'width',
          'height',
          'action',
          'label',
          'fixed',
        ]);
        expect(hit['x'], isA<double>());
        expect(hit['y'], isA<double>());
        expect(hit['width'], isA<double>());
        expect(hit['height'], isA<double>());
        expect(hit['action'], isA<String>());
        expect(hit['label'], isA<String>());
        expect(hit['fixed'], true);
      }
    });

    test('全部矩形为正尺寸，且 PlayerBar 每条 hit 都带 fixed:true', () {
      for (final Map<String, Object?> hit in drawing.hits) {
        expect(hit['fixed'], isTrue);
        expect(hit['width'] as double, greaterThan(0.0));
        expect(hit['height'] as double, greaterThan(0.0));
      }
    });

    test('全命中顺序：song 歌词 → like → prev/toggle/next → 词 → mode → seek → volume → open', () {
      expect(
        drawing.hits.map((Map<String, Object?> h) => h['action']).toList(),
        <String>[
          'player:lyrics', // song() 先于 favorite()
          'music:like-current',
          'player:prev',
          'player:toggle',
          'player:next',
          'player:lyrics', // lyrics() 按钮
          'player:mode',
          'player:seek-fraction:0',
          'player:volume-fraction:0',
          'player:open',
        ],
      );
      expect(drawing.hits.length, 10);
    });
  });

  group('favorite 三态文案与颜色', () {
    PlayerBarDrawing render(PlayerBarState state) =>
        renderPlayerBar(state, rowBounds, false, const UnitGlyphs());

    test('canLike=false 时不发命中', () {
      expect(hitsOf(render(const PlayerBarState()), 'music:like-current'), isEmpty);
    });

    test('likeKnown=true 未喜欢 → 「喜欢当前歌曲」，path 用 ink', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(canLike: true, likeKnown: true));
      final Map<String, Object?> hit = hitOf(drawing, 'music:like-current');
      expect(hit['label'], '喜欢当前歌曲');
      expect(hit['x'], 206.0);
      expect(hit['y'], 624.0);
      expect(hit['width'], 48.0);
      expect(hit['height'], 48.0);
      expect(indexOfCommand(drawing, <Object?>['path', heartPath, 1.5, ink, <Object?>[], 0]),
          isNonNegative);
      expect(commandsOf(drawing, 'fill-path'), hasLength(1));
    });

    test('likeKnown=true 已喜欢 → 「取消喜欢当前歌曲」，heart 走 fill-path', () {
      final PlayerBarDrawing drawing =
          render(const PlayerBarState(canLike: true, liked: true, likeKnown: true));
      expect(hitOf(drawing, 'music:like-current')['label'], '取消喜欢当前歌曲');
      expect(commandsOf(drawing, 'fill-path'), <List<Object?>>[
        <Object?>['fill-path', heartPath, ink],
        <Object?>['fill-path', playPath, paper],
      ]);
    });

    test('likeKnown=false → 「核实并切换当前歌曲喜欢状态」，颜色 muted 但填充仍只看 liked', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(canLike: true, liked: true));
      expect(hitOf(drawing, 'music:like-current')['label'], '核实并切换当前歌曲喜欢状态');
      // Qt PlayerBar.cpp:161-163：path(heart, likeKnown ? ink : muted, state.liked)
      // 颜色看 likeKnown、填充看 liked，两者互相独立。
      expect(commandsOf(drawing, 'fill-path'), <List<Object?>>[
        <Object?>['fill-path', heartPath, muted],
        <Object?>['fill-path', playPath, paper],
      ]);
      expect(
        commandsOf(drawing, 'path').where((List<Object?> c) => c[1] == heartPath),
        isEmpty,
      );
    });

    test('likeKnown=false 且未喜欢 → heart 走 path 且用 muted', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(canLike: true));
      expect(indexOfCommand(drawing, <Object?>['path', heartPath, 1.5, muted, <Object?>[], 0]),
          isNonNegative);
      expect(commandsOf(drawing, 'fill-path'), <List<Object?>>[
        <Object?>['fill-path', playPath, paper],
      ]);
    });
  });

  group('playbackMode 四态', () {
    PlayerBarDrawing render(String mode) =>
        renderPlayerBar(PlayerBarState(mode: mode), rowBounds, false, const UnitGlyphs());

    test('shuffle：随机播放 + 交叉箭头', () {
      final PlayerBarDrawing drawing = render('shuffle');
      expect(hitOf(drawing, 'player:mode')['label'], '随机播放，点击切换播放模式');
      expect(indexOfCommand(drawing, <Object?>['path', shufflePath, 1.5, ink, <Object?>[], 0]),
          isNonNegative);
      expect(textValues(drawing), isNot(contains('1')));
    });

    test('all：列表循环 + 环形箭头', () {
      final PlayerBarDrawing drawing = render('all');
      expect(hitOf(drawing, 'player:mode')['label'], '列表循环，点击切换播放模式');
      expect(indexOfCommand(drawing, <Object?>['path', loopPath, 1.5, ink, <Object?>[], 0]),
          isNonNegative);
      expect(textValues(drawing), isNot(contains('1')));
    });

    test('one：单曲循环 + 环形箭头 + 居中 "1"', () {
      final PlayerBarDrawing drawing = render('one');
      expect(hitOf(drawing, 'player:mode')['label'], '单曲循环，点击切换播放模式');
      final int loopIndex =
          indexOfCommand(drawing, <Object?>['path', loopPath, 1.5, ink, <Object?>[], 0]);
      final List<Object?> one =
          commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == '1');
      final int oneIndex = drawing.commands.indexOf(one);
      // 该命令位于 translate(620,648) 帧内，携带局部坐标：0-0-0.5 / 0+9-6
      expect(one[2], -0.5);
      expect(one[3], 3.0);
      expect(one[4], 12.0);
      expect(one[5], 'demibold');
      expect(one[7], ink);
      // "1" 紧跟 loop path、其后立即 restore（PlayerBar.cpp:183-197）
      expect(oneIndex, loopIndex + 1);
      expect(drawing.commands[oneIndex + 1], <Object?>['restore']);
      expect(oneIndex, lessThan(indexOfCommand(drawing, <Object?>['fill', amber, 0.0, 600.0, 0.0, 3.0])));
    });

    test('其它取值（含空串）：顺序播放 + 列表箭头', () {
      for (final String mode in <String>['', 'off', 'sequential']) {
        final PlayerBarDrawing drawing = render(mode);
        expect(hitOf(drawing, 'player:mode')['label'], '顺序播放，点击切换播放模式');
        expect(indexOfCommand(drawing, <Object?>['path', orderPath, 1.5, ink, <Object?>[], 0]),
            isNonNegative);
      }
    });
  });

  group('output 音量与队列', () {
    PlayerBarDrawing render(PlayerBarState state) =>
        renderPlayerBar(state, rowBounds, false, const UnitGlyphs());

    test('applicationVolume=true：音量命中 + 双 fill（line/ink）', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState());
      expect(drawing.volume, isNotNull);
      expect(textValues(drawing), contains('音量'));
      expect(hitOf(drawing, 'player:volume-fraction:0')['label'], '音量');
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[2] == 758.0).toList(),
          <List<Object?>>[
            <Object?>['fill', line, 758.0, 660.0, 100.0, 3.0],
            <Object?>['fill', ink, 758.0, 660.0, 100.0, 3.0],
          ]);
    });

    test('applicationVolume=false：无 volume 矩形、无命中、无音量条', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState(applicationVolume: false));
      expect(drawing.volume, isNull);
      expect(hitsOf(drawing, 'player:volume-fraction:0'), isEmpty);
      expect(textValues(drawing), contains('系统音量'));
      expect(textValues(drawing), isNot(contains('音量')));
      expect(commandsOf(drawing, 'fill').where((List<Object?> c) => c[2] == 758.0), isEmpty);
    });

    test('volume 夹取到 0..1', () {
      expect(
        indexOfCommand(
            render(const PlayerBarState(volume: 3.0)),
            <Object?>['fill', ink, 758.0, 660.0, 100.0, 3.0]),
        isNonNegative,
      );
      expect(
        indexOfCommand(
            render(const PlayerBarState(volume: -2.0)),
            <Object?>['fill', ink, 758.0, 660.0, 0.0, 3.0]),
        isNonNegative,
      );
      expect(
        indexOfCommand(
            render(const PlayerBarState(volume: 0.25)),
            <Object?>['fill', ink, 758.0, 660.0, 25.0, 3.0]),
        isNonNegative,
      );
    });

    test('queue 图标三条 + 「队列」标签 + 命中（right-65 派生）', () {
      final PlayerBarDrawing drawing = render(const PlayerBarState());
      final List<List<Object?>> fills = commandsOf(drawing, 'fill');
      expect(fills.sublist(fills.length - 3), <List<Object?>>[
        <Object?>['fill', ink, 935.0, 628.0, 19.0, 1.5],
        <Object?>['fill', ink, 935.0, 634.0, 19.0, 1.5],
        <Object?>['fill', ink, 935.0, 640.0, 13.0, 1.5],
      ]);
      expect(textValues(drawing), contains('队列'));
      expect(drawing.hits.last['action'], 'player:open');
      expect(drawing.hits.last['x'], 921.0);
      expect(drawing.hits.last['width'], 54.0);
      expect(drawing.hits.last['height'], 65.0);
    });
  });

  group('dark 调色板', () {
    test('dark 只换 paper/ink/muted/line，amber 不变', () {
      final PlayerBarDrawing drawing = renderPlayerBar(
        const PlayerBarState(seekable: true, durationMs: 1000.0, positionMs: 500.0, hasTrack: true),
        rowBounds,
        true,
        const UnitGlyphs(),
      );
      final List<List<Object?>> fills = commandsOf(drawing, 'fill');
      expect(fills.first, <Object?>['fill', paperDark, 0.0, 600.0, 1000.0, 96.0]);
      expect(fills, contains(<Object?>['fill', lineDark, 0.0, 600.0, 1000.0, 3.0]));
      expect(fills, contains(<Object?>['fill', amber, 0.0, 600.0, 500.0, 3.0]));
      expect(indexOfCommand(drawing, <Object?>['fill', inkDark, 498.5, 596.0, 3.0, 11.0]),
          isNonNegative);
      expect(
        commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == 'NOW PLAYING / 当前音轨')[7],
        mutedDark,
      );
      expect(commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == '词')[7], inkDark);
      expect(indexOfCommand(drawing, <Object?>['path', prevPath, 1.5, inkDark, <Object?>[], 0]),
          isNonNegative);
    });
  });

  group('泛化几何与纯函数性', () {
    test('bounds.x / bounds.y 全程参与，不假设原点为 0', () {
      final PlayerBarDrawing drawing = renderPlayerBar(
        const PlayerBarState(hasTrack: true, seekable: true, durationMs: 2000.0, positionMs: 500.0),
        const PlayerBarRect(40.0, 10.0, 1000.0, 96.0),
        false,
        const UnitGlyphs(),
      );
      expect(commandsOf(drawing, 'ellipse').first,
          <Object?>['ellipse', line, 68.0, 31.0, 54.0, 54.0]);
      expect(drawing.inputBounds.x, 40.0);
      expect(drawing.inputBounds.y, 4.0);
      expect(drawing.inputBounds.width, 1000.0);
      expect(drawing.inputBounds.height, 102.0);
      // center = 40+500 = 540 → prev hit x = 451
      expect(hitOf(drawing, 'player:prev')['x'], 451.0);
      // seek 与 row 同宽同 x
      expect(drawing.seek!.x, 40.0);
      expect(drawing.seek!.y, 4.0);
      // timeline 中心 540 → 540-157 = 383
      expect(commandsOf(drawing, 'text').firstWhere((List<Object?> c) => c[1] == '00:00')[2], 383.0);
    });

    test('render 是纯函数：重复调用同结果，且不改 state', () {
      const PlayerBarState state =
          PlayerBarState(title: 'S', positionMs: 1000.0, durationMs: 4000.0);
      final PlayerBarDrawing first = renderPlayerBar(state, rowBounds, false, const UnitGlyphs());
      final PlayerBarDrawing second = renderPlayerBar(state, rowBounds, false, const UnitGlyphs());
      expect(first.commands, second.commands);
      expect(first.hits, second.hits);
      expect(state.title, 'S');
      expect(state.positionMs, 1000.0);
      expect(state.durationMs, 4000.0);
    });

    test('PlayerBarRect 提供 Qt QRectF 的 left/right/center 语义', () {
      const PlayerBarRect rect = PlayerBarRect(40.0, 10.0, 1000.0, 96.0);
      expect(rect.left, 40.0);
      expect(rect.top, 10.0);
      expect(rect.right, 1040.0);
      expect(rect.bottom, 106.0);
      expect(rect.centerX, 540.0);
      expect(rect.centerY, 58.0);
      expect(rect, const PlayerBarRect(40.0, 10.0, 1000.0, 96.0));
    });
  });
}
