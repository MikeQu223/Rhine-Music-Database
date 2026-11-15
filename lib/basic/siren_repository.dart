/// 塞壬唱片（monster-siren）真实网络仓库：lane A 的唯一网络出口。
///
/// 真值来源（只读）：
/// - /home/aibeto/code/Rhine-Music-Database/MusicBridge/client/siren.mjs
///   request :89-111（User-Agent / Accept / 20s 超时 / HTTP 与 code 错误文案）、
///   getText :56-74、load :114-187、songDetail :282-291、freshSong :294-296、
///   albumDetail :298-307、detail :414-439、playback :482-495、lyrics :497-513。
///
/// wire 形状（协调者 control seq5 纠正，逐字）：
///   "官网 wire = { code: 0, data: ... }，错误信息在 code/msg；目录 data 可能为数组或 { list: [...] }。"
/// 因此主分支只认 code == 0 → data；{code: 200, value: ...} 仅作为**次选**容忍分支
/// （本地 Qt HostReply 桥接归一形态，来源 Qt/src/MusicApi.cpp，不是官网 wire）。
/// 冻结契约 v1 原文里的 {code:200,value} 已被协调者作废，不得作为默认主分支。
///
/// 依赖限制：pubspec 只有 flutter + cupertino_icons，所以只能用 dart:io.HttpClient。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'basic_models.dart';

/// 官网 origin（MusicBridge/client/siren.mjs:1 的 ORIGIN）。
const String sirenOrigin = 'https://monster-siren.hypergryph.com';

/// 上游要求的 User-Agent（MusicBridge/client/siren.mjs:90）。
const String sirenUserAgent = 'RhineMusicDatabase/1.0';

/// 一次 HTTP 取回的原始结果；[get] 注入点用它承接网络层，便于测试只写不跑。
class SirenHttpResult {
  const SirenHttpResult({required this.statusCode, required this.bytes});

  /// HTTP 状态码（非 200 由仓库转成可显示错误，见 siren.mjs:101/:68）。
  final int statusCode;

  /// 原始响应字节（UTF-8 解码前；坏字节必须报错，不静默替换）。
  final List<int> bytes;
}

/// 网络注入点：默认实现走 dart:io HttpClient，测试注入假实现（不触网）。
typedef SirenHttpGet = Future<SirenHttpResult> Function(Uri uri);

/// 塞壬唱片仓库：catalog / 歌曲详情 / 专辑详情 / 歌词文本。
///
/// 不缓存任何响应：曲库是启动时的一次性全量（siren.mjs:310-316），
/// 歌曲详情带时效签名直链，必须每次播放前 fresh 读取（siren.mjs:293-296 的注释），
/// 所以本类故意不提供 detail 缓存——缓存只能存在于调用方明确标记的地方。
class SirenRepository {
  SirenRepository({
    Uri? baseUri,
    HttpClient? client,
    SirenHttpGet? get,
    this.timeout = const Duration(seconds: 20),
  })  : baseUri = baseUri ?? Uri.parse(sirenOrigin),
        _client = client,
        _get = get;

  /// 站点根地址（默认 [sirenOrigin]）；末段路径会被保留，便于测试注入子路径。
  final Uri baseUri;

  /// 连接/读取超时（siren.mjs:91 的 20000ms）。
  final Duration timeout;

  final HttpClient? _client;
  final SirenHttpGet? _get;
  HttpClient? _ownClient;
  bool _closed = false;

  /// 一次性全量曲库：并发 GET /api/songs 与 /api/albums（siren.mjs:114-187、:310-316）。
  ///
  /// 解析顺序与 siren.mjs 一致：先建专辑表（cid → name/coverUrl/artistes），
  /// 再用 albumCid 归组歌曲，最后按专辑表顺序产出专辑（曲目数 = 归组数）。
  Future<SirenCatalog> loadCatalog() async {
    final List<Object?> responses = await Future.wait(<Future<Object?>>[
      _requestJson(_uri('/api/songs')),
      _requestJson(_uri('/api/albums')),
    ]);
    final List<Map<String, Object?>> songRows = _rows(responses[0], '/api/songs');
    final List<Map<String, Object?>> albumRows = _rows(responses[1], '/api/albums');

    final Map<String, String> albumNames = <String, String>{};
    final Map<String, String> albumCovers = <String, String>{};
    final Map<String, List<String>> albumArtists = <String, List<String>>{};
    for (final Map<String, Object?> row in albumRows) {
      final String id = _trim(row['cid']);
      if (id.isEmpty) {
        // siren.mjs:219-221：cid 为空的专辑被丢弃。
        continue;
      }
      albumNames.putIfAbsent(id, () => _trim(row['name']));
      albumCovers.putIfAbsent(id, () => _text(row['coverUrl']));
      albumArtists.putIfAbsent(id, () => _names(row['artistes']));
    }

    final List<SirenSong> songs = <SirenSong>[];
    final Map<String, List<String>> songArtists = <String, List<String>>{};
    final Map<String, List<SirenSong>> songsByAlbum = <String, List<SirenSong>>{};
    for (final Map<String, Object?> row in songRows) {
      final String id = _trim(row['cid']);
      if (id.isEmpty) {
        // siren.mjs:190-193：cid 为空的歌曲被丢弃。
        continue;
      }
      final String albumId = _trim(row['albumCid']);
      final List<String> rawArtists = _names(row['artists']);
      final List<String> artists = rawArtists.isNotEmpty
          ? rawArtists
          : (albumArtists[albumId]?.isNotEmpty == true
              ? albumArtists[albumId]!
              : const <String>[sirenDefaultArtist]);
      final SirenSong song = SirenSong(
        id: id,
        title: _title(row['name']),
        artist: artists.join(' / '),
        album: albumNames[albumId] ?? '',
        albumId: albumId,
        cover: albumCovers[albumId] ?? '',
        sourceUrl: '',
        lyricUrl: '',
        durationMs: 0,
      );
      songs.add(song);
      songArtists[id] = artists;
      songsByAlbum.putIfAbsent(albumId, () => <SirenSong>[]).add(song);
    }

    final List<SirenAlbum> albums = <SirenAlbum>[];
    for (final Map<String, Object?> row in albumRows) {
      final String id = _trim(row['cid']);
      if (id.isEmpty) {
        continue;
      }
      final List<SirenSong> tracks = List<SirenSong>.unmodifiable(
        songsByAlbum[id] ?? const <SirenSong>[],
      );
      List<String> artists = _names(row['artistes']);
      if (artists.isEmpty) {
        // siren.mjs:231-238：专辑无 artistes 时取专辑内歌曲艺人并集（保持歌曲顺序）。
        final Set<String> union = <String>{};
        for (final SirenSong track in tracks) {
          union.addAll(songArtists[track.id] ?? const <String>[]);
        }
        artists = union.toList(growable: false);
      }
      if (artists.isEmpty) {
        // siren.mjs:250：仍为空则默认艺人。
        artists = const <String>[sirenDefaultArtist];
      }
      albums.add(SirenAlbum(
        id: id,
        name: _title(row['name']),
        artist: artists.join(' / '),
        cover: _text(row['coverUrl']),
        songCount: tracks.length,
        songs: tracks,
      ));
    }
    return SirenCatalog(
      songs: List<SirenSong>.unmodifiable(songs),
      albums: List<SirenAlbum>.unmodifiable(albums),
    );
  }

  /// GET /api/song/<id>（siren.mjs:282-296）：播放前 fresh 读取，拿带时效签名直链与歌词地址。
  ///
  /// 不做缓存；空 [sourceUrl] 不在这里报错——播放入口用
  /// siren.mjs:485 的 '塞壬唱片未提供可播放音源' 拒绝，避免把"详情成功但无音源"误报成网络错误。
  Future<SirenSongDetail> songDetail(String id) async {
    final String trimmed = id.trim();
    if (trimmed.isEmpty) {
      throw const SirenException('塞壬唱片响应格式无效：歌曲 id 为空');
    }
    final String path = '/api/song/${Uri.encodeComponent(trimmed)}';
    final Map<String, Object?> value = _object(await _requestJson(_uri(path)), path);
    return SirenSongDetail(
      id: trimmed,
      title: _trim(value['name']),
      sourceUrl: _trim(value['sourceUrl']),
      lyricUrl: _trim(value['lyricUrl']),
    );
  }

  /// GET /api/album/<id>/detail（siren.mjs:298-307、:414-439）。
  ///
  /// 详情曲目的 albumCid 用请求的专辑 id、艺人取 detail 的 artistes；
  /// 专辑名/封面沿用曲库值（siren.mjs:425 的 merged 只覆盖 detail 真正给出的字段）。
  /// 详情非空时覆盖 name/cover/artist，曲目数与曲目列表一律以 detail 为准（:430）。
  Future<SirenAlbum> albumDetail(SirenAlbum album) async {
    final String albumId = album.id.trim();
    if (albumId.isEmpty) {
      throw const SirenException('塞壬唱片响应格式无效：专辑 id 为空');
    }
    final String path = '/api/album/${Uri.encodeComponent(albumId)}/detail';
    final Map<String, Object?> detail = _object(await _requestJson(_uri(path)), path);
    final List<Map<String, Object?>> rows = _rows(detail['songs'], path);

    // 先算出详情给出的专辑字段：曲目缺 artistes 时，siren.mjs:425 的 merged album 已是
    // "曲库专辑 + detail 覆盖"，所以回退艺人要用 detail 的 artistes，而不是曲库旧值。
    final String name = _trim(detail['name']);
    final String cover = _text(detail['coverUrl']);
    final List<String> albumArtistNames = _names(detail['artistes']);
    final String fallbackArtist =
        albumArtistNames.isNotEmpty ? albumArtistNames.join(' / ') : album.artist;
    final String albumTitle = name.isEmpty ? album.name : name;
    final String albumCover = cover.isEmpty ? album.cover : cover;

    final List<SirenSong> songs = <SirenSong>[];
    for (final Map<String, Object?> row in rows) {
      final String id = _trim(row['cid']);
      if (id.isEmpty) {
        continue;
      }
      final List<String> artists = _names(row['artistes']);
      songs.add(SirenSong(
        id: id,
        title: _title(row['name']),
        artist: artists.isNotEmpty ? artists.join(' / ') : fallbackArtist,
        album: albumTitle,
        albumId: albumId,
        cover: albumCover,
        sourceUrl: _trim(row['sourceUrl']),
        lyricUrl: _trim(row['lyricUrl']),
        durationMs: 0,
      ));
    }

    return album.copyWith(
      name: name.isEmpty ? null : name,
      cover: cover.isEmpty ? null : cover,
      artist: albumArtistNames.isEmpty ? null : albumArtistNames.join(' / '),
      songs: List<SirenSong>.unmodifiable(songs),
      songCount: songs.length,
    );
  }

  /// GET 歌词文件（siren.mjs:497-513）：原样返回文本。
  ///
  /// 超过 sirenMaxLyricLength（1e6）或去空白后为空的处理在控制器（siren.mjs 返回 null 的语义），
  /// 仓库只负责把"资源请求失败（HTTP …）"变成可显示错误。
  Future<String> lyricsText(String lyricUrl) async {
    final String trimmed = lyricUrl.trim();
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || trimmed.isEmpty) {
      throw SirenException('塞壬唱片响应格式无效：歌词地址无效（$lyricUrl）');
    }
    final SirenHttpResult result = await _fetch(uri);
    if (result.statusCode != 200) {
      // siren.mjs:66-69 的 getText 分支，文案与 request() 分支不同（"资源请求失败"）。
      throw SirenException('塞壬唱片资源请求失败（HTTP ${result.statusCode}）');
    }
    try {
      return utf8.decode(result.bytes);
    } on FormatException catch (error) {
      throw SirenException('塞壬唱片响应解码失败：${error.message}', error);
    }
  }

  /// 关掉自建的 HttpClient；注入的 client 由注入方负责关闭。
  void close() {
    _closed = true;
    _ownClient?.close(force: true);
    _ownClient = null;
  }

  // ---------------------------------------------------------------------------
  // wire 解码
  // ---------------------------------------------------------------------------

  Future<Object?> _requestJson(Uri uri) async {
    final SirenHttpResult result = await _fetch(uri);
    if (result.statusCode != 200) {
      throw SirenException('塞壬唱片请求失败（HTTP ${result.statusCode}）');
    }
    final String text;
    try {
      text = utf8.decode(result.bytes);
    } on FormatException catch (error) {
      throw SirenException('塞壬唱片响应解码失败：${error.message}', error);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw SirenException('塞壬唱片响应格式无效：${error.message}', error);
    }
    return _unwrap(decoded, uri);
  }

  /// 解包 envelope（siren.mjs:104-107 只认 code === 0 → data）。
  ///
  /// 次选容忍 code == 200 的本地桥接形态 {code:200, value:...}：来源是 Qt HostReply
  /// （Qt/src/MusicApi.cpp 的回复归一），不是官网 wire；协调者已作废把它当默认分支。
  /// 其余 code（含缺失）按 siren.mjs:105 的文案报错：'塞壬唱片返回 <code>：<msg>'。
  Object? _unwrap(Object? decoded, Uri uri) {
    if (decoded is! Map) {
      throw SirenException('塞壬唱片响应格式无效：${uri.path} 的响应不是 JSON 对象');
    }
    final Object? code = decoded['code'];
    if (code == 0) {
      return decoded['data'];
    }
    if (code == 200) {
      return decoded['value'];
    }
    final Object? message = decoded['msg'] ?? decoded['message'];
    final String detail = message is String && message.trim().isNotEmpty ? message.trim() : '请稍后重试';
    throw SirenException('塞壬唱片返回 ${code ?? '未知错误'}：$detail');
  }

  Map<String, Object?> _object(Object? value, String path) {
    if (value is Map) {
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in value.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      };
    }
    throw SirenException('塞壬唱片响应格式无效：$path 的 data 不是对象');
  }

  /// 目录的 data 可能是数组，也可能是 { list: [...] }（协调者纠正原句）。
  List<Map<String, Object?>> _rows(Object? value, String path) {
    final List<Object?>? raw = value is List
        ? value
        : (value is Map && value['list'] is List ? value['list'] as List<Object?> : null);
    if (raw == null) {
      throw SirenException('塞壬唱片响应格式无效：$path 的 data 不是数组');
    }
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (final Object? entry in raw) {
      if (entry is Map) {
        rows.add(<String, Object?>{
          for (final MapEntry<Object?, Object?> item in entry.entries)
            if (item.key is String) item.key! as String: item.value,
        });
      }
    }
    return rows;
  }

  // ---------------------------------------------------------------------------
  // 传输
  // ---------------------------------------------------------------------------

  Future<SirenHttpResult> _fetch(Uri uri) async {
    if (_closed) {
      throw const SirenException('塞壬唱片请求已关闭');
    }
    final SirenHttpGet? injected = _get;
    if (injected != null) {
      try {
        return await injected(uri).timeout(timeout);
      } on TimeoutException {
        throw SirenException('塞壬唱片请求超时（${timeout.inSeconds} 秒）');
      }
    }
    final HttpClient client = _ensureClient();
    try {
      final HttpClientRequest request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, sirenUserAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse response = await request.close().timeout(timeout);
      final Uint8List bytes = await _readBytes(response).timeout(timeout);
      return SirenHttpResult(statusCode: response.statusCode, bytes: bytes);
    } on TimeoutException {
      throw SirenException('塞壬唱片请求超时（${timeout.inSeconds} 秒）');
    } on SirenException {
      rethrow;
    } on Object catch (error) {
      // 上游 siren.mjs 只定义了 HTTP(:101)/code(:105)/资源(:68) 三类文案；连接失败没有对应原文，
      // 这里沿用同一前缀并附真实原因，绝不吞成"未知错误"。
      throw SirenException('塞壬唱片请求失败：$error', error);
    }
  }

  HttpClient _ensureClient() {
    final HttpClient? injected = _client;
    if (injected != null) {
      return injected;
    }
    final HttpClient? existing = _ownClient;
    if (existing != null) {
      return existing;
    }
    final HttpClient created = HttpClient()..connectionTimeout = timeout;
    _ownClient = created;
    return created;
  }

  Future<Uint8List> _readBytes(HttpClientResponse response) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  // ---------------------------------------------------------------------------
  // 字段清洗（siren.mjs 的 trimmed/text/array 语义）
  // ---------------------------------------------------------------------------

  Uri _uri(String path) {
    final String base = baseUri.toString();
    final String prefix = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return Uri.parse('$prefix$path');
  }

  String _trim(Object? value) => value is String ? value.trim() : '';

  String _text(Object? value) => _trim(value);

  /// 标题空则占位 '正在读取…'（siren.mjs:203、:242）。
  String _title(Object? value) {
    final String text = _trim(value);
    return text.isEmpty ? sirenUnknownTitle : text;
  }

  List<String> _names(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    final List<String> names = <String>[];
    for (final Object? entry in value) {
      final String name = _trim(entry);
      if (name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }
}
