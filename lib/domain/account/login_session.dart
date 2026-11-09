/// Qt 账号登录域（MusicAccount.cpp / MusicLibrary.h / MusicApi.cpp）的 Dart 移植。
///
/// 对应 Qt 行号（1:1 契约）：
/// - 六阶段 loginPhase：MusicAccount.cpp:357 idle、:542 preparing、:588 waiting、
///   :654 confirming、:515 complete、:311/:465 failed。
/// - 六路径：:202 provider 白名单、:279/:414/:446 loginMethod、:201 kugouEdition、:562-564 QQ channel。
/// - 轮询与超时：:625-667（:626 上限 300、:631 schedule(1000)、:642 缺省码 800、:665 允许码）。
/// - 世代失效：:340-341、:352-354、:565、:630-634（MusicApi.cpp:90 的 valid 守卫）。
/// - 取消屏障：:343-379。
/// - 冷却读秒：:299-302、:308-341。
/// - 失败文案与诊断白名单：MusicAccount.cpp:9-58、MusicApi.cpp:26-58。
///
/// `status` 字段对应 Qt 的 `MusicLibrary::loginStatus`（账号面板文案）；Qt 里图书馆级的
/// `MusicLibrary::status`（例如"已登录，可读取我的音乐"）属于列表域，不在本文件承担。
///
/// 依赖只通过注入端口（transport/scheduler/qrRenderer/credentials/effects）引入，
/// 不 import bridge 或平台实现，便于在无设备环境下静态审查与替换。
///
/// 任务契约：本次只编写、不执行 flutter/dart test；RED/GREEN 均未执行。
library;

import 'dart:async';

/// Qt 六条登录路径的来源（MusicAccount.cpp:202 白名单）。
enum AccountProvider {
  netease('netease'),
  qq('qq'),
  kugou('kugou'),
  local('local'),
  siren('siren');

  const AccountProvider(this.wire);

  /// 与 Qt 字符串常量一致的线上取值。
  final String wire;
}

/// Qt loginMethod（MusicAccount.cpp:279 初值 "qr"，:414/:446 置 "phone"）。
enum LoginMethod {
  qr('qr'),
  phone('phone'),
  wechat('wechat');

  const LoginMethod(this.wire);

  final String wire;
}

/// Qt kugouEdition（MusicAccount.cpp:201 白名单，MusicLibrary.cpp:107 lite 显示为概念版）。
enum KugouEdition {
  standard('standard'),
  lite('lite');

  const KugouEdition(this.wire);

  final String wire;
}

/// Qt loginPhase 字段；wire 即 Qt 字面量。
enum LoginPhase {
  idle('idle'),
  preparing('preparing'),
  waiting('waiting'),
  confirming('confirming'),
  complete('complete'),
  failed('failed');

  const LoginPhase(this.wire);

  final String wire;
}

/// Qt MusicApi::providerName（MusicApi.cpp:10-24）叠加 MusicLibrary::providerName
/// （MusicLibrary.cpp:106-111，酷狗概念版）。
String accountProviderName(AccountProvider provider, KugouEdition edition) =>
    switch (provider) {
      AccountProvider.local => '本地音乐',
      AccountProvider.qq => 'QQ 音乐',
      AccountProvider.kugou =>
        edition == KugouEdition.lite ? '酷狗概念版' : '酷狗音乐',
      AccountProvider.siren => '塞壬唱片',
      AccountProvider.netease => '网易云音乐',
    };

/// Qt MusicLibrary::accountKey（MusicLibrary.cpp:169-171）：酷狗带版本后缀。
String accountKeyOf(AccountProvider provider, KugouEdition edition) =>
    provider == AccountProvider.kugou ? 'kugou-${edition.wire}' : provider.wire;

/// 六条登录路径的定义表（MusicAccount.cpp:202 x :279/:414/:446 x :562-564）。
class LoginPath {
  const LoginPath({
    required this.id,
    required this.provider,
    required this.method,
    required this.edition,
    required this.usesSms,
    required this.qrChannel,
    required this.needsRemoteQrImage,
  });

  final String id;
  final AccountProvider provider;
  final LoginMethod method;
  final KugouEdition edition;

  /// 只有网易云手机号路径使用短信（:403/:433 的 `provider != "netease"` 守卫）。
  final bool usesSms;

  /// QQ 密钥请求里的 channel 参数；非 QQ 为 null（:562-564）。
  final String? qrChannel;

  /// 网易云本地渲染二维码（:593-596），QQ/酷狗走 /login/qr/create（:598-620）。
  final bool needsRemoteQrImage;

  /// 顺序即 Qt 白名单顺序，UI 与测试按索引对齐。
  static const List<LoginPath> all = <LoginPath>[
    LoginPath(
      id: 'netease/qr',
      provider: AccountProvider.netease,
      method: LoginMethod.qr,
      edition: KugouEdition.standard,
      usesSms: false,
      qrChannel: null,
      needsRemoteQrImage: false,
    ),
    LoginPath(
      id: 'netease/phone',
      provider: AccountProvider.netease,
      method: LoginMethod.phone,
      edition: KugouEdition.standard,
      usesSms: true,
      qrChannel: null,
      needsRemoteQrImage: false,
    ),
    LoginPath(
      id: 'qq/qq',
      provider: AccountProvider.qq,
      method: LoginMethod.qr,
      edition: KugouEdition.standard,
      usesSms: false,
      qrChannel: 'qq',
      needsRemoteQrImage: true,
    ),
    LoginPath(
      id: 'qq/wechat',
      provider: AccountProvider.qq,
      method: LoginMethod.wechat,
      edition: KugouEdition.standard,
      usesSms: false,
      qrChannel: 'wechat',
      needsRemoteQrImage: true,
    ),
    LoginPath(
      id: 'kugou/standard',
      provider: AccountProvider.kugou,
      method: LoginMethod.qr,
      edition: KugouEdition.standard,
      usesSms: false,
      qrChannel: null,
      needsRemoteQrImage: true,
    ),
    LoginPath(
      id: 'kugou/lite',
      provider: AccountProvider.kugou,
      method: LoginMethod.qr,
      edition: KugouEdition.lite,
      usesSms: false,
      qrChannel: null,
      needsRemoteQrImage: true,
    ),
  ];
}

/// Qt MusicReply 的最小投影：ok/error/failure/value。
class LoginResult {
  const LoginResult._(this.ok, this.data, this.error, this.failure);

  /// 成功；value 即 Qt result.value。
  const LoginResult.ok(Object? data)
      : this._(true, data, '', const <String, Object?>{});

  /// 失败；failure 即 Qt result.failure，error 即 Qt result.error。
  const LoginResult.failure(String error,
      {Map<String, Object?> failure = const <String, Object?>{}})
      : this._(false, null, error, failure);

  final bool ok;
  final Object? data;
  final String error;
  final Map<String, Object?> failure;

  /// Qt result.value.toObject()（非对象视为空对象）。
  Map<String, Object?> get body {
    final Object? value = data;
    if (value is Map) {
      return value.cast<String, Object?>();
    }
    return const <String, Object?>{};
  }

  /// Qt result.value.toArray()。
  List<Object?> get list {
    final Object? value = data;
    if (value is List) {
      return value;
    }
    return const <Object?>[];
  }
}

/// 传输端口：对应 MusicApi::request / MusicApi::call。
abstract class LoginTransport {
  /// 对应 MusicApi::request(route, parameters, allowed)：allowedCodes 为空时等价 {200}。
  Future<LoginResult> request(String route, Map<String, Object?> parameters,
      {Set<int>? allowedCodes});

  /// 对应 MusicApi::call("account")（MusicAccount.cpp:476）。
  Future<LoginResult> account();
}

/// 定时端口：对应 Host::schedule(delayMs, fn) 与 QDateTime::currentMSecsSinceEpoch()。
abstract class LoginScheduler {
  int nowMs();

  void schedule(int ms, void Function() callback);
}

/// 二维码端口：对应 Host::qr(key)（MusicAccount.cpp:594）与 Host::qrImage(data)（:613）。
abstract class QrRenderer {
  String render(String key);

  String renderImage(String dataUrl);
}

/// 凭据端口：对应 Host::saveCredential()/hasCredential()/logout() 与 PlatformAndroid 的
/// account.credential（Host.cpp:541-605、PlatformAndroid.cpp:10-46）。
abstract class CredentialPort {
  bool hasCredential(AccountProvider source);

  /// 返回空串表示写入成功，否则返回 Qt 的提示文案（Host.cpp:599-605）。
  String saveCredential();

  void deleteCredential();

  /// Qt Host::logout() 的分来源清理（Host.cpp:609-662）。
  void logoutSource(AccountProvider source, KugouEdition edition);
}

/// 账号域之外的双向副作用（Qt 里直接写在 MusicLibrary 内：:500-519）。
/// 列表、播放、QQ 能力刷新属于其它卡，因此以可替换实现注入。
class AccountEffects {
  const AccountEffects();

  /// MusicAccount.cpp:503-505 resetLikeState()。
  void resetLikedState() {}

  /// MusicAccount.cpp:508 rememberIdentityName()。
  void rememberIdentity(AccountProvider provider, String nickname) {}

  /// MusicAccount.cpp:510 refreshQQFeatures()。
  void refreshQqFeatures() {}

  /// MusicAccount.cpp:519 loadMoreSource(2)。
  void loadPersonalLanes() {}
}

/// 对应 MusicAccount.cpp:9-58 的失败文案表（顺序即 Qt 判定顺序）。
String loginFailureMessage(Map<String, Object?> details) {
  final Object? lastFailure = details['lastFailure'];
  final Map<String, Object?> failure =
      lastFailure is Map ? lastFailure.cast<String, Object?>() : details;
  final Object? primaryRaw = failure['primaryFailure'];
  final Map<String, Object?> primary =
      primaryRaw is Map ? primaryRaw.cast<String, Object?>() : const <String, Object?>{};
  final String primaryError = _text(primary['upstreamErrorKey']);
  final String upstreamError =
      primaryError.isNotEmpty ? primaryError : _text(failure['upstreamErrorKey']);
  if (_intOrNull(failure['upstreamCode']) == 20279 ||
      _intOrNull(primary['upstreamCode']) == 20279 ||
      upstreamError == 'auth.device-limit') {
    return '登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备';
  }
  if (_intOrNull(primary['upstreamCode']) == 50006) {
    return '请使用手机 QQ 扫描手机 QQ 通道二维码，再尝试登录';
  }
  if (upstreamError == 'auth.rate-limited' ||
      _intOrNull(primary['upstreamCode']) == 104604 ||
      _intOrNull(failure['upstreamCode']) == 104604) {
    return 'QQ 登录操作过于频繁，请等待冷却后重试';
  }
  const Map<String, String> restricted = <String, String>{
    'auth.account-restricted': '账号当前受限，请在 QQ 音乐客户端检查',
    'auth.account-banned': 'QQ 返回账号被封禁，请在官方客户端核实',
    'auth.account-binding': '账号绑定状态异常，请在 QQ 音乐客户端检查',
  };
  final String? mapped = restricted[upstreamError];
  if (mapped != null) {
    return mapped;
  }
  final String reason = _text(failure['failureReason']);
  if (reason == 'qr-timeout') {
    return '二维码已过期，请重新生成';
  }
  if (reason == 'user-canceled') {
    return '已取消扫码登录';
  }
  final String stage = _text(failure['failureStage']);
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
  if (_intOrNull(details['code']) == 429 || _text(details['failureReason']) == 'local-backoff') {
    return '扫码登录暂时冷却';
  }
  if (_intOrNull(details['code']) == 401) {
    return 'QQ 登录已失效，请重新扫码';
  }
  return _intOrNull(details['code']) == 800 ? '二维码会话已失效或登录失败，请重新生成' : '扫码登录失败，请稍后重试';
}

/// 对应 MusicApi::safeFailure(body, true)（MusicApi.cpp:26-58）：只保留白名单诊断字段，
/// 避免把 cookie 之类的敏感内容带进日志或 UI。
Map<String, Object?> safeLoginFailure(Map<String, Object?> body) => _safeFailure(body, true);

/// 对应 MusicApi::safeFailure：诊断字段白名单 + 递归 lastFailure/primaryFailure。
Map<String, Object?> _safeFailure(Map<String, Object?> body, bool includePrevious) {
  const List<String> texts = <String>[
    'failureStage',
    'failureReason',
    'errorKey',
    'upstreamErrorKey',
  ];
  const List<String> numbers = <String>[
    'code',
    'retryAfterMs',
    'upstreamHttpStatus',
    'upstreamCode',
    'upstreamGlobalCode',
    'upstreamSubCode',
  ];
  const List<String> booleans = <String>['retryable', 'writeAttempted'];
  final Map<String, Object?> result = <String, Object?>{};
  for (final String name in texts) {
    final Object? value = body[name];
    if (value is String && _diagnostic.hasMatch(value)) {
      result[name] = value;
    }
  }
  for (final String name in numbers) {
    final Object? value = body[name];
    if (value is num && value.isFinite) {
      result[name] = value;
    }
  }
  if (includePrevious) {
    for (final String name in const <String>['lastFailure', 'primaryFailure']) {
      final Object? nested = body[name];
      if (nested is Map) {
        result[name] = _safeFailure(nested.cast<String, Object?>(), false);
      }
    }
  }
  for (final String name in booleans) {
    final Object? value = body[name];
    if (value is bool) {
      result[name] = value;
    }
  }
  if (body['verification'] == 'unconfirmed') {
    result['verification'] = 'unconfirmed';
  }
  if (body['authExpired'] == true) {
    result['authExpired'] = true;
  }
  return result;
}

final RegExp _diagnostic = RegExp(r'^[a-z.-]{1,80}$');
final RegExp _qrDataUrl = RegExp(r'^data:image/(png|jpeg|gif|webp);base64,');

String _text(Object? value) => value is String ? value : '';

int? _intOrNull(Object? value) {
  if (value is num && value.isFinite) {
    return value.toInt();
  }
  return null;
}

class _Cooldown {
  const _Cooldown(this.deadline, this.message, this.token);

  final int deadline;
  final String message;
  final int token;
}

class _Cancellation {
  final List<void Function(bool cancelled)> waiters = <void Function(bool cancelled)>[];
}

/// 登录状态机（MusicAccount.cpp:299-667 的账号部分）。
class LoginSession {
  LoginSession({
    required this.transport,
    required this.scheduler,
    required this.qrRenderer,
    required this.credentials,
    this.effects = const AccountEffects(),
  });

  final LoginTransport transport;
  final LoginScheduler scheduler;
  final QrRenderer qrRenderer;
  final CredentialPort credentials;
  final AccountEffects effects;

  /// MusicAccount.cpp:626 的 300 次上限。
  static const int pollLimit = 300;

  /// MusicAccount.cpp:631 的 1000 ms 轮询间隔。
  static const int pollIntervalMs = 1000;

  /// MusicAccount.cpp:665 的允许码。
  static const Set<int> pollCodes = <int>{800, 801, 802, 803};

  /// MusicAccount.cpp:418 的 60 秒短信重发间隔。
  static const int smsResendIntervalMs = 60000;

  static const Set<int> _okCodes = <int>{200};

  /// MusicLibrary.h:161；:220 换来源时按白名单设置。
  AccountProvider provider = AccountProvider.netease;

  /// MusicLibrary.h:162 kugouEdition。
  KugouEdition edition = KugouEdition.standard;

  /// MusicLibrary.h:175 loginMethod，初值 "qr"。
  LoginMethod method = LoginMethod.qr;

  /// MusicLibrary.h:163 uid。
  String uid = '';

  /// MusicLibrary.h:164 nickname，未登录为"未登录"。
  String nickname = '未登录';

  /// MusicLibrary.h:171 qr。
  String qr = '';

  /// MusicLibrary.h:172 qrKey。
  String qrKey = '';

  /// MusicLibrary.h:173 loginStatus（账号面板文案）。
  String status = '';

  /// MusicLibrary.h:174 loginPhase，初值 "idle"。
  LoginPhase phase = LoginPhase.idle;

  /// MusicLibrary.h:176 loginDiagnostics。
  Map<String, Object?> diagnostics = <String, Object?>{};

  /// MusicLibrary.h:177 accountLoading。
  bool loading = false;

  /// MusicLibrary.h:103 accountGeneration()。
  int get accountGeneration => _accountGeneration;

  int _accountGeneration = 0;
  int _loginGeneration = 0;
  int _cooldownGeneration = 0;
  int _smsRetryAtMs = 0;
  final Map<AccountProvider, _Cooldown> _cooldowns = <AccountProvider, _Cooldown>{};
  final Map<AccountProvider, _Cancellation> _cancellations = <AccountProvider, _Cancellation>{};
  final List<void Function()> _listeners = <void Function()>[];

  /// 对应 Qt changed() 信号；UI 层订阅。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  bool _isCurrent(int token) => token == _loginGeneration;

  /// MusicAccount.cpp:299-302。
  int loginRetrySeconds() {
    final _Cooldown? cooldown = _cooldowns[provider];
    if (cooldown == null) {
      return 0;
    }
    return _secondsUntil(cooldown.deadline);
  }

  /// MusicAccount.cpp:381-384。
  int smsRetrySeconds() => _secondsUntil(_smsRetryAtMs);

  int _secondsUntil(int deadline) {
    final int remaining = deadline - scheduler.nowMs();
    final int seconds = (remaining + 999) ~/ 1000;
    return seconds > 0 ? seconds : 0;
  }

  /// MusicAccount.cpp:304-306。
  bool canRegenerateLogin() =>
      loginRetrySeconds() == 0 &&
      phase != LoginPhase.preparing &&
      phase != LoginPhase.confirming;

  /// MusicAccount.cpp:525-558。
  void startLogin() {
    if (provider == AccountProvider.local || provider == AccountProvider.siren) {
      return;
    }
    if (!canRegenerateLogin()) {
      final int seconds = loginRetrySeconds();
      if (seconds > 0) {
        phase = LoginPhase.failed;
        status = '${_cooldowns[provider]!.message}（请等待 $seconds 秒）';
        _notify();
      }
      return;
    }
    cancelLogin();
    final int token = ++_loginGeneration;
    phase = LoginPhase.preparing;
    diagnostics = <String, Object?>{};
    status = '准备二维码…';
    qr = '';
    loading = true;
    _notify();
    _waitCancellation(provider, (bool cancelled) {
      if (!_isCurrent(token)) {
        return;
      }
      if (!cancelled) {
        failLogin(const LoginResult.failure('旧二维码取消失败，请稍后重试'));
        return;
      }
      unawaited(_prepareQr(token));
    });
  }

  /// MusicAccount.cpp:560-623。
  Future<void> _prepareQr(int token) async {
    final Map<String, Object?> parameters = <String, Object?>{'timestamp': scheduler.nowMs()};
    if (provider == AccountProvider.qq) {
      parameters['channel'] = method == LoginMethod.wechat ? 'wechat' : 'qq';
    }
    final LoginResult result =
        await transport.request('/login/qr/key', parameters, allowedCodes: _okCodes);
    if (!_isCurrent(token)) {
      return;
    }
    if (!result.ok) {
      failLogin(result);
      return;
    }
    final Map<String, Object?> body = result.body;
    Object? key = body['unikey'];
    if (key == null) {
      final Object? nested = body['data'];
      key = nested is Map ? nested['unikey'] : null;
    }
    if (key is! String) {
      failLogin(const LoginResult.failure('二维码生成失败'));
      return;
    }
    qrKey = key;
    if (provider == AccountProvider.netease) {
      qr = qrRenderer.render(qrKey);
      _ready(token);
      return;
    }
    final LoginResult image = await transport.request(
      '/login/qr/create',
      <String, Object?>{'key': qrKey, 'qrimg': true, 'timestamp': scheduler.nowMs()},
      allowedCodes: _okCodes,
    );
    if (!_isCurrent(token)) {
      return;
    }
    if (!image.ok) {
      failLogin(image);
      return;
    }
    final Object? data = image.body['data'];
    final String dataUrl = data is Map ? _text(data['qrimg']) : '';
    if (!_qrDataUrl.hasMatch(dataUrl)) {
      failLogin(LoginResult.failure('${accountProviderName(provider, edition)}二维码格式无效'));
      return;
    }
    qr = qrRenderer.renderImage(dataUrl);
    if (qr.isEmpty) {
      failLogin(LoginResult.failure('${accountProviderName(provider, edition)}二维码读取失败'));
      return;
    }
    _ready(token);
  }

  /// MusicAccount.cpp:583-592 的 ready 闭包。
  void _ready(int token) {
    String scanner = accountProviderName(provider, edition);
    if (provider == AccountProvider.qq) {
      scanner = method == LoginMethod.wechat ? '微信' : '手机 QQ';
    }
    phase = LoginPhase.waiting;
    status = '请用$scanner扫描并确认登录';
    _notify();
    _pollQr(token, 0);
  }

  /// MusicAccount.cpp:625-667。
  void _pollQr(int token, int count) {
    if (count >= pollLimit) {
      failLogin(const LoginResult.failure('二维码超时，请重新生成'));
      return;
    }
    scheduler.schedule(pollIntervalMs, () {
      if (!_isCurrent(token)) {
        return;
      }
      unawaited(_pollTick(token, count));
    });
  }

  /// 与 Qt 私有 pollQR 同形的测试入口：直接以给定 count 进入轮询分支，
  /// 无需等待 300 次真实计时（契约仍由 pollLimit 常量约束）。
  void debugPollQr(int count) => _pollQr(_loginGeneration, count);

  Future<void> _pollTick(int token, int count) async {
    final LoginResult result = await transport.request(
      '/login/qr/check',
      <String, Object?>{'key': qrKey, 'timestamp': scheduler.nowMs()},
      allowedCodes: pollCodes,
    );
    if (!_isCurrent(token)) {
      return;
    }
    if (!result.ok) {
      failLogin(result);
      return;
    }
    final Map<String, Object?> body = result.body;
    final int code = _intOrNull(body['code']) ?? 800;
    if (code == 800) {
      qr = '';
      loading = false;
      if (provider == AccountProvider.qq) {
        reportLoginFailure(body);
      } else {
        failLogin(const LoginResult.failure('二维码已过期，请重新生成'));
      }
      return;
    }
    if (code == 802) {
      phase = LoginPhase.confirming;
      status = '已扫描，请在手机上确认';
      _notify();
    }
    if (code == 803) {
      phase = LoginPhase.confirming;
      await _confirmLogin(token);
      return;
    }
    _pollQr(token, count + 1);
  }

  /// MusicAccount.cpp:475-523。
  Future<void> _confirmLogin(int token, [bool captcha = false]) async {
    final LoginResult result = await transport.account();
    if (!_isCurrent(token)) {
      return;
    }
    if (!result.ok) {
      if (captcha) {
        status = result.error;
        loading = false;
        _notify();
      } else {
        failLogin(result);
      }
      return;
    }
    final String error = credentials.saveCredential();
    if (!_isCurrent(token)) {
      return;
    }
    if (error.isNotEmpty) {
      if (captcha) {
        status = error;
        loading = false;
        _notify();
      } else {
        failLogin(LoginResult.failure(error));
      }
      return;
    }
    _accountGeneration++;
    final List<Object?> values = result.list;
    final String nextUid = values.isNotEmpty ? _text(values[0]) : '';
    final String nextNickname = values.length > 1 ? _text(values[1]) : '';
    if (uid != nextUid) {
      effects.resetLikedState();
    }
    uid = nextUid;
    nickname = nextNickname;
    effects.rememberIdentity(provider, nickname);
    status = '已登录：$nickname';
    effects.refreshQqFeatures();
    if (!captcha) {
      qr = '';
      qrKey = '';
      phase = LoginPhase.complete;
      _cooldowns.remove(provider);
    }
    loading = false;
    effects.loadPersonalLanes();
    _notify();
  }

  /// MusicAccount.cpp:464-473。
  void failLogin(LoginResult result) {
    phase = LoginPhase.failed;
    loading = false;
    if (provider == AccountProvider.qq && result.failure.containsKey('code')) {
      reportLoginFailure(result.failure);
    } else {
      status = result.error;
      _notify();
    }
  }

  /// MusicAccount.cpp:308-320。
  void reportLoginFailure(Map<String, Object?> details, [String fallback = '']) {
    diagnostics = safeLoginFailure(details);
    final String message = fallback.isEmpty ? loginFailureMessage(details) : fallback;
    phase = LoginPhase.failed;
    status = message;
    final int retry = _intOrNull(details['retryAfterMs']) ?? 0;
    if (retry > 0) {
      final _Cooldown cooldown =
          _Cooldown(scheduler.nowMs() + retry, message, ++_cooldownGeneration);
      _cooldowns[provider] = cooldown;
      _updateLoginCooldown(provider, cooldown);
    }
    _notify();
  }

  /// MusicAccount.cpp:322-341：冷却中以墙钟读秒，并在仍为当前来源/阶段时刷新文案。
  void _updateLoginCooldown(AccountProvider source, _Cooldown cooldown) {
    final _Cooldown? current = _cooldowns[source];
    if (current == null || current.token != cooldown.token) {
      return;
    }
    final int remaining = cooldown.deadline - scheduler.nowMs();
    final int raw = (remaining + 999) ~/ 1000;
    final int seconds = raw > 0 ? raw : 0;
    if (source == provider && phase == LoginPhase.failed) {
      status = cooldown.message + (seconds > 0 ? '（请等待 $seconds 秒）' : '，可重新生成');
      _notify();
    }
    if (seconds > 0) {
      scheduler.schedule(pollIntervalMs, () {
        _updateLoginCooldown(source, cooldown);
      });
    }
  }

  /// MusicAccount.cpp:343-349。
  void _waitCancellation(AccountProvider source, void Function(bool cancelled) done) {
    final _Cancellation? pending = _cancellations[source];
    if (pending != null) {
      pending.waiters.add(done);
    } else {
      done(true);
    }
  }

  /// MusicAccount.cpp:352-379：取消旧二维码并建立完成屏障。
  void cancelLogin([void Function(bool cancelled)? done]) {
    final String previousKey = qrKey;
    _loginGeneration++;
    qrKey = '';
    qr = '';
    phase = LoginPhase.idle;
    loading = false;
    if (provider != AccountProvider.qq || previousKey.isEmpty) {
      if (done != null) {
        _waitCancellation(provider, done);
      }
      return;
    }
    final AccountProvider source = provider;
    final _Cancellation pending = _Cancellation();
    if (done != null) {
      pending.waiters.add(done);
    }
    _cancellations[source] = pending;
    unawaited(transport
        .request('/login/qr/cancel', <String, Object?>{'key': previousKey}, allowedCodes: _okCodes)
        .then((LoginResult result) {
      if (identical(_cancellations[source], pending)) {
        _cancellations.remove(source);
      }
      for (final void Function(bool cancelled) complete
          in List<void Function(bool cancelled)>.from(pending.waiters)) {
        complete(result.ok);
      }
    }));
  }
}
