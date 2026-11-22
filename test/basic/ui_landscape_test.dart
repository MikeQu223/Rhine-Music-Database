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

  group('landscape player bar lyrics keys', () {
    /// 播放条上的「词」键（Qt `PlayerBar.cpp:201-206`）与歌名区（`:167-169`）
    /// 都发 `player:lyrics`；两者在横屏必须都点得动。
    testWidgets('词键在没选中曲目时先把在播曲目落成当前行，再开歌词页',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 横屏浏览资料库时选中行可能落在专辑列上，controller 会把 `_song` 清空；
      // 这时 `player:lyrics` 会被 `openLyrics()` 的 `_song == null` 静默挡掉。
      final SirenSong playing = _song('s2', '第二首');
      final BasicViewState state = _library().copyWith(
        playingTrack: playing,
        playing: true,
        queue: <SirenSong>[playing],
        queueIndex: 0,
        durationMs: 180000,
      );
      final int row = basicLibraryItems(state)
          .indexWhere((BasicListItem item) => item.kind == 'song' && item.id == 's2');
      expect(row, isNonNegative);

      final BasicHudFrame frame = BasicHudFrame.build(
        state: state,
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      final HudHit key = frame.hits.firstWhere(
        (HudHit hit) => hit.action == 'player:lyrics' && hit.width < 100,
      );
      final List<String> actions = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BasicHudSurface(
            state: state,
            ports: _ports(),
            onAction: actions.add,
            geometry: const StageGeometry(logicalWidth: 1920.0, logicalHeight: 1080.0),
            stage: const HudStage(scale: 1.0, width: 1920.0, height: 1080.0),
          ),
        ),
      ));
      await tester.pump();

      await tester.tapAt(Offset(key.x + key.width / 2, key.y + key.height / 2));
      await tester.pump();
      expect(actions, equals(<String>['music:index:$row', 'player:lyrics']));
    });

    testWidgets('已在歌词页时再点词键发出「回到当前句」', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final SirenSong current = _song('s1', '第一首');
      final BasicViewState state = _library().copyWith(
        phase: BasicPhase.lyrics,
        song: current,
        playingTrack: current,
        playing: true,
        queue: <SirenSong>[current],
        queueIndex: 0,
        durationMs: 180000,
        positionMs: 30000,
      );
      final BasicHudFrame frame = BasicHudFrame.build(
        state: state,
        ports: _ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      final HudHit key = frame.hits.firstWhere(
        (HudHit hit) => hit.action == 'player:lyrics' && hit.width < 100,
      );
      final List<String> actions = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BasicHudSurface(
            state: state,
            ports: _ports(),
            onAction: actions.add,
            geometry: const StageGeometry(logicalWidth: 1920.0, logicalHeight: 1080.0),
            stage: const HudStage(scale: 1.0, width: 1920.0, height: 1080.0),
          ),
        ),
      ));
      await tester.pump();

      await tester.tapAt(Offset(key.x + key.width / 2, key.y + key.height / 2));
      await tester.pump();
      expect(actions, equals(<String>['player:lyrics-follow']));
    });
  });
}
