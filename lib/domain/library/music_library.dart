/// 原生资料库领域层：Qt MusicLibrary / MusicDirectory / MusicSiren / MusicMutation /
/// MusicSession / MusicAccount / MusicLocal / MusicData / MusicApi 的 Flutter 逐语义迁移。
///
/// 迁移原则
/// - 条目沿用 Qt QJsonObject 语义，用 JsonMap（键名与源码一致）承载；不引入第二套模型。
/// - 远端调用只使用源码已存在的操作名/路由（Qt MusicApi::call => /native/<provider>/<op>，
///   Qt MusicApi::request 在 provider != netease 时前置 "/<provider>"），本层不发明传输字段。
/// - 代数（generation）语义与 Qt 一致：旧响应必须因代数过期而丢弃。
///
/// 本库以 part 拆分为四片，保持 Qt 源文件边界并共享私有状态：
/// music_library.dart（本文件）、directory_stack.dart、search_controller.dart、siren_catalog.dart。
///
library;

import 'dart:async';
import 'dart:convert';

part 'directory_stack.dart';
part 'search_controller.dart';
part 'siren_catalog.dart';

/// Qt QJsonObject 的迁移表示：键名保持源码原样，值为 JSON 允许的类型。
typedef JsonMap = Map<String, Object?>;

/// Qt MusicApi::send 在 valid() 为假时**不回调**（Qt/src/MusicApi.cpp:98-100）。
/// Dart 的 Future 必须完成，因此用该哨兵 error 表示"被代数丢弃"；调用方必须
/// 先判断 isStale(reply) 再处理失败，等价于 Qt 的静默丢弃。
const String _staleReply = '\u0000stale';

bool isStale(MusicReply reply) => reply.error == _staleReply;

// 宿主端口（Qt Host 接口中本层实际使用的部分）

/// 宿主 JSON 请求端口。Qt 侧为 Host::requestJson(route, params, callback)。
abstract class HostRequestPort {
  Future<HostReply> requestJson(String route, JsonMap params);
}

/// 宿主应答：body 为已解包响应体，error 非空表示失败。
///
/// cookies / epoch / credentialKey 对应 Qt MusicApi::send 成功分支读取的
/// response["cookies"] / response["_epoch"] / response["_credentialKey"]
/// （Qt/src/MusicApi.cpp:119-122）。
class HostReply {
  const HostReply(
    this.body, {
    this.error,
    this.failure,
    this.cookies = const <Object?>[],
    this.epoch = 0,
    this.credentialKey = '',
  });

  const HostReply.failure(this.error, [this.failure])
      : body = null,
        cookies = const <Object?>[],
        epoch = 0,
        credentialKey = '';

  final JsonMap? body;
  final String? error;
  final JsonMap? failure;
  final List<Object?> cookies;
  final int epoch;
  final String credentialKey;

  bool get ok => error == null;
}

/// 偏好存储端口（Qt Host::preference / setPreference）。
abstract class LibraryPreferencesPort {
  String? read(String key);

  void write(String key, String value);
}

/// 宿主硬依赖端口（Qt Host）：本层用到的全部宿主能力。
abstract class LibraryHostPort {
  bool get authenticated;

  bool get offline;

  bool get localEnabled;

  Future<void> clearCache();

  Future<void> invalidateMetadata();

  Future<void> openExternal(String url);

  /// Qt Host::fromLink：把「歌曲/专辑/歌单/歌手:ID」或分享链接解析为内部链接。
  String fromLink(String text);

  Future<String?> loadCover(String url);

  Future<void> acceptCookies(String cookies, int epoch, String credentialKey);

  /// Qt Host::qr（网易云二维码内容直接由宿主生成）。
  String qr(String key);

  /// Qt Host::qrImage（把 data:image/...;base64 转为可直接显示的键）。
  String qrImage(String data);

  bool hasCredential(String provider);

  /// Qt Host::saveCredential：成功返回空串。
  Future<String> saveCredential();

  Future<void> logout();

  Future<void> setProvider(String provider);

  Future<void> setKugouEdition(String edition);

  /// Qt Host::playOfficial(id, callback(message))：官方播放通道，失败以文案回报。
  Future<void> playOfficial(String id, void Function(String message) done);

  /// Qt Host::schedule：延时回调；返回值可取消（Qt 侧忽略返回值）。
  Cancelable schedule(Duration delay, void Function() action);
}

/// 本地音乐索引端口（Qt LocalMusicLibrary）。
abstract class LocalMusicPort {
  bool get busy;

  String get status;

  List<JsonMap> songs();

  List<JsonMap> collections(String kind);

  List<JsonMap> tracks(JsonMap collection);

  List<JsonMap> search(String query, String kind);

  /// Qt LocalMusicLibrary::contains(path)。
  bool contains(String path);

  void importPaths(List<String> paths);

  void cancel();
}

/// 塞壬本地集合端口（Qt LocalCollections：收藏与自建歌单，仅存本机）。
abstract class SirenCollectionsPort {
  String get creatorId;

  List<String> likedIds();

  bool isLiked(String id);

  bool setLiked(String id, bool liked);

  List<JsonMap> playlists();

  JsonMap playlist(String id);

  List<String> tracks(String id);

  String createPlaylist(String name);

  bool renamePlaylist(String id, String name);

  bool deletePlaylist(String id);

  bool addTrack(String id, String trackId);

  bool removeTrack(String id, String trackId);
}

/// 播放器端口（Qt MusicPlayer 中被资料库调用的部分）。
abstract class PlaybackPort {
  JsonMap get current;

  String get coverImage;

  /// Qt PlaybackQueue::items()。
  List<JsonMap> get queueItems;

  /// Qt PlaybackQueue：完整 ID 顺序。
  List<String> get queueIds;

  /// Qt PlaybackQueue::index()/indexOfId：当前队列位置。
  int get queueIndex;

  int queueIndexOfId(String id);

  /// Qt PlaybackQueue::size()。端口只声明 getter：实现侧可用字段或 getter。
  int get queueSize;

  List<JsonMap> get history;

  void play(JsonMap track, {List<JsonMap>? source});

  void loadQueue(List<String> ids, List<JsonMap> items);

  void remove(int index);

  void stop();

  void clearHistory();

  void clearCaches();

  /// Qt MusicPlayer::changed 的订阅点（宿主注入）。
  void Function()? onChanged;

  /// Qt MusicPlayer::trackSelected 的订阅点（宿主注入）。
  void Function(JsonMap value)? onTrackSelected;
}

/// 延迟调度端口：承载 Qt 的 200/300ms 合并、1s 轮询与登录冷却。
abstract class SchedulerPort {
  Cancelable schedule(Duration delay, void Function() action);
}

abstract class Cancelable {
  void cancel();
}

/// 草稿空实现：把调度交给 Timer，语义与 Qt Host::schedule 一致。
class TimerScheduler implements SchedulerPort {
  @override
  Cancelable schedule(Duration delay, void Function() action) {
    return _TimerCancelable(Timer(delay, action));
  }
}

class _TimerCancelable implements Cancelable {
  _TimerCancelable(this._timer);

  final Timer _timer;

  @override
  void cancel() {
    _timer.cancel();
  }
}

/// 草稿空实现：未注入播放器时资料库仍可独立工作（Qt 侧 player 始终存在）。
class NullPlayback implements PlaybackPort {
  JsonMap _current = <String, Object?>{};
  String _coverImage = '';
  List<JsonMap> _queueItems = <JsonMap>[];
  List<String> _queueIds = <String>[];
  int _queueIndex = -1;
  List<JsonMap> _history = <JsonMap>[];

  @override
  JsonMap get current => _current;

  @override
  String get coverImage => _coverImage;

  @override
  List<JsonMap> get queueItems => _queueItems;

  @override
  List<String> get queueIds => _queueIds;

  @override
  int get queueIndex => _queueIndex;

  @override
  int get queueSize => _queueIds.length;

  @override
  List<JsonMap> get history => _history;

  @override
  int queueIndexOfId(String id) => _queueIds.indexOf(id);

  @override
  void play(JsonMap track, {List<JsonMap>? source}) {
    _current = track;
    _coverImage = textOf(track['cover']);
    if (source != null) {
      _queueItems = List<JsonMap>.of(source);
      _queueIds = <String>[for (final item in source) itemIdOf(item)];
      _queueIndex = 0;
    }
    _history = <JsonMap>[track, ..._history];
  }

  @override
  void loadQueue(List<String> ids, List<JsonMap> items) {
    _queueIds = List<String>.of(ids);
    _queueItems = List<JsonMap>.of(items);
  }

  @override
  void remove(int index) {
    if (index < 0 || index >= _queueItems.length) {
      return;
    }
    _queueItems.removeAt(index);
    if (index < _queueIds.length) {
      _queueIds.removeAt(index);
    }
    if (_queueIndex >= index && _queueIndex > 0) {
      _queueIndex--;
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
    _coverImage = '';
  }

  @override
  void Function()? onChanged;

  @override
  void Function(JsonMap value)? onTrackSelected;
}

// 远端应答与 API 适配（Qt MusicApi.{h,cpp}）

/// Qt MusicReply：value 是 QJsonValue（任意类型，可能是数组或对象）。
class MusicReply {
  const MusicReply(this.value, this.error, this.failure);

  const MusicReply.ok(this.value)
      : error = null,
        failure = null;

  const MusicReply.fail(this.error, [this.failure]) : value = null;

  final Object? value;
  final String? error;
  final JsonMap? failure;

  bool get ok => error == null;
}

/// Qt MusicApi::providerName（Qt/src/MusicApi.cpp:10-24）。
String musicProviderName(String provider) {
  switch (provider) {
    case 'local':
      return '本地音乐';
    case 'qq':
      return 'QQ 音乐';
    case 'kugou':
      return '酷狗音乐';
    case 'siren':
      return '塞壬唱片';
    default:
      return '网易云音乐';
  }
}

/// Qt QJsonValue::toInt(defaultValue)：只有数值类型转换，字符串一律取默认值。
int _jsonToInt(Object? value, int fallback) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite || value < -2147483648 || value > 2147483647) {
      return fallback;
    }
    return value.toInt();
  }
  return fallback;
}

/// Qt MusicApi：统一包装操作名、渠道路由、返回码白名单与失败摘要。
class MusicApiClient {
  MusicApiClient(this.requests, {this.host, this.provider = 'netease'});

  final HostRequestPort requests;

  /// MusicApi 在 Qt 里持有 Host*，用于成功分支接收 Cookie（MusicApi.cpp:119）。
  final LibraryHostPort? host;

  String provider;

  String get providerName => musicProviderName(provider);

  /// Qt MusicApi::call：参数是 QJsonArray，路由 /native/<provider>/<operation>。
  Future<MusicReply> call(
    String operation,
    List<Object?> arguments, {
    bool Function()? valid,
    Set<int> allowed = const <int>{200},
  }) {
    if (provider == 'local') {
      if (valid == null || valid()) {
        return Future<MusicReply>.value(
          const MusicReply.fail('本地模式不提供在线平台操作'),
        );
      }
      return Future<MusicReply>.value(const MusicReply.fail(_staleReply));
    }
    return _send(
      '/native/' + provider + '/' + operation,
      <String, Object?>{'args': arguments},
      adapted: true,
      valid: valid,
    );
  }

  /// Qt MusicApi::request：非 netease 渠道前置 /<provider>。
  Future<MusicReply> request(
    String route,
    JsonMap params, {
    bool Function()? valid,
    Set<int> allowed = const <int>{200},
  }) {
    if (provider == 'local') {
      if (valid == null || valid()) {
        return Future<MusicReply>.value(
          const MusicReply.fail('本地模式不提供在线平台操作'),
        );
      }
      return Future<MusicReply>.value(const MusicReply.fail(_staleReply));
    }
    final target = provider == 'netease' ? route : '/' + provider + route;
    return _send(
      target,
      params,
      adapted: false,
      valid: valid,
      allowed: allowed,
    );
  }

  Future<MusicReply> _send(
    String route,
    JsonMap params, {
    required bool adapted,
    required bool Function()? valid,
    Set<int> allowed = const <int>{200},
  }) async {
    final source = provider;
    final HostReply reply = await requests.requestJson(route, params);
    if (valid != null && !valid()) {
      return const MusicReply.fail(_staleReply);
    }
    if (!reply.ok) {
      return MusicReply.fail(reply.error ?? '');
    }
    final body = reply.body;
    if (body == null) {
      return const MusicReply.fail('元数据格式无效');
    }
    // Qt: const auto code = body["code"].toInt(200);
    final code = _jsonToInt(body['code'], 200);
    if (!allowed.contains(code)) {
      // Qt: body["message"].toString(body["msg"].toString("请稍后重试"))
      final rawMessage = body['message'];
      final rawMsg = body['msg'];
      final message = rawMessage is String
          ? rawMessage
          : (rawMsg is String ? rawMsg : '请稍后重试');
      return MusicReply.fail(
        adapted
            ? message
            : musicProviderName(source) + '返回 ' + code.toString() + '：' + message,
        safeFailure(body),
      );
    }
    final owner = host;
    if (owner != null) {
      await owner.acceptCookies(
        jsonEncode(reply.cookies),
        reply.epoch,
        reply.credentialKey,
      );
    }
    return MusicReply.ok(adapted ? body['value'] : body);
  }

  /// Qt MusicApi::safeFailure：只透出诊断白名单字段，避免泄漏整包上游响应。
  /// includePrevious 只允许递归一层（Qt/src/MusicApi.cpp:26-58）。
  /// Qt 恒返回 QJsonObject：空投影是空对象而非 null，调用方据此区分
  /// “有 failure 但字段全被过滤”与“没有 failure”。
  static JsonMap safeFailure(JsonMap body, [bool includePrevious = true]) {
    final out = <String, Object?>{};
    const stringKeys = <String>[
      'failureStage',
      'failureReason',
      'errorKey',
      'upstreamErrorKey',
    ];
    for (final key in stringKeys) {
      final value = body[key];
      if (value is String && RegExp(r'^[a-z.-]{1,80}$').hasMatch(value)) {
        out[key] = value;
      }
    }
    const numberKeys = <String>[
      'code',
      'retryAfterMs',
      'upstreamHttpStatus',
      'upstreamCode',
      'upstreamGlobalCode',
      'upstreamSubCode',
    ];
    for (final key in numberKeys) {
      final value = body[key];
      if (value is num && value.isFinite) {
        out[key] = value;
      }
    }
    if (includePrevious) {
      for (final key in const <String>['lastFailure', 'primaryFailure']) {
        final nested = body[key];
        if (nested is Map) {
          out[key] = safeFailure(Map<String, Object?>.from(nested), false);
        }
      }
    }
    for (final key in const <String>['retryable', 'writeAttempted']) {
      final value = body[key];
      if (value is bool) {
        out[key] = value;
      }
    }
    if (body['verification'] == 'unconfirmed') {
      out['verification'] = 'unconfirmed';
    }
    // Qt: if (body["authExpired"].toBool()) result["authExpired"] = true;
    if (boolOf(body['authExpired'])) {
      out['authExpired'] = true;
    }
    return out;
  }

}

// JSON 与条目辅助（Qt MusicData.cpp）

/// Qt wrap：((value % count) + count) % count（Qt/src/MusicLibrary.cpp:10-12）。
int wrapIndex(int value, int count) {
  if (count <= 0) {
    return 0;
  }
  return ((value % count) + count) % count;
}

/// Qt QJsonValue::toString()：非字符串一律空串。
String textOf(Object? value) => value is String ? value : '';

/// Qt QJsonValue::toInt()：只有数值类型转换，字符串一律 0。
int intOf(Object? value) => _jsonToInt(value, 0);

/// Qt QJsonValue::toBool()：只有 true 为真。
bool boolOf(Object? value) => value == true;

/// Qt QJsonValue::toObject()：非对象一律空对象。
JsonMap mapOf(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  return <String, Object?>{};
}

/// Qt QJsonValue::toArray() 的对象投影：非对象元素按 Qt 语义得到空对象，
/// 这里跳过它们以免向列表注入无 key 的空条目（Qt 各调用点不包含该情形）。
List<JsonMap> mapsOf(Object? value) {
  if (value is! List) {
    return <JsonMap>[];
  }
  final out = <JsonMap>[];
  for (final entry in value) {
    if (entry is Map) {
      out.add(Map<String, Object?>.from(entry));
    }
  }
  return out;
}

/// Qt QJsonArray -> QStringList 的常见用法：只保留非空字符串。
List<String> stringsOf(Object? value) {
  if (value is! List) {
    return <String>[];
  }
  final out = <String>[];
  for (final entry in value) {
    if (entry is String && entry.isNotEmpty) {
      out.add(entry);
    }
  }
  return out;
}

/// Qt MusicLibrary.cpp:370-371 `values.at(2).toArray()`：保留 QJsonValue 原始
/// 类型（数字 id 仍是数字），供 MusicData::cursor 做类型敏感查找；非数组一律
/// 空数组，与 toArray() 对非数组值的结果一致。
List<Object?> trackIdValuesOf(Object? value) {
  if (value is! List) {
    return <Object?>[];
  }
  return value.cast<Object?>();
}

/// Qt MusicData.cpp:10-18 identifier()：字符串原样，数值转整数字符串，其余空。
String identifierOf(Object? value) {
  if (value is String) {
    return value;
  }
  if (value is int) {
    return value.toString();
  }
  if (value is double && value.isFinite) {
    return value.toInt().toString();
  }
  return '';
}

String itemKeyOf(JsonMap item) => textOf(item['key']);

String itemIdOf(JsonMap item) => textOf(item['id']);

String itemKindOf(JsonMap item) => textOf(item['kind']);

/// Qt MusicData::item：构造统一条目（Qt/src/MusicData.cpp:22-39）。
JsonMap musicItem({
  required String kind,
  required String id,
  String title = '正在读取…',
  String artist = '',
  String provider = 'netease',
}) {
  return <String, Object?>{
    'kind': kind,
    'id': id,
    'title': title,
    'artist': artist,
    'artists': <Object?>[],
    'creatorID': '',
    'albumID': '',
    'album': '',
    'cover': '',
    'description': '',
    'wiki': '',
    'date': '',
    'duration': 0,
    'trackCount': 0,
    'provider': provider,
    'key': provider + ':' + kind + ':' + id,
  };
}

/// Qt MusicData::parse：把平台原始条目解析成统一条目（Qt/src/MusicData.cpp:41-80）。
/// 只在 playlistForm 的网易云建歌单回包处使用（与 Qt 相同）。
JsonMap musicItemParse(JsonMap raw, String kind) {
  final id = identifierOf(raw['id']);
  if (!RegExp(r'^[0-9]{1,20}$').hasMatch(id) || raw['name'] is! String) {
    return <String, Object?>{};
  }
  var artists = raw['ar'] is List ? raw['ar'] as List : const <Object?>[];
  if (raw['ar'] == null) {
    artists = raw['artists'] is List ? raw['artists'] as List : const <Object?>[];
    if (raw['artists'] == null && raw['artist'] is Map) {
      artists = <Object?>[raw['artist']];
    }
  }
  final creator = mapOf(raw['creator']);
  final album = raw['al'] is Map ? mapOf(raw['al']) : mapOf(raw['album']);
  final names = <String>[];
  final entries = <Object?>[];
  for (final value in artists) {
    final artist = mapOf(value);
    if (artist['name'] is String) {
      names.add(textOf(artist['name']));
      entries.add(<String, Object?>{
        'id': identifierOf(artist['id']),
        'name': artist['name'],
      });
    }
  }
  final value = musicItem(
    kind: kind,
    id: id,
    title: textOf(raw['name']),
    artist: kind == 'playlist'
        ? (creator['nickname'] is String ? textOf(creator['nickname']) : '暂无创建者')
        : names.join(' / '),
  );
  value['artists'] = entries;
  value['creatorID'] = identifierOf(creator['userId']);
  value['albumID'] = identifierOf(album['id']);
  value['album'] = textOf(album['name']);
  value['cover'] = textOf(raw['picUrl']).isNotEmpty
      ? textOf(raw['picUrl'])
      : (textOf(raw['coverImgUrl']).isNotEmpty
          ? textOf(raw['coverImgUrl'])
          : textOf(album['picUrl']));
  value['duration'] = raw['dt'] is num
      ? raw['dt']
      : (raw['duration'] is num ? raw['duration'] : 0);
  value['trackCount'] = raw['trackCount'] is num
      ? raw['trackCount']
      : (raw['size'] is num ? raw['size'] : 0);
  value['description'] = textOf(raw['description']).isNotEmpty
      ? textOf(raw['description'])
      : textOf(raw['briefDesc']);
  final published = raw['publishTime'] is num ? (raw['publishTime'] as num) : 0;
  if (published > 0) {
    value['date'] = _dateOf(published.toInt());
  }
  return value;
}

String _dateOf(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final month = time.month < 10 ? '0' + time.month.toString() : time.month.toString();
  final day = time.day < 10 ? '0' + time.day.toString() : time.day.toString();
  return time.year.toString() + '-' + month + '-' + day;
}

/// Qt MusicData::unique：按 key 去重追加；空 key 同样只保留第一个
/// （Qt/src/MusicData.cpp:82-96 的 QSet 语义）。
List<JsonMap> uniqueItems(List<JsonMap> existing, List<JsonMap> values) {
  final out = List<JsonMap>.of(existing);
  final seen = <String>{for (final item in existing) itemKeyOf(item)};
  for (final value in values) {
    final key = itemKeyOf(value);
    if (seen.add(key)) {
      out.add(value);
    }
  }
  return out;
}

/// Qt MusicData::ordered：按 id 顺序重排，缺失的 id 跳过。
/// ids 是原样保留的 QJsonArray（DirectoryFolder.ids，可能是数字 id），
/// 查表前按 identifierOf 归一（Qt/src/MusicData.cpp:10-18 identifier：
/// 字符串原样、数值转整数字符串）；曲目侧沿用 itemIdOf
/// （Qt/src/MusicData.cpp:98-114 的 song["id"].toString() 只认字符串）。
/// 字符串 id 与 Qt 结果逐位一致；数字 id 在 Qt 的 toString() 下得空串而落空，
/// 这里归一成整数字符串，才能命中 id 为 "7" 的规范曲目 —— 这是规范要求的
/// 修复，不是 Qt 的数值匹配行为。
/// 输出顺序完全由 ids 决定：缺失 id 跳过，重复 id 重复输出，曲目侧重复 id
/// 先到先得（Qt 的 entries.contains 守卫）。
List<JsonMap> orderedItems(List<Object?> ids, List<JsonMap> songs) {
  final byId = <String, JsonMap>{};
  for (final song in songs) {
    final id = itemIdOf(song);
    if (!byId.containsKey(id)) {
      byId[id] = song;
    }
  }
  final out = <JsonMap>[];
  for (final id in ids) {
    final song = byId[identifierOf(id)];
    if (song != null) {
      out.add(song);
    }
  }
  return out;
}

/// Qt MusicData::slice：end=min(size,rawStart+count)，i 从 max(0,start)。
/// end 必须用**未抬正**的 start 计算：start=-2/count=5 时 Qt 只返回 3 个
/// （Qt/src/MusicData.cpp:116-123）。
List<JsonMap> sliceItems(List<JsonMap> values, int start, int count) {
  if (values.isEmpty) {
    return <JsonMap>[];
  }
  final rawEnd = start + count;
  final end = values.length < rawEnd ? values.length : rawEnd;
  final begin = start < 0 ? 0 : start;
  if (begin >= end) {
    return <JsonMap>[];
  }
  return values.sublist(begin, end);
}

/// Qt MusicData::slice 的原始值版本：trackIDs 是 QJsonArray（可含数字），
/// 不能走 sliceStrings 的字符串通道。end 语义与 sliceStrings 完全一致。
List<Object?> sliceValues(List<Object?> values, int start, int count) {
  if (values.isEmpty) {
    return <Object?>[];
  }
  final rawEnd = start + count;
  final end = values.length < rawEnd ? values.length : rawEnd;
  final begin = start < 0 ? 0 : start;
  if (begin >= end) {
    return <Object?>[];
  }
  return values.sublist(begin, end);
}

List<String> sliceStrings(List<String> values, int start, int count) {
  if (values.isEmpty) {
    return <String>[];
  }
  final rawEnd = start + count;
  final end = values.length < rawEnd ? values.length : rawEnd;
  final begin = start < 0 ? 0 : start;
  if (begin >= end) {
    return <String>[];
  }
  return values.sublist(begin, end);
}

/// Qt MusicData::indexOfId：按 ["id"].toString() 比较，不跳过空 id。
int indexOfId(List<JsonMap> values, String id) {
  for (var index = 0; index < values.length; index++) {
    if (itemIdOf(values[index]) == id) {
      return index;
    }
  }
  return -1;
}

/// Qt MusicData::indexOf：QJsonValue 深比较。
int indexOfValue(List<JsonMap> values, JsonMap value) {
  for (var index = 0; index < values.length; index++) {
    if (sameItem(values[index], value)) {
      return index;
    }
  }
  return -1;
}

int indexOfText(List<String> values, Object? value) {
  for (var index = 0; index < values.length; index++) {
    if (values[index] == textOf(value)) {
      return index;
    }
  }
  return -1;
}

/// Qt QJsonValue::operator== 的相等语义：类型不同一律不等，数值比数值、
/// 字符串比文本、数组/对象按内容深比较（Qt/src/MusicData.cpp:125-132）。
bool sameJsonValue(Object? left, Object? right) {
  if (left is num && right is num) {
    return left == right;
  }
  if (left is String && right is String) {
    return left == right;
  }
  if (left is bool && right is bool) {
    return left == right;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!sameJsonValue(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final key in left.keys) {
      if (!right.containsKey(key) || !sameJsonValue(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  return left == null && right == null;
}

/// Qt MusicData::indexOf：QJsonValue 类型敏感查找，数字 id 与字符串 id 不合并。
int indexOfJsonValue(List<Object?> values, Object? value) {
  for (var index = 0; index < values.length; index++) {
    if (sameJsonValue(values[index], value)) {
      return index;
    }
  }
  return -1;
}

/// 条目深比较：对齐 Qt QJsonObject operator==（列表按内容顺序比较）。
bool sameItem(JsonMap left, JsonMap right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key)) {
      return false;
    }
    final other = right[entry.key];
    if (entry.value is List && other is List) {
      if (jsonEncode(entry.value) != jsonEncode(other)) {
        return false;
      }
    } else if (entry.value != other) {
      return false;
    }
  }
  return true;
}

/// Qt MusicData::cursor：末首歌之后的游标，缺省为已载入数量。
/// ids 保持 QJsonArray 的原始值类型：Qt 用 songs.last()["id"] 的 QJsonValue
/// 做类型敏感比较（Qt/src/MusicData.cpp:143-146）。
int cursorOf(List<JsonMap> songs, List<Object?> ids) {
  if (songs.isEmpty) {
    return 0;
  }
  // Qt 的 QJsonObject["id"] 缺键是 Undefined，JSON 数组元素不可能是 Undefined，
  // 因此缺 id 时 indexOf 恒为 -1（不会与数组里的 null 合并）。
  if (!songs.last.containsKey('id')) {
    return songs.length;
  }
  final index = indexOfJsonValue(ids, songs.last['id']);
  return index < 0 ? songs.length : index + 1;
}

/// Qt MusicData::sortOrder：稳定排序，空名置后，忽略大小写并识别数字段。
/// Qt 用 QCollator(zh_CN, CaseInsensitive, NumericMode) 对 trimmed 原名排序
/// （不做 toLower，避免改变中英混排结果）。
List<int> sortOrder(List<JsonMap> values, String field) {
  final indices = List<int>.generate(values.length, (int index) => index);
  if (field != 'title' && field != 'album' && field != 'artist') {
    return indices;
  }
  final names = <String>[for (final value in values) textOf(value[field]).trim()];
  indices.sort((int left, int right) {
    final a = names[left];
    final b = names[right];
    if (a.isEmpty != b.isEmpty) {
      return a.isEmpty ? 1 : -1;
    }
    final compared = compareNatural(a.toLowerCase(), b.toLowerCase());
    return compared != 0 ? compared : left.compareTo(right);
  });
  return indices;
}

/// QCollator 数字感知比较的近似：数字段按数值、其他按码位比较。
int compareNatural(String left, String right) {
  var i = 0;
  var j = 0;
  while (i < left.length && j < right.length) {
    final ca = left.codeUnitAt(i);
    final cb = right.codeUnitAt(j);
    final digitA = ca >= 0x30 && ca <= 0x39;
    final digitB = cb >= 0x30 && cb <= 0x39;
    if (digitA && digitB) {
      var endA = i;
      while (endA < left.length &&
          left.codeUnitAt(endA) >= 0x30 &&
          left.codeUnitAt(endA) <= 0x39) {
        endA++;
      }
      var endB = j;
      while (endB < right.length &&
          right.codeUnitAt(endB) >= 0x30 &&
          right.codeUnitAt(endB) <= 0x39) {
        endB++;
      }
      final numberA = int.tryParse(left.substring(i, endA)) ?? 0;
      final numberB = int.tryParse(right.substring(j, endB)) ?? 0;
      if (numberA != numberB) {
        return numberA.compareTo(numberB);
      }
      i = endA;
      j = endB;
      continue;
    }
    if (ca != cb) {
      return ca.compareTo(cb);
    }
    i++;
    j++;
  }
  if (i < left.length) {
    return 1;
  }
  if (j < right.length) {
    return -1;
  }
  return 0;
}

/// Qt QVector/QList::value(index, fallback)。
int slotValue(List<int> slots, int index, int fallback) {
  return (index >= 0 && index < slots.length) ? slots[index] : fallback;
}

// 目录节点（Qt MusicLibrary.h 的 MusicDirectory + MusicDirectory.cpp）

/// 目录栈节点。父指针构成返回链，anchor 让选中项在 5 列 8 行网格中保持物理位置。
class DirectoryFolder {
  DirectoryFolder({
    this.parent,
    JsonMap? item,
    List<JsonMap>? songs,
    this.sortField = 'none',
    List<Object?>? ids,
    List<JsonMap>? albums,
    this.cursor = 0,
    this.index = 0,
    this.anchor = 0,
    this.page = 0,
    this.parentPhysical = 0,
    this.parentLane = 0,
    JsonMap? parentItem,
    this.albumCursor = 0,
    this.albumsMore = false,
    this.albumsLoading = false,
  })  : item = item ?? <String, Object?>{},
        songs = songs ?? <JsonMap>[],
        ids = ids ?? <Object?>[],
        albums = albums ?? <JsonMap>[],
        parentItem = parentItem ?? <String, Object?>{};

  DirectoryFolder? parent;
  JsonMap item;
  List<JsonMap> songs;
  String sortField;
  /// Qt MusicDirectory::ids 是原样保留的 QJsonArray（可能是数字 id），
  /// 不能用字符串投影，否则后续游标/包含判断会与 Qt 分叉。
  List<Object?> ids;
  List<JsonMap> albums;
  int cursor;
  int index;
  int anchor;
  int page;
  int parentPhysical;
  int parentLane;
  JsonMap parentItem;
  int albumCursor;
  bool albumsMore;
  bool albumsLoading;

  List<JsonMap>? _cachedSongs;
  List<JsonMap> _sorted = <JsonMap>[];
  String? _cachedSortField;

  /// Qt MusicDirectory::orderedSongs（Qt/src/MusicDirectory.cpp:9-19）。
  List<JsonMap> orderedSongs() {
    if (identical(_cachedSongs, songs) && _cachedSortField == sortField) {
      return _sorted;
    }
    final indices = sortOrder(songs, sortField);
    _sorted = <JsonMap>[for (final index in indices) songs[index]];
    _cachedSongs = songs;
    _cachedSortField = sortField;
    return _sorted;
  }

  /// Qt MusicDirectory::updateSongs（Qt/src/MusicDirectory.cpp:22-31）：
  /// 换页/排序后保持选中项与物理格位 (index + anchor) % 40。
  void updateSongs(List<JsonMap> values, String field) {
    final previous = orderedSongs();
    final selected =
        index >= 0 && index < previous.length ? itemIdOf(previous[index]) : '';
    final cell = (index + anchor) % 40;
    songs = values;
    sortField = field;
    _cachedSongs = null;
    _cachedSortField = null;
    final ordered = orderedSongs();
    final position = selected.isEmpty ? -1 : indexOfId(ordered, selected);
    index = position >= 0
        ? position
        : (index < 0
            ? 0
            : (index > (values.isEmpty ? 0 : values.length - 1)
                ? (values.isEmpty ? 0 : values.length - 1)
                : index));
    page = (index ~/ 40) * 40;
    anchor = ((cell - index % 40) + 40) % 40;
  }

  JsonMap toJson() {
    return <String, Object?>{
      'item': item,
      'songs': songs,
      'sortField': sortField,
      'ids': ids,
      'albums': albums,
      'cursor': cursor,
      'index': index,
      'anchor': anchor,
      'page': page,
      'parentPhysical': parentPhysical,
      'parentLane': parentLane,
      'parentItem': parentItem,
      'albumCursor': albumCursor,
      'albumsMore': albumsMore,
    };
  }

  /// Qt MusicSession.cpp:115-137 的目录重建（sortField 白名单、数值夹取）。
  static DirectoryFolder fromJson(JsonMap saved) {
    final field = textOf(saved['sortField']);
    final folder = DirectoryFolder(
      item: mapOf(saved['item']),
      songs: mapsOf(saved['songs']),
      sortField: const <String>{'none', 'title', 'album', 'artist'}.contains(field)
          ? field
          : 'none',
      ids: trackIdValuesOf(saved['ids']),
      albums: mapsOf(saved['albums']),
      cursor: intOf(saved['cursor']),
      index: intOf(saved['index']),
      anchor: intOf(saved['anchor']),
      page: intOf(saved['page']),
      parentPhysical: intOf(saved['parentPhysical']),
      parentLane: intOf(saved['parentLane']),
      parentItem: mapOf(saved['parentItem']),
      albumCursor: intOf(saved['albumCursor']),
      albumsMore: boolOf(saved['albumsMore']),
    );
    folder.cursor = _clampInt(folder.cursor, 0, folder.ids.length);
    folder.index = _clampInt(
      folder.index,
      0,
      folder.songs.isEmpty ? 0 : folder.songs.length - 1,
    );
    folder.anchor = _clampInt(folder.anchor, 0, 39);
    folder.page = (folder.index ~/ 40) * 40;
    folder.parentPhysical = _clampInt(folder.parentPhysical, 0, 39);
    folder.parentLane = _clampInt(folder.parentLane, 0, 4);
    folder.albumCursor = folder.albumCursor < 0 ? 0 : folder.albumCursor;
    return folder;
  }
}

int _clampInt(int value, int lowest, int highest) {
  if (highest < lowest) {
    return lowest;
  }
  if (value < lowest) {
    return lowest;
  }
  if (value > highest) {
    return highest;
  }
  return value;
}

/// Qt 里大量出现 qMax(0, value)：负值一律归零，正数保持原样。
int _nonnegative(int value) => value < 0 ? 0 : value;

/// 一次导航通知（Qt signal navigationRequested(axis, direction)）。
class LibraryNavigation {
  const LibraryNavigation(this.axis, this.direction);

  final String axis;
  final int direction;
}

/// Qt MusicLibrary：曲库 / 目录 / 搜索 / 账号 / 写操作的领域根对象。
///
/// 逐语义迁移 Qt/src/MusicLibrary.{h,cpp}；拆出的 4 个 part 共享本私有作用域。
class MusicLibrary {
  MusicLibrary({
    required LibraryHostPort host,
    required LibraryPreferencesPort preferences,
    required HostRequestPort requests,
    JsonMap? content,
    this.collections,
    PlaybackPort? player,
    SchedulerPort? scheduler,
    this.local,
  })  : host = host,
        preferences = preferences,
        api = MusicApiClient(requests, host: host),
        player = player ?? NullPlayback(),
        scheduler = scheduler ?? TimerScheduler(),
        _content = content ?? <String, Object?>{} {
    _identityApi = MusicApiClient(requests, host: host);
    _bootstrap();
  }

  final LibraryHostPort host;
  final LibraryPreferencesPort preferences;
  final MusicApiClient api;
  final PlaybackPort player;
  final SchedulerPort scheduler;
  final SirenCollectionsPort? collections;
  LocalMusicPort? local;
  final JsonMap _content;
  late final MusicApiClient _identityApi;

  static const List<String> _onlineColumns = <String>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑'];
  static const List<String> _sirenColumns = <String>['搜索结果', '喜欢的歌曲', '我的歌单', '全部歌曲', '全部专辑'];
  static const List<String> _localColumns = <String>['本地检索', '全部歌曲', '文件夹', '本地专辑', '本地歌手'];
  static const int _maxSearchHistory = 12;
  static const int _maxSeedFolders = 64;
  static const int _physicalCount = 40;

  // ── Qt MusicLibrary.h:136-210 公开状态 ────────────────────────────────
  String provider = 'netease';
  String kugouEdition = 'standard';
  List<String> columns = List<String>.from(_onlineColumns);

  Map<String, String> identityNames = <String, String>{};

  List<List<JsonMap>> lists = List<List<JsonMap>>.generate(5, (_) => <JsonMap>[]);
  List<int> totals = List<int>.filled(5, 0);
  List<int> offsets = List<int>.filled(5, 0);
  List<int> sirenOffsets = List<int>.filled(5, 0);
  List<bool> hasMore = List<bool>.filled(5, true);
  List<int> rowMemory = List<int>.filled(5, 0);
  List<List<int>> physicalSlots = List<List<int>>.generate(5, (_) => <int>[]);
  List<String> sourceErrors = List<String>.filled(5, '');

  List<JsonMap> sirenSongs = <JsonMap>[];
  List<JsonMap> sirenAlbums = <JsonMap>[];
  bool sirenCatalogLoading = false;
  bool pendingSirenSearch = false;

  int selectedPhysical = -1;
  int selectedLane = 0;

  JsonMap current = <String, Object?>{};
  List<JsonMap> tracks = <JsonMap>[];
  /// Qt MusicLibrary.h `QJsonArray trackIDs`：保留 values.at(2) 的原始 QJsonValue
  /// 类型（数字 id 仍是数字）；续页请求与 `trackIDs` 快照都按原样走。
  List<Object?> trackIds = <Object?>[];
  List<JsonMap> playContext = <JsonMap>[];
  Map<String, JsonMap> details = <String, JsonMap>{};
  bool privateSelection = false;

  String coverImage = '';
  String coverKey = '';
  bool wantsSongDetails = false;

  String searchKind = 'song';
  String keyword = '';
  String status = '输入关键词检索音乐';
  int searchCursor = 0;
  List<String> searchHistory = <String>[];
  List<String> suggestions = <String>[];
  bool searchLoading = false;

  DirectoryFolder? directory;
  bool directoryLoading = false;
  bool directoryInfo = false;
  JsonMap frame = <String, Object?>{'mode': 'archive', 'selected': 0};
  final MusicDiscoverState discover = MusicDiscoverState();

  String uid = '';
  String nickname = '未登录';
  bool restoringAccount = false;
  String mAccountError = '';
  bool personalLoading = false;
  bool writeLoading = false;
  bool detailLoading = false;
  bool trackLoad = false;
  bool albumLoaded = false;

  List<String>? likedIds;
  List<String> subscriptions = <String>[];
  Map<String, String> subscriptionStates = <String, String>{};
  JsonMap capabilities = <String, Object?>{};
  String vipLevel = 'unknown';

  String groupName = '';
  List<int> groupIndices = <int>[];
  int groupLane = -1;

  int playlistCursor = 0;
  int albumCursor = 0;
  int likedCursor = 0;
  int trackCursor = 0;

  int generation = 0;
  int selectionGeneration = 0;
  int accountGeneration = 0;
  int directoryGeneration = 0;
  int wikiGeneration = 0;
  int suggestGeneration = 0;
  int subscriptionGeneration = 0;
  int playbackLikeGeneration = 0;
  String playbackLikeContext = '';

  final List<LibraryNavigation> navigationRequests = <LibraryNavigation>[];
  final List<String> modeRequests = <String>[];
  final List<String> identityRequests = <String>[];
  final List<({int index, JsonMap navigation})> selectionRequests = <({int index, JsonMap navigation})>[];
  int revision = 0;
  void Function()? onInvalidated;
  void Function()? onPlaybackInvalidated;
  void Function()? onMusicClearRequested;

  // Qt MusicAccount.cpp 登录状态
  String qr = '';
  String qrKey = '';
  String loginStatus = '';
  String loginPhase = 'idle';
  String loginMethod = 'qr';
  JsonMap loginDiagnostics = <String, Object?>{};
  bool accountLoading = false;

  final Map<String, _Cooldown> _cooldowns = <String, _Cooldown>{};
  final Map<String, _Cancellation> _cancellations = <String, _Cancellation>{};
  int _loginGeneration = 0;
  int _cooldownGeneration = 0;
  int _smsRetryAtMs = 0;
  int _pendingLane = -1;
  bool _playLiked = false;

  // ── 构造（Qt MusicLibrary::MusicLibrary 16-82） ───────────────────────
  void _bootstrap() {
    kugouEdition = _pref('kugou-edition') == 'lite' ? 'lite' : 'standard';
    final saved = _pref('provider');
    const Set<String> known = <String>{'netease', 'qq', 'kugou', 'local', 'siren'};
    provider = known.contains(saved) ? saved : 'netease';
    if (provider == 'local' && !host.localEnabled) {
      provider = 'netease';
    }
    api.provider = provider;
    columns = List<String>.from(isSiren ? _sirenColumns : _onlineColumns);
    _buildPhysicalSlots();
    identityNames['netease'] = _pref('welcome-name-netease');
    identityNames['qq'] = _pref('welcome-name-qq');
    identityNames['kugou'] = _pref('welcome-name-kugou-' + kugouEdition);
    _loadSearchHistory();
    restoreCachedAccount();
    if (isLocal && local != null) {
      unawaited(refreshLocal());
    }
    if (isSiren && collections != null) {
      unawaited(librarySirenReloadCollections(this));
      unawaited(librarySirenLoadCatalog(this));
    }
    player.onChanged = () {
      if (isLocal) {
        final value = player.current;
        final cover = textOf(value['cover']);
        if (cover.isNotEmpty && cover != coverImage) {
          coverImage = cover;
          coverKey = itemKeyOf(value);
        }
      }
      refreshPlaybackLike();
      ++revision;
      onPlaybackInvalidated?.call();
    };
    player.onTrackSelected = (JsonMap value) {
      unawaited(followPlayback(value));
    };
  }

  void _loadSearchHistory() {
    final raw = _pref('search-history');
    if (raw.isEmpty) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! List) {
      return;
    }
    final values = <String>[];
    for (final entry in decoded) {
      if (entry is String && entry.isNotEmpty) {
        values.add(entry);
        if (values.length >= _maxSearchHistory) {
          break;
        }
      }
    }
    searchHistory = values;
  }

  void _buildPhysicalSlots() {
    physicalSlots = List<List<int>>.generate(5, (_) => <int>[]);
    final records = mapsOf(_content['records']);
    // Qt MusicLibrary.cpp:52-58 对 records 全量 append，不在 40 处截断；
    // 40 只用于恢复会话时校验 selectedPhysical 上限（MusicSession.cpp:95）。
    for (var index = 0; index < records.length; index++) {
      final category = textOf(records[index]['category']);
      if (category.isEmpty) {
        continue;
      }
      for (var lane = 0; lane < columns.length && lane < 5; lane++) {
        if (columns[lane] == category) {
          physicalSlots[lane].add(index);
          break;
        }
      }
    }
  }

  // ── 偏好读写（Qt preference/setPreference） ──────────────────────────
  String _pref(String key) => preferences.read(key) ?? '';

  void _setPref(String key, String value) => preferences.write(key, value);

  // ── 派生（Qt MusicLibrary.h:212-236 内联） ───────────────────────────
  /// Qt m_accountError 的冻结别名（契约要求暴露 accountError）。
  String get accountError => mAccountError;

  set accountError(String value) => mAccountError = value;

  bool get isLocal => provider == 'local';

  bool get isKugou => provider == 'kugou';

  bool get isSiren => provider == 'siren';

  /// Qt editable(): netease / qq / siren（草稿曾漏掉 qq）。
  bool get editable => provider == 'netease' || provider == 'qq' || provider == 'siren';

  /// Qt sourceLoading(): 四个来源装载标志的合并。
  bool get sourceLoading => restoringAccount || searchLoading || personalLoading || sirenCatalogLoading;

  List<JsonMap> get discoverItems => discover.items;

  String providerName() => musicProviderName(provider);

  String accountKey() => isKugou ? 'kugou-' + kugouEdition : provider;

  String identityName() {
    if (isSiren) {
      return '';
    }
    return identityNames[provider] ?? '';
  }

  List<int> sourceOrder() => isKugou ? <int>[1, 2, 3, 0] : <int>[1, 2, 3, 4, 0];

  List<JsonMap> sourceItems([int? lane]) {
    final index = lane ?? selectedLane;
    if (index < 0 || index >= lists.length) {
      return <JsonMap>[];
    }
    if (groupLane == index && groupIndices.isNotEmpty) {
      final values = <JsonMap>[];
      for (final position in groupIndices) {
        if (position >= 0 && position < lists[index].length) {
          values.add(lists[index][position]);
        }
      }
      return values;
    }
    return lists[index];
  }

  List<JsonMap> libraryItems() {
    final folder = directory;
    if (folder != null) {
      return folder.songs;
    }
    return sourceItems();
  }

  String libraryName() {
    final folder = directory;
    if (folder != null) {
      return textOf(folder.item['title']);
    }
    return selectedLane >= 0 && selectedLane < columns.length ? columns[selectedLane] : '';
  }

  int libraryTotal([DirectoryFolder? folder]) {
    final target = folder ?? directory;
    if (target != null) {
      var total = target.ids.length;
      final count = intOf(target.item['trackCount']);
      if (count > total) {
        total = count;
      }
      if (target.songs.length > total) {
        total = target.songs.length;
      }
      return total;
    }
    if (groupLane == selectedLane) {
      return sourceItems().length;
    }
    if (selectedLane < 0 || selectedLane >= totals.length) {
      return 0;
    }
    return totals[selectedLane];
  }

  int libraryIndex([DirectoryFolder? folder]) {
    final target = folder ?? directory;
    if (target != null) {
      return target.index;
    }
    final slots = selectedLane >= 0 && selectedLane < physicalSlots.length ? physicalSlots[selectedLane] : <int>[];
    final row = slots.indexOf(selectedPhysical);
    final offset = selectedLane >= 0 && selectedLane < offsets.length ? offsets[selectedLane] : 0;
    final count = sourceItems().length;
    return wrapIndex(offset + (row > 0 ? row : 0), count < 1 ? 1 : count);
  }

  void setGroupView(String name, List<int> indices, int lane) {
    groupIndices = List<int>.from(indices);
    groupName = name;
    groupLane = indices.isEmpty ? -1 : lane;
  }

  void changed() {
    refreshPlaybackLike();
    ++revision;
    onInvalidated?.call();
  }

  void clearCaches() {
    unawaited(host.clearCache());
    player.clearCaches();
    searchHistory.clear();
    suggestions.clear();
    _setPref('search-history', '[]');
    changed();
  }

  /// Qt MusicLibrary::sourceMessage：栏目空态/错误文案，逐字对齐。
  String sourceMessage(int lane) {
    if (lane < 0 || lane >= columns.length) {
      return '';
    }
    final column = columns[lane];
    if (isLocal) {
      if (local != null && local!.busy) {
        return local!.status;
      }
      if (libraryItems().isEmpty) {
        return '暂无本地音乐，请在文件夹管理中导入';
      }
      if (lane == 0) {
        return '没有匹配的本地音乐';
      }
      return '暂无此类本地音乐';
    }
    if (lane == 0) {
      return searchLoading ? '正在检索音乐，请稍候…' : status;
    }
    if (isKugou && lane == 4) {
      return '此渠道暂不支持收藏专辑';
    }
    if (isSiren) {
      if (sirenCatalogLoading) {
        return '正在读取塞壬唱片曲库…';
      }
      if (personalLoading) {
        return '正在读取' + column + '，请稍候…';
      }
      final error = lane < sourceErrors.length ? sourceErrors[lane] : '';
      if (error.isNotEmpty) {
        return error + '，可点击加载更多重试';
      }
      if (lane == 1) {
        return '暂无喜欢的歌曲，在歌曲详情或播放栏点击红心即可加入';
      }
      if (lane == 2) {
        return '暂无本地歌单，点击上方“创建歌单”开始整理';
      }
      return '暂无' + column;
    }
    if (restoringAccount) {
      return '正在恢复' + providerName() + '登录，请稍候…';
    }
    if (mAccountError.isNotEmpty) {
      return mAccountError;
    }
    if (uid.isEmpty) {
      return '登录后查看个人音乐';
    }
    if (personalLoading) {
      return '正在读取' + column + '，请稍候…';
    }
    final error = lane < sourceErrors.length ? sourceErrors[lane] : '';
    if (error.isNotEmpty) {
      return error;
    }
    return '暂无' + column;
  }

  // ── 栏目切换（Qt showSource 556-588） ────────────────────────────────
  void showSource(int lane) {
    if (lane < 0 || lane >= columns.length) {
      return;
    }
    if (isKugou && lane == 4) {
      status = '酷狗 API 未提供收藏专辑，此栏目已禁用';
      changed();
      return;
    }
    privateSelection = lane > 0 && !isLocal && !isSiren;
    if (directory != null) {
      unawaited(leaveDirectory(restore: false));
    }
    selectedLane = lane;
    selectedPhysical = -1;
    final physical = slotValue(physicalSlots[lane], rowMemory[lane], -1);
    selectionRequests.add((index: physical, navigation: const <String, Object?>{}));
    unawaited(observe(physical));
    if (isSiren) {
      if (lane > 0 && lists[lane].isEmpty) {
        unawaited(loadMoreSource(lane));
      }
    // Qt/src/MusicLibrary.cpp:578 是 `} else if (lane > 0 && !isLocal()) {`：
    // lane 0 是检索栏，空 uid 时既不覆盖 status 也不预取。
    } else if (lane > 0 && !isLocal) {
      if (restoringAccount) {
        unawaited(loadMoreSource(lane));
      } else if (uid.isEmpty) {
        status = '登录后查看' + columns[lane];
      } else if (lists[lane].isEmpty) {
        unawaited(loadMoreSource(lane));
      }
    }
    changed();
  }

  // ── 选择（Qt observe 244-279 / choose 282-394） ──────────────────────
  Future<void> observe(int physical) async {
    if (directory != null) {
      await observeDirectory(physical);
      return;
    }
    if (physical == selectedPhysical) {
      return;
    }
    var lane = -1;
    for (var index = 0; index < physicalSlots.length; index++) {
      if (physicalSlots[index].contains(physical)) {
        lane = index;
        break;
      }
    }
    if (lane < 0) {
      return;
    }
    if (isKugou && lane == 4) {
      final slots = physicalSlots[selectedLane];
      if (slots.isNotEmpty) {
        selectionRequests.add((
          index: slotValue(slots, rowMemory[selectedLane], 0),
          navigation: const <String, Object?>{},
        ));
      }
      return;
    }
    selectedPhysical = physical;
    selectedLane = lane;
    rowMemory[lane] = physicalSlots[lane].indexOf(physical);
    final values = sourceItems(lane);
    playContext = values;
    if (values.isEmpty) {
      unawaited(choose(<String, Object?>{}));
      if (lane > 0) {
        unawaited(loadMoreSource(lane));
      }
      return;
    }
    unawaited(choose(values[wrapIndex(offsets[lane] + rowMemory[lane], values.length)]));
  }

  Future<void> choose(
    JsonMap input, {
    JsonMap? containerDetails,
    bool? showDetails,
  }) async {
    final token = ++selectionGeneration;
    ++wikiGeneration;
    final key = itemKeyOf(input);
    wantsSongDetails = showDetails ?? textOf(frame['mode']) == 'detail';
    albumLoaded = false;
    trackCursor = 0;
    trackLoad = false;
    current = input;
    identityRequests.add(key);
    tracks = <JsonMap>[];
    trackIds = <String>[];
    if (coverKey != key) {
      coverImage = '';
      coverKey = '';
    }
    detailLoading = input.isNotEmpty;
    changed();
    if (input.isEmpty) {
      return;
    }
    current = details[key] ?? input;
    unawaited(loadCover(current));
    if (isLocal) {
      details[key] = current;
      detailLoading = false;
      changed();
      return;
    }
    unawaited(loadSubscriptionStatus());
    detailLoading = true;
    if (itemKindOf(current) != 'song' && containerDetails == null) {
      detailLoading = false;
      changed();
      return;
    }
    final quick = itemKindOf(current) == 'song' &&
        intOf(current['duration']) > 0 &&
        textOf(current['albumID']).isNotEmpty &&
        (textOf(current['cover']).isNotEmpty || details.containsKey(key));
    if (quick) {
      details[key] = current;
      detailLoading = false;
      if (wantsSongDetails) {
        unawaited(loadSongWiki());
      }
      changed();
      return;
    }
    if (!_isAlive(token)) {
      return;
    }
    await _delay(300);
    if (!_isAlive(token)) {
      return;
    }
    final reply = await api.call('detail', <Object?>[input]);
    if (!_isAlive(token)) {
      return;
    }
    if (!reply.ok) {
      detailLoading = false;
      status = '读取失败：' + (reply.error ?? '');
      changed();
      return;
    }
    final values = mapsOf(reply.value);
    if (values.isEmpty) {
      detailLoading = false;
      status = '读取失败：元数据格式无效';
      changed();
      return;
    }
    final value = <String, Object?>{...values[0]};
    if (itemKindOf(value) == 'song') {
      final description = current['description'];
      if (description != null) {
        value['description'] = description;
      }
      value['wiki'] = current['wiki'];
    }
    if (textOf(current['date']).isNotEmpty) {
      value['date'] = current['date'];
    }
    if (boolOf(input['special'])) {
      value['special'] = true;
    }
    details[key] = value;
    if (lists[0].isNotEmpty && itemKeyOf(lists[0][0]) == key) {
      lists[0][0] = value;
    }
    current = value;
    final songs = values.length > 1 ? mapsOf(values[1]) : <JsonMap>[];
    if (itemKindOf(value) != 'song' || !albumLoaded) {
      tracks = songs;
    }
    final rawTrackIds = values.length > 2 ? values[2] : null;
    // Qt MusicLibrary.cpp:370-371 `trackIDs = values.at(2).toArray()`：保留原始
    // QJsonValue 类型。stringsOf 会把数字 id 丢成空列表，续页与快照都会丢条目，
    // 类型敏感游标也就永远走不到。
    trackIds = trackIdValuesOf(rawTrackIds);
    trackCursor = cursorOf(tracks, trackIds);
    detailLoading = false;
    if (status == '正在读取链接…') {
      status = '已读取：' + textOf(value['title']);
    }
    unawaited(loadCover(value));
    changed();
    if (itemKindOf(value) == 'song' && textOf(value['wiki']).isEmpty && wantsSongDetails) {
      final wikiReply = await api.call('wiki', <Object?>[textOf(value['id'])]);
      if (!_isAlive(token)) {
        return;
      }
      if (wikiReply.ok) {
        final wiki = textOf(wikiReply.value);
        if (wiki.isNotEmpty) {
          current['wiki'] = wiki;
          details[key] = current;
          changed();
        }
      } else {
        status = '百科暂时无法读取：' + (wikiReply.error ?? '');
        changed();
      }
    }
  }

  Future<void> loadCover(JsonMap value) async {
    final key = itemKeyOf(value);
    final cover = textOf(value['cover']);
    if (cover.isEmpty) {
      return;
    }
    final token = selectionGeneration;
    await _delay(200);
    if (!_isAlive(token) || itemKeyOf(current) != key) {
      return;
    }
    final image = await host.loadCover(cover);
    if (!_isAlive(token) || image == null || image.isEmpty) {
      return;
    }
    coverImage = image;
    coverKey = key;
    changed();
  }

  bool _isAlive(int token) => token == selectionGeneration;

  Future<void> _delay(int millis) {
    final completer = Completer<void>();
    scheduler.schedule(Duration(milliseconds: millis), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  /// Qt MusicLibrary::loadSongWiki（912-937）。
  Future<void> loadSongWiki() async {
    if (isLocal) {
      return;
    }
    wantsSongDetails = true;
    if (itemKindOf(current) != 'song' || detailLoading || textOf(current['wiki']).isNotEmpty) {
      return;
    }
    final token = selectionGeneration;
    final wikiToken = ++wikiGeneration;
    final reply = await api.call('wiki', <Object?>[textOf(current['id'])]);
    if (!_isAlive(token) || wikiToken != wikiGeneration) {
      return;
    }
    if (reply.ok) {
      final wiki = textOf(reply.value);
      if (wiki.isNotEmpty) {
        current['wiki'] = wiki;
        details[itemKeyOf(current)] = current;
        changed();
      }
      return;
    }
    status = '百科暂不可读取：' + (reply.error ?? '');
    changed();
  }

  /// Qt MusicLibrary::loadTrackPage（856-878）。
  Future<void> loadTrackPage([int? start]) async {
    if (isLocal) {
      return;
    }
    final offset = start ?? trackCursor;
    if (current.isEmpty || trackLoad) {
      return;
    }
    if (offset + 3 < tracks.length || offset >= trackIds.length) {
      return;
    }
    trackLoad = true;
    // Qt MusicLibrary.cpp:856-878 原样把 trackIDs 切片交给 songs；归一化只用于
    // ordered() 的 id→song 匹配（MusicData::identifier 语义），请求仍带原始类型。
    final ids = sliceValues(trackIds, offset, 100);
    final reply = await api.call('songs', <Object?>[ids]);
    trackLoad = false;
    if (!reply.ok) {
      status = reply.error ?? '';
      changed();
      return;
    }
    trackCursor = offset + ids.length;
    tracks = uniqueItems(
      tracks,
      orderedItems(<String>[for (final entry in ids) identifierOf(entry)], mapsOf(reply.value)),
    );
    changed();
  }

  /// Qt MusicLibrary::sameAlbum（880-910）。
  Future<void> sameAlbum() async {
    if (isLocal) {
      final source = local;
      if (source != null) {
        tracks = source.tracks(<String, Object?>{'kind': 'album', 'id': textOf(current['albumID'])});
        albumLoaded = true;
        changed();
      }
      return;
    }
    if (itemKindOf(current) != 'song' || detailLoading || textOf(current['albumID']).isEmpty || albumLoaded) {
      return;
    }
    albumLoaded = true;
    final album = musicItem(
      kind: 'album',
      id: textOf(current['albumID']),
      title: textOf(current['album']),
      artist: textOf(current['artist']),
      provider: provider,
    );
    final reply = await api.call('detail', <Object?>[album]);
    if (!reply.ok) {
      albumLoaded = false;
      status = reply.error ?? '';
      changed();
      return;
    }
    final values = mapsOf(reply.value);
    if (values.isEmpty) {
      albumLoaded = false;
      status = '读取失败：元数据格式无效';
      changed();
      return;
    }
    final value = values[0];
    current['description'] = value['description'] ?? current['description'];
    current['date'] = value['date'];
    tracks = values.length > 1 ? mapsOf(values[1]) : <JsonMap>[];
    changed();
  }

  /// Qt MusicLibrary::play（943-957）。
  void play({bool byUser = true}) {
    if (itemKindOf(current) != 'song') {
      status = '请先选择一首歌曲';
      changed();
      return;
    }
    final replaceQueue = byUser && _pref('single-play-mode') != 'append';
    if (!replaceQueue) {
      player.play(current);
      return;
    }
    final source = currentSource();
    player.play(current, source: source.items);
    player.loadQueue(source.ids, source.items);
  }

  ({List<String> ids, List<JsonMap> items}) currentSource() {
    final source = directorySource();
    final id = textOf(current['id']);
    final loaded = indexOfId(source.items, id) >= 0;
    final listed = source.ids.isNotEmpty && source.ids.contains(id);
    if (loaded || listed) {
      return source;
    }
    final contextId = indexOfId(playContext, id);
    if (contextId >= 0) {
      return (ids: <String>[], items: playContext);
    }
    return (ids: <String>[], items: libraryItems());
  }

  /// Qt MusicLibrary::directorySource（975-1010）。
  ({List<String> ids, List<JsonMap> items}) directorySource() {
    final folder = directory;
    if (folder != null) {
      final values = folder.orderedSongs();
      // Qt MusicLibrary.cpp:979-981：sortField=none 时 ids 就是目录的完整 ids；
      // 播放端口以字符串承载，数字 id 走 identifier() 归一化。
      if (folder.sortField == 'none') {
        return (ids: <String>[for (final id in folder.ids) identifierOf(id)], items: values);
      }
      final ids = <String>[];
      for (final value in values) {
        if (itemKindOf(value) == 'song') {
          ids.add(textOf(value['id']));
        }
      }
      for (final id in folder.ids) {
        final text = identifierOf(id);
        if (!ids.contains(text)) {
          ids.add(text);
        }
      }
      return (ids: ids, items: values);
    }
    if (isSiren && selectedLane == 3) {
      // Qt MusicLibrary.cpp:996-1001：塞壬收藏列表的 ids 来自列表项的原始 ["id"]。
      return (
        ids: <String>[for (final value in lists[3]) identifierOf(value['id'])],
        items: lists[3],
      );
    }
    if (selectedLane == 1) {
      final values = lists[1];
      final ids = likedIds;
      if (ids != null) {
        return (ids: List<String>.from(ids), items: values);
      }
      return (ids: <String>[], items: values);
    }
    return (ids: <String>[], items: sourceItems());
  }

  /// Qt MusicLibrary::playDirectory（1013-1029）。
  void playDirectory() {
    final allowed = directory != null || selectedLane == 1 || (isSiren && selectedLane == 3);
    if (!allowed) {
      return;
    }
    if (directory == null && selectedLane == 1 && !isLocal && hasMore[1]) {
      _playLiked = true;
      unawaited(loadMoreSource(1));
      return;
    }
    final source = directorySource();
    if (source.items.isEmpty) {
      return;
    }
    player.play(source.items.first, source: source.items);
    player.loadQueue(source.ids, source.items);
  }

  /// Qt MusicLibrary::playOfficial（1031-1054）：显式 `value` 为空回落到 current。
  void playOfficial([JsonMap? selection]) {
    if (isLocal) {
      return;
    }
    final value = selection == null || selection.isEmpty ? current : selection;
    if (value.isEmpty || itemKindOf(value) != 'song') {
      return;
    }
    // Qt `value["provider"].toString(provider)`：只有字符串才覆盖当前渠道；
    // 缺键或非字符串（含数值）一律回落到 provider。
    final rawProvider = value['provider'];
    final source = rawProvider is String ? rawProvider : provider;
    if (source != 'netease') {
      unawaited(host.openExternal(sourceURL(value)));
      return;
    }
    unawaited(host.playOfficial(textOf(value['id']), (String message) {
      status = message;
      changed();
    }));
  }

  /// Qt MusicLibrary::sourceURL（1056-1082）。
  String sourceURL([JsonMap? value]) {
    if (isLocal) {
      return '';
    }
    // Qt 1060-1062：显式空对象与缺省一样回落到 current，仍空才返回 {}。
    var item = value ?? const <String, Object?>{};
    if (item.isEmpty) {
      item = current;
    }
    if (item.isEmpty) {
      return '';
    }
    final kind = itemKindOf(item);
    final id = textOf(item['id']);
    // Qt `value["provider"].toString(provider)`：URL 用条目自身渠道，不用全局 provider。
    final rawProvider = item['provider'];
    final source = rawProvider is String ? rawProvider : provider;
    if (source == 'netease') {
      return 'https://music.163.com/#/' + kind + '?id=' + id;
    }
    if (source == 'kugou') {
      return 'https://www.kugou.com/';
    }
    if (source == 'siren') {
      return 'https://monster-siren.hypergryph.com/music';
    }
    var path = '';
    if (kind == 'song') {
      path = 'songDetail';
    } else if (kind == 'album') {
      path = 'albumDetail';
    } else if (kind == 'artist') {
      path = 'singer';
    } else if (kind == 'playlist') {
      path = boolOf(item['chart']) ? 'toplist' : 'playlist';
    }
    if (path.isEmpty) {
      return '';
    }
    return 'https://y.qq.com/n/ryqq/' + path + '/' + Uri.encodeComponent(id).replaceAll('%21', '!').replaceAll('%28', '(').replaceAll('%29', ')').replaceAll('%2A', '*');
  }

  /// Qt MusicData::pageOf 的等价解析：既接受 List payload，也接受 {items,total,more,...} 对象。
  ({List<JsonMap> items, int rawCount, int total, bool more, bool incomplete, String notice})
  pageOf(Object? payload) {
    if (payload is List) {
      final items = mapsOf(payload);
      return (
        items: items,
        rawCount: items.length,
        total: items.length,
        more: false,
        incomplete: false,
        notice: '',
      );
    }
    final page = mapOf(payload);
    final items = mapsOf(page.containsKey('items') ? page['items'] : page['songs']);
    final rawCount = page.containsKey('rawCount') ? intOf(page['rawCount']) : items.length;
    final total = page.containsKey('total') ? intOf(page['total']) : items.length;
    return (
      items: items,
      rawCount: rawCount,
      total: total,
      more: boolOf(page['more']),
      incomplete: boolOf(page['incomplete']),
      notice: textOf(page['notice']),
    );
  }

  /// Qt MusicLibrary::refreshPersonal（591-614）。
  Future<void> refreshPersonal(int lane) async {
    // Qt 592：个人库只对 QQ 渠道开放；原稿 `!isKugou` 与上游判据相反。
    if (provider != 'qq' || uid.isEmpty || lane < 1 || lane > 4) {
      return;
    }
    if (personalLoading || writeLoading || accountLoading) {
      return;
    }
    await host.invalidateMetadata();
    lists[lane] = <JsonMap>[];
    totals[lane] = 0;
    hasMore[lane] = true;
    if (lane == 1) {
      likedCursor = 0;
      likedIds = null;
    } else if (lane == 4) {
      albumCursor = 0;
    } else {
      // Qt 608-612：2/3 两栏共用一次刷新，两个列表都要清。
      lists[2] = <JsonMap>[];
      lists[3] = <JsonMap>[];
      playlistCursor = 0;
    }
    await loadMoreSource(lane);
  }

  /// Qt MusicLibrary::loadLikedIDs（699-736）。
  Future<void> loadLikedIDs() async {
    final token = accountGeneration;
    final user = uid;
    final ids = likedIds;
    if (ids == null) {
      final reply = await api.call('likedIDs', <Object?>[user]);
      if (token != accountGeneration || uid != user) {
        return;
      }
      if (!reply.ok) {
        completePersonal(1, reply.error ?? '');
        return;
      }
      final list = stringsOf(reply.value);
      likedIds = list;
      likedCursor = 0;
      await loadLikedIDs();
      return;
    }
    final chunk = sliceStrings(ids, likedCursor, 100);
    if (chunk.isEmpty) {
      likedCursor = ids.length;
      totals[1] = ids.length;
      hasMore[1] = false;
      completePersonal(1, '');
      return;
    }
    final reply = await api.call('songs', <Object?>[chunk]);
    if (token != accountGeneration || uid != user) {
      return;
    }
    if (!reply.ok) {
      completePersonal(1, reply.error ?? '');
      return;
    }
    likedIds = ids;
    likedCursor += chunk.length;
    lists[1] = uniqueItems(lists[1], orderedItems(chunk, mapsOf(reply.value)));
    totals[1] = ids.length;
    hasMore[1] = likedCursor < ids.length;
    completePersonal(1, '');
  }

  /// Qt MusicLibrary::completePersonal（671-697）。
  void completePersonal(int lane, String error) {
    personalLoading = false;
    if (lane >= 0 && lane < sourceErrors.length) {
      sourceErrors[lane] = error;
    }
    if (lane == 2 || lane == 3) {
      sourceErrors[2] = error;
      sourceErrors[3] = error;
    }
    status = error.isEmpty ? '已读取个人音乐' : error;
    if (error.isEmpty && current.isEmpty) {
      final related = selectedLane == lane ||
          ((lane == 2 || lane == 3) && (selectedLane == 2 || selectedLane == 3));
      if (related) {
        // Qt 682：缺省用 selectedLane 的槽位；负数原样交给 observe，不再夹取。
        selectedPhysical = -1;
        unawaited(observe(_jsonToInt(frame['selected'], slotValue(physicalSlots[selectedLane], 0, -1))));
      }
    }
    final pending = _pendingLane;
    _pendingLane = -1;
    final mirrored = (pending == 2 || pending == 3) && (lane == 2 || lane == 3);
    if (pending > 0 && pending != lane && !mirrored && lists[pending].isEmpty) {
      unawaited(loadMoreSource(pending));
    }
    if (lane == 1 && _playLiked) {
      _playLiked = false;
      if (error.isEmpty && selectedLane == 1 && directory == null) {
        playDirectory();
      }
    }
    changed();
  }

  /// Qt MusicLibrary::loadMoreSource（738-854）。
  Future<void> loadMoreSource(int lane) async {
    if (isLocal || lane < 0 || lane >= columns.length) {
      return;
    }
    if (isSiren) {
      if (lane == 0) {
        await librarySearch(this, keyword, more: true);
      } else {
        await librarySirenLoadSource(this, lane);
      }
      return;
    }
    if (isKugou && lane == 4) {
      hasMore[4] = false;
      status = '酷狗 API 未提供收藏专辑，此栏目已禁用';
      changed();
      return;
    }
    if (lane > 0 && (restoringAccount || personalLoading)) {
      _pendingLane = lane;
      changed();
      return;
    }
    if (!hasMore[lane]) {
      return;
    }
    if (lane == 0) {
      await librarySearch(this, keyword, more: true);
      return;
    }
    if (mAccountError.isNotEmpty && host.authenticated) {
      _pendingLane = lane;
      await restoreAccount();
      return;
    }
    if (uid.isEmpty) {
      status = '请登录' + providerName();
      changed();
      return;
    }
    personalLoading = true;
    if (lane < sourceErrors.length) {
      sourceErrors[lane] = '';
    }
    final token = accountGeneration;
    final user = uid;
    changed();
    if (lane == 1 && provider == 'netease') {
      await loadLikedIDs();
      return;
    }
    final operation = lane == 1 ? 'likedSongs' : (lane == 4 ? 'likedAlbums' : 'userPlaylists');
    final arguments = lane == 1
        ? <Object?>[likedCursor]
        : lane == 4
            ? <Object?>[albumCursor]
            : <Object?>[user];
    final reply = await api.call(operation, arguments);
    if (token != accountGeneration || uid != user) {
      return;
    }
    if (!reply.ok) {
      completePersonal(lane, reply.error ?? '');
      return;
    }
    final page = pageOf(reply.value);
    final raw = page.items;
    if (lane == 1) {
      likedCursor += page.rawCount;
      lists[1] = uniqueItems(lists[1], raw);
      likedIds = <String>[for (final value in lists[1]) textOf(value['id'])];
      totals[1] = page.total;
      hasMore[1] = page.more;
    } else if (lane == 4) {
      albumCursor += page.rawCount;
      lists[4] = uniqueItems(lists[4], raw);
      totals[4] = page.total > lists[4].length ? page.total : lists[4].length;
      hasMore[4] = page.more;
    } else {
      playlistCursor += page.rawCount;
      final owned = <JsonMap>[];
      final collected = <JsonMap>[];
      for (final value in raw) {
        final creator = textOf(value['creatorID']);
        if (creator == user) {
          owned.add(value);
        } else {
          collected.add(value);
        }
      }
      lists[2] = uniqueItems(lists[2], owned);
      lists[3] = uniqueItems(lists[3], collected);
      totals[2] = lists[2].length;
      totals[3] = lists[3].length;
      hasMore[2] = page.more;
      hasMore[3] = page.more;
    }
    completePersonal(lane, '');
    if (page.incomplete) {
      status = '已读取部分歌单，上游未提供可靠的后续页，请稍后刷新';
      changed();
    }
  }

  /// Qt MusicLibrary::selectResult（616-644）。
  Future<void> selectResult(int index, [int? lane, String mode = 'open']) async {
    final targetLane = lane ?? selectedLane;
    if (targetLane < 0 || targetLane >= columns.length) {
      return;
    }
    final values = lists[targetLane];
    if (index < 0 || index >= values.length) {
      return;
    }
    if (directory != null) {
      await leaveDirectory(restore: false);
    }
    var viewIndex = index;
    if (groupLane == targetLane) {
      final position = groupIndices.indexOf(index);
      if (position >= 0) {
        viewIndex = position;
      } else {
        groupLane = -1;
        viewIndex = index;
      }
    }
    offsets[targetLane] = (viewIndex ~/ 8) * 8;
    selectedPhysical = -1;
    playContext = sourceItems(targetLane);
    final physical = slotValue(physicalSlots[targetLane], viewIndex % 8, -1);
    selectionRequests.add((index: physical, navigation: const <String, Object?>{}));
    final nextMode = mode == 'open' && itemKindOf(values[index]) == 'song' ? 'detail' : 'archive';
    modeRequests.add(nextMode);
    frame['mode'] = nextMode;
    await observe(physical);
    if (mode == 'open' && itemKindOf(current) != 'song') {
      await enterDirectory(current);
    }
  }

  /// Qt MusicLibrary::next（646-668）。
  Future<void> next(int direction) async {
    final folder = directory;
    if (folder != null) {
      await navigateDirectory(direction, 'row');
      return;
    }
    final slots = physicalSlots[selectedLane];
    final row = slots.indexOf(selectedPhysical);
    final values = sourceItems();
    if (row < 0 || values.isEmpty) {
      return;
    }
    final absolute = wrapIndex(offsets[selectedLane] + row, values.length);
    final raw = absolute + direction;
    if (raw >= values.length && hasMore[selectedLane] && groupLane != selectedLane) {
      // Qt 658-661：补页后立即返回，不能再用旧 values 推进一步。
      unawaited(loadMoreSource(selectedLane));
      return;
    }
    final nextValue = wrapIndex(raw, values.length);
    final target = wrapIndex(row + direction, 8);
    offsets[selectedLane] = nextValue - target;
    navigationRequests.add(LibraryNavigation('row', direction));
    selectedPhysical = -1;
    changed();
  }

  // ── 写操作（Qt MusicMutation.cpp 全文） ──────────────────────────────
  static List<JsonMap> without(List<JsonMap> values, String field, String key) {
    final result = <JsonMap>[];
    for (final value in values) {
      final currentValue = field.isEmpty ? itemKeyOf(value) : textOf(value[field]);
      if (currentValue != key) {
        result.add(value);
      }
    }
    return result;
  }

  static const Map<String, List<String>> _qqMutations = <String, List<String>>{
    '/like': <String>['mutations', 'likeSong'],
    '/album/sub': <String>['mutations', 'subscribeAlbum'],
    '/playlist/subscribe': <String>['mutations', 'subscribePlaylist'],
    '/playlist/tracks': <String>['mutations', 'updatePlaylistTracks'],
    '/playlist/create': <String>['playlistManagement', 'createPlaylist'],
    '/playlist/name/update': <String>['playlistManagement', 'renamePlaylist'],
    '/playlist/delete': <String>['playlistManagement', 'deletePlaylist'],
  };

  static const Set<String> _sirenMutations = <String>{
    '/like',
    '/playlist/create',
    '/playlist/name/update',
    '/playlist/delete',
    '/playlist/tracks',
  };

  /// Qt MusicMutation::canMutate。
  bool canMutate(String route) {
    if (isSiren) {
      return _sirenMutations.contains(route);
    }
    if (provider == 'netease') {
      return true;
    }
    if (provider != 'qq') {
      return false;
    }
    final keys = _qqMutations[route];
    if (keys == null) {
      return false;
    }
    // Qt MusicMutation.cpp:44：capabilities 为空表示上游没有下发声明，按放行处理。
    return capabilities.isEmpty || boolOf(mapOf(capabilities[keys[0]])[keys[1]]);
  }

  /// Qt MusicMutation::canEditPlaylist。
  bool canEditPlaylist(JsonMap item) {
    if (isSiren) {
      final creator = collections?.creatorId ?? '';
      return collections != null && itemKindOf(item) == 'playlist' && textOf(item['creatorID']) == creator;
    }
    if (boolOf(item['special'])) {
      return false;
    }
    if (!editable || uid.isEmpty || itemKindOf(item) != 'playlist' || textOf(item['creatorID']) != uid) {
      return false;
    }
    if (provider != 'qq') {
      return true;
    }
    final owned = boolOf(item['owned']);
    // Qt 62-64 `value["dirId"].toString().toInt(&parsed)`：字符串数字也算解析成功。
    final rawDirId = item['dirId'];
    final dirId = rawDirId is String ? int.tryParse(rawDirId) : intOf(rawDirId);
    return owned && dirId != null && dirId >= 1 && dirId <= 199;
  }

  /// Qt MusicMutation::loadSubscriptionStatus。
  Future<void> loadSubscriptionStatus() async {
    if (provider != 'qq' || uid.isEmpty) {
      return;
    }
    if (boolOf(current['virtual'])) {
      return;
    }
    final kind = itemKindOf(current);
    if (kind != 'song' && kind != 'album' && kind != 'playlist') {
      return;
    }
    final token = ++subscriptionGeneration;
    final key = itemKeyOf(current);
    final Object? id = current['id'];
    // Qt MusicMutation.cpp:76-87：账号代数与选中 token 双重 valid；key 在回调里
    // 只用于丢弃选中已变化的响应（Qt 不额外要求 key/id 非空）。
    final accountToken = accountGeneration;
    final reply = await api.call(
      'subscriptionStatus',
      <Object?>[kind, id],
      valid: () => accountToken == accountGeneration && token == subscriptionGeneration,
    );
    if (accountToken != accountGeneration || token != subscriptionGeneration || itemKeyOf(current) != key) {
      return;
    }
    // Qt MusicMutation.cpp:84 result.value.toString("unknown")：只有非字符串才回落，
    // 空字符串是合法结果，不能折叠成 unknown。
    subscriptionStates[key] = reply.ok
        ? (reply.value is String ? reply.value! as String : 'unknown')
        : 'unknown';
    changed();
  }

  /// Qt MusicMutation::resetLikeState。
  void resetLikeState() {
    writeLoading = false;
    ++playbackLikeGeneration;
    playbackLikeContext = '';
    likedIds = null;
    lists[1] = <JsonMap>[];
    totals[1] = 0;
    likedCursor = 0;
    hasMore[1] = true;
    subscriptionStates.clear();
  }

  /// Qt MusicMutation::songLiked：true/false/null 三态。
  bool? songLiked([JsonMap? value]) {
    final item = value ?? current;
    if (itemKindOf(item) != 'song') {
      return null;
    }
    final itemProvider = textOf(item['provider']).isEmpty ? provider : textOf(item['provider']);
    if (itemProvider != provider) {
      return null;
    }
    if (isSiren) {
      final ids = likedIds;
      if (ids == null) {
        return null;
      }
      return ids.contains(textOf(item['id']));
    }
    if (uid.isEmpty || !canMutate('/like')) {
      return null;
    }
    if (provider == 'qq') {
      final state = subscriptionStates[itemKeyOf(item)] ?? '';
      if (state == 'subscribed') {
        return true;
      }
      if (state == 'not-subscribed') {
        return false;
      }
    } else {
      final ids = likedIds;
      if (ids != null) {
        return ids.contains(textOf(item['id']));
      }
    }
    if (indexOfId(lists[1], textOf(item['id'])) >= 0) {
      return true;
    }
    return null;
  }

  /// Qt MusicMutation::refreshPlaybackLike。
  void refreshPlaybackLike() {
    if (isSiren) {
      return;
    }
    final track = player.current;
    if (writeLoading || uid.isEmpty) {
      return;
    }
    if (itemKindOf(track) != 'song') {
      return;
    }
    final trackProvider = textOf(track['provider']).isEmpty ? provider : textOf(track['provider']);
    if (trackProvider != provider) {
      return;
    }
    if (!canMutate('/like')) {
      return;
    }
    final qq = provider == 'qq';
    final context = provider + ':' + uid + ':' + accountGeneration.toString() + ':' +
        (qq ? itemKeyOf(track) : 'likedIDs');
    // Qt MusicMutation.cpp:140：songLiked(track) 已有确定答案（含 lists[1] 命中）就不再读。
    if (songLiked(track) != null) {
      return;
    }
    if (playbackLikeContext == context) {
      return;
    }
    playbackLikeContext = context;
    final token = ++playbackLikeGeneration;
    final accountToken = accountGeneration;
    final key = itemKeyOf(track);
    final id = textOf(track['id']);
    unawaited(() async {
      final reply = qq
          ? await api.call(
              'subscriptionStatus',
              <Object?>['song', id],
              valid: () => accountToken == accountGeneration && token == playbackLikeGeneration,
            )
          : await api.call(
              'likedIDs',
              <Object?>[uid],
              valid: () => accountToken == accountGeneration && token == playbackLikeGeneration,
            );
      if (accountToken != accountGeneration || token != playbackLikeGeneration || !reply.ok) {
        return;
      }
      if (qq) {
        subscriptionStates[key] =
            reply.value is String ? reply.value! as String : 'unknown';
      } else {
        final ids = stringsOf(reply.value);
        if (reply.value is List) {
          likedIds = ids;
        }
      }
      changed();
    }());
  }

  /// Qt MusicMutation::isSubscribed。
  bool isSubscribed(JsonMap item) {
    final key = itemKeyOf(item);
    if (key.isEmpty) {
      return false;
    }
    if (subscriptions.contains(key)) {
      return true;
    }
    final kind = itemKindOf(item);
    if (kind != 'playlist' && kind != 'album') {
      return false;
    }
    final lane = kind == 'album' ? 4 : 3;
    for (final value in lists[lane]) {
      if (itemKeyOf(value) == key) {
        return true;
      }
    }
    return false;
  }

  /// Qt MusicMutation::mutate。返回 done(ok) 的 ok。
  Future<bool> mutate(
    String route,
    JsonMap values, {
    void Function(JsonMap body)? success,
  }) async {
    if (isSiren && route == '/playlist/delete') {
      final source = collections;
      final id = textOf(values['id']);
      final ok = source != null && source.deletePlaylist(id);
      if (ok) {
        lists[2] = source!.playlists();
        totals[2] = lists[2].length;
        status = '已删除歌单';
        // Qt 237-239：本地删除成功也要回传 {id}，上层据此收束目录。
        success?.call(<String, Object?>{'id': id});
      } else {
        status = '无法删除歌单';
      }
      changed();
      return ok;
    }
    if (!canMutate(route) || writeLoading || uid.isEmpty) {
      if (!editable) {
        status = providerName() + '当前支持读取与播放';
      } else if (uid.isEmpty) {
        status = '请先登录' + providerName();
      } else if (!canMutate(route)) {
        // Qt 195-198：writeLoading 占用时不改 status，只有路由确实不可写才提示。
        status = '当前 QQ 服务未开放此编辑功能';
      }
      changed();
      return false;
    }
    writeLoading = true;
    ++playbackLikeGeneration;
    playbackLikeContext = '';
    if (provider == 'qq') {
      ++subscriptionGeneration;
    }
    changed();
    // Qt MusicMutation.cpp:240-245：写入携带账号代数 valid；换号后旧回调整段不执行。
    final accountToken = accountGeneration;
    final reply = provider == 'qq'
        ? await api.call(
            'mutate',
            <Object?>[route, values],
            valid: () => accountToken == accountGeneration,
          )
        : await api.request(
            route,
            values,
            valid: () => accountToken == accountGeneration,
          );
    if (isStale(reply) || accountToken != accountGeneration) {
      // 对应 Qt 回调未执行：不改 status/success/元数据，writeLoading 保持占用。
      return false;
    }
    var ok = reply.ok;
    final body = mapOf(reply.value);
    if (provider == 'qq') {
      ++subscriptionGeneration;
    }
    // Qt 216：嵌套码必须从 body["body"].code 读；顶层 code 是传输层结果码。
    final nested = _jsonToInt(mapOf(body['body'])['code'], 200);
    if (ok && nested != 200) {
      // Qt 217-220：嵌套失败不改写本地集合，也不失效元数据。
      ok = false;
      status = providerName() + '返回 ' + nested.toString();
    } else if (ok) {
      await host.invalidateMetadata();
      success?.call(body);
      status = '已同步至' + providerName();
    } else {
      status = reply.error ?? '';
      if (provider == 'qq') {
        subscriptionStates.clear();
        await host.invalidateMetadata();
      }
    }
    writeLoading = false;
    changed();
    return ok;
  }

  /// Qt MusicMutation::like(input)：按本地已知状态取反后写回。
  Future<void> like(JsonMap value) async {
    // Qt 249-251：空对象回落到当前条目。
    final item = value.isEmpty ? current : value;
    if (itemKindOf(item) != 'song') {
      return;
    }
    final id = textOf(item['id']);
    if (isSiren) {
      final source = collections;
      if (source == null) {
        return;
      }
      final enabled = !source.isLiked(id);
      if (!source.setLiked(id, enabled)) {
        status = '无法写入本地收藏';
        changed();
        return;
      }
      final ids = source.likedIds();
      likedIds = ids;
      if (enabled) {
        lists[1] = uniqueItems(<JsonMap>[item], lists[1]);
        likedCursor = likedCursor + 1 > ids.length ? ids.length : likedCursor + 1;
      } else {
        final index = indexOfId(lists[1], id);
        lists[1] = without(lists[1], 'id', id);
        if (index >= 0 && index < likedCursor) {
          --likedCursor;
        }
      }
      totals[1] = ids.length;
      hasMore[1] = likedCursor < totals[1];
      status = enabled ? '已加入喜欢的歌曲' : '已从喜欢的歌曲移除';
      changed();
      return;
    }
    if (uid.isEmpty) {
      status = '请先登录' + providerName();
      changed();
      return;
    }
    // Qt 290-316 的 update(enabled)：qq 与 netease 共用同一份本地集合维护。
    void update(bool enabled) {
      if (provider == 'qq') {
        subscriptionStates[itemKeyOf(item)] = enabled ? 'subscribed' : 'not-subscribed';
      }
      final existed = indexOfId(lists[1], id) >= 0;
      if (!enabled) {
        lists[1] = without(lists[1], 'id', id);
        final known = likedIds;
        if (known != null) {
          likedIds = <String>[for (final entry in known) if (entry != id) entry];
        }
      } else {
        lists[1] = uniqueItems(lists[1], <JsonMap>[item]);
        final known = likedIds;
        if (known != null && !known.contains(id)) {
          likedIds = <String>[...known, id];
        }
      }
      if (provider == 'qq') {
        // Qt 311-314：qq 用 adjustment 维护 totals，并把 likedCursor 拉到列表末尾。
        final adjustment = enabled ? (existed ? 0 : 1) : -1;
        final adjusted = totals[1] + adjustment;
        totals[1] = lists[1].length > adjusted ? lists[1].length : adjusted;
        likedCursor = lists[1].length;
      } else {
        totals[1] = likedIds != null ? likedIds!.length : lists[1].length;
      }
    }

    if (provider == 'qq') {
      await mutate('/like', <String, Object?>{'id': id}, success: (JsonMap body) {
        // Qt 317-321：qq 用上游回执的 liked，其余渠道用本地取反值。
        update(boolOf(body['liked']));
      });
      return;
    }
    var ids = likedIds;
    if (ids == null) {
      final reply = await api.call('likedIDs', <Object?>[uid]);
      if (!reply.ok) {
        status = reply.error ?? '';
        changed();
        return;
      }
      ids = stringsOf(reply.value);
      likedIds = ids;
    }
    final liked = ids.contains(id) || indexOfId(lists[1], id) >= 0;
    await mutate('/like', <String, Object?>{'id': id, 'like': !liked}, success: (JsonMap body) {
      // Qt 337-340：非 qq 忽略回执，按取反后的本地状态维护。
      update(!liked);
    });
  }

  /// Qt MusicMutation::subscribe(input)：按当前收藏状态取反。
  Future<void> subscribe(JsonMap value) async {
    final item = value;
    final subscribed = isSubscribed(item);
    final kind = itemKindOf(item);
    if (kind != 'album' && kind != 'playlist' && kind != 'artist') {
      return;
    }
    if (provider == 'qq' && kind == 'artist') {
      status = 'QQ 上游尚未提供收藏歌手写入';
      changed();
      return;
    }
    if (boolOf(item['special'])) {
      status = '“我喜欢的音乐”不支持收藏操作';
      changed();
      return;
    }
    final lane = kind == 'album' ? 4 : 3;
    final route = kind == 'playlist' ? '/playlist/subscribe' : '/' + kind + '/sub';
    final id = textOf(item['id']);
    await mutate(route, <String, Object?>{'id': id, 't': subscribed ? 2 : 1}, success: (JsonMap body) {
      final enabled = provider == 'qq' ? boolOf(body['subscribed']) : !subscribed;
      final key = itemKeyOf(item);
      if (provider == 'qq') {
        subscriptionStates[key] = enabled ? 'subscribed' : 'not-subscribed';
      }
      if (enabled) {
        if (!subscriptions.contains(key)) {
          subscriptions.add(key);
        }
      } else {
        subscriptions.remove(key);
      }
      if (kind != 'artist') {
        if (enabled) {
          // Qt MusicData::unique(lists[lane], {value})：旧在前、新项追加。
          lists[lane] = uniqueItems(lists[lane], <JsonMap>[item]);
        } else {
          lists[lane] = without(lists[lane], 'key', key);
        }
      }
      if (kind != 'artist') {
        totals[lane] = lists[lane].length;
      }
    });
  }

  /// Qt MusicMutation::playlistForm。
  Future<bool> playlistForm(String kind, String name, [String id = '']) async {
    final trimmed = name.trim();
    final maximum = provider == 'qq' ? 20 : 100;
    // Qt 413 `name.toUcs4().size()`：按码点计数，代理对只算一个字。
    if (trimmed.isEmpty || trimmed.runes.length > maximum) {
      status = '请输入 1–' + maximum.toString() + ' 字歌单名称';
      changed();
      return false;
    }
    final source = collections;
    if (isSiren) {
      // Qt 421-427：塞壬分支没有 collections 只能失败，不能落入网络路由。
      if (source == null) {
        return false;
      }
      if (kind == 'create') {
        final created = source.createPlaylist(trimmed);
        if (created.isEmpty) {
          status = '无法创建歌单，请检查名称或数量上限';
          changed();
          return false;
        }
        lists[2] = source.playlists();
        totals[2] = lists[2].length;
        status = '已创建歌单：' + trimmed;
        changed();
        return true;
      }
      final renamed = source.renamePlaylist(id, trimmed);
      if (!renamed) {
        status = '无法重命名歌单';
        changed();
        return false;
      }
      lists[2] = source.playlists();
      totals[2] = lists[2].length;
      final folder = directory;
      if (folder != null && textOf(folder.item['id']) == id) {
        folder.item['title'] = trimmed;
      }
      status = '已重命名歌单';
      changed();
      return true;
    }
    if (kind != 'create') {
      // Qt 457-458：目录歌单还要求 creatorID==uid，才是自己创建、可改名的。
      final ownedByFolder = directory != null &&
          textOf(directory!.item['id']) == id &&
          textOf(directory!.item['creatorID']) == uid;
      if (indexOfId(lists[2], id) < 0 && !ownedByFolder) {
        status = '只能编辑自己创建的歌单';
        changed();
        return false;
      }
    }
    final route = kind == 'create' ? '/playlist/create' : '/playlist/name/update';
    final values = kind == 'create'
        ? <String, Object?>{'name': trimmed}
        : <String, Object?>{'id': id, 'name': trimmed};
    final ok = await mutate(route, values, success: (JsonMap body) {
      if (kind == 'create') {
        // Qt 470-476：只认 body["playlist"] 对象；QQ 原样收下，其它渠道走 parse；
        // 解析为空时不动 lists[2]，新项追加在尾部（unique(existing, {value})）。
        final playlist = mapOf(body['playlist']);
        if (playlist.isNotEmpty) {
          final created = provider == 'qq' ? playlist : musicItemParse(playlist, 'playlist');
          if (created.isNotEmpty) {
            lists[2] = uniqueItems(lists[2], <JsonMap>[<String, Object?>{...created, 'creatorID': uid}]);
          }
        }
      } else {
        // Qt 478-489：verifiedName = body["name"].toString(name)，只覆盖 title。
        final rawName = body['name'];
        final updated = rawName is String ? rawName : trimmed;
        for (var index = 0; index < lists[2].length; index++) {
          if (textOf(lists[2][index]['id']) == id) {
            lists[2][index] = <String, Object?>{...lists[2][index], 'title': updated};
          }
        }
        final folder = directory;
        if (folder != null && textOf(folder.item['id']) == id) {
          folder.item['title'] = updated;
        }
      }
      totals[2] = lists[2].length;
    });
    return ok;
  }

  /// Qt MusicMutation::playlistTrack。
  Future<bool> playlistTrack(String id, JsonMap value, bool remove) async {
    // Qt 497-499：空对象回落到当前条目。
    final song = value.isEmpty ? current : value;
    if (itemKindOf(song) != 'song') {
      return false;
    }
    final songId = textOf(song['id']);
    final source = collections;
    if (isSiren) {
      if (source == null) {
        return false;
      }
      final existed = source.tracks(id).contains(songId);
      final ok = remove ? source.removeTrack(id, songId) : source.addTrack(id, songId);
      if (!ok) {
        status = '无法写入本地歌单';
        changed();
        return false;
      }
      final updated = source.playlist(id);
      if (updated.isNotEmpty) {
        for (var index = 0; index < lists[2].length; index++) {
          if (textOf(lists[2][index]['id']) == id) {
            lists[2][index] = <String, Object?>{...updated, 'cover': lists[2][index]['cover']};
          }
        }
        totals[2] = lists[2].length;
      }
      await _syncDirectoryTracks(id, song, remove, existed, siren: true);
      status = remove ? '已从歌单移除' : '已加入歌单';
      changed();
      return true;
    }
    // Qt 570-576：目录歌单必须有 creatorID==uid 才允许编辑。
    final ownedByFolder = directory != null &&
        textOf(directory!.item['id']) == id &&
        textOf(directory!.item['creatorID']) == uid;
    if (indexOfId(lists[2], id) < 0 && !ownedByFolder) {
      status = '请选择自己创建的歌单';
      changed();
      return false;
    }
    final ok = await mutate('/playlist/tracks', <String, Object?>{
      'pid': id,
      'tracks': songId,
      'op': remove ? 'del' : 'add',
    });
    if (ok) {
      // Qt 581-601：远程回调里重新计算 contained，只有 QQ 新增才涨 trackCount。
      await _syncDirectoryTracks(id, song, remove, false, siren: false);
    }
    return ok;
  }

  /// Qt MusicMutation::playlistTrack 的目录同步（539-562 / 581-601）。
  Future<void> _syncDirectoryTracks(
    String id,
    JsonMap value,
    bool remove,
    bool existed, {
    required bool siren,
  }) async {
    final folder = directory;
    if (folder == null || textOf(folder.item['id']) != id) {
      return;
    }
    // Qt 539：塞壬只在成员真的发生变化时同步；远程回调没有这条守卫。
    if (siren && (remove ? !existed : existed)) {
      return;
    }
    // Qt MusicMutation.cpp:546-558：ids 用原始 QJsonValue 做类型敏感比较与插入；
    // songs 侧仍是 MusicData::indexOfId（id.toString()）的字符串比较。
    final Object? songId = value['id'];
    final contained = indexOfId(folder.songs, textOf(songId)) >= 0;
    // 两路顺序不同：塞壬新项在前（unique({value}, songs)），远程追加在尾部
    // （unique(songs, {value})）。
    final songs = remove
        ? without(folder.songs, 'id', textOf(songId))
        : (siren ? uniqueItems(<JsonMap>[value], folder.songs) : uniqueItems(folder.songs, <JsonMap>[value]));
    folder.updateSongs(songs, folder.sortField);
    if (remove) {
      // Qt MusicMutation.cpp:546-550：ids 里的旧下标必须在删除前算。
      final old = indexOfJsonValue(folder.ids, songId);
      if (old >= 0 && old < folder.cursor) {
        --folder.cursor;
      }
      final kept = <Object?>[];
      for (final entry in folder.ids) {
        if (!sameJsonValue(entry, songId)) {
          kept.add(entry);
        }
      }
      folder.ids = kept;
      folder.item['trackCount'] = intOf(folder.item['trackCount']) > 0 ? intOf(folder.item['trackCount']) - 1 : 0;
      final last = folder.songs.isEmpty ? 0 : folder.songs.length - 1;
      folder.index = folder.index < last ? folder.index : last;
    } else if (siren) {
      if (!contained) {
        folder.item['trackCount'] = intOf(folder.item['trackCount']) + 1;
      }
      if (indexOfJsonValue(folder.ids, songId) < 0) {
        folder.ids = <Object?>[songId, ...folder.ids];
        ++folder.cursor;
      }
    } else if (provider == 'qq' && !contained) {
      folder.item['trackCount'] = intOf(folder.item['trackCount']) + 1;
    }
    changed();
  }

  // ── 会话快照（Qt MusicSession.cpp 全文） ─────────────────────────────
  JsonMap sessionState() {
    final sources = <JsonMap>[];
    for (var lane = 0; lane < 5; lane++) {
      sources.add(<String, Object?>{
        'items': lists[lane],
        'total': totals[lane],
        'offset': offsets[lane],
        'more': hasMore[lane],
        'row': rowMemory[lane],
      });
    }
    final directories = <JsonMap>[];
    DirectoryFolder? cursor = directory;
    while (cursor != null && directories.length < _maxSeedFolders) {
      directories.insert(0, cursor.toJson());
      cursor = cursor.parent;
    }
    final saved = <String, Object?>{
      'provider': provider,
      'edition': kugouEdition,
      'uid': uid,
      'sources': sources,
      'directories': directories,
      'current': current,
      'selectedPhysical': selectedPhysical,
      'selectedLane': selectedLane,
      'keyword': keyword,
      'searchKind': searchKind,
      'status': status,
      'searchLoading': searchLoading,
      'directoryLoading': directoryLoading,
      'detailLoading': detailLoading,
      'privateSelection': privateSelection,
      'searchCursor': searchCursor,
      'playlistCursor': playlistCursor,
      'albumCursor': albumCursor,
      'likedCursor': likedCursor,
      'groupName': groupName,
      'groupIndices': groupIndices,
      'groupLane': groupLane,
      'tracks': tracks,
      'trackIDs': trackIds,
      'trackCursor': trackCursor,
      'albumLoaded': albumLoaded,
      'playContext': playContext,
      'directoryInfo': directoryInfo,
      'wantsSongDetails': wantsSongDetails,
      'discover': discover.toJson(),
    };
    final ids = likedIds;
    if (ids != null) {
      saved['likedIDs'] = ids;
    }
    return saved;
  }

  bool restoreSessionState(JsonMap saved) {
    if (saved.isEmpty) {
      return false;
    }
    if (textOf(saved['provider']) != provider) {
      return false;
    }
    if (textOf(saved['edition']) != kugouEdition) {
      return false;
    }
    if (textOf(saved['uid']) != uid) {
      return false;
    }
    // Qt MusicSession.cpp:97-109：先校验 selectedLane/selectedPhysical（physical 必须是该栏位
    // 真实存在的物理格），再校验 sources 长度与目录栈深度，任一不符整份放弃。
    final sources = mapsOf(saved['sources']);
    final lanes = intOf(saved['selectedLane']);
    final physical = intOf(saved['selectedPhysical']);
    if (sources.length != 5 ||
        lanes < 0 ||
        lanes > 4 ||
        physical < -1 ||
        physical >= _physicalCount ||
        (physical >= 0 && !physicalSlots[lanes].contains(physical))) {
      return false;
    }
    final folders = mapsOf(saved['directories']);
    if (folders.length > _maxSeedFolders) {
      return false;
    }
    ++selectionGeneration;
    ++directoryGeneration;
    ++wikiGeneration;
    for (var lane = 0; lane < 5; lane++) {
      final items = mapsOf(sources[lane]['items']);
      lists[lane] = items;
      final total = intOf(sources[lane]['total']);
      final effective = total < 0 ? 0 : total;
      totals[lane] = items.length > effective ? items.length : effective;
      offsets[lane] = _clampInt(intOf(sources[lane]['offset']), 0, items.isEmpty ? 0 : items.length - 1);
      rowMemory[lane] = _clampInt(intOf(sources[lane]['row']), 0, 7);
      hasMore[lane] = boolOf(sources[lane]['more']);
    }
    // Qt 在解析目录栈之前就推进了世代（同上），此处不再重复 ++。
    DirectoryFolder? built;
    for (final entry in folders) {
      final sortField = textOf(entry['sortField']);
      const List<String> fields = <String>['title', 'album', 'artist', 'none'];
      final folder = DirectoryFolder(
        parent: built,
        item: mapOf(entry['item']),
        songs: mapsOf(entry['songs']),
        sortField: fields.contains(sortField) ? sortField : 'none',
        ids: trackIdValuesOf(entry['ids']),
        albums: mapsOf(entry['albums']),
      );
      folder.cursor = _clampInt(intOf(entry['cursor']), 0, folder.ids.length);
      folder.index = _clampInt(intOf(entry['index']), 0, folder.songs.isEmpty ? 0 : folder.songs.length - 1);
      folder.anchor = _clampInt(intOf(entry['anchor']), 0, _physicalCount - 1);
      folder.page = (folder.index ~/ _physicalCount) * _physicalCount;
      folder.parentPhysical = _clampInt(intOf(entry['parentPhysical']), 0, _physicalCount - 1);
      folder.parentLane = _clampInt(intOf(entry['parentLane']), 0, 4);
      folder.parentItem = mapOf(entry['parentItem']);
      folder.albumCursor = _nonnegative(intOf(entry['albumCursor']));
      folder.albumsMore = boolOf(entry['albumsMore']);
      built = folder;
    }
    directory = built;
    selectedLane = lanes;
    selectedPhysical = physical;
    keyword = textOf(saved['keyword']);
    // Qt MusicSession.cpp:141：toString("song") 只在缺键/非字符串时回落，
    // 显式空串保持空串。
    searchKind = saved['searchKind'] is String ? saved['searchKind']! as String : 'song';
    status = textOf(saved['status']);
    searchCursor = _nonnegative(intOf(saved['searchCursor']));
    playlistCursor = _nonnegative(intOf(saved['playlistCursor']));
    albumCursor = _nonnegative(intOf(saved['albumCursor']));
    likedCursor = _nonnegative(intOf(saved['likedCursor']));
    final ids = saved['likedIDs'];
    likedIds = ids is List ? stringsOf(ids) : null;
    groupName = textOf(saved['groupName']);
    groupIndices = <int>[
      for (final value in (saved['groupIndices'] is List ? saved['groupIndices']! as List : const <Object?>[]))
        _nonnegative(intOf(value)),
    ];
    // Qt MusicSession.cpp:150：toInt(-1) 只在缺键/非数值时取 -1，显式 0 保留。
    groupLane = _clampInt(saved['groupLane'] is num ? intOf(saved['groupLane']) : -1, -1, 4);
    current = mapOf(saved['current']);
    tracks = mapsOf(saved['tracks']);
    // Qt MusicSession.cpp:157 `trackIDs = saved["trackIDs"].toArray()`：原样恢复，
    // 数值 id 不能再被 stringsOf 丢掉。
    trackIds = trackIdValuesOf(saved['trackIDs']);
    trackCursor = _nonnegative(intOf(saved['trackCursor']));
    albumLoaded = boolOf(saved['albumLoaded']);
    playContext = mapsOf(saved['playContext']);
    privateSelection = boolOf(saved['privateSelection']);
    directoryInfo = boolOf(saved['directoryInfo']);
    wantsSongDetails = boolOf(saved['wantsSongDetails']);
    final resumeSearch = boolOf(saved['searchLoading']);
    final resumeDirectory = boolOf(saved['directoryLoading']);
    final resumeDetail = boolOf(saved['detailLoading']);
    searchLoading = false;
    detailLoading = false;
    directoryLoading = false;
    trackLoad = false;
    discover.restore(mapOf(saved['discover']));
    coverImage = '';
    coverKey = '';
    identityRequests.add(itemKeyOf(current));
    unawaited(loadCover(current));
    changed();
    if (resumeSearch && keyword.isNotEmpty) {
      unawaited(librarySearch(this, keyword, kind: searchKind, more: lists[0].isNotEmpty));
    } else if (resumeDirectory && directory != null && directory!.songs.isEmpty) {
      final folder = directory!;
      directory = folder.parent;
      unawaited(enterDirectory(folder.item));
    } else if (resumeDetail && current.isNotEmpty) {
      unawaited(choose(current, containerDetails: directoryInfo ? <String, Object?>{} : null, showDetails: wantsSongDetails));
    }
    if (isSiren) {
      unawaited(librarySirenReloadCollections(this));
      // Qt MusicSession.cpp:191-210：只有真的读到了曲库才覆盖 lists[3..4]，
      // 绝不写死 933 首 / 303 专辑这类数字。
      if (sirenSongs.isNotEmpty) {
        lists[3] = sirenSongs;
        lists[4] = sirenAlbums;
        totals[3] = lists[3].length;
        totals[4] = lists[4].length;
        hasMore[3] = false;
        hasMore[4] = false;
      }
      sirenOffsets[3] = lists[3].length;
      sirenOffsets[4] = lists[4].length;
    }
    if (directory == null && selectedLane > 0 && lists[selectedLane].isEmpty) {
      if (isSiren) {
        unawaited(librarySirenLoadSource(this, selectedLane));
      } else {
        _pendingLane = selectedLane;
      }
    }
    return true;
  }

  // ── 账号与登录（Qt MusicAccount.cpp 全文） ───────────────────────────
  void rememberIdentityName(String source, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    identityNames[source] = trimmed;
    final key = source == 'kugou' ? accountKey() : source;
    _setPref('welcome-name-' + key, trimmed);
    if (source == provider && uid.isNotEmpty) {
      _setPref('account-id-' + key, uid);
    }
  }

  Future<void> restoreIdentityName() async {
    if (isLocal || isSiren) {
      return;
    }
    final source = provider == 'netease' ? 'qq' : 'netease';
    if ((identityNames[source] ?? '').isNotEmpty) {
      return;
    }
    if (!await host.hasCredential(source)) {
      return;
    }
    _identityApi.provider = source;
    final accountToken = accountGeneration;
    final reply = await _identityApi.call(
      'account',
      <Object?>[],
      valid: () => accountToken == accountGeneration,
    );
    if (accountToken != accountGeneration || !reply.ok) {
      return;
    }
    // Qt MusicAccount.cpp:87：account 返回 [uid, nickname]，昵称取索引 1 的字符串。
    final List<Object?> values =
        reply.value is List ? (reply.value as List).cast<Object?>() : const <Object?>[];
    rememberIdentityName(source, values.length > 1 ? textOf(values[1]) : '');
    changed();
  }

  void restoreCachedAccount() {
    if (isLocal) {
      uid = '';
      nickname = '本地音乐';
      return;
    }
    if (isSiren) {
      uid = '';
      nickname = '本地收藏';
      return;
    }
    final key = accountKey();
    uid = host.authenticated ? _pref('account-id-' + key) : '';
    nickname = host.authenticated ? (identityNames[provider] ?? '') : '未登录';
    if (host.authenticated && nickname.isEmpty) {
      nickname = '正在恢复登录…';
    }
  }

  Future<void> refreshQQFeatures() async {
    if (provider != 'qq') {
      return;
    }
    // Qt MusicAccount.cpp:118-136：两项查询并发发出，均绑定账号代数；
    // 成功 capability 才写声明并 changed，vip 无论成败都写 unknown 并 changed。
    final accountToken = accountGeneration;
    final capsFuture = api.call(
      'capabilities',
      <Object?>[],
      valid: () => accountToken == accountGeneration,
    );
    final vipFuture = host.authenticated
        ? api.call('vip', <Object?>[], valid: () => accountToken == accountGeneration)
        : null;
    final caps = await capsFuture;
    if (!isStale(caps) && accountToken == accountGeneration && caps.ok) {
      capabilities = mapOf(caps.value);
      changed();
    }
    if (vipFuture == null) {
      return;
    }
    final vip = await vipFuture;
    if (isStale(vip) || accountToken != accountGeneration) {
      return;
    }
    final raw = mapOf(vip.value)['vipLevel'];
    vipLevel = vip.ok ? (raw is String ? raw : 'unknown') : 'unknown';
    changed();
  }

  /// Qt MusicAccount::restoreAccount。
  Future<bool> restoreAccount() async {
    if (isLocal || isSiren) {
      return true;
    }
    unawaited(refreshQQFeatures());
    if (!host.authenticated) {
      return true;
    }
    restoringAccount = true;
    mAccountError = '';
    changed();
    final previous = uid;
    final accountToken = accountGeneration;
    final reply = await api.call(
      'account',
      <Object?>[],
      valid: () => accountToken == accountGeneration,
    );
    if (accountToken != accountGeneration) {
      return false;
    }
    if (reply.ok) {
      // Qt MusicAccount.cpp:161-167：account 返回 [uid, nickname] 字符串数组，
      // 按固定下标取值，不是对象字段。
      final List<Object?> values =
          reply.value is List ? (reply.value as List).cast<Object?>() : const <Object?>[];
      final nextUid = values.isNotEmpty ? textOf(values[0]) : '';
      if (nextUid != previous) {
        ++accountGeneration;
        resetLikeState();
      }
      uid = nextUid;
      nickname = values.length > 1 ? textOf(values[1]) : '';
      rememberIdentityName(provider, nickname);
    } else {
      final failure = mapOf(reply.failure);
      final code = intOf(failure['code']);
      final expired = code == 401 || boolOf(failure['authExpired']) || (provider == 'netease' && code == 301);
      if (expired) {
        uid = '';
        nickname = '登录已失效';
        _setPref('account-id-' + accountKey(), '');
        status = '登录已失效，请重新登录';
      } else {
        status = '账号验证暂不可用，已保留本机登录记录';
      }
      mAccountError = status;
    }
    restoringAccount = false;
    final pending = _pendingLane;
    _pendingLane = -1;
    if (reply.ok && pending > 0) {
      unawaited(loadMoreSource(pending));
    }
    changed();
    return reply.ok;
  }

  /// Qt MusicAccount::switchProvider。
  Future<bool> switchProvider(String source, [String edition = '']) async {
    if (source == 'local' && !host.localEnabled) {
      return false;
    }
    // Qt MusicAccount.cpp:202-204 判的是目标 source（不是当前 provider）。
    final editionChanged =
        source == 'kugou' && (edition == 'standard' || edition == 'lite') && edition != kugouEdition;
    if (source != 'local' && source != 'netease' && source != 'qq' && source != 'kugou' && source != 'siren') {
      return true;
    }
    if (source == provider && !editionChanged) {
      return true;
    }
    unawaited(cancelLogin());
    ++generation;
    ++accountGeneration;
    ++selectionGeneration;
    ++directoryGeneration;
    ++wikiGeneration;
    ++suggestGeneration;
    discover.cancel();
    player.stop();
    final localSource = local;
    if (localSource != null) {
      localSource.cancel();
    }
    onMusicClearRequested?.call();
    provider = source;
    if (editionChanged) {
      kugouEdition = edition;
      await host.setKugouEdition(edition);
      _setPref('kugou-edition', edition);
      identityNames['kugou'] = _pref('welcome-name-' + accountKey());
    }
    await host.setProvider(source);
    _setPref('provider', source);
    api.provider = source;
    restoreCachedAccount();
    restoringAccount = false;
    _pendingLane = -1;
    _playLiked = false;
    mAccountError = '';
    sourceErrors = List<String>.filled(5, '');
    loginStatus = '';
    loginDiagnostics = <String, Object?>{};
    current = <String, Object?>{};
    directory = null;
    groupLane = -1;
    groupName = '';
    groupIndices = <int>[];
    details.clear();
    tracks = <JsonMap>[];
    trackIds = <String>[];
    coverImage = '';
    coverKey = '';
    lists = List<List<JsonMap>>.generate(5, (_) => <JsonMap>[]);
    totals = List<int>.filled(5, 0);
    offsets = List<int>.filled(5, 0);
    sirenOffsets = List<int>.filled(5, 0);
    rowMemory = List<int>.filled(5, 0);
    hasMore = List<bool>.filled(5, true);
    likedIds = null;
    likedCursor = 0;
    playlistCursor = 0;
    albumCursor = 0;
    trackCursor = 0;
    searchCursor = 0;
    searchLoading = false;
    personalLoading = false;
    detailLoading = false;
    directoryLoading = false;
    trackLoad = false;
    albumLoaded = false;
    writeLoading = false;
    sirenCatalogLoading = false;
    accountLoading = false;
    subscriptions = <String>[];
    subscriptionStates = <String, String>{};
    capabilities = <String, Object?>{};
    vipLevel = 'unknown';
    searchKind = 'song';
    keyword = '';
    suggestions = <String>[];
    selectedPhysical = -1;
    selectedLane = 0;
    privateSelection = false;
    loginMethod = 'qr';
    if (isLocal) {
      await refreshLocal();
    } else if (isSiren) {
      columns = List<String>.from(_sirenColumns);
      if (collections != null) {
        unawaited(librarySirenReloadCollections(this));
        unawaited(librarySirenLoadCatalog(this));
      }
    } else {
      columns = List<String>.from(_onlineColumns);
    }
    _buildPhysicalSlots();
    status = '已切换至' + providerName();
    changed();
    return restoreAccount();
  }

  /// Qt MusicAccount::loginFailureMessage。
  String loginFailureMessage(JsonMap details) {
    // Qt MusicAccount.cpp:9-58 逐行映射。字段位置：upstreamCode 在 failure /
    // primaryFailure，failureStage 不是 failureReason，details.code 只用于最后三档。
    final failure = details['lastFailure'] is Map ? mapOf(details['lastFailure']) : details;
    final primary = mapOf(failure['primaryFailure']);
    final Object? primaryError = primary['upstreamErrorKey'];
    final Object? failureError = failure['upstreamErrorKey'];
    final upstreamError = primaryError is String
        ? primaryError
        : (failureError is String ? failureError : '');
    final failureCode = intOf(failure['upstreamCode']);
    final primaryCode = intOf(primary['upstreamCode']);
    final reason = textOf(failure['failureReason']);
    final stage = textOf(failure['failureStage']);
    final detailCode = intOf(details['code']);
    if (failureCode == 20279 || primaryCode == 20279 || upstreamError == 'auth.device-limit') {
      return '登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备';
    }
    if (primaryCode == 50006) {
      return '请使用手机 QQ 扫描手机 QQ 通道二维码，再尝试登录';
    }
    if (upstreamError == 'auth.rate-limited' || primaryCode == 104604 || failureCode == 104604) {
      return 'QQ 登录操作过于频繁，请等待冷却后重试';
    }
    const Map<String, String> messages = <String, String>{
      'auth.account-restricted': '账号当前受限，请在 QQ 音乐客户端检查',
      'auth.account-banned': 'QQ 返回账号被封禁，请在官方客户端核实',
      'auth.account-binding': '账号绑定状态异常，请在 QQ 音乐客户端检查',
    };
    final restricted = messages[upstreamError];
    if (restricted != null) {
      return restricted;
    }
    if (reason == 'qr-timeout') {
      return '二维码已过期，请重新生成';
    }
    if (reason == 'user-canceled') {
      return '已取消扫码登录';
    }
    if (stage == 'credential-validation') {
      return '登录凭证验证失败，请重试或检查设备管理';
    }
    if (stage == 'credential-exchange') {
      return '扫码授权交换失败，请重试或检查设备管理';
    }
    if (stage == 'mqtt-listener') {
      return '扫码连接中断，请检查网络后重试';
    }
    if (reason == 'session-busy') {
      return '扫码授权仍在处理中，请等待';
    }
    if (detailCode == 429 || textOf(details['failureReason']) == 'local-backoff') {
      return '扫码登录暂时冷却';
    }
    if (detailCode == 401) {
      return 'QQ 登录已失效，请重新扫码';
    }
    return detailCode == 800 ? '二维码会话已失效或登录失败，请重新生成' : '扫码登录失败，请稍后重试';
  }

  int loginRetrySeconds() {
    final cooldown = _cooldowns[provider];
    if (cooldown == null) {
      return 0;
    }
    final remaining = cooldown.deadline - DateTime.now().millisecondsSinceEpoch;
    if (remaining <= 0) {
      return 0;
    }
    return (remaining + 999) ~/ 1000;
  }

  /// Qt MusicAccount::smsRetrySeconds：短信冷却剩余秒数。
  int smsRetrySeconds() {
    final remaining = _smsRetryAtMs - DateTime.now().millisecondsSinceEpoch;
    if (remaining <= 0) {
      return 0;
    }
    return (remaining + 999) ~/ 1000;
  }

  bool canRegenerateLogin() {
    final cooldown = _cooldowns[provider];
    final retry = loginRetrySeconds();
    if (retry > 0) {
      return false;
    }
    if (loginPhase == 'preparing' || loginPhase == 'confirming') {
      return false;
    }
    return cooldown == null || cooldown.deadline <= DateTime.now().millisecondsSinceEpoch;
  }

  void reportLoginFailure(JsonMap details, [String fallback = '']) {
    loginDiagnostics = MusicApiClient.safeFailure(details);
    final message = fallback.isNotEmpty ? fallback : loginFailureMessage(details);
    loginPhase = 'failed';
    loginStatus = message;
    status = message;
    final retry = intOf(details['retryAfterMs']);
    final effective = retry > 0 ? retry : intOf(mapOf(details['lastFailure'])['retryAfterMs']);
    if (effective > 0) {
      _cooldowns[provider] = _Cooldown(
        DateTime.now().millisecondsSinceEpoch + effective,
        message,
        ++_cooldownGeneration,
      );
      updateLoginCooldown();
    }
    changed();
  }

  void updateLoginCooldown() {
    final cooldown = _cooldowns[provider];
    if (cooldown == null || cooldown.token != _cooldownGeneration) {
      return;
    }
    final seconds = loginRetrySeconds();
    if (provider == this.provider && loginPhase == 'failed') {
      loginStatus = seconds > 0 ? cooldown.message + '（请等待 ' + seconds.toString() + ' 秒）' : cooldown.message + '，可重新生成';
      status = loginStatus;
    }
    if (seconds > 0) {
      scheduler.schedule(const Duration(seconds: 1), updateLoginCooldown);
    } else {
      _cooldowns.remove(provider);
      changed();
    }
  }

  /// Qt MusicAccount.cpp:343-349 waitCancellation：有 pending 才登记，
  /// 否则立即以 true 完成。
  Future<bool> waitCancellation() {
    final pending = _cancellations[provider];
    if (pending == null) {
      return Future<bool>.value(true);
    }
    final completer = Completer<bool>();
    pending.waiters.add(completer);
    return completer.future;
  }

  /// Qt MusicAccount.cpp:352-379 cancelLogin：同步作废旧二维码并登记取消屏障，
  /// 网络结果以 cancel 请求的 ok 完成等待者。
  Future<bool> cancelLogin() {
    final previousKey = qrKey;
    ++_loginGeneration;
    qrKey = '';
    qr = '';
    loginPhase = 'idle';
    accountLoading = false;
    if (provider != 'qq' || previousKey.isEmpty) {
      return waitCancellation();
    }
    final source = provider;
    final cancellation = _Cancellation();
    _cancellations[source] = cancellation;
    final completer = Completer<bool>();
    cancellation.waiters.add(completer);
    unawaited(() async {
      final reply = await api.request('/login/qr/cancel', <String, Object?>{'key': previousKey});
      if (identical(_cancellations[source], cancellation)) {
        _cancellations.remove(source);
      }
      cancellation.complete(reply.ok);
    }());
    return completer.future;
  }

  /// Qt MusicAccount::sendLoginCode。
  Future<void> sendLoginCode(String phone) async {
    if (provider != 'netease' || accountLoading) {
      return;
    }
    if (_smsRetryAtMs > DateTime.now().millisecondsSinceEpoch) {
      return;
    }
    final trimmed = phone.trim();
    if (!RegExp(r'^1[0-9]{10}$').hasMatch(trimmed)) {
      status = '请输入有效的中国大陆手机号码';
      changed();
      return;
    }
    unawaited(cancelLogin());
    final token = ++_loginGeneration;
    loginMethod = 'phone';
    loginStatus = '正在发送短信验证码…';
    status = loginStatus;
    accountLoading = true;
    _smsRetryAtMs = DateTime.now().millisecondsSinceEpoch + 60000;
    changed();
    final reply = await api.request('/captcha/sent', <String, Object?>{'phone': trimmed, 'ctcode': '86'});
    if (token != _loginGeneration) {
      return;
    }
    accountLoading = false;
    loginStatus = reply.ok ? '验证码已发送，请查看手机短信' : (reply.error ?? '');
    status = loginStatus;
    changed();
  }

  /// Qt MusicAccount::captchaLogin。
  Future<void> captchaLogin(String phone, String captcha) async {
    if (provider != 'netease' || accountLoading) {
      return;
    }
    final trimmedPhone = phone.trim();
    final trimmedCaptcha = captcha.trim();
    if (!RegExp(r'^1[0-9]{10}$').hasMatch(trimmedPhone) || !RegExp(r'^[0-9]{4,8}$').hasMatch(trimmedCaptcha)) {
      status = '请输入中国大陆手机号码和短信验证码';
      changed();
      return;
    }
    unawaited(cancelLogin());
    final token = ++_loginGeneration;
    loginPhase = 'confirming';
    loginStatus = '正在登录…';
    status = loginStatus;
    accountLoading = true;
    changed();
    final reply = await api.request('/login/cellphone', <String, Object?>{
      'phone': trimmedPhone,
      'captcha': trimmedCaptcha,
      'countrycode': '86',
    });
    if (token != _loginGeneration) {
      return;
    }
    if (reply.ok) {
      await confirmLogin(token, true);
      return;
    }
    accountLoading = false;
    loginStatus = reply.error ?? '';
    status = loginStatus;
    changed();
  }

  /// Qt MusicAccount::confirmLogin。
  Future<void> confirmLogin(int token, bool captcha) async {
    if (token != _loginGeneration) {
      return;
    }
    final reply = await api.call('account', <Object?>[]);
    if (token != _loginGeneration) {
      return;
    }
    if (!reply.ok) {
      if (captcha) {
        accountLoading = false;
        loginStatus = reply.error ?? '';
        status = loginStatus;
        changed();
      } else {
        reportLoginFailure(mapOf(reply.failure));
      }
      return;
    }
    // Qt MusicAccount.cpp:503-507：登录确认同样按 [uid, nickname] 下标解析。
    final List<Object?> values =
        reply.value is List ? (reply.value as List).cast<Object?>() : const <Object?>[];
    final saveError = await host.saveCredential();
    if (saveError.isNotEmpty) {
      accountLoading = false;
      if (captcha) {
        loginStatus = saveError;
        status = loginStatus;
        changed();
      } else {
        reportLoginFailure(<String, Object?>{}, saveError);
      }
      return;
    }
    ++accountGeneration;
    restoringAccount = false;
    mAccountError = '';
    final previous = uid;
    final nextUid = values.isNotEmpty ? textOf(values[0]) : '';
    if (nextUid != previous) {
      resetLikeState();
    }
    uid = nextUid;
    nickname = values.length > 1 ? textOf(values[1]) : '';
    rememberIdentityName(provider, nickname);
    loginStatus = '已登录：' + nickname;
    unawaited(refreshQQFeatures());
    status = captcha ? loginStatus : '已登录，可读取我的音乐';
    if (!captcha) {
      qr = '';
      qrKey = '';
      loginPhase = 'complete';
      _cooldowns.remove(provider);
    }
    accountLoading = false;
    changed();
    unawaited(loadMoreSource(2));
  }

  /// Qt MusicAccount::startLogin。
  Future<void> startLogin() async {
    if (isLocal || isSiren) {
      return;
    }
    if (!canRegenerateLogin()) {
      final seconds = loginRetrySeconds();
      if (seconds > 0) {
        final message = _cooldowns[provider]?.message ?? loginStatus;
        loginPhase = 'failed';
        loginStatus = message + '（请等待 ' + seconds.toString() + ' 秒）';
        status = loginStatus;
        changed();
      }
      return;
    }
    unawaited(cancelLogin());
    final token = ++_loginGeneration;
    loginPhase = 'preparing';
    loginDiagnostics = <String, Object?>{};
    loginStatus = '准备二维码…';
    status = loginStatus;
    qr = '';
    accountLoading = true;
    changed();
    final cancelled = await waitCancellation();
    if (token != _loginGeneration) {
      return;
    }
    if (!cancelled) {
      accountLoading = false;
      reportLoginFailure(<String, Object?>{}, '旧二维码取消失败，请稍后重试');
      return;
    }
    await _prepareQR(token);
  }

  Future<void> _prepareQR(int token) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final params = <String, Object?>{'timestamp': timestamp};
    if (provider == 'qq') {
      params['channel'] = loginMethod == 'wechat' ? 'wechat' : 'qq';
    }
    final reply = await api.request('/login/qr/key', params);
    if (token != _loginGeneration) {
      return;
    }
    if (!reply.ok) {
      reportLoginFailure(mapOf(reply.failure), reply.error ?? '');
      accountLoading = false;
      return;
    }
    final body = mapOf(reply.value);
    var key = textOf(body['unikey']);
    if (key.isEmpty) {
      key = textOf(mapOf(body['data'])['unikey']);
    }
    if (key.isEmpty) {
      reportLoginFailure(<String, Object?>{}, '二维码生成失败');
      accountLoading = false;
      return;
    }
    qrKey = key;
    if (provider == 'qq') {
      loginPhase = 'waiting';
      final scanner = loginMethod == 'wechat' ? '微信' : '手机 QQ';
      loginStatus = '请用' + scanner + '扫描并确认登录';
      status = loginStatus;
      accountLoading = false;
      changed();
      unawaited(_pollQR(token, 0));
      return;
    }
    final image = await host.qr(qrKey);
    if (token != _loginGeneration) {
      return;
    }
    if (image.isNotEmpty) {
      qr = image;
      loginPhase = 'waiting';
      loginStatus = '请使用网易云音乐 App 扫描并确认登录';
      status = loginStatus;
      accountLoading = false;
      changed();
      return;
    }
    final create = await api.request('/login/qr/create', <String, Object?>{
      'key': qrKey,
      'qrimg': true,
      'timestamp': timestamp,
    });
    if (token != _loginGeneration) {
      return;
    }
    final data = textOf(mapOf(mapOf(create.value)['data'])['qrimg']);
    if (!RegExp('^data:image/(png|jpeg|gif|webp);base64,').hasMatch(data)) {
      reportLoginFailure(<String, Object?>{}, providerName() + '二维码格式无效');
      accountLoading = false;
      return;
    }
    final rendered = await host.qrImage(data);
    if (token != _loginGeneration) {
      return;
    }
    if (rendered.isEmpty) {
      reportLoginFailure(<String, Object?>{}, providerName() + '二维码读取失败');
      accountLoading = false;
      return;
    }
    qr = rendered;
    loginPhase = 'waiting';
    loginStatus = '请使用网易云音乐 App 扫描并确认登录';
    status = loginStatus;
    accountLoading = false;
    changed();
  }

  Future<void> _pollQR(int token, int count) async {
    if (token != _loginGeneration) {
      return;
    }
    if (count >= 300) {
      reportLoginFailure(<String, Object?>{}, '二维码超时，请重新生成');
      accountLoading = false;
      return;
    }
    await _delay(1000);
    if (token != _loginGeneration) {
      return;
    }
    final reply = await api.request(
      '/login/qr/check',
      <String, Object?>{'key': qrKey, 'timestamp': DateTime.now().millisecondsSinceEpoch},
      allowed: const <int>{800, 801, 802, 803},
    );
    if (token != _loginGeneration) {
      return;
    }
    final body = mapOf(reply.value);
    final code = reply.ok ? _jsonToInt(body['code'], 800) : 800;
    if (code == 800) {
      qr = '';
      accountLoading = false;
      if (provider == 'qq') {
        reportLoginFailure(body);
      } else {
        reportLoginFailure(<String, Object?>{}, '二维码已过期，请重新生成');
      }
      return;
    }
    if (code == 802) {
      loginPhase = 'confirming';
      loginStatus = '已扫描，请在手机上确认';
      status = loginStatus;
      changed();
      unawaited(_pollQR(token, count + 1));
      return;
    }
    if (code == 803) {
      loginPhase = 'confirming';
      await confirmLogin(token, false);
      return;
    }
    unawaited(_pollQR(token, count + 1));
  }

  /// Qt MusicAccount::logout。
  Future<void> logout() async {
    if (isLocal || isSiren) {
      return;
    }
    final clearSelection = selectedLane > 0 || privateSelection;
    writeLoading = false;
    subscriptions = <String>[];
    subscriptionStates = <String, String>{};
    vipLevel = 'unknown';
    discover.cancel();
    player.stop();
    player.clearHistory();
    _setPref('play-history', '[]');
    while (directory != null) {
      await leaveDirectory();
    }
    groupLane = -1;
    groupName = '';
    groupIndices = <int>[];
    unawaited(cancelLogin());
    ++accountGeneration;
    restoringAccount = false;
    _pendingLane = -1;
    _playLiked = false;
    mAccountError = '';
    sourceErrors = List<String>.filled(5, '');
    await host.logout();
    _setPref('account-id-' + accountKey(), '');
    uid = '';
    nickname = '未登录';
    likedIds = null;
    likedCursor = 0;
    playlistCursor = 0;
    albumCursor = 0;
    personalLoading = false;
    details.clear();
    for (var lane = 1; lane < 5; lane++) {
      lists[lane] = <JsonMap>[];
      totals[lane] = 0;
      offsets[lane] = 0;
      hasMore[lane] = true;
    }
    onMusicClearRequested?.call();
    await choose(clearSelection ? <String, Object?>{} : current);
    privateSelection = false;
    status = '已退出登录';
    changed();
  }

  // ── 本地音乐（Qt MusicLocal.cpp 全文） ───────────────────────────────
  Future<void> refreshLocal() async {
    final source = local;
    if (!isLocal || source == null) {
      return;
    }
    columns = List<String>.from(_localColumns);
    lists[1] = source.songs();
    lists[2] = source.collections('folder');
    lists[3] = source.collections('album');
    lists[4] = source.collections('artist');
    lists[0] = source.search(keyword, searchKind);
    for (var lane = 0; lane < 5; lane++) {
      totals[lane] = lists[lane].length;
      hasMore[lane] = false;
    }
    _buildPhysicalSlots();
    if (source.busy) {
      status = source.status;
      changed();
      return;
    }
    details.clear();
    final byPath = <String, JsonMap>{};
    for (final value in source.songs()) {
      final path = textOf(value['path']);
      if (path.isNotEmpty) {
        byPath[path] = value;
      }
    }
    final playing = current;
    final playingPath = textOf(playing['path']);
    if (itemKindOf(playing) == 'song' && playingPath.isNotEmpty && byPath.containsKey(playingPath)) {
      final replacement = byPath[playingPath]!;
      if (textOf(replacement['fingerprint']) != textOf(playing['fingerprint'])) {
        ++selectionGeneration;
        current = replacement;
        coverImage = '';
        coverKey = '';
        unawaited(loadCover(current));
      }
    }
    final queue = player.queueItems;
    for (var index = queue.length - 1; index >= 0; index--) {
      final value = queue[index];
      if (textOf(value['provider']) != 'local') {
        continue;
      }
      final path = textOf(value['path']);
      if (byPath.containsKey(path)) {
        continue;
      }
      final playingThis = itemKeyOf(value) == itemKeyOf(player.current);
      if (playingThis) {
        player.stop();
      } else {
        player.remove(index);
      }
    }
    final folder = directory;
    if (folder != null && itemKeyOf(folder.item) != 'playback:queue') {
      folder.updateSongs(source.tracks(folder.item), folder.sortField);
      // Qt MusicLocal.cpp:53-56：ids 直接追加 songs 里原始的 ["id"]。
      folder.ids = <Object?>[for (final value in folder.songs) value['id']];
      folder.cursor = folder.ids.length;
      folder.index = folder.songs.isEmpty ? 0 : (folder.index > folder.songs.length - 1 ? folder.songs.length - 1 : folder.index);
      folder.item['trackCount'] = folder.songs.length;
      folder.page = (folder.index ~/ _physicalCount) * _physicalCount;
    }
    if (itemKindOf(current) == 'song' && playingPath.isNotEmpty && !byPath.containsKey(playingPath)) {
      await choose(<String, Object?>{});
    }
    status = source.status;
    changed();
  }

  /// Qt MusicLocal::searchLocal。
  Future<void> searchLocal(String query, {String kind = ''}) async {
    final source = local;
    if (!isLocal || source == null) {
      return;
    }
    ++generation;
    if (kind.isNotEmpty) {
      searchKind = kind;
    }
    keyword = query.trim();
    searchLoading = false;
    groupLane = -1;
    groupIndices = <int>[];
    groupName = '';
    lists[0] = source.search(keyword, searchKind);
    totals[0] = lists[0].length;
    hasMore[0] = false;
    offsets[0] = 0;
    rowMemory[0] = 0;
    showSource(0);
    status = '本地检索：' + totals[0].toString() + ' 条结果';
    modeRequests.add('archive');
    changed();
  }

  /// Qt MusicLocal::importLocal。
  void importLocal(List<String> paths) {
    if (!isLocal) {
      return;
    }
    local?.importPaths(paths);
  }

  /// Qt MusicDiscover.cpp:16-122 load：推荐分页，世代与账号代数一起校验。
  Future<void> discoverLoad(String nextTab, bool append) async {
    final state = discover;
    if (append && (state.loading || !state.more)) {
      return;
    }
    if (nextTab.isNotEmpty) {
      state.tab = nextTab;
    }
    final token = ++state.generation;
    final accountToken = accountGeneration;
    bool alive() => state.generation == token && accountGeneration == accountToken;
    final start = append ? state.offset : 0;
    state.loading = true;
    state.status = '正在读取…';
    if (!append) {
      state.items = <JsonMap>[];
    }
    changed();
    final currentTab = state.tab;
    if ((currentTab == 'daily' || currentTab == 'guess') && uid.isEmpty) {
      discoverAccept(const MusicReply.fail('登录后查看每日推荐'), currentTab, start, append);
      return;
    }
    if (currentTab == 'artists' && (uid.isEmpty || provider != 'netease')) {
      discoverAccept(const MusicReply.fail('登录网易云后查看收藏歌手'), currentTab, start, append);
      return;
    }
    if (currentTab == 'history') {
      final history = <JsonMap>[];
      for (final value in player.history) {
        final valueProvider = value['provider'] is String ? value['provider']! as String : 'netease';
        if (valueProvider == provider) {
          history.add(value);
        }
      }
      discoverAccept(
        MusicReply.ok(<String, Object?>{'items': history, 'rawCount': 0, 'more': false}),
        currentTab,
        start,
        append,
      );
      return;
    }
    if (provider != 'netease') {
      final reply = await api.call(
        'discover',
        <Object?>[currentTab, start, currentTab == 'new-songs' ? state.newSongArea : state.category],
        valid: alive,
      );
      if (!alive()) {
        return;
      }
      discoverAccept(reply, currentTab, start, append);
      return;
    }
    String route;
    JsonMap parameters = <String, Object?>{};
    String kind = 'playlist';
    String field = '';
    if (currentTab == 'playlists') {
      route = '/personalized';
      parameters = <String, Object?>{'limit': 30};
      field = 'result';
    } else if (currentTab == 'daily') {
      route = '/recommend/songs';
      kind = 'song';
    } else if (currentTab == 'charts') {
      route = '/toplist';
      field = 'list';
    } else if (currentTab == 'albums') {
      route = '/album/newest';
      field = 'albums';
      kind = 'album';
    } else if (currentTab == 'categories') {
      route = '/top/playlist';
      parameters = <String, Object?>{'cat': state.category, 'limit': 30, 'offset': start};
      field = 'playlists';
    } else if (currentTab == 'artists') {
      route = '/artist/sublist';
      parameters = <String, Object?>{'limit': 30, 'offset': start};
      field = 'data';
      kind = 'artist';
    } else {
      discoverAccept(const MusicReply.fail('不支持的发现类别'), currentTab, start, append);
      return;
    }
    final reply = await api.request(route, parameters, valid: alive);
    if (!alive()) {
      return;
    }
    if (!reply.ok) {
      discoverAccept(reply, currentTab, start, append);
      return;
    }
    final body = mapOf(reply.value);
    Object? rawData = body[field];
    if (currentTab == 'daily') {
      final daily = mapOf(body['data'])['dailySongs'];
      rawData = daily is List ? daily : body['recommend'];
    }
    final data = rawData is List ? rawData.cast<Object?>() : const <Object?>[];
    final values = <JsonMap>[];
    for (final value in data) {
      final entry = musicItemParse(mapOf(value), kind);
      if (entry.isNotEmpty) {
        values.add(entry);
      }
    }
    var more = false;
    if (currentTab == 'categories') {
      more = boolOf(body['more']);
    } else if (currentTab == 'artists') {
      more = boolOf(body['hasMore']);
    }
    discoverAccept(
      MusicReply.ok(<String, Object?>{'items': values, 'rawCount': data.length, 'more': more}),
      currentTab,
      start,
      append,
    );
  }

  /// Qt MusicDiscover.cpp:124-150 accept。
  void discoverAccept(MusicReply result, String currentTab, int start, bool append) {
    final state = discover;
    if (!result.ok) {
      state.status = result.error ?? '';
    } else {
      final page = mapOf(result.value);
      if (currentTab == 'categories' && provider == 'qq' && page['category'] is String) {
        state.category = page['category']! as String;
      }
      if (currentTab == 'new-songs') {
        state.newSongAreas = mapsOf(page['areas']);
        state.newSongArea = _jsonToInt(page['area'], 5).toString();
      }
      final pageItems = mapsOf(page['items']);
      state.items = append ? uniqueItems(state.items, pageItems) : pageItems;
      state.offset = start + intOf(page['rawCount']);
      if (currentTab == 'artists') {
        for (final value in state.items) {
          subscriptions.add(textOf(value['key']));
        }
      }
      state.more = boolOf(page['more']);
      state.status =
          state.items.isEmpty ? '暂无内容' : '已载入 ' + state.items.length.toString() + ' 条';
    }
    state.loading = false;
    changed();
  }

  /// Qt MusicDiscover.cpp:152-181 loadCategories。
  Future<void> discoverLoadCategories() async {
    final state = discover;
    final token = state.generation;
    final accountToken = accountGeneration;
    bool alive() => state.generation == token && accountGeneration == accountToken;
    if (provider != 'netease') {
      final reply = await api.call('categories', const <Object?>[], valid: alive);
      if (!alive()) {
        return;
      }
      _acceptDiscoverCategories(reply);
      return;
    }
    final reply = await api.request('/playlist/catlist', <String, Object?>{}, valid: alive);
    if (!alive()) {
      return;
    }
    if (!reply.ok) {
      _acceptDiscoverCategories(reply);
      return;
    }
    final values = <JsonMap>[];
    for (final value in mapsOf(mapOf(reply.value)['sub'])) {
      final name = value['name'];
      values.add(<String, Object?>{'id': name, 'name': name});
    }
    _acceptDiscoverCategories(MusicReply.ok(values));
  }

  void _acceptDiscoverCategories(MusicReply result) {
    if (result.ok) {
      discover.categories = mapsOf(result.value);
      changed();
    } else {
      discover.status = result.error ?? '';
    }
  }

  /// Qt MusicDiscover::open。
  Future<void> openDiscover(int index) async {
    if (index < 0 || index >= discover.items.length) {
      return;
    }
    final value = discover.items[index];
    privateSelection = discover.tab == 'daily' || discover.tab == 'artists';
    playContext = discover.items;
    if (itemKindOf(value) == 'song') {
      player.play(value, source: discover.items);
      await choose(value);
      modeRequests.add('detail');
      changed();
      return;
    }
    await enterDirectory(value);
  }

  // ── part 委托（签名由根文件冻结，实现分别在三个 part） ───────────────
  Future<void> setDirectorySort(String field) => librarySetDirectorySort(this, field);

  Future<void> enterDirectory(JsonMap value) => libraryEnterDirectory(this, value);

  Future<bool> openDaily() => libraryOpenDaily(this);

  Future<void> loadArtistAlbums() => libraryLoadArtistAlbums(this);

  Future<void> openSongArtist(int index) => libraryOpenSongArtist(this, index);

  Future<void> observeDirectory(int physical) => libraryObserveDirectory(this, physical);

  /// Qt MusicLibrary.h:128：selectDirectory(int index, QString mode = "archive",
  /// QString axis = "row", int direction = 1)。axis 默认是 "row"，不是空串：
  /// 空串会让 navigation 变成空对象，是可观测差异（MusicDirectory.cpp:302-319）。
  Future<void> selectDirectory(
    int index,
    String mode, {
    String axis = 'row',
    int direction = 1,
  }) =>
      librarySelectDirectory(this, index, mode, axis: axis, direction: direction);

  /// Qt MusicLibrary.h:129：navigateDirectory(int step, QString axis = {})。
  Future<void> navigateDirectory(int step, [String axis = '']) =>
      libraryNavigateDirectory(this, step, axis);

  Future<void> loadDirectoryPage([int? selectAfter]) => libraryLoadDirectoryPage(this, selectAfter);

  Future<void> showDirectoryInfo() => libraryShowDirectoryInfo(this);

  Future<void> returnToDirectory() => libraryReturnToDirectory(this);

  Future<void> leaveDirectory({bool restore = true}) => libraryLeaveDirectory(this, restore: restore);

  Future<void> followPlayback(JsonMap value) => libraryFollowPlayback(this, value);

  Future<void> search(String text, {String kind = '', bool more = false}) =>
      librarySearch(this, text, kind: kind, more: more);

  void suggest(String text) => librarySuggest(this, text);

  void cancelSearch() => libraryCancelSearch(this);

  Future<void> sirenReloadCollections() => librarySirenReloadCollections(this);

  Future<void> sirenLoadCatalog() => librarySirenLoadCatalog(this);

  Future<void> sirenSearchLocal(String query, String kind, int start, bool more) =>
      librarySirenSearchLocal(this, query, kind, start, more);

  Future<void> sirenLoadSource(int lane) => librarySirenLoadSource(this, lane);

  Future<bool> openSirenAllSongs() => libraryOpenSirenAllSongs(this);
}

/// Qt MusicLibrary::Cooldown：登录冷却（deadline + 文案 + 世代 token）。
class _Cooldown {
  _Cooldown(this.deadline, this.message, this.token);

  final int deadline;
  final String message;
  final int token;
}

/// Qt MusicLibrary::Cancellation：扫码取消的等待者集合。
class _Cancellation {
  final List<Completer<bool>> waiters = <Completer<bool>>[];
  bool _done = false;

  bool get done => _done;

  void complete(bool value) {
    _done = true;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(value);
      }
    }
    waiters.clear();
  }
}

/// Qt MusicDiscover：发现页状态（tab/items/分页/分类）。
class MusicDiscoverState {
  String tab = 'playlists';
  List<JsonMap> items = <JsonMap>[];
  bool loading = false;
  String status = '';
  int generation = 0;
  int offset = 0;
  bool more = false;
  String category = '全部';
  /// Qt QJsonArray：分类对象列表（{id,name}）。
  List<JsonMap> categories = <JsonMap>[];
  /// Qt QJsonArray：新歌区域对象列表（{id,name}）。
  List<JsonMap> newSongAreas = <JsonMap>[];
  String newSongArea = '5';

  void cancel() {
    ++generation;
    loading = false;
    items = <JsonMap>[];
    more = false;
    offset = 0;
    categories = <JsonMap>[];
    newSongAreas = <JsonMap>[];
    newSongArea = '5';
    category = '全部';
    tab = 'playlists';
  }

  JsonMap toJson() => <String, Object?>{
        'tab': tab,
        'items': items,
        'offset': offset,
        'more': more,
        'category': category,
        'newSongArea': newSongArea,
      };

  void restore(JsonMap saved) {
    if (saved.isEmpty) {
      tab = 'playlists';
      category = '全部';
      newSongArea = '5';
      return;
    }
    final savedTab = textOf(saved['tab']);
    tab = savedTab.isEmpty ? 'playlists' : savedTab;
    items = mapsOf(saved['items']);
    offset = intOf(saved['offset']);
    more = boolOf(saved['more']);
    final savedCategory = textOf(saved['category']);
    category = savedCategory.isEmpty ? '全部' : savedCategory;
    final area = textOf(saved['newSongArea']);
    newSongArea = area.isEmpty ? '5' : area;
  }
}
