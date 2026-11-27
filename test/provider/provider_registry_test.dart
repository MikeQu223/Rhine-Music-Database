import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';

/// 平台注册表契约：排序、去重、禁用、内置兜底、能力缺省。
///
/// 真值对照 `Qt/src/ProviderRegistry.cpp`：`load()` 的装载顺序、`ids()` 按 `display.order`
/// 升序同序按 id 字典序、`defaultId`/`fallbackId` 的选用规则、`visibleLanes` 取小。
void main() {
  final Map<String, Object?> siren = <String, Object?>{
    'schemaVersion': 2,
    'id': 'siren',
    'display': <String, Object?>{'name': '塞壬唱片', 'label': 'SIREN', 'order': 0},
    'capabilities': <String, Object?>{'search': true},
    'library': <String, Object?>{
      'columns': <String>['搜索结果', '喜欢的歌曲'],
      'sourceOrder': <int>[1, 0],
      'lanes': 5,
    },
    'quality': <String, Object?>{'default': 'lossless'},
    'login': null,
  };
  final Map<String, Object?> local = <String, Object?>{
    'schemaVersion': 2,
    'id': 'local',
    'display': <String, Object?>{'name': '本地音乐', 'label': 'LOCAL', 'order': 4},
    'capabilities': <String, Object?>{},
    'quality': <String, Object?>{'default': 'original'},
    'login': null,
  };
  Map<String, Object?> plugin(String id, int order, {bool defaulted = false, String version = '1.0.0'}) {
    return <String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'version': version,
      'apiVersion': '2.0',
      'entry': <String, Object?>{'file': 'plugin.cjs'},
      'display': <String, Object?>{
        'name': '$id 平台',
        'label': id.toUpperCase(),
        'order': order,
        'default': defaulted,
      },
      'capabilities': <String, Object?>{'mv': true, 'comments': true},
      'login': <String, Object?>{
        'methods': <Map<String, Object?>>[
          <String, Object?>{'id': 'qr', 'type': 'qr', 'label': '扫码登录'},
        ],
      },
      'library': <String, Object?>{
        'columns': <String>['搜索结果', '喜欢的歌曲', '我的歌单'],
        'sourceOrder': <int>[1, 2, 0],
        'likedModel': 'likedIDs',
      },
    };
  }

  test('ids 按 display.order 升序，同序按 id 字典序', () {
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[local, siren],
      userManifests: <Map<String, Object?>>[plugin('zeta', 3), plugin('alpha', 3)],
    );
    expect(registry.ids, <String>['siren', 'alpha', 'zeta', 'local']);
    expect(registry.contains('siren'), isTrue);
    expect(registry.contains('qq'), isFalse);
  });

  test('用户插件不能占用内置 id，禁用列表中的插件不装载', () {
    final List<String> rejected = <String>[];
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[siren, local],
      userManifests: <Map<String, Object?>>[
        plugin('siren', 1),
        plugin('netease', 2),
        plugin('qq', 5),
      ],
      disabled: <String>{'qq'},
      onRejected: (String id, String reason) => rejected.add('$id:$reason'),
    );
    expect(registry.name('siren'), '塞壬唱片', reason: '内置项不得被同名插件覆盖');
    expect(registry.ids, <String>['siren', 'netease', 'local']);
    expect(rejected, isEmpty, reason: '被跳过的插件不算拒绝，只有解析失败才回报');
  });

  test('不合法的插件被跳过且不打断整张表', () {
    final List<String> rejected = <String>[];
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[siren, local],
      userManifests: <Map<String, Object?>>[
        <String, Object?>{'schemaVersion': 2, 'id': 'broken', 'display': 'nope'},
        plugin('netease', 2),
      ],
      onRejected: (String id, String reason) => rejected.add('$id:$reason'),
    );
    expect(rejected, <String>['broken:平台描述符缺少 display']);
    expect(registry.ids, <String>['siren', 'netease', 'local']);
  });

  test('defaultId 优先 display.default，fallbackId 可排除当前平台', () {
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[siren, local],
      userManifests: <Map<String, Object?>>[plugin('netease', 2, defaulted: true)],
    );
    expect(registry.defaultId, 'netease');
    expect(registry.fallbackId(), 'netease');
    expect(registry.fallbackId(exclude: <String>{'netease'}), 'siren');
  });

  test('visibleLanes 取 lanes 与 columns 的较小值（Qt 同）', () {
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[siren, local],
      userManifests: <Map<String, Object?>>[plugin('netease', 2)],
    );
    expect(registry.columns('siren'), <String>['搜索结果', '喜欢的歌曲']);
    expect(registry.visibleLanes('siren'), 2, reason: 'descriptor 写了 lanes 5 但只有 2 列');
    expect(registry.visibleLanes('netease'), 3);
    expect(registry.visibleLanes('missing'), 0);
  });

  test('能力缺省：未知平台按 fallback 值；未知能力缺省 true', () {
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[siren],
      userManifests: <Map<String, Object?>>[plugin('netease', 2)],
    );
    expect(registry.capability('netease', 'mv'), isTrue);
    expect(registry.capability('netease', 'login'), isTrue, reason: '未知能力按 Qt 缺省 true');
    expect(registry.capability('netease', 'login', fallback: false), isFalse);
    expect(registry.capability('missing', 'search'), isTrue);
    expect(registry.operation('netease', 'unknown'), isFalse);
  });

  test('loginMethods / maxQueryLength / 用户插件标记', () {
    final ProviderRegistry registry = ProviderRegistry.load(
      builtins: <Map<String, Object?>>[siren, local],
      userManifests: <Map<String, Object?>>[plugin('netease', 2)],
    );
    expect(registry.loginMethods('siren'), isEmpty);
    expect(registry.loginMethods('netease').length, 1);
    expect(registry.loginMethod('netease', 'qr')?['type'], 'qr');
    expect(registry.loginMethod('netease', 'phone'), isNull);
    expect(registry.maxQueryLength('netease'), 100);
    expect(registry.userInstalled('netease'), isTrue);
    expect(registry.userInstalled('siren'), isFalse);
    expect(registry.descriptor('missing'), isNull);
    expect(registry.archivePrefix('siren'), '');
    expect(registry.sessionLabel('netease'), 'NETEASE SESSION');
  });
}
