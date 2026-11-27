/// 竖屏发现页（Qt compact `ResponsiveHudLayout::discover`）与宿主动作的接线断言。
///
/// 覆盖：①tab 行按 `discover:tab:<id>` 命中；②行列表条目的 `discover:item:<i>`
/// 命中；③空态把 `status` 画成段落而不是留白；④`more` 时给 `discover:more`；
/// ⑤map 层三件事（tab 表来自 descriptor、history 用本地播放历史、无 discover
/// 能力时给诚实状态串）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_discover_mapper.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/portrait/portrait_discover_page.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';

/// 用 `ProviderDescriptor.parse` 造描述符：构造函数有 20+ 必填参数，测试不直接调。
ProviderDescriptor _descriptor(Map<String, Object?> discover) {
  return ProviderDescriptor.parse(<String, Object?>{
    'schemaVersion': 2,
    'id': 'plugin-demo',
    'display': <String, Object?>{'name': '示例平台', 'label': 'DEMO', 'order': 1},
    'capabilities': <String, Object?>{'discover': true},
    'discover': discover,
  });
}

ProviderDescriptor _sirenChip() => ProviderDescriptor.parse(<String, Object?>{
      'schemaVersion': 2,
      'id': 'siren',
      'display': <String, Object?>{'name': '塞壬唱片', 'label': 'MONSTER SIREN', 'order': 0},
      'capabilities': <String, Object?>{'discover': false},
      'discover': <String, Object?>{'enabled': false, 'defaultTab': '', 'tabs': <Object?>[]},
    });

/// 真字形端口：`BasicHudFrame.build` 的 `ports` 是必填，且文字要真字形才会落命令。
BasicGlyphPorts _realPorts() {
  final String glyphJson = File(basicGlyphTableAsset).readAsStringSync();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  return BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
}

BasicViewState _libraryState() => const BasicViewState(phase: BasicPhase.library);

List<String> _hits(BasicHudFrame frame) => <String>[
      for (final HudHit hit in frame.hits) hit.action,
    ];

List<String> _texts(BasicHudFrame frame) => <String>[
      for (final List<Object?> command in frame.commands)
        if (command.length > 1 && command.first == 'text') '${command[1]}',
    ];

void main() {
  test('map：tab 表来自 descriptor，选中项按 id 对齐', () {
    final ProviderDescriptor d = _descriptor(<String, Object?>{
      'enabled': true,
      'defaultTab': 'playlists',
      'tabs': <Object?>[
        <String, Object?>{'id': 'playlists', 'label': '推荐歌单'},
        <String, Object?>{'id': 'history', 'label': '播放历史'},
      ],
    });
    final List<PortraitDiscoverChip> tabs =
        basicDiscoverTabs(d, selectedTab: 'history');
    expect(tabs.map((PortraitDiscoverChip t) => t.action).toList(), <String>[
      '${basicDiscoverTabPrefix}playlists',
      '${basicDiscoverTabPrefix}history',
    ]);
    expect(tabs.map((PortraitDiscoverChip t) => t.label).toList(), <String>[
      '推荐歌单',
      '播放历史',
    ]);
    expect(tabs.last.selected, isTrue);
    expect(basicDiscoverInitialTab(d), 'playlists');
  });

  test('map：历史条目按本地播放历史生成，序号从 0 起', () {
    final List<PortraitDiscoverEntry> entries = basicDiscoverHistoryEntries(
      const <SirenSong>[
        SirenSong(
          id: '1',
          title: 'Kernel Overflow',
          artist: '塞壬唱片-MSR',
          album: '卫戍协议',
          albumId: 'a1',
          cover: '',
          sourceUrl: '',
          lyricUrl: '',
          durationMs: 0,
        ),
        SirenSong(
          id: '2',
          title: 'Systematic Violation',
          artist: '塞壬唱片-MSR',
          album: '卫戍协议',
          albumId: 'a1',
          cover: '',
          sourceUrl: '',
          lyricUrl: '',
          durationMs: 0,
        ),
      ],
    );
    expect(entries.length, 2);
    expect(entries.first.index, 0);
    expect(entries.first.title, 'Kernel Overflow');
    expect(entries.last.index, 1);
  });

  test('map：塞壬没有 discover 能力时状态串是「不提供发现页」', () {
    expect(
      basicDiscoverStatus(descriptor: _sirenChip(), tab: 'playlists', entryCount: 0),
      '塞壬唱片不提供发现页',
    );
    expect(
      basicDiscoverStatus(descriptor: null, tab: '', entryCount: 0),
      '音乐平台尚未装载',
    );
    expect(
      basicDiscoverStatus(
        descriptor: _descriptor(<String, Object?>{'enabled': true, 'tabs': <Object?>[]}),
        tab: basicDiscoverHistoryTab,
        entryCount: 0,
      ),
      '还没有播放记录',
    );
  });

  test('竖屏帧：tab 命中 + 行条目命中 + more 按钮', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      state: _libraryState(),
      width: 393,
      height: 852,
      portrait: true,
      ports: _realPorts(),
      modal: 'discover',
      discover: const BasicDiscoverSnapshot(
        tabs: <PortraitDiscoverChip>[
          PortraitDiscoverChip(
            label: '播放历史',
            action: '${basicDiscoverTabPrefix}history',
            selected: true,
          ),
        ],
        tab: basicDiscoverHistoryTab,
        entries: <PortraitDiscoverEntry>[
          PortraitDiscoverEntry(index: 0, title: 'Kernel Overflow', artist: '塞壬唱片-MSR'),
          PortraitDiscoverEntry(index: 1, title: 'Systematic Violation', artist: '塞壬唱片-MSR'),
        ],
        more: true,
      ),
    );
    final List<String> actions = _hits(frame);
    expect(actions, contains('${basicDiscoverTabPrefix}history'));
    expect(actions, contains('${basicDiscoverItemPrefix}0'));
    expect(actions, contains('${basicDiscoverItemPrefix}1'));
    expect(actions, contains(basicDiscoverMoreAction));
    final String text = _texts(frame).join('|');
    expect(text, contains('Kernel Overflow'));
    expect(text, contains('发现音乐'));
  });

  test('竖屏帧：空表时把 status 画成段落（不是留白）', () {
    final BasicHudFrame frame = BasicHudFrame.build(
      state: _libraryState(),
      width: 393,
      height: 852,
      portrait: true,
      ports: _realPorts(),
      modal: 'discover',
      discover: const BasicDiscoverSnapshot(
        tabs: <PortraitDiscoverChip>[
          PortraitDiscoverChip(label: '推荐歌单', action: '${basicDiscoverTabPrefix}playlists'),
        ],
        tab: 'playlists',
        status: '这个分类暂时没有内容',
      ),
    );
    expect(_texts(frame).join('|'), contains('这个分类暂时没有内容'));
    expect(
      _hits(frame).where((String a) => a.startsWith(basicDiscoverItemPrefix)),
      isEmpty,
    );
  });
}
