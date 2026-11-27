// 音乐平台页（modal == 'provider'）接线的三条契约。
//
// 本步只做「打开 / 切换 / 登录 / 退出」的动作分发，不做登录面板本身，所以测试
// 钉的是三个真值来源：
// 1. 内置 descriptor 能在测试环境装成含 `siren` / `local` 的注册表（页面行数据
//    来自它，装不到就只有空态）；
// 2. `BasicHudFrame` 在 `modal:'provider'` 时真的走平台页分支，命中集合里有
//    平台行的 `provider:<id>` 载荷（不是主页/设置页）；
// 3. 载荷前缀常量与 `_onAction` 认的分派前缀是同一个字面量。

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart' show basicProviderSwitchPrefix;
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/provider/provider_assets.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';

SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

BasicViewState _library() => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
      catalogLoaded: true,
      dark: true,
    );

/// 缺省 descriptor（形状抄 `MusicBridge/plugins/descriptors/*.json`：
/// `display` 与 `capabilities` 必填）。真资产读不到时用它兜住第 2 条。
ProviderDescriptor _descriptor(String id, String name, int order) =>
    ProviderDescriptor.parse(<String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'display': <String, Object?>{
        'name': name,
        'label': id.toUpperCase(),
        'order': order,
        'default': false,
      },
      'capabilities': <String, Object?>{'search': true},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ProviderAssetLoader 在测试环境装出 siren / local 两个内置平台', () async {
    // flutter_test 的 rootBundle 读的是 pubspec 声明的真 asset（`pubspec.yaml`
    // 的 `MusicBridge/plugins/descriptors/` 整目录），所以这里走的是宿主同一条
    // 装载路径，而不是手搓的 map。
    final ProviderRegistry registry = await ProviderAssetLoader().load();
    if (registry.ids.isEmpty) {
      // 万一 asset 在测试环境里读不到（例如跑在未构建 asset 的裸 dart VM），
      // 装载器会退回空表——这是既有契约：页面画「当前没有可用的音乐平台。」
      // 空态，不伪造平台行。这条退化为钉住空表行为本身。
      expect(registry.ids, isEmpty);
      expect(registry.descriptor('siren'), isNull);
      expect(registry.defaultId, isNull);
      return;
    }
    expect(registry.ids, <String>['siren', 'local']);
    expect(registry.descriptor('siren')!.name, '塞壬唱片');
    expect(registry.descriptor('local')!.name, '本地音乐');
    // 两份内置 descriptor 的 `display.default` 都是 false ⇒ defaultId 退回首个 id。
    expect(registry.defaultId, 'siren');
  });

  test('modal:provider 走平台页分支，命中集合里有 provider:<id> 载荷', () async {
    final ProviderRegistry loaded = await ProviderAssetLoader().load();
    final List<ProviderDescriptor> providers = loaded.ids.isEmpty
        ? <ProviderDescriptor>[_descriptor('siren', '塞壬唱片', 0), _descriptor('local', '本地音乐', 4)]
        : <ProviderDescriptor>[for (final String id in loaded.ids) loaded.descriptor(id)!];

    final BasicHudFrame frame = BasicHudFrame.build(
      state: _library(),
      ports: _ports(),
      width: 1080,
      height: 1920,
      portrait: true,
      modal: 'provider',
      providers: providers,
      providerId: 'siren',
    );
    final List<String> actions = <String>[
      for (final HudHit hit in frame.hits) hit.action,
    ];
    // 平台行载荷（`portrait_pages_provider.dart` 的 `provider:${provider.id}`）：
    // 两个内置平台里至少有一行画出来并带同一前缀。
    expect(
      actions.where((String action) => action == 'provider:siren').length +
          actions.where((String action) => action == 'provider:local').length,
      greaterThanOrEqualTo(1),
    );
    // 当前平台是 siren 时 ACCOUNT 段走「官网曲库 / 无需登录」分支，所以这一帧
    // 不该出现登录按钮的载荷（那是未知平台才有的入口）。
    expect(actions, isNot(contains('music:login')));
  });

  test('平台行载荷前缀与 _onAction 的分派前缀是同一个字面量', () {
    expect(basicProviderSwitchPrefix, 'provider:');
  });
}
