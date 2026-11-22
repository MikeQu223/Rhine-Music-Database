/// 用户安装插件（netease/qq/kugou/…）的真实网关：把 `ProviderGateway` 的每个操作
/// 映射到插件 worker 的 `/native/<id>/<operation>` 路由。
///
/// 参数形状逐条照 `Qt/src/MusicApi.cpp` 的调用点（`search` 传 `{query, searchKind, start}`、
/// `loginBegin` 传 `{loginMethod}`、`loginPoll` 传 `{qrKey}`、`comments` 传
/// `{track, targetID, sort, page, cursor}` …），响应按 `body.value` 取。
library;

import 'plugin_bridge.dart';
import 'provider_descriptor.dart';
import 'provider_gateway.dart';

/// 插件网关。一个实例只服务一个平台。
class PluginGateway implements ProviderGateway {
  PluginGateway({
    required this.descriptor,
    required this.bridge,
    this.onDiagnostic,
    Map<String, String> cookies = const <String, String>{},
    this.onCookies,
  }) : _cookies = <String, String>{...cookies};

  /// 平台描述符（manifest 按 `descriptorFields` 白名单拷出来的那份）。
  final ProviderDescriptor descriptor;

  /// 诊断回调（面板上显示「插件返回 <原因>」时用，可空）。
  final void Function(String message)? onDiagnostic;

  /// 通道客户端（测试可注入假实现）。
  final PluginBridgeClient bridge;

  /// 最近一次 `loginBegin` 的令牌，`cancelLogin` 要带它（Qt 的 `previousKey`）。
  String _lastToken = '';

  /// 会话 cookie 罐（`name -> value`）：每次请求随行、每次响应回写。
  ///
  /// **必须是对象而不是 `Set-Cookie` 行数组**：`MusicBridge/core/host.cjs:8` 是
  /// `{...message.cookies}`，数组会被摊成 `{"0": "MUSIC_U=…"}`，于是插件永远
  /// 认为未登录（真机表现为扫码成功后 `account` 仍回「请登录网易云」）。
  final Map<String, String> _cookies;

  /// cookie 变更回调（宿主把它写进偏好）。
  final void Function(Map<String, String> cookies)? onCookies;

  @override
  String get providerId => descriptor.id;

  @override
  bool capability(String key, {bool fallback = true}) => descriptor.capability(key, fallback: fallback);

  @override
  bool operation(String key, {bool fallback = false}) => descriptor.operation(key, fallback: fallback);

  @override
  List<ProviderLoginMethod> get loginMethods => <ProviderLoginMethod>[
        for (final Map<String, Object?> entry in descriptor.loginMethods)
          ProviderLoginMethod.parse(entry, fallbackCooldownMs: descriptor.loginPollIntervalMs),
      ];

  /// 发一条请求并把失败变成异常（控制器会把它变成可见状态串）。
  ///
  /// `args` 必须是**位置参数数组**：`MusicBridge/worker.cjs:70` 调的是
  /// `plugin.dispatchNative(operation, args)`，而插件侧
  /// （`/tmp/plug/netease/plugin.cjs` 的 `dispatchNative`）执行
  /// `method.apply(api, args)`，传对象会被当成「一个参数」导致上游 400。
  Future<Map<String, Object?>> _call(
    String operation, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final PluginBridgeReply reply = await _request(operation, args);
    return reply.map;
  }

  /// 与 [_call] 相同，但保留 `body.value` 的原始形状（`categories` 这类操作
  /// 返回的是数组而不是对象，`reply.map` 会把它折成空表）。
  Future<PluginBridgeReply> _request(
    String operation, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final PluginBridgeReply reply =
        await bridge.request(descriptor.id, operation, args, _cookies);
    if (reply.cookies.isNotEmpty && _applyCookies(reply.cookies)) {
      onCookies?.call(<String, String>{..._cookies});
    }
    if (!reply.ok) {
      onDiagnostic?.call(reply.error);
      throw ProviderRequestError('${descriptor.name}：${reply.error}');
    }
    return reply;
  }

  @override
  Future<ProviderAccount> account() async {
    // 未登录时插件会用非 200 回「未登录」类错误；Qt 的 `MusicAccount` 对 `account`
    // 的失败是**非致命**的（只是拿不到昵称），所以这里不抛，回一个未登录账号。
    final Map<String, Object?> value;
    try {
      value = await _call('account');
    } on ProviderRequestError {
      return const ProviderAccount();
    }
    final Object? nested = value['account'];
    final Map<String, Object?> source = nested is Map
        ? nested.map((Object? key, Object? item) => MapEntry<String, Object?>('$key', item))
        : value;
    return ProviderAccount(
      id: _text(source['id'] ?? source['uid'] ?? source['userId'] ?? source['accountId']),
      nickname: _text(source['nickname'] ?? source['name'] ?? source['userName']),
      vipLevel: _text(source['vipLevel'] ?? source['vip'] ?? 'unknown'),
    );
  }

  @override
  Future<ProviderLoginSession> beginLogin(String method) async {
    final Map<String, Object?> value = await _call('loginBegin', <Object?>[method]);
    final String token = _text(value['token'] ?? value['qrKey'] ?? value['key']);
    _lastToken = token;
    return ProviderLoginSession(
      token: token,
      qrText: _text(value['qrText'] ?? value['qr'] ?? value['url']),
      qrImage: _text(value['qrImage'] ?? value['image']),
      pollIntervalMs: value['pollIntervalMs'] is num
          ? (value['pollIntervalMs'] as num).toInt()
          : descriptor.loginPollIntervalMs,
    );
  }

  @override
  Future<ProviderLoginPoll> pollLogin(String token) async {
    final Map<String, Object?> value =
        await _call('loginPoll', <Object?>[token.isEmpty ? _lastToken : token]);
    return ProviderLoginPoll(
      status: _text(value['status'] ?? 'waiting'),
      code: _text(value['code']),
      message: _text(value['message']),
      accountId: _text(value['accountId'] ?? value['uid']),
      nickname: _text(value['nickname']),
    );
  }

  @override
  Future<void> cancelLogin() async {
    if (_lastToken.isEmpty) {
      return;
    }
    try {
      await _call('loginCancel');
    } on ProviderRequestError {
      // 取消失败不影响本地状态：Qt 的 cancelLogin 也不回报错误。
    }
    _lastToken = '';
  }

  @override
  Future<void> sendLoginCode(String phone, String method) async {
    await _call('loginSms', <Object?>[phone]);
  }

  @override
  Future<void> submitLoginCode(String phone, String code, String method) async {
    await _call('loginSubmit', <Object?>[phone, code]);
  }

  @override
  Future<void> logout() async {
    // 插件没有独立的 logout 路由（Qt 侧退出登录是 host->logout() 清凭据 + 清列表）。
    await cancelLogin();
  }

  @override
  Future<ProviderCommentPage> comments({
    required String trackId,
    required ProviderCommentSort sort,
    required int page,
    String cursor = '',
  }) async {
    // 插件签名 `comments(track, id, sort, page, cursor)`。
    final Map<String, Object?> value =
        await _call('comments', <Object?>[trackId, trackId, sort.id, page, cursor]);
    final List<Object?> raw = value['comments'] is List ? value['comments'] as List<Object?> : const <Object?>[];
    return ProviderCommentPage(
      comments: <ProviderComment>[for (final Object? item in raw) _comment(item)],
      totalCount: value['total'] is num ? (value['total'] as num).toInt() : 0,
      hasMore: value['more'] == true,
      cursor: _text(value['cursor']),
    );
  }

  @override
  Future<ProviderRepliesPage> replies({required String commentId, required int page}) async {
    // 插件签名 `commentReplies(track, id, parentCommentId, cursor, limit)`；
    // 详情页回复只需要父评论 id，曲目上下文由插件按 commentID 自行解析。
    final Map<String, Object?> value =
        await _call('commentReplies', <Object?>[null, null, commentId, '-1', 20]);
    final List<Object?> raw = value['comments'] is List ? value['comments'] as List<Object?> : const <Object?>[];
    return ProviderRepliesPage(
      comments: <ProviderComment>[for (final Object? item in raw) _comment(item)],
      hasMore: value['more'] == true,
      timeLabel: _text(value['time']),
    );
  }

  @override
  Future<List<ProviderMvVersion>> mvVersions({required String trackId}) async {
    // 插件签名 `mvVersions(value)`，`value.id` 必须是曲目 id 字符串。
    final Map<String, Object?> value =
        await _call('mvVersions', <Object?>[<String, Object?>{'id': trackId}]);
    // 插件回 `{versions:[…], warning:''}`；旧实现只认 `items`，永远读成空表。
    final Object? versionSource = value['versions'] ?? value['items'];
    final List<Object?> raw = versionSource is List ? versionSource : const <Object?>[];
    return <ProviderMvVersion>[
      for (final Object? item in raw)
        if (item is Map)
          ProviderMvVersion(
            id: _text(item['id']),
            title: _text(item['title'] ?? item['name']),
            artist: _text(item['artist']),
            associated: item['associated'] == true,
          ),
    ];
  }

  @override
  Future<ProviderMvTrack> mv({required String trackId, required String versionId}) async {
    // 插件签名 `mv(value)`：`value.id` 是**曲目** id，`value.videoID` 才是版本 id；
    // 只给一个 id 会被当成曲目 id 去查 `/song/detail`，报「歌曲标识无效」。
    final Map<String, Object?> value = await _call(
      'mv',
      <Object?>[<String, Object?>{'id': trackId, 'videoID': versionId}],
    );
    return ProviderMvTrack(
      id: _text(value['id'] ?? versionId),
      title: _text(value['title']),
      url: _text(value['url'] ?? value['src']),
      resolution: value['resolution'] is num ? (value['resolution'] as num).toInt() : 0,
    );
  }

  @override
  Future<String> playback({
    required String trackId,
    String quality = '',
    bool alternative = false,
  }) async {
    // 插件签名 `playback(value, quality, alternative)`（`plugin.cjs` 里
    // `async playback(value, quality, alternative, valid)`）：只传 value 会让
    // `level=undefined`，上游一律回「暂无可用音源」。
    final String level = quality.isNotEmpty ? quality : descriptor.qualityDefault;
    final Map<String, Object?> value = await _call('playback', <Object?>[
      <String, Object?>{'id': trackId},
      level,
      alternative,
    ]);
    return _text(value['url'] ?? value['src'] ?? value['source']);
  }

  /// 歌词（插件签名 `lyrics(track)`，第一个位置参数就是整条 track）。
  ///
  /// 返回的是插件原样的 lyrics-format 文档；`lines[].translation` 在插件侧就
  /// 已经拆好（网易云的 tlyric 合并、酷狗的逐行译文），这里不再解析。
  @override
  Future<Map<String, Object?>> lyricsByTrack(Map<String, Object?> track) async {
    final Map<String, Object?> value =
        await _call('lyrics', <Object?>[track]);
    return value;
  }

  @override
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  }) async {
    // 插件签名 `search(text, kind, offset)`。
    final Map<String, Object?> value = await _call('search', <Object?>[query, kind.id, start]);
    final List<Object?> raw = value['items'] is List ? value['items'] as List<Object?> : const <Object?>[];
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map) item.map((Object? key, Object? value) => MapEntry<String, Object?>('$key', value)),
    ];
  }

  @override
  Future<List<String>> discoverCategories() async {
    final PluginBridgeReply reply = await _request('categories', const <Object?>[]);
    final Object? value = reply.value;
    if (value is! List) {
      return const <String>[];
    }
    return <String>[
      for (final Object? row in value)
        if (row is Map && '${row['name'] ?? row['id'] ?? ''}'.isNotEmpty)
          '${row['name'] ?? row['id']}',
    ];
  }

  @override
  Future<Map<String, Object?>> discover({
    required String tab,
    int start = 0,
    String category = '',
    String area = '',
  }) {
    // 位置参数：插件签名 `discover(tab, start, category)`（Qt
    // `MusicDiscover.cpp:52-55` 第三个参数在 `new-songs` 下换成曲风区）。
    return _call('discover', <Object?>[tab, start, tab == 'new-songs' ? area : category]);
  }

  @override
  Future<List<String>> likedTrackIds({String uid = ''}) async {
    // 插件签名 `likedIDs(uid)`：uid 空串时插件用会话里的账号（真机验证过，
    // 传账号 id 或空串都能拿到同一份列表）。
    final List<Object?> raw = await _callList('likedIDs', <Object?>[uid]);
    return <String>[for (final Object? id in raw) _text(id)];
  }

  @override
  Future<List<Map<String, Object?>>> userPlaylists({String uid = ''}) async {
    final Map<String, Object?> value = await _call('userPlaylists', <Object?>[uid]);
    final List<Object?> raw = value['items'] is List ? value['items'] as List<Object?> : const <Object?>[];
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map) item.map((Object? key, Object? value) => MapEntry<String, Object?>('$key', value)),
    ];
  }

  @override
  Future<List<String>> likedState(List<String> trackIds) async {
    // 插件签名 `likedState(ids, uid)`：返回已喜欢的 id 列表（Qt 把它当集合用）。
    final List<Object?> raw = await _callList('likedState', <Object?>[trackIds, '']);
    return <String>[for (final Object? id in raw) _text(id)];
  }

  @override
  Future<bool> setTrackLiked({required String trackId, required bool liked}) async {
    // 插件签名 `mutate(route, values)`；Qt 的 `/like` 语义见 `MusicMutation.cpp:337`。
    final Map<String, Object?> value = await _call('mutate', <Object?>[
      '/like',
      <String, Object?>{'id': trackId, 'like': liked},
    ]);
    final String state = _text(value['state']);
    if (state.isNotEmpty) {
      return state == 'subscribed';
    }
    return liked;
  }

  @override
  Future<Map<String, Object?>> mutate(String route, Map<String, Object?> values) async {
    final Map<String, Object?>? value = await _call('mutate', <Object?>[route, values]);
    return value ?? const <String, Object?>{};
  }

  Future<List<Map<String, Object?>>> detailSongs(Map<String, Object?> item) async {
    final List<Object?> value = await _callList('detail', <Object?>[item]);
    if (value.length < 2 || value[1] is! List) {
      return const <Map<String, Object?>>[];
    }
    return <Map<String, Object?>>[
      for (final Object? row in value[1] as List)
        if (row is Map) Map<String, Object?>.from(row),
    ];
  }

  Future<List<Map<String, Object?>>> songsByIds(List<String> ids) async {
    // 插件签名 `songs(ids, valid)`：`body.value` **直接是数组**（不是 `items` 包一层，
    // 真机探针 `{"id":1,"body":{"code":200,"value":[{...}]}}` 确认）。
    final List<Object?> raw = await _callList('songs', <Object?>[ids]);
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map) item.map((Object? key, Object? value) => MapEntry<String, Object?>('$key', value)),
    ];
  }

  /// 歌曲百科：插件 `wiki(id, valid)` 的 `body.value` 是**纯文本**（真机确认），
  /// 不是对象；这里包成 `{'text': …}`，空值也保留空串让页面显示诚实状态。
  @override
  Future<Map<String, Object?>> wiki({required String trackId}) async {
    final PluginBridgeReply reply =
        await _request('wiki', <Object?>[trackId]);
    final Object? value = reply.value;
    if (value is Map) {
      return value.map((Object? key, Object? item) => MapEntry<String, Object?>('$key', item));
    }
    return <String, Object?>{'text': _text(value)};
  }

  /// 专辑信息：插件没有独立 `album` operation（真机回「插件不支持该接口：album」），
  /// 用 `detail({kind:'album', id})` 的 `[item, songs, ids]` 组装。
  @override
  Future<Map<String, Object?>> albumInfo({required String albumId}) async {
    final String id = albumId.trim();
    if (id.isEmpty) {
      throw const ProviderRequestError('专辑 id 为空');
    }
    final String key = '$providerId:album:$id';
    final PluginBridgeReply reply = await _request('detail', <Object?>[
      <String, Object?>{
        'provider': providerId,
        'kind': 'album',
        'id': id,
        'key': key,
        'title': '',
      },
    ]);
    final Object? value = reply.value;
    if (value is! List || value.isEmpty || value[0] is! Map) {
      throw ProviderRequestError('${descriptor.name}：没有返回专辑信息');
    }
    final Map<String, Object?> album = (value[0] as Map)
        .map((Object? key, Object? item) => MapEntry<String, Object?>('$key', item));
    final List<Map<String, Object?>> songs = value.length > 1 && value[1] is List
        ? <Map<String, Object?>>[
            for (final Object? row in value[1] as List)
              if (row is Map)
                row.map((Object? key, Object? item) => MapEntry<String, Object?>('$key', item)),
          ]
        : const <Map<String, Object?>>[];
    final List<String> ids = value.length > 2 && value[2] is List
        ? <String>[for (final Object? item in value[2] as List) _text(item)]
        : <String>[for (final Map<String, Object?> row in songs) _text(row['id'])];
    return <String, Object?>{'album': album, 'songs': songs, 'ids': ids};
  }

  /// 取「列表型」响应（`body.value` 直接是数组时）。
  Future<List<Object?>> _callList(String operation, List<Object?> args) async {
    final PluginBridgeReply reply =
        await bridge.request(providerId, operation, args, <String, String>{..._cookies});
    _applyCookies(reply.cookies);
    if (!reply.ok) {
      throw ProviderRequestError(reply.error);
    }
    final Object? value = reply.value;
    return value is List ? value : const <Object?>[];
  }

  /// 当前 cookie 罐（宿主首次打开登录页时回读持久化值用）。
  Map<String, String> get cookies => <String, String>{..._cookies};

  /// 把响应里的 `Set-Cookie` 行并进罐子；返回是否有变化。
  bool _applyCookies(List<String> lines) {
    bool changed = false;
    for (final String line in lines) {
      final RegExpMatch? match =
          RegExp(r'^\s*([^=;]+)=([^;]*)').firstMatch(line);
      if (match == null) {
        continue;
      }
      final String name = match.group(1)!.trim();
      final String value = match.group(2) ?? '';
      final bool expired = line.toLowerCase().contains('max-age=0');
      if (expired) {
        if (_cookies.remove(name) != null) {
          changed = true;
        }
        continue;
      }
      if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    return changed;
  }

  ProviderComment _comment(Object? raw) {
    final Map<String, Object?> item = raw is Map
        ? raw.map((Object? key, Object? value) => MapEntry<String, Object?>('$key', value))
        : const <String, Object?>{};
    final List<Object?> inline = item['inlineReplies'] is List
        ? item['inlineReplies'] as List<Object?>
        : const <Object?>[];
    return ProviderComment(
      id: _text(item['id']),
      content: _text(item['content'] ?? item['text']),
      nickname: _text(item['nickname'] ?? item['user']),
      avatarUrl: _absoluteUrl(_text(item['avatar'] ?? item['avatarUrl'])),
      // Qt `CommentsController.cpp:665` 把平台返回的毫秒时间戳换算成「刚刚/N 分钟前/
      // N 小时前/N 天前/yyyy-MM-dd」，不是把数字原样上屏（真机上曾显示 1709572042026）。
      timeLabel: _commentTimeLabel(item['time'] ?? item['timeLabel']),
      likedCount: item['liked'] is num ? (item['liked'] as num).toInt() : 0,
      replyCount: item['replyCount'] is num ? (item['replyCount'] as num).toInt() : 0,
      replyTo: _text(item['replyTo']),
      truncated: item['truncated'] == true,
      inlineReplies: <ProviderComment>[for (final Object? reply in inline) _comment(reply)],
      inlineMore: item['inlineMore'] == true,
    );
  }

  static String _text(Object? value) => value == null ? '' : '$value';

  /// 平台给的 `//host/path` 或 `http://host/path` 统一成可直接请求的绝对 URL。
  static String _absoluteUrl(String value) {
    if (value.isEmpty) {
      return '';
    }
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    return value;
  }

  /// 评论时间文案：`time` 是毫秒时间戳时按 Qt `CommentsController::relativeTime`
  /// 的六档换算；已经是字符串文案时原样返回（部分插件直接给格式化结果）。
  static String _commentTimeLabel(Object? raw) {
    final double? milliseconds = raw is num
        ? raw.toDouble()
        : (raw is String ? double.tryParse(raw) : null);
    if (milliseconds == null || !milliseconds.isFinite || milliseconds <= 0) {
      return _text(raw);
    }
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt());
    final Duration gap = DateTime.now().difference(time);
    if (gap.isNegative || gap.inMinutes < 1) {
      return '刚刚';
    }
    if (gap.inHours < 1) {
      return '${gap.inMinutes} 分钟前';
    }
    if (gap.inDays < 1) {
      return '${gap.inHours} 小时前';
    }
    if (gap.inDays < 30) {
      return '${gap.inDays} 天前';
    }
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }
}

/// 插件请求失败（`body.code != 200` 或传输错误）。
class ProviderRequestError implements Exception {
  const ProviderRequestError(this.message);

  final String message;

  @override
  String toString() => message;
}
