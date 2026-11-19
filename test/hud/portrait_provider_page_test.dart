// 竖屏「音乐平台」页与设置页 ACCESS 卡的绘制测试。
//
// 两个 painter 都只往 PortraitCanvas 写命令与热区、不建 widget，所以测试就是
// 「构造画布 → 画 → 断言命令/热区」。真值口径：
// - Qt/src/ResponsiveHudPages.cpp:612-701（providerPage 整页几何与三段 terminalSection）
// - Qt/src/ResponsiveHudPages.cpp:25-34（terminalSection）
// - Qt/src/ResponsiveHudPages.cpp:527-544（设置页 ACCESS / 音乐平台 卡）
// - Qt/src/NativeHud.cpp:478-486,543-545（providers / providerPlaylistEditors 状态键）
//
// 宽度按字符数估算：本组只关心「画了什么 / 发了什么动作」，不校验像素级字形宽度。
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' show Rect;

import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_provider.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';

PortraitCanvas _canvas({double gridWidth = 393, double height = 700}) =>
    PortraitCanvas(
      metrics: PortraitMetrics(
        width: (String value, double size, String weight) =>
            value.length * size * .6,
        wrap: (String value, double limit, double size, String weight) =>
            <String>[value],
        bounds: (String value, double size, String weight) =>
            PortraitGlyphBounds(width: value.length * size * .6, height: size),
      ),
      unit: 1,
      height: height,
      dark: true,
      gridWidth: gridWidth,
    );

List<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toList();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command.length >= 2 && command[0] == 'text') command[1]! as String,
];

ProviderDescriptor _descriptor(
  String id,
  String name,
  String label,
  String detail,
) =>
    ProviderDescriptor.parse(<String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'display': <String, Object?>{
        'name': name,
        'label': label,
        'detail': detail,
        'order': 0,
      },
      'capabilities': <String, Object?>{},
    });

void main() {
  group('竖屏音乐平台页', () {
    final ProviderDescriptor siren =
        _descriptor('siren', '塞壬唱片', 'MONSTER SIREN', '官网曲库');
    final ProviderDescriptor netease =
        _descriptor('netease', '网易云音乐', 'NETEASE', '搜索 · 个人音乐 · 播放');
    final ProviderDescriptor local =
        _descriptor('local', '本地音乐', 'LOCAL', '文件夹管理 · 本地检索');

    test('平台行各发一条 provider:<id> 命中，label 是「切换到 <名>」', () {
      final PortraitCanvas c = _canvas();
      paintPortraitProviderPage(
        c,
        providers: <ProviderDescriptor>[siren, netease, local],
        currentId: 'netease',
        accounts: const <String, ProviderAccount?>{},
        scrollOffset: '0',
      );

      final List<String> actions = _actions(c);
      // Qt :637 c.hit({20, y, 353, rowHeight}, "provider:" + id, "切换到 " + name)
      expect(actions, contains('provider:siren'));
      expect(actions, contains('provider:netease'));
      expect(actions, contains('provider:local'));
      // :643 插件市场入口 + :664 账号登录按钮
      expect(actions, contains('plugins'));
      expect(actions, contains('music:login'));

      final HudHit neteaseHit = c.hits.firstWhere(
        (HudHit hit) => hit.action == 'provider:netease',
      );
      expect(neteaseHit.label, '切换到 网易云音乐');
      expect(neteaseHit.width, 353);
      expect(neteaseHit.height, 64);

      // 三段 terminalSection 的标题与说明。
      final List<String> texts = _texts(c);
      expect(texts, containsAll(<String>[
        '音乐平台',
        'PROVIDER ACCESS',
        '第三方平台插件',
        'PLUGINS',
        '账号与歌单',
        'ACCOUNT',
        '插件市场',
        '安装与管理第三方平台插件',
      ]));
      // 页尾两段（:669-678）。
      expect(texts, contains('平台能力由插件声明。'));
      expect(texts, contains('切换平台会停止当前播放，各平台账号与个人音乐独立保存。'));
    });

    test('当前平台画「当前平台」，其余平台画「切换 →」', () {
      final PortraitCanvas c = _canvas();
      paintPortraitProviderPage(
        c,
        providers: <ProviderDescriptor>[siren, netease, local],
        currentId: 'siren',
        accounts: const <String, ProviderAccount?>{},
        scrollOffset: '0',
      );

      final List<String> texts = _texts(c);
      // :634-635 —— selected ? "当前平台" : "切换 →"
      expect(texts, contains('当前平台'));
      expect(texts, contains('切换 →'));
      expect(
        texts.where((String value) => value == '当前平台').length,
        1,
        reason: '只有一个当前平台',
      );
      expect(
        texts.where((String value) => value == '切换 →').length,
        2,
        reason: '另外两个平台各一条',
      );
      // 选中行的 raised 底 + amber 竖条只出现一次（2 px 宽的那个）。
      final List<List<Object?>> fills = <List<Object?>>[
        for (final List<Object?> command in c.commands)
          if (command.length >= 2 && command[0] == 'fill') command,
      ];
      expect(
        fills.where((List<Object?> f) => f[4] == 2 && f[5] == 64).length,
        1,
      );
    });

    test('空列表只画 Qt 的空态文案，不发任何 provider 命中', () {
      final PortraitCanvas c = _canvas();
      paintPortraitProviderPage(
        c,
        providers: const <ProviderDescriptor>[],
        currentId: 'netease',
        accounts: const <String, ProviderAccount?>{},
        scrollOffset: '0',
      );

      expect(
        _actions(c).any((String a) => a.startsWith('provider:')),
        isFalse,
        reason: '没有平台就没有行命中',
      );
      expect(_texts(c), contains('当前没有可用的音乐平台。'));
      // 空列表不影响后面两段照常绘制（Qt 的 for 循环空转）。
      expect(_texts(c), contains('插件市场'));
    });

    test('页宽跟着 gridWidth 走，不写死 393', () {
      final PortraitCanvas c = _canvas(gridWidth: 420);
      paintPortraitProviderPage(
        c,
        providers: <ProviderDescriptor>[siren, netease],
        currentId: 'netease',
        accounts: const <String, ProviderAccount?>{},
        scrollOffset: '0',
      );

      final HudHit neteaseHit = c.hits.firstWhere(
        (HudHit hit) => hit.action == 'provider:netease',
      );
      // 353 = 393-40；420 时应为 380。
      expect(neteaseHit.width, 420 - 40);
      expect(neteaseHit.x, 20);
    });

    test('滚动偏移决定第一行的 y，且只接受可解析的数字', () {
      final PortraitCanvas c = _canvas();
      paintPortraitProviderPage(
        c,
        providers: <ProviderDescriptor>[siren, netease],
        currentId: 'netease',
        accounts: const <String, ProviderAccount?>{},
        scrollOffset: '40',
      );
      final HudHit first = c.hits.firstWhere(
        (HudHit hit) => hit.action == 'provider:siren',
      );
      // 158 - 40 + 26（section 高）= 144，但内容裁剪从 158 起，
      // 所以命中矩形被夹成「可见部分」：top 158，高 64-(158-144)=50。
      expect(first.y, 158);
      expect(first.height, 50);

      final PortraitCanvas invalid = _canvas();
      paintPortraitProviderPage(
        invalid,
        providers: <ProviderDescriptor>[siren],
        currentId: 'siren',
        accounts: const <String, ProviderAccount?>{},
        scrollOffset: 'not-a-number',
      );
      final HudHit fallback = invalid.hits.firstWhere(
        (HudHit hit) => hit.action == 'provider:siren',
      );
      expect(fallback.y, 158 + 26, reason: '解析失败按 0');
    });

    test('ACCOUNT 段三分支：本地音乐 / 塞壬 / 其它', () {
      List<String> textsFor(String currentId) {
        final PortraitCanvas c = _canvas();
        paintPortraitProviderPage(
          c,
          providers: <ProviderDescriptor>[siren, netease, local],
          currentId: currentId,
          accounts: const <String, ProviderAccount?>{},
          scrollOffset: '0',
        );
        return _texts(c);
      }

      // :647-652 localMusic → 文件夹管理。
      expect(textsFor('local'), contains('文件夹管理 ＋'));
      expect(textsFor('local'), contains('本地索引 / 无需账号，文件保留在原目录'));
      // :653-656 siren → 官网曲库 / 无需登录。
      expect(textsFor('siren'), contains('官网曲库 / 无需登录'));
      // :657-666 其它 → 登录态 + 账号登录按钮。
      expect(textsFor('netease'), contains('未登录'));
      expect(textsFor('netease'), contains('账号登录 / 网易云音乐'));
    });

    test('已登录时画昵称与「已登录」，页尾列出支持歌单编辑的平台', () {
      final PortraitCanvas c = _canvas();
      paintPortraitProviderPage(
        c,
        providers: <ProviderDescriptor>[siren, netease],
        currentId: 'netease',
        accounts: const <String, ProviderAccount?>{
          'netease': ProviderAccount(id: 'u-1', nickname: '莱茵'),
        },
        scrollOffset: '0',
        playlistEditors: const <String>['网易云音乐', 'QQ 音乐'],
      );

      final List<String> texts = _texts(c);
      expect(texts, contains('已登录'));
      expect(texts, contains('莱茵'));
      expect(texts, contains('支持歌单编辑：网易云音乐、QQ 音乐'));
    });
  });

  group('竖屏设置页 ACCESS 卡', () {
    test('未登录：切换平台 / 登录账号两条命中', () {
      final PortraitCanvas c = _canvas();
      final double next = paintPortraitProviderAccessCard(
        c,
        130,
        providerName: '网易云音乐',
        loggedIn: false,
      );

      expect(next, 130 + 116, reason: 'Qt :544 y += 116');
      final List<String> actions = _actions(c);
      expect(actions, contains('provider'));
      expect(actions, contains('music:login'));
      expect(actions, isNot(contains('music:logout')));
      final List<String> texts = _texts(c);
      expect(texts, contains('ACCESS / 音乐平台'));
      expect(texts, contains('网易云音乐'));
      expect(texts, contains('切换平台 ↗'));
      expect(texts, contains('尚未登录'));
      expect(texts, contains('登录账号 ↗'));

      final HudHit switcher =
          c.hits.firstWhere((HudHit hit) => hit.action == 'provider');
      expect(switcher.label, '切换音乐平台');
      // 393 - 124 = 269，104×44。
      expect(switcher.x, 269);
      expect(switcher.width, 104);
      expect(switcher.height, 44);
    });

    test('已登录：画昵称与「退出登录 ↗」，命中 music:logout', () {
      final PortraitCanvas c = _canvas();
      final double next = paintPortraitProviderAccessCard(
        c,
        130,
        providerName: '网易云音乐',
        loggedIn: true,
        userName: '莱茵',
      );

      expect(next, 246);
      expect(_actions(c), contains('music:logout'));
      expect(_actions(c), isNot(contains('music:login')));
      final List<String> texts = _texts(c);
      expect(texts, contains('莱茵'));
      expect(texts, contains('退出登录 ↗'));
      expect(texts, isNot(contains('尚未登录')));

      final HudHit logout = c.hits.firstWhere(
        (HudHit hit) => hit.action == 'music:logout',
      );
      expect(logout.x, 269);
      expect(logout.y, 130 + 52);
      expect(logout.width, 104);
      expect(logout.height, 44);
    });

    test('页宽适应：右缘命中贴着 gridWidth - 124', () {
      final PortraitCanvas c = _canvas(gridWidth: 420);
      paintPortraitProviderAccessCard(
        c,
        130,
        providerName: '网易云音乐',
        loggedIn: false,
      );
      final HudHit switcher =
          c.hits.firstWhere((HudHit hit) => hit.action == 'provider');
      expect(switcher.x, 420 - 124);
      final Rect card = Rect.fromLTWH(20, 130, 420 - 40, 96);
      // 393 时 269+104 = 373 = 卡的右缘（20+353）；420 时同理 296+104 = 400。
      expect(switcher.x + switcher.width, card.right);
    });
  });
}
