/// T24-S01 登录矩阵测试：逐条对齐 Qt/src/MusicAccount.cpp 与 MusicLibrary.h。
///
/// 契约来源（每条断言都在注释里给出 Qt 行号）：
/// - 六阶段：MusicAccount.cpp:357 idle、:542 preparing、:588 waiting、:654/:659 confirming、
///   :515 complete、:311/:465/:532 failed。
/// - 六路径：MusicAccount.cpp:202 provider 白名单、:279/:414/:446 loginMethod、:562-564 QQ channel。
/// - 轮询：MusicAccount.cpp:626 上限 300、:631 schedule(1000)、:665 允许码 {800,801,802,803}。
/// - 世代：MusicAccount.cpp:352-354、:540。
///
/// 任务契约禁止执行 flutter/dart test；本文件只编写、不运行，RED/GREEN 均未执行。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/account/login_session.dart';

class _FakeTransport implements LoginTransport {
  final List<String> routes = <String>[];
  final List<Map<String, Object?>> parameters = <Map<String, Object?>>[];
  final List<Set<int>?> allowedCodes = <Set<int>?>[];
  final List<LoginResult> queued = <LoginResult>[];
  int accountCalls = 0;

  @override
  Future<LoginResult> request(String route, Map<String, Object?> params, {Set<int>? allowedCodes}) async {
    routes.add(route);
    parameters.add(params);
    this.allowedCodes.add(allowedCodes);
    return _next();
  }

  @override
  Future<LoginResult> account({AccountProvider? provider}) async {
    accountCalls++;
    return _next();
  }

  LoginResult _next() =>
      queued.isEmpty ? const LoginResult.failure('no queued response') : queued.removeAt(0);
}

class _Scheduled {
  _Scheduled(this.ms, this.callback);
  final int ms;
  final void Function() callback;
}

class _FakeScheduler implements LoginScheduler {
  int now = 1700000000000;
  final List<_Scheduled> pending = <_Scheduled>[];
  final List<int> delays = <int>[];

  @override
  int nowMs() => now;

  @override
  void schedule(int ms, void Function() callback) {
    delays.add(ms);
    pending.add(_Scheduled(ms, callback));
  }

  /// 只推进"调用时已登记"的回调，等价于 Qt 的一代 Host::schedule。
  /// 同一批定时器共享一次墙钟推进（真实 QTimer 到点同刻触发），回调里新登记的
  /// 定时器留给下一次 flush，便于断言单步时序。
  Future<void> flush() async {
    final List<_Scheduled> batch = List<_Scheduled>.from(pending);
    pending.clear();
    if (batch.isNotEmpty) {
      now += batch.first.ms;
    }
    for (final _Scheduled next in batch) {
      next.callback();
      await pumpMicrotasks();
    }
  }
}

class _FakeQrRenderer implements QrRenderer {
  final List<String> keys = <String>[];
  final List<String> images = <String>[];
  String renderedValue = 'qr-bytes';
  String imageValue = 'qr-image-bytes';

  @override
  String render(String key) {
    keys.add(key);
    return renderedValue;
  }

  @override
  String renderImage(String dataUrl) {
    images.add(dataUrl);
    return imageValue;
  }
}

class _FakeCredentials implements CredentialPort {
  String saveResult = '';
  int saves = 0;

  @override
  bool hasCredential(AccountProvider source) => false;

  @override
  String saveCredential() {
    saves++;
    return saveResult;
  }

  @override
  void deleteCredential() {}

  @override
  void logoutSource(AccountProvider source, KugouEdition edition) {}
}

Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Harness {
  _Harness() {
    session = LoginSession(
      transport: transport,
      scheduler: scheduler,
      qrRenderer: qr,
      credentials: credentials,
    );
  }

  final _FakeTransport transport = _FakeTransport();
  final _FakeScheduler scheduler = _FakeScheduler();
  final _FakeQrRenderer qr = _FakeQrRenderer();
  final _FakeCredentials credentials = _FakeCredentials();
  late final LoginSession session;
}

void main() {
  group('six login phases', () {
    test('exactly the six Qt loginPhase literals in source order', () {
      expect(LoginPhase.values.length, 6);
      expect(
        LoginPhase.values.map((LoginPhase value) => value.wire).toList(),
        <String>['idle', 'preparing', 'waiting', 'confirming', 'complete', 'failed'],
      );
    });
  });

  group('six login paths', () {
    test('path table matches Qt provider/method/edition combinations', () {
      expect(LoginPath.all.length, 6);
      expect(
        LoginPath.all.map((LoginPath path) => path.id).toList(),
        <String>[
          'netease/qr',
          'netease/phone',
          'qq/qq',
          'qq/wechat',
          'kugou/standard',
          'kugou/lite',
        ],
      );
    });

    test('only netease/phone uses SMS (MusicAccount.cpp:403,433 guard provider != netease)', () {
      final List<LoginPath> sms =
          LoginPath.all.where((LoginPath path) => path.usesSms).toList();
      expect(sms.length, 1);
      expect(sms.single.provider, AccountProvider.netease);
      expect(sms.single.method, LoginMethod.phone);
    });

    test('QQ carries the channel parameter and never SMS (MusicAccount.cpp:562-564)', () {
      final LoginPath qq = LoginPath.all[2];
      final LoginPath wechat = LoginPath.all[3];
      expect(qq.qrChannel, 'qq');
      expect(wechat.qrChannel, 'wechat');
      expect(qq.usesSms, isFalse);
      expect(wechat.usesSms, isFalse);
    });

    test('kugou paths carry standard/lite editions and never SMS', () {
      expect(LoginPath.all[4].edition, KugouEdition.standard);
      expect(LoginPath.all[5].edition, KugouEdition.lite);
      expect(LoginPath.all[4].usesSms, isFalse);
      expect(LoginPath.all[5].usesSms, isFalse);
    });

    test('netEase renders locally, QQ and Kugou need the remote image route', () {
      expect(LoginPath.all[0].needsRemoteQrImage, isFalse);
      expect(LoginPath.all[2].needsRemoteQrImage, isTrue);
      expect(LoginPath.all[4].needsRemoteQrImage, isTrue);
    });
  });

  group('poll contract constants', () {
    test('1000 ms interval, 300 attempts, codes 800/801/802/803 (MusicAccount.cpp:626,631,665)', () {
      expect(LoginSession.pollIntervalMs, 1000);
      expect(LoginSession.pollLimit, 300);
      expect(LoginSession.pollCodes.toList()..sort(), <int>[800, 801, 802, 803]);
      expect(LoginSession.smsResendIntervalMs, 60000);
    });
  });

  group('startLogin', () {
    test('netease prepares, renders locally and enters waiting (MusicAccount.cpp:542,588,593-596)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-1'}));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/qr/key']);
      expect(h.qr.keys, <String>['key-1']);
      expect(h.session.qrKey, 'key-1');
      expect(h.session.qr, 'qr-bytes');
      expect(h.session.phase, LoginPhase.waiting);
      expect(h.session.status, '请用网易云音乐扫描并确认登录');
      expect(h.session.loading, isTrue);
      expect(h.scheduler.delays, <int>[1000]);
    });

    test('qq sends channel and goes through /login/qr/create (MusicAccount.cpp:562-564,598-620)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.method = LoginMethod.wechat;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/qr/key', '/login/qr/create']);
      expect(h.transport.parameters.first['channel'], 'wechat');
      expect(h.transport.parameters.last['key'], 'key-q');
      expect(h.transport.parameters.last['qrimg'], isTrue);
      expect(h.qr.images, <String>['data:image/png;base64,AAAA']);
      expect(h.session.status, '请用微信扫描并确认登录');
      expect(h.session.phase, LoginPhase.waiting);
    });

    test('qq rejects a non image data url (MusicAccount.cpp:607-611)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'https://example.test/qr.png'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, 'QQ 音乐二维码格式无效');
    });

    test('local and siren never start a login (MusicAccount.cpp:526)', () {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.local;
      h.session.startLogin();
      expect(h.transport.routes, isEmpty);
      expect(h.session.phase, LoginPhase.idle);
    });

    test('re-entry while confirming is refused (MusicAccount.cpp:304-306,529)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.session.phase = LoginPhase.confirming;
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.transport.routes, isEmpty);
    });
  });

  group('pollQR', () {
    Future<_Harness> waiting() async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-1'}));
      h.session.startLogin();
      await pumpMicrotasks();
      return h;
    }

    test('801 keeps the phase and polls again after another second (MusicAccount.cpp:663,665)', () async {
      final _Harness h = await waiting();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 801}));
      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.transport.routes.last, '/login/qr/check');
      expect(h.transport.allowedCodes.last!.toList()..sort(), <int>[800, 801, 802, 803]);
      expect(h.session.phase, LoginPhase.waiting);
      // 一次 801 只新增一次 1000 ms 轮询，阶段不变（MusicAccount.cpp:663-665）。
      expect(h.scheduler.delays, <int>[1000, 1000]);
    });

    test('802 switches to confirming and keeps polling (MusicAccount.cpp:653-657)', () async {
      final _Harness h = await waiting();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 802}));
      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.confirming);
      expect(h.session.status, '已扫描，请在手机上确认');
      expect(h.scheduler.pending.length, 1);
    });

    test('803 confirms, saves credential and completes without remote qr image (MusicAccount.cpp:658-662,500-517)', () async {
      final _Harness h = await waiting();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 803}));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-7', '昵称七']));

      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.complete);
      expect(h.session.qr, '');
      expect(h.session.qrKey, '');
      expect(h.session.uid, 'uid-7');
      expect(h.session.nickname, '昵称七');
      expect(h.session.status, '已登录：昵称七');
      expect(h.session.loading, isFalse);
      expect(h.credentials.saves, 1);
      expect(h.session.diagnostics, isEmpty);
    });

    test('800 expires the code, clears the qr and fails for netease (MusicAccount.cpp:643-651)', () async {
      final _Harness h = await waiting();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 800}));
      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.session.qr, '');
      expect(h.session.loading, isFalse);
      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '二维码已过期，请重新生成');
    });

    test('missing code defaults to 800 (MusicAccount.cpp:642)', () async {
      final _Harness h = await waiting();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      await h.scheduler.flush();
      await pumpMicrotasks();
      expect(h.session.phase, LoginPhase.failed);
    });

    test('300 attempts exhaust the code without another request (MusicAccount.cpp:626-629)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.session.debugPollQr(LoginSession.pollLimit);
      await pumpMicrotasks();

      expect(h.transport.routes, isEmpty);
      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '二维码超时，请重新生成');
    });
  });

  group('generation discards stale replies', () {
    test('a scheduled poll after cancelLogin never reaches the transport (MusicAccount.cpp:352-354,630-634)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-1'}));
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.scheduler.pending.length, 1);

      h.session.cancelLogin();
      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/qr/key']);
      expect(h.session.phase, LoginPhase.idle);
      expect(h.session.qrKey, '');
      expect(h.session.qr, '');
      expect(h.session.loading, isFalse);
    });
  });

  group('failure classification', () {
    test('device limit and rate limit map to the Qt messages (MusicAccount.cpp:13-23)', () {
      expect(
        loginFailureMessage(<String, Object?>{'upstreamCode': 20279}),
        '登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备',
      );
      expect(
        loginFailureMessage(<String, Object?>{'upstreamErrorKey': 'auth.rate-limited'}),
        'QQ 登录操作过于频繁，请等待冷却后重试',
      );
      expect(
        loginFailureMessage(<String, Object?>{'primaryFailure': <String, Object?>{'upstreamCode': 50006}}),
        '请使用手机 QQ 扫描手机 QQ 通道二维码，再尝试登录',
      );
    });

    test('stage and reason map to the Qt messages (MusicAccount.cpp:32-49)', () {
      expect(
        loginFailureMessage(<String, Object?>{'failureReason': 'qr-timeout'}),
        '二维码已过期，请重新生成',
      );
      expect(
        loginFailureMessage(<String, Object?>{'failureReason': 'user-canceled'}),
        '已取消扫码登录',
      );
      expect(
        loginFailureMessage(<String, Object?>{'failureStage': 'credential-validation'}),
        '登录凭证验证失败，请重试或检查设备管理',
      );
      expect(
        loginFailureMessage(<String, Object?>{'failureStage': 'mqtt-listener'}),
        '扫码连接中断，请检查网络后重试',
      );
    });

    test('default branch distinguishes code 800 (MusicAccount.cpp:56-57)', () {
      expect(
        loginFailureMessage(<String, Object?>{'code': 800}),
        '二维码会话已失效或登录失败，请重新生成',
      );
      expect(loginFailureMessage(<String, Object?>{}), '扫码登录失败，请稍后重试');
    });

    test('diagnostics keep only the safe whitelist (MusicApi.cpp:26-58)', () {
      final _Harness h = _Harness();
      h.session.reportLoginFailure(<String, Object?>{
        'failureStage': 'credential-exchange',
        'code': 401,
        'retryAfterMs': 3000,
        'cookie': 'MUSIC_U=secret',
        'message': 'raw upstream text',
      });
      expect(h.session.diagnostics.keys.toList()..sort(), <String>['code', 'failureStage', 'retryAfterMs']);
      expect(h.session.diagnostics.values.contains('MUSIC_U=secret'), isFalse);
    });
  });

  group('credential save failure', () {
    test('a failed save must not fake a login for the qr path (MusicAccount.cpp:489-499)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.credentials.saveResult = '登录成功，但 Android 凭据当前不可写';
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 803}));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', 'name']));

      h.session.startLogin();
      await pumpMicrotasks();
      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.uid, '');
      expect(h.session.nickname, '未登录');
    });
  });

  group('sms login (netease only)', () {
    test('sendLoginCode refuses every non netease provider (MusicAccount.cpp:403)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.sendLoginCode('13800138000');
      await pumpMicrotasks();
      expect(h.transport.routes, isEmpty);
      expect(h.session.method, LoginMethod.qr);
    });

    test('sendLoginCode rejects an invalid mainland number (MusicAccount.cpp:407-410)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.session.sendLoginCode(' 12345 ');
      await pumpMicrotasks();
      expect(h.transport.routes, isEmpty);
      expect(h.session.status, '请输入有效的中国大陆手机号码');
      expect(h.session.method, LoginMethod.qr);
    });

    test('sendLoginCode posts /captcha/sent with ctcode 86 and starts the 60 s window (MusicAccount.cpp:415-425)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));

      h.session.sendLoginCode(' 13800138000 ');
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/captcha/sent']);
      expect(h.transport.parameters.single['phone'], '13800138000');
      expect(h.transport.parameters.single['ctcode'], '86');
      expect(h.session.method, LoginMethod.phone);
      expect(h.session.status, '验证码已发送，请查看手机短信');
      expect(h.session.loading, isFalse);
      // updateSmsCooldown（MusicAccount.cpp:386-397）在 60 s 内每秒重排一次
      expect(h.scheduler.delays, <int>[1000]);
      expect(h.session.smsRetrySeconds(), 60);
    });

    test('sendLoginCode surfaces the transport error and clears loading (MusicAccount.cpp:422-425)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.failure('短信发送失败'));

      h.session.sendLoginCode('13800138000');
      await pumpMicrotasks();

      expect(h.session.status, '短信发送失败');
      expect(h.session.loading, isFalse);
      expect(h.session.phase, LoginPhase.idle);
    });

    test('a second send inside the 60 s window is refused (MusicAccount.cpp:403)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));

      h.session.sendLoginCode('13800138000');
      await pumpMicrotasks();
      h.session.sendLoginCode('13800138000');
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/captcha/sent']);
    });

    test('smsRetrySeconds counts down on the wall clock (MusicAccount.cpp:381-384)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.session.sendLoginCode('13800138000');
      await pumpMicrotasks();

      expect(h.session.smsRetrySeconds(), 60);
      h.scheduler.now += 30000;
      expect(h.session.smsRetrySeconds(), 30);
      h.scheduler.now += 29999;
      expect(h.session.smsRetrySeconds(), 1);
      h.scheduler.now += 1;
      expect(h.session.smsRetrySeconds(), 0);
    });

    test('captchaLogin rejects a malformed phone or code (MusicAccount.cpp:437-441)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.session.captchaLogin('13800138000', '12');
      await pumpMicrotasks();
      expect(h.transport.routes, isEmpty);
      expect(h.session.status, '请输入中国大陆手机号码和短信验证码');

      h.session.captchaLogin('1380013800', '1234');
      await pumpMicrotasks();
      expect(h.transport.routes, isEmpty);
      expect(h.session.status, '请输入中国大陆手机号码和短信验证码');
    });

    test('captchaLogin posts /login/cellphone and confirms with captcha (MusicAccount.cpp:443-461,475-523)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-9', '九号']));

      h.session.captchaLogin(' 13800138000 ', ' 123456 ');
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/cellphone']);
      expect(h.transport.parameters.single['phone'], '13800138000');
      expect(h.transport.parameters.single['captcha'], '123456');
      expect(h.transport.parameters.single['countrycode'], '86');
      expect(h.transport.accountCalls, 1);
      expect(h.session.uid, 'uid-9');
      expect(h.session.nickname, '九号');
      expect(h.session.status, '已登录：九号');
      expect(h.session.loading, isFalse);
      expect(h.credentials.saves, 1);
      // captcha 路径不置 complete、不清二维码（MusicAccount.cpp:511-517 的 if(!captcha)）
      expect(h.session.phase, LoginPhase.idle);
    });

    test('captcha failure never leaves the phase in failed (MusicAccount.cpp:446-451)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.failure('短信验证码错误'));

      h.session.captchaLogin('13800138000', '1234');
      await pumpMicrotasks();

      expect(h.session.status, '短信验证码错误');
      expect(h.session.loading, isFalse);
      expect(h.session.phase, LoginPhase.idle);
      expect(h.session.uid, '');
    });

    test('captchaLogin is refused while a request is in flight (MusicAccount.cpp:433)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', 'a']));

      h.session.captchaLogin('13800138000', '1234');
      h.session.captchaLogin('13800138000', '1234');
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/cellphone']);
    });

    test('sendLoginCode cancels an in flight qr login first (MusicAccount.cpp:411)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.session.qrKey = 'key-old';
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));

      h.session.sendLoginCode('13800138000');
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/captcha/sent']);
      expect(h.session.qrKey, '');
      expect(h.session.phase, LoginPhase.idle);
    });
  });

  group('qq cancel completion barrier (MusicAccount.cpp:343-379)', () {
    test('cancelLogin posts the previous key and completes the waiter only after the reply', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.session.phase, LoginPhase.waiting);
      expect(h.session.qrKey, 'key-q');

      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      bool? completed;
      h.session.cancelLogin((bool cancelled) => completed = cancelled);

      // Qt:352-358 的五个副作用同步发生，屏障要等 /login/qr/cancel 的回复。
      expect(h.session.phase, LoginPhase.idle);
      expect(h.session.qr, '');
      expect(h.session.qrKey, '');
      expect(h.session.loading, isFalse);
      expect(h.transport.routes.last, '/login/qr/cancel');
      expect(h.transport.parameters.last, <String, Object?>{'key': 'key-q'});
      expect(completed, isNull);

      await pumpMicrotasks();
      expect(completed, isTrue);
    });

    test('a failed cancel reply surfaces 旧二维码取消失败 and blocks the new qr (MusicAccount.cpp:548-557)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.session.phase, LoginPhase.waiting);

      h.transport.queued.add(const LoginResult.failure('cancel failed'));
      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '旧二维码取消失败，请稍后重试');
      expect(h.session.loading, isFalse);
      // 屏障未放行时绝不能生成第二张二维码。
      expect(h.transport.routes.where((String route) => route == '/login/qr/key').length, 1);
    });

    test('netease never calls the qq cancel route and the waiter completes at once (MusicAccount.cpp:359-362)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-n'}));
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.session.phase, LoginPhase.waiting);

      bool? completed;
      h.session.cancelLogin((bool cancelled) => completed = cancelled);
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/qr/key']);
      expect(completed, isTrue);
      expect(h.session.phase, LoginPhase.idle);
    });

    test('cancelLogin without a qr key completes immediately and sends nothing (MusicAccount.cpp:359-362)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;

      bool? completed;
      h.session.cancelLogin((bool cancelled) => completed = cancelled);
      await pumpMicrotasks();

      expect(h.transport.routes, isEmpty);
      expect(completed, isTrue);
      expect(h.session.phase, LoginPhase.idle);
    });

    test('re-entry while the cancel is in flight rotates exactly one qr (MusicAccount.cpp:525-558)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.session.qrKey, 'key-q');

      // 第 2 次重入：旧二维码取消请求挂起，本代进入 preparing 等屏障。
      // 第 3 次重入在实现里由 preparing 守卫挡回（MusicAccount.cpp:529-538）；本用例只断言这一轮
      // 最终只旋转一次（即便守卫缺位、第二个 waiter 被登记，世代差仍让 waiter#1 失效），
      // 多 waiter 合流另见下一个用例。
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      h.session.startLogin();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-r'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,BBBB'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.transport.routes.where((String route) => route == '/login/qr/key').length, 2);
      expect(h.transport.routes.where((String route) => route == '/login/qr/cancel').length, 1);
      expect(h.session.qrKey, 'key-r');
      expect(h.session.qr, 'qr-image-bytes');
      expect(h.session.phase, LoginPhase.waiting);
    });

    test('two waiters merge on one cancel barrier (MusicAccount.cpp:343-349)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.session.qrKey, 'key-q');

      // 取消回包先入队，第 2 次 startLogin 才会挂起在屏障上（waiter#1）。
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      h.session.startLogin();
      expect(h.session.phase, LoginPhase.preparing);

      // 外部取消（等价 logout/switchProvider 里的 cancelLogin）把 phase 拉回 idle，
      // 于是第 3 次 startLogin 能过 canRegenerateLogin()，在同一个屏障上登记 waiter#2。
      h.session.cancelLogin();
      expect(h.session.phase, LoginPhase.idle);
      h.session.startLogin();
      expect(h.session.phase, LoginPhase.preparing);

      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-r'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,BBBB'},
      }));
      await pumpMicrotasks();

      // 一个 /login/qr/cancel 回包同时放行两个 waiter：两个回调都被调用，
      // 但只有最新一代（token 与 _loginGeneration 相同）的那个真正发码，
      // 旧一代在 _isCurrent 处被丢弃（Qt 同构：generation 屏障 + 单次旋转）。
      expect(h.transport.routes.where((String route) => route == '/login/qr/cancel').length, 1);
      expect(h.transport.routes.where((String route) => route == '/login/qr/key').length, 2);
      expect(h.session.phase, LoginPhase.waiting);
      expect(h.session.qrKey, 'key-r');
      expect(h.session.qr, 'qr-image-bytes');
    });

    test('the previous qr poll dies on rotation (MusicAccount.cpp:631-632)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();

      h.transport.queued.add(const LoginResult.ok(<String, Object?>{}));
      h.session.startLogin();
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-r'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,BBBB'},
      }));
      await pumpMicrotasks();
      expect(h.session.qrKey, 'key-r');

      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 801}));
      await h.scheduler.flush();
      await pumpMicrotasks();

      // 旧计时器因世代过期被丢弃，只有新二维码发出一次轮询。
      final List<int> checks = <int>[];
      for (var i = 0; i < h.transport.routes.length; i++) {
        if (h.transport.routes[i] == '/login/qr/check') checks.add(i);
      }
      expect(checks.length, 1);
      expect(h.transport.parameters[checks.single]['key'], 'key-r');
      expect(h.session.phase, LoginPhase.waiting);
    });
  });

  group('retryAfterMs wall clock cooldown (MusicAccount.cpp:308-341)', () {
    test('the failure installs a whole second countdown that ends with ，可重新生成', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.reportLoginFailure(<String, Object?>{'code': 429, 'retryAfterMs': 5000});

      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '扫码登录暂时冷却（请等待 5 秒）');
      expect(h.session.loginRetrySeconds(), 5);
      expect(h.session.canRegenerateLogin(), isFalse);
      expect(h.scheduler.delays, <int>[1000]);

      await h.scheduler.flush();
      expect(h.session.status, '扫码登录暂时冷却（请等待 4 秒）');
      await h.scheduler.flush();
      expect(h.session.status, '扫码登录暂时冷却（请等待 3 秒）');
      await h.scheduler.flush();
      await h.scheduler.flush();
      await h.scheduler.flush();
      expect(h.session.status, '扫码登录暂时冷却，可重新生成');
      expect(h.session.loginRetrySeconds(), 0);
      expect(h.session.canRegenerateLogin(), isTrue);
    });

    test('startLogin during the cooldown reports the remaining seconds without a qr (MusicAccount.cpp:525-540)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.reportLoginFailure(<String, Object?>{'code': 429, 'retryAfterMs': 3000});
      await h.scheduler.flush();
      // 先放一个与冷却文案不同的现状，否则空转也能通过 :529-537 的断言。
      h.session.status = '旧文案';

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.transport.routes, isEmpty);
      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '扫码登录暂时冷却（请等待 2 秒）');
      expect(h.session.loginRetrySeconds(), 2);
      expect(h.session.loading, isFalse);
    });

    test('a stale cooldown timer never overwrites the newer failure text (MusicAccount.cpp:322-341)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.reportLoginFailure(<String, Object?>{'code': 429, 'retryAfterMs': 3000});
      await h.scheduler.flush();

      h.session.reportLoginFailure(<String, Object?>{'code': 401, 'retryAfterMs': 5000});
      expect(h.session.status, 'QQ 登录已失效，请重新扫码（请等待 5 秒）');
      await h.scheduler.flush();

      // 两个定时器同刻触发（一次墙钟推进 1000 ms）：旧 token 到点即被守卫丢弃、不再续订，
      // 因此队列里只剩新冷却的下一次 tick（有守卫 1 个，无守卫会变成 2 个）。
      expect(h.scheduler.pending.length, 1);
      expect(h.session.status, 'QQ 登录已失效，请重新扫码（请等待 4 秒）');
      expect(h.session.loginRetrySeconds(), 4);
    });

    test('a failure without retryAfterMs installs no cooldown timer (MusicAccount.cpp:316-318)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.reportLoginFailure(<String, Object?>{'code': 429});

      expect(h.session.phase, LoginPhase.failed);
      // 关掉 if (retry > 0) 时状态会退化成『扫码登录暂时冷却，可重新生成』，此处锁住原文案。
      expect(h.session.status, '扫码登录暂时冷却');
      expect(h.session.loginRetrySeconds(), 0);
      expect(h.scheduler.delays, isEmpty);
      expect(h.session.canRegenerateLogin(), isTrue);
    });

    test('a completed login leaves nothing that blocks the next startLogin (MusicAccount.cpp:516)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.reportLoginFailure(<String, Object?>{'code': 429, 'retryAfterMs': 1000});
      await h.scheduler.flush();
      expect(h.session.canRegenerateLogin(), isTrue);

      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-q'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,AAAA'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();
      expect(h.session.phase, LoginPhase.waiting);

      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'code': 803}));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', '甲']));
      await h.scheduler.flush();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.complete);
      expect(h.session.loginRetrySeconds(), 0);
      expect(h.session.canRegenerateLogin(), isTrue);

      // Qt:516 的 m_cooldowns.remove(provider) 本身在 deadline 已过后不可观测
      // （loginRetrySeconds 恒为 0），这里断言的是它的用户可见结果：再开一次必须真的发码。
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-2'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,DDDD'},
      }));
      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.waiting);
      expect(h.session.qrKey, 'key-2');
      expect(h.transport.routes.where((String route) => route == '/login/qr/key').length, 2);
    });
  });

  group('remote qr image and scanner copy (MusicAccount.cpp:560-623, 583-592)', () {
    test('kugou standard asks for a remote image and uses the 酷狗音乐 copy', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.kugou;
      h.session.edition = KugouEdition.standard;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'kg-1'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,BBBB'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.transport.routes, <String>['/login/qr/key', '/login/qr/create']);
      expect(h.transport.parameters[1], <String, Object?>{
        'key': 'kg-1',
        'qrimg': true,
        'timestamp': h.scheduler.now,
      });
      expect(h.qr.images, <String>['data:image/png;base64,BBBB']);
      expect(h.session.qr, 'qr-image-bytes');
      expect(h.session.phase, LoginPhase.waiting);
      expect(h.session.status, '请用酷狗音乐扫描并确认登录');
    });

    test('kugou lite uses the 酷狗概念版 copy', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.kugou;
      h.session.edition = KugouEdition.lite;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'kg-2'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,BBBB'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.waiting);
      expect(h.session.status, '请用酷狗概念版扫描并确认登录');
    });

    test('wechat channel scans with the 微信 copy (MusicAccount.cpp:585-587)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.qq;
      h.session.method = LoginMethod.wechat;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'key-w'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,CCCC'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.transport.parameters.first['channel'], 'wechat');
      expect(h.session.status, '请用微信扫描并确认登录');
    });

    test('an empty rendered image fails with 二维码读取失败 (MusicAccount.cpp:613-617)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.kugou;
      h.qr.imageValue = '';
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'kg-1'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'data:image/png;base64,BBBB'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '酷狗音乐二维码读取失败');
      expect(h.session.loading, isFalse);
      expect(h.session.qr, '');
    });

    test('a non image payload fails with 二维码格式无效 (MusicAccount.cpp:607-612)', () async {
      final _Harness h = _Harness();
      h.session.provider = AccountProvider.kugou;
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{'unikey': 'kg-1'}));
      h.transport.queued.add(const LoginResult.ok(<String, Object?>{
        'data': <String, Object?>{'qrimg': 'https://cdn.example.com/qr.png'},
      }));

      h.session.startLogin();
      await pumpMicrotasks();

      expect(h.session.phase, LoginPhase.failed);
      expect(h.session.status, '酷狗音乐二维码格式无效');
      expect(h.qr.images, isEmpty);
    });
  });
}
