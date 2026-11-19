import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/data/storage/preference_store.dart';
import 'package:rhine_music_database/provider/platform_switcher.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';
import 'package:rhine_music_database/provider/provider_service.dart';

/// 平台切换器契约。
///
/// 真值逐条对照 `Qt/src/MusicAccount.cpp:190-327` `switchProvider`：
/// 变体优先级（显式 → `variantPreference` 偏好 → 首个）、提前返回条件
/// （`sourceChanged || variantChanged`）、副作用顺序（先 onBeforeSwitch，再写
/// 变体偏好与 `panel/provider`，再 onAfterSwitch，最后 `status = 已切换至<名>`）、
/// `restore()` 对非法偏好的回落，以及 `Qt/src/MusicAccount.cpp:191-196` 的
/// `PlatformFeatures::LocalMusic` 门禁。
/// 内存 [PreferencePort] 替身：只做 Map 读写，键原样保留（调用方已加 `panel/`）。
final class MemoryPreferences implements PreferencePort {
  MemoryPreferences([Map<String, String>? initial])
      : values = <String, String>{...?initial};

  final Map<String, String> values;
  final List<String> writes = <String>[];
  final List<String> reads = <String>[];

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add('$key=$value');
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

void main() {
  /// 两个内置平台 + 一个用来测变体的假平台。
  Map<String, Object?> descriptor(
    String id, {
    String? name,
    int order = 0,
    bool defaulted = false,
    List<Map<String, Object?>> variants = const <Map<String, Object?>>[],
    String variantPreference = '',
    Map<String, Object?> display = const <String, Object?>{},
  }) {
    return <String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'display': <String, Object?>{
        'name': name ?? '$id 平台',
        'label': id.toUpperCase(),
        'order': order,
        'default': defaulted,
        ...display,
      },
      'capabilities': <String, Object?>{},
      if (variants.isNotEmpty) 'variants': variants,
      if (variantPreference.isNotEmpty) 'variantPreference': variantPreference,
    };
  }

  final Map<String, Object?> siren = descriptor('siren', name: '塞壬唱片', order: 0, defaulted: true);
  final Map<String, Object?> local = descriptor('local', name: '本地音乐', order: 4);

  /// kugou：两个变体，偏好键 `kugou-edition`，变体各自有显示名。
  final Map<String, Object?> kugou = descriptor(
    'kugou',
    name: '酷狗音乐',
    order: 2,
    variantPreference: 'kugou-edition',
    variants: <Map<String, Object?>>[
      <String, Object?>{'id': 'standard', 'label': '标准版'},
      <String, Object?>{'id': 'lite', 'label': '概念版'},
    ],
    display: <String, Object?>{
      'nameByVariant': <String, Object?>{'lite': '酷狗概念版'},
    },
  );

  ProviderRegistry registryWith(List<Map<String, Object?>> builtins) =>
      ProviderRegistry.load(builtins: builtins);

  group('PlatformSwitcher.choose', () {
    test('切换写偏好 panel/provider，并把 status 设成「已切换至<名>」', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
      );

      expect(switcher.status, '');
      final bool changed = await switcher.choose('local');

      expect(changed, isTrue);
      expect(service.currentId, 'local');
      // Qt :244 host->setPreference("provider", source)，落盘键带 panel/ 前缀。
      expect(preferences.values['panel/provider'], 'local');
      expect(preferences.writes, <String>['panel/provider=local']);
      // Qt :324 status = QStringLiteral("已切换至") + providerName()。
      expect(switcher.status, '已切换至本地音乐');
    });

    test('同平台且无变体变化时不重复切换、不写偏好、不改 status', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
      );

      final bool changed = await switcher.choose('siren');

      // Qt :223-228 —— (!sourceChanged && !variantChanged) → done(true)，无副作用。
      expect(changed, isTrue);
      expect(preferences.writes, isEmpty);
      expect(switcher.status, '');
    });

    test('非法 id 直接拒绝（done(false)），不动当前平台也不写偏好', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
      );

      // Qt :230 —— !ProviderRegistry::contains(source) → done(false)。
      expect(await switcher.choose('netease'), isFalse);
      expect(service.currentId, 'siren');
      expect(preferences.writes, isEmpty);
      expect(switcher.status, '');
    });

    test('localMusicEnabled=false 时拒绝切到 local（Qt :191-196）', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
        localMusicEnabled: false,
      );

      expect(await switcher.choose('local'), isFalse);
      expect(service.currentId, 'siren');
      expect(preferences.writes, isEmpty);
    });

    test('生效顺序：onBeforeSwitch → 写偏好 → onAfterSwitch → status', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final List<String> events = <String>[];
      late PlatformSwitcher switcher;
      switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
        onBeforeSwitch: (String id) {
          events.add('before:$id');
          events.add('current:${service.currentId}');
        },
        onAfterSwitch: (String id) {
          events.add('after:$id');
          events.add('stored:${preferences.values['panel/provider']}');
          events.add('status:${switcher.status}');
        },
      );

      await switcher.choose('local');
      events.add('final:${switcher.status}');

      expect(events, <String>[
        'before:local',
        // Qt :241-246 —— 停播/清列表在 host->setProvider(source) 之前，
        // 所以 before 回调里当前平台还是旧值。
        'current:siren',
        'after:local',
        // :244 偏好写入在 :247-249 的宿主重载之前。
        'stored:local',
        // :324 status 在宿主重载之后才赋值，所以 after 里 status 仍是旧值。
        'status:',
        'final:已切换至本地音乐',
      ]);
    });

    test('偏好在 onAfterSwitch 之后仍然存在，且成功后 status 只置一次', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
      );

      await switcher.choose('local');
      final int writesAfterFirst = preferences.writes.length;
      await switcher.choose('siren');

      expect(preferences.values['panel/provider'], 'siren');
      expect(preferences.writes.length, writesAfterFirst + 1);
      expect(switcher.status, '已切换至塞壬唱片');
    });
  });

  group('PlatformSwitcher 变体优先级', () {
    PlatformSwitcher switcherOver(
      MemoryPreferences preferences, {
      String initial = 'siren',
      bool localMusicEnabled = true,
    }) {
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, kugou, local]),
        initialProvider: initial,
      );
      return PlatformSwitcher(
        service: service,
        preferences: preferences,
        localMusicEnabled: localMusicEnabled,
      );
    }

    test('resolveVariant：没有变体的平台返回空串', () {
      final MemoryPreferences preferences = MemoryPreferences();
      final PlatformSwitcher switcher = switcherOver(preferences);
      expect(switcher.resolveVariant('siren'), '');
      expect(switcher.resolveVariant('local'), '');
      expect(switcher.resolveVariant('netease'), '');
    });

    test('显式 variant 优先于偏好', () async {
      final MemoryPreferences preferences =
          MemoryPreferences(<String, String>{'panel/kugou-edition': 'standard'});
      final PlatformSwitcher switcher = switcherOver(preferences);

      await switcher.choose('kugou', variant: 'lite');

      // Qt :201-202 —— selected = variant（先赋值），只有为空才读偏好。
      expect(switcher.currentVariant, 'lite');
      expect(preferences.values['panel/kugou-edition'], 'lite');
      expect(preferences.values['panel/provider'], 'kugou');
      // :296-305 providerName() —— 变体名优先。
      expect(switcher.status, '已切换至酷狗概念版');
    });

    test('无显式 variant 时读偏好', () async {
      final MemoryPreferences preferences =
          MemoryPreferences(<String, String>{'panel/kugou-edition': 'lite'});
      final PlatformSwitcher switcher = switcherOver(preferences);

      await switcher.choose('kugou');

      expect(switcher.currentVariant, 'lite');
      expect(switcher.status, '已切换至酷狗概念版');
      // 偏好合法时不需要重写（值相同，仍按 Qt 写一次）。
      expect(preferences.values['panel/kugou-edition'], 'lite');
    });

    test('偏好缺失或非法时回落到首个变体', () async {
      final MemoryPreferences preferences =
          MemoryPreferences(<String, String>{'panel/kugou-edition': 'nope'});
      final PlatformSwitcher switcher = switcherOver(preferences);

      await switcher.choose('kugou');

      // Qt :208-219 —— 不在 variants 里就取 first。
      expect(switcher.currentVariant, 'standard');
      expect(preferences.values['panel/kugou-edition'], 'standard');
      // standard 没有 nameByVariant，回落到 registry.name。
      expect(switcher.status, '已切换至酷狗音乐');
    });

    test('只有变体变化（同平台）也算切换', () async {
      final MemoryPreferences preferences = MemoryPreferences(<String, String>{
        'panel/provider': 'kugou',
        'panel/kugou-edition': 'standard',
      });
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, kugou, local]),
        initialProvider: 'kugou',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
      );
      // 先把当前变体拉到 standard（restore 口径）。
      await switcher.restore();
      expect(switcher.currentVariant, 'standard');

      final bool changed = await switcher.choose('kugou', variant: 'lite');

      // Qt :222 —— variantChanged = !selected.isEmpty() && selected != providerVariant。
      expect(changed, isTrue);
      expect(switcher.currentVariant, 'lite');
      expect(preferences.values['panel/provider'], 'kugou');
      expect(switcher.status, '已切换至酷狗概念版');
    });

    test('同平台同变体不重复切换', () async {
      final MemoryPreferences preferences = MemoryPreferences(<String, String>{
        'panel/provider': 'kugou',
        'panel/kugou-edition': 'standard',
      });
      final PlatformSwitcher switcher = switcherOver(preferences, initial: 'kugou');
      await switcher.restore();

      final int writesBefore = preferences.writes.length;
      final bool changed = await switcher.choose('kugou', variant: 'standard');

      expect(changed, isTrue);
      expect(preferences.writes.length, writesBefore, reason: '没有变化就不写偏好');
    });
  });

  group('PlatformSwitcher.restore', () {
    test('读 panel/provider 恢复平台，并设变体', () async {
      final MemoryPreferences preferences = MemoryPreferences(<String, String>{
        'panel/provider': 'kugou',
        'panel/kugou-edition': 'lite',
      });
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, kugou, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.restore();

      expect(service.currentId, 'kugou');
      expect(switcher.currentVariant, 'lite');
    });

    test('非法偏好回落 fallbackId，且不把回退值写回磁盘', () async {
      final MemoryPreferences preferences = MemoryPreferences(<String, String>{
        'panel/provider': 'netease',
      });
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, kugou, local]),
        initialProvider: 'kugou',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.restore();

      // Qt 只在内存里回退，缺省值不落盘（Host::preference 只读）。
      expect(service.currentId, 'siren');
      expect(preferences.writes, isEmpty);
      expect(preferences.values['panel/provider'], 'netease');
      expect(switcher.status, '');
    });

    test('偏好指向被门禁的 local 时回落到非 local 的平台', () async {
      final MemoryPreferences preferences =
          MemoryPreferences(<String, String>{'panel/provider': 'local'});
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher = PlatformSwitcher(
        service: service,
        preferences: preferences,
        localMusicEnabled: false,
      );

      await switcher.restore();

      expect(service.currentId, 'siren');
      expect(preferences.writes, isEmpty);
    });

    test('偏好缺失时用 defaultId', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'local',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.restore();

      // siren 的 display.default 是 true。
      expect(service.currentId, 'siren');
    });

    test('变体偏好非法时回落到首个变体', () async {
      final MemoryPreferences preferences = MemoryPreferences(<String, String>{
        'panel/provider': 'kugou',
        'panel/kugou-edition': 'concept',
      });
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, kugou, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.restore();

      expect(switcher.currentVariant, 'standard');
    });

    test('restore 后 choose 相同平台不重复写偏好', () async {
      final MemoryPreferences preferences =
          MemoryPreferences(<String, String>{'panel/provider': 'local'});
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.restore();
      final int writesBefore = preferences.writes.length;

      expect(await switcher.choose('local'), isTrue);
      expect(preferences.writes.length, writesBefore);
    });
  });

  group('PlatformSwitcher 偏好键', () {
    test('偏好键走 PreferenceStore.prefix，读写的都是 panel/ 前缀键', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.choose('local');
      await switcher.restore();

      expect(preferences.writes, <String>['panel/provider=local']);
      expect(
        preferences.reads,
        containsAll(<String>['panel/provider']),
        reason: 'restore 读的就是同一个键',
      );
      expect(
        preferences.reads.every((String key) => key.startsWith(PreferenceStore.prefix)),
        isTrue,
      );
    });

    test('没有变体偏好的平台不读写任何额外键', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      await switcher.choose('local');

      expect(
        preferences.writes,
        <String>['panel/provider=local'],
        reason: 'local 没有 variants/variantPreference，只写 provider 一个键',
      );
    });

    test('rememberVariant 之后 resolveVariant 用缓存值', () async {
      final MemoryPreferences preferences = MemoryPreferences();
      final ProviderService service = ProviderService(
        registry: registryWith(<Map<String, Object?>>[siren, kugou, local]),
        initialProvider: 'siren',
      );
      final PlatformSwitcher switcher =
          PlatformSwitcher(service: service, preferences: preferences);

      expect(switcher.resolveVariant('kugou'), 'standard');
      switcher.rememberVariant('kugou', 'lite');
      expect(switcher.resolveVariant('kugou'), 'lite');
      // 没有 variantPreference 键的平台不吃缓存。
      switcher.rememberVariant('siren', 'lite');
      expect(switcher.resolveVariant('siren'), '');
    });
  });
}
