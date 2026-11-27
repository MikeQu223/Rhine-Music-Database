import 'provider_descriptor.dart';

/// 平台注册表（Qt `ProviderRegistry` 的纯数据面投影）。
///
/// 对应 `Qt/src/ProviderRegistry.{h,cpp}`。Qt 的装载顺序是：
/// 1. 用户插件目录里的 `manifest.json`（`loadManifestFallback(userRoot)`）；
/// 2. 构建期内置 descriptor 目录（`loadDirectory(root + "/MusicBridge/plugins/descriptors")`）；
/// 3. `root + "/MusicBridge/local-plugins"` 里的 manifest；
/// 4. 最后 `addBuiltin("siren", …, order 0)` / `addBuiltin("local", …, order 4)` 兜底。
///
/// 本类只做第 1、2 步的合并与 `ids()` 排序（`display.order` 升序，同序按 id 字典序），
/// 装载 I/O 交给调用方（Flutter 侧读 assets / 插件目录），这样本类可脱离 Flutter 测试。
class ProviderRegistry {
  ProviderRegistry._(this._descriptors);

  final Map<String, ProviderDescriptor> _descriptors;

  /// 空表（装载失败时的安全初值）。
  static final ProviderRegistry empty = ProviderRegistry._(const <String, ProviderDescriptor>{});

  /// 合并内置 descriptor 与用户插件 manifest，按 Qt 规则去重与排序。
  ///
  /// - `builtins`：内置 descriptor（siren、local），键为文件名不含 `.json` 的 id；
  /// - `userManifests`：用户插件 manifest 原始 JSON（每份都必须能通过
  ///   [ProviderDescriptor.parse] 的校验，失败项跳过 —— Qt 在 `loadManifestFallback`
  ///   里也是静默跳过不合法的插件，不中断整张表）；
  /// - `disabled`：用户禁用列表（`plugins-state.json` 的 `disabled`），命中的插件不装载；
  /// - `builtinIds`：不能由用户插件覆盖的 id（Qt 里是 `local`/`siren`）。
  static ProviderRegistry load({
    required Iterable<Map<String, Object?>> builtins,
    Iterable<Map<String, Object?>> userManifests = const <Map<String, Object?>>[],
    Set<String> disabled = const <String>{},
    Set<String> builtinIds = const <String>{'siren', 'local'},
    void Function(String id, String reason)? onRejected,
  }) {
    final Map<String, ProviderDescriptor> table = <String, ProviderDescriptor>{};
    for (final Map<String, Object?> json in builtins) {
      try {
        final ProviderDescriptor descriptor = ProviderDescriptor.parse(json);
        table[descriptor.id] = descriptor;
      } on ProviderDescriptorError catch (error) {
        onRejected?.call('${json['id'] ?? '?'}', error.message);
      }
    }
    for (final Map<String, Object?> json in userManifests) {
      final String id = '${json['id'] ?? ''}';
      if (id.isEmpty || builtinIds.contains(id) || disabled.contains(id)) {
        continue;
      }
      try {
        final ProviderDescriptor descriptor = ProviderDescriptor.parse(json, userInstalled: true);
        // 用户插件覆盖同名内置之外的平台；同名 market 条目后到者胜（Qt 同）。
        table[descriptor.id] = descriptor;
      } on ProviderDescriptorError catch (error) {
        onRejected?.call(id, error.message);
      }
    }
    return ProviderRegistry._(Map<String, ProviderDescriptor>.unmodifiable(table));
  }

  /// 已装载的平台 id，按 `display.order` 升序（Qt `ProviderRegistry::ids`）。
  List<String> get ids {
    final List<String> all = _descriptors.keys.toList(growable: false);
    all.sort((String a, String b) {
      final int byOrder = _descriptors[a]!.order.compareTo(_descriptors[b]!.order);
      return byOrder != 0 ? byOrder : a.compareTo(b);
    });
    return all;
  }

  /// 是否装载了某个平台。
  bool contains(String id) => _descriptors.containsKey(id);

  /// 取描述符（未装载返回 null）。
  ProviderDescriptor? descriptor(String id) => _descriptors[id];

  /// 缺省平台：优先 `display.default`，否则按 [ids] 首个（Qt `defaultId`）。
  String? get defaultId {
    for (final String id in ids) {
      if (_descriptors[id]!.isDefault) {
        return id;
      }
    }
    return ids.isEmpty ? null : ids.first;
  }

  /// 回退平台：`display.default` 优先，其次首个不是 [exclude] 的 id（Qt `fallbackId`）。
  String? fallbackId({Set<String> exclude = const <String>{}}) {
    final String? preferred = defaultId;
    if (preferred != null && !exclude.contains(preferred)) {
      return preferred;
    }
    for (final String id in ids) {
      if (!exclude.contains(id)) {
        return id;
      }
    }
    return null;
  }

  /// 平台中文名（Qt `name`）。
  String name(String id) => _descriptors[id]?.name ?? id;

  /// 平台拉丁标签（Qt `label`）。
  String label(String id) => _descriptors[id]?.label ?? id.toUpperCase();

  /// 平台定位语（Qt `detail`）。
  String detail(String id) => _descriptors[id]?.detail ?? '';

  /// 会话标签（Qt `sessionLabel`）。
  String sessionLabel(String id) => _descriptors[id]?.sessionLabel ?? '${label(id)} SESSION';

  /// 档案编号前缀（Qt `archivePrefix`）。
  String archivePrefix(String id) => _descriptors[id]?.archiveIdPrefix ?? '';

  /// 能力布尔（Qt `capability(id, key, fallback)`）。
  bool capability(String id, String key, {bool fallback = true}) =>
      _descriptors[id]?.capability(key, fallback: fallback) ?? fallback;

  /// 操作布尔（插件 manifest 的 `operations`）。
  bool operation(String id, String key, {bool fallback = false}) =>
      _descriptors[id]?.operation(key, fallback: fallback) ?? fallback;

  /// 资料库列名（Qt `columns`）。
  List<String> columns(String id) => _descriptors[id]?.columns ?? const <String>[];

  /// 列的来源顺序（Qt `sourceOrder`）。
  List<int> sourceOrder(String id) => _descriptors[id]?.sourceOrder ?? const <int>[];

  /// 可见列数：descriptor 的 `lanes` 与 `columns` 长度取小（Qt `visibleLanes`）。
  int visibleLanes(String id) {
    final ProviderDescriptor? entry = _descriptors[id];
    if (entry == null) {
      return 0;
    }
    final int declared = entry.lanes <= 0 ? entry.columns.length : entry.lanes;
    return declared < entry.columns.length ? declared : entry.columns.length;
  }

  /// 登录方式（Qt `loginMethods`）。
  List<Map<String, Object?>> loginMethods(String id) =>
      _descriptors[id]?.loginMethods ?? const <Map<String, Object?>>[];

  /// 单个登录方式（Qt `loginMethod`）。
  Map<String, Object?>? loginMethod(String id, String method) =>
      _descriptors[id]?.loginMethod(method);

  /// 文案（Qt `text`）。
  String text(String id, String key) => _descriptors[id]?.text(key) ?? '';

  /// 变体（Qt `variants`）。
  List<Map<String, Object?>> variants(String id) => _descriptors[id]?.variants ?? const <Map<String, Object?>>[];

  /// 检索词上限（Qt `maxQueryLength`）。
  int maxQueryLength(String id) => _descriptors[id]?.maxQueryLength ?? 100;

  /// 是否用户插件（可卸载）。
  bool userInstalled(String id) => _descriptors[id]?.userInstalled ?? false;
}
