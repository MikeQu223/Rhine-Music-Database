// 横屏 `provider` 弹层补充段的测试：注册表驱动的平台卡组 + 第 6 张「第三方平台插件」卡。
//
// 真值口径：
// - Qt/src/NativeHudModal.cpp:305-320（providerCardsState：遍历 registry.ids()、local 门禁）
// - Qt/src/NativeHudModal.cpp:341-399（platformChoices：cardCount = items.size()+1、
//   cardWidth = (width - 12*(cardCount-1))/cardCount、第 6 张卡 hit("plugins", "第三方平台插件")）
// - Qt/src/NativeHudModal.cpp:322-338（providerPlaylistEditors）
//
// 只测几何/文案/命中，不测像素：字形宽度用字符数估算。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/modals/provider_plugins_section.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';

final class _Metrics implements HudTextPort {
  const _Metrics();

  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      value.length * size * 0.5;

  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => 0;

  @override
  String fit(String value, double size, double width,
      [String weight = 'regular']) => value;

  @override
  void rolling(String key, String value, double x, double y, double size,
      String weight, double tracking, bool numeric) {}
}

final class _Sink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => throw UnsupportedError('只通过 ModalShellBody.hit 发命中');
}

List<String> _texts(List<List<Object?>> commands) => <String>[
      for (final List<Object?> command in commands)
        if (command[0] == 'text') command[1]! as String,
    ];

Map<String, Object?> _builtin(String id, String name, String label, String detail, int order,
        {bool defaulted = false}) =>
    <String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'display': <String, Object?>{
        'name': name,
        'label': label,
        'detail': detail,
        'order': order,
        'default': defaulted,
      },
      'capabilities': <String, Object?>{},
    };

Map<String, Object?> _plugin(String id, String name, int order,
        {Map<String, Object?> capabilities = const <String, Object?>{}}) =>
    <String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'version': '1.0.0',
      'apiVersion': '2.0',
      'entry': <String, Object?>{'file': 'plugin.cjs'},
      'display': <String, Object?>{
        'name': name,
        'label': id.toUpperCase(),
        'order': order,
      },
      'capabilities': capabilities,
    };

void main() {
  group('providerPlatformCards', () {
    final List<Map<String, Object?>> builtins = <Map<String, Object?>>[
      _builtin('siren', '塞壬唱片', 'MONSTER SIREN', '官网曲库', 0, defaulted: true),
      _builtin('netease', '网易云音乐', 'NETEASE', '搜索 · 个人音乐 · 播放', 1),
      _builtin('local', '本地音乐', 'LOCAL', '文件夹管理 · 本地检索', 4),
    ];
    final List<Map<String, Object?>> manifests = <Map<String, Object?>>[
      _plugin('qq', 'QQ 音乐', 2),
    ];

    test('内置在前、插件在后，当前平台标 selected', () {
      final ProviderRegistry registry =
          ProviderRegistry.load(builtins: builtins, userManifests: manifests);
      final List<ProviderPlatformCard> cards = providerPlatformCards(
        registry: registry,
        currentProvider: 'netease',
        credentials: const <String>{'qq'},
      );

      expect(cards.map((ProviderPlatformCard c) => c.id), <String>[
        'siren',
        'netease',
        'local',
        'qq',
      ]);
      expect(cards[1].selected, isTrue);
      expect(cards.where((ProviderPlatformCard c) => c.selected).length, 1);
      expect(cards[3].plugin, isTrue, reason: 'qq 来自用户插件目录');
      expect(cards[3].authenticated, isTrue, reason: 'credentials 里有 qq');
      expect(cards[0].authenticated, isFalse);
      // label / detail 直接取 registry。
      expect(cards[1].label, 'NETEASE');
      expect(cards[1].detail, '搜索 · 个人音乐 · 播放');
    });

    test('localMusicEnabled=false 时 local 卡整条消失', () {
      final ProviderRegistry registry =
          ProviderRegistry.load(builtins: builtins, userManifests: manifests);
      final List<ProviderPlatformCard> cards = providerPlatformCards(
        registry: registry,
        currentProvider: 'netease',
        localMusicEnabled: false,
      );
      expect(cards.map((ProviderPlatformCard c) => c.id), isNot(contains('local')));
      expect(cards.length, 3);
    });

    test('kugou lite 显示名覆盖为「酷狗概念版」', () {
      final Map<String, Object?> kugou = <String, Object?>{
        'schemaVersion': 2,
        'id': 'kugou',
        'display': <String, Object?>{
          'name': '酷狗音乐',
          'label': 'KUGOU',
          'order': 3,
          'nameByVariant': <String, Object?>{'lite': '酷狗概念版'},
        },
        'capabilities': <String, Object?>{},
        'variants': <Map<String, Object?>>[
          <String, Object?>{'id': 'standard', 'label': '标准版'},
          <String, Object?>{'id': 'lite', 'label': '概念版'},
        ],
      };
      final ProviderRegistry registry = ProviderRegistry.load(
        builtins: <Map<String, Object?>>[kugou],
      );
      expect(
        providerPlatformCards(registry: registry, currentProvider: 'kugou')
            .single
            .name,
        '酷狗音乐',
      );
      expect(
        providerPlatformCards(
          registry: registry,
          currentProvider: 'kugou',
          kugouLite: true,
        ).single.name,
        '酷狗概念版',
      );
    });
  });

  group('providerPlaylistEditors', () {
    test('capabilities.playlistManagement 里任一 true 就算支持', () {
      final ProviderRegistry registry = ProviderRegistry.load(builtins: <Map<String, Object?>>[
        <String, Object?>{
          'schemaVersion': 2,
          'id': 'netease',
          'display': <String, Object?>{'name': '网易云音乐', 'label': 'NETEASE', 'order': 0},
          'capabilities': <String, Object?>{
            'playlistManagement': <String, Object?>{'create': true, 'delete': false},
          },
          'variants': <Map<String, Object?>>[],
        },
        <String, Object?>{
          'schemaVersion': 2,
          'id': 'qq',
          'display': <String, Object?>{'name': 'QQ 音乐', 'label': 'QQ MUSIC', 'order': 1},
          'capabilities': <String, Object?>{
            'playlistManagement': <String, Object?>{'create': false},
          },
        },
        <String, Object?>{
          'schemaVersion': 2,
          'id': 'siren',
          'display': <String, Object?>{'name': '塞壬唱片', 'label': 'MONSTER SIREN', 'order': 2},
          'capabilities': <String, Object?>{},
        },
      ]);
      expect(providerPlaylistEditors(registry), <String>['网易云音乐']);
      expect(
        providerPlaylistCapabilityLine(providerPlaylistEditors(registry)),
        '支持歌单编辑：网易云音乐',
      );
    });

    test('空表回落 Qt 的「平台能力由插件声明。」', () {
      final ProviderRegistry registry = ProviderRegistry.load(
        builtins: <Map<String, Object?>>[_builtin('siren', '塞壬唱片', 'MONSTER SIREN', '官网曲库', 0)],
      );
      expect(providerPlaylistEditors(registry), isEmpty);
      expect(providerPlaylistCapabilityLine(const <String>[]), '平台能力由插件声明。');
      expect(providerPlaylistCapabilityLine(const <String>['', '  ']), '平台能力由插件声明。');
    });
  });

  group('providerCardsLayout', () {
    test('cardCount = platformCount + 1，卡宽按 Qt 公式', () {
      // 横屏 panel 可用宽 1154（1260 - 106），5 个平台 → 6 张卡。
      final ProviderCardsLayout layout =
          providerCardsLayout(x: 383, width: 1154, platformCount: 5);
      expect(layout.count, 6);
      expect(layout.cardWidth, closeTo((1154 - 12 * 5) / 6, 1e-9));
      expect(layout.lefts.elementAt(0), 383);
      expect(layout.lefts.elementAt(4), closeTo(383 + 4 * (layout.cardWidth + 12), 1e-9));
      expect(layout.pluginsLeft, closeTo(383 + 5 * (layout.cardWidth + 12), 1e-9));
      // 最后一张卡的右缘正好落在可用宽度末端。
      expect(layout.pluginsLeft + layout.cardWidth, closeTo(383 + 1154, 1e-9));
    });
  });

  group('绘制', () {
    ProviderRegistry registry() => ProviderRegistry.load(
          builtins: <Map<String, Object?>>[
            _builtin('siren', '塞壬唱片', 'MONSTER SIREN', '官网曲库', 0, defaulted: true),
            _builtin('netease', '网易云音乐', 'NETEASE', '搜索 · 个人音乐 · 播放', 1),
            _builtin('local', '本地音乐', 'LOCAL', '文件夹管理 · 本地检索', 4),
          ],
          userManifests: <Map<String, Object?>>[_plugin('qq', 'QQ 音乐', 2)],
        );

    test('平台卡各发一条 provider:<id>，当前平台带 / ACTIVE', () {
      final List<ProviderPlatformCard> cards = providerPlatformCards(
        registry: registry(),
        currentProvider: 'siren',
      );
      final _Sink sink = _Sink();

      // 直接构造一个收集命中的 body（ModalShellHitTable 只收命中）。
      final ModalShellHitTable table = ModalShellHitTable();
      final ModalShellBody painter = ModalShellBody(
        sink: sink,
        text: const _Metrics(),
        hits: table,
        policy: ModalShellPolicy.forModal('provider'),
        bounds: const ModalShellBounds(left: 330, top: 122, width: 1260, height: 836),
        stageWidth: 1920,
        stageHeight: 1080,
        dark: false,
        offset: 0,
      );

      paintProviderPlatformCards(
        painter,
        cards: cards,
        x: 383,
        y: 380,
        width: 1154,
      );
      paintProviderPluginsCard(
        painter,
        x: 383,
        y: 380,
        width: 1154,
        platformCount: cards.length,
      );

      final List<String> actions = table.entries.map((HudHit h) => h.action).toList();
      expect(actions, <String>[
        'provider:siren',
        'provider:netease',
        'provider:local',
        'provider:qq',
        'plugins',
      ]);
      expect(
        table.entries.firstWhere((HudHit h) => h.action == 'provider:siren').label,
        '塞壬唱片',
      );
      expect(
        table.entries.firstWhere((HudHit h) => h.action == 'plugins').label,
        '第三方平台插件',
      );
      // 4 个平台 + 第 6 张插件卡 = 5 张，同宽、同高 190、同 y。
      final double cardWidth = (1154 - 12 * 4) / 5;
      for (final HudHit hit in table.entries) {
        expect(hit.width, closeTo(cardWidth, 1e-9));
        expect(hit.height, 190);
        expect(hit.y, 380);
      }
      expect(table.entries.last.x, closeTo(383 + 4 * (cardWidth + 12), 1e-9));

      final List<String> texts = _texts(sink.commands);
      expect(texts, contains('MONSTER SIREN / ACTIVE'));
      expect(texts, isNot(contains('NETEASE / ACTIVE')));
      // 第 6 张卡的文案三件套。
      expect(texts, contains('THIRD-PARTY / PLUGINS'));
      expect(texts, contains('第三方平台插件'));
      expect(texts, contains('插件市场 / 安装与启用'));
      // 未选中插件卡 + 选中卡 3px 竖条。
      expect(
        sink.commands.where((List<Object?> c) => c[0] == 'fill' && c[4] == 3).length,
        1,
      );
      expect(table.entries.length, 5);
    });

    test('compact 档卡高 66 且平台卡不画 detail', () {
      final List<ProviderPlatformCard> cards = providerPlatformCards(
        registry: registry(),
        currentProvider: 'netease',
      );
      final _Sink sink = _Sink();
      final ModalShellHitTable table = ModalShellHitTable();
      final ModalShellBody painter = ModalShellBody(
        sink: sink,
        text: const _Metrics(),
        hits: table,
        policy: ModalShellPolicy.forModal('provider'),
        bounds: const ModalShellBounds(left: 330, top: 122, width: 1260, height: 836),
        stageWidth: 1920,
        stageHeight: 1080,
        dark: true,
        offset: 0,
      );
      paintProviderPlatformCards(
        painter,
        cards: cards,
        x: 383,
        y: 380,
        width: 1154,
        expanded: false,
      );
      for (final HudHit hit in table.entries) {
        expect(hit.height, 66);
      }
      final List<String> texts = _texts(sink.commands);
      expect(texts, isNot(contains('搜索 · 个人音乐 · 播放')));
      // 名称仍是 22 → compact 用 17：断言字号命令。
      final List<Object?> netease = sink.commands.firstWhere(
        (List<Object?> c) => c[0] == 'text' && c[1] == '网易云音乐',
      );
      expect(netease[4], 17);
    });

    test('providerCardNote 四分法', () {
      ProviderPlatformCard card(String id, {bool authenticated = false}) =>
          ProviderPlatformCard(
            id: id,
            name: id,
            label: id,
            detail: '',
            selected: false,
            authenticated: authenticated,
            plugin: false,
          );
      expect(providerCardNote(card('local')), '独立本地库 / 无需登录');
      expect(providerCardNote(card('siren')), '官网曲库 / 无需登录');
      expect(providerCardNote(card('netease', authenticated: true)), '本机已保存登录');
      expect(providerCardNote(card('netease')), '未登录 / 可选择后扫码');
    });
  });
}
