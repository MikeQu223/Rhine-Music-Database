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

  // 横屏的「我的音乐」不再塞 393 竖屏窄栏：它复用横屏资料库骨架画当前收藏列
  // （见 `fc64ae728`）。所以这里验的是「画出了资料库骨架、且不再有竖屏专属动作」。
  test('横屏 modal=saved：走横屏资料库骨架，不再出现竖屏返回动作', () {
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
    expect(frame.commands, isNotEmpty);
    // 竖屏总览页的返回/收藏列动作不该出现在横屏骨架上。
    expect(hits, isNot(contains('mobile:mine')));
    expect(hits, isNot(contains('music:collection:1')));
  });

  test('横屏 modal=saved 且 savedLane=2：同样走横屏骨架', () {
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
    expect(frame.commands, isNotEmpty);
    expect(hits, isNot(contains('music:result:2:0')));
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
