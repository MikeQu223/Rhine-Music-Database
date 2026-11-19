/// Flutter port of the Qt landscape 'login' modal body (modal == 'login').
///
/// Content only. The shared frame — save(), alpha(motion.opacity), the full-stage
/// scrim, translate(0, motion.offset), the panel base, the title band and the
/// close-modal hit — comes from lib/hud/modals/modal_shell.dart. This file adds
/// the login body; it never draws a scrim, a panel base, a title band or a close
/// hit of its own.
///
/// Qt evidence, line by line:
///
/// * dispatch: Qt/src/NativeHudModal.cpp:287-288 — modal == 'login' calls
///   loginPanel(x, y, usable).
/// * title / subtitle: Qt/src/NativeHudModal.cpp:1-30 — `registry.label(provider)
///   + " LOGIN"` and `registry.text(provider, "loginHint")` with the fallback
///   `可选登录，公开搜索不需要账号`.
/// * loginPanel: Qt/src/NativeHudLibrary.cpp:271-330 (all coordinates below are
///   relative to the panel x/width, exactly as Qt passes them).
/// * method / variant buttons: :272-281 — variants replace the method row at
///   `x+53+index*190`, otherwise the methods sit at `x+53+index*145`; both are
///   35 tall, 13 point labels, actions `music:variant:<id>` / `music:login-method:<id>`.
/// * QR branch: :283-292 — `image(qr, x+width/2-120, y+260, 240, 240)`,
///   `deviceNotice` wrapped to `width-106` from `y+520` (18 unit leading), and
///   either the `重新生成二维码` button at `y+626` (`music:qr`) or the cooldown
///   label at `y+636`.
/// * SMS branch: :294-297 — the two field labels and the `按 ENTER 登录` hint.
/// * tail: :300-329 — status line at `y+600`, the `本轮跳过账号验证` button at
///   `y+709` (`close-modal`), the keychain note at `y+785`.
/// * wrap(): Qt/src/Glyphs.cpp:350-402 (grapheme branch :361-379).
/// * primitives: Qt/src/NativeHud.cpp:10-15 (ink), :37-39 (fill), :40-43 (text),
///   :48-76 (fit), :77-79 (limited), :102-109 (hit), :110-120 (button), :125-129 (rule).
///
/// Deliberately **not** owned here: the login state machine (`LoginController`),
/// the network calls, credential storage, the QR rendering itself and the
/// open/close animation. This file paints one frame from an immutable
/// [LoginState] snapshot and nothing else.
library;

import 'package:rhine_music_database/domain/account/login_controller.dart' show LoginState;
import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart' show ProviderLoginMethod;

/// The modal id this body renders under (Qt modal == 'login', :287).
const String kLoginModalId = 'login';

/// Qt `modalTitle("login")` (Qt/src/NativeHudModal.cpp:27): `<platform label> LOGIN`.
String loginModalTitle(String providerLabel) =>
    providerLabel.isEmpty ? 'LOGIN' : '$providerLabel LOGIN';

/// Qt `modalSubtitle("login")` (Qt/src/NativeHudModal.cpp:53).
String loginModalSubtitle(String loginHint) =>
    loginHint.isEmpty ? '可选登录，公开搜索不需要账号' : loginHint;

/// One entry of the method row (`music:login-method:<id>` / `music:variant:<id>`).
final class LoginModalChoice {
  const LoginModalChoice({required this.id, required this.label, this.isVariant = false});

  /// Method or variant id.
  final String id;

  /// Button label (manifest `label`, or the variant label).
  final String label;

  /// Qt swaps the method row for the variant row when the platform has variants
  /// (NativeHudLibrary.cpp:272-281).
  final bool isVariant;

  /// Action string Qt emits (`NativeHudLibrary.cpp:279` / `:281`).
  String get action => isVariant ? 'music:variant:$id' : 'music:login-method:$id';
}

/// Paints one frame. Pure: no I/O, no mutation, no global state.
final class LoginModal {
  const LoginModal({
    required this.textPort,
    required this.stageWidth,
    required this.state,
    this.text = const <String, String>{},
    this.methods = const <ProviderLoginMethod>[],
    this.variants = const <Map<String, Object?>>[],
    this.selectedVariant = '',
    this.cooldownLabel = '',
    this.title = 'LOGIN',
    this.subtitle = '可选登录，公开搜索不需要账号',
    this.dark = false,
    this.opacity = 1,
    this.offset = 0,
  });

  /// Glyph port shared with the shell (real advances only).
  final HudTextPort textPort;

  /// Stage width (the shell centres the panel within it).
  final double stageWidth;

  /// Immutable login snapshot (provider/method/qr/status/cooldown…).
  final LoginState state;

  /// Platform `strings` table; `scanHint` / `deviceNotice` are read here.
  final Map<String, String> text;

  /// `login.methods` projection (used when [variants] is empty).
  final List<ProviderLoginMethod> methods;

  /// `variants` raw list; non-empty replaces the method row (Qt :272-281).
  final List<Map<String, Object?>> variants;

  /// Current variant id (paints a `✓ ` prefix and is passed through in the action).
  final String selectedVariant;

  /// Value the controller's `cooldownLabel` getter produced: empty means the
  /// `重新生成二维码` button is available; otherwise it is the one-line label Qt
  /// paints instead (NativeHudLibrary.cpp:291-292).
  final String cooldownLabel;

  /// Title band text (the shell owns the band; caller passes
  /// [loginModalTitle]).
  final String title;

  /// Title band subtitle ([loginModalSubtitle]).
  final String subtitle;

  /// Dark palette flag.
  final bool dark;

  /// Shell motion opacity (1 = fully shown).
  final double opacity;

  /// Shell motion offset (0 = settled).
  final double offset;

  /// Paints one frame.
  LoginModalFrame build() {
    final _CommandSink sink = _CommandSink();
    final ModalShellResult result = ModalShell(
      sink: sink,
      text: textPort,
      spec: ModalShellSpec(
        modalId: kLoginModalId,
        stageWidth: stageWidth,
        dark: dark,
        opacity: opacity,
        offset: offset,
        title: title,
        subtitle: subtitle,
        content: _paint,
      ),
    ).build();
    return LoginModalFrame(
      commands: sink.commands,
      hits: result.hits,
      bounds: result.bounds,
      policy: result.policy,
    );
  }

  /// The visible choice row: variants win when the platform declares any
  /// (NativeHudLibrary.cpp:272-281).
  List<LoginModalChoice> get choices {
    if (variants.isNotEmpty) {
      return <LoginModalChoice>[
        for (final Map<String, Object?> variant in variants)
          if ('${variant['id'] ?? ''}'.isNotEmpty)
            LoginModalChoice(
              id: '${variant['id']}',
              label: '${variant['label'] ?? variant['id']}',
              isVariant: true,
            ),
      ];
    }
    return <LoginModalChoice>[
      for (final ProviderLoginMethod method in methods)
        if (method.id.isNotEmpty)
          LoginModalChoice(
            id: method.id,
            label: method.label.isEmpty
                ? (method.type == 'sms' ? '手机号登录' : '扫码登录')
                : method.label,
          ),
    ];
  }

  /// Whether the current method is the QR branch (`{"qr","wechat"}` contains it,
  /// NativeHudLibrary.cpp:283).
  bool get isQrBranch {
    final String id = state.methodId;
    if (id == 'qr' || id == 'wechat') {
      return true;
    }
    for (final ProviderLoginMethod method in methods) {
      if (method.id == id) {
        return method.type == 'qr';
      }
    }
    return false;
  }

  void _paint(ModalShellBody body) {
    final double x = body.bounds.left;
    final double y = body.bounds.top;
    final double usable = body.bounds.width;
    final double left = x + 53; // :294
    final double width = usable - 106; // :294

    _choiceRow(body, left, y + 207);
    if (isQrBranch) {
      _qrBranch(body, left, width, y);
    } else {
      // :294-297 — Qt also registers contentSink fields here ("account",
      // "captcha", "submit"); the Flutter shell has no field channel, so the
      // labels are painted and the host attaches its own text input.
      hudText(body.sink, '手机号码（中国大陆）', left, y + 278, 14, dark: dark); // :295
      hudText(body.sink, '短信验证码', left, y + 391, 14, dark: dark); // :296
      hudText(body.sink, '按 ENTER 登录', left, y + 532, 12, dark: dark); // :297
    }

    // :300 — limited(music.loginStatus, x+53, y+600, 15, width-106).
    if (state.status.isNotEmpty) {
      _limited(body, state.status, left, y + 600, 15, width);
    }

    // :302-304 — the one always-available exit.
    _button(body, '本轮跳过账号验证', left, y + 709, 350, 45, 'close-modal', 16);

    // :306 — the keychain note.
    hudText(
      body.sink,
      '凭据仅保存至本机钥匙串，不读取官方 App 的登录信息。',
      left,
      y + 785,
      11,
      dark: dark,
    );
  }

  /// Method / variant row (NativeHudLibrary.cpp:272-281).
  void _choiceRow(ModalShellBody body, double left, double y) {
    final List<LoginModalChoice> row = choices;
    if (row.isEmpty) {
      return;
    }
    const double height = 35;
    for (int index = 0; index < row.length; index++) {
      final LoginModalChoice choice = row[index];
      final double stride = choice.isVariant ? 190 : 145;
      final double buttonWidth = choice.isVariant ? 180 : 140;
      final double x = left + index * stride;
      final String label = choice.isVariant
          ? '${selectedVariant == choice.id ? '✓ ' : ''}${choice.label}'
          : choice.label;
      _button(body, label, x, y, buttonWidth, height, choice.action, 13);
    }
  }

  /// QR branch (NativeHudLibrary.cpp:283-292).
  void _qrBranch(ModalShellBody body, double left, double width, double y) {
    final double x = body.bounds.left;
    final double half = body.bounds.width / 2;
    final double boxLeft = x + half - 120;
    final double boxTop = y + 260;
    const double box = 240;

    // Qt draws `image(qr, ...)`: the host QR object is either an image or text.
    // Without either, paint an honest placeholder box — never a fake QR.
    if (state.qrImage.isEmpty) {
      hudFill(body.sink, modalShellControlTint(dark: dark), boxLeft, boxTop, box, box);
      hudRule(body.sink, dark, boxLeft, boxTop, box, 0.6);
      hudRule(body.sink, dark, boxLeft, boxTop + box - 1, box, 0.6);
    }
    if (state.qrImage.isNotEmpty) {
      hudOp(body.sink, <Object?>['image', state.qrImage, boxLeft + 12, boxTop + 12, box - 24, box - 24]);
    } else if (state.qrText.isNotEmpty) {
      final List<String> lines = _wrap(state.qrText, box - 24, 11);
      final int visible = lines.length > 12 ? 12 : lines.length;
      for (int index = 0; index < visible; index++) {
        hudText(body.sink, lines[index], boxLeft + 12, boxTop + 12 + index * 16, 11, dark: dark);
      }
    }

    // :286-289 — device notice wrapped at width-106, 18 apart, from y+520.
    final String notice = text['deviceNotice'] ?? '';
    if (notice.isNotEmpty) {
      final List<String> lines = _wrap(notice, width, 13);
      for (int index = 0; index < lines.length; index++) {
        hudText(body.sink, lines[index], left, y + 520 + index * 18, 13, dark: dark);
      }
    }

    // :291-292 — regenerate button, or the one-line cooldown label when refused.
    if (cooldownLabel.isEmpty) {
      _button(body, '重新生成二维码', left, y + 626, 260, 40, 'music:qr', 15);
    } else {
      hudText(body.sink, cooldownLabel, left, y + 636, 15, dark: dark);
    }
  }

  /// Qt NativeHud::button (Qt/src/NativeHud.cpp:110-120).
  void _button(
    ModalShellBody body,
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size,
  ) {
    body.hit(x, y, width, height, action, label); // :112
    final double inset = width / 8 < 10 ? width / 8 : 10; // :113
    hudFill(body.sink, modalShellControlTint(dark: dark), x, y, width, height); // :115-116
    hudText(
      body.sink,
      textPort.fit(label, size, width - inset * 2), // :118
      x + inset,
      y + (height - size) / 2 - 4,
      size,
      dark: dark,
    ); // :119
  }

  /// Qt Glyphs::wrap grapheme branch (Qt/src/Glyphs.cpp:361-379).
  List<String> _wrap(String value, double limit, double size) {
    final List<String> lines = <String>[];
    String line = '';
    for (final int rune in value.runes) {
      final String cluster = String.fromCharCode(rune);
      if (cluster == '\n') {
        lines.add(line);
        line = '';
      } else if (line.isNotEmpty && textPort.glyphWidth(line + cluster, size) > limit) {
        lines.add(line);
        line = cluster;
      } else {
        line += cluster;
      }
    }
    lines.add(line);
    return lines;
  }

  /// Qt limited(value, x, y, size, width, weight) (Qt/src/NativeHud.cpp:77-79).
  void _limited(
    ModalShellBody body,
    String value,
    double x,
    double y,
    double size,
    double width, [
    String weight = 'regular',
  ]) {
    hudText(
      body.sink,
      textPort.fit(value, size, width, weight),
      x,
      y,
      size,
      weight: weight,
      dark: dark,
    );
  }
}

/// Painted frame of one login modal.
final class LoginModalFrame {
  const LoginModalFrame({
    required this.commands,
    required this.hits,
    required this.bounds,
    required this.policy,
  });

  /// Wire commands in Qt emission order.
  final List<List<Object?>> commands;

  /// Hit table (stage coordinates, fixed:true).
  final List<HudHit> hits;

  /// Panel bounds the shell computed.
  final ModalShellBounds bounds;

  /// Policy the shell applied (scrim / title band / back action).
  final ModalShellPolicy policy;
}

/// Command-only sink: hits go through the shell's ModalShellHitTable (body.hit).
final class _CommandSink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => throw UnsupportedError('LoginModal 只通过 ModalShellBody.hit 发命中。');
}
