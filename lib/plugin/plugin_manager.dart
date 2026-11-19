/// 插件市场与本地安装（PLUGIN-1）——Qt `Host` 插件子系统的 Dart 侧对应物。
///
/// 权威源（逐条对齐，便于双向核对）：
/// - 市场索引地址与 base 推导：`Qt/src/Host.cpp:1529-1534`、`:1811-1813`
///   （base = 索引 URL 去掉最后一段；文件 URL = `base/<entry.path>/<name>`）；
/// - 安装要下载的文件集合：`Host.cpp:1814-1824`（固定带 `manifest.json`，再去重
///   `entry.file` 与 `files[]`，`files[]` 元素可以是字符串或 `{path}`）；
/// - staging → 校验 → 备份 → 提交 → 回滚：`Host.cpp:1826-1899`；
/// - 状态文案：`Host.cpp:1608-1681`、`:1831-2000`（本文件的字面量与之一致）；
/// - 启用/禁用的持久化：`Host.cpp:1919-1967` 写 `<plugins 根>/plugins-state.json`
///   的 `{"disabled":[id...]}`，本文件用同一个文件名与结构。
///
/// 与 Qt 的两处**刻意差异**：
///  1. 根目录由 `plugin_paths.dart` 给出（`<pkg>/file/plugin` 外部目录），不是 Qt 的
///     `<AppLocalDataLocation>/plugins` 私有目录——用户要能直接把插件放进去；
///  2. GitHub 直连在国内常被墙：市场索引与文件下载都先试直连，再试 `v6.gh-proxy.org`
///     前缀镜像（用户指定的镜像），最后试 `gh-proxy.org`。成功的那条前缀会被记住，
///     后续文件下载不再重试失败的前缀。
///
/// 本文件不执行插件代码：`.cjs` 入口由 Node worker（libnode）加载，Dart 侧只负责把它
/// 放到 worker 会扫描的目录里，并把 `RHINE_USER_PLUGINS`（见 [PluginManager.userPluginsRoot]）
/// 交给将来的桥接启动代码。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'plugin_models.dart';
import 'plugin_paths.dart';

/// 市场索引默认地址（`Host.cpp:1529-1534`，可用 `RHINE_PLUGIN_MARKETPLACE_URL` 覆盖）。
const String defaultPluginMarketplaceUrl =
    'https://raw.githubusercontent.com/MikeQu223/Rhine-Plugin-Market/main/index.json';

/// 镜像前缀（**用户指定的顺序**，空串 = github.com 直连）。
///
/// 用法是「在 GitHub 原始链接前加 `https://<proxy>/`」，所以这些前缀都带尾斜杠，
/// 拼出来的就是 `https://v6.gh-proxy.org/https://raw.githubusercontent.com/...`。
const List<String> pluginMarketMirrorPrefixes = <String>[
  '',
  'https://gh-proxy.org/',
  'https://v4.gh-proxy.org/',
  'https://v6.gh-proxy.org/',
  'https://cdn.gh-proxy.org/',
  'https://axisnow.gh-proxy.org/',
];

/// 单级镜像的响应窗口：200ms 内没拿到响应就同时发下一级（不等前一级失败）。
///
/// 串行「先等一级彻底失败再换下一级」在真机上要等满 30s 超时，用户看到的是
/// 「一直读不出来」；这里改成**对冲**：第 i 级在 `i * 200ms` 起跑，谁先返回响应
/// 谁就赢，其余丢弃。慢但能用的镜像仍然会被采用（只要它比后面的快），
/// 彻底不通的域名同样会被记录下来给用户看。
const Duration pluginMirrorResponseWindow = Duration(milliseconds: 200);

/// 镜像前缀的人类可读名字（页脚展示用）。
String pluginMirrorLabel(String prefix) {
  if (prefix.isEmpty) {
    return 'github.com（直连）';
  }
  return prefix
      .replaceFirst('https://', '')
      .replaceFirst('http://', '')
      .replaceAll(RegExp(r'/+$'), '');
}

/// 尺寸上限：索引 8 MiB、单文件 64 MiB（`Host.cpp:1640`、`:1786`）。
const int pluginIndexLimitBytes = 8 * 1024 * 1024;
const int pluginFileLimitBytes = 64 * 1024 * 1024;

/// 单次请求超时（Qt 用 30s：`Host.cpp:1790`）。
const Duration pluginRequestTimeout = Duration(seconds: 30);

/// 一次探路的结果：赢家前缀 + 这轮里明确失败 / 太慢没回话的级别。
class _ProbeResult {
  const _ProbeResult(this.prefix, this.failed, this.slow);

  final String prefix;
  final Set<String> failed;

  /// 赢家先回话时还在飞行中、被强行断掉的级别（「未响应」的判定口径）。
  final Set<String> slow;
}

/// 一次对冲抓取的赢家：实际用的前缀 + 内容。
class _FetchWin {
  const _FetchWin(this.prefix, this.bytes);

  final String prefix;
  final Uint8List bytes;
}

/// 安装进度（`pluginMarketplaceState()` 的 install* 字段）。
class PluginInstallProgress {
  const PluginInstallProgress({
    this.installing = false,
    this.id = '',
    this.file = '',
    this.filesDone = 0,
    this.filesTotal = 0,
    this.bytes = 0,
    this.speed = 0,
    this.progress = 0,
  });

  final bool installing;
  final String id;
  final String file;
  final int filesDone;
  final int filesTotal;
  final int bytes;

  /// 字节/秒，安装中才有意义。
  final double speed;
  final double progress;

  PluginInstallProgress copyWith({
    bool? installing,
    String? id,
    String? file,
    int? filesDone,
    int? filesTotal,
    int? bytes,
    double? speed,
    double? progress,
  }) {
    return PluginInstallProgress(
      installing: installing ?? this.installing,
      id: id ?? this.id,
      file: file ?? this.file,
      filesDone: filesDone ?? this.filesDone,
      filesTotal: filesTotal ?? this.filesTotal,
      bytes: bytes ?? this.bytes,
      speed: speed ?? this.speed,
      progress: progress ?? this.progress,
    );
  }
}

/// 插件管理器的内存快照，UI 只读这个（不做 IO）。
class PluginSnapshot {
  const PluginSnapshot({
    required this.marketUrl,
    required this.loading,
    required this.status,
    required this.message,
    required this.market,
    required this.installed,
    required this.progress,
    required this.rootPath,
    required this.updates,
    this.activeHost = '',
    this.probingHost = '',
    this.deadHosts = const <String>[],
    this.mirrors = const <String>[],
  });

  final String marketUrl;
  final bool loading;

  /// 市场状态行（`已载入 N 个插件` / `插件市场读取失败` / …）。
  final String status;

  /// 操作反馈（`已安装 X` / `已卸载 X` / 拒绝文案），非空时替换列表尾注。
  final String message;
  final List<MarketPluginEntry> market;
  final List<InstalledPlugin> installed;
  final PluginInstallProgress progress;
  final String rootPath;
  final int updates;

  /// 当前（最近一次成功）使用的域名，空串 = 还没成功过。
  final String activeHost;

  /// 正在探路的域名，空串 = 没在探路。
  final String probingHost;

  /// 本次会话里未响应/失败的域名（已去重、按镜像链顺序）。
  final List<String> deadHosts;

  /// 完整镜像链（用于页脚「按顺序尝试」的展示）。
  final List<String> mirrors;

  InstalledPlugin? installedById(String id) {
    for (final InstalledPlugin plugin in installed) {
      if (plugin.id == id) {
        return plugin;
      }
    }
    return null;
  }

  MarketPluginEntry? marketById(String id) {
    for (final MarketPluginEntry entry in market) {
      if (entry.id == id) {
        return entry;
      }
    }
    return null;
  }
}

/// 插件管理器：市场读取、安装、卸载、启用状态、给 UI 的快照。
///
/// 所有网络与文件操作都串行（同一时刻只有一个安装），与 Qt 的 `marketplaceInstalling`
/// 单实例语义一致；并发调用 [install] 返回「正在安装插件，请稍候」。
class PluginManager extends ChangeNotifier {
  PluginManager({
    Future<Directory?> Function()? rootResolver,
    String? marketUrl,
    HttpClient Function()? httpClient,
  })  : _rootResolver = rootResolver ?? (() => resolvePluginRoot()),
        _marketUrl = (marketUrl ??
                Platform.environment['RHINE_PLUGIN_MARKETPLACE_URL'] ??
                defaultPluginMarketplaceUrl)
            .trim(),
        _httpClient = httpClient ?? (() => HttpClient()),
        super();

  final Future<Directory?> Function() _rootResolver;
  final String _marketUrl;
  final HttpClient Function() _httpClient;

  Directory? _root;
  List<InstalledPlugin> _installed = const <InstalledPlugin>[];
  List<MarketPluginEntry> _market = const <MarketPluginEntry>[];
  PluginInstallProgress _progress = const PluginInstallProgress();
  final Set<String> _disabled = <String>{};
  String _status = '';
  String _message = '';
  bool _loading = false;
  bool _initialized = false;

  void _notifyProgressThrottled() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProgressNotifyMs < 200) {
      return;
    }
    _lastProgressNotifyMs = now;
    notifyListeners();
  }

  /// 市场索引里本次用成功的前缀（直连=空串）；下载文件时优先用它。
  String _workingPrefix = '';

  /// 最近一次成功的前缀（页脚「当前域名」）。
  String _activePrefix = '';
  bool _activeKnown = false;

  /// 本次会话里没在窗口内响应的前缀（页脚「未响应域名」）。
  final Set<String> _deadPrefixes = <String>{};

  /// 正在探路的级别（页脚在还没成功时显示「正在尝试 …」）。
  String _probingPrefix = '';

  /// 下载进度节流：每 200ms 最多通知一次（12MB 文件逐块通知会拖慢 UI）。
  int _lastProgressNotifyMs = 0;

  /// 插件根目录绝对路径（未解析成功时为空串）。
  String get rootPath => _root?.path ?? '';

  /// 要给 Node worker 的 `RHINE_USER_PLUGINS`（`Host.cpp:1072-1073`）——桥接启动时读这个。
  String get userPluginsRoot => rootPath;

  bool get initialized => _initialized;
  bool get loading => _loading;
  bool get installing => _progress.installing;
  String get status => _status;
  String get message => _message;
  List<MarketPluginEntry> get market => List<MarketPluginEntry>.unmodifiable(_market);
  List<InstalledPlugin> get installed => List<InstalledPlugin>.unmodifiable(_installed);

  /// 市场里有可用更新的已装插件数（`Host.cpp:1645-1650` 的 `发现 N 个更新`）。
  int get updates => _installed.where((InstalledPlugin p) => p.updateAvailable).length;

  PluginSnapshot snapshot() {
    return PluginSnapshot(
      marketUrl: _marketUrl,
      loading: _loading,
      status: _status,
      message: _message,
      market: market,
      installed: installed,
      progress: _progress,
      rootPath: rootPath,
      updates: updates,
      activeHost: _activeKnown ? pluginMirrorLabel(_activePrefix) : '',
      probingHost: _probingPrefix.isEmpty ? '' : pluginMirrorLabel(_probingPrefix),
      deadHosts: <String>[
        for (final String prefix in pluginMarketMirrorPrefixes)
          if (_deadPrefixes.contains(prefix)) pluginMirrorLabel(prefix),
      ],
      mirrors: <String>[
        for (final String prefix in pluginMarketMirrorPrefixes) pluginMirrorLabel(prefix),
      ],
    );
  }

  /// 解析根目录、读已装插件与禁用状态。可重复调用（每次重新扫描磁盘）。
  Future<void> initialize() async {
    _root = await _rootResolver();
    if (_root == null) {
      _status = '插件目录不可用';
      _installed = const <InstalledPlugin>[];
      _initialized = true;
      notifyListeners();
      return;
    }
    await _loadState();
    await _scanInstalled();
    if (_status.isEmpty) {
      _status = _market.isEmpty ? '尚未读取插件市场' : _status;
    }
    _initialized = true;
    notifyListeners();
  }

  /// 读 `plugins-state.json`（`Host.cpp:1919-1967`）。
  Future<void> _loadState() async {
    _disabled.clear();
    final File file = File('${_root!.path}/plugins-state.json');
    if (!file.existsSync()) {
      return;
    }
    try {
      final Object? json = jsonDecode(await file.readAsString());
      if (json is Map && json['disabled'] is List) {
        for (final Object? id in json['disabled'] as List) {
          _disabled.add('$id');
        }
      }
    } on FormatException {
      // 坏文件当作没有禁用项：与 Qt 读失败时的行为一致（不阻断启动）。
    }
  }

  Future<void> _writeState() async {
    if (_root == null) {
      return;
    }
    final File file = File('${_root!.path}/plugins-state.json');
    final List<String> sorted = _disabled.toList()..sort();
    await file.writeAsString(jsonEncode(<String, Object?>{'disabled': sorted}), flush: true);
  }

  /// 扫已装插件目录：每个子目录里的 `manifest.json` 能被接受才算一个插件。
  Future<void> _scanInstalled() async {
    final List<InstalledPlugin> found = <InstalledPlugin>[];
    if (_root != null) {
      for (final FileSystemEntity entity in _root!.listSync(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        final String name = entity.uri.pathSegments.lastWhere((String s) => s.isNotEmpty,
            orElse: () => '');
        if (name.startsWith('.')) {
          continue;
        }
        final File manifestFile = File('${entity.path}/manifest.json');
        if (!manifestFile.existsSync()) {
          continue;
        }
        try {
          final PluginManifest manifest = parsePluginManifest(
            jsonDecode(await manifestFile.readAsString()),
          );
          found.add(InstalledPlugin(
            manifest: manifest,
            enabled: !_disabled.contains(manifest.id),
            userInstalled: true,
            marketVersion: _marketVersionOf(manifest.id),
          ));
        } on PluginManifestError {
          continue;
        } on FormatException {
          continue;
        }
      }
    }
    found.sort((InstalledPlugin a, InstalledPlugin b) => a.id.compareTo(b.id));
    _installed = found;
  }

  String _marketVersionOf(String id) {
    for (final MarketPluginEntry entry in _market) {
      if (entry.id == id) {
        return entry.version;
      }
    }
    return '';
  }

  /// 拉市场索引（`Host.cpp:1608-1690`）。失败只写状态，不抛。
  Future<void> refreshMarket() async {
    if (_loading) {
      return;
    }
    if (_marketUrl.isEmpty) {
      _status = '未配置插件市场地址';
      notifyListeners();
      return;
    }
    _loading = true;
    _status = '正在读取插件市场…';
    _message = '';
    // 每次刷新重新记「未响应域名」：页脚要反映这一轮，不是上次的历史。
    _deadPrefixes.clear();
    notifyListeners();
    try {
      final Uint8List bytes = await _fetchWithMirrors(_marketUrl, pluginIndexLimitBytes);
      final Object? json = jsonDecode(utf8.decode(bytes));
      final List<MarketPluginEntry> parsed = <MarketPluginEntry>[];
      if (json is Map && json['plugins'] is List) {
        for (final Object? item in json['plugins'] as List) {
          final MarketPluginEntry? entry = parseMarketEntry(item);
          if (entry != null) {
            parsed.add(entry);
          }
        }
      }
      _market = parsed;
      await _scanInstalled();
      _status = '已载入 ${_market.length} 个插件';
      if (updates > 0) {
        _status = '$_status · 发现 $updates 个更新';
      }
      _loading = false;
      notifyListeners();
    } on Object {
      _market = const <MarketPluginEntry>[];
      _loading = false;
      _status = '插件市场读取失败';
      notifyListeners();
    }
  }

  /// 安装（或重装/更新）市场插件：返回空串表示已受理，否则是拒绝原因。
  /// 与 Qt 一样是「立即返回 + 后台进度」，真实结果看 [status] 与 [installed]。
  Future<String> install(String id) async {
    if (_progress.installing) {
      return '正在安装插件，请稍候';
    }
    if (_root == null) {
      return '插件目录不可用';
    }
    MarketPluginEntry? entry;
    for (final MarketPluginEntry candidate in _market) {
      if (candidate.id == id) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) {
      return '插件市场中没有该插件';
    }
    final MarketPluginEntry target = entry;
    unawaited(_runInstall(target));
    return '';
  }

  Future<void> _runInstall(MarketPluginEntry entry) async {
    final Directory root = _root!;
    final String stagingPath =
        '${root.path}/.staging-${entry.id}-${DateTime.now().microsecondsSinceEpoch}';
    final Directory staging = Directory(stagingPath);
    final List<String> files = <String>['manifest.json'];
    if (entry.entryFile.isNotEmpty) {
      files.add(entry.entryFile);
    }
    files.addAll(entry.files);
    final List<String> unique = <String>[];
    for (final String name in files) {
      if (name.isNotEmpty && !unique.contains(name)) {
        unique.add(name);
      }
    }
    final String folder = entry.path.isEmpty ? 'plugins/${entry.id}' : entry.path;
    _progress = PluginInstallProgress(
      installing: true,
      id: entry.id,
      filesTotal: unique.length,
    );
    _status = '正在安装 ${entry.label}';
    _message = '';
    notifyListeners();
    final Stopwatch clock = Stopwatch()..start();
    int downloaded = 0;
    try {
      await staging.create(recursive: true);
      for (int i = 0; i < unique.length; i += 1) {
        final String name = unique[i];
        _progress = _progress.copyWith(file: name);
        notifyListeners();
        final Uri fileUri = Uri.parse('$_marketBase/$folder/$name');
        final int baseBytes = downloaded;
        final Uint8List bytes = await _fetchWithMirrors(
          fileUri.toString(),
          pluginFileLimitBytes,
          onProgress: (int received) {
            // 字节与速度按「已下载总量」算，单文件 12MB 时进度条也能动。
            final int totalBytes = baseBytes + received;
            final int elapsed = clock.elapsedMilliseconds < 1 ? 1 : clock.elapsedMilliseconds;
            _progress = _progress.copyWith(
              bytes: totalBytes,
              speed: totalBytes * 1000.0 / elapsed,
              progress: ((i + _fileFraction(received, totalBytes)) / unique.length).clamp(0.0, 1.0),
            );
            _notifyProgressThrottled();
          },
        );
        final File out = File('${staging.path}/$name');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes, flush: true);
        downloaded += bytes.length;
        final int elapsed = clock.elapsedMilliseconds < 1 ? 1 : clock.elapsedMilliseconds;
        _progress = _progress.copyWith(
          filesDone: i + 1,
          bytes: downloaded,
          speed: downloaded * 1000.0 / elapsed,
          progress: (i + 1) / unique.length,
        );
        notifyListeners();
      }
      final PluginManifest manifest = parsePluginManifest(
        jsonDecode(await File('${staging.path}/manifest.json').readAsString()),
        expectedId: entry.id,
        expectedEntry: entry.entryFile,
      );
      if (!File('${staging.path}/${manifest.entryFile}').existsSync()) {
        throw const PluginManifestError('插件 manifest 与市场条目不一致');
      }
      await _commit(root, staging, entry.id);
      _progress = const PluginInstallProgress();
      _status = '已安装 ${entry.label}';
      await _scanInstalled();
      notifyListeners();
    } on PluginManifestError catch (error) {
      await _discard(staging);
      _progress = const PluginInstallProgress();
      _status = error.message;
      notifyListeners();
    } on Object {
      await _discard(staging);
      _progress = const PluginInstallProgress();
      _status = '插件安装失败';
      notifyListeners();
    }
  }

  /// 单文件阶段的进度小数：市场索引没有文件大小，只能用已下载量与速度做一个
  /// 单调递增的软估计（不保证到 1，最后以「文件完成」为准跳一格）。
  double _fileFraction(int received, int totalBytes) {
    if (received <= 0) {
      return 0;
    }
    // 12MB 级别的常见插件入口文件：按 16MB 估；超过就贴 0.99，完成时由 filesDone 补齐。
    return (received / (16 * 1024 * 1024)).clamp(0.0, 0.99);
  }

  /// staging → 备份旧目录 → 提交 → 失败回滚（`Host.cpp:1875-1899`）。
  Future<void> _commit(Directory root, Directory staging, String id) async {
    final Directory target = Directory('${root.path}/$id');
    final Directory backup = Directory('${root.path}/.backup-$id');
    if (backup.existsSync()) {
      await backup.delete(recursive: true);
    }
    bool moved = false;
    if (target.existsSync()) {
      await target.rename(backup.path);
      moved = true;
    }
    try {
      await staging.rename(target.path);
    } on FileSystemException {
      if (moved) {
        await backup.rename(target.path);
      }
      throw const FileSystemException('无法替换已安装插件');
    }
    // 备份目录**保留**：Qt 安装成功后同样不删 `.backup-<id>`，
    // `rollbackPlugin` 依赖它（`Host.cpp:1868-1900`、`:1968-1999`）。
  }

  Future<void> _discard(Directory staging) async {
    try {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
    } on FileSystemException {
      // 删不掉不影响用户：下次安装前会清 `.staging-*`（与 Qt 同）。
    }
  }

  /// 卸载：只删插件目录，不碰账号数据（`Host.cpp:797-826` 的确认文案语义）。
  Future<String> uninstall(String id) async {
    if (_root == null) {
      return '插件目录不可用';
    }
    final Directory target = Directory('${_root!.path}/$id');
    if (!target.existsSync()) {
      return '插件未安装';
    }
    try {
      await target.delete(recursive: true);
      final Directory backup = Directory('${_root!.path}/.backup-$id');
      if (backup.existsSync()) {
        await backup.delete(recursive: true);
      }
      _disabled.remove(id);
      await _writeState();
      await _scanInstalled();
      // _message = '已卸载 $id';
      notifyListeners();
      return '';
    } on FileSystemException {
      _message = '插件卸载失败';
      notifyListeners();
      return '插件卸载失败';
    }
  }

  /// 启用/禁用；被禁用的插件不会出现在来源列表里（worker 侧读同一个状态文件）。
  Future<void> setEnabled(String id, bool enabled) async {
    if (enabled) {
      _disabled.remove(id);
    } else {
      _disabled.add(id);
    }
    await _writeState();
    await _scanInstalled();
    _message = enabled ? '已启用插件' : '已禁用插件';
    notifyListeners();
  }

  bool enabled(String id) => !_disabled.contains(id);

  /// 是否存在可回滚的上一版本（Qt 用 `.backup-<id>`，安装成功后保留）。
  bool hasRollback(String id) {
    if (_root == null) {
      return false;
    }
    return Directory('${_root!.path}/.backup-$id').existsSync();
  }

  /// 回滚到上一版本（`Host.cpp:1968-1999`）：当前目录挪到 `.rollback-*`，
  /// 备份提为当前目录，失败则换回；成功后丢弃 `.rollback-*`。
  Future<String> rollback(String id) async {
    if (_root == null) {
      return '插件目录不可用';
    }
    if (!pluginProviderIdPattern.hasMatch(id)) {
      return '插件 id 无效';
    }
    final Directory root = _root!;
    final Directory target = Directory('${root.path}/$id');
    final Directory backup = Directory('${root.path}/.backup-$id');
    if (!backup.existsSync()) {
      return '没有可回滚的版本';
    }
    final Directory staging = Directory(
      '${root.path}/.rollback-$id-${DateTime.now().microsecondsSinceEpoch}',
    );
    bool moved = false;
    if (target.existsSync()) {
      try {
        await target.rename(staging.path);
        moved = true;
      } on FileSystemException {
        return '插件回滚失败';
      }
    }
    try {
      await backup.rename(target.path);
    } on FileSystemException {
      if (moved) {
        await staging.rename(target.path);
      }
      return '插件回滚失败';
    }
    await _discard(staging);
    await _scanInstalled();
    _message = '插件已回滚';
    notifyListeners();
    return '';
  }

  String get _marketBase {
    final int slash = _marketUrl.lastIndexOf('/');
    if (slash <= 0) {
      return _marketUrl;
    }
    return _marketUrl.substring(0, slash);
  }

  /// 对冲探路 + 单连接下载（用户要求：每 200ms 无响应就推进到下一级）。
  ///
  /// 两段式，避免「6 个镜像同时下一份 12MB」把流量翻六倍：
  /// 1. 探路：第 i 级在 `i * 200ms` 起跑，只要 HTTP 头（不读 body）。谁先返回 200
  ///    谁就是这一轮的镜像，其余连接立刻强制关闭（服务端跟着断）。
  /// 2. 下载：只在这一个镜像上开一条连接读 body，按块回报进度。
  ///
  /// 探路阶段没在窗口内响应的级别记进「未响应域名」，页面末尾展示给用户。
  /// 下载阶段失败会把这个镜像拉黑并重新探路（最多把整条链走完）。
  Future<Uint8List> _fetchWithMirrors(
    String url,
    int limit, {
    void Function(int received)? onProgress,
  }) async {
    final List<String> tried = <String>[];
    Object? lastError;
    while (true) {
      final List<String> candidates = <String>[
        if (_workingPrefix.isNotEmpty || _activeKnown) _workingPrefix,
        ...pluginMarketMirrorPrefixes,
      ].where((String prefix) => !tried.contains(prefix)).toList();
      if (candidates.isEmpty) {
        throw lastError ?? const HttpException('插件市场读取失败');
      }
      final _ProbeResult probe = await _probeMirror(url, candidates);
      final String prefix = probe.prefix;
      _workingPrefix = prefix;
      _activePrefix = prefix;
      _activeKnown = true;
      _probingPrefix = '';
      // 「未响应」= 明确失败或太慢被断掉的级别；赢家自己绝不进这个列表。
      _deadPrefixes.addAll(probe.failed);
      _deadPrefixes.addAll(probe.slow);
      _deadPrefixes.remove(prefix);
      notifyListeners();
      try {
        return await _getBody(
          prefix.isEmpty ? url : '$prefix$url',
          limit,
          onProgress,
        );
      } on Object catch (error) {
        // 这个镜像头能通但正文不通：拉黑后换下一级。
        lastError = error;
        tried.add(prefix);
        _deadPrefixes.add(prefix);
        notifyListeners();
      }
    }
  }

  /// 起跑窗口内谁先回 200 就用谁；返回胜出前缀（直连是空串）与失败情况。
  Future<_ProbeResult> _probeMirror(String url, List<String> candidates) async {
    final Completer<String> winner = Completer<String>();
    final Set<String> failed = <String>{};
    final Set<String> slow = <String>{};
    final List<Timer> timers = <Timer>[];
    final List<HttpClient> clients = <HttpClient>[];
    final Set<int> started = <int>{};
    Object? lastError;
    int settled = 0;

    void launch(int index) {
      if (winner.isCompleted || index >= candidates.length || started.contains(index)) {
        return;
      }
      started.add(index);
      final String prefix = candidates[index];
      _probingPrefix = prefix;
      notifyListeners();
      final String candidate = prefix.isEmpty ? url : '$prefix$url';
      final HttpClient client = _httpClient()
        ..connectionTimeout = pluginRequestTimeout
        ..userAgent = 'RhineMusic/1.0 (+plugin-manager)';
      clients.add(client);
      () async {
        final HttpClientRequest request = await client.getUrl(Uri.parse(candidate));
        final HttpClientResponse response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          // 非 200 也是「通了但不可用」，直接记死。
          throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(candidate));
        }
        // 只要头：把 body 扔掉，连接由胜者之外的 client.close 断掉。
        unawaited(response.drain<void>().catchError((Object _) {}));
        if (!winner.isCompleted) {
          winner.complete(prefix);
        }
      }()
          .catchError((Object error) {
        lastError = error;
        settled += 1;
        failed.add(prefix);
        if (!winner.isCompleted) {
          if (started.length < candidates.length) {
            for (int i = 0; i < candidates.length; i += 1) {
              if (!started.contains(i)) {
                launch(i);
                break;
              }
            }
          } else if (settled >= candidates.length) {
            winner.completeError(lastError!, StackTrace.current);
          }
        }
      });
    }

    launch(0);
    for (int i = 1; i < candidates.length; i += 1) {
      final int index = i;
      timers.add(Timer(pluginMirrorResponseWindow * i, () {
        if (winner.isCompleted || started.contains(index)) {
          return;
        }
        // 到点了还没轮到这一级：前面起跑过但没回话的，就是「未响应」。
        for (int k = 0; k < index; k += 1) {
          if (started.contains(k) && !winner.isCompleted) {
            slow.add(candidates[k]);
          }
        }
        launch(index);
      }));
    }

    try {
      final String prefix = await winner.future;
      // 赢家出现时仍在飞行中的级别：它们「没在窗口内响应」，算慢。
      for (int k = 0; k < candidates.length; k += 1) {
        if (started.contains(k) && candidates[k] != prefix && !failed.contains(candidates[k])) {
          slow.add(candidates[k]);
        }
      }
      slow.remove(prefix);
      failed.remove(prefix);
      return _ProbeResult(prefix, failed, slow);
    } finally {
      for (final Timer timer in timers) {
        timer.cancel();
      }
      for (final HttpClient client in clients) {
        client.close(force: true);
      }
    }
  }

  /// 单连接下载：30s 超时、只认 200、有上限（`Host.cpp:1786-1795`），按块回报进度。
  Future<Uint8List> _getBody(
    String url,
    int limit, [
    void Function(int received)? onProgress,
  ]) async {
    final HttpClient client = _httpClient()
      ..connectionTimeout = pluginRequestTimeout
      ..userAgent = 'RhineMusic/1.0 (+plugin-manager)';
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final HttpClientResponse response =
          await request.close().timeout(pluginRequestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(pluginRequestTimeout)) {
        builder.add(chunk);
        onProgress?.call(builder.length);
        if (builder.length > limit) {
          throw HttpException('响应超过上限', uri: Uri.parse(url));
        }
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
