// Qt → Flutter 迁移：曲库领域（MusicLibrary / MusicApi / MusicMutation /
// MusicSession / MusicLocal / LocalCollections）的静态断言测试。
//
// RED/GREEN 未执行：本卡只允许写测试，禁止 dart/flutter test/analyze。
// 每条断言上方注释给出 Qt 源证据（文件:行），断言必须能体现该语义。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/library/music_library.dart';

// ---------------------------------------------------------------------------
// 端口替身：逐条实现 lib/domain/library/music_library.dart 冻结端口，
// 任何一条签名漂移都会让本文件静态失败（这是有意为之的契约闸门）。
// ---------------------------------------------------------------------------

class _Prefs implements LibraryPreferencesPort {
  _Prefs([Map<String, String>? seed]) : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) {
    _values[key] = value;
  }
}

class _Cancel implements Cancelable {
  _Cancel([this.onCancel]);

  final void Function()? onCancel;
  bool cancelled = false;

  @override
  void cancel() {
    cancelled = true;
    onCancel?.call();
  }
}

class _Host implements LibraryHostPort {
  _Host({
    this.localEnabled = false,
    this.authenticated = false,
    this.offline = false,
    this.saveCredentialError = '',
  });

  @override
  final bool localEnabled;

  @override
  final bool authenticated;

  @override
  final bool offline;

  final List<String> external = <String>[];
  final List<String> cookiePayloads = <String>[];
  final List<int> cookieEpochs = <int>[];
  final List<String> cookieKeys = <String>[];
  final List<Cancelable> scheduled = <Cancelable>[];
  final List<String> officialIds = <String>[];
  int clearCacheCount = 0;
  int invalidateCount = 0;
  int logoutCount = 0;
  String saveCredentialError;
  String provider = '';
  String edition = '';

  @override
  Future<void> clearCache() async {
    clearCacheCount++;
  }

  @override
  Future<void> invalidateMetadata() async {
    invalidateCount++;
  }

  @override
  Future<void> openExternal(String url) async {
    external.add(url);
  }

  @override
  String fromLink(String text) => text;

  @override
  Future<String?> loadCover(String url) async => '';

  @override
  Future<void> acceptCookies(String cookies, int epoch, String credentialKey) async {
    cookiePayloads.add(cookies);
    cookieEpochs.add(epoch);
    cookieKeys.add(credentialKey);
  }

  @override
  String qr(String key) => 'qr:' + key;

  @override
  String qrImage(String data) => 'img:' + data;

  @override
  bool hasCredential(String provider) => true;

  @override
  Future<String> saveCredential() async => saveCredentialError;

  @override
  Future<void> logout() async {
    logoutCount++;
  }

  @override
  Future<void> setProvider(String provider) async {
    this.provider = provider;
  }

  @override
  Future<void> setKugouEdition(String edition) async {
    this.edition = edition;
  }

  @override
  Future<void> playOfficial(String id, void Function(String message) done) async {
    officialIds.add(id);
    done('');
  }

  @override
  Cancelable schedule(Duration delay, void Function() action) {
    final cancelable = _Cancel(action);
    scheduled.add(cancelable);
    return cancelable;
  }
}

class _Wire implements HostRequestPort {
  final List<({String route, JsonMap params})> calls = <({String route, JsonMap params})>[];
  final List<HostReply> queue = <HostReply>[];
  HostReply fallback = const HostReply(<String, Object?>{'code': 200});

  @override
  Future<HostReply> requestJson(String route, JsonMap params) {
    calls.add((route: route, params: params));
    if (queue.isEmpty) {
      return Future<HostReply>.value(fallback);
    }
    return Future<HostReply>.value(queue.removeAt(0));
  }
}

class _Playback implements PlaybackPort {
  JsonMap _current = <String, Object?>{};
  String _cover = '';
  List<JsonMap> _items = <JsonMap>[];
  List<String> _ids = <String>[];
  int _index = -1;
  List<JsonMap> _history = <JsonMap>[];
  final List<JsonMap> played = <JsonMap>[];
  final List<List<JsonMap>?> playedSources = <List<JsonMap>?>[];

  @override
  void Function()? onChanged;

  @override
  void Function(JsonMap value)? onTrackSelected;

  @override
  JsonMap get current => _current;

  @override
  String get coverImage => _cover;

  @override
  List<JsonMap> get queueItems => _items;

  @override
  List<String> get queueIds => _ids;

  @override
  int get queueIndex => _index;

  @override
  int get queueSize => _ids.length;

  @override
  List<JsonMap> get history => _history;

  @override
  int queueIndexOfId(String id) => _ids.indexOf(id);

  @override
  void play(JsonMap track, {List<JsonMap>? source}) {
    played.add(track);
    playedSources.add(source);
    _current = track;
  }

  @override
  void loadQueue(List<String> ids, List<JsonMap> items) {
    _ids = List<String>.of(ids);
    _items = List<JsonMap>.of(items);
  }

  @override
  void remove(int index) {
    if (index >= 0 && index < _ids.length) {
      _ids.removeAt(index);
    }
  }

  @override
  void stop() {
    _current = <String, Object?>{};
  }

  @override
  void clearHistory() {
    _history = <JsonMap>[];
  }

  @override
  void clearCaches() {
    _cover = '';
  }
}

class _Collections implements SirenCollectionsPort {
  _Collections({this.creatorId = 'creator-1'});

  @override
  final String creatorId;

  final List<String> liked = <String>[];
  final Map<String, JsonMap> byId = <String, JsonMap>{};
  final Map<String, List<String>> tracksById = <String, List<String>>{};
  int _next = 1;

  @override
  List<String> likedIds() => List<String>.of(liked);

  @override
  bool isLiked(String id) => liked.contains(id);

  @override
  bool setLiked(String id, bool liked) {
    if (liked) {
      if (!this.liked.contains(id)) {
        this.liked.add(id);
      }
    } else {
      this.liked.remove(id);
    }
    return true;
  }

  @override
  List<JsonMap> playlists() => byId.values.toList();

  @override
  JsonMap playlist(String id) => byId[id] ?? <String, Object?>{};

  @override
  List<String> tracks(String id) => tracksById[id] ?? <String>[];

  @override
  String createPlaylist(String name) {
    final id = 'p' + _next.toString();
    _next++;
    byId[id] = <String, Object?>{
      'kind': 'playlist',
      'id': id,
      'title': name,
      'creatorID': creatorId,
    };
    tracksById[id] = <String>[];
    return id;
  }

  @override
  bool renamePlaylist(String id, String name) {
    final value = byId[id];
    if (value == null) {
      return false;
    }
    value['title'] = name;
    return true;
  }

  @override
  bool deletePlaylist(String id) {
    tracksById.remove(id);
    return byId.remove(id) != null;
  }

  @override
  bool addTrack(String id, String trackId) {
    final ids = tracksById[id];
    if (ids == null) {
      return false;
    }
    if (!ids.contains(trackId)) {
      ids.add(trackId);
    }
    return true;
  }

  @override
  bool removeTrack(String id, String trackId) {
    final ids = tracksById[id];
    if (ids == null) {
      return false;
    }
    return ids.remove(trackId);
  }
}

class _Local implements LocalMusicPort {
  @override
  bool get busy => false;

  @override
  String get status => '';

  @override
  List<JsonMap> songs() => <JsonMap>[];

  @override
  List<JsonMap> collections(String kind) => <JsonMap>[];

  @override
  List<JsonMap> tracks(JsonMap collection) => <JsonMap>[];

  @override
  List<JsonMap> search(String query, String kind) => <JsonMap>[];

  @override
  bool contains(String path) => false;

  @override
  void importPaths(List<String> paths) {}

  @override
  void cancel() {}
}

class _Scheduler implements SchedulerPort {
  final List<void Function()> pending = <void Function()>[];
  final List<Duration> delays = <Duration>[];

  @override
  Cancelable schedule(Duration delay, void Function() action) {
    delays.add(delay);
    pending.add(action);
    return _Cancel(() => pending.remove(action));
  }
}

// ---------------------------------------------------------------------------
// 构造辅助
// ---------------------------------------------------------------------------

const List<String> _onlineColumns = <String>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑'];

JsonMap _contentWith(List<String> categories) => <String, Object?>{
      'records': <JsonMap>[
        for (final category in categories) <String, Object?>{'category': category},
      ],
    };

MusicLibrary _build({
  Map<String, String>? prefs,
  JsonMap? content,
  _Wire? wire,
  _Host? host,
  _Playback? playback,
  _Collections? collections,
  _Local? local,
  _Scheduler? scheduler,
}) {
  return MusicLibrary(
    host: host ?? _Host(),
    preferences: _Prefs(prefs),
    requests: wire ?? _Wire(),
    content: content ?? _contentWith(_onlineColumns),
    collections: collections,
    player: playback ?? _Playback(),
    scheduler: scheduler ?? _Scheduler(),
    local: local,
  );
}

JsonMap _song(String id, {String title = '歌', String album = '', String artist = ''}) {
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'key': 'netease:song:' + id,
  };
}

JsonMap _lane({
  List<JsonMap>? items,
  int total = 0,
  int offset = 0,
  bool more = false,
  int row = 0,
}) {
  return <String, Object?>{
    'items': items ?? <JsonMap>[],
    'total': total,
    'offset': offset,
    'more': more,
    'row': row,
  };
}

JsonMap _session({
  String provider = 'netease',
  String edition = 'standard',
  String uid = '',
  List<JsonMap>? sources,
  List<JsonMap>? directories,
  String searchKind = '',
}) {
  return <String, Object?>{
    'provider': provider,
    'edition': edition,
    'uid': uid,
    'sources': sources ?? <JsonMap>[for (var lane = 0; lane < 5; lane++) _lane()],
    'directories': directories ?? <JsonMap>[],
    'selectedLane': 0,
    'selectedPhysical': -1,
    'searchKind': searchKind,
  };
}

void main() {
  group('Qt MusicLibrary：五 lane 与 40 格物理锚点', () {
    // Qt/src/MusicLibrary.h:136-210：columns/lists/totals/offsets/hasMore/rowMemory/
    // physicalSlots/sourceErrors 全部是长度 5 的平行数组；物理格共 40（0..39）。
    test('在线渠道固定五栏，顺序与 Qt 一致', () {
      final lib = _build();
      expect(lib.columns, <String>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑']);
      expect(lib.lists.length, 5);
      expect(lib.totals.length, 5);
      expect(lib.offsets.length, 5);
      expect(lib.hasMore.length, 5);
      expect(lib.rowMemory.length, 5);
      expect(lib.physicalSlots.length, 5);
      expect(lib.sourceErrors.length, 5);
      expect(lib.sirenOffsets.length, 5);
    });

    test('physicalSlots 只收 category 命中该栏的记录，且全量保留', () {
      final records = <JsonMap>[
        for (var index = 0; index < 45; index++)
          <String, Object?>{'category': '搜索结果'},
      ];
      final lib = _build(content: <String, Object?>{'records': records});
      expect(lib.physicalSlots[0].length, 45);
      expect(lib.physicalSlots[0].first, 0);
      expect(lib.physicalSlots[0].last, 44);
      expect(lib.physicalSlots[1], isEmpty);
    });

    test('未知 category 不占格', () {
      final lib = _build(content: <String, Object?>{
        'records': <JsonMap>[
          <String, Object?>{'category': '不存在的栏目'},
          <String, Object?>{'category': '收藏专辑'},
        ],
      });
      expect(lib.physicalSlots[0], isEmpty);
      expect(lib.physicalSlots[4], <int>[1]);
    });

    test('塞壬栏目换列名但仍是五栏', () {
      final lib = _build(prefs: <String, String>{'provider': 'siren'}, collections: _Collections());
      expect(lib.columns, <String>['搜索结果', '喜欢的歌曲', '我的歌单', '全部歌曲', '全部专辑']);
      expect(lib.columns.length, 5);
    });

    test('本地栏目换列名；本地未启用时 provider 回退 netease', () {
      expect(_build(prefs: <String, String>{'provider': 'local'}).provider, 'netease');
      final local = _build(
        prefs: <String, String>{'provider': 'local'},
        local: _Local(),
        host: _Host(localEnabled: true),
      );
      expect(local.provider, 'local');
      expect(local.columns, <String>['本地检索', '全部歌曲', '文件夹', '本地专辑', '本地歌手']);
    });

    test('未知 provider 一律回退 netease', () {
      expect(_build(prefs: <String, String>{'provider': 'spotify'}).provider, 'netease');
    });

    test('sourceOrder：酷狗把收藏专辑换成收藏歌单位（Qt sourceOrder）', () {
      expect(_build().sourceOrder(), <int>[1, 2, 3, 4, 0]);
      expect(_build(prefs: <String, String>{'provider': 'kugou'}).sourceOrder(), <int>[1, 2, 3, 0]);
    });
  });

  group('Qt MusicLibrary：editable / sourceLoading', () {
    // Qt/src/MusicLibrary.cpp editable()：netease || qq || siren。
    test('只有网易云、QQ、塞壬可写', () {
      expect(_build().editable, isTrue);
      expect(_build(prefs: <String, String>{'provider': 'qq'}).editable, isTrue);
      expect(_build(prefs: <String, String>{'provider': 'siren'}, collections: _Collections()).editable, isTrue);
      expect(_build(prefs: <String, String>{'provider': 'kugou'}).editable, isFalse);
      expect(
        _build(prefs: <String, String>{'provider': 'local'}, local: _Local(), host: _Host(localEnabled: true)).editable,
        isFalse,
      );
    });

    test('sourceLoading = restoringAccount || searchLoading || personalLoading || sirenCatalogLoading', () {
      final lib = _build();
      expect(lib.sourceLoading, isFalse);
      lib.restoringAccount = true;
      expect(lib.sourceLoading, isTrue);
      lib.restoringAccount = false;
      lib.searchLoading = true;
      expect(lib.sourceLoading, isTrue);
      lib.searchLoading = false;
      lib.personalLoading = true;
      expect(lib.sourceLoading, isTrue);
      lib.personalLoading = false;
      lib.sirenCatalogLoading = true;
      expect(lib.sourceLoading, isTrue);
    });
  });

  group('Qt MusicApi：路由与参数形状（MusicApi.cpp:60-125）', () {
    test('call 的 arguments 是 JSON 数组，路由 /native/<provider>/<operation>', () async {
      final wire = _Wire();
      final client = MusicApiClient(wire, host: _Host());
      final reply = await client.call('song/detail', <Object?>['1', 2, true]);
      expect(reply.ok, isTrue);
      expect(wire.calls.single.route, '/native/netease/song/detail');
      expect(wire.calls.single.params['args'], <Object?>['1', 2, true]);
    });

    test('request 只有非 netease 才前置 /<provider>', () async {
      final neteaseWire = _Wire();
      await MusicApiClient(neteaseWire, host: _Host()).request('/like', <String, Object?>{'id': '1'});
      expect(neteaseWire.calls.single.route, '/like');

      final qqWire = _Wire();
      await MusicApiClient(qqWire, host: _Host(), provider: 'qq').request('/like', <String, Object?>{'id': '1'});
      expect(qqWire.calls.single.route, '/qq/like');
    });

    test('local 渠道不发请求，直接回本地模式文案', () async {
      final wire = _Wire();
      final client = MusicApiClient(wire, host: _Host(), provider: 'local');
      final reply = await client.call('song/detail', <Object?>[]);
      expect(reply.ok, isFalse);
      expect(reply.error, '本地模式不提供在线平台操作');
      expect(wire.calls, isEmpty);
    });

    test('providerName 文案与 Qt 一致', () {
      expect(musicProviderName('netease'), '网易云音乐');
      expect(musicProviderName('qq'), 'QQ 音乐');
      expect(musicProviderName('kugou'), '酷狗音乐');
      expect(musicProviderName('siren'), '塞壬唱片');
      expect(musicProviderName('local'), '本地音乐');
    });
  });

  group('Qt MusicApi：body code 语义（QJsonValue::toInt(200)）', () {
    test('缺省 code 视为 200', () async {
      final wire = _Wire()..queue.add(const HostReply(<String, Object?>{'value': 'ok'}));
      final reply = await MusicApiClient(wire, host: _Host()).call('x', <Object?>[]);
      expect(reply.ok, isTrue);
      expect(reply.value, 'ok');
    });

    test('字符串 code 不是数字，同样取默认 200（不是 0）', () async {
      final wire = _Wire()
        ..queue.add(const HostReply(<String, Object?>{'code': '0', 'value': 1}));
      final reply = await MusicApiClient(wire, host: _Host()).call('x', <Object?>[]);
      expect(reply.ok, isTrue);
      expect(reply.value, 1);
    });

    test('显式 code=0 判失败，且带 providerName 前缀（request 路径）', () async {
      final wire = _Wire()
        ..queue.add(const HostReply(<String, Object?>{'code': 0, 'message': '参数错误'}));
      final reply = await MusicApiClient(wire, host: _Host()).request('/like', <String, Object?>{});
      expect(reply.ok, isFalse);
      expect(reply.error, '网易云音乐返回 0：参数错误');
    });

    test('call（adapted）只回上游 message，不加前缀', () async {
      final wire = _Wire()
        ..queue.add(const HostReply(<String, Object?>{'code': 0, 'message': '参数错误'}));
      final reply = await MusicApiClient(wire, host: _Host()).call('x', <Object?>[]);
      expect(reply.ok, isFalse);
      expect(reply.error, '参数错误');
    });

    test('message 缺失回退 msg，再回退 请稍后重试', () async {
      final wire = _Wire()
        ..queue.add(const HostReply(<String, Object?>{'code': 403, 'msg': '无权限'}))
        ..queue.add(const HostReply(<String, Object?>{'code': 403}));
      final client = MusicApiClient(wire, host: _Host());
      expect((await client.request('/like', <String, Object?>{})).error, '网易云音乐返回 403：无权限');
      expect((await client.request('/like', <String, Object?>{})).error, '网易云音乐返回 403：请稍后重试');
    });

    test('allowed 集合内的 code 视为成功', () async {
      final wire = _Wire()..queue.add(const HostReply(<String, Object?>{'code': 201}));
      final reply = await MusicApiClient(wire, host: _Host())
          .request('/like', <String, Object?>{}, allowed: <int>{200, 201});
      expect(reply.ok, isTrue);
      expect(reply.value, isA<JsonMap>());
    });

    test('body 非对象回元数据格式无效', () async {
      final wire = _Wire()..queue.add(const HostReply(null));
      final reply = await MusicApiClient(wire, host: _Host()).request('/like', <String, Object?>{});
      expect(reply.ok, isFalse);
      expect(reply.error, '元数据格式无效');
    });

    test('宿主错误原样透传', () async {
      final wire = _Wire()..queue.add(const HostReply.failure('网络不可用'));
      final reply = await MusicApiClient(wire, host: _Host()).request('/like', <String, Object?>{});
      expect(reply.ok, isFalse);
      expect(reply.error, '网络不可用');
    });
  });

  group('Qt MusicApi::safeFailure 白名单（MusicApi.cpp:26-58）', () {
    test('字符串键只留白名单且必须匹配 ^[a-z.-]{1,80}$', () {
      final failure = MusicApiClient.safeFailure(<String, Object?>{
        'failureStage': 'request',
        'failureReason': 'Bad Thing',
        'errorKey': 'network.timeout',
        'upstreamErrorKey': 'A' * 81,
        'raw': 'secret',
      });
      expect(failure, isNotEmpty);
      expect(failure['failureStage'], 'request');
      expect(failure.containsKey('failureReason'), isFalse);
      expect(failure['errorKey'], 'network.timeout');
      expect(failure.containsKey('upstreamErrorKey'), isFalse);
      expect(failure.containsKey('raw'), isFalse);
    });

    test('数值键保留 num，非数值丢弃', () {
      final failure = MusicApiClient.safeFailure(<String, Object?>{
        'code': 0,
        'retryAfterMs': 1500,
        'upstreamHttpStatus': '500',
      });
      expect(failure['code'], 0);
      expect(failure['retryAfterMs'], 1500);
      expect(failure.containsKey('upstreamHttpStatus'), isFalse);
    });

    test('retryable/writeAttempted 只接受 bool', () {
      final failure = MusicApiClient.safeFailure(<String, Object?>{
        'retryable': true,
        'writeAttempted': 'yes',
      });
      expect(failure['retryable'], isTrue);
      expect(failure.containsKey('writeAttempted'), isFalse);
    });

    test('authExpired 走 toBool 真值，非 bool 不写', () {
      expect(MusicApiClient.safeFailure(<String, Object?>{'authExpired': true})['authExpired'], isTrue);
      expect(MusicApiClient.safeFailure(<String, Object?>{'authExpired': 1}), isEmpty);
      expect(MusicApiClient.safeFailure(<String, Object?>{'authExpired': 'true'}), isEmpty);
    });

    test('verification 只在 unconfirmed 时透出', () {
      expect(MusicApiClient.safeFailure(<String, Object?>{'verification': 'unconfirmed'})['verification'], 'unconfirmed');
      expect(MusicApiClient.safeFailure(<String, Object?>{'verification': 'confirmed'}), isEmpty);
    });

    test('lastFailure/primaryFailure 只递归一层', () {
      final failure = MusicApiClient.safeFailure(<String, Object?>{
        'code': 500,
        'lastFailure': <String, Object?>{
          'code': 401,
          'lastFailure': <String, Object?>{'code': 403},
        },
      });
      final previous = mapOf(failure['lastFailure']);
      expect(previous['code'], 401);
      expect(previous.containsKey('lastFailure'), isFalse);
    });

    test('空投影返回空 Map：Qt 恒返回 QJsonObject，不是 null', () {
      // Qt/src/MusicApi.cpp:26-58 result 是恒返回的 QJsonObject：未命中任何
      // 白名单字段时是空对象，调用方据此区分“有 failure”与“没有 failure”。
      final failure = MusicApiClient.safeFailure(<String, Object?>{});
      expect(failure, isEmpty);
      expect(failure, isA<Map<String, Object?>>());
      expect(MusicApiClient.safeFailure(<String, Object?>{'raw': 'secret'}), isEmpty);
    });
  });

  group('Qt MusicApi::send 成功即写 Cookie（MusicApi.cpp:119）', () {
    test('acceptCookies 收到紧凑 JSON + epoch + credentialKey', () async {
      final host = _Host();
      final wire = _Wire()
        ..queue.add(const HostReply(
          <String, Object?>{'code': 200, 'value': 1},
          cookies: <Object?>['a=b', 'c=d'],
          epoch: 7,
          credentialKey: 'netease:42',
        ));
      final reply = await MusicApiClient(wire, host: host).call('x', <Object?>[]);
      expect(reply.ok, isTrue);
      expect(host.cookiePayloads.single, '["a=b","c=d"]');
      expect(host.cookieEpochs.single, 7);
      expect(host.cookieKeys.single, 'netease:42');
    });

    test('失败分支不写 Cookie', () async {
      final host = _Host();
      final wire = _Wire()..queue.add(const HostReply(<String, Object?>{'code': 500}));
      await MusicApiClient(wire, host: host).request('/like', <String, Object?>{});
      expect(host.cookiePayloads, isEmpty);
    });
  });

  group('代数（generation）丢弃旧响应', () {
    test('valid() 变假后回复标记为 stale，且不带业务 failure', () async {
      final wire = _Wire()..queue.add(const HostReply(<String, Object?>{'code': 200, 'value': 1}));
      final client = MusicApiClient(wire, host: _Host());
      var alive = true;
      final fresh = await client.call('x', <Object?>[], valid: () => alive);
      expect(fresh.ok, isTrue);

      wire.queue.add(const HostReply(<String, Object?>{'code': 200, 'value': 2}));
      alive = false;
      final stale = await client.call('x', <Object?>[], valid: () => alive);
      expect(stale.ok, isFalse);
      expect(isStale(stale), isTrue);
      expect(stale.failure, isNull);
      expect(stale.value, isNull);
    });

    test('sessionState 恢复会推进三个世代（Qt MusicSession.cpp:110）', () {
      final lib = _build();
      final selection = lib.selectionGeneration;
      final directory = lib.directoryGeneration;
      final wiki = lib.wikiGeneration;
      expect(lib.restoreSessionState(_session()), isTrue);
      expect(lib.selectionGeneration, selection + 1);
      expect(lib.directoryGeneration, directory + 1);
      expect(lib.wikiGeneration, wiki + 1);
    });
  });

  group('最近搜索白名单（最多 12 条）', () {
    test('超过 12 条截断，空串与非字符串丢弃', () {
      final many = <Object?>[for (var index = 0; index < 15; index++) 'k' + index.toString()];
      final lib = _build(prefs: <String, String>{'search-history': jsonEncode(many)});
      expect(lib.searchHistory.length, 12);
      expect(lib.searchHistory.first, 'k0');
      expect(lib.searchHistory.last, 'k11');
    });

    test('空串/数字/null 不进入历史', () {
      final dirty = <Object?>['a', '', 3, 'b', null, 'c'];
      final lib = _build(prefs: <String, String>{'search-history': jsonEncode(dirty)});
      expect(lib.searchHistory, <String>['a', 'b', 'c']);
    });

    test('坏 JSON 直接忽略，不抛异常', () {
      final lib = _build(prefs: <String, String>{'search-history': '{'});
      expect(lib.searchHistory, isEmpty);
    });
  });

  group('Qt MusicSession：快照恢复的夹取规则', () {
    test('row 42 夹取为 7，不是拒绝恢复', () {
      final lib = _build();
      final sources = <JsonMap>[_lane(row: 42), _lane(), _lane(), _lane(), _lane()];
      expect(lib.restoreSessionState(_session(sources: sources)), isTrue);
      expect(lib.rowMemory[0], 7);
    });

    test('offset 夹取到 [0, max(0, size-1)]', () {
      final lib = _build();
      final sources = <JsonMap>[
        _lane(items: <JsonMap>[_song('1'), _song('2')], offset: 99),
        _lane(offset: -5),
        _lane(),
        _lane(),
        _lane(),
      ];
      expect(lib.restoreSessionState(_session(sources: sources)), isTrue);
      expect(lib.offsets[0], 1);
      expect(lib.offsets[1], 0);
    });

    test('totals 取 max(items.size, total)', () {
      final lib = _build();
      final sources = <JsonMap>[
        _lane(items: <JsonMap>[_song('1'), _song('2')], total: 1),
        _lane(total: 88),
        _lane(),
        _lane(),
        _lane(),
      ];
      expect(lib.restoreSessionState(_session(sources: sources)), isTrue);
      expect(lib.totals[0], 2);
      expect(lib.totals[1], 88);
    });

    test('selectedPhysical 必须命中该栏物理格，否则整份拒绝', () {
      final lib = _build();
      final saved = _session();
      saved['selectedPhysical'] = 5;
      expect(lib.restoreSessionState(saved), isFalse);
    });

    test('selectedPhysical 命中 physicalSlots 时接受', () {
      final lib = _build();
      final saved = _session();
      saved['selectedPhysical'] = 0;
      expect(lib.restoreSessionState(saved), isTrue);
      expect(lib.selectedPhysical, 0);
    });

    test('provider/edition/uid 任一不符即拒绝', () {
      expect(_build().restoreSessionState(_session(provider: 'qq')), isFalse);
      expect(_build().restoreSessionState(_session(edition: 'lite')), isFalse);
      expect(_build().restoreSessionState(_session(uid: '42')), isFalse);
    });

    test('目录栈超过 64 层拒绝', () {
      final folders = <JsonMap>[
        for (var index = 0; index < 65; index++)
          <String, Object?>{
            'item': <String, Object?>{'kind': 'folder', 'id': 'f' + index.toString()},
          },
      ];
      expect(_build().restoreSessionState(_session(directories: folders)), isFalse);
    });

    test('searchKind 缺键回落 song，显式空串保留', () {
      final missing = _session();
      missing.remove('searchKind');
      final fallback = _build();
      expect(fallback.restoreSessionState(missing), isTrue);
      expect(fallback.searchKind, 'song');
      final explicit = _build();
      expect(explicit.restoreSessionState(_session(searchKind: '')), isTrue);
      expect(explicit.searchKind, '');
    });

    test('sessionState 往返保留 keyword/searchKind/栏目', () {
      final lib = _build();
      lib.keyword = '周杰伦';
      lib.searchKind = 'album';
      final saved = lib.sessionState();
      final restored = _build();
      expect(restored.restoreSessionState(saved), isTrue);
      expect(restored.keyword, '周杰伦');
      expect(restored.searchKind, 'album');
    });

    test('塞壬恢复不写死 933 首 / 303 专辑：没读到曲库就保持空', () {
      final lib = _build(prefs: <String, String>{'provider': 'siren'}, collections: _Collections());
      final sources = <JsonMap>[for (var lane = 0; lane < 5; lane++) _lane()];
      expect(lib.restoreSessionState(_session(provider: 'siren', sources: sources)), isTrue);
      expect(lib.sirenSongs, isEmpty);
      expect(lib.sirenAlbums, isEmpty);
      expect(lib.lists[3], isEmpty);
      expect(lib.lists[4], isEmpty);
      expect(lib.sirenOffsets[3], 0);
      expect(lib.sirenOffsets[4], 0);
    });
  });

  group('Qt MusicMutation：写操作路由与 values', () {
    test('未登录只提示，不发请求', () async {
      final wire = _Wire();
      final lib = _build(wire: wire);
      await lib.like(_song('7'));
      expect(wire.calls, isEmpty);
      expect(lib.status, '请先登录网易云音乐');
    });

    test('网易云收藏：request(/like, {id, like:true})', () async {
      final wire = _Wire();
      final lib = _build(wire: wire);
      lib.uid = '42';
      lib.likedIds = <String>[];
      await lib.like(_song('7'));
      expect(wire.calls.single.route, '/like');
      expect(wire.calls.single.params, <String, Object?>{'id': '7', 'like': true});
    });

    test('已收藏再点即取消：like:false', () async {
      final wire = _Wire();
      final lib = _build(wire: wire);
      lib.uid = '42';
      lib.likedIds = <String>['7'];
      await lib.like(_song('7'));
      expect(wire.calls.single.params, <String, Object?>{'id': '7', 'like': false});
    });

    test('收藏专辑：request(/album/sub, {id, t:1})', () async {
      final wire = _Wire();
      final lib = _build(wire: wire);
      lib.uid = '42';
      await lib.subscribe(<String, Object?>{
        'kind': 'album',
        'id': '9',
        'title': '专辑',
        'key': 'netease:album:9',
      });
      expect(wire.calls.single.route, '/album/sub');
      expect(wire.calls.single.params, <String, Object?>{'id': '9', 't': 1});
    });

    test('QQ 收藏走 call(mutate, [route, values])', () async {
      final wire = _Wire();
      final lib = _build(wire: wire, prefs: <String, String>{'provider': 'qq'});
      lib.uid = '42';
      lib.capabilities = <String, Object?>{
        'mutations': <String, Object?>{'likeSong': true},
      };
      await lib.like(_song('7'));
      expect(wire.calls.single.route, '/native/qq/mutate');
      final args = wire.calls.single.params['args']! as List<Object?>;
      expect(args.first, '/like');
      expect(args.last, <String, Object?>{'id': '7'});
    });

    test('QQ capabilities 为空时 canMutate 按放行（MusicMutation::canMutate）', () {
      final lib = _build(prefs: <String, String>{'provider': 'qq'});
      expect(lib.canMutate('/like'), isTrue);
      lib.capabilities = <String, Object?>{
        'mutations': <String, Object?>{'likeSong': true},
      };
      expect(lib.canMutate('/like'), isTrue);
      expect(lib.canMutate('/playlist/delete'), isFalse);
    });

    test('塞壬只开放五个写操作', () {
      final lib = _build(prefs: <String, String>{'provider': 'siren'}, collections: _Collections());
      expect(lib.canMutate('/like'), isTrue);
      expect(lib.canMutate('/playlist/tracks'), isTrue);
      expect(lib.canMutate('/album/sub'), isFalse);
    });

    test('酷狗一律不可写', () {
      final lib = _build(prefs: <String, String>{'provider': 'kugou'});
      expect(lib.canMutate('/like'), isFalse);
      expect(lib.canMutate('/playlist/create'), isFalse);
    });

    test('playlistForm 名称上限：QQ 20 字，其它 100 字', () async {
      final qq = _build(prefs: <String, String>{'provider': 'qq'});
      qq.uid = '42';
      expect(await qq.playlistForm('create', 'a' * 21), isFalse);
      expect(qq.status, '请输入 1\u201320 字歌单名称');

      final netease = _build();
      netease.uid = '42';
      expect(await netease.playlistForm('create', ''), isFalse);
      expect(netease.status, '请输入 1\u2013100 字歌单名称');
    });

    test('写操作成功后状态为已同步至<provider>', () async {
      final wire = _Wire();
      final lib = _build(wire: wire);
      lib.uid = '42';
      lib.likedIds = <String>[];
      await lib.like(_song('7'));
      expect(lib.status, '已同步至网易云音乐');
      expect(lib.writeLoading, isFalse);
    });
  });

  group('Qt MusicLibrary：栏目文案与账户键', () {
    test('未登录第 2..5 栏提示登录后查看个人音乐', () {
      final lib = _build();
      expect(lib.sourceMessage(1), '登录后查看个人音乐');
      expect(lib.sourceMessage(3), '登录后查看个人音乐');
    });

    test('账户错误优先于登录提示', () {
      final lib = _build();
      lib.mAccountError = '登录已过期，请重新登录';
      expect(lib.sourceMessage(1), '登录已过期，请重新登录');
    });

    test('酷狗第 5 栏不支持收藏专辑', () {
      final lib = _build(prefs: <String, String>{'provider': 'kugou'});
      expect(lib.sourceMessage(4), '此渠道暂不支持收藏专辑');
    });

    test('酷狗账户键带 edition，身份名分开存', () {
      final lib = _build(prefs: <String, String>{'provider': 'kugou', 'kugou-edition': 'lite'});
      expect(lib.kugouEdition, 'lite');
      expect(lib.accountKey(), 'kugou-lite');
      expect(lib.identityNames.containsKey('kugou'), isTrue);
      expect(lib.identityName(), '');
    });

    test('accountError 是 mAccountError 的别名（冻结成员名）', () {
      final lib = _build();
      lib.accountError = '会话失效';
      expect(lib.mAccountError, '会话失效');
      lib.mAccountError = '其它';
      expect(lib.accountError, '其它');
    });
  });

  group('Qt MusicData：条目构造与纯函数', () {
    test('musicItem 默认标题为 正在读取…，key 为 provider:kind:id', () {
      final item = musicItem(kind: 'song', id: '1');
      expect(item['title'], '正在读取…');
      expect(item['key'], 'netease:song:1');
      expect(item['trackCount'], 0);
      expect(item['duration'], 0);
    });

    test('musicItemParse 拒绝非法 id 与非字符串 name', () {
      expect(musicItemParse(<String, Object?>{'id': 'abc', 'name': 'x'}, 'song'), isEmpty);
      expect(musicItemParse(<String, Object?>{'id': '1', 'name': 3}, 'song'), isEmpty);
      expect(musicItemParse(<String, Object?>{'id': '1', 'name': '晴天'}, 'song')['title'], '晴天');
    });

    test('uniqueItems 空 key 只保留第一个（Qt QSet 去重）', () {
      final first = <String, Object?>{'kind': 'song', 'id': '1', 'key': ''};
      final second = <String, Object?>{'kind': 'song', 'id': '2', 'key': ''};
      expect(uniqueItems(<JsonMap>[first], <JsonMap>[second]).length, 1);
    });

    test('cursorOf：末曲不在 ids 时等于 songs.size', () {
      expect(cursorOf(<JsonMap>[_song('1')], <String>[]), 1);
      // 末曲 id '2' 不在 ids 中（ids 只有 '3'）→ 游标等于已载入数量。
      expect(cursorOf(<JsonMap>[_song('1'), _song('2')], <Object?>['3']), 2);
    });

    test('cursorOf：ids 保持 QJsonValue 类型，数字与字符串 id 不合并', () {
      // Qt/src/MusicData.cpp:125-132 indexOf 用 QJsonValue operator==（类型不同
      // 一律不等）；:143-146 cursor 取 songs.last()["id"] 的原始值查找。
      final numbers = <JsonMap>[
        <String, Object?>{'kind': 'song', 'id': 1},
        <String, Object?>{'kind': 'song', 'id': 2},
        <String, Object?>{'kind': 'song', 'id': 789},
      ];
      // 数字 789 命中下标 1 → 2；若把未命中当作命中会得到 songs.size=3。
      expect(cursorOf(numbers, <Object?>[456, 789]), 2);
      // 末曲 id 是数字 789：字符串 '789' 排在前面不算命中，数字 789 命中下标 1 → 2；
      // 若两侧都 toString() 会命中下标 0 → 1。
      expect(
        cursorOf(
          <JsonMap>[
            <String, Object?>{'kind': 'song', 'id': 1},
            <String, Object?>{'kind': 'song', 'id': 2},
            <String, Object?>{'kind': 'song', 'id': 3},
            <String, Object?>{'kind': 'song', 'id': 789},
          ],
          <Object?>['789', 789],
        ),
        2,
      );
      // 字符串 '789' 不等于数字 789：未命中 → songs.size=2（字符串合并实现得 1）。
      expect(
        cursorOf(
          <JsonMap>[
            <String, Object?>{'kind': 'song', 'id': 1},
            <String, Object?>{'kind': 'song', 'id': 789},
          ],
          <Object?>['789'],
        ),
        2,
      );
      // 先数字后字符串：数字 789 跳过，字符串 '789' 命中下标 1 → 2；
      // 若两侧都 toString() 会命中下标 0 → 1。
      expect(
        cursorOf(
          <JsonMap>[
            <String, Object?>{'kind': 'song', 'id': 1},
            <String, Object?>{'kind': 'song', 'id': 2},
            <String, Object?>{'kind': 'song', 'id': '789'},
          ],
          <Object?>[789, '789'],
        ),
        2,
      );
      // 缺 id 键在 Qt 是 Undefined，不会与 ids 里的 null 合并（未命中 → 2）。
      expect(cursorOf(<JsonMap>[{'kind': 'song'}, {'kind': 'song'}], <Object?>[null]), 2);
    });

    test('cursorOf：values[2] 原始 QJsonArray 直连 cursor，数字 id 不被丢弃', () {
      // Qt MusicLibrary.cpp:370-371：trackIDs = values.at(2).toArray() 保留原始
      // 类型；MusicData::cursor 用它的 QJsonValue 做类型敏感查找。
      // X20-DOMAIN-STORAGE ISS-02 repro：ids=[123,456,789]、末曲 id=456 → 2。
      final values = <Object?>[
        <String, Object?>{'kind': 'song', 'id': '456'},
        <Object?>[
          <String, Object?>{'kind': 'song', 'id': 'a'},
          <String, Object?>{'kind': 'song', 'id': 123},
          <String, Object?>{'kind': 'song', 'id': 456},
        ],
        <Object?>[123, 456, 789],
      ];
      final ids = trackIdValuesOf(values[2]);
      expect(ids, <Object?>[123, 456, 789]);
      expect(cursorOf(mapsOf(values[1]), ids), 2);
      // 若用 stringsOf 归一化再查找，数字 id 全部丢失，游标退化为 songs.size=3。
      expect(stringsOf(values[2]), isEmpty);
      expect(cursorOf(mapsOf(values[1]), stringsOf(values[2])), 3);
    });

    test('sortOrder：空名排最后，忽略大小写', () {
      final values = <JsonMap>[
        _song('1', title: 'b'),
        _song('2', title: ''),
        _song('3', title: 'A'),
      ];
      final order = sortOrder(values, 'title');
      expect(order.first, 2);
      expect(order.last, 1);
    });

    test('sliceItems/sliceStrings 的 end 夹取', () {
      expect(sliceItems(<JsonMap>[_song('1'), _song('2')], 1, 5).length, 1);
      expect(sliceStrings(<String>['a', 'b'], 0, 1), <String>['a']);
    });

    test('sliceItems/sliceStrings：end=rawStart+count，负 start 不多返回', () {
      // Qt/src/MusicData.cpp:116-123：end 用未抬正的 start 计算，
      // 循环起点才是 max(0,start)。
      final values = <JsonMap>[_song('1'), _song('2'), _song('3'), _song('4'), _song('5')];
      expect(
        sliceItems(values, -2, 5).map((JsonMap item) => item['id']).toList(),
        <Object?>['1', '2', '3'],
      );
      expect(
        sliceItems(values, -3, 5).map((JsonMap item) => item['id']).toList(),
        <Object?>['1', '2'],
      );
      expect(sliceItems(values, -5, 3), isEmpty);
      expect(sliceItems(values, -1, 10).length, 5);
      expect(sliceStrings(<String>['a', 'b', 'c', 'd', 'e'], -2, 5), <String>['a', 'b', 'c']);
      expect(sliceStrings(<String>['a', 'b', 'c', 'd', 'e'], -5, 3), isEmpty);
      expect(sliceStrings(<String>['a', 'b', 'c'], 1, 0), isEmpty);
      expect(sliceStrings(<String>['a', 'b', 'c'], 5, 2), isEmpty);
    });
  });

  group('Qt MusicData::ordered 原始 id（DEDUP-14）', () {
    test('数字 id 与同值字符串 id 命中同一条曲目', () {
      // Qt/src/MusicData.cpp:10-18 identifier()：字符串原样、数值转整数字符串；
      // :98-114 ordered 以 song["id"].toString() 建立 id→song 查表。
      final songs = <JsonMap>[_song('7'), _song('8')];
      final fromNumber = orderedItems(<Object?>[7], songs);
      final fromString = orderedItems(<Object?>['7'], songs);
      expect(fromNumber.length, 1);
      expect(fromString.length, 1);
      expect(identical(fromNumber.single, fromString.single), isTrue);
      expect(itemIdOf(fromNumber.single), '7');
      // double 有限值按 identifierOf 的 toInt 规则归一，不得丢类型。
      expect(itemIdOf(orderedItems(<Object?>[8.0], songs).single), '8');
      // null/bool 归一为空串；曲目侧没有空 id 条目时不得误命中。
      expect(orderedItems(<Object?>[null, true], songs), isEmpty);
    });

    test('顺序由 ids 决定：缺失跳过、重复 id 重复输出、曲目侧先到先得', () {
      // Qt/src/MusicData.cpp:98-114：逐 id append，缺键不补位。
      final songs = <JsonMap>[_song('1'), _song('2'), _song('3')];
      expect(
        orderedItems(<Object?>['3', '1'], songs).map(itemIdOf).toList(),
        <String>['3', '1'],
      );
      expect(
        orderedItems(<Object?>['2', 'x', '2'], songs).map(itemIdOf).toList(),
        <String>['2', '2'],
      );
      expect(orderedItems(<Object?>[], songs), isEmpty);
      expect(orderedItems(<Object?>['x'], songs), isEmpty);
      // 同 id 两条曲目：Qt entries.contains 先到先得，输出第一条。
      final duplicated = <JsonMap>[_song('1', title: '先'), _song('1', title: '后')];
      expect(orderedItems(<Object?>['1'], duplicated).single['title'], '先');
    });

    test('sliceValues：end=min(size,start+count)，游标越界取空、count 截断', () {
      // Qt/src/MusicData.cpp:116-123：切片对原始 QJsonArray 生效，
      // end 用未抬正的 start 计算，循环起点才是 max(0,start)。
      final ids = <Object?>['a', 7, <String, Object?>{'k': 1}, null];
      expect(sliceValues(ids, 0, 2), <Object?>['a', 7]);
      expect(sliceValues(ids, 3, 100), <Object?>[null]);
      expect(sliceValues(ids, 4, 100), isEmpty);
      expect(sliceValues(ids, 9, 1), isEmpty);
      expect(sliceValues(ids, -2, 5), <Object?>['a', 7, <String, Object?>{'k': 1}]);
      expect(sliceValues(ids, -5, 2), isEmpty);
      expect(sliceValues(<Object?>[], 0, 10), isEmpty);
    });
  });

  group('Qt MusicLocal：本地检索入口', () {
    test('本地渠道 sourceMessage 无曲目时提示导入', () {
      final lib = _build(
        prefs: <String, String>{'provider': 'local'},
        local: _Local(),
        host: _Host(localEnabled: true),
      );
      expect(lib.sourceMessage(0), '暂无本地音乐，请在文件夹管理中导入');
    });
  });
}
