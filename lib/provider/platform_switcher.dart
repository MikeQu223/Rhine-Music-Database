/// 平台切换器：Qt `MusicLibrary::switchProvider` 的 Dart 侧投影。
///
/// 真值来源（逐条对应，改行为先改这里并同步测试）：
/// - `Qt/src/MusicAccount.cpp:190-327` `switchProvider(source, variant, done)`：
///   变体解析（显式 variant → `variantPreference` 偏好 → 首个变体）、
///   提前返回条件（`contains` / `local` 门禁 / `sourceChanged||variantChanged`）、
///   副作用顺序、`status = "已切换至" + providerName()`。
/// - `Qt/src/Host.cpp:1360-1390` `setProviderVariant`：变体校验后写
///   `variantPreference` 偏好键（键名不带前缀，就是 descriptor 里那个字符串）。
/// - `Qt/src/MusicLibrary.cpp:296-305` `providerName()`：有变体且
///   `nameForVariant` 非空时用变体名，否则注册表名，再否则平台 id。
/// - `Qt/src/Host.cpp:2755,2762`：偏好键落盘时加 `"panel/"` 前缀
///   （同 `lib/data/storage/preference_store.dart` 的 `PreferenceStore.prefix`）。
///
/// 本文件是**纯 Dart**：不 import flutter，不触网、不写盘。
/// 停播、清列表、重载目标平台数据这些业务副作用由调用方通过
/// [onBeforeSwitch] / [onAfterSwitch] 注入 —— 切换器只负责"顺序"与"偏好"，
/// 不持有播放器、列表或控制器。
library;

import '../data/storage/preference_store.dart';
import '../provider/provider_descriptor.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_service.dart';

/// 平台切换器。
///
/// 一次 [choose] 的副作用顺序（照 Qt `switchProvider` 与 `setProviderVariant`）：
/// 1. [onBeforeSwitch]（宿主停播、取消登录/请求、清空列表与选中态）；
/// 2. 写变体偏好（`variantPreference` 键非空且有选中变体时）；
/// 3. 写偏好 `panel/provider`；
/// 4. [onAfterSwitch]（宿主重载目标平台的账号/数据）；
/// 5. `status = "已切换至" + 平台名`。
class PlatformSwitcher {
  PlatformSwitcher({
    required this.service,
    required this.preferences,
    this.localMusicEnabled = true,
    this.onBeforeSwitch,
    this.onAfterSwitch,
  });

  /// Qt `panel/provider` 的键（落盘时由 [PreferenceStore.prefix] 加前缀）。
  static const String providerPreferenceKey = 'provider';

  /// 平台服务（注册表 + 当前平台 + 网关）。
  final ProviderService service;

  /// 偏好落盘端口（Qt `AppStorage::settings()` 的 `panel/` 命名空间）。
  final PreferencePort preferences;

  /// 切换前回调：宿主停播、取消在途登录/请求、清空列表与选中态
  /// （Qt/src/MusicAccount.cpp:241-246）。
  final void Function(String providerId)? onBeforeSwitch;

  /// 切换后回调：宿主重载目标平台的账号与数据
  /// （Qt/src/MusicAccount.cpp:247-249）。
  final void Function(String providerId)? onAfterSwitch;

  /// `PlatformFeatures::LocalMusic`：false 时拒绝切到 `local`
  /// （Qt/src/MusicAccount.cpp:191-196）。
  final bool localMusicEnabled;

  String _status = '';
  String _variant = '';

  /// 变体偏好键 → 最近一次读到的值。`variantPreference` 在 Qt 里是同步读取，
  /// 而 [PreferencePort] 是异步的，所以 [resolveVariant] 用这份缓存。
  final Map<String, String> _variantPreferences = <String, String>{};

  /// 最近一次状态文案（Qt `status`）：成功切换后是 `已切换至<平台名>`。
  String get status => _status;

  /// 当前选中的变体（空串表示该平台没有变体）。
  String get currentVariant => _variant;

  /// 切换平台。返回 true 表示"切换完成或本来就选它"（Qt 的 `done(true)`），
  /// false 表示平台不存在 / 被 `LocalMusic` 门禁拒绝。
  Future<bool> choose(String id, {String? variant}) async {
    final ProviderRegistry registry = service.registry;
    // :191-196 —— local 关掉时直接拒绝（done(false)）。
    if (id == 'local' && !localMusicEnabled) {
      return false;
    }
    // :230 —— contains 校验。
    if (!registry.contains(id)) {
      return false;
    }

    String selected = '';
    String preferenceKey = '';
    final List<Map<String, Object?>> variants = registry.variants(id);
    if (variants.isNotEmpty) {
      preferenceKey = registry.descriptor(id)?.variantPreferenceKey ?? '';
      selected = variant ?? ''; // :201-202 —— 显式变体优先
      if (selected.isEmpty && preferenceKey.isNotEmpty) {
        // :203-207 —— 其次读偏好键
        selected = (await preferences.read(_qualified(preferenceKey)) ?? '').trim();
      }
      if (!_variantExists(variants, selected)) {
        // :208-219 —— 非法/缺失一律回落到首个变体
        selected = variants.first['id']?.toString() ?? '';
      }
    }

    final bool sourceChanged = id != service.currentId; // :221
    final bool variantChanged = selected.isNotEmpty && selected != _variant; // :222
    if (!sourceChanged && !variantChanged) {
      // :223-228 —— 不重复切换（done(true)），不改状态、不动偏好。
      return true;
    }

    // :241-246 —— 宿主侧副作用：停播、取消在途请求、清空列表与选中态。
    onBeforeSwitch?.call(id);
    service.select(id);
    _variant = selected;
    if (selected.isNotEmpty) {
      // :245 —— host->setProviderVariant(selected) 写 variantPreference。
      _variantPreferences[preferenceKey] = selected;
      if (preferenceKey.isNotEmpty) {
        await preferences.write(_qualified(preferenceKey), selected);
      }
    }
    // :244 —— host->setPreference("provider", source)
    await preferences.write(_qualified(providerPreferenceKey), id);
    // :247-249 —— 宿主重载目标平台的账号与数据。
    onAfterSwitch?.call(id);
    // :324 —— status = "已切换至" + providerName()
    _status = '已切换至${_displayName(id, selected)}';
    return true;
  }

  /// 该平台会被选中的变体：偏好值合法则用它，否则首个变体；没有变体返回空串
  /// （Qt/src/MusicAccount.cpp:200-219）。
  ///
  /// 与 [choose] 的区别：本方法不读盘（[PreferencePort] 是异步的），只用
  /// [rememberVariant] / [choose] 已读到的偏好缓存。
  String resolveVariant(String id) {
    final List<Map<String, Object?>> variants = service.registry.variants(id);
    if (variants.isEmpty) {
      return '';
    }
    final String preferenceKey =
        service.registry.descriptor(id)?.variantPreferenceKey ?? '';
    final String remembered = _variantPreferences[preferenceKey] ?? '';
    if (preferenceKey.isNotEmpty && _variantExists(variants, remembered)) {
      return remembered;
    }
    if (id == service.currentId && _variantExists(variants, _variant)) {
      return _variant;
    }
    return variants.first['id']?.toString() ?? '';
  }

  /// 记录一次读到的变体偏好（宿主在启动时或设置页改偏好后调用）。
  void rememberVariant(String providerId, String variant) {
    final String key =
        service.registry.descriptor(providerId)?.variantPreferenceKey ?? '';
    if (key.isEmpty) {
      return;
    }
    _variantPreferences[key] = variant;
  }

  /// 启动时恢复平台：读偏好 `panel/provider`，未装载则回落 `fallbackId()`。
  ///
  /// Qt 只在内存里回退到缺省平台，**不把回退值写回磁盘**
  /// （Qt/src/Host.cpp:2732-2735 只读；缺省值不落盘）。
  Future<void> restore() async {
    final ProviderRegistry registry = service.registry;
    final String stored =
        (await preferences.read(_qualified(providerPreferenceKey)) ?? '').trim();
    String target = registry.contains(stored) ? stored : '';
    if (target.isEmpty) {
      // Qt 的 fallback：`display.default` 优先，其次首个。
      target = registry.fallbackId() ?? service.currentId;
    }
    if (target == 'local' && !localMusicEnabled) {
      target = registry.fallbackId(exclude: <String>{'local'}) ?? target;
    }
    service.select(target);

    final List<Map<String, Object?>> variants = registry.variants(target);
    if (variants.isEmpty) {
      _variant = '';
      return;
    }
    final String preferenceKey =
        registry.descriptor(target)?.variantPreferenceKey ?? '';
    String selected = '';
    if (preferenceKey.isNotEmpty) {
      selected = (await preferences.read(_qualified(preferenceKey)) ?? '').trim();
      _variantPreferences[preferenceKey] = selected;
    }
    if (!_variantExists(variants, selected)) {
      selected = variants.first['id']?.toString() ?? '';
    }
    _variant = selected;
  }

  /// Qt/src/MusicLibrary.cpp:296-305 `providerName()`。
  String _displayName(String id, String variant) {
    if (variant.isNotEmpty) {
      final ProviderDescriptor? descriptor = service.registry.descriptor(id);
      final String name = descriptor?.nameForVariant(variant) ?? '';
      if (name.isNotEmpty) {
        return name;
      }
    }
    final String name = service.registry.name(id);
    return name.isEmpty ? id : name;
  }

  static bool _variantExists(List<Map<String, Object?>> variants, String id) {
    if (id.isEmpty) {
      return false;
    }
    for (final Map<String, Object?> value in variants) {
      if (value['id']?.toString() == id) {
        return true;
      }
    }
    return false;
  }

  /// Qt 落盘键带 `panel/` 前缀（Qt/src/Host.cpp:2755,2762）。
  static String _qualified(String key) => '${PreferenceStore.prefix}$key';
}
