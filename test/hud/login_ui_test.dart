// ===========================================================================
// 登录 UI 测试：竖屏页（portrait_pages_login.dart）+ 横屏弹层（login_modal.dart）
// 参考真值：
//   Qt/src/NativeHudLibrary.cpp:271-330（loginPanel 的全部坐标、文案与动作串）
//   Qt/src/NativeHudModal.cpp:1-30 / :287-288（login 弹层的标题、副标题与分发）
//   Qt/src/NativeHudMusic.cpp:405-446（login / login-method / qr / logout 的动作语义）
//   Qt/src/ResponsiveHudPages.cpp:527-545（设置页 ACCESS 卡）、:647-680（平台页 03 ACCOUNT）
//   Qt/src/MusicAccount.cpp:577-620（prepareQR 的 scanHint 兜底串）
// 说明：期望值一律是按 Qt 源码折算出、直接写死的字面量（标签 / 动作串 / 坐标）；
//   只有显式标注 identity check 的断言才与产品常量比较。
// ===========================================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/account/login_controller.dart';
import 'package:rhine_music_database/hud/modals/login_modal.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_login.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Deterministic glyph metrics: every code unit advances size * 0.5.
/// fit() reproduces Qt NativeHud::fit() (Qt/src/NativeHud.cpp:48-76).
final class _Metrics implements HudTextPort {
  const _Metrics();

  static const double _advance = 0.5;

  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      value.length * size * _advance;

  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => 0;

  @override
  String fit(String value, double size, double width,
      [String weight = 'regular']) {
    if (glyphWidth(value, size) <= width) {
      return value;
    }
    int low = 1;
    int high = value.length;
    while (low < high) {
      final int middle = (low + high + 1) ~/ 2;
      if (glyphWidth(value.substring(0, middle), size) <= width) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return '${value.substring(0, low - 1)}\u2026';
  }

  @override
  void rolling(String key, String value, double x, double y, double size,
      String weight, double tracking, bool numeric) {}
}

/// 竖屏画布：宽度按字符数估算即可（本组只看「画了什么 / 发了什么动作」）。
PortraitCanvas _canvas({double gridWidth = 393, double height = 760}) =>
    PortraitCanvas(
      metrics: PortraitMetrics(
        width: (String value, double size, String weight) =>
            value.length * size * .6,
        wrap: (String value, double limit, double size, String weight) =>
            <String>[value],
        bounds: (String value, double size, String weight) =>
            PortraitGlyphBounds(width: value.length * size * .6, height: size),
      ),
      unit: 1,
      height: height,
      dark: true,
      gridWidth: gridWidth,
    );

Set<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toSet();

List<String> _portraitTexts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command.length >= 2 && command[0] == 'text') command[1]! as String,
];

List<List<Object?>> _ofType(List<List<Object?>> commands, String type) =>
    commands.where((List<Object?> command) => command[0] == type).toList();

List<String> _texts(List<List<Object?>> commands) => _ofType(commands, 'text')
    .map((List<Object?> command) => command[1]! as String)
    .toList();

List<String> _hitActions(List<HudHit> hits) =>
    hits.map((HudHit hit) => hit.action).toList();

List<Object?> _textCommand(List<List<Object?>> commands, String value) =>
    commands.firstWhere(
      (List<Object?> command) => command[0] == 'text' && command[1] == value,
      orElse: () => throw StateError('missing text command: $value'),
    );

/// α 平台的两种登录方式（MusicBridge/plugins/sdk/fixtures/plugins/alpha/manifest.json）。
const List<ProviderLoginMethod> _alphaMethods = <ProviderLoginMethod>[
  ProviderLoginMethod(id: 'qr', type: 'qr', label: '扫码登录'),
  ProviderLoginMethod(
    id: 'phone',
    type: 'sms',
    label: '手机号登录',
    phonePattern: r'^\d{11}$',
    codePattern: r'^[0-9]{6}$',
  ),
];

LoginState _state({
  LoginPhase phase = LoginPhase.waiting,
  String methodId = 'qr',
  String status = '',
  String qrText = '',
  String qrImage = '',
  String token = '',
  String nickname = '',
  String accountId = '',
  bool loading = false,
  DateTime? canRegenerateAt,
}) =>
    LoginState(
      provider: 'alpha',
      methodId: methodId,
      phase: phase,
      status: status,
      qrText: qrText,
      qrImage: qrImage,
      token: token,
      nickname: nickname,
      accountId: accountId,
      loading: loading,
      canRegenerateAt: canRegenerateAt,
    );

void main() {
  // =========================================================================
  // 竖屏页
  // =========================================================================
  group('paintPortraitLoginPage', () {
    test('页面宽度一律取 gridWidth，不写死 393', () {
      final PortraitCanvas narrow = _canvas(gridWidth: 320);
      paintPortraitLoginPage(
        narrow,
        state: _state(),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
      );
      // 页头 back 热区固定 (16,76,44,44)，与页宽无关（portrait_canvas header）。
      expect(_actions(narrow), contains('back'));
      // 所有命中都落在 gridWidth(320) 内，没有任何硬编码 393 的坐标漏出来。
      for (final HudHit hit in narrow.hits) {
        expect(hit.x + hit.width, lessThanOrEqualTo(320));
      }
      expect(
        _actions(narrow).where(
          (String action) => action.startsWith(kPortraitLoginMethodPrefix),
        ),
        isNotEmpty,
      );
    });

    test('扫码分支：占位方框 + qrText + scanHint 兜底串 + 重新生成', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(qrText: 'rhine://login/alpha-1'),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
      );
      final List<String> texts = _portraitTexts(c);
      // scanHint 为空时的 Qt 兜底串（MusicAccount.cpp:606-611 同文）。
      expect(texts, contains('请用Alpha Music扫描并确认登录'));
      // 二维码方框：surface 底 + line 四边。
      final List<List<Object?>> fills = _ofType(c.commands, 'fill');
      expect(fills.length, greaterThan(0));
      // 重新生成按钮只在可重新生成时出现（这里冷却是空的）。
      expect(_actions(c), contains(kPortraitLoginRegenerateAction));
      // 文本二维码内容被画出来（不画假二维码）。
      expect(texts.where((String t) => t.contains('rhine://')).length,
          greaterThan(0));
    });

    test('扫码分支：scanHint 与 deviceNotice 由平台 strings 提供', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
        scanHint: '请用 Alpha Music 扫码',
        deviceNotice: '请确认手机与电脑处于同一网络。',
      );
      final List<String> texts = _portraitTexts(c);
      expect(texts, contains('请用 Alpha Music 扫码'));
      expect(texts, contains('请确认手机与电脑处于同一网络。'));
    });

    test('冷却中不出「重新生成二维码」，只画一行 cooldownLabel', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
        cooldownLabel: '请等待 42 秒后重新生成',
      );
      expect(_actions(c), isNot(contains(kPortraitLoginRegenerateAction)));
      expect(_portraitTexts(c), contains('请等待 42 秒后重新生成'));
    });

    test('短信分支：手机号/验证码字段 + 发送按钮 + 登录按钮', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(methodId: 'phone'),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
      );
      expect(_portraitTexts(c),
          contains('手机号码（中国大陆）')); // NativeHudLibrary.cpp:295
      expect(_portraitTexts(c), contains('短信验证码')); // :296
      expect(_portraitTexts(c), contains('发送验证码'));
      expect(_portraitTexts(c), contains('登录 →'));
      expect(c.fields.containsKey('account'), isTrue);
      expect(c.fields.containsKey('captcha'), isTrue);
      expect(_actions(c), contains(kPortraitLoginSendCodeAction));
      expect(_actions(c), contains(kPortraitLoginSubmitAction));
    });

    test('短信冷却时发送按钮改成「N 秒后重发」，热区仍在', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(methodId: 'phone'),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
        smsRetrySeconds: 42,
      );
      expect(_portraitTexts(c), contains('42 秒后重发'));
      expect(_actions(c), contains(kPortraitLoginSendCodeAction));
    });

    test('已登录态：昵称卡 + 退出登录动作，不画二维码', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(
          phase: LoginPhase.complete,
          nickname: '小塞壬',
          accountId: 'uid-1',
        ),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
      );
      expect(_portraitTexts(c), contains('小塞壬'));
      expect(_portraitTexts(c), contains('账号 id / uid-1'));
      expect(_portraitTexts(c), contains('已登录'));
      expect(_actions(c), contains(kPortraitLoginLogoutAction));
      expect(_actions(c), isNot(contains(kPortraitLoginRegenerateAction)));
    });

    test('方式 chip 发出 music:login-method:<id>，选中态跟随 state.methodId', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLoginPage(
        c,
        state: _state(methodId: 'phone'),
        methods: _alphaMethods,
        providerName: 'Alpha Music',
      );
      expect(
        _actions(c).where(
              (String action) => action.startsWith(kPortraitLoginMethodPrefix),
            ),
        containsAll(<String>[
          '${kPortraitLoginMethodPrefix}qr',
          '${kPortraitLoginMethodPrefix}phone',
        ]),
      );
    });
  });

  // =========================================================================
  // 横屏弹层
  // =========================================================================
  group('LoginModal', () {
    LoginModal modal({
      LoginState? state,
      List<ProviderLoginMethod> methods = _alphaMethods,
      List<Map<String, Object?>> variants = const <Map<String, Object?>>[],
      String selectedVariant = '',
      String cooldownLabel = '',
      Map<String, String> text = const <String, String>{},
      bool dark = false,
    }) =>
        LoginModal(
          textPort: const _Metrics(),
          stageWidth: 1920,
          state: state ?? _state(),
          text: text,
          methods: methods,
          variants: variants,
          selectedVariant: selectedVariant,
          cooldownLabel: cooldownLabel,
          title: loginModalTitle('Alpha Music'),
          subtitle: loginModalSubtitle(text['loginHint'] ?? ''),
          dark: dark,
        );

    test('弹层外框沿用 modal_shell 的 login 策略（遮罩 + 标题带 + close-modal）', () {
      final LoginModalFrame frame = modal().build();
      expect(frame.bounds.left, 330);
      expect(frame.bounds.top, 122);
      expect(frame.bounds.width, 1260);
      expect(frame.bounds.height, 836);
      expect(frame.policy.modalId, 'login');
      expect(frame.policy.paintsStageScrim, isTrue);
      expect(frame.policy.usesTitleBand, isTrue);
      expect(frame.policy.dismissesOnStageTap, isFalse);
      expect(frame.policy.backAction, 'close-modal');
      expect(frame.policy.category, 'MUSIC DIRECTORY');
    });

    test('标题 = <平台名> LOGIN，副标题取 loginHint，空则用 Qt 兜底串', () {
      // NativeHudModal.cpp:27 / :53
      expect(loginModalTitle('Alpha Music'), 'Alpha Music LOGIN');
      expect(loginModalTitle(''), 'LOGIN');
      expect(loginModalSubtitle('可选登录'), '可选登录');
      expect(loginModalSubtitle(''), '可选登录，公开搜索不需要账号');

      final List<String> texts = _texts(modal().build().commands);
      expect(texts, contains('Alpha Music LOGIN'));
      expect(texts, contains('可选登录，公开搜索不需要账号'));
    });

    test('方式按钮行：坐标 x+53+index*145 / 宽 140 / 高 35 / 字号 13', () {
      final LoginModalFrame frame = modal().build();
      // 面板 left 330 → left = 383；y = 122 + 207 = 329。
      final HudHit first = frame.hits.firstWhere(
        (HudHit hit) => hit.action == 'music:login-method:qr',
      );
      expect(first.x, 383);
      expect(first.y, 329);
      expect(first.width, 140);
      expect(first.height, 35);
      final HudHit second = frame.hits.firstWhere(
        (HudHit hit) => hit.action == 'music:login-method:phone',
      );
      expect(second.x, 383 + 145);
      // NativeHudLibrary.cpp:281 的字号 13。
      final List<Object?> label = _textCommand(frame.commands, '扫码登录');
      expect(label[4], 13);
    });

    test('变体行替换方式行：步长 190 / 宽 180 / ✓ 前缀 / music:variant:<id>', () {
      final LoginModalFrame frame = modal(
        variants: <Map<String, Object?>>[
          <String, Object?>{'id': 'kugou', 'label': '酷狗'},
          <String, Object?>{'id': 'lite', 'label': '酷狗概念版'},
        ],
        selectedVariant: 'kugou',
      ).build();
      expect(_hitActions(frame.hits),
          isNot(contains('music:login-method:qr')));
      final HudHit first =
          frame.hits.firstWhere((HudHit h) => h.action == 'music:variant:kugou');
      expect(first.x, 383);
      expect(first.width, 180);
      final HudHit second =
          frame.hits.firstWhere((HudHit h) => h.action == 'music:variant:lite');
      expect(second.x, 383 + 190);
      expect(_texts(frame.commands), contains('✓ 酷狗'));
    });

    test('扫码分支：240 方框、deviceNotice 起点 y+520、重新生成按钮 y+626', () {
      final LoginModalFrame frame = modal(
        text: <String, String>{'deviceNotice': '请确认手机与电脑在同一网络。'},
      ).build();
      // 方框：x + usable/2 - 120 = 330 + 630 - 120 = 840；y = 122 + 260 = 382。
      final List<List<Object?>> fills = _ofType(frame.commands, 'fill');
      final List<Object?> box = fills.firstWhere(
        (List<Object?> c) => c[4] == 240 && c[5] == 240,
        orElse: () => throw StateError('missing 240 QR box'),
      );
      expect(box[2], 840);
      expect(box[3], 382);
      final List<Object?> notice =
          _textCommand(frame.commands, '请确认手机与电脑在同一网络。');
      expect(notice[3], 122 + 520); // :287
      final HudHit regenerate =
          frame.hits.firstWhere((HudHit h) => h.action == 'music:qr');
      expect(regenerate.x, 383);
      expect(regenerate.y, 122 + 626); // :292
      expect(regenerate.width, 260);
      expect(regenerate.height, 40);
      // NativeHudLibrary.cpp:292 的字号 15。
      final List<Object?> label = _textCommand(frame.commands, '重新生成二维码');
      expect(label[4], 15);
    });

    test('冷却中：不出重新生成按钮，改画 cooldownLabel 于 y+636', () {
      final LoginModalFrame frame =
          modal(cooldownLabel: '请等待 42 秒后重新生成').build();
      expect(_hitActions(frame.hits), isNot(contains('music:qr')));
      final List<Object?> label =
          _textCommand(frame.commands, '请等待 42 秒后重新生成');
      expect(label[2], 383);
      expect(label[3], 122 + 636); // :293
    });

    test('短信分支：只画三行标签，没有二维码方框与重新生成', () {
      final LoginModalFrame frame = modal(state: _state(methodId: 'phone')).build();
      final List<String> texts = _texts(frame.commands);
      expect(texts, contains('手机号码（中国大陆）')); // :295
      expect(texts, contains('短信验证码')); // :296
      expect(texts, contains('按 ENTER 登录')); // :297
      expect(_hitActions(frame.hits), isNot(contains('music:qr')));
      final List<Object?> phoneLabel =
          _textCommand(frame.commands, '手机号码（中国大陆）');
      expect(phoneLabel[2], 383);
      expect(phoneLabel[3], 122 + 278);
      expect(phoneLabel[4], 14);
    });

    test('尾部：状态行 y+600、跳过按钮 y+709（close-modal）、钥匙串说明 y+785', () {
      final LoginModalFrame frame = modal(state: _state(status: '已扫描，请在手机上确认'))
          .build();
      final List<Object?> status =
          _textCommand(frame.commands, '已扫描，请在手机上确认');
      expect(status[2], 383);
      expect(status[3], 122 + 600);
      expect(status[4], 15);
      final HudHit skip = frame.hits.firstWhere(
        (HudHit h) => h.action == 'close-modal' && h.width == 350,
      );
      expect(skip.x, 383);
      expect(skip.y, 122 + 709);
      expect(skip.height, 45);
      final List<Object?> note = _textCommand(
          frame.commands, '凭据仅保存至本机钥匙串，不读取官方 App 的登录信息。');
      expect(note[3], 122 + 785);
      expect(note[4], 11);
    });

    test('命中表顺序：close-modal 先于内容命中（modal_shell 独占关闭热区）', () {
      final LoginModalFrame frame = modal().build();
      final List<String> actions = _hitActions(frame.hits);
      expect(actions.first, 'close-modal');
      expect(actions.where((String a) => a == 'close-modal').length, 2);
    });

    test('build 纯函数：两次构建命令与命中完全一致', () {
      final LoginModal subject = modal();
      final LoginModalFrame first = subject.build();
      final LoginModalFrame second = subject.build();
      expect(second.commands, first.commands);
      expect(second.hits, first.hits);
    });

    test('qrText 在无图片时按 11 号逐行画出（不画假二维码）', () {
      final LoginModalFrame frame =
          modal(state: _state(qrText: 'rhine://login/alpha-1')).build();
      expect(_hitActions(frame.hits), isNot(contains('image')));
      final List<String> texts = _texts(frame.commands);
      expect(texts.where((String t) => t.contains('rhine://')).length,
          greaterThan(0));
    });

    test('深色主题用 dark 的 control tint', () {
      final LoginModalFrame frame = modal(dark: true).build();
      final List<List<Object?>> fills = _ofType(frame.commands, 'fill');
      // modalShellControlTint(dark:true) == [.55,.59,.46,.13]
      expect(
        fills.any((List<Object?> c) =>
            (c[1]! as List<Object?>)[0] == 0.55 &&
            (c[1]! as List<Object?>)[1] == 0.59),
        isTrue,
      );
    });
  });

  // =========================================================================
  // 动作串常量（与 Qt 对齐的 identity check）
  // =========================================================================
  group('动作串常量', () {
    test('与 Qt NativeHudLibrary/NativeHudMusic 的字面量逐字一致', () {
      expect(kPortraitLoginRegenerateAction, 'music:qr'); // :292
      expect(kPortraitLoginLogoutAction, 'music:logout'); // :540
      expect(kPortraitLoginMethodPrefix, 'music:login-method:'); // :281
      expect(LoginModalChoice(id: 'qr', label: '扫码登录').action,
          'music:login-method:qr');
      expect(
        LoginModalChoice(id: 'kugou', label: '酷狗', isVariant: true).action,
        'music:variant:kugou',
      );
    });

    test('短信表单动作串为 Flutter 侧新增（Qt 由 QML overlay 直调原生方法）', () {
      // 记录这一对常量是 Flutter 新增而不是 Qt 抄来的，宿主接线时不要找 Qt 对应物。
      expect(kPortraitLoginSendCodeAction, 'music:login-send-code');
      expect(kPortraitLoginSubmitAction, 'music:login-submit');
    });
  });
}
