/// 本机收藏（喜欢的歌曲 + 自建歌单）的领域层实现。
///
/// 真值来源（逐条对齐，C++ 改写成 Dart）：
/// - `Qt/src/LocalCollections.cpp`：整份存储契约（文档形状、上限、倒序读取、
///   各 mutator 的返回值与幂等语义）。
/// - `Qt/src/MusicSiren.cpp:6-21`、`:251-335`：likedIDs/playlists 的消费方式。
/// - `Qt/src/MusicMutation.cpp`：写操作的状态文案（`status` 用的就是这些字面量）。
///
/// **持久化不是 QSettings 偏好，而是一个 JSON 文档**：Qt 把
/// `{"version":1,"provider":"siren","liked":[…],"playlists":[{id,name,createdAt,trackIDs}]}`
/// 以 `QJsonDocument::Compact` 写进 `<data>/collections/siren.json`
/// （LocalCollections.cpp:19-21、:73-85、:36-71）。本文件不碰文件系统，
/// 于是选一个**等价实现**：把同一份 Compact 文档、同一个键名
/// `collections/<provider>.json` 交给注入的 [PreferencePort] 存成一个字符串值。
/// 这样落盘内容与 Qt 逐字节同形（键名/顺序/结构一致），只是载体从「文件」变成
/// 「后端的一个键」——报告里必须写明这一处差异。
///
/// 本文件是纯 Dart：不 import flutter、不 import dart:io。
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../basic/basic_models.dart';
import '../../data/storage/preference_store.dart';

/// 本机收藏存储：喜欢的歌曲 id 与自建歌单。
///
/// 同步读缓存（[likedIds]、[playlists]、[isLiked]、[playlistTrackIds]、
/// [likedCount]）全部走内存；所有写入经 [load] 之后由串行队列落到
/// [PreferencePort]，因此并发调用不会互相覆盖。
class LocalCollectionStore implements BasicLocalCollections {
  /// 用注入的 [port] 建库；[provider] 决定文档里的 provider 字段与键名
  /// （Qt 的 `m_provider`，LocalCollections.cpp:13-21）。
  ///
  /// 构造不读盘：Qt 的构造函数末尾会 `load()`，但 Dart 端口是异步的，
  /// 构造函数不能等待，所以读取放在 [load]（与 `LyricsController.create`
  /// 同一取舍：Qt 同步读、Dart 异步化）。
  ///
  /// [clock] 只用于测试注入（Qt 用 `QDateTime::currentMSecsSinceEpoch()`，
  /// LocalCollections.cpp:185）。
  LocalCollectionStore({
    required this.port,
    String provider = sirenProvider,
    DateTime Function()? clock,
  })  : _provider = provider.trim(),
        _clock = clock ?? DateTime.now;

  /// 注入的持久化后端（`PreferencePort` 三方法：read/write/remove）。本类从不
  /// 绕过它直接碰文件。
  final PreferencePort port;

  /// Qt `m_provider`（已 trim）。
  final String _provider;

  final DateTime Function() _clock;

  /// 文档版本号；Qt 只认 1（LocalCollections.cpp:44）。
  static const int documentVersion = 1;

  /// 歌单数量上限（`m_playlists.size() >= 200`，LocalCollections.cpp:180）。
  static const int maxPlaylists = 200;

  /// 歌单名称上限，单位是 **UCS-4 码点**（`title.toUcs4().size() > 100`，
  /// LocalCollections.cpp:180、:195）。不是 UTF-16 码元数，也不是字节数。
  static const int maxTitleRunes = 100;

  /// 文档大小上限：Qt 在 `file.size() > 16 * 1024 * 1024` 时整份忽略
  /// （LocalCollections.cpp:40）。
  static const int maxDocumentBytes = 16 * 1024 * 1024;

  /// 键名前缀：Qt 的 `<storage>/<provider>.json` 在偏好后端里的等价形状。
  static const String keyPrefix = 'collections/';

  /// 空歌单哨兵：Qt 的 `createPlaylist` 在拒绝时返回**空 QJsonObject**
  /// （LocalCollections.cpp:180-182），调用方用 `isEmpty()` 判断。Dart 侧等价物
  /// 是 `id` 为空的 [BasicLocalPlaylist]；[createPlaylist] 拒绝时返回它。
  static const BasicLocalPlaylist emptyPlaylist =
      BasicLocalPlaylist(id: '', title: '');

  /// 本 store 的偏好键（`collections/siren.json`）。
  String get storageKey => '$keyPrefix$_provider.json';

  /// 内存里的喜欢列表，**存储顺序**（添加顺序）；对外读取时才反转。
  List<String> _liked = <String>[];

  /// 内存里的歌单，顺序与 Qt `m_playlists` 一致（新建 prepend / 载入按
  /// createdAt 降序）。
  List<_PlaylistRecord> _playlists = <_PlaylistRecord>[];

  String _status = '';

  /// 最近一次写操作的结果文案（Qt 里这些字面量分散在 MusicMutation.cpp 与
  /// MusicSiren.cpp 的 `status` 赋值点）。空串 = 还没有结论。
  String get status => _status;

  /// 串行写队列：Qt 是单线程 + 同步写，Dart 侧用一个 Future 链保证
  /// 「后一次写一定看到前一次写的内存状态」，不会交叉覆盖。
  Future<void> _pending = Future<void>.value();

  /// 把 [action] 追加到串行队列；返回值是**本条**的结果，队列本身永不因为
  /// 上一条抛错而断掉。
  Future<T> _serialize<T>(Future<T> Function() action) {
    final Future<T> next = _pending.then((_) => action());
    _pending = next.then<void>(
      (_) {},
      // 队列只关心「上一条结束了」，不关心它是否成功：错误已经由 next 交给
      // 调用方，这里吞掉，避免未处理的异步错误把整条链打死。
      onError: (Object _) {},
    );
    return next;
  }

  // ---------------------------------------------------------------------------
  // 读（同步、走内存缓存）
  // ---------------------------------------------------------------------------

  /// 喜欢的歌曲 id，**从新到旧**（Qt `likedIDs()`，LocalCollections.cpp:87-94：
  /// 「存储按添加顺序追加，读取时反转为从新到旧」）。
  @override
  List<String> likedIds() =>
      List<String>.unmodifiable(_liked.reversed.toList(growable: false));

  /// 全部自建歌单，顺序与 Qt `playlists()` 一致（新建在最前 / 载入按
  /// createdAt 降序）。[BasicLocalPlaylist.trackCount] 是**歌单内曲目数**，
  /// 与 Qt `playlistItem` 的 `trackCount` 同义（LocalCollections.cpp:143）。
  @override
  List<BasicLocalPlaylist> playlists() => List<BasicLocalPlaylist>.unmodifiable(
        <BasicLocalPlaylist>[
          for (final _PlaylistRecord record in _playlists)
            BasicLocalPlaylist(
              id: record.id,
              title: record.name,
              trackCount: record.trackIds.length,
            ),
        ],
      );

  /// 喜欢总数（= [likedIds] 长度）。
  int get likedCount => _liked.length;

  /// [id] 是否被喜欢（Qt `isLiked`，LocalCollections.cpp:96-103；空 id 恒 false，
  /// 因为存储里不可能出现空串——`strings()` 已过滤）。
  bool isLiked(String id) => id.isNotEmpty && _liked.contains(id);

  /// [playlistId] 内的曲目 id，**从新到旧**（Qt `tracks(id)`，
  /// LocalCollections.cpp:164-176）；未知歌单返回空表。
  List<String> playlistTrackIds(String playlistId) {
    final int index = _indexOfPlaylist(playlistId);
    if (index < 0) {
      return const <String>[];
    }
    return List<String>.unmodifiable(
      _playlists[index].trackIds.reversed.toList(growable: false),
    );
  }

  // ---------------------------------------------------------------------------
  // 载入
  // ---------------------------------------------------------------------------

  /// 读后端并重建内存状态（Qt `load()`，LocalCollections.cpp:36-71）。
  ///
  /// 容错口径与 Qt 一致：键缺失、读失败、超 16 MiB、JSON 坏、`version != 1`、
  /// `provider` 不符 → **静默当作空集合**，绝不抛异常、也绝不回写。
  Future<void> load() => _serialize(() async {
        _liked = <String>[];
        _playlists = <_PlaylistRecord>[];
        final String? raw = await _readDocument();
        if (raw == null) {
          return;
        }
        final Map<String, Object?>? document = _decodeDocument(raw);
        if (document == null) {
          return;
        }
        if (_asInt(document['version']) != documentVersion) {
          return;
        }
        if (document['provider']?.toString() != _provider) {
          return;
        }
        _liked = _strings(document['liked']);
        for (final Object? entry in _asList(document['playlists'])) {
          if (entry is! Map) {
            continue;
          }
          final _PlaylistRecord? record = _PlaylistRecord.fromJson(entry);
          if (record == null) {
            continue;
          }
          _playlists.add(record);
        }
        // Qt 载入后按 createdAt 稳定降序（LocalCollections.cpp:60-70）。Dart 的
        // List.sort 不稳定，这里用原始下标做次级键，保证同毫秒的歌单顺序不变。
        final List<int> order = <int>[for (int i = 0; i < _playlists.length; i++) i];
        order.sort((int left, int right) {
          final int byTime = _playlists[right]
              .createdAt
              .compareTo(_playlists[left].createdAt);
          return byTime != 0 ? byTime : left.compareTo(right);
        });
        _playlists = <_PlaylistRecord>[for (final int at in order) _playlists[at]];
      });

  // ---------------------------------------------------------------------------
  // 喜欢（写）
  // ---------------------------------------------------------------------------

  /// 切换 [id] 的喜欢状态，返回**切换后**的状态（true = 现在是喜欢的）。
  ///
  /// Qt 的等价点是 MusicMutation 的 like 分支：`enabled = !isLiked(id)` 再
  /// `setLiked(id, enabled)`。空 id 无法写入（Qt `setLiked` 返回 false），
  /// 返回 false 并把 [status] 置为 `无法写入本地收藏`。
  Future<bool> toggleLike(String id) => _serialize(() async {
        final bool liked = isLiked(id);
        final (bool accepted, bool changed) = _setLiked(id, !liked);
        if (!accepted) {
          _status = '无法写入本地收藏';
          return false;
        }
        if (changed) {
          await _save();
        }
        _status = liked ? '已从喜欢的歌曲移除' : '已加入喜欢的歌曲';
        return !liked;
      });

  /// 标为喜欢（幂等：已喜欢不重复写）。
  Future<void> like(String id) => _serialize(() async {
        final (bool accepted, bool changed) = _setLiked(id, true);
        if (!accepted) {
          _status = '无法写入本地收藏';
          return;
        }
        if (changed) {
          await _save();
        }
        _status = '已加入喜欢的歌曲';
      });

  /// 取消喜欢（幂等：本来就不喜欢不写）。
  Future<void> unlike(String id) => _serialize(() async {
        final (bool accepted, bool changed) = _setLiked(id, false);
        if (!accepted) {
          _status = '无法写入本地收藏';
          return;
        }
        if (changed) {
          await _save();
        }
        _status = '已从喜欢的歌曲移除';
      });

  /// Qt `setLiked(id, liked)`（LocalCollections.cpp:105-126）逐行等价：
  /// 空 id → 拒绝；已存在且 liked → 接受但**不写**；已存在且 !liked → 删除；
  /// 不存在且 !liked → 接受不写；不存在且 liked → 追加到**末尾**（存储顺序，
  /// 对外读取时才反转）。
  ///
  /// 返回 `(accepted, changed)`：`accepted == false` 只有空 id 一种（Qt 返回
  /// false）；`changed == false` 表示内存没动、因此**不能**落盘（Qt 的幂等分支
  /// 直接 return true，从不调用 save()）。
  (bool, bool) _setLiked(String id, bool liked) {
    if (id.isEmpty) {
      return (false, false);
    }
    final int at = _liked.indexOf(id);
    if (at >= 0) {
      if (liked) {
        return (true, false);
      }
      _liked.removeAt(at);
      return (true, true);
    }
    if (!liked) {
      return (true, false);
    }
    _liked.add(id);
    return (true, true);
  }

  // ---------------------------------------------------------------------------
  // 歌单（写）
  // ---------------------------------------------------------------------------

  /// 新建歌单，成功返回带新 id 的歌单，被拒绝时返回 [emptyPlaylist]
  /// （id 为空串 —— Qt 返回空 QJsonObject，LocalCollections.cpp:178-190）。
  ///
  /// 拒绝条件（全部照 Qt）：title 去空白后为空、超 [maxTitleRunes] 个码点、
  /// 已有 [maxPlaylists] 个歌单。新歌单**插到列表最前**，与 Qt 的 `prepend` 一致。
  Future<BasicLocalPlaylist> createPlaylist(String title) => _serialize(() async {
        final String name = title.trim();
        if (name.isEmpty) {
          _status = '请输入 1–$maxTitleRunes 字歌单名称';
          return emptyPlaylist;
        }
        if (name.runes.length > maxTitleRunes) {
          _status = '无法创建歌单，请检查名称或数量上限';
          return emptyPlaylist;
        }
        if (_playlists.length >= maxPlaylists) {
          _status = '无法创建歌单，请检查名称或数量上限';
          return emptyPlaylist;
        }
        final _PlaylistRecord record = _PlaylistRecord(
          id: _newId(),
          name: name,
          createdAt: _clock().millisecondsSinceEpoch,
          trackIds: <String>[],
        );
        _playlists.insert(0, record);
        await _save();
        _status = '已创建歌单：$name';
        return BasicLocalPlaylist(id: record.id, title: record.name);
      });

  /// 改名（Qt `renamePlaylist`，LocalCollections.cpp:192-203）：歌单不存在、
  /// 名称空、超 [maxTitleRunes] 码点 → 不写，[status] 记失败文案。
  Future<void> renamePlaylist(String id, String title) => _serialize(() async {
        final int index = _indexOfPlaylist(id);
        final String name = title.trim();
        if (index < 0 || name.isEmpty || name.runes.length > maxTitleRunes) {
          _status = '无法重命名歌单';
          return;
        }
        _playlists[index] = _playlists[index].copyWith(name: name);
        await _save();
        _status = '已重命名歌单';
      });

  /// 删除歌单（Qt `deletePlaylist`，LocalCollections.cpp:205-213）：不存在 →
  /// 不写，[status] 记 `无法删除歌单`。
  Future<void> deletePlaylist(String id) => _serialize(() async {
        final int index = _indexOfPlaylist(id);
        if (index < 0) {
          _status = '无法删除歌单';
          return;
        }
        _playlists.removeAt(index);
        await _save();
        _status = '已删除歌单';
      });

  /// 往歌单里加一首（Qt `addTrack`，LocalCollections.cpp:215-232）：歌单不存在
  /// 或 [trackId] 空 → 不写，[status] 记 `无法写入本地歌单`；已在歌单里 →
  /// 幂等不写；否则**追加到末尾**（存储顺序，对外读取时反转）。
  Future<void> addTrack(String playlistId, String trackId) =>
      _serialize(() async {
        final int index = _indexOfPlaylist(playlistId);
        if (index < 0 || trackId.isEmpty) {
          _status = '无法写入本地歌单';
          return;
        }
        if (_playlists[index].trackIds.contains(trackId)) {
          return;
        }
        _playlists[index] = _playlists[index]
            .copyWith(trackIds: <String>[..._playlists[index].trackIds, trackId]);
        await _save();
      });

  /// 从歌单里移除一首（Qt `removeTrack`，LocalCollections.cpp:234-251）：
  /// 歌单不存在 → 不写，[status] 记 `无法写入本地歌单`；**曲目不在歌单里也算
  /// 成功**（Qt 只在找到时才 break，函数末尾恒 return true）；找到则只删第一个。
  Future<void> removeTrack(String playlistId, String trackId) =>
      _serialize(() async {
        final int index = _indexOfPlaylist(playlistId);
        if (index < 0) {
          _status = '无法写入本地歌单';
          return;
        }
        final int at = _playlists[index].trackIds.indexOf(trackId);
        if (at < 0) {
          return;
        }
        final List<String> next = <String>[..._playlists[index].trackIds]
          ..removeAt(at);
        _playlists[index] = _playlists[index].copyWith(trackIds: next);
        await _save();
      });

  int _indexOfPlaylist(String id) {
    if (id.isEmpty) {
      return -1;
    }
    return _playlists.indexWhere((_PlaylistRecord record) => record.id == id);
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  /// 整份文档落盘（Qt `save()`，LocalCollections.cpp:73-85）。
  ///
  /// Qt 的所有 mutator 都**忽略** `save()` 的返回值（内存照改，写失败不上报），
  /// 这里保持同样口径：后端抛错只吞掉，不改内存、不改 [status]。
  Future<void> _save() async {
    final Map<String, Object?> document = <String, Object?>{
      'version': documentVersion,
      'provider': _provider,
      'liked': _liked,
      'playlists': <Object?>[
        for (final _PlaylistRecord record in _playlists) record.toJson(),
      ],
    };
    try {
      await port.write(storageKey, jsonEncode(document));
    } catch (_) {
      // 与 Qt 同口径：写失败不改变调用方看到的结果。
    }
  }

  Future<String?> _readDocument() async {
    try {
      return await port.read(storageKey);
    } catch (_) {
      // 读不到 = 空集合（Qt 打不开文件也是这个分支）。
      return null;
    }
  }

  /// 解析文档；超限、坏 JSON、非对象一律返回 null（＝忽略整份文件）。
  Map<String, Object?>? _decodeDocument(String raw) {
    // Qt 的上限比的是**字节**（`file.size()`）。UTF-8 长度恒 ≥ UTF-16 码元数，
    // 所以先用 length 做便宜的粗筛，再按字节精确判一次。
    if (raw.length > maxDocumentBytes) {
      return null;
    }
    if (utf8.encode(raw).length > maxDocumentBytes) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Qt `strings()`（LocalCollections.cpp:23-34）：只留非空字符串并去重。
  static List<String> _strings(Object? value) {
    final List<String> result = <String>[];
    for (final Object? entry in _asList(value)) {
      if (entry is! String || entry.isEmpty) {
        continue;
      }
      if (result.contains(entry)) {
        continue;
      }
      result.add(entry);
    }
    return result;
  }

  static List<Object?> _asList(Object? value) =>
      value is List ? value : const <Object?>[];

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  static final math.Random _random = math.Random();

  /// 新歌单 id：Qt 用 `QUuid::createUuid().toString(WithoutBraces)`
  /// （LocalCollections.cpp:183），这里生成同形状的 v4 UUID（32 个十六进制
  /// 字符 + 4 个连字符，无花括号）。
  static String _newId() {
    final List<int> bytes =
        List<int>.generate(16, (_) => _random.nextInt(256), growable: false);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final String hex = bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

/// 一份歌单的存储记录（Qt `m_playlists` 里的 QJsonObject：
/// `{id, name, createdAt, trackIDs}`，LocalCollections.cpp:48-59、:55-58）。
class _PlaylistRecord {
  const _PlaylistRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.trackIds,
  });

  final String id;
  final String name;
  final int createdAt;

  /// 曲目 id，**存储顺序**（加入顺序）；对外读取时才反转。
  final List<String> trackIds;

  _PlaylistRecord copyWith({String? name, List<String>? trackIds}) =>
      _PlaylistRecord(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        trackIds: trackIds ?? this.trackIds,
      );

  /// Qt 的持久化字段名逐字照抄（`trackIDs` 大写 ID）。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'trackIDs': trackIds,
      };

  /// 反序列化；`id` 空或 `name.trim()` 空返回 null（Qt load 直接 skip，
  /// LocalCollections.cpp:52-54）。
  static _PlaylistRecord? fromJson(Map<Object?, Object?> json) {
    final Object? rawId = json['id'];
    final Object? rawName = json['name'];
    final String id = rawId is String ? rawId : '';
    final String name = rawName is String ? rawName.trim() : '';
    if (id.isEmpty || name.isEmpty) {
      return null;
    }
    final Object? rawCreated = json['createdAt'];
    return _PlaylistRecord(
      id: id,
      name: name,
      createdAt: rawCreated is num ? rawCreated.toInt() : 0,
      trackIds: LocalCollectionStore._strings(json['trackIDs']),
    );
  }
}
