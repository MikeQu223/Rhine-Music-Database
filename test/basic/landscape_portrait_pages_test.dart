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

  // 横屏的「我的音乐」是**收藏列的模态弹层**（Qt `NativeHudModal.cpp:163-218` 的
  // 遮罩 + 836 面板），不是把竖屏窄栏塞进 1080 骨架。2026-11-25 起它和
  // `discover` / `playlist-picker` 一样放进 `discoverModalBounds` 的外框：
  // 遮罩铺满舞台、纸底 1260×836、整页内容用 `_HudSink.shifted` 平移进去。
  bool hasMask(BasicHudFrame frame) => frame.commands.any((List<Object?> c) =>
      c.length >= 6 && c[0] == 'fill' && (c[1] as List<Object?>)[3] == 0.42);

  test('横屏 modal=saved：遮罩 + 1260×836 面板，总览行可达', () {
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
    // 弹层存在：全舞台 42% 遮罩（Qt `NativeHudModal.cpp:163` 的 scrim）。
    expect(hasMask(frame), isTrue);
    // 外框纸底与 Qt 的模态几何一致：宽 min(1260, 舞台-100)、高 836。
    expect(
      frame.commands.any((List<Object?> c) =>
          c.length >= 6 && c[0] == 'fill' && c[4] == 1260.0 && c[5] == 836.0),
      isTrue,
      reason: '收藏列面板应按 discoverModalBounds 铺 1260×836 纸底',
    );
    // 总览的行动作在平移后的坐标上仍然可点。
    expect(hits, contains('music:collection:1'));
  });

  test('横屏 modal=saved 且 savedLane=2：面板内画歌单列', () {
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
    expect(frame.commands, isNotEmpty);
    expect(hasMask(frame), isTrue);
    // 歌单行与「新建歌单」在平移后的坐标上仍然可点。
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
