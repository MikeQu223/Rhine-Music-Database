/// 横屏下的「我的音乐 / 发现 / 加入歌单」：这三页只有 393 稿，
/// 横屏用同一套 painter 按舞台高度重采样，至少要画出来、并且动作可达。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_discover_mapper.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_collection_playlists.dart'
    show PortraitPlaylistRow;
import 'package:rhine_music_database/hud/portrait/portrait_saved_overview.dart'
    show PortraitSavedOverviewRow;
import 'package:rhine_music_database/hud/portrait/portrait_discover_page.dart'
    show PortraitDiscoverChip;
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 真字形端口：`BasicHudFrame.build` 的文字度量走它，测试不能造假数据。
BasicGlyphPorts _realPorts() {
  final String glyphJson = File(basicGlyphTableAsset).readAsStringSync();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  return BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
}

void main() {
  const BasicViewState state = BasicViewState(
    phase: BasicPhase.library,
    catalogLoaded: true,
  );
  final BasicGlyphPorts ports = _realPorts();

  test('横屏 modal=saved：画出我的音乐总览并给出收藏列动作', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      width: 1920,
      height: 1080,
      portrait: false,
      ports: ports,
      modal: 'saved',
      savedOverview: true,
      savedProviderName: '塞壬唱片',
      savedOverviewRows: const <PortraitSavedOverviewRow>[
        PortraitSavedOverviewRow(
          title: '喜欢的歌曲',
          subtitle: 'PERSONAL TRACKS',
          action: 'music:collection:1',
          icon: 'heart',
        ),
      ],
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('music:collection:1'));
    expect(frame.commands, isNotEmpty);
  });

  test('横屏 modal=saved 且 savedLane=2：画出我的歌单列并可创建', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      width: 1920,
      height: 1080,
      portrait: false,
      ports: ports,
      modal: 'saved',
      savedOverview: false,
      savedLane: 2,
      playlistRows: const <PortraitPlaylistRow>[
        PortraitPlaylistRow(id: 'p1', title: '卫戍协议', trackCount: 3),
      ],
      canCreatePlaylist: true,
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('music:result:2:0'));
    expect(hits, contains('music:create-playlist'));
  });

  test('横屏 modal=discover：tab 命中与空态都能画', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      width: 1920,
      height: 1080,
      portrait: false,
      ports: ports,
      modal: 'discover',
      discover: const BasicDiscoverSnapshot(
        tabs: <PortraitDiscoverChip>[
          PortraitDiscoverChip(label: '播放历史', action: 'discover:tab:history', selected: true),
        ],
        tab: 'history',
        status: '还没有播放记录',
      ),
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('discover:tab:history'));
  });

  test('横屏 modal=playlist-picker：行与创建按钮可达', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      width: 1920,
      height: 1080,
      portrait: false,
      ports: ports,
      modal: 'playlist-picker',
      pickerPlaylists: const <(String, String, int)>[('p1', '卫戍协议', 3)],
      canCreatePlaylist: true,
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('music:playlist-pick:p1'));
    expect(hits, contains('music:create-playlist'));
  });
}
