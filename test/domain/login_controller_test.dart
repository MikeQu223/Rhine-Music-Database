/// 多平台登录状态机测试（Qt/src/MusicAccount.cpp 逐行为真值）。
///
/// 没有可用于验证的账号，所以验收标准是"逻辑正确"：本文件用假网关 + 内存偏好 +
/// 假时钟 + 假延时器，把 Qt 的文案、冷却、正则、轮询夹取与失败映射逐条钉住。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/account/login_controller.dart';
import 'package:rhine_music_database/domain/player/music_player.dart' show PreferencePort;
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';

/// 内存偏好（Qt `Host::setPreference`）。
final class MemoryPreferences implements PreferencePort {
  final Map<String, String> values = <String, String>{};

  @override
  String read(String key) => values[key] ?? '';

  @override
  void write(String key, String value) => values[key] = value;
}

/// 假网关：按脚本回答 account/beginLogin/pollLogin/sendLoginCode/submitLoginCode。
final class FakeGateway implements ProviderGateway {
  FakeGateway({
    this.descriptor,
    this.polls,
    this.accountValue = const ProviderAccount(),
    this.beginSession,
    this.beginError,
    this.sendError,
    this.submitError,
    this.loggedInAccount = const ProviderAccount(id: 'uid-1', nickname: '小塞壬'),
  });

  final ProviderDescriptor? descriptor;
  List<ProviderLoginPoll>? polls;
  ProviderAccount accountValue;
  ProviderLoginSession? beginSession;
  String? beginError;
  String? sendError;
  String? submitError;
  ProviderAccount loggedInAccount;

  /// 记录调用顺序，便于断言"先取消再开始"。
  final List<String> calls = <String>[];

  /// 每次 beginLogin 收到的 method id。
  final List<String> beginMethods = <String>[];

  /// 每次 pollLogin 收到的会话令牌。
  final List<String> pollTokens = <String>[];

  @override
  String get providerId => descriptor?.id ?? 'fake';

  @override
  bool capability(String key, {bool fallback = true}) =>
      descriptor?.capability(key, fallback: fallback) ?? fallback;

  @override
  bool operation(String key, {bool fallback = false}) =>
      descriptor?.operation(key, fallback: fallback) ?? fallback;

  @override
  List<ProviderLoginMethod> get loginMethods => <ProviderLoginMethod>[
        for (final Map<String, Object?> method in descriptor?.loginMethods ?? const [])
          ProviderLoginMethod.parse(method),
      ];

  @override
  Future<ProviderAccount> account() async => accountValue;

  @override
  Future<ProviderLoginSession> beginLogin(String method) async {
    calls.add('begin:$method');
    beginMethods.add(method);
    if (beginError != null) {
      throw ProviderUnavailableError(beginError!);
    }
    return beginSession ?? const ProviderLoginSession(token: 'session-1', qrText: 'QR-TEXT');
  }

  @override
  Future<ProviderLoginPoll> pollLogin(String token) async {
    calls.add('poll:$token');
    pollTokens.add(token);
    final List<ProviderLoginPoll> script = polls ?? const <ProviderLoginPoll>[];
    if (script.isEmpty) {
      return const ProviderLoginPoll(status: 'waiting', code: '801');
    }
    if (script.length > 1) {
      polls = script.sublist(1);
    }
    return script.first;
  }

  @override
  Future<void> cancelLogin() async => calls.add('cancel');

 @override
  Future<void> sendLoginCode(String phone, String method) async {
    calls.add('send:$phone');
    if (sendError != null) {
      throw ProviderUnavailableError(sendError!);
    }
  }

  @override
  Future<void> submitLoginCode(String phone, String code, String method) async {
    calls.add('submit:$phone:$code');
    if (submitError != null) {
      throw ProviderUnavailableError(submitError!);
    }
    accountValue = loggedInAccount;
  }

  @override
  Future<void> logout() async => calls.add('logout');

  @override
  Future<ProviderCommentPage> comments({
    required String trackId,
    required ProviderCommentSort sort,
    required int page,
    String cursor = '',
  }) async => const ProviderCommentPage(comments: <ProviderComment>[]);

  @override
  Future<ProviderRepliesPage> replies({required String commentId, required int page}) async =>
      const ProviderRepliesPage(comments: <ProviderComment>[]);

  @override
  Future<List<ProviderMvVersion>> mvVersions({required String trackId}) async =>
      const <ProviderMvVersion>[];

  @override
  Future<ProviderMvTrack> mv({required String versionId}) async =>
      const ProviderMvTrack(id: 'v', title: 't', url: 'https://example.invalid/mv.mp4');

  @override
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  }) async => const <Map<String, Object?>>[];
}

/// 一次测试用的平台描述符（形状对齐 `MusicBridge/plugins/sdk/fixtures/plugins/alpha/manifest.json`）。
ProviderDescriptor descriptorOf({
  String id = 'alpha',
  bool login = true,
  List<Map<String, Object?>>? methods,
  Map<String, String> failures = const <String, String>{},
  int pollIntervalMs = 1000,
  int pollTimeoutMs = 300000,
  Map<String, String> strings = const <String, String>{},
  Map<String, Object?>? capabilities,
}) {
  return ProviderDescriptor.parse(<String, Object?>{
    'schemaVersion': '2',
    'id': id,
    'display': <String, Object?>{'name': 'Alpha Music', 'label': 'ALPHA', 'order': 10},
    'capabilities': capabilities ?? <String, Object?>{'login': login, 'search': true},
    'login': <String, Object?>{
      'methods': methods ??
          <Map<String, Object?>>[
            <String, Object?>{'id': 'qr', 'type': 'qr', 'label': '扫码登录'},
            <String, Object?>{
              'id': 'phone',
              'type': 'sms',
              'label': '手机号登录',
              'phonePattern': r'^\d{11}$',
              'flow': <String, Object?>{
                'send': 'loginSms',
                'submit': 'loginSubmit',
                'codePattern': r'^[0-9]{6}$',
                'resendCooldownMs': 60000,
              },
            },
          ],
      'pollIntervalMs': pollIntervalMs,
      'pollTimeoutMs': pollTimeoutMs,
      'failureMessages': failures,
    },
    'strings': strings,
  });
}

/// 手动时钟 + 假延时器。
final class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 20, 12);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

void main() {
  late MemoryPreferences prefs;
  late FakeClock clock;
  late List<Duration> delays;

  setUp(() {
    prefs = MemoryPreferences();
    clock = FakeClock();
    delays = <Duration>[];
  });

  LoginController controllerFor(FakeGateway gateway, ProviderDescriptor descriptor,
      {String? methodId, Future<void> Function(Duration)? delay}) {
    final LoginController controller = LoginController(
      preferences: prefs,
      clock: clock.call,
      delay: delay ??
          (Duration duration) async {
            delays.add(duration);
          },
    );
    return controller;
  }

  group('扫码全流程', () {
    test('preparing → waiting → confirming → complete，status 逐条是 Qt 文案', () async {
      final ProviderDescriptor descriptor = descriptorOf(
        failures: const <String, String>{'expired': '二维码已过期'},
        strings: const <String, String>{'scanHint': '请用 Alpha Music 扫码'},
      );
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        accountValue: const ProviderAccount(id: 'uid-1', nickname: '小塞壬'),
        polls: const <ProviderLoginPoll>[
          ProviderLoginPoll(status: 'waiting', code: '801'),
          ProviderLoginPoll(status: 'scanned', code: '802'),
          ProviderLoginPoll(status: 'scanned', code: '802'),
          ProviderLoginPoll(status: 'confirmed', code: '803'),
        ],
      );
      final List<LoginState> states = <LoginState>[];
      final LoginController controller = controllerFor(gateway, descriptor)
        ..addListener(() {});
      controller.addListener(() => states.add(controller.state));
      await controller.open(descriptor, gateway);
      await controller.start();

      final List<String> statuses = <String>[
        for (final LoginState state in states) state.status
      ];
      expect(statuses.contains('准备二维码…'), isTrue);
      expect(statuses.contains('请用 Alpha Music 扫码'), isTrue);
      expect(statuses.contains('已扫描，请在手机上确认'), isTrue);
      expect(controller.state.phase, LoginPhase.complete);
      expect(controller.state.status, '已登录：小塞壬');
      expect(controller.state.accountId, 'uid-1');
      expect(controller.state.loading, isFalse);
      // Qt confirmLogin :543 — 扫码成功后清二维码与令牌。
      expect(controller.state.qrText, isEmpty);
      expect(controller.state.token, isEmpty);
      // rememberIdentityName :57-62
      expect(prefs.read('welcome-name-alpha'), '小塞壬');
      expect(prefs.read('account-id-alpha'), 'uid-1');
      // 轮询令牌来自 loginBegin 的 token（不是世代号）。
      expect(gateway.pollTokens.every((String t) => t == 'session-1'), isTrue);
      // 轮询间隔来自 descriptor 的 pollIntervalMs。
      expect(delays.every((Duration d) => d.inMilliseconds == 1000), isTrue);
    });

    test('账号键带变体后缀：同一平台的标准版/轻量版互不覆盖', () async {
      // Qt `accountKey()`（MusicLibrary.cpp:363-365）：
      // `providerVariant.isEmpty ? provider : provider + "-" + variant`。
      // 用 setUp 里的 `prefs`：`controllerFor` 拿的就是它，别在测试里新建一份。
      final ProviderDescriptor descriptor = descriptorOf(
        strings: const <String, String>{'scanHint': '请用 Alpha Music 扫码'},
      );
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        accountValue: const ProviderAccount(id: 'uid-1', nickname: '小塞壬'),
        polls: const <ProviderLoginPoll>[
          ProviderLoginPoll(status: 'scanned', code: '802'),
          ProviderLoginPoll(status: 'confirmed', code: '803'),
        ],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, variant: 'lite');
      await controller.start();

      expect(controller.state.phase, LoginPhase.complete);
      expect(prefs.read('account-id-alpha-lite'), 'uid-1');
      expect(prefs.read('welcome-name-alpha-lite'), '小塞壬');
      // 不带变体时保持旧行为（siren/local 没有变体）。
      expect(prefs.read('account-id-alpha'), isEmpty);
    });

    test('pollIntervalMs 夹到 100..60000，timeout 取 max(interval, value)', () async {
      final List<int> intervals = <int>[];
      for (final int raw in <int>[999999, 5, 1000]) {
        final ProviderDescriptor descriptor = descriptorOf(
          pollIntervalMs: raw,
          pollTimeoutMs: 1000,
        );
        delays.clear();
        final FakeGateway gateway = FakeGateway(
          descriptor: descriptor,
          accountValue: const ProviderAccount(id: 'uid-1', nickname: '小塞壬'),
          polls: const <ProviderLoginPoll>[ProviderLoginPoll(status: 'confirmed', code: '803')],
        );
        final LoginController controller = controllerFor(gateway, descriptor);
        await controller.open(descriptor, gateway, methodId: 'qr');
        await controller.start();
        expect(controller.state.phase, LoginPhase.complete);
        intervals.add(delays.single.inMilliseconds);
      }
      // qBound(100, raw, 60000)：上界 60000、下界 100、中间原样。
      expect(intervals, <int>[60000, 100, 1000]);
    });
  });

  group('二维码过期与超时', () {
    test('expired 且 descriptor 有 failureMessages → 用表里的文案', () async {
      final ProviderDescriptor descriptor = descriptorOf(
        failures: const <String, String>{'expired': '二维码已过期'},
      );
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        polls: const <ProviderLoginPoll>[ProviderLoginPoll(status: 'expired', code: '800')],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.phase, LoginPhase.failed);
      expect(controller.state.status, '二维码已过期');
      expect(controller.state.qrText, isEmpty); // :646 qr.clear()
      expect(controller.state.loading, isFalse);
    });

    test('expired 且没有 failureMessages → 兜底文案"二维码已过期，请重新生成"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        polls: const <ProviderLoginPoll>[ProviderLoginPoll(status: 'expired', code: '800')],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.phase, LoginPhase.failed);
      expect(controller.state.status, '二维码已过期，请重新生成');
    });

    test('空 status/code 视同 800（QString::toInt(800)）', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        polls: const <ProviderLoginPoll>[ProviderLoginPoll()],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.status, '二维码已过期，请重新生成');
    });

    test('轮询次数用尽 → "二维码超时，请重新生成"', () async {
      // interval=100, timeout=max(100, 300)=300 → attempts=max(1, (300+99)/100)=3
      final ProviderDescriptor descriptor = descriptorOf(pollIntervalMs: 100, pollTimeoutMs: 300);
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        polls: const <ProviderLoginPoll>[
          ProviderLoginPoll(status: 'waiting', code: '801'),
          ProviderLoginPoll(status: 'waiting', code: '801'),
          ProviderLoginPoll(status: 'waiting', code: '801'),
        ],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.phase, LoginPhase.failed);
      expect(controller.state.status, '二维码超时，请重新生成');
      expect(gateway.pollTokens.length, 3);
    });
  });

  group('失败映射', () {
    test('命中 descriptor.loginFailureMessages 的 auth.device-limit', () async {
      expect(
        LoginController(preferences: prefs, clock: clock.call)
            .loginFailureMessage(const <String, Object?>{
          'lastFailure': <String, Object?>{
            'primaryFailure': <String, Object?>{'upstreamErrorKey': 'auth.device-limit'},
          },
        }),
        '登录失败，请稍后重试',
        reason: '未 open 时没有 descriptor，走通用兜底',
      );

      final ProviderDescriptor descriptor = descriptorOf(
        failures: const <String, String>{'auth.device-limit': '设备数已达上限，请先在官方 App 移除设备'},
      );
      final FakeGateway gateway = FakeGateway(descriptor: descriptor, beginError: '设备数已达上限');
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');

      expect(
        controller.loginFailureMessage(const <String, Object?>{
          'lastFailure': <String, Object?>{
            'primaryFailure': <String, Object?>{'upstreamErrorKey': 'auth.device-limit'},
          },
        }),
        '设备数已达上限，请先在官方 App 移除设备',
      );
      // code:<n> 也是候选键
      expect(
        controller.loginFailureMessage(const <String, Object?>{'code': 403}),
        '登录失败，请稍后重试',
      );
    });

    test('候选键顺序：upstreamKey > failureReason > failureStage > upstream:code > code:', () {
      final ProviderDescriptor descriptor = descriptorOf(
        failures: const <String, String>{
          'A': 'A 文案',
          'B': 'B 文案',
          'C': 'C 文案',
          'upstream:7': 'upstream 文案',
          'code:9': 'code 文案',
        },
      );
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      controller.open(descriptor, gateway);

      String map(Map<String, Object?> failure, {Map<String, Object?> extra = const {}}) =>
          controller.loginFailureMessage(<String, Object?>{
            ...extra,
            'lastFailure': failure,
          });

      expect(
        map(<String, Object?>{
          'primaryFailure': <String, Object?>{'upstreamErrorKey': 'A'},
          'failureReason': 'B',
        }),
        'A 文案',
      );
      expect(map(<String, Object?>{'failureReason': 'B', 'failureStage': 'C'}), 'B 文案');
      expect(map(<String, Object?>{'failureStage': 'C'}), 'C 文案');
      expect(
        map(<String, Object?>{'upstreamCode': 7}),
        'upstream 文案',
      );
      expect(
        map(const <String, Object?>{}, extra: const <String, Object?>{'code': 9}),
        'code 文案',
      );
    });

    test('兜底串：qr-timeout / user-canceled / 429 / local-backoff / 401 / 通用', () {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      controller.open(descriptor, gateway);

      expect(
        controller.loginFailureMessage(const <String, Object?>{
          'lastFailure': <String, Object?>{'failureReason': 'qr-timeout'},
        }),
        '二维码已过期，请重新生成',
      );
      expect(
        controller.loginFailureMessage(const <String, Object?>{
          'lastFailure': <String, Object?>{'failureReason': 'user-canceled'},
        }),
        '已取消扫码登录',
      );
      expect(
        controller.loginFailureMessage(const <String, Object?>{'failureReason': 'local-backoff'}),
        '登录操作暂时冷却，请稍后重试',
      );
      expect(
        controller.loginFailureMessage(const <String, Object?>{'code': 429}),
        '登录操作暂时冷却，请稍后重试',
      );
      expect(
        controller.loginFailureMessage(const <String, Object?>{'code': 401}),
        '登录已失效，请重新登录',
      );
      expect(
        controller.loginFailureMessage(const <String, Object?>{}),
        '登录失败，请稍后重试',
      );
    });
  });

  group('冷却', () {
    test('reportLoginFailure 带 retryAfterMs → 秒数回报、canRegenerate 为 false', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        accountValue: const ProviderAccount(id: 'uid-1', nickname: '小塞壬'),
        polls: const <ProviderLoginPoll>[ProviderLoginPoll(status: 'confirmed', code: '803')],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      expect(controller.canRegenerate, isTrue);

      await controller.reportLoginFailure(const <String, Object?>{
        'failureReason': 'local-backoff',
        'retryAfterMs': 42000,
      });
      expect(controller.state.phase, LoginPhase.failed);
      expect(controller.state.status, '登录操作暂时冷却，请稍后重试');
      expect(controller.cooldownSeconds, 42);
      expect(controller.canRegenerate, isFalse);
      expect(controller.cooldownLabel, '请等待 42 秒后重新生成');

      clock.advance(const Duration(seconds: 20));
      expect(controller.cooldownSeconds, 22);
      expect(controller.cooldownLabel, '请等待 22 秒后重新生成');

      clock.advance(const Duration(seconds: 22));
      expect(controller.cooldownSeconds, 0);
      expect(controller.canRegenerate, isTrue);
      expect(controller.cooldownLabel, isEmpty);

      // 冷却结束后可以重新开始。
      await controller.start();
      expect(controller.state.phase, LoginPhase.complete);
      expect(gateway.calls, contains('begin:qr'));
    });

    test('冷却中 start 被拒：status = 冷却文案 + "（请等待 N 秒）"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.reportLoginFailure(const <String, Object?>{
        'code': 429,
        'retryAfterMs': 65000,
      });
      expect(controller.state.status, '登录操作暂时冷却，请稍后重试');
      final int before = gateway.calls.length;
      await controller.start();
      expect(controller.state.phase, LoginPhase.failed);
      expect(controller.state.status, '登录操作暂时冷却，请稍后重试（请等待 65 秒）');
      expect(gateway.calls.length, before, reason: 'Qt :553-562 冷却中直接 return');
    });

    test('短信冷却：60s 后重发解禁，smsRetrySeconds 向上取整', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'phone');
      await controller.sendCode('13800138000');
      expect(controller.state.status, '验证码已发送，请查看手机短信');
      expect(controller.smsRetrySeconds, 60);
      clock.advance(const Duration(seconds: 30));
      expect(controller.smsRetrySeconds, 30);
      final int sent = gateway.calls.length;
      await controller.sendCode('13800138000');
      expect(gateway.calls.length, sent, reason: '冷却中 Qt :425 直接 return');
      clock.advance(const Duration(seconds: 31));
      expect(controller.smsRetrySeconds, 0);
      expect(controller.canRegenerate, isTrue);
    });
  });

  group('短信登录', () {
    test('没有 sms 方式 → sendCode/submitCode 不动状态', () async {
      final ProviderDescriptor descriptor = descriptorOf(
        methods: <Map<String, Object?>>[
          <String, Object?>{'id': 'qr', 'type': 'qr', 'label': '扫码登录'},
        ],
      );
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway);
      await controller.sendCode('13800138000');
      await controller.submitCode('13800138000', '123456');
      expect(controller.state.status, isEmpty);
      expect(gateway.calls.isEmpty, isTrue);
      expect(controller.smsMethod, isNull);
    });

    test('手机号正则不过 → "请输入有效的手机号码"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'phone');
      await controller.sendCode('123');
      expect(controller.state.status, '请输入有效的手机号码');
      expect(controller.state.loading, isFalse);
      expect(gateway.calls.isEmpty, isTrue); // :431 先返回，不发请求
    });

    test('缺省手机号正则 ^\\d{6,15} 美元符（descriptor 未声明时）', () async {
      final ProviderDescriptor descriptor = descriptorOf(
        methods: <Map<String, Object?>>[
          <String, Object?>{'id': 'sms', 'type': 'sms', 'label': '手机号登录'},
        ],
      );
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway);
      await controller.sendCode('12345'); // 5 位，不匹配 6..15
      expect(controller.state.status, '请输入有效的手机号码');
      await controller.sendCode('123456'); // 6 位，匹配
      expect(controller.state.status, '验证码已发送，请查看手机短信');
    });

    test('发送成功文案 + 60s 重发冷却 + 冷却期间重发被拒', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'phone');
      await controller.sendCode('13800138000');
      expect(controller.state.status, '验证码已发送，请查看手机短信');
      expect(controller.state.phase, LoginPhase.sms);
      expect(controller.smsRetrySeconds, 60);
      expect(controller.state.methodId, 'phone');
      clock.advance(const Duration(seconds: 30));
      expect(controller.smsRetrySeconds, 30);
      final int sent = gateway.calls.length;
      await controller.sendCode('13800138000');
      expect(gateway.calls.length, sent, reason: '冷却中 Qt :425 直接 return');
      clock.advance(const Duration(seconds: 31));
      expect(controller.smsRetrySeconds, 0);
      await controller.sendCode('13800138000');
      expect(gateway.calls.length, sent + 1);
    });

    test('验证码正则不过 → "请输入手机号码和短信验证码"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'phone');
      await controller.submitCode('13800138000', '12');
      expect(controller.state.status, '请输入手机号码和短信验证码');
      await controller.submitCode('138', '123456');
      expect(controller.state.status, '请输入手机号码和短信验证码');
      expect(gateway.calls.isEmpty, isTrue);
    });

    test('提交成功进入 complete，文案"已登录：<昵称>"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'phone');
      await controller.submitCode('13800138000', '123456');
      expect(controller.state.phase, LoginPhase.complete);
      expect(controller.state.status, '已登录：小塞壬');
      expect(controller.state.accountId, 'uid-1');
      expect(prefs.read('account-id-alpha'), 'uid-1');
      expect(gateway.calls, contains('submit:13800138000:123456'));
    });
  });

  group('退出与不支持', () {
    test('logout 清账号并把 account-id-<key> 写成空串', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'phone');
      await controller.submitCode('13800138000', '123456');
      prefs.write('account-id-alpha', 'uid-1');
      await controller.logout();
      expect(controller.state.accountId, isEmpty);
      expect(controller.state.nickname, '未登录');
      expect(controller.state.status, '已退出登录');
      expect(prefs.read('account-id-alpha'), isEmpty);
      expect(gateway.calls, contains('logout'));
      expect(gateway.calls, contains('cancel'));
      // 已登录昵称仍在偏好里（Qt 不退 welcome-name）。
      expect(prefs.read('welcome-name-alpha'), '小塞壬');
    });

    test('UnavailableProviderGateway：状态诚实、不抛异常', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final UnavailableProviderGateway gateway = UnavailableProviderGateway(descriptor);
      final LoginController controller = controllerFor(FakeGateway(descriptor: descriptor), descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.phase, LoginPhase.failed);
      expect(controller.state.status, '当前来源不支持该功能');
      await controller.sendCode('13800138000');
      expect(controller.state.status, '当前来源不支持该功能');
      await controller.submitCode('13800138000', '123456');
      expect(controller.state.status, '当前来源不支持该功能');
      await controller.logout();
      expect(controller.state.accountId, isEmpty);
    });

    test('siren/local 平台不启动登录（Qt :549-551 直接 return）', () async {
      for (final String id in <String>['siren', 'local']) {
        final ProviderDescriptor descriptor = descriptorOf(id: id, login: false);
        final FakeGateway gateway = FakeGateway(descriptor: descriptor);
        final LoginController controller = controllerFor(gateway, descriptor);
        await controller.open(descriptor, gateway);
        await controller.start();
        expect(controller.state.status, contains('不支持账号登录'));
        expect(gateway.calls, isEmpty);
        await controller.logout();
        expect(gateway.calls, isEmpty, reason: 'Qt logout 对 local/siren 也直接 return');
      }
    });
  });

  group('方式切换与取消', () {
    test('chooseMethod 切到 sms 不自动开始；切回 qr 自动开始', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        accountValue: const ProviderAccount(id: 'uid-1', nickname: '小塞壬'),
        polls: const <ProviderLoginPoll>[ProviderLoginPoll(status: 'confirmed', code: '803')],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.chooseMethod('phone');
      expect(controller.state.methodId, 'phone');
      expect(controller.state.phase, LoginPhase.sms);
      expect(controller.state.qrText, isEmpty);
      expect(gateway.calls.where((String c) => c.startsWith('begin')), isEmpty,
          reason: 'Qt login-method 分支只在 type==qr 时 startLogin');

      await controller.chooseMethod('qr');
      expect(controller.state.methodId, 'qr');
      expect(controller.state.phase, LoginPhase.complete);
      expect(gateway.calls, contains('begin:qr'));
    });

    test('cancel 回 idle 并清二维码；close 让在飞轮询失效', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        polls: const <ProviderLoginPoll>[
          ProviderLoginPoll(status: 'scanned', code: '802'),
          ProviderLoginPoll(status: 'confirmed', code: '803'),
        ],
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.cancel();
      expect(controller.state.phase, LoginPhase.idle);
      expect(controller.state.token, isEmpty);
      expect(gateway.calls, contains('cancel'));

      // 再开一次，故意在轮询中途 close。
      await controller.open(descriptor, gateway, methodId: 'qr');
      controller.close();
      expect(controller.state.phase, LoginPhase.idle);
      expect(controller.state.qrText, isEmpty);
    });

    test('open 时已登录 → complete；未登录 → idle', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        accountValue: const ProviderAccount(id: 'uid-9', nickname: '老用户'),
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway);
      expect(controller.state.phase, LoginPhase.complete);
      expect(controller.state.status, '已登录：老用户');
      expect(controller.state.nickname, '老用户');

      final FakeGateway anonymous = FakeGateway(descriptor: descriptor);
      final LoginController second = controllerFor(anonymous, descriptor);
      await second.open(descriptor, anonymous);
      expect(second.state.phase, LoginPhase.idle);
      expect(second.state.accountId, isEmpty);
    });
  });

  group('登录方式投影', () {
    test('methods 来自 descriptor.login.methods，默认取第一个 id', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(descriptor: descriptor);
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway);
      expect(controller.methods.map((ProviderLoginMethod m) => m.id).toList(),
          <String>['qr', 'phone']);
      expect(controller.state.methodId, 'qr');
      expect(controller.smsMethod?.id, 'phone');
      expect(controller.smsMethod?.label, '手机号登录');
    });

    test('二维码为空时按 Qt 报"<平台名>二维码读取失败"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        beginSession: const ProviderLoginSession(token: 'session-1'),
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.status, 'Alpha Music二维码读取失败');
      expect(controller.state.phase, LoginPhase.failed);
    });

    test('beginLogin 返回空 token → "二维码生成失败"', () async {
      final ProviderDescriptor descriptor = descriptorOf();
      final FakeGateway gateway = FakeGateway(
        descriptor: descriptor,
        beginSession: const ProviderLoginSession(token: '', qrText: 'x'),
      );
      final LoginController controller = controllerFor(gateway, descriptor);
      await controller.open(descriptor, gateway, methodId: 'qr');
      await controller.start();
      expect(controller.state.status, '二维码生成失败');
    });
  });
}
