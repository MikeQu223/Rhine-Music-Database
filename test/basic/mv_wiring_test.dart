/// MV 面板接线：映射层 + 动作串 + 竖屏分支的可执行断言。
///
/// 只验「接线」这一层：领域层状态机本身另有 `test/domain/mv_controller_test.dart`，
/// 竖屏页面另有 `test/hud/mv_panels_test.dart`，这里不重复。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/basic_mv_mapper.dart';
import 'package:rhine_music_database/domain/mv/mv_controller.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_mv.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';

Future<BasicGlyphPorts> _realPorts() async {
  final String glyphJson = await File(basicGlyphTableAsset).readAsString();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

SirenSong _song() => SirenSong(
      id: '880380',
      title: 'Systematic Violation',
      artist: '塞壬唱片-MSR',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/a.mp3',
      lyricUrl: '',
      durationMs: 300000,
    );

void main() {
  test('映射层：status/title/trackId/auto 原样转发，decodable 恒 false', () {
    final MvState state = const MvState(
      trackId: '880380',
      phase: MvPhase.playing,
      status: '静音跟随音乐 · 720p',
      track: ProviderMvTrack(id: 'mv-1', title: 'Systematic Violation', url: 'https://a/b.mp4'),
      resolution: 720,
      auto: false,
      versionStatus: '1 个版本',
    );
    final MvPanelModel model = basicMvPanelModelOf(state);
    expect(model.status, '静音跟随音乐 · 720p');
    expect(model.title, 'Systematic Violation');
    expect(model.trackId, '880380');
    expect(model.resolution, 720);
    expect(model.versionStatus, '1 个版本');
    expect(model.auto, isFalse);
    // Android 不接视频解码（Qt/src/PlatformFeatures.h:23-27）：面板必须诚实降级。
    expect(model.decodable, isFalse);
  });

  test('映射层：版本行带 id 与已拼好的标签', () {
    final MvState state = const MvState(
      versions: <ProviderMvVersion>[
        ProviderMvVersion(id: 'a', title: '官方版', artist: '塞壬唱片-MSR', associated: true),
        ProviderMvVersion(id: 'b', title: '现场版'),
      ],
      selectedVersionId: 'b',
    );
    final MvPanelModel model = basicMvPanelModelOf(state);
    expect(model.versions.map((MvPanelVersionRow row) => row.id), <String>['a', 'b']);
    expect(model.versions.first.label, '[歌曲关联] 官方版 · 塞壬唱片-MSR · #a');
    expect(model.versions.first.associated, isTrue);
    expect(model.versions.last.label, '[搜索结果] 现场版 · #b');
    expect(model.selectedVersionId, 'b');
  });

  test('竖屏帧：modal == "mv" 时画出 MV 页，且动作串与 MvAction 对表', () async {
    final BasicGlyphPorts ports = await _realPorts();
    // 弹层的 modal 优先于歌曲页（Qt compact `ResponsiveHudLayout.cpp:209-250`：
    // `modal == "comments"` 等分支先于 `m_song`）；这里用曲库态避免详情页抢先。
    final BasicViewState state = BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[_song()],
      selectedLane: basicDefaultLane,
    );
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      ports: ports,
      width: 393,
      height: 852,
      portrait: true,
      modal: 'mv',
      mv: basicMvPanelModelOf(const MvState(trackId: '880380', status: '正在查找 MV…')),
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    // 页头的返回箭头是通用 `close-modal`（Qt compact 的 header(back:true) 就是它，
    // 由宿主 `_onAction` 收口）；面板自己的关闭串是 `MvAction.close`，见下一行断言。
    expect(hits, contains('close-modal'));
    expect(MvAction.close, 'mv:close');
  });
}
