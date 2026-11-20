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
  Map<String, String> _cookies;

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
    final PluginBridgeReply reply =
        await bridge.request(descriptor.id, operation, args, _cookies);
    if (reply.cookies.isNotEmpty && _applyCookies(reply.cookies)) {
      onCookies?.call(<String, String>{..._cookies});
    }
    if (!reply.ok) {
      onDiagnostic?.call(reply.error);
      throw ProviderRequestError('${descriptor.name}：${reply.error}');
    }
    return reply.map;
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
    final List<Object?> raw = value['items'] is List ? value['items'] as List<Object?> : const <Object?>[];
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
  Future<ProviderMvTrack> mv({required String versionId}) async {
    final Map<String, Object?> value =
        await _call('mv', <Object?>[<String, Object?>{'id': versionId}]);
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
      avatarUrl: _text(item['avatar'] ?? item['avatarUrl']),
      timeLabel: _text(item['time'] ?? item['timeLabel']),
      likedCount: item['liked'] is num ? (item['liked'] as num).toInt() : 0,
      replyCount: item['replyCount'] is num ? (item['replyCount'] as num).toInt() : 0,
      replyTo: _text(item['replyTo']),
      truncated: item['truncated'] == true,
      inlineReplies: <ProviderComment>[for (final Object? reply in inline) _comment(reply)],
      inlineMore: item['inlineMore'] == true,
    );
  }

  static String _text(Object? value) => value == null ? '' : '$value';
}

/// 插件请求失败（`body.code != 200` 或传输错误）。
class ProviderRequestError implements Exception {
  const ProviderRequestError(this.message);

  final String message;

  @override
  String toString() => message;
}
