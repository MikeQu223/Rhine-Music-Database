/// 通知栏/锁屏封面的**本地真实资源**缓存。
///
/// 为什么需要这一层：系统媒体通知的封面必须是本地文件路径
/// （`MediaSessionHost` 用 `BitmapFactory.decodeFile` 读），而 Siren 的
/// `SirenSong.cover` 是远端 URL。直接把 URL 塞进 `coverPath` 只会得到空封面，
/// 所以封面要在这里落成应用私有目录里的真实图片文件。
///
/// 三条硬约束（MUST）：
///  1. **资源-only**：只抓封面字节、只写自己的目录；不新建播放器/后端/队列副本，
///     也不碰播放状态——它是"取一张图"的工具，不是第二个播放链路。
///  2. **有界**：条目数、单条字节、总量、超时都有上限；超限时按最后使用时间淘汰
///     最旧的条目，绝不无限增长（缓存目录是 rebuildable 的，删掉只影响一次加载）。
///  3. **不串台**：文件名只由 URL 派生，A 与 B 的图各自独立落地；调用方再用
///     playing generation 校验"这次结果仍属于当前曲目"，因此旧曲目 A 的迟到结果
///     不可能覆盖 B 的封面。
///
/// 失败一律返回 null（没有目录、没有网络、404、不是图片……），调用方如实留空，
/// 不抛异常、不重试失控——通知没有封面绝不是崩溃的理由。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 封面缓存的默认上限：16 条 / 16 MiB / 单条 4 MiB。
const int kBasicArtMaxEntries = 16;
const int kBasicArtMaxTotalBytes = 16 * 1024 * 1024;
const int kBasicArtMaxEntryBytes = 4 * 1024 * 1024;

/// 把远端封面 URL 落成本地可解码文件的最小缓存。
class BasicArtCache {
  BasicArtCache({
    required Future<String?> Function() directory,
    HttpClient? client,
    this.maxEntries = kBasicArtMaxEntries,
    this.maxTotalBytes = kBasicArtMaxTotalBytes,
    this.maxEntryBytes = kBasicArtMaxEntryBytes,
    this.timeout = const Duration(seconds: 12),
  })  : _directory = directory,
        _client = client;

  /// 平台缓存目录的来源（Application.cacheDir）。返回 null 表示这一平台没有可写
  /// 目录，此时所有请求都如实返回 null。
  final Future<String?> Function() _directory;

  /// 注入点：默认自建 HttpClient，测试可注入假实现（不触网）。
  final HttpClient? _client;

  final int maxEntries;
  final int maxTotalBytes;
  final int maxEntryBytes;
  final Duration timeout;

  HttpClient? _ownClient;
  bool _closed = false;
  int _generation = 0;

  /// 同一 URL 的并发请求只发一次：滚动/重绘会短时间内重复问同一张图。
  final Map<String, Future<String?>> _inflight = <String, Future<String?>>{};

  /// 递增的"使用代次"。每次 [localPath] 命中或写入都算一次使用，
  /// 淘汰时用它保证**正在被本次流程使用**的条目最后才被考虑删除。
  int _useCounter = 0;
  final Map<String, int> _lastUse = <String, int>{};

  /// 当前缓存目录；用于测试与诊断，不代表持久证据。
  String? get activeDirectory => _activeDirectory;
  String? _activeDirectory;

  /// 让"这本曲目的封面"和"当前播放代次"绑定的标记；调用方只认最新代次的结果。
  int get generation => _generation;

  /// 取本地路径，不存在就抓一次。永远不抛：失败返回 null。
  Future<String?> localPath(String url) {
    final String normalized = url.trim();
    if (_closed || normalized.isEmpty) {
      return Future<String?>.value(null);
    }
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return Future<String?>.value(null);
    }
    final String key = _keyOf(normalized);
    // `_cachedPath` 摸的是真实文件系统（existsSync/lengthSync/setLastModifiedSync），
    // 这些同步调用在任何 I/O 错误上都会抛；本方法承诺"永不抛"，所以在调用点收敛，
    // 不让一个坏目录把异常漏给调用方，也不让它顺带跳过真正的抓取。
    String? cached;
    try {
      cached = _cachedPath(key);
    } on FileSystemException {
      cached = null;
    }
    if (cached != null) {
      _lastUse[key] = ++_useCounter;
      return Future<String?>.value(cached);
    }
    final Future<String?>? pending = _inflight[key];
    if (pending != null) {
      return pending;
    }
    final Future<String?> started = _fetch(normalized, key);
    _inflight[key] = started;
    return started.whenComplete(() {
      _inflight.remove(key);
    });
  }

  /// 曲目变化时推进代次；调用方拿旧代次的结果去发布时必须丢弃。
  void beginGeneration() {
    _generation++;
  }

  Future<void> close() async {
    _closed = true;
    _inflight.clear();
    _ownClient?.close(force: true);
    _ownClient = null;
  }

  // ---------------------------------------------------------------- internals

  String? _cachedPath(String key) {
    final String? dir = _activeDirectory;
    if (dir == null) {
      return null;
    }
    final String path = _pathOf(dir, key);
    final File file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    if (file.lengthSync() <= 0) {
      // 上次写到一半就断了：删掉重来，别把 0 字节当封面。
      try {
        file.deleteSync();
      } on FileSystemException {
        // 删不掉也无所谓：下面会重新抓。
      }
      return null;
    }
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // 时间戳更新失败只影响淘汰顺序，不影响正确性。
    }
    return path;
  }

  Future<String?> _fetch(String url, String key) async {
    final String? dir = await _resolveDirectory();
    if (dir == null) {
      return null;
    }
    final String path = _pathOf(dir, key);
    final String tempPath = '$path.part';
    HttpClient? client;
    try {
      client = _client ?? (_ownClient ??= HttpClient());
      client.connectionTimeout = timeout;
      final HttpClientRequest request =
          await client.getUrl(Uri.parse(url)).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'image/*');
      final HttpClientResponse response =
          await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final int declared = response.contentLength;
      if (declared > maxEntryBytes) {
        await response.drain<void>();
        return null;
      }
      final Uint8List bytes = await _readBounded(response).timeout(timeout);
      if (bytes.isEmpty) {
        return null;
      }
      // 原子落盘：先写 .part 再 rename，任何时刻都不会有"半个封面"被读到。
      final File temp = File(tempPath);
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(path);
      _lastUse[key] = ++_useCounter;
      try {
        await _prune(keep: path);
      } catch (_) {
        // 淘汰是**容量维护**，不是这次抓取的一部分：文件已经原子落好盘，
        // 淘汰自己抛错（目录被并发删除/条目刚好消失）不能把封面结论改成"没有"。
      }
      return path;
    } catch (_) {
      try {
        final File temp = File(tempPath);
        if (temp.existsSync()) {
          temp.deleteSync();
        }
      } on FileSystemException {
        // 清临时文件失败不该改变"这次没有封面"的结论。
      }
      return null;
    }
  }

  Future<Uint8List> _readBounded(HttpClientResponse response) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      builder.add(chunk);
      if (builder.length > maxEntryBytes) {
        // 声明长度不可信时用实际字节兜底，防止被大文件拖垮。
        break;
      }
    }
    if (builder.length > maxEntryBytes) {
      return Uint8List(0);
    }
    return builder.takeBytes();
  }

  Future<String?> _resolveDirectory() async {
    if (_activeDirectory != null) {
      return _activeDirectory;
    }
    String? base;
    try {
      base = await _directory();
    } catch (_) {
      return null;
    }
    if (base == null || base.trim().isEmpty) {
      return null;
    }
    final Directory artDir = Directory(_join(base.trim(), 'basic_art'));
    try {
      if (!artDir.existsSync()) {
        artDir.createSync(recursive: true);
      }
    } on FileSystemException {
      return null;
    }
    _activeDirectory = artDir.path;
    return _activeDirectory;
  }

  /// 按最后使用时间淘汰：条目数超限或总量超限时从最旧的开始删。
  /// [keep] 是刚写入的那条，任何情况下都不删。
  Future<void> _prune({String? keep}) async {
    final String? dir = _activeDirectory;
    if (dir == null) {
      return;
    }
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync();
    } on FileSystemException {
      return;
    }
    final List<File> files = <File>[];
    for (final FileSystemEntity entity in entries) {
      if (entity is File && entity.path.endsWith('.img')) {
        files.add(entity);
      }
    }
    if (files.length <= maxEntries) {
      int total = 0;
      for (final File file in files) {
        total += _sizeOf(file);
      }
      if (total <= maxTotalBytes) {
        return;
      }
    }
    files.sort((File a, File b) {
      final int byTime = _modifiedOf(a).compareTo(_modifiedOf(b));
      if (byTime != 0) {
        return byTime;
      }
      return a.path.compareTo(b.path);
    });
    int total = 0;
    for (final File file in files) {
      total += _sizeOf(file);
    }
    int count = files.length;
    for (final File file in files) {
      if (count <= maxEntries && total <= maxTotalBytes) {
        break;
      }
      if (keep != null && file.path == keep) {
        continue;
      }
      final int size = _sizeOf(file);
      try {
        file.deleteSync();
        count--;
        total -= size;
      } on FileSystemException {
        // 删不掉就跳过，下一次再试，不因此丢掉刚拿到的封面。
      }
    }
  }

  /// 条目大小：读不到的条目按 0 计（它要么刚被并发删掉，要么无权访问——
  /// 这两种情况下"少算一个字节"都比让整个淘汰流程抛错更接近真相）。
  static int _sizeOf(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  /// 条目时间戳：读不到就给 epoch，排序时自然排在最前（=最先被淘汰）。
  static DateTime _modifiedOf(File file) {
    try {
      return file.lastModifiedSync();
    } on FileSystemException {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  String _pathOf(String dir, String key) => _join(dir, '$key.img');

  static String _join(String base, String leaf) {
    if (base.isEmpty) {
      return leaf;
    }
    final String trimmed =
        base.endsWith(Platform.pathSeparator) || base.endsWith('/')
            ? base.substring(0, base.length - 1)
            : base;
    return '$trimmed${Platform.pathSeparator}$leaf';
  }

  /// 文件名只由 URL 派生（FNV-1a 64），不引入 crypto 依赖，也不需要跨平台稳定
  /// 的 Dart hashCode（后者只保证进程内一致）。
  static String _keyOf(String url) {
    final List<int> bytes = utf8.encode(url);
    int hash = 0xcbf29ce484222325;
    for (final int byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final String hex = hash.toRadixString(16);
    return 'art-${hex.padLeft(16, '0')}';
  }
}
