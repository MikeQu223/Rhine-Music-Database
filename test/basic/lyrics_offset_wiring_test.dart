/// 歌词偏移浮层接线：横屏歌词帧在 `lyricsOffsetOpen` 时应当多出
/// `lyrics_offset_modal` 的六个命中（Qt `NativeHudController.cpp:375-379`
/// 打开 `modal == "lyrics-offset"`，浮层本体见 `NativeHudModal.cpp:69-121`）。
///
/// 只验「接线」：浮层自身的几何另有 `lib/hud/modals/lyrics_offset_modal.dart`
/// 的实现，这里只保证宿主把开关透到帧里、命中能出去。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/modals/lyrics_offset_modal.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  return BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
}

SirenSong _song() => SirenSong(
      id: 's1',
      title: '第一首',
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/s1.mp3',
      lyricUrl: 'https://example.invalid/s1.lrc',
      durationMs: 180000,
    );

BasicViewState _lyrics({double offsetMs = 0, double globalOffsetMs = 0}) => BasicViewState(
      phase: BasicPhase.lyrics,
      songs: <SirenSong>[_song()],
      song: _song(),
      lyrics: <BasicLyricLine>[const BasicLyricLine(startMs: 0, text: '第一句')],
      lyricIndex: 0,
      catalogLoaded: true,
      dark: true,
      lyricsOffsetMs: offsetMs,
      lyricsGlobalOffsetMs: globalOffsetMs,
    );

bool _has(BasicHudFrame frame, String action) =>
    frame.hits.any((HudHit hit) => hit.action == action);

BasicHudFrame _frame({required bool open, double offsetMs = 0, double globalOffsetMs = 0}) =>
    BasicHudFrame.build(
      state: _lyrics(offsetMs: offsetMs, globalOffsetMs: globalOffsetMs),
      ports: _ports(),
      width: 1920,
      height: 1080,
      portrait: false,
      lyricsOffsetOpen: open,
    );

void main() {
  test('横屏歌词帧默认画「歌词偏移」入口', () {
    final BasicHudFrame frame = _frame(open: false);
    expect(_has(frame, 'player:lyrics-offset'), isTrue);
    // 未打开时不该有浮层的「全局应用」。
    expect(_has(frame, LyricsOffsetModal.actionApplyGlobal), isFalse);
  });

  test('打开后浮层命中进帧：偏移非零时重置与全局应用都可点', () {
    final BasicHudFrame frame = _frame(open: true, offsetMs: 200);
    expect(_has(frame, LyricsOffsetModal.actionEarlier), isTrue);
    expect(_has(frame, LyricsOffsetModal.actionLater), isTrue);
    expect(_has(frame, LyricsOffsetModal.actionReset), isTrue);
    expect(_has(frame, LyricsOffsetModal.actionApplyGlobal), isTrue);
    // 浮层自带「关闭」：命中串与面板其它关闭同源（close-modal）。
    expect(_has(frame, LyricsOffsetModal.actionClose), isTrue);
  });

  test('偏移非零时「重置」仍可点，偏移为零时只画灰字（不给命中）', () {
    expect(_has(_frame(open: true), LyricsOffsetModal.actionReset), isFalse);
    expect(_has(_frame(open: true, offsetMs: 200), LyricsOffsetModal.actionReset), isTrue);
  });
}
