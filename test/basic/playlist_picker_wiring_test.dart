/// 竖屏「加入歌单」选择器与喜欢/歌词偏移动作的接线断言。
///
/// 覆盖三件事：①选择器页画出歌单行并逐行命中 `music:playlist-pick:<id>`；
/// ②空表时给「＋ 创建歌单」入口；③喜欢与歌词偏移动作串在 `BasicHudFrame` 里
/// 真的存在（宿主 `_onAction` 已按这些串分发）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/portrait/portrait_playlist_picker.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

Future<BasicGlyphPorts> _realPorts() async {
  final String glyphJson = await File(basicGlyphTableAsset).readAsString();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

void main() {
  late BasicGlyphPorts ports;
  setUpAll(() async {
    ports = await _realPorts();
  });
  test('选择器：歌单逐行命中 music:playlist-pick:<id>，并带序号与曲目数', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      ports: ports,
      state: const BasicViewState(phase: BasicPhase.library),
      width: 393,
      height: 852,
      portrait: true,
      modal: 'playlist-picker',
      pickerPlaylists: const <(String, String, int)>[
        ('pl-1', '我的收藏', 12),
        ('pl-2', '通勤歌单', 3),
      ],
      canCreatePlaylist: true,
    );
    final List<String> actions = <String>[
      for (final HudHit hit in frame.hits) hit.action,
    ];
    expect(actions, contains('music:playlist-pick:pl-1'));
    expect(actions, contains('music:playlist-pick:pl-2'));
    // Qt 选择器在 `canCreatePlaylist` 时才给新建入口（ResponsiveHudPages.cpp:889）。
    expect(actions, contains('music:create-playlist'));
    // 页头有关闭。
    expect(actions, contains('close-modal'));
    final List<String> texts = <String>[
      for (final List<Object?> command in frame.commands)
        if (command.length > 1 && command.first == 'text') '${command[1]}',
    ];
    expect(texts.join('|'), contains(portraitPlaylistPickerTitle));
    expect(texts.join('|'), contains('我的收藏'));
    expect(texts.join('|'), contains('通勤歌单'));
  });

  test('选择器：空表画空态，不给行命中，但仍可创建歌单', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      ports: ports,
      state: const BasicViewState(phase: BasicPhase.library),
      width: 393,
      height: 852,
      portrait: true,
      modal: 'playlist-picker',
      pickerNotice: '还没有本地歌单',
      canCreatePlaylist: true,
    );
    final List<String> actions = <String>[
      for (final HudHit hit in frame.hits) hit.action,
    ];
    expect(actions.where((String a) => a.startsWith(portraitPlaylistPickPrefix)), isEmpty);
    expect(actions, contains('music:create-playlist'));
  });
}
