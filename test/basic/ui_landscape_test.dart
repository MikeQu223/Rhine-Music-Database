import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

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

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

BasicViewState _library() => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首'), _song('s3', '第三首')],
      albums: <SirenAlbum>[
        SirenAlbum(id: 'album-1', name: '测试专辑', artist: '塞壬唱片', cover: '', songCount: 2, songs: <SirenSong>[_song('s1', '第一首')]),
      ],
      catalogLoaded: true,
      dark: true,
    );

bool _hasAction(BasicHudFrame frame, String action) =>
    frame.hits.any((HudHit hit) => hit.action == action);

void main() {
  group('phase routing', () {
    testWidgets('library frame carries archive, list and player hits', (WidgetTester tester) async {
      final BasicHudFrame frame = BasicHudFrame.build(
        state: _library(),
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      expect(frame.commands, isNotEmpty);
      expect(_hasAction(frame, 'open'), isTrue);
      expect(_hasAction(frame, 'music:index:1'), isTrue);
      expect(_hasAction(frame, 'player:open'), isTrue);
      expect(_hasAction(frame, 'player:toggle'), isTrue);
      expect(_hasAction(frame, 'back'), isFalse);
    });

    testWidgets('detail frame draws song detail and its back button', (WidgetTester tester) async {
      final BasicViewState library = _library();
      final BasicHudFrame frame = BasicHudFrame.build(
        state: library.copyWith(
          phase: BasicPhase.detail,
          song: library.songs.first,
          album: library.albums.first,
        ),
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      expect(_hasAction(frame, 'back'), isTrue);
      // 详情页不画资料库轨道列表。
      expect(_hasAction(frame, 'music:index:1'), isFalse);
      expect(_hasAction(frame, 'player:toggle'), isTrue);
    });

    testWidgets('lyrics frame delegates song detail to the lyrics panel', (WidgetTester tester) async {
      final BasicViewState library = _library();
      final BasicHudFrame frame = BasicHudFrame.build(
        state: library.copyWith(
          phase: BasicPhase.lyrics,
          song: library.songs.first,
          lyrics: <BasicLyricLine>[
            const BasicLyricLine(startMs: 0, text: '第一句'),
            const BasicLyricLine(startMs: 4000, text: '第二句'),
          ],
          lyricIndex: 0,
        ),
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      expect(_hasAction(frame, 'player:lyrics-close'), isTrue);
      expect(_hasAction(frame, 'player:toggle'), isTrue);
    });
  });

  group('hit dispatch', () {
    testWidgets('tapping the player queue entry emits player:open',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final List<String> actions = <String>[];
      final BasicGlyphPorts ports = _ports();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BasicHudSurface(
            state: _library(),
            ports: ports,
            onAction: actions.add,
            geometry: const StageGeometry(logicalWidth: 1920.0, logicalHeight: 1080.0),
            stage: const HudStage(scale: 1.0, width: 1920.0, height: 1080.0),
          ),
        ),
      ));
      await tester.pump();

      // `player:open` 全表唯一发射点是播放条右端的队列入口
      // （Qt/src/PlayerBar.cpp:224 `hit({queueX - 14, y + 16, 54, 65}, "player:open", …)`）；
      // 歌曲信息区在 Qt 里只有 player:lyrics（:136），没有 player:open。
      // 旧版这里硬编码 (100, 1040)，那是 transport 区的左侧空白，从未命中任何 hit。
      final HudHit open = BasicHudFrame.build(
        state: _library(),
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      ).hits.firstWhere((HudHit hit) => hit.action == 'player:open');
      await tester.tapAt(Offset(open.x + open.width / 2, open.y + open.height / 2));
      await tester.pump();
      expect(actions, contains('player:open'));
    });

    testWidgets('seek hits resolve to a real fraction via HitLayer', (WidgetTester tester) async {
      // Qt PlayerBar.cpp:148-150 只在 `state.seekable && durationMs > 0` 时挂
      // `player:seek-fraction:0`；空转的曲库（没有时长）本来就没有进度命中，
      // 所以这里必须给一个真的有时长的播放投影，而不是断言"总有一个 seek 命中"。
      final BasicViewState seekable = _library().copyWith(durationMs: 180000, positionMs: 60000);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final BasicHudFrame frame = BasicHudFrame.build(
        state: seekable,
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      final HudHit seek = frame.hits.firstWhere(
        (HudHit hit) => hit.action.startsWith('player:seek-fraction:'),
      );
      final List<String> actions = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BasicHudSurface(
            state: seekable,
            ports: _ports(),
            onAction: actions.add,
            geometry: const StageGeometry(logicalWidth: 1920.0, logicalHeight: 1080.0),
            stage: const HudStage(scale: 1.0, width: 1920.0, height: 1080.0),
          ),
        ),
      ));
      await tester.pump();

      await tester.tapAt(Offset(seek.x + seek.width / 2, seek.y + seek.height / 2));
      await tester.pump();
      expect(actions, isNotEmpty);
      final String action = actions.last;
      expect(action.startsWith('player:seek-fraction:'), isTrue);
      final double fraction = double.parse(action.substring('player:seek-fraction:'.length));
      expect(fraction, greaterThan(0.4));
      expect(fraction, lessThan(0.6));
    });
  });
}
