/// 竖屏（compact）「账号登录」整页：命令流排版，不建 widget。
///
/// 真源与取舍：
/// - Qt 的竖屏页面表 `Qt/src/ResponsiveHudPages.cpp` **没有**登录页（登录只有
///   横屏弹层 `loginPanel`，NativeHudLibrary.cpp:271-330 + QML Overlay 的表单）。
///   竖屏能进登录的入口只有两处：设置页 ACCESS 卡的 `music:login` / `music:logout`
///   （ResponsiveHudPages.cpp:527-545）与平台页 03 ACCOUNT 的 `账号登录 / <平台>`
///   （:647-680）。本文件就是把弹层那套状态机搬成竖屏内页。
/// - 二维码分支抄横屏 `loginPanel` 的语义而不是坐标：`qr` 有图片就 `image()`，
///   没有图片就「占位方框 + qrText」（Qt 侧 `qr` 是宿主渲染对象，文本二维码也合法）；
///   提示串取平台 `strings.scanHint`，空则 `请用<平台名>扫描并确认登录`
///   （NativeHudLibrary.cpp 的 `prepareQR` 兜底，MusicAccount.cpp:606-611 同文）。
/// - 短信分支抄 Qt `sendLoginCode`/`captchaLogin` 的**表单语义**：手机号框、验证码框、
///   「发送验证码 / N 秒后重发」按钮、"登录 →" 按钮；按下动作与 Qt QML overlay 同一
///   语义，但动作串是 Flutter 侧新增（Qt 走 `rhine.sendLoginCode`/`submitForm`），
///   见文件里三个 `kPortraitLogin*Action` 常量，宿主接线时直接取用。
///
/// 页宽一律读 `c.gridWidth`（设计稿 353 = 393 - 40，DPI 适配后页更宽），不写死 393。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:qr/qr.dart';

import '../../domain/account/login_controller.dart' show LoginState;
import '../../provider/provider_gateway.dart' show ProviderLoginMethod;
import '../scale/portrait_rhythm.dart';
import 'portrait_canvas.dart';

/// 「发送验证码」按钮动作（Flutter 侧新增；Qt 由 QML overlay 直接调 `rhine.sendLoginCode`）。
const String kPortraitLoginSendCodeAction = 'music:login-send-code';

/// 「登录 →」按钮动作（Flutter 侧新增；Qt 由 QML overlay 调 `submitForm`）。
const String kPortraitLoginSubmitAction = 'music:login-submit';

/// 「重新生成二维码」按钮动作（与横屏 `loginPanel` 同一串，NativeHudLibrary.cpp:288）。
const String kPortraitLoginRegenerateAction = 'music:qr';

/// 「退出登录」动作（Qt ResponsiveHudPages.cpp:538 原文）。
const String kPortraitLoginLogoutAction = 'music:logout';

/// 登录方式按钮的动作前缀（Qt `music:login-method:<id>`，NativeHudMusic.cpp:414-446）。
const String kPortraitLoginMethodPrefix = 'music:login-method:';

/// 正文左右留白（Qt 全站 20 / 373）。
const double _gutter = 20;

/// 方式按钮高度。
const double _methodHeight = 36;

/// 二维码占位方框边长上限（横屏 `loginPanel` 的 240）。
const double _qrMax = 240;

/// 画「账号登录」竖屏页。返回前会调用 `c.finish()`。
///
/// [state] 来自 [LoginController]；[methods] 平台的登录方式（descriptor 的
/// `login.methods`）；[providerName] 平台中文名（`display.name`）；
/// [scanHint] 平台 `strings.scanHint`（空则用 Qt 兜底串）；
/// [deviceNotice] 平台 `strings.deviceNotice`（空则不画）；
/// [cooldownLabel]/[smsRetrySeconds] 由控制器算好传进来（Qt 里也是 `loginPanel`
/// 现算，不是状态字段）。
void paintPortraitLoginPage(
  PortraitCanvas c, {
  required LoginState state,
  required List<ProviderLoginMethod> methods,
  required String providerName,
  String scanHint = '',
  String deviceNotice = '',
  String cooldownLabel = '',
  int smsRetrySeconds = 0,
}) {
  final double width = c.gridWidth - 2 * _gutter;
  final double height = c.height;
  // 整页纸色（与资料库内页同源，ResponsiveHudLayout.cpp:96-98）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, height), c.paper);
  // 登录层是弹层：返回键必须关层，不能落回 `back`（那会把目录栈弹掉、层还留着）。
  c.header('账号登录', back: true, backAction: 'close-modal');

  // 起点按页高节奏收：矮屏上固定 126 会把二维码下半截挤出裁剪线。
  final double top = math.min(PortraitRhythm.below(90, 126.0, height), height * .22);
  final double bottom = _pageBottom(c, top);

  double y = top;
  // 平台名 + 已登录/未登录（平台页 03 ACCOUNT 的排法，ResponsiveHudPages.cpp:647-680）。
  c.text(providerName.isEmpty ? '音乐平台' : providerName, _gutter, y,
      size: 15, width: width - 96, weight: 'demibold');
  c.rightText(state.loggedIn ? '已登录' : '未登录', _gutter + width, y + 3, 10,
      'regular', state.loggedIn ? c.ink : c.muted);
  y += 26;

  if (state.loggedIn) {
    _paintLoggedIn(c, state, y, width, bottom);
    c.finish();
    return;
  }

  // 登录方式切换（Qt `music:login-method:<id>`；竖屏用 chip 行代替弹层的 140×35 按钮）。
  y = _paintMethods(c, methods, state.methodId, y, width);
  y += 12;

  final bool qrBranch = _isQrMethod(state.methodId, methods);
  if (qrBranch) {
    y = _paintQrBranch(
      c,
      state: state,
      providerName: providerName,
      scanHint: scanHint,
      deviceNotice: deviceNotice,
      cooldownLabel: cooldownLabel,
      y: y,
      width: width,
      bottom: bottom,
    );
  } else {
    y = _paintSmsBranch(
      c,
      state: state,
      smsRetrySeconds: smsRetrySeconds,
      y: y,
      width: width,
      bottom: bottom,
    );
  }

  // 失败/成功文案（Qt `limited(loginStatus, ...)` 的竖屏等价物）。
  if (state.status.isNotEmpty && !qrBranch) {
    y = c.paragraph(state.status, _gutter, y + 8,
            size: 12, width: width, color: c.muted) +
        10;
  }

  // 尾部说明（Qt `loginPanel` 的最后一行，NativeHudLibrary.cpp:329）。
  if (y + 30 <= bottom) {
    c.paragraph(
      '凭据仅保存至本机钥匙串，不读取官方 App 的登录信息。',
      _gutter,
      math.max(y + 8, bottom - c.gestureInset),
      size: 10,
      width: width,
      color: c.muted,
      maximumLines: 2,
    );
  }
  c.finish();
}

/// 已登录态：昵称 + 账号 id + 退出登录（Qt ResponsiveHudPages.cpp:527-545 的 ACCESS 卡）。
void _paintLoggedIn(PortraitCanvas c, LoginState state, double y, double width, double bottom) {
  final Rect card = Rect.fromLTWH(_gutter, y, width, 96);
  c.fill(card, c.surface);
  c.fill(Rect.fromLTWH(_gutter, y, 2, 96), c.amber);
  c.text(state.nickname.isEmpty ? '未登录' : state.nickname, _gutter + 13, y + 18,
      size: 18, width: width - 40, weight: 'demibold');
  c.text('账号 id / ${state.accountId}', _gutter + 13, y + 50,
      size: 10, width: width - 40, color: c.muted);
  c.text('各平台账号与个人音乐独立保存。', _gutter + 13, y + 70,
      size: 10, width: width - 40, color: c.muted);
  if (y + 96 + 20 < bottom) {
    c.button(
      Rect.fromLTWH(_gutter, y + 116, width, 44),
      '退出登录',
      kPortraitLoginLogoutAction,
    );
  }
}

/// 登录方式 chip 行；返回下一行的 y。
double _paintMethods(
  PortraitCanvas c,
  List<ProviderLoginMethod> methods,
  String selected,
  double y,
  double width,
) {
  if (methods.isEmpty) {
    return y;
  }
  const double gap = 8;
  final double cell = (width - gap * (methods.length - 1)) / methods.length;
  for (int index = 0; index < methods.length; index++) {
    final ProviderLoginMethod method = methods[index];
    final String label =
        method.label.isEmpty ? (method.type == 'sms' ? '手机号登录' : '扫码登录') : method.label;
    c.chip(
      Rect.fromLTWH(_gutter + index * (cell + gap), y, cell, _methodHeight),
      label,
      '$kPortraitLoginMethodPrefix${method.id}',
      selected: method.id == selected,
    );
  }
  return y + _methodHeight;
}

/// 扫码分支：状态区 + 二维码方框（图片或文本）+ 提示串 + 重新生成。
double _paintQrBranch(
  PortraitCanvas c, {
  required LoginState state,
  required String providerName,
  required String scanHint,
  required String deviceNotice,
  required String cooldownLabel,
  required double y,
  required double width,
  required double bottom,
}) {
  final double limit = math.max(0, bottom - y - 96);
  final double side = math.max(80, math.min(_qrMax, math.min(width, limit)));
  final Rect box = Rect.fromLTWH(c.gridWidth / 2 - side / 2, y, side, side);

  // 方框永远在：没有真实图片时它就是占位框，绝不画假二维码。
  c.fill(box, c.surface);
  c.border(box, c.line);
  if (state.qrImage.isNotEmpty) {
    c.image(state.qrImage, box.deflate(12));
  } else if (state.qrText.isNotEmpty) {
    // 文本二维码（Qt 的 `qr(text)` 分支）：**真的把内容编成二维码**再画模块。
    // 插件（netease 等）只回 `qrText`（登录 URL），宿主必须自己渲染，扫码器才认。
    if (!_paintQr(c, state.qrText, box)) {
      // 编码失败（内容过长/非法）才退回纯文本，绝不画假二维码。
      c.paragraph(
        state.qrText,
        box.left + 12,
        box.top + math.max(12, side / 2 - 18),
        size: 10,
        width: side - 24,
        color: c.ink,
        maximumLines: math.max(1, (side - 24).floor() ~/ 8),
      );
    }
  } else {
    c.icon('database', box.left + side / 2 - 16, box.top + side / 2 - 16,
        size: 32, color: c.muted);
  }

  double cursor = box.bottom + 14;
  final String hint = scanHint.isEmpty ? '请用${providerName.isEmpty ? '手机' : providerName}扫描并确认登录'
      : scanHint;
  cursor = c.paragraph(hint, _gutter, cursor, size: 13, width: width, color: c.ink) + 8;

  if (state.status.isNotEmpty && state.status != hint) {
    cursor = c.paragraph(state.status, _gutter, cursor, size: 12, width: width, color: c.muted) + 8;
  }

  if (deviceNotice.isNotEmpty) {
    cursor = c.paragraph(deviceNotice, _gutter, cursor, size: 11, width: width, color: c.muted) + 8;
  }

  if (cursor + 44 <= bottom) {
    if (cooldownLabel.isEmpty) {
      c.button(
        Rect.fromLTWH(_gutter, cursor, width, 44),
        '重新生成二维码',
        kPortraitLoginRegenerateAction,
      );
    } else {
      // Qt `loginPanel` 不能重新生成时只画一行：`请等待 N 秒后重新生成` / `正在处理扫码登录…`。
      c.text(cooldownLabel, _gutter, cursor + 14, size: 13, width: width, color: c.muted);
    }
    cursor += 52;
  }
  return cursor;
}

/// 短信分支：手机号框 + 发送按钮 + 验证码框 + 登录按钮（Qt QML overlay 的表单语义）。
double _paintSmsBranch(
  PortraitCanvas c, {
  required LoginState state,
  required int smsRetrySeconds,
  required double y,
  required double width,
  required double bottom,
}) {
  double cursor = y;
  // 手机号行：label + 输入框 + 右侧发送按钮（Qt QML 170*s 宽、在框右侧）。
  c.text('手机号码（中国大陆）', _gutter, cursor, size: 11, width: width, color: c.muted);
  cursor += 20;
  const double sendWidth = 96;
  final double fieldWidth = math.max(0, width - sendWidth - 8);
  final Rect phoneField = Rect.fromLTWH(_gutter, cursor, fieldWidth, 40);
  c.fill(phoneField, c.raised);
  c.border(phoneField, c.line);
  c.field('account', phoneField);
  final bool canSend = !state.loading && smsRetrySeconds == 0;
  final String sendLabel = smsRetrySeconds > 0 ? '$smsRetrySeconds 秒后重发' : '发送验证码';
  c.text(
    sendLabel,
    phoneField.right + 8 + (sendWidth - c.measure(sendLabel, 12)) / 2,
    cursor + 13,
    size: 12,
    width: sendWidth,
    color: canSend ? c.ink : c.muted,
  );
  // 发送按钮的热区：禁用时仍发命中，宿主据 controller 的冷却状态自行忽略。
  c.hit(
    Rect.fromLTWH(phoneField.right + 8, cursor, sendWidth, 40),
    kPortraitLoginSendCodeAction,
    sendLabel,
  );
  cursor += 52;

  // 验证码行。
  c.text('短信验证码', _gutter, cursor, size: 11, width: width, color: c.muted);
  cursor += 20;
  final Rect codeField = Rect.fromLTWH(_gutter, cursor, width, 40);
  c.fill(codeField, c.raised);
  c.border(codeField, c.line);
  c.field('captcha', codeField);
  cursor += 52;

  if (cursor + 44 <= bottom) {
    c.button(
      Rect.fromLTWH(_gutter, cursor, width, 44),
      '登录 →',
      kPortraitLoginSubmitAction,
      primary: true,
    );
    cursor += 52;
  }
  return cursor;
}

/// 当前方式是否扫码分支（Qt `{"qr","wechat"}.contains(loginMethod)`，:277）。
bool _isQrMethod(String methodId, List<ProviderLoginMethod> methods) {
  for (final ProviderLoginMethod method in methods) {
    if (method.id == methodId) {
      return method.type == 'qr';
    }
  }
  return methodId == 'qr' || methodId == 'wechat';
}

/// 页面可用底边：`contentBottom` 与真实高度取小，留 6 单位安全边。
double _pageBottom(PortraitCanvas c, double top) {
  final double limit = math.max(0.0, math.min(c.contentBottom, c.height) - 6);
  return math.max(top + 60, limit);
}


/// 把文本编成二维码并逐模块填色；成功返回 true。
///
/// 插件只回 `qrText`（`netease` 的 `loginBegin` 返回
/// `https://music.163.com/login?codekey=<token>`），Qt 侧是宿主渲染的
/// `qr(text)`，这里用 `qr` 包做同样的事：纸色底 + 墨色模块，四周留 12 网格静区。
bool _paintQr(PortraitCanvas c, String data, Rect box) {
  try {
    final QrCode code = QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
    final QrImage image = QrImage(code);
    final int count = image.moduleCount;
    if (count <= 0) {
      return false;
    }
    final double inset = 12;
    final double usable = math.min(box.width, box.height) - inset * 2;
    final double cell = usable / count;
    final double left = box.left + (box.width - usable) / 2;
    final double top = box.top + (box.height - usable) / 2;
    for (int row = 0; row < count; row++) {
      for (int col = 0; col < count; col++) {
        if (!image.isDark(row, col)) {
          continue;
        }
        c.fill(
          Rect.fromLTWH(left + col * cell, top + row * cell, cell + .2, cell + .2),
          c.ink,
        );
      }
    }
    return true;
  } on Object {
    return false;
  }
}
