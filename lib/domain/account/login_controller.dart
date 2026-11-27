/// 多平台登录状态机：Qt `MusicAccount.cpp` 登录流程的 Dart 移植。
///
/// 六阶段 + sms：startLogin / prepareQR / pollQR / confirmLogin / 取消与登出，
/// 冷却与失败文案逐条对照 Qt。
///
/// 依赖只有三个端口：PreferencePort、可注入 clock 与 delay。纯 Dart，不 import flutter。
///
/// 有意差异：open 只负责装载 descriptor 与当前账号（Qt 打开即扫码）；短信成功也进
/// complete；倒计时按需计算而不持有定时器。
library;

import 'dart:async';
import 'dart:math' as math;

import '../../provider/provider_descriptor.dart';
import '../../provider/provider_gateway.dart';
import '../player/music_player.dart' show PreferencePort;

/// Qt 登录阶段。wire 即 Qt 字面量（多一个 [sms]，见文件头差异 1/3）。
enum LoginPhase {
  idle('idle'),
  preparing('preparing'),
  waiting('waiting'),
  confirming('confirming'),
  sms('sms'),
  complete('complete'),
  failed('failed');

  const LoginPhase(this.wire);

  /// Qt 字面量。
  final String wire;
}

/// 登录面板的只读状态（对应 Qt `MusicLibrary` 的 login* 字段集合）。
class LoginState {
  const LoginState({
    this.provider = '',
    this.methodId = '',
    this.phase = LoginPhase.idle,
    this.status = '',
    this.qrText = '',
    this.qrImage = '',
    this.token = '',
    this.nickname = '',
    this.accountId = '',
    this.loading = false,
    this.canRegenerateAt,
    this.smsRetryAt,
    this.message = '',
  });

  /// 当前平台 id（descriptor 的 `id`）。
  final String provider;

  /// 当前登录方式 id（Qt `loginMethod`）。
  final String methodId;

  /// 阶段（Qt `loginPhase`）。
  final LoginPhase phase;

  /// 面板文案（Qt `loginStatus`）：UI 直接画这一行。
  final String status;

  /// 二维码文本内容（Qt `qr` 的文本分支）。
  final String qrText;

  /// 二维码图片地址（Qt `qr` 的图片分支）。
  final String qrImage;

  /// 轮询令牌（Qt `qrKey`）。
  final String token;

  /// 已登录昵称（Qt `nickname`）。
  final String nickname;

  /// 已登录账号 id（Qt `accountID`）。
  final String accountId;

  /// 是否有请求在飞（Qt `accountLoading`）。
  final bool loading;

  /// 二维码冷却截止时刻（Qt `m_cooldowns[provider].deadline`）。
  final DateTime? canRegenerateAt;

  /// 短信重发冷却截止时刻（Qt `m_smsRetryAtMs`）。
  final DateTime? smsRetryAt;

  /// 最近一次失败的映射文案（Qt `loginDiagnostics` 的可读投影）。
  final String message;

  /// 是否已登录（Qt `accountID` 非空）。
  bool get loggedIn => accountId.isNotEmpty;

  /// 拷贝；`null` 语义由两个 clear 开关显式表达（Qt 清 qrKey 是显式动作，不是缺省）。
  LoginState copyWith({
    String? provider,
    String? methodId,
    LoginPhase? phase,
    String? status,
    String? qrText,
    String? qrImage,
    String? token,
    String? nickname,
    String? accountId,
    bool? loading,
    DateTime? canRegenerateAt,
    bool clearCanRegenerateAt = false,
    DateTime? smsRetryAt,
    bool clearSmsRetryAt = false,
    String? message,
  }) {
    return LoginState(
      provider: provider ?? this.provider,
      methodId: methodId ?? this.methodId,
      phase: phase ?? this.phase,
      status: status ?? this.status,
      qrText: qrText ?? this.qrText,
      qrImage: qrImage ?? this.qrImage,
      token: token ?? this.token,
      nickname: nickname ?? this.nickname,
      accountId: accountId ?? this.accountId,
      loading: loading ?? this.loading,
      canRegenerateAt:
          clearCanRegenerateAt ? null : (canRegenerateAt ?? this.canRegenerateAt),
      smsRetryAt: clearSmsRetryAt ? null : (smsRetryAt ?? this.smsRetryAt),
      message: message ?? this.message,
    );
  }
}

/// Qt 未声明手机号正则时的缺省（MusicAccount.cpp:425）。
const String kDefaultPhonePattern = r'^\d{6,15}$';

/// Qt 未声明验证码正则时的缺省（MusicAccount.cpp:463）。
const String kDefaultCodePattern = r'^[0-9]{4,8}$';

/// Qt `SMS_RESEND_INTERVAL_MS`（MusicAccount.cpp:441 附近的常量）。
const int kSmsResendIntervalMs = 60000;

/// 登录控制器：一个实例管一个平台的一次登录会话。
class LoginController {
  LoginController({
    required PreferencePort preferences,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  })  : _preferences = preferences, // ignore: prefer_initializing_formals
        _clock = clock ?? DateTime.now,
        _delay = delay ?? _defaultDelay;

  final PreferencePort _preferences;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  ProviderDescriptor? _descriptor;
  ProviderGateway? _gateway;
  LoginState _state = const LoginState();
  int _generation = 0;
  bool _closed = false;

  /// 当前变体 id（Qt `providerVariant`）。空串 = 平台没有变体。
  String _variant = '';
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前状态（不可变快照）。
  LoginState get state => _state;

  /// 当前平台的登录方式（未 [open] 时为空表）。
  List<ProviderLoginMethod> get methods {
    final ProviderDescriptor? descriptor = _descriptor;
    if (descriptor == null) {
      return const <ProviderLoginMethod>[];
    }
    return <ProviderLoginMethod>[
      for (final Map<String, Object?> method in descriptor.loginMethods)
        ProviderLoginMethod.parse(method),
    ];
  }

  /// Qt `loginRetrySeconds()` :329-331：剩余秒数向上取整，下限 0。
  int get cooldownSeconds {
    final DateTime? deadline = _state.canRegenerateAt;
    if (deadline == null) {
      return 0;
    }
    final int remaining = deadline.difference(_clock()).inMilliseconds;
    // Qt 用 int 的 (remaining+999)/1000 向上取整；Dart 的 ~/ 是向下取整，负余数时必须分开处理。
    return math.max(0, (remaining + 999) ~/ 1000);
  }

  /// 剩余毫秒转秒的 Qt 口径（:330 `(remaining+999)/1000`）。
  static int _ceilSeconds(int remainingMs) {
    if (remainingMs <= 0) {
      return 0;
    }
    return (remainingMs + 999) ~/ 1000;
  }

  /// Qt `loginPanel` 在不能重新生成时显示的那一行（NativeHudLibrary.cpp:283-290）。
  ///
  /// 冷却中 → `请等待 N 秒后重新生成`；否则 → `正在处理扫码登录…`。
  /// 能重新生成时返回空串（那时应显示"重新生成二维码"按钮）。
  String get cooldownLabel {
    if (canRegenerate) {
      return '';
    }
    final int seconds = cooldownSeconds;
    if (seconds > 0) {
      return '请等待 $seconds 秒后重新生成';
    }
    return '正在处理扫码登录…';
  }

  /// Qt `canRegenerateLogin()` :334-337。
  bool get canRegenerate =>
      cooldownSeconds == 0 &&
      _state.phase != LoginPhase.preparing &&
      _state.phase != LoginPhase.confirming;

  /// Qt `smsRetrySeconds()` :404-407。
  int get smsRetrySeconds {
    final DateTime? deadline = _state.smsRetryAt;
    if (deadline == null) {
      return 0;
    }
    final int remaining = deadline.difference(_clock()).inMilliseconds;
    return _ceilSeconds(remaining);
  }

  /// 注册状态变更回调（UI 重绘用）。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 注销状态变更回调。
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void _set(LoginState next) {
    _state = next;
    _notify();
  }

  /// 装载平台（Qt 打开登录弹层时的那一步）。
  ///
  /// 只做数据面：descriptor、网关、可选方式、当前账号。**不自动开始扫码**，调用方按
  /// Qt `NativeHudMusic.cpp:405-437` 的顺序在扫码方式上再调 [start]。
  Future<void> open(
    ProviderDescriptor descriptor,
    ProviderGateway gateway, {
    String? methodId,
    String variant = '',
  }) async {
    _descriptor = descriptor;
    _gateway = gateway;
    _variant = variant.trim();
    _closed = false;
    _generation += 1; // 旧平台的轮询立即失效（Qt 每次 cancelLogin 都 ++m_loginGeneration）
    String method = methodId ?? descriptor.defaultLoginMethod;
    final ProviderLoginMethod? found = _findMethod(method);
    if (found == null) {
      method = descriptor.defaultLoginMethod;
    }
    _state = LoginState(
      provider: descriptor.id,
      methodId: method,
      phase: LoginPhase.idle,
    );
    _notify();
    try {
      final ProviderAccount account = await gateway.account();
      if (_closed) {
        return;
      }
      _set(_state.copyWith(
        nickname: account.nickname,
        accountId: account.id,
        phase: account.loggedIn ? LoginPhase.complete : _state.phase,
        status: account.loggedIn ? '已登录：${account.nickname}' : _state.status,
      ));
    } on ProviderUnavailableError catch (error) {
      _set(_state.copyWith(status: error.message, phase: LoginPhase.failed));
    } catch (_) {
      _set(_state.copyWith(status: '登录失败，请稍后重试', phase: LoginPhase.failed));
    }
  }

  /// 平台是否可登录（Qt `startLogin` 对 local/siren 直接 return，:549-551）。
  bool get _loginSupported {
    final ProviderDescriptor? descriptor = _descriptor;
    if (descriptor == null) {
      return false;
    }
    if (descriptor.id == 'local' || descriptor.id == 'siren') {
      return false;
    }
    return descriptor.capability('login', fallback: true);
  }

  ProviderLoginMethod? _findMethod(String id) {
    for (final ProviderLoginMethod method in methods) {
      if (method.id == id) {
        return method;
      }
    }
    return null;
  }

  /// 空表方法（Qt `smsLoginMethod` 线性查找，:45-53）。
  ProviderLoginMethod? get smsMethod {
    for (final ProviderLoginMethod method in methods) {
      if (method.type == 'sms') {
        return method;
      }
    }
    return null;
  }

  /// Qt `startLogin()` :549-575。
  Future<void> start() async {
    final ProviderDescriptor? descriptor = _descriptor;
    final ProviderGateway? gateway = _gateway;
    if (descriptor == null || gateway == null) {
      return;
    }
    if (!_loginSupported) {
      _set(_state.copyWith(
        phase: LoginPhase.failed,
        status: '${descriptor.name}不支持账号登录',
      ));
      return;
    }
    if (!canRegenerate) {
      final int seconds = cooldownSeconds;
      if (seconds > 0) {
        _set(_state.copyWith(
          phase: LoginPhase.failed,
          status: '${_state.message}（请等待 $seconds 秒）',
        ));
      }
      return;
    }
    _set(_state.copyWith(
      phase: LoginPhase.preparing,
      status: '准备二维码…',
      qrText: '',
      qrImage: '',
      token: '',
      loading: true,
      message: '',
    ));
    // Qt cancelLogin() 失败时不再往下走（:566-572）。
    try {
      await gateway.cancelLogin();
    } catch (_) {
      await _failResult(fallback: '旧二维码取消失败，请稍后重试');
      return;
    }
    final int token = _generation + 1;
    _generation = token;
    await _prepareQr(token);
  }

  /// Qt `prepareQR(token)` :577-620。
  Future<void> _prepareQr(int token) async {
    final ProviderDescriptor descriptor = _descriptor!;
    final ProviderGateway gateway = _gateway!;
    ProviderLoginSession session;
    try {
      session = await gateway.beginLogin(_state.methodId);
    } on ProviderUnavailableError catch (error) {
      if (_generation != token) {
        return;
      }
      await _reportFailure(<String, Object?>{}, fallback: error.message);
      return;
    } catch (_) {
      if (_generation != token) {
        return;
      }
      await _failResult(fallback: '登录失败，请稍后重试');
      return;
    }
    if (_generation != token || _closed) {
      return;
    }
    if (session.token.trim().isEmpty) {
      await _failResult(fallback: '二维码生成失败');
      return;
    }
    final String qrText = session.qrText;
    final String qrImage = session.qrImage;
    if (qrText.isEmpty && qrImage.isEmpty) {
      await _failResult(fallback: '${descriptor.name}二维码读取失败');
      return;
    }
    final String rawHint = descriptor.text('scanHint');
    final String hint = rawHint.isEmpty ? '请用${descriptor.name}扫描并确认登录' : rawHint;
    _set(_state.copyWith(
      phase: LoginPhase.waiting,
      status: hint,
      token: session.token,
      qrText: qrText,
      qrImage: qrImage,
      loading: false,
    ));
    await _pollQr(token, session.token, 0);
  }

  /// Qt `pollQR(token, count)` :625-667。
  Future<void> _pollQr(int token, String sessionToken, int count) async {
    final ProviderDescriptor descriptor = _descriptor!;
    final ProviderGateway gateway = _gateway!;
    // :626-629 — 夹取规则逐字照抄（间隔来自 descriptor 的 login.pollIntervalMs）。
    final int interval = _clampInt(descriptor.loginPollIntervalMs, 100, 60000);
    final int timeout = math.max(interval, descriptor.loginTimeoutMs);
    final int attempts = math.max(1, (timeout + interval - 1) ~/ interval);
    int index = count;
    while (true) {
      if (_generation != token || _closed) {
        return;
      }
      if (index >= attempts) {
        await _failResult(fallback: '二维码超时，请重新生成');
        return;
      }
      await _delay(Duration(milliseconds: interval));
      if (_generation != token || _closed) {
        return;
      }
      ProviderLoginPoll poll;
      try {
        poll = await gateway.pollLogin(sessionToken);
      } catch (_) {
        if (_generation != token) {
          return;
        }
        await _failResult(fallback: '登录失败，请稍后重试');
        return;
      }
      if (_generation != token || _closed) {
        return;
      }
      final String status = poll.status;
      // :642 — QString::toInt(800)：缺省/不可解析一律 800（Qt 视为过期）。
      final String code = poll.code.isEmpty ? '800' : poll.code;
      final Map<String, Object?> details = <String, Object?>{
        'failureReason': status,
        'code': _intValue(code, 800),
        if (poll.message.isNotEmpty) 'message': poll.message,
        if (poll.accountId.isNotEmpty) 'accountId': poll.accountId,
        if (poll.nickname.isNotEmpty) 'nickname': poll.nickname,
      };
      if (status == 'expired' || code == '800') {
        // :644-655 — 先清二维码与 loading，再按 failureMessages 分支报错。
        _set(_state.copyWith(
          qrText: '',
          qrImage: '',
          token: '',
          loading: false,
        ));
        if (descriptor.loginFailureMessages.isNotEmpty) {
          await _reportFailure(details);
        } else {
          await _failResult(fallback: '二维码已过期，请重新生成');
        }
        return;
      }
      if (status == 'scanned' || code == '802') {
        // :657-660 — Qt 这里不 return，继续同一轮轮询。
        _set(_state.copyWith(
          phase: LoginPhase.confirming,
          status: '已扫描，请在手机上确认',
        ));
      }
      if (status == 'confirmed' || code == '803') {
        // :662-665
        _set(_state.copyWith(phase: LoginPhase.confirming));
        await _confirmLogin(token, captcha: false, poll: poll);
        return;
      }
      index += 1;
    }
  }

  /// Qt `confirmLogin(token, captcha)` :505-547。
  Future<void> _confirmLogin(
    int token, {
    required bool captcha,
    ProviderLoginPoll? poll,
  }) async {
    final ProviderDescriptor descriptor = _descriptor!;
    final ProviderGateway gateway = _gateway!;
    ProviderAccount account;
    try {
      account = await gateway.account();
    } on ProviderUnavailableError catch (error) {
      if (_generation != token) {
        return;
      }
      _set(_state.copyWith(phase: LoginPhase.failed, loading: false, status: error.message));
      return;
    } catch (_) {
      if (_generation != token) {
        return;
      }
      await _failResult(fallback: '登录失败，请稍后重试');
      return;
    }
    if (_generation != token || _closed) {
      return;
    }
    if (!account.loggedIn) {
      // :512-520 — 扫码路径走 failLogin；短信路径只写错误串。
      if (captcha) {
        _set(_state.copyWith(loading: false, status: '登录失败，请稍后重试'));
      } else {
        await _failResult(fallback: '登录失败，请稍后重试');
      }
      return;
    }
    final String nickname = account.nickname.isEmpty
        ? (poll?.nickname ?? '')
        : account.nickname;
    final String accountId = account.id;
    // :531-534 rememberIdentityName：welcome-name-<key> 与 account-id-<key>。
    _rememberIdentity(descriptor, accountId, nickname);
    _set(_state.copyWith(
      phase: LoginPhase.complete,
      status: '已登录：$nickname',
      nickname: nickname,
      accountId: accountId,
      loading: false,
      clearCanRegenerateAt: true, // :543 m_cooldowns.remove(provider)
      qrText: '',
      qrImage: '',
      token: '',
    ));
  }

  /// Qt `rememberIdentityName` :57-62 的偏好写入部分。
  void _rememberIdentity(
    ProviderDescriptor descriptor,
    String accountId,
    String nickname,
  ) {
    final String key = _accountKey(descriptor);
    final String normalized = nickname.trim();
    if (normalized.isNotEmpty) {
      _preferences.write('welcome-name-$key', normalized);
    }
    if (accountId.isNotEmpty) {
      _preferences.write('account-id-$key', accountId);
    }
  }

  /// Qt 的账号键：平台上再加变体后缀（`provider-variant`）。
  /// 同一平台的标准版与轻量版各有独立账号，键里不带变体就会互相覆盖。
  String _accountKey(ProviderDescriptor descriptor) =>
      _variant.isEmpty ? descriptor.id : '${descriptor.id}-$_variant';

  /// Qt `reportLoginFailure(details, fallback)` :338-352 的公开入口。
  ///
  /// 网关把上游失败（`retryAfterMs`/`primaryFailure`/`failureReason`/`code`）交给 UI 时走这里；
  /// `details['retryAfterMs'] > 0` 会写入二维码冷却，之后 [start] 进入 "（请等待 N 秒）" 分支。
  Future<void> reportLoginFailure(Map<String, Object?> details, {String fallback = ''}) =>
      _reportFailure(details, fallback: fallback);

  /// Qt `failLogin(result)` :493-499。
  Future<void> _failResult({String fallback = ''}) =>
      _reportFailure(const <String, Object?>{}, fallback: fallback);

  /// Qt `reportLoginFailure(details, fallback)` :338-352。
  Future<void> _reportFailure(
    Map<String, Object?> details, {
    String fallback = '',
  }) async {
    final String message =
        fallback.isEmpty ? loginFailureMessage(details) : fallback;
    final int retryAfterMs = _intValue(details['retryAfterMs'], 0);
    final DateTime? deadline = retryAfterMs > 0
        ? _clock().add(Duration(milliseconds: retryAfterMs))
        : null;
    _set(_state.copyWith(
      phase: LoginPhase.failed,
      status: message,
      message: message,
      loading: false,
      canRegenerateAt: deadline,
    ));
  }

  /// Qt `loginFailureMessage(provider, details)` :10-43（候选键顺序逐字照抄）。
  String loginFailureMessage(Map<String, Object?> details) {
    final ProviderDescriptor? descriptor = _descriptor;
    final Map<String, String> messages =
        descriptor?.loginFailureMessages ?? const <String, String>{};
    final Map<String, Object?> failure = details['lastFailure'] is Map
        ? (details['lastFailure']! as Map).cast<String, Object?>()
        : details;
    final Map<String, Object?> primary = failure['primaryFailure'] is Map
        ? (failure['primaryFailure']! as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final int code = _intValue(
      failure['upstreamCode'],
      _intValue(primary['upstreamCode'], 0),
    );
    final List<String> candidates = <String>[
      _stringValue(primary['upstreamErrorKey'], _stringValue(failure['upstreamErrorKey'], '')),
      _stringValue(failure['failureReason'], ''),
      _stringValue(failure['failureStage'], ''),
      code != 0 ? 'upstream:$code' : '',
      'code:${_intValue(details['code'], 0)}',
    ];
    for (final String key in candidates) {
      if (key.isEmpty) {
        continue;
      }
      final String? message = messages[key];
      if (message != null) {
        return message;
      }
    }
    final String failureReason = _stringValue(failure['failureReason'], '');
    if (failureReason == 'qr-timeout') {
      return '二维码已过期，请重新生成';
    }
    if (failureReason == 'user-canceled') {
      return '已取消扫码登录';
    }
    if (_stringValue(details['failureReason'], '') == 'local-backoff' ||
        _intValue(details['code'], 0) == 429) {
      return '登录操作暂时冷却，请稍后重试';
    }
    if (_intValue(details['code'], 0) == 401) {
      return '登录已失效，请重新登录';
    }
    return '登录失败，请稍后重试';
  }

  /// Qt `sendLoginCode(phone)` :421-453。
  Future<void> sendCode(String phone) async {
    final ProviderDescriptor? descriptor = _descriptor;
    final ProviderGateway? gateway = _gateway;
    if (descriptor == null || gateway == null) {
      return;
    }
    final ProviderLoginMethod? method = smsMethod;
    // :425 — 没有 sms 方式 / 有请求在飞 / 冷却中，一律不动状态。
    if (method == null || _state.loading || smsRetrySeconds > 0) {
      return;
    }
    final String trimmed = phone.trim();
    final String pattern = _pattern(
      descriptor,
      method.id,
      'phonePattern',
      _stringValue(method.phonePattern, ''),
      kDefaultPhonePattern,
    );
    if (!_matches(pattern, trimmed)) {
      // :427-431
      _set(_state.copyWith(status: '请输入有效的手机号码'));
      return;
    }
    final int retryMs = _resendCooldownMs(descriptor, method);
    _set(_state.copyWith(
      phase: LoginPhase.sms,
      methodId: method.id.isEmpty ? 'sms' : method.id,
      status: '正在发送短信验证码…',
      loading: true,
      smsRetryAt: _clock().add(Duration(milliseconds: math.max(0, retryMs))),
    ));
    try {
      await gateway.sendLoginCode(trimmed, method.id);
    } on ProviderUnavailableError catch (error) {
      _set(_state.copyWith(loading: false, status: error.message));
      return;
    } catch (_) {
      _set(_state.copyWith(loading: false, status: '登录失败，请稍后重试'));
      return;
    }
    _set(_state.copyWith(
      loading: false,
      status: '验证码已发送，请查看手机短信',
    ));
  }

  /// Qt `captchaLogin(phone, captcha)` :455-491。
  Future<void> submitCode(String phone, String code) async {
    final ProviderDescriptor? descriptor = _descriptor;
    final ProviderGateway? gateway = _gateway;
    if (descriptor == null || gateway == null) {
      return;
    }
    final ProviderLoginMethod? method = smsMethod;
    if (method == null || _state.loading) {
      return;
    }
    final String trimmedPhone = phone.trim();
    final String trimmedCode = code.trim();
    final String phonePattern = _pattern(
      descriptor,
      method.id,
      'phonePattern',
      _stringValue(method.phonePattern, ''),
      kDefaultPhonePattern,
    );
    final String codePattern = _pattern(
      descriptor,
      method.id,
      'codePattern',
      _stringValue(method.codePattern, ''),
      kDefaultCodePattern,
    );
    if (!_matches(phonePattern, trimmedPhone) || !_matches(codePattern, trimmedCode)) {
      // :461-466
      _set(_state.copyWith(status: '请输入手机号码和短信验证码'));
      return;
    }
    final int token = _generation + 1;
    _generation = token;
    _set(_state.copyWith(
      phase: LoginPhase.sms,
      methodId: method.id.isEmpty ? 'sms' : method.id,
      status: '正在登录…',
      loading: true,
      qrText: '',
      qrImage: '',
      token: '',
    ));
    try {
      await gateway.submitLoginCode(trimmedPhone, trimmedCode, method.id);
    } on ProviderUnavailableError catch (error) {
      _set(_state.copyWith(loading: false, status: error.message));
      return;
    } catch (_) {
      _set(_state.copyWith(loading: false, status: '登录失败，请稍后重试'));
      return;
    }
    if (_generation != token) {
      return;
    }
    await _confirmLogin(token, captcha: true);
  }

  /// 重新生成二维码（Qt 动作 `music:qr` → `startLogin()`）。
  Future<void> regenerate() => start();

  /// 切换登录方式（Qt `login-method:<id>` 分支，NativeHudMusic.cpp:414-446）。
  Future<void> chooseMethod(String methodId) async {
    final ProviderDescriptor? descriptor = _descriptor;
    final ProviderGateway? gateway = _gateway;
    if (descriptor == null || gateway == null) {
      return;
    }
    final ProviderLoginMethod? method = _findMethod(methodId);
    if (method == null) {
      return;
    }
    try {
      await gateway.cancelLogin();
    } catch (_) {
      // Qt 的 login-method 分支不看 cancel 结果，这里同样忽略。
    }
    _generation += 1;
    final bool qr = method.type == 'qr' || method.id == 'qr' || method.id == 'wechat';
    _set(_state.copyWith(
      methodId: method.id,
      phase: qr ? LoginPhase.idle : LoginPhase.sms,
      status: '',
      qrText: '',
      qrImage: '',
      token: '',
      loading: false,
      clearCanRegenerateAt: qr,
      clearSmsRetryAt: !qr,
    ));
    if (qr) {
      await start();
    }
  }

  /// Qt `cancelLogin()` :374-400（清二维码/令牌，阶段回 idle）。
  Future<void> cancel() async {
    final ProviderGateway? gateway = _gateway;
    _generation += 1;
    _set(_state.copyWith(
      phase: LoginPhase.idle,
      qrText: '',
      qrImage: '',
      token: '',
      loading: false,
    ));
    if (gateway == null) {
      return;
    }
    try {
      await gateway.cancelLogin();
    } catch (_) {
      // Qt 的 cancel 只把 ok 交给调用方；本控制器不据此改变状态。
    }
  }

  /// Qt `logout()` :676-726 的账号部分（播放/列表副作用属于调用方）。
  Future<void> logout() async {
    final ProviderDescriptor? descriptor = _descriptor;
    final ProviderGateway? gateway = _gateway;
    if (descriptor == null || gateway == null) {
      return;
    }
    if (!_loginSupported) {
      return;
    }
    await cancel();
    try {
      await gateway.logout();
    } catch (_) {
      // Qt 的 host->logout() 是本地动作，失败不改状态。
    }
    _generation += 1;
    _preferences.write('account-id-${_accountKey(descriptor)}', '');
    _set(_state.copyWith(
      phase: LoginPhase.idle,
      accountId: '',
      nickname: '未登录',
      status: '已退出登录',
      qrText: '',
      qrImage: '',
      token: '',
      loading: false,
      message: '',
      clearCanRegenerateAt: true,
      clearSmsRetryAt: true,
    ));
  }

  /// 关闭面板：让在飞的轮询立即失效，不触发网络取消（Qt 关闭弹层时不清 qrKey）。
  void close() {
    _closed = true;
    _generation += 1;
    _set(LoginState(
      provider: _state.provider,
      methodId: _state.methodId,
      phase: LoginPhase.idle,
      nickname: _state.nickname,
      accountId: _state.accountId,
      status: _state.status,
    ));
  }

  /// 读方法原始 map 里的 `flow.<key>`（Qt 的验证码正则与重发冷却都在 flow 里）。
  String _flowString(
    ProviderDescriptor descriptor,
    String methodId,
    String key,
  ) {
    final Map<String, Object?>? method = descriptor.loginMethod(methodId);
    final Object? flow = method?['flow'];
    if (flow is Map) {
      final Object? value = flow[key];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _pattern(
    ProviderDescriptor descriptor,
    String methodId,
    String key,
    String direct,
    String fallback,
  ) {
    if (direct.isNotEmpty) {
      return direct;
    }
    final String flow = _flowString(descriptor, methodId, key);
    if (flow.isNotEmpty) {
      return flow;
    }
    return fallback;
  }

  int _resendCooldownMs(ProviderDescriptor descriptor, ProviderLoginMethod method) {
    final Map<String, Object?>? raw = descriptor.loginMethod(method.id);
    final Object? flow = raw?['flow'];
    if (flow is Map) {
      final int value = _intValue(flow['resendCooldownMs'], 0);
      if (value > 0) {
        return value;
      }
    }
    if (method.resendCooldownMs > 0) {
      return method.resendCooldownMs;
    }
    return kSmsResendIntervalMs;
  }
}

bool _matches(String pattern, String value) {
  try {
    return RegExp(pattern).hasMatch(value);
  } catch (_) {
    // Qt 里非法的 QRegularExpression 同样恒不匹配（:429 的 match().hasMatch()）。
    return false;
  }
}

int _clampInt(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);

int _intValue(Object? value, int fallback) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

String _stringValue(Object? value, String fallback) =>
    value is String ? value : fallback;
