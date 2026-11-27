/// 插件（provider plugin）的数据模型与 manifest 校验。
///
/// 契约真值（与 Node 侧 `MusicBridge/core/registry.cjs`、Qt 侧
/// `Qt/src/ProviderRegistry.cpp` 同源，本文件是它们的 Dart 投影）：
/// - 必填字段 `schemaVersion == 2` / `apiVersion` / `id` / `version` / `entry.file`
///   （`MusicBridge/plugins/sdk/manifest.schema.json:6-28`）；
/// - `id` 形如 `^[a-z0-9-]{1,40}$`，且 `local` 与 `siren` 是保留 id
///   （`registry.cjs:96-99`、`plugin-package.cjs:145-147`）；
/// - Qt 侧 `compatiblePluginApi()` 实际只放行 `apiVersion == "2.0"`
///   （`ProviderRegistry.cpp:20-24` 的 `minor <= 0`）；
/// - `entry.file` 不得是绝对路径、不得含 `..` 或反斜杠（`ProviderRegistry.cpp:29-55`）；
/// - 外加 `plugin-package.cjs:138-160` 的两条硬门槛：`display.name` 与
///   `capabilities` 必须是对象，否则插件装上了也不会出现在来源列表里。
///
/// 本文件只做「能不能被宿主接受」的判定，不执行插件代码——执行由 Node worker 负责
/// （`MusicBridge/worker.cjs` + libnode），Dart 侧只负责安装、启用状态与展示。
library;

/// provider id 规则（`registry.cjs:10`）。
final RegExp pluginProviderIdPattern = RegExp(r'^[a-z0-9-]{1,40}$');

/// 内置来源的保留 id（`registry.cjs:96-99`）。
const Set<String> pluginReservedIds = <String>{'local', 'siren'};

/// 宿主接受的插件 API 版本（`ProviderRegistry.cpp:20-24`）。
const String pluginHostApiVersion = '2.0';

/// 插件 manifest：只保留宿主真的会用到的字段，其余原样留在 [raw]。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.entryFile,
    required this.publisher,
    required this.license,
    required this.capabilities,
    required this.raw,
  });

  final String id;

  /// `display.name`（`manifest.schema.json` $defs.display），宿主列表显示用。
  final String name;
  final String version;
  final String apiVersion;
  final String entryFile;
  final String publisher;
  final String license;

  /// `capabilities` 里值为 `true` 的键，按字典序，供详情页「能力 N 项」。
  final List<String> capabilities;

  /// 原始 JSON，详情页字段与未来运行时都要用。
  final Map<String, Object?> raw;

  String get label => name.isEmpty ? id : name;
}

/// manifest 校验失败原因（文案照抄 Qt `Host.cpp` 的状态串风格）。
class PluginManifestError implements Exception {
  const PluginManifestError(this.message);

  final String message;

  @override
  String toString() => message;
}

bool _isPlainMap(Object? value) => value is Map;

/// 解析并校验一份 manifest（`file` 已读成 JSON 后传进来）。
///
/// 失败抛 [PluginManifestError]，错误文案与宿主侧一致：
/// `插件 manifest 缺失` / `插件 manifest 与市场条目不一致` / 以及具体字段错误。
PluginManifest parsePluginManifest(
  Object? json, {
  String? expectedId,
  String? expectedEntry,
}) {
  if (!_isPlainMap(json)) {
    throw const PluginManifestError('插件 manifest 缺失');
  }
  final Map<Object?, Object?> map = json as Map<Object?, Object?>;
  final Object? schemaVersion = map['schemaVersion'];
  if (schemaVersion != 2) {
    throw const PluginManifestError('插件 manifest 版本不受支持');
  }
  final String id = '${map['id'] ?? ''}';
  if (!pluginProviderIdPattern.hasMatch(id)) {
    throw const PluginManifestError('插件 id 无效');
  }
  if (pluginReservedIds.contains(id)) {
    throw const PluginManifestError('插件 id 为保留 id');
  }
  if (expectedId != null && id != expectedId) {
    throw const PluginManifestError('插件 manifest 与市场条目不一致');
  }
  final String apiVersion = '${map['apiVersion'] ?? ''}';
  if (apiVersion != pluginHostApiVersion) {
    throw const PluginManifestError('插件 API 版本不兼容');
  }
  final String version = '${map['version'] ?? ''}';
  if (version.isEmpty) {
    throw const PluginManifestError('插件版本缺失');
  }
  final Object? entry = map['entry'];
  final String entryFile = _isPlainMap(entry) ? '${(entry as Map)['file'] ?? ''}' : '';
  if (entryFile.isEmpty ||
      entryFile.startsWith('/') ||
      entryFile.contains('..') ||
      entryFile.contains(r'\')) {
    throw const PluginManifestError('插件入口无效');
  }
  if (expectedEntry != null && expectedEntry.isNotEmpty && entryFile != expectedEntry) {
    throw const PluginManifestError('插件 manifest 与市场条目不一致');
  }
  final Object? display = map['display'];
  if (!_isPlainMap(display)) {
    throw const PluginManifestError('插件 display 缺失');
  }
  final Object? capabilities = map['capabilities'];
  if (!_isPlainMap(capabilities)) {
    throw const PluginManifestError('插件 capabilities 缺失');
  }
  final List<String> enabledCapabilities = <String>[
    for (final MapEntry<Object?, Object?> e in (capabilities as Map).entries)
      if (e.value == true) '${e.key}',
  ]..sort();
  return PluginManifest(
    id: id,
    name: '${(display as Map)['name'] ?? ''}'.trim(),
    version: version,
    apiVersion: apiVersion,
    entryFile: entryFile,
    publisher: '${map['publisher'] ?? ''}',
    license: '${map['license'] ?? ''}',
    capabilities: enabledCapabilities,
    raw: <String, Object?>{
      for (final MapEntry<Object?, Object?> e in map.entries) '${e.key}': e.value,
    },
  );
}

/// 市场索引里的一个条目（`index.json` 的 `plugins[]`）。
///
/// 市场索引字段全集见 `Qt/src/Host.cpp:1631-1660`：宿主只消费
/// `id / path / version / name / entry.file / files[]`，其余键原样透传给 UI。
class MarketPluginEntry {
  const MarketPluginEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.publisher,
    required this.license,
    required this.path,
    required this.entryFile,
    required this.files,
    required this.raw,
  });

  final String id;
  final String name;
  final String description;
  final String version;
  final String publisher;
  final String license;

  /// 仓库内相对目录，例如 `plugins/netease`。
  final String path;
  final String entryFile;

  /// 需要下载的相对文件名；`manifest.json` 不在其中，由安装器固定附带。
  final List<String> files;
  final Map<String, Object?> raw;

  String get label => name.isEmpty ? id : name;
}

/// 解析索引里的单个条目；`files[]` 既可能是字符串数组，也可能是 `{path}` 对象
/// （`Host.cpp:1820` 两种都吃），这里同样两种都收。
MarketPluginEntry? parseMarketEntry(Object? json) {
  if (!_isPlainMap(json)) {
    return null;
  }
  final Map<Object?, Object?> map = json as Map<Object?, Object?>;
  final String id = '${map['id'] ?? ''}';
  if (id.isEmpty) {
    return null;
  }
  final Object? entry = map['entry'];
  final String entryFile = _isPlainMap(entry) ? '${(entry as Map)['file'] ?? ''}' : '';
  final List<String> files = <String>[];
  final Object? rawFiles = map['files'];
  if (rawFiles is List) {
    for (final Object? item in rawFiles) {
      if (item is String && item.isNotEmpty) {
        files.add(item);
      } else if (_isPlainMap(item)) {
        final String path = '${(item as Map)['path'] ?? ''}';
        if (path.isNotEmpty) {
          files.add(path);
        }
      }
    }
  }
  return MarketPluginEntry(
    id: id,
    name: '${map['name'] ?? ''}'.trim(),
    description: '${map['description'] ?? ''}'.trim(),
    version: '${map['version'] ?? ''}',
    publisher: '${map['publisher'] ?? ''}',
    license: '${map['license'] ?? ''}',
    path: '${map['path'] ?? ''}',
    entryFile: entryFile,
    files: files,
    raw: <String, Object?>{
      for (final MapEntry<Object?, Object?> e in map.entries) '${e.key}': e.value,
    },
  );
}

/// 已安装插件 + 它与市场的对照结果。
class InstalledPlugin {
  const InstalledPlugin({
    required this.manifest,
    required this.enabled,
    required this.userInstalled,
    this.marketVersion = '',
  });

  final PluginManifest manifest;
  final bool enabled;

  /// 装在用户插件目录（可卸载）而不是构建期内置目录。
  final bool userInstalled;

  /// 市场索引里的版本；本机没读过市场时为空。
  final String marketVersion;

  bool get updateAvailable =>
      marketVersion.isNotEmpty && comparePluginVersion(marketVersion, manifest.version) > 0;

  String get id => manifest.id;
  String get name => manifest.label;
  String get version => manifest.version;
}

/// 语义化版本比较（`Host.cpp` 的 `pluginUpdateAvailable`）：
/// 按 `.` 切段逐段比数字；任一段不是数字则退化成字符串比较（Qt 同款退化）。
int comparePluginVersion(String a, String b) {
  final List<String> left = a.split('.');
  final List<String> right = b.split('.');
  final int count = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < count; i += 1) {
    final String l = i < left.length ? left[i] : '0';
    final String r = i < right.length ? right[i] : '0';
    final int? ln = int.tryParse(l);
    final int? rn = int.tryParse(r);
    if (ln == null || rn == null) {
      return a.compareTo(b);
    }
    if (ln != rn) {
      return ln < rn ? -1 : 1;
    }
  }
  return 0;
}
