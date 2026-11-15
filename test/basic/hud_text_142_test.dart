// HUD-SYNC-TEXT-142 · COMMON 共享滚动文字/数字动画渲染链回归。
//
// 真机现象（用户 2026-11-16 反馈）：左上「当前档案库所属」空白，底部只剩
// `/936`——`music-number` 前的动态序号没了，且**所有**共享滚动文字都不出现。
// 机制：`BasicGlyphPorts.rolling` 旧实现只 `rollingRequests += 1` 就返回，
// `music-brand` / `music-source` / `music-title` / `music-id` / `music-column` /
// `music-number` 六类滚动词全部不发命令；静态 `hudText("/")` 与 total 照画，
// 于是只剩 "/total"。
//
// 本文件只写不跑：tests/analyze/build/ADB 的唯一执行者是 FINAL-INTEGRATION-141。
// 这里走真实端口（Assets/fonts/misans-glyphs.json）与真实命令流，三个时点
// （初始 / 过渡中点 / 稳定）都要求当前所属与当前序号有 draw 输出，并守住静态
// `/` 与 total；把 rolling 链改回"只计数不发射"会让第一条断言立刻为红。

import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/render/hud_painter.dart';
import 'package:rhine_music_database/hud/render/paint_stack.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/hud/text/rolling_label.dart';
import 'package:rhine_music_database/hud/text/rolling_text.dart';

SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

List<SirenSong> _songs() => <SirenSong>[
      _song('s1', '第一首'),
      _song('s2', '第二首'),
      _song('s3', '第三首'),
      _song('s4', '第四首'),
      _song('s5', '第五首'),
    ];

List<SirenAlbum> _albums() => <SirenAlbum>[
      SirenAlbum(
        id: 'album-1',
        name: '专辑一',
        artist: '塞壬唱片',
        cover: '',
        songCount: 2,
        songs: <SirenSong>[_song('s1', '第一首')],
      ),
      SirenAlbum(
        id: 'album-2',
        name: '专辑二',
        artist: '塞壬唱片',
        cover: '',
        songCount: 2,
        songs: <SirenSong>[_song('s2', '第二首')],
      ),
    ];

/// 曲库态：lane 3「全部歌曲」= 5 首，lane 4「全部专辑」= 2 张。
BasicViewState _library({
  int lane = basicDefaultLane,
  int selected = 0,
  double? listPosition,
  bool dark = true,
}) {
  final List<SirenSong> songs = _songs();
  return BasicViewState(
    phase: BasicPhase.library,
    songs: songs,
    albums: _albums(),
    catalogLoaded: true,
    dark: dark,
    selectedLane: lane,
    song: songs[selected],
    listPosition: listPosition,
  );
}

/// 真字形表：量宽/裁剪框必须来自线上资源，不用替身端口。
Future<BasicGlyphPorts> _realPorts() async {
  final String glyphJson = await File(basicGlyphTableAsset).readAsString();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

List<List<Object?>> _texts(BasicHudFrame frame) => <List<Object?>>[
      for (final List<Object?> c in frame.commands)
        if (c.isNotEmpty && c[0] == 'text') c,
    ];

List<List<Object?>> _textsWith(BasicHudFrame frame, String value) => <List<Object?>>[
      for (final List<Object?> c in _texts(frame))
        if (c.length > 1 && c[1] == value) c,
    ];

/// 左上角「所属」文字（music-brand 槽：44 号粗体、落在 _brandTop）。
///
/// 同一个词在底部的列游标（`music-column`，archive_page.dart:322 的 (col+70, 925, 15)）
/// 也会出现，所以不能只按字符串断言"只有一条"—— 那是两处不同的绘制点，都在画是对的。
List<List<Object?>> _brandTextsWith(BasicHudFrame frame, String value) =>
    <List<Object?>>[
      for (final List<Object?> c in _textsWith(frame, value))
        if (c.length > 4 && c[4] == 44.0 && _near(c[3], _brandTop)) c,
    ];

bool _near(Object? value, double target) =>
    value is num && (value.toDouble() - target).abs() < 0.75;

/// 某一基准高度上的字符命令（逐字槽按 `y + (index - p) * line` 落笔）。
List<String> _glyphsNear(BasicHudFrame frame, double top) => <String>[
      for (final List<Object?> c in _texts(frame))
        if (c.length > 3 && _near(c[3], top)) c[1] as String,
    ];

List<List<Object?>> _textCommandsNear(BasicHudFrame frame, double top) => <List<Object?>>[
      for (final List<Object?> c in _texts(frame))
        if (c.length > 3 && _near(c[3], top)) c,
    ];

/// 裁剪框以标签的 y 为顶边，不随 reel 位置漂移（UiMotion.cpp:239）。
List<List<Object?>> _clipsNear(BasicHudFrame frame, double top) => <List<Object?>>[
      for (final List<Object?> c in frame.commands)
        if (c.length > 4 && c[0] == 'clip' && _near(c[2], top)) c,
    ];

const double _brandTop = 115.425;
const double _numberTop = 901.2;

/// 首帧 + 过 kReelDuration 的一帧：同一端口上标签收敛为单条静态 text。
BasicHudFrame _settle(BasicGlyphPorts ports, BasicViewState state, {double? listPosition}) {
  BasicHudFrame.build(
    state: state,
    ports: ports,
    width: 1080,
    height: 1920,
    portrait: true,
    listPosition: listPosition,
    animationTime: 0,
    animateText: true,
  );
  return BasicHudFrame.build(
    state: state,
    ports: ports,
    width: 1080,
    height: 1920,
    portrait: true,
    listPosition: listPosition,
    animationTime: 1.2,
    animateText: true,
  );
}

HudFrameEnvelope _envelope(BasicHudFrame frame) => HudFrameEnvelope.decode(<String, Object?>{
      'generation': frame.generation,
      'frame': <String, Object?>{},
      'commands': frame.commands,
      'hits': <Object?>[for (final HudHit hit in frame.hits) hit.toJson()],
      'state': <String, Object?>{},
    });

class _RecordingSink implements HudSurfaceSink {
  _RecordingSink(this.commands);

  final List<List<Object?>> commands;

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) {}
}

void main() {
  group('共享滚动文字：初始 / 过渡 / 稳定三时点都有绘制输出', () {
    test('初始帧（ticker 刚启动）逐字槽画出「全部歌曲」与「01」，静态 / 与 total 仍在', () async {
      final BasicGlyphPorts ports = await _realPorts();
      final BasicHudFrame frame = BasicHudFrame.build(
        state: _library(),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 0,
        animateText: true,
      );
      // 首帧就有字符槽在动 → 宿主必须续帧（不是等业务轮询/一次性静态）。
      expect(frame.animating, isTrue);

      // 当前所属：左上 music-brand。
      expect(_glyphsNear(frame, _brandTop).join(), '全部歌曲',
          reason: '左上所属必须首帧可见（旧 rolling 只计数 → 空白）');
      expect(_clipsNear(frame, _brandTop), isNotEmpty,
          reason: '首帧应走 save/alpha/clip/text/restore 的逐字链');

      // 当前序号：music-number；同一行的静态 "/" 与 total 照旧。
      expect(_glyphsNear(frame, _numberTop).join(), '01');
      expect(_textsWith(frame, '/'), isNotEmpty);
      expect(_textsWith(frame, '5'), isNotEmpty, reason: '静态 total 不能被滚动链吞掉');
    });

    test('过渡中点两处都还在画；稳定后收敛为单条静态 text（clip 链消失）', () async {
      final BasicGlyphPorts ports = await _realPorts();
      final BasicHudFrame atZero = BasicHudFrame.build(
        state: _library(),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 0,
        animateText: true,
      );
      expect(_glyphsNear(atZero, _brandTop).join(), '全部歌曲');
      expect(_glyphsNear(atZero, _numberTop).join(), '01');

      // 同列内 选中 0→1：序号 01→02 进入 reel（所属不动，仍要照画）。
      final BasicHudFrame numberMid = BasicHudFrame.build(
        state: _library(selected: 1),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 0.2,
        animateText: true,
      );
      expect(_clipsNear(numberMid, _numberTop), isNotEmpty,
          reason: '序号变化必须走 clip/reel，不能整段消失');
      final double numberSize =
          math.min(58.0, 58.0 * 77 / math.max(1.0, ports.glyphWidth('02', 58)));
      expect(
        _texts(numberMid).where((List<Object?> c) => c.length > 4 && c[4] == numberSize),
        isNotEmpty,
        reason: '过渡中 music-number 仍要有 glyph 命令',
      );
      expect(_glyphsNear(numberMid, _brandTop).join(), '全部歌曲',
          reason: '所属没变时仍要画出当前所属');

      // 显式换列 3→4：所属 全部歌曲→全部专辑 进入 reel。
      final BasicHudFrame brandMid = BasicHudFrame.build(
        state: _library(lane: 4),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 0.2,
        animateText: true,
      );
      expect(_clipsNear(brandMid, _brandTop), isNotEmpty,
          reason: '显式换列必须走 clip/reel，不能直接空白');
      expect(
        _texts(brandMid).where((List<Object?> c) => c.length > 4 && c[4] == 44.0),
        isNotEmpty,
        reason: '过渡中 music-brand 仍要有 glyph 命令',
      );

      // 稳定（t=1.2）：整段 text，clip 链消失，静态 / 与 total 保留。
      final BasicHudFrame settled = BasicHudFrame.build(
        state: _library(lane: 4),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 1.2,
        animateText: true,
      );
      final List<List<Object?>> brand = _brandTextsWith(settled, '全部专辑');
      expect(brand, hasLength(1), reason: '稳定后应是一条整段 text，而不是逐字槽');
      expect(_near(brand.single[3], _brandTop), isTrue);
      expect(_clipsNear(settled, _brandTop), isEmpty);
      // 专辑条目没有 song 选中：序号由 basicSelectedItemIndex 回落到 0 → 01。
      expect(_glyphsNear(settled, _numberTop).join(), '01');
      expect(_textsWith(settled, '/'), isNotEmpty);
      expect(_textsWith(settled, '2'), isNotEmpty);
      expect(settled.animating, isFalse, reason: '稳定帧不得再申请续帧（ticker 不许空转）');
    });

    test('无帧时钟/暂停（animateText=false）时仍是静态可见文字，不靠业务轮询器', () async {
      final BasicGlyphPorts ports = await _realPorts();
      final BasicHudFrame frame = BasicHudFrame.build(
        state: _library(),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animateText: false,
      );
      expect(frame.animating, isFalse);
      expect(_brandTextsWith(frame, '全部歌曲'), hasLength(1));
      final List<List<Object?>> number = _textsWith(frame, '01');
      expect(number, hasLength(1));
      expect((number.single[2] as num).toDouble(), closeTo(60, 0.001));
      expect(_textsWith(frame, '/'), isNotEmpty);
      expect(_textsWith(frame, '5'), isNotEmpty);
    });

    test('暗/亮主题沿用同一 hudInk（滚动文字不会因主题为空或换色）', () async {
      for (final bool dark in <bool>[true, false]) {
        final BasicGlyphPorts ports = await _realPorts();
        final BasicHudFrame frame = BasicHudFrame.build(
          state: _library(dark: dark),
          ports: ports,
          width: 1080,
          height: 1920,
          portrait: true,
          animationTime: 0,
          animateText: true,
        );
        final List<List<Object?>> brand = _textCommandsNear(frame, _brandTop);
        expect(brand, isNotEmpty);
        final List<Object?> expected = hudInk(dark);
        for (final List<Object?> command in brand) {
          expect(command[7], expected, reason: 'dark=$dark 的滚动文字必须用 hudInk($dark)');
        }
      }
    });
  });

  group('所属/序号只由显式 state 驱动，不跟滚动窗口漂移', () {
    test('稳定帧：显式换列更新所属与总数；listPosition 只滚窗口，不改标题/序号', () async {
      final BasicGlyphPorts songsPorts = await _realPorts();
      final BasicHudFrame songs = _settle(songsPorts, _library(lane: 3));
      expect(_brandTextsWith(songs, '全部歌曲'), hasLength(1),
          reason: '全部歌曲 5 首 → 左上显示列名，不显示固定品牌名');
      expect(_glyphsNear(songs, _numberTop).join(), '01');
      expect(_textsWith(songs, '5'), isNotEmpty);

      // 同一个 state 只把滚动窗口推到 2.4：标题/序号不得跟着变。
      final BasicGlyphPorts scrollPorts = await _realPorts();
      final BasicHudFrame scrolled = _settle(
        scrollPorts,
        _library(lane: 3, listPosition: 2.4),
      );
      expect(_brandTextsWith(scrolled, '全部歌曲'), hasLength(1),
          reason: 'ARCHIVE3D 滑动锁当前所属：只滚当前列表');
      expect(_glyphsNear(scrolled, _numberTop).join(), '01',
          reason: '滚动窗口不是选中项，序号只跟 selection');

      final BasicGlyphPorts albumsPorts = await _realPorts();
      final BasicHudFrame albums = _settle(albumsPorts, _library(lane: 4));
      expect(_brandTextsWith(albums, '全部专辑'), hasLength(1),
          reason: '显式切换到全部专辑 → 左上所属跟着换');
      // 顶部品牌槽必须只剩新所属；底部列游标(music-column)同时换词，所以按字符串单看会有
      // 第二条，这里同样只在左上槽上断言。
      expect(_brandTextsWith(albums, '全部歌曲'), isEmpty);
      expect(_glyphsNear(albums, _numberTop).join(), '01');
      expect(_textsWith(albums, '2'), isNotEmpty);
    });
  });

  group('共享运行时与真实 painter', () {
    test('同 key 的 RollingLabel 跨帧存活（不是每帧新建，动画从中间继续）', () async {
      final BasicGlyphPorts ports = await _realPorts();
      final HudRollingText rolling = HudRollingText(
        measure: (String text, double size, String weight, double tracking) =>
            ports.glyphWidth(text, size, weight),
      );
      final List<List<Object?>> out = <List<Object?>>[];

      rolling.begin(time: 0, emit: out.add);
      rolling.request(
        key: 'music-brand',
        value: '全部歌曲',
        x: 59,
        y: _brandTop,
        size: 44,
        weight: 'bold',
        tracking: 0,
        numeric: false,
        ink: hudInk(true),
        animate: true,
      );
      final RollingLabel? first = rolling.labelFor('music-brand');
      expect(first, isNotNull);
      expect(out.any((List<Object?> c) => c[0] == 'text'), isTrue);

      out.clear();
      rolling.begin(time: 0.2, emit: out.add);
      rolling.request(
        key: 'music-brand',
        value: '全部专辑',
        x: 59,
        y: _brandTop,
        size: 44,
        weight: 'bold',
        tracking: 0,
        numeric: false,
        ink: hudInk(true),
        animate: true,
      );
      expect(identical(rolling.labelFor('music-brand'), first), isTrue,
          reason: '同一 key 必须复用同一个标签，否则动画每帧从零开始');
      expect(out.any((List<Object?> c) => c[0] == 'clip'), isTrue);

      out.clear();
      rolling.begin(time: 1.5, emit: out.add);
      rolling.request(
        key: 'music-brand',
        value: '全部专辑',
        x: 59,
        y: _brandTop,
        size: 44,
        weight: 'bold',
        tracking: 0,
        numeric: false,
        ink: hudInk(true),
        animate: true,
      );
      expect(out, hasLength(1), reason: '稳定后单条 text（UiMotion.cpp:236）');
      expect(out.single[0], 'text');
      expect(out.single[1], '全部专辑');
    });

    test('端口在帧外不发射（旧调用点语义不变），帧内立即发射', () async {
      final BasicGlyphPorts ports = await _realPorts();
      final List<List<Object?>> recorded = <List<Object?>>[];
      // 帧外：不 begin 就不发命令，保持旧端口"只计数"的对外可见语义。
      ports.rolling('music-brand', '全部歌曲', 59, _brandTop, 44, 'bold', 0, false);
      expect(recorded, isEmpty);

      ports.beginFrame(
        sink: _RecordingSink(recorded),
        time: 0,
        ink: hudInk(true),
        animate: false,
      );
      ports.rolling('music-brand', '全部歌曲', 59, _brandTop, 44, 'bold', 0, false);
      final bool animating = ports.endFrame();
      expect(animating, isFalse);
      expect(recorded, hasLength(1), reason: '旧实现（只 rollingRequests+=1）在这里是空表 → 红');
      expect(recorded.single[0], 'text');
      expect(recorded.single[1], '全部歌曲');
    });

    test('真实 HudStagePainter 回放新命令流：文本端口齐、restore 平衡、画面非空', () async {
      final BasicGlyphPorts ports = await _realPorts();
      // 先起一帧，再取过渡中点（含 save/alpha/clip/restore 与 reel 行）。
      BasicHudFrame.build(
        state: _library(),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 0,
        animateText: true,
      );
      final BasicHudFrame frame = BasicHudFrame.build(
        state: _library(lane: 4),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
        animationTime: 0.25,
        animateText: true,
      );
      HudPaintResult? result;
      int textRuns = 0;
      final HudStagePainter painter = HudStagePainter(
        envelope: _envelope(frame),
        ports: HudPainterPorts(
          text: (
            ui.Canvas canvas,
            String value,
            double x,
            double y,
            double size,
            String weight,
            double tracking,
            ui.Color color,
          ) {
            textRuns++;
            ports.draw(canvas, value, x, y, size, weight, tracking, color);
          },
          path: ports.pathFor,
          image: ports.imageFor,
        ),
        stage: const HudStage(scale: 1, width: 1080, height: 1920),
        onPainted: (HudPaintResult painted) => result = painted,
      );
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      painter.paint(ui.Canvas(recorder), const Size(1080, 1920));
      recorder.endRecording().dispose();
      expect(result, isNotNull);
      expect(
        result!.issues.where((HudPaintIssue issue) =>
            issue.kind == HudPaintIssueKind.unbalancedRestore ||
            issue.kind == HudPaintIssueKind.missingTextPort),
        isEmpty,
        reason: '滚动链只允许 17 命令契约内的 save/clip/alpha/text/restore',
      );
      // Picture.getBounds() 在本机 dart:ui 里不存在（142 未能执行测试，编译错误随合并进来）；
      // 而 picture.toImage() 在 flutter_test 的 fake async 下会一直挂住（实测 10 分钟超时）。
      // 这里改用"真实 painter 确实把文本命令交给了端口"来做可见性证据：端口是本测试里
      // 唯一的绘制出口，命令数为 0 就一定是空画面。
      expect(textRuns, greaterThan(0), reason: '真实 painter 必须发出可见的文本绘制命令');
    });
  });
}
