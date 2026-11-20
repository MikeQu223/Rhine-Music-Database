import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';

/// 音乐平台页接线的两条契约：
/// 1. HUD 平台行发的载荷前缀与 `_onAction` 认的前缀是同一个字面量；
/// 2. 内置 descriptor 装成注册表后 `ids` / `defaultId` 符合 Qt 规则。
void main() {
  /// 最小内置 descriptor（形状抄 `MusicBridge/plugins/descriptors/*.json`：
  /// `display` 与 `capabilities` 必填，`library.columns` 决定 lanes 缺省）。
  Map<String, Object?> builtin(String id, String name, int order, {bool defaulted = false}) {
    return <String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'display': <String, Object?>{
        'name': name,
        'label': id.toUpperCase(),
        'order': order,
        'default': defaulted,
      },
      'capabilities': <String, Object?>{'search': true},
      'library': <String, Object?>{
        'columns': <String>['搜索结果', '喜欢的歌曲'],
      },
      'login': null,
    };
  }

  test('平台行载荷前缀是 provider:', () {
    expect(basicProviderSwitchPrefix, 'provider:');
  });

  test('内置 descriptor 装表后 ids 按 order 升序，defaultId 取 display.default', () {
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[
        builtin('siren', '塞壬唱片', 0),
        builtin('local', '本地音乐', 4, defaulted: true),
      ],
    );
    expect(registry.ids, <String>['siren', 'local']);
    expect(registry.descriptor('siren'), isNotNull);
    expect(registry.descriptor('siren')!.name, '塞壬唱片');
    expect(registry.defaultId, 'local');
  });
}
