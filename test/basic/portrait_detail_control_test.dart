/// 竖屏详情页的控制带必须服从**详情页曲目**，不是正在播放的另一首。
///
/// 用户 2026-11-19：「在竖屏播放音频的情况下，如果点进另一个音频的详情，那么底部的
/// 控制条仍然是当前在播放的曲目的，并且也是控制当前在播放曲目的」。真值来源是 Qt
/// compact `song()` 的 `selectedSongIsCurrent`（Qt/src/ResponsiveHudPages.cpp:165-241）：
/// 非当前曲目 → 进度归零、右侧读本曲目时长、播放键发 `music:play`、seek 不给热区、
/// 歌词入口不出现；当前曲目 → 全部走 `player:*` 与真实播放读数。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_song.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

SirenSong _song(String id, String title, {double durationMs = 180000}) =>
    SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: durationMs,
    );

/// 宽度按字符数估算即可：本组测试只关心「画了什么/发了什么动作」，
/// 不校验像素级字形宽度。
PortraitCanvas _canvas() => PortraitCanvas(
  metrics: PortraitMetrics(
    width: (String value, double size, String weight) =>
        value.length * size * .6,
    wrap: (String value, double limit, double size, String weight) => <String>[
      value,
    ],
    bounds: (String value, double size, String weight) =>
        PortraitGlyphBounds(width: value.length * size * .6, height: size),
  ),
  unit: 1,
  height: 700,
  dark: true,
);

Set<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toSet();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command.length >= 2 && command[0] == 'text') command[1]! as String,
];

void _paint(
  PortraitCanvas c, {
  required bool current,
  bool playing = true,
  bool buffering = false,
  double positionMs = 65000,
  double durationMs = 180000,
  String lyricPreview = '',
  bool lyricsAvailable = true,
}) {
  paintPortraitSongPage(
    c,
    title: '第二首',
    artist: '塞壬唱片',
    album: '专辑',
    kind: 'song',
    stamp: '02 / 03',
    cover: '',
    current: current,
    playing: playing,
    buffering: buffering,
    favourite: false,
    positionMs: positionMs,
    durationMs: durationMs,
    lyricPreview: lyricPreview,
    lyricsAvailable: lyricsAvailable,
  );
}

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

void main() {
  group('portrait song page follows the page track, not the playing one', () {
    test('详情曲目未在播放：播放键发 music:play，传输键按详情页列表换曲', () {
      final PortraitCanvas c = _canvas();
      _paint(c, current: false, playing: true, lyricPreview: '别的歌的歌词');
      final Set<String> actions = _actions(c);

      // 在播的是另一首：本页播放键必须是「切到本曲目」，不能去暂停那首。
      expect(actions, contains('music:play'));
      expect(actions.contains('player:toggle'), isFalse);
      // 传输键同理：播放队列的邻居不是本页的邻居。
      expect(actions, contains('music:detail-prev'));
      expect(actions, contains('music:detail-next'));
      expect(actions.contains('player:prev'), isFalse);
      expect(actions.contains('player:next'), isFalse);
      // seek 不产生字段：否则拖动会把在播那首的位置改掉。
      expect(c.fields.containsKey('seek'), isFalse);
      // 歌词入口不出现（state.lyrics 属于播放曲目）。
      expect(actions.contains('player:lyrics'), isFalse);
    });

    test('详情曲目未在播放：进度归零、右侧读本曲目总时长、状态「尚未播放」', () {
      final PortraitCanvas c = _canvas();
      _paint(
        c,
        current: false,
        playing: true,
        positionMs: 65000,
        durationMs: 180000,
      );
      final List<String> texts = _texts(c);

      expect(texts, contains('尚未播放'));
      expect(texts.contains('正在播放'), isFalse);
      expect(texts, contains('00:00'));
      // 非当前曲目的右读数没有负号（Qt: `current ? "−"+rest : model.duration`）。
      expect(texts, contains('03:00'));
      expect(texts.contains('-01:55'), isFalse);
    });

    test('详情曲目未在播放：不显示另一首的歌词预览', () {
      final PortraitCanvas c = _canvas();
      _paint(c, current: false, lyricPreview: '别的歌的歌词');
      expect(_texts(c).contains('别的歌的歌词'), isFalse);
    });

    test('详情曲目就是当前曲目：控制带走真实播放态', () {
      final PortraitCanvas c = _canvas();
      _paint(
        c,
        current: true,
        playing: true,
        positionMs: 60000,
        durationMs: 180000,
      );
      final Set<String> actions = _actions(c);

      expect(actions, contains('player:toggle'));
      expect(actions, contains('player:prev'));
      expect(actions, contains('player:next'));
      expect(actions.contains('music:play'), isFalse);
      expect(c.fields.containsKey('seek'), isTrue);

      final List<String> texts = _texts(c);
      expect(texts, contains('正在播放'));
      expect(texts, contains('01:00'));
      expect(texts, contains('-02:00'));
    });

    test('当前曲目暂停 / 载入中的状态文案', () {
      final PortraitCanvas paused = _canvas();
      _paint(paused, current: true, playing: false);
      expect(_texts(paused), contains('已暂停'));

      final PortraitCanvas loading = _canvas();
      _paint(loading, current: true, playing: true, buffering: true);
      expect(_texts(loading), contains('正在载入'));
    });
  });

  group('portrait frame wires the page identity through', () {
    test('详情页曲目 ≠ 播放曲目时，整帧没有 player: 传输键', () {
      final SirenSong playing = _song('s1', '第一首');
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.detail,
        songs: <SirenSong>[playing, _song('s2', '第二首'), _song('s3', '第三首')],
        song: _song('s2', '第二首'),
        selection: const BasicSelection(kind: 'song', id: 's2'),
        playingTrack: playing,
        playing: true,
        positionMs: 65000,
        durationMs: 180000,
        catalogLoaded: true,
        dark: true,
      );
      final BasicHudFrame frame = BasicHudFrame.build(
        state: state,
        ports: _ports(),
        width: 1080,
        height: 1920,
        portrait: true,
      );
      final Set<String> actions = frame.hits
          .map((HudHit hit) => hit.action)
          .toSet();

      expect(actions, contains('music:play'));
      expect(actions, contains('music:detail-prev'));
      expect(actions, contains('music:detail-next'));
      expect(actions.contains('player:toggle'), isFalse);
      expect(actions.contains('player:next'), isFalse);
      expect(actions.contains('player:prev'), isFalse);
    });

    test('详情页曲目就是播放曲目时，整帧回到 player: 传输键', () {
      final SirenSong current = _song('s2', '第二首');
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.detail,
        songs: <SirenSong>[_song('s1', '第一首'), current, _song('s3', '第三首')],
        song: current,
        selection: const BasicSelection(kind: 'song', id: 's2'),
        playingTrack: current,
        playing: true,
        positionMs: 30000,
        durationMs: 180000,
        catalogLoaded: true,
        dark: true,
      );
      final BasicHudFrame frame = BasicHudFrame.build(
        state: state,
        ports: _ports(),
        width: 1080,
        height: 1920,
        portrait: true,
      );
      final Set<String> actions = frame.hits
          .map((HudHit hit) => hit.action)
          .toSet();

      expect(actions, contains('player:toggle'));
      expect(actions, contains('player:prev'));
      expect(actions, contains('player:next'));
      expect(actions.contains('music:play'), isFalse);
    });
  });
}
