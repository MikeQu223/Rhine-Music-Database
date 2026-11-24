/// T32-80 的 IME / 输入框 / 无障碍语义断言（W3 收敛后的静态对账）。
///
/// RED/GREEN 未执行（per-task ban；本轮 W3 同样未执行）
///
/// 本文件按任务禁令**只写不跑**：没有执行过 flutter test / dart test / analyze，
/// 因此下列断言既没有 RED 记录也没有 GREEN 记录，全部记为「未执行」。
/// 本轮（W3）只做静态修订：按钮 opacity 现在按 formFields.modalOpacity 合成
/// （Overlay.qml:362 × 416/469），相关用例显式给 modalOpacity: 1，并新增淡入用例；
/// 仍未执行 flutter test / dart test / analyze。
///
/// ## 静态可解析性说明
/// - 产品代码：lib/hud/input/text_input_overlay.dart、lib/hud/a11y/semantics_layer.dart。
/// - 导入链：本文件 → text_input_overlay.dart 的 `import 'key_router.dart' show HudAction`
///   → key_router.dart → wheel_router.dart:48 → hit_layer.dart:39 →
///   ../protocol/hud_hit.dart（HudHit）。该文件只存在于 T30 树（dev-hud-protocol 分支），
///   本树按计划尚未集成，因此整条链在本树**预期不可解析**；semantics_layer.dart 也依赖
///   同一个 hud_hit.dart。这是跨树集成缺口，不是本轮缺陷（与 hit_layer.dart 现状一致）；
///   禁止把 hud_hit.dart 复制进 T32。除此之外的断言只依赖本树已存在文件。
/// - 导入一律用 package:rhine_music_database/...（pubspec name 已确认）。
///
/// ## 断言与 Qt 断言的一一对应
/// 每组 test 的组名/首行注释都标了 Qt 出处；关键处给出行号，便于静态审查逐条对账：
///   Overlay.qml:519-562 检索框、384-461 两个表单字段、575-602 设置编辑框、
///   553-561 占位文案、363-369 可见性迁移、370-376 提交、408-483 两个按钮、
///   187-196 hits 语义；Engine.cpp:1006-1012 searchAccepted；InputMethodChecks.cpp:28-71
///   预编辑/提交语义。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/input/text_input_overlay.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/a11y/semantics_layer.dart';

/// 记录型端口：断言「业务副作用发给了谁、发了什么」。
class RecordingPorts implements TextInputPorts {
  RecordingPorts();

  final List<String> calls = <String>[];

  void clear() => calls.clear();

  @override
  void action(String action) => calls.add('action:$action');

  @override
  void query(String text) => calls.add('query:$text');

  @override
  void searchAccepted(String text, {required bool control}) =>
      calls.add('searchAccepted:$text:$control');

  @override
  void submitForm(String account, String captcha) =>
      calls.add('submitForm:$account:$captcha');

  @override
  void sendLoginCode(String phone) => calls.add('sendLoginCode:$phone');

  @override
  void settingEditText(String text) => calls.add('settingEditText:$text');

  @override
  void settingEditAccepted() => calls.add('settingEditAccepted');

  @override
  void settingEditCancel() => calls.add('settingEditCancel');

  @override
  void focusInputLayer() => calls.add('focusInputLayer');
}

void expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 1e-9), reason: 'left');
  expect(actual.top, closeTo(expected.top, 1e-9), reason: 'top');
  expect(actual.width, closeTo(expected.width, 1e-9), reason: 'width');
  expect(actual.height, closeTo(expected.height, 1e-9), reason: 'height');
}

/// Effect 的可读投影，便于失败信息直接指出是哪条迁移。
String describeEffect(TextInputEffect effect) {
  final String field =
      effect.field == null ? '-' : effect.field!.objectName;
  return '${effect.kind}:$field:${effect.text ?? ''}';
}

List<String> describeEffects(List<TextInputEffect> effects) =>
    effects.map(describeEffect).toList();

/// 调色板：与 text_input_overlay.dart 的映射一一对应（QML 十六进制 → 0xFFRRGGBB）。
class P {
  static const Color eeeeeb = Color(0xFFEEEEEB);
  static const Color s161914 = Color(0xFF161914);
  static const Color s30312b = Color(0xFF30312B);
  static const Color d9d8ce = Color(0xFFD9D8CE);
  static const Color s2b332c = Color(0xFF2B332C);
  static const Color e5e7da = Color(0xFFE5E7DA);
  static const Color s4a554b = Color(0xFF4A554B);
  static const Color aab0a0 = Color(0xFFAAB0A0);
  static const Color s777b60 = Color(0xFF777B60);
  static const Color f0eee5 = Color(0xFFF0EEE5);
  static const Color e9e7da = Color(0xFFE9E7DA);
  static const Color s222a25 = Color(0xFF222A25);
  static const Color ebebeb = Color(0xFFEBEBEB);
  static const Color s141613 = Color(0xFF141613);
  static const Color a2aa9d = Color(0xFFA2AA9D);
  static const Color s626b60 = Color(0xFF626B60);
  static const Color s777777 = Color(0xFF777777);
  static const Color white = Color(0xFFFFFFFF);
}

void main() {
  const TextInputOverlayLogic logic = TextInputOverlayLogic(
    ports: _NoopPorts(),
  );

  // ---------------------------------------------------------------------------
  // 真实文本输入栈：composing / selection / 占位规则
  // ---------------------------------------------------------------------------

  group('composing 来自 TextEditingValue.composing（Qt InputMethodChecks.cpp:28-71）', () {
    test('预编辑 ceshi：text 含预编辑，committedText 为空、preeditText 为 ceshi', () {
      // Qt: 输入 "ceshi" 后 preeditText == "ceshi" 且 text == ""。
      // Flutter 的 EditableText 把预编辑并入 value.text，故必须用 composing 区间剥离。
      const TextEditingValue value = TextEditingValue(
        text: 'ceshi',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      expect(preeditText(value), 'ceshi');
      expect(committedText(value), '');
      // Overlay.qml:555 的 visible 条件：text 空 **且** 无 preeditText → 此时不显示占位。
      expect(showsPlaceholder(value), isFalse);
    });

    test('提交 测试：composing 折叠，committedText 即全文（Qt text == 测试）', () {
      const TextEditingValue value = TextEditingValue(
        text: '测试',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(preeditText(value), '');
      expect(committedText(value), '测试');
      expect(showsPlaceholder(value), isFalse);
    });

    test('中文可连续提交为 测试测试（不得对合法的相同命令去重）', () {
      // Qt: InputMethodChecks.cpp 断言连续两次提交得到 "测试测试"。
      TextEditingValue value = valueForText('测试');
      value = TextEditingValue(
        text: '${value.text}测试',
        selection: const TextSelection.collapsed(offset: 4),
      );
      expect(value.text, '测试测试');
      expect(committedText(value), '测试测试');
    });

    test('composing 区间非法/越界时按无组合处理，不抛异常', () {
      const TextEditingValue collapsed = TextEditingValue(
        text: 'abc',
        composing: TextRange.empty,
      );
      expect(preeditText(collapsed), '');
      expect(committedText(collapsed), 'abc');

      const TextEditingValue outOfRange = TextEditingValue(
        text: 'abc',
        composing: TextRange(start: 1, end: 9),
      );
      expect(preeditText(outOfRange), '');
      expect(committedText(outOfRange), 'abc');
    });

    test('占位只在 text 空且无组合文本时可见（Overlay.qml:555）', () {
      expect(showsPlaceholder(const TextEditingValue(text: '')), isTrue);
      expect(
        showsPlaceholder(const TextEditingValue(text: 'a')),
        isFalse,
      );
      // 组合中：Qt 的 text 仍为空，但 preeditText 非空 → 占位隐藏。
      expect(
        showsPlaceholder(const TextEditingValue(
          text: 'zhong',
          composing: TextRange(start: 0, end: 5),
        )),
        isFalse,
      );
    });

    test('valueForText 把光标落在文本末尾（程序化赋值的最小语义）', () {
      final TextEditingValue value = valueForText('测试');
      expect(value.text, '测试');
      expect(value.selection, const TextSelection.collapsed(offset: 2));
      expect(value.composing, TextRange.empty);
    });

    test('真实 TextEditingController：selection 与 composing 都来自 controller.value', () {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);

      controller.value = const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      // 组合态就是 controller.value.composing —— 不是自造字符串。
      expect(controller.value.composing, const TextRange(start: 0, end: 5));
      expect(preeditText(controller.value), 'nihao');
      expect(committedText(controller.value), '');
      expect(controller.selection.baseOffset, 5);

      controller.value = const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(controller.value.composing, TextRange.empty);
      expect(committedText(controller.value), '你好');
    });

    test('TextCommitTracker 只吞掉「提交文本未变」的重复上报', () {
      final TextCommitTracker tracker = TextCommitTracker();
      expect(tracker.acceptText(''), isNull);
      expect(tracker.acceptText('测试'), '测试');
      expect(tracker.acceptText('测试'), isNull);
      expect(tracker.acceptText('测试测试'), '测试测试');
      tracker.resetTo('abc');
      expect(tracker.last, 'abc');
      expect(tracker.acceptText('abc'), isNull);
      expect(tracker.acceptText('abd'), 'abd');
    });
  });

  // ---------------------------------------------------------------------------
  // 几何：位置一律来自 state（Overlay.qml:528-531、358-360、567-570、579-582）
  // ---------------------------------------------------------------------------

  group('检索框 rect 来自 state.inputX/inputY/inputWidth + modalOffset（Overlay.qml:528-531）', () {
    test('x/y/width/height = 逐边乘 stageScale，高恒 54*stageScale', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'search',
          inputX: 100,
          inputY: 200,
          inputWidth: 800,
          modalOffset: 0,
          modalOpacity: 1,
        ),
      );
      expectRect(layout.rect, const Rect.fromLTWH(50, 100, 400, 27));
      expect(layout.visible, isTrue);
      expect(layout.kind, TextFieldKind.search);
      expect(layout.kind.objectName, 'musicSearchInput');
    });

    test('inputY 缺省回退 302（QML 的 state.inputY||302）', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'saved',
          inputX: 0,
          inputWidth: 100,
        ),
      );
      // (302 + 0) * 0.5
      expect(layout.rect.top, closeTo(151, 1e-9));
    });

    test('inputY 显式为 0 也回退 302（QML 的 || 把 0 当假，不是 ??）', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 100,
        ),
      );
      expect(layout.rect.top, closeTo(151, 1e-9));
    });

    test('modalOffset 加到 y 上（Overlay.qml:529），不影响 x', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'search',
          inputX: 10,
          inputY: 100,
          inputWidth: 300,
          modalOffset: 6,
        ),
      );
      expect(layout.rect.left, closeTo(5, 1e-9));
      expect(layout.rect.top, closeTo(53, 1e-9));
    });

    test('字号 22*stageScale、左 18*stageScale 右 14*stageScale（Overlay.qml:523-524、533）', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 100,
          rhineFontFamily: 'Rhine Sans',
        ),
      );
      expect(layout.fontSize, closeTo(11, 1e-9));
      expect(layout.fontFamily, 'Rhine Sans');
      expect(layout.padding.left, closeTo(9, 1e-9));
      expect(layout.padding.right, closeTo(7, 1e-9));
      expect(layout.padding.top, 0);
      expect(layout.padding.bottom, 0);
      expect(layout.clip, isTrue);
      expect(layout.selectByMouse, isTrue);
      expect(layout.verticallyCentered, isTrue);
      expect(layout.textStyle.fontSize, closeTo(11, 1e-9));
      expect(layout.textStyle.fontFamily, 'Rhine Sans');
      // 未声明 maximumLength：Qt TextInput 默认 32767（Overlay.qml:519-562 无该属性）。
      expect(layout.maxLength, 32767);
    });

    test('可见配色 dark/light 两套（Overlay.qml:534），不可见时用非 modal 配色', () {
      TextInputLayout layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 1,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 10,
          dark: true,
          modalOpacity: 1,
        ),
      );
      expect(layout.textColor, P.e9e7da);
      expect(layout.placeholderColor, P.a2aa9d);
      expect(layout.backdrop, isNotNull);
      expect(layout.backdrop!.color, P.white);
      expect(layout.backdrop!.opacity, closeTo(0, 1e-9));
      expect(layout.opacity, closeTo(1, 1e-9));

      layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 1,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 10,
          dark: false,
          modalOpacity: 1,
        ),
      );
      expect(layout.textColor, P.s222a25);
      expect(layout.placeholderColor, P.s626b60);
      expect(layout.backdrop!.color, P.s141613);

      // modal 为空 → 检索框不可见，配色换成「非 search/saved」那一支（Overlay.qml:534）。
      layout = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 1,
          modal: '',
          inputX: 0,
          inputY: 0,
          inputWidth: 10,
          dark: true,
          modalOpacity: 10,
        ),
      );
      expect(layout.visible, isFalse);
      expect(layout.textColor, P.ebebeb);
      expect(layout.placeholderColor, P.s777777);
      // 背景矩形在不可见时用 modalOpacity * 0.045（Overlay.qml:517）。
      expect(layout.backdrop!.opacity, closeTo(0.45, 1e-9));
      // Qt 的 opacity 属性钳制到 [0,1]；10 不能直接喂给 Flutter 的 Opacity。
      expect(layout.opacity, closeTo(1, 1e-9));
    });

    test('Accessible.name 逐字：本地/在线两套（Overlay.qml:539）且与 placeholder 同串', () {
      final TextInputLayout online = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 1,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 10,
        ),
      );
      expect(online.accessibilityName, '搜索歌曲、歌手、专辑或歌单');
      expect(online.placeholder, online.accessibilityName);
      expect(online.hasPlaceholder, isTrue);

      final TextInputLayout local = logic.layout(
        TextFieldKind.search,
        const TextInputStageState(
          stageScale: 1,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 10,
          localMusic: true,
        ),
      );
      expect(local.accessibilityName, '检索本地歌曲、歌手、专辑或文件夹');
      expect(local.placeholder, local.accessibilityName);
    });
  });

  group('表单字段 rect / 长度 / 输入法提示（Overlay.qml:384-461）', () {
    test('登录手机号：x 加 14*scale、宽减 208*scale、maximumLength 11、ImhDigitsOnly', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.account,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 100,
          inputWidth: 800,
          modalOffset: 6,
          modalOpacity: 1,
        ),
      );
      expectRect(layout.rect, const Rect.fromLTWH(57, 218, 296, 27.5));
      expect(layout.visible, isTrue);
      expect(layout.enabled, isTrue);
      expect(layout.maxLength, 11);
      expect(layout.digitsOnly, isTrue);
      expect(layout.sensitive, isFalse);
      expect(layout.accessibilityName, '手机号码');
      expect(layout.fontSize, closeTo(9.5, 1e-9));
      expect(layout.fontFamily, isNull);
      expect(layout.padding, EdgeInsets.zero);
      expect(layout.textColor, P.s161914);
      expect(layout.hasPlaceholder, isFalse);
      // 背后 Rectangle：登录时右边界让出 180*scale 给「发送验证码」（Overlay.qml:380）。
      expect(layout.backdrop, isNotNull);
      expectRect(layout.backdrop!.rect, const Rect.fromLTWH(50, 218, 310, 27.5));
      expect(layout.backdrop!.color, P.d9d8ce);
    });

    test('歌单名：宽减 28*scale、maximumLength 100、无数字提示、文案「歌单名称」', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.account,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'playlist-form',
          loginMethod: 'phone',
          inputX: 100,
          inputWidth: 800,
          dark: true,
          modalOpacity: 1,
        ),
      );
      expectRect(layout.rect, const Rect.fromLTWH(57, 215, 386, 27.5));
      expect(layout.maxLength, 100);
      expect(layout.digitsOnly, isFalse);
      expect(layout.accessibilityName, '歌单名称');
      expect(layout.textColor, P.eeeeeb);
      expect(layout.backdrop!.color, P.s30312b);
      expect(layout.backdrop!.rect.width, closeTo(400, 1e-9));
    });

    test('loginBusy 时手机号与验证码同时失能（Overlay.qml:396、456）', () {
      final TextInputStageState busy = const TextInputStageState(
        stageScale: 1,
        modal: 'login',
        loginMethod: 'phone',
        inputX: 0,
        inputWidth: 100,
        loginBusy: true,
      );
      expect(logic.layout(TextFieldKind.account, busy).enabled, isFalse);
      expect(logic.layout(TextFieldKind.captcha, busy).enabled, isFalse);
    });

    test('验证码：y 541*scale、宽减 28*scale、maximumLength 8、digits+sensitive', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.captcha,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 100,
          inputWidth: 800,
          modalOffset: 6,
          modalOpacity: 1,
        ),
      );
      expectRect(layout.rect, const Rect.fromLTWH(57, 273.5, 386, 27.5));
      expect(layout.maxLength, 8);
      expect(layout.digitsOnly, isTrue);
      // Qt.ImhSensitiveData（Overlay.qml:457）：关联想/个性化学习，但**不遮挡**文本。
      expect(layout.sensitive, isTrue);
      expect(layout.accessibilityName, '短信验证码');
      expectRect(layout.backdrop!.rect, const Rect.fromLTWH(50, 273.5, 400, 27.5));
    });

    test('歌单表单不显示验证码（Overlay.qml:446 的 visible: login）', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.captcha,
        const TextInputStageState(
          stageScale: 1,
          modal: 'playlist-form',
          inputX: 0,
          inputWidth: 100,
        ),
      );
      expect(layout.visible, isFalse);
    });

    test('playlist-form 下手机号字段仍可见（formVisible 的两支之一）', () {
      final TextInputStageState state = const TextInputStageState(
        stageScale: 1,
        modal: 'playlist-form',
        inputX: 0,
        inputWidth: 100,
      );
      expect(state.formVisible, isTrue);
      expect(state.loginMode, isFalse);
      expect(logic.layout(TextFieldKind.account, state).visible, isTrue);
    });

    test('login 但 loginMethod 不是 phone 时整块表单隐藏（Overlay.qml:357）', () {
      const TextInputStageState state = TextInputStageState(
        stageScale: 1,
        modal: 'login',
        loginMethod: 'qr',
        inputX: 0,
        inputWidth: 100,
      );
      expect(state.formVisible, isFalse);
      expect(logic.layout(TextFieldKind.account, state).visible, isFalse);
      expect(logic.button(FormButtonKind.submit, state, accountLength: 0).visible, isFalse);
    });
  });

  group('设置编辑框 rect（Overlay.qml:575-602）', () {
    test('内缩 12*scale、宽减 24*scale、字号 16*scale、带 1*scale 边框', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.settingEdit,
        const TextInputStageState(
          stageScale: 0.5,
          modal: '',
          modalOffset: 6,
          editingSetting: true,
          editingSettingValue: '旧值',
          editingSettingX: 10,
          editingSettingY: 20,
          editingSettingWidth: 300,
          editingSettingHeight: 40,
          rhineFontFamily: 'Rhine Sans',
          dark: false,
        ),
      );
      // 背景：(10*0.5, (20+6)*0.5, 300*0.5, 40*0.5) = (5, 13, 150, 20)
      expectRect(layout.backdrop!.rect, const Rect.fromLTWH(5, 13, 150, 20));
      // 字段：左 +12*0.5=6，宽 -24*0.5=12
      expectRect(layout.rect, const Rect.fromLTWH(11, 13, 138, 20));
      expect(layout.fontSize, closeTo(8, 1e-9));
      expect(layout.fontFamily, 'Rhine Sans');
      expect(layout.clip, isTrue);
      expect(layout.selectByMouse, isTrue);
      expect(layout.opacity, closeTo(1, 1e-9));
      // 未声明 maximumLength：Qt TextInput 默认 32767（Overlay.qml:575-602 无该属性）。
      expect(layout.maxLength, 32767);
      expect(layout.accessibilityName, '设置文本');
      expect(layout.backdrop!.color, P.e5e7da);
      expect(layout.backdrop!.borderColor, P.aab0a0);
      expect(layout.backdrop!.borderWidth, closeTo(0.5, 1e-9));
      expect(layout.rect.width, greaterThanOrEqualTo(0));
    });

    test('宽度不足时字段宽夹到 0（QML 的 max(0, ...)，Overlay.qml:581）', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.settingEdit,
        const TextInputStageState(
          stageScale: 1,
          modal: '',
          editingSetting: true,
          editingSettingX: 0,
          editingSettingY: 0,
          editingSettingWidth: 10,
          editingSettingHeight: 20,
        ),
      );
      expect(layout.rect.width, 0);
    });

    test('editingSetting 为 false 时不可见（Overlay.qml:578）', () {
      final TextInputLayout layout = logic.layout(
        TextFieldKind.settingEdit,
        const TextInputStageState(
          stageScale: 1,
          modal: '',
          editingSetting: false,
          editingSettingX: 0,
          editingSettingY: 0,
          editingSettingWidth: 100,
          editingSettingHeight: 20,
        ),
      );
      expect(layout.visible, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 两个按钮（Overlay.qml:408-434、462-483）
  // ---------------------------------------------------------------------------

  group('发送验证码按钮（Overlay.qml:408-434）', () {
    const TextInputStageState base = TextInputStageState(
      stageScale: 0.5,
      modal: 'login',
      loginMethod: 'phone',
      inputX: 100,
      inputWidth: 800,
      modalOffset: 6,
      modalOpacity: 1,
      dark: false,
    );

    test('仅 login 可见；账号满 11 位才可用；文案与无障碍名逐字', () {
      final FormButtonLayout enabled =
          logic.button(FormButtonKind.sendCode, base, accountLength: 11);
      expect(enabled.visible, isTrue);
      expect(enabled.enabled, isTrue);
      expect(enabled.opacity, closeTo(1, 1e-9));
      expect(enabled.label, '发送验证码');
      expect(enabled.accessibilityName, '发送短信验证码');
      expect(enabled.color, P.s777b60);
      expect(enabled.labelColor, P.f0eee5);
      expect(enabled.fontSize, closeTo(7, 1e-9));
      // (50 + 400 - 85, (6+430)*0.5, 85, 27.5)：inputX*s 是 formFields 原点。
      expectRect(enabled.rect, const Rect.fromLTWH(365, 218, 85, 27.5));

      final FormButtonLayout short =
          logic.button(FormButtonKind.sendCode, base, accountLength: 10);
      expect(short.enabled, isFalse);
      expect(short.opacity, closeTo(0.5, 1e-9));
    });

    test('倒计时期间失能且文案为「N 秒后重发」（Overlay.qml:414、419）', () {
      final FormButtonLayout layout = logic.button(
        FormButtonKind.sendCode,
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 0,
          inputWidth: 100,
          smsRetrySeconds: 7,
        ),
        accountLength: 11,
      );
      expect(layout.label, '7 秒后重发');
      expect(layout.enabled, isFalse);
    });

    test('loginBusy 期间即使账号满 11 位也失能', () {
      final FormButtonLayout layout = logic.button(
        FormButtonKind.sendCode,
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 0,
          inputWidth: 100,
          loginBusy: true,
        ),
        accountLength: 11,
      );
      expect(layout.enabled, isFalse);
    });

    test('非 login 时不可见（Overlay.qml:409）', () {
      final FormButtonLayout layout = logic.button(
        FormButtonKind.sendCode,
        const TextInputStageState(
          stageScale: 1,
          modal: 'playlist-form',
          inputX: 0,
          inputWidth: 100,
        ),
        accountLength: 11,
      );
      expect(layout.visible, isFalse);
    });

    test('opacity = 自身 × formFields.modalOpacity，并钳制到 [0,1]', () {
      const TextInputStageState fading = TextInputStageState(
        stageScale: 0.5,
        modal: 'login',
        loginMethod: 'phone',
        inputX: 100,
        inputWidth: 800,
        modalOffset: 6,
        modalOpacity: 0.25,
      );
      expect(
        logic.button(FormButtonKind.sendCode, fading, accountLength: 11).opacity,
        closeTo(0.25, 1e-9),
      );
      expect(
        logic.button(FormButtonKind.sendCode, fading, accountLength: 10).opacity,
        closeTo(0.125, 1e-9),
      );
      const TextInputStageState overshoot = TextInputStageState(
        stageScale: 0.5,
        modal: 'login',
        loginMethod: 'phone',
        inputX: 100,
        inputWidth: 800,
        modalOffset: 6,
        modalOpacity: 3,
      );
      expect(
        logic.button(FormButtonKind.sendCode, overshoot, accountLength: 11)
            .opacity,
        closeTo(1, 1e-9),
      );
      // 父 opacity 先钳到 1，再乘自身 0.5：失能态不能因为 modalOpacity=3 被钳成 1。
      expect(
        logic.button(FormButtonKind.sendCode, overshoot, accountLength: 10)
            .opacity,
        closeTo(0.5, 1e-9),
      );
    });
  });

  group('提交按钮（Overlay.qml:462-483）', () {
    test('登录态：y 611*scale、高 36*scale、文案「登录 →」', () {
      final FormButtonLayout layout = logic.button(
        FormButtonKind.submit,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 100,
          inputWidth: 800,
          modalOffset: 6,
          modalOpacity: 1,
        ),
        accountLength: 0,
      );
      expect(layout.visible, isTrue);
      expect(layout.enabled, isTrue);
      expect(layout.label, '登录 →');
      expect(layout.accessibilityName, '提交表单');
      expectRect(layout.rect, const Rect.fromLTWH(365, 308.5, 85, 18));
    });

    test('歌单态：y 530*scale、文案「保存 →」', () {
      final FormButtonLayout layout = logic.button(
        FormButtonKind.submit,
        const TextInputStageState(
          stageScale: 0.5,
          modal: 'playlist-form',
          inputX: 100,
          inputWidth: 800,
          modalOffset: 6,
        ),
        accountLength: 0,
      );
      expect(layout.label, '保存 →');
      expect(layout.enabled, isTrue);
      expectRect(layout.rect, const Rect.fromLTWH(365, 268, 85, 18));
    });

    test('loginBusy 时失能（Overlay.qml:465）', () {
      final FormButtonLayout layout = logic.button(
        FormButtonKind.submit,
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          inputX: 0,
          inputWidth: 100,
          loginBusy: true,
          modalOpacity: 1,
        ),
        accountLength: 11,
      );
      expect(layout.enabled, isFalse);
      expect(layout.opacity, closeTo(0.5, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // 可见性迁移（Overlay.qml:363-369、541-548、592-599）
  // ---------------------------------------------------------------------------

  group('可见性迁移的焦点与文本规则', () {
    test('formFields 变可见：先清两框再抢 account 焦点（Overlay.qml:363-369）', () {
      final List<TextInputEffect> effects = logic.visibilityEffects(
        TextInputContainer.formFields,
        wasVisible: false,
        isVisible: true,
        state: const TextInputStageState(stageScale: 1, modal: 'login'),
      );
      expect(describeEffects(effects), <String>[
        'clear-text:accountField:-',
        'clear-text:captchaField:-',
        'focus:accountField:-',
      ]);
    });

    test('formFields 变隐藏：只清两框，不碰焦点（Overlay.qml:364-365、368）', () {
      final List<TextInputEffect> effects = logic.visibilityEffects(
        TextInputContainer.formFields,
        wasVisible: true,
        isVisible: false,
        state: const TextInputStageState(stageScale: 1, modal: ''),
      );
      expect(describeEffects(effects), <String>[
        'clear-text:accountField:-',
        'clear-text:captchaField:-',
      ]);
    });

    test('检索框变可见：写入 state.query 并 forceActiveFocus（Overlay.qml:543-544）', () {
      final List<TextInputEffect> effects = logic.visibilityEffects(
        TextInputContainer.searchInput,
        wasVisible: false,
        isVisible: true,
        state: const TextInputStageState(
          stageScale: 1,
          modal: 'search',
          query: '晴天',
        ),
      );
      expect(describeEffects(effects), <String>[
        'set-text:musicSearchInput:晴天',
        'focus:musicSearchInput:-',
      ]);
    });

    test('检索框变隐藏：焦点交回输入层（Overlay.qml:546）', () {
      final List<TextInputEffect> effects = logic.visibilityEffects(
        TextInputContainer.searchInput,
        wasVisible: true,
        isVisible: false,
        state: const TextInputStageState(stageScale: 1, modal: ''),
      );
      expect(describeEffects(effects), <String>['focus-input-layer:-:-']);
    });

    test('query 为 null 时写入空串（QML 的 state.query||""）', () {
      final List<TextInputEffect> effects = logic.visibilityEffects(
        TextInputContainer.searchInput,
        wasVisible: false,
        isVisible: true,
        state: const TextInputStageState(stageScale: 1, modal: 'search'),
      );
      expect(effects.first.text, '');
    });

    test('设置编辑框：写入 editingSettingValue 并抢焦点，隐藏时回输入层', () {
      final List<TextInputEffect> show = logic.visibilityEffects(
        TextInputContainer.settingEditInput,
        wasVisible: false,
        isVisible: true,
        state: const TextInputStageState(
          stageScale: 1,
          modal: '',
          editingSetting: true,
          editingSettingValue: '旧值',
        ),
      );
      expect(describeEffects(show), <String>[
        'set-text:musicSettingEditInput:旧值',
        'focus:musicSettingEditInput:-',
      ]);

      final List<TextInputEffect> hide = logic.visibilityEffects(
        TextInputContainer.settingEditInput,
        wasVisible: true,
        isVisible: false,
        state: const TextInputStageState(stageScale: 1, modal: ''),
      );
      expect(describeEffects(hide), <String>['focus-input-layer:-:-']);
    });

    test('可见性未变化时不产生任何迁移', () {
      expect(
        logic.visibilityEffects(
          TextInputContainer.searchInput,
          wasVisible: true,
          isVisible: true,
          state: const TextInputStageState(stageScale: 1, modal: 'search'),
        ),
        isEmpty,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // onTextEdited 上报（Overlay.qml:540、591）
  // ---------------------------------------------------------------------------

  group('文本编辑上报', () {
    test('检索框每次提交文本变化都发 query（含相同文本连续提交）', () {
      final RecordingPorts ports = RecordingPorts();
      final TextInputOverlayLogic local = TextInputOverlayLogic(ports: ports);
      local.textEdited(TextFieldKind.search, '晴天');
      local.textEdited(TextFieldKind.search, '晴天');
      expect(ports.calls, <String>['query:晴天', 'query:晴天']);
    });

    test('设置编辑框发 settingEditText', () {
      final RecordingPorts ports = RecordingPorts();
      TextInputOverlayLogic(ports: ports).textEdited(TextFieldKind.settingEdit, '新值');
      expect(ports.calls, <String>['settingEditText:新值']);
    });

    test('账号与验证码框没有 onTextEdited，不发任何请求', () {
      final RecordingPorts ports = RecordingPorts();
      final TextInputOverlayLogic local = TextInputOverlayLogic(ports: ports);
      local.textEdited(TextFieldKind.account, '13800000000');
      local.textEdited(TextFieldKind.captcha, '1234');
      expect(ports.calls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Return / Escape 分支（Overlay.qml:399-406、459-460、549-552、600-601）
  // ---------------------------------------------------------------------------

  group('Return / Escape 分支', () {
    late RecordingPorts ports;
    late TextInputOverlayLogic local;

    setUp(() {
      ports = RecordingPorts();
      local = TextInputOverlayLogic(ports: ports);
    });

    test('检索框 Return：交给 searchAccepted(text, control)（Overlay.qml:550-552 → Engine.cpp:1006-1012）', () {
      final List<TextInputEffect> effects = local.handleKey(
        TextFieldKind.search,
        const TextInputKeyEvent(isReturn: true),
        state: const TextInputStageState(stageScale: 1, modal: 'search'),
        text: '晴天',
      );
      expect(ports.calls, <String>['searchAccepted:晴天:false']);
      expect(effects, isEmpty);
    });

    test('检索框 Return + Control：仍然走 searchAccepted，control=true（macOS 的 Cmd 由 Widget 折算）', () {
      local.handleKey(
        TextFieldKind.search,
        const TextInputKeyEvent(isReturn: true, control: true),
        state: const TextInputStageState(stageScale: 1, modal: 'search'),
        text: '晴天',
      );
      expect(ports.calls, <String>['searchAccepted:晴天:true']);
    });

    test('检索框 Escape：close-modal，不是 settingEditCancel（Overlay.qml:549）', () {
      final List<TextInputEffect> effects = local.handleKey(
        TextFieldKind.search,
        const TextInputKeyEvent(isEscape: true),
        state: const TextInputStageState(stageScale: 1, modal: 'search'),
        text: '',
      );
      expect(ports.calls, <String>['action:close-modal']);
      expect(effects, isEmpty);
    });

    test('登录态手机号 Return：焦点交给验证码框，不提交（Overlay.qml:399-405）', () {
      final List<TextInputEffect> effects = local.handleKey(
        TextFieldKind.account,
        const TextInputKeyEvent(isReturn: true),
        state: const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
        ),
        text: '13800000000',
        captcha: '1234',
      );
      expect(describeEffects(effects), <String>['focus:captchaField:-']);
      expect(ports.calls, isEmpty);
    });

    test('歌单态手机号 Return：直接提交表单（Overlay.qml:399-401）', () {
      final List<TextInputEffect> effects = local.handleKey(
        TextFieldKind.account,
        const TextInputKeyEvent(isReturn: true),
        state: const TextInputStageState(stageScale: 1, modal: 'playlist-form'),
        text: '我的歌单',
        captcha: '',
      );
      expect(ports.calls, <String>['submitForm:我的歌单:']);
      expect(describeEffects(effects), <String>['clear-text:captchaField:-']);
    });

    test('验证码框 Return：用两框的实时文本提交（Overlay.qml:459）', () {
      final List<TextInputEffect> effects = local.handleKey(
        TextFieldKind.captcha,
        const TextInputKeyEvent(isReturn: true),
        state: const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
        ),
        text: '1234',
        account: '13800000000',
      );
      expect(ports.calls, <String>['submitForm:13800000000:1234']);
      expect(describeEffects(effects), <String>['clear-text:captchaField:-']);
    });

    test('loginBusy 时 Return 不提交也不清验证码（Overlay.qml:371）', () {
      final List<TextInputEffect> effects = local.submit(
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
          loginBusy: true,
        ),
        account: '13800000000',
        captcha: '1234',
      );
      expect(ports.calls, isEmpty);
      expect(effects, isEmpty);
    });

    test('验证码框 Escape：close-modal（Overlay.qml:460）', () {
      local.handleKey(
        TextFieldKind.captcha,
        const TextInputKeyEvent(isEscape: true),
        state: const TextInputStageState(stageScale: 1, modal: 'login'),
        text: '',
      );
      expect(ports.calls, <String>['action:close-modal']);
    });

    test('设置编辑框 Return：settingEditAccepted（Overlay.qml:600）', () {
      local.handleKey(
        TextFieldKind.settingEdit,
        const TextInputKeyEvent(isReturn: true),
        state: const TextInputStageState(stageScale: 1, modal: ''),
        text: '新值',
      );
      expect(ports.calls, <String>['settingEditAccepted']);
    });

    test('设置编辑框 Escape：settingEditCancel，绝不关弹窗（Overlay.qml:601）', () {
      local.handleKey(
        TextFieldKind.settingEdit,
        const TextInputKeyEvent(isEscape: true),
        state: const TextInputStageState(stageScale: 1, modal: ''),
        text: '新值',
      );
      expect(ports.calls, <String>['settingEditCancel']);
    });

    test('发送验证码只在 login + phone 下真的发码（Engine.cpp 的 sendLoginCode 守卫）', () {
      local.sendLoginCode(
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
        ),
        account: '13800000000',
      );
      local.sendLoginCode(
        const TextInputStageState(stageScale: 1, modal: 'playlist-form'),
        account: '13800000000',
      );
      local.sendLoginCode(
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'qr',
        ),
        account: '13800000000',
      );
      expect(ports.calls, <String>['sendLoginCode:13800000000']);
    });

    test('非 Return 非 Escape 的事件不产生副作用', () {
      expect(
        local.handleKey(
          TextFieldKind.search,
          const TextInputKeyEvent(),
          state: const TextInputStageState(stageScale: 1, modal: 'search'),
          text: 'x',
        ),
        isEmpty,
      );
      expect(ports.calls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // 无障碍语义（Overlay.qml:194-196 + NativeHud.cpp:345-356）
  // ---------------------------------------------------------------------------

  HitLayer stageLayer() => HitLayer(
        geometry: const StageGeometry(logicalWidth: 1080, logicalHeight: 1080),
        android: true,
      );

  List<HudHit> navHits() => <HudHit>[
        const HudHit(
          x: 0,
          y: 118,
          width: 184,
          height: 54,
          action: 'discover',
          label: '发现音乐 ↗',
        ),
        const HudHit(
          x: 210,
          y: 118,
          width: 184,
          height: 54,
          action: 'search',
          label: '音乐检索  /',
        ),
        const HudHit(
          x: 410,
          y: 118,
          width: 184,
          height: 54,
          action: 'saved',
          label: '本地曲库',
        ),
        const HudHit(
          x: 610,
          y: 118,
          width: 120,
          height: 54,
          action: 'settings',
          label: '设置',
        ),
      ];

  group('hits 语义 == Accessible.role/name/onPressAction（Overlay.qml:194-196）', () {
    test('每个 hit 一个 button 节点，label/action 原样透传，矩形是 area 的逻辑坐标', () {
      final HitLayer layer = stageLayer();
      final List<HudHit> hits = navHits();
      final List<HudSemanticsNode> nodes = hitNodes(layer, hits);
      expect(nodes.length, hits.length);
      for (int i = 0; i < hits.length; i++) {
        expect(nodes[i].id, 'hit:$i');
        expect(nodes[i].role, SemanticsRole.button);
        expect(nodes[i].isButton, isTrue);
        expect(nodes[i].label, hits[i].label);
        expect(nodes[i].action, hits[i].action);
        // android pad 16：x-16 / y-16 / w+32 / h+32（Qt.rect 的同算法）。
        expectRect(
          nodes[i].rect,
          Rect.fromLTWH(
            hits[i].x - 16,
            hits[i].y - 16,
            hits[i].width + 32,
            hits[i].height + 32,
          ),
        );
      }
    });

    test('非 fixed 命中在 modal 打开时随 modalOffset 下移（Overlay.qml:191）', () {
      final HitLayer layer = HitLayer(
        geometry: const StageGeometry(logicalWidth: 1080, logicalHeight: 1080),
        android: false,
        modal: 'search',
        modalOffset: 40,
      );
      final List<HudHit> hits = <HudHit>[
        const HudHit(x: 0, y: 100, width: 10, height: 10, action: 'a', label: 'a'),
        const HudHit(
          x: 0,
          y: 100,
          width: 10,
          height: 10,
          action: 'b',
          label: 'b',
          fixed: true,
        ),
      ];
      final List<HudSemanticsNode> nodes = hitNodes(layer, hits);
      expect(nodes[0].rect.top, closeTo(140, 1e-9));
      expect(nodes[1].rect.top, closeTo(100, 1e-9));
    });

    test('顶部导航节点就是这四个 hit，文案不在本层重写（NativeHud.cpp:345-356）', () {
      final List<HudSemanticsNode> nav = navigationNodes(stageLayer(), navHits());
      expect(nav.map((HudSemanticsNode n) => n.label).toList(), <String>[
        '发现音乐 ↗',
        '音乐检索  /',
        '本地曲库',
        '设置',
      ]);
      expect(nav.map((HudSemanticsNode n) => n.action).toList(),
          NavigationAction.all);
      expect(nav.map((HudSemanticsNode n) => n.id).toList(), <String>[
        'nav:discover',
        'nav:search',
        'nav:saved',
        'nav:settings',
      ]);
      expect(NavigationAction.isNavigation('discover'), isTrue);
      expect(NavigationAction.isNavigation('player:toggle'), isFalse);
    });

    test('navigationNodes 不会把 result/expand 之类混进来', () {
      final List<HudSemanticsNode> nav = navigationNodes(stageLayer(), <HudHit>[
        const HudHit(
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          action: 'music:result:3',
          label: '晴天',
        ),
      ]);
      expect(nav, isEmpty);
    });
  });

  group('输入框与表单按钮的语义节点（Overlay.qml:398、424、458、477）', () {
    test('检索框：role=text-field、label 与 Accessible.name 同串', () {
      final List<HudSemanticsNode> nodes = inputNodes(
        logic,
        const TextInputStageState(
          stageScale: 1,
          modal: 'search',
          inputX: 0,
          inputY: 0,
          inputWidth: 100,
        ),
        accountLength: 0,
      );
      expect(nodes.length, 1);
      expect(nodes.single.id, 'input:musicSearchInput');
      expect(nodes.single.role, SemanticsRole.textField);
      expect(nodes.single.label, '搜索歌曲、歌手、专辑或歌单');
      expect(nodes.single.enabled, isTrue);
    });

    test('登录表单：两个字段 + 两个按钮，按钮带 command 与逐字文案', () {
      final List<HudSemanticsNode> nodes = inputNodes(
        logic,
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 0,
          inputWidth: 100,
        ),
        accountLength: 11,
      );
      expect(nodes.map((HudSemanticsNode n) => n.id).toList(), <String>[
        'input:accountField',
        'input:captchaField',
        'form:send-code',
        'form:submit',
      ]);
      expect(nodes[0].label, '手机号码');
      expect(nodes[1].label, '短信验证码');
      expect(nodes[2].label, '发送短信验证码');
      expect(nodes[2].command, SemanticsCommand.sendCode);
      expect(nodes[2].enabled, isTrue);
      expect(nodes[3].label, '提交表单');
      expect(nodes[3].command, SemanticsCommand.submit);
    });

    test('账号不足 11 位时发送按钮语义为失能（Overlay.qml:414）', () {
      final List<HudSemanticsNode> nodes = inputNodes(
        logic,
        const TextInputStageState(
          stageScale: 1,
          modal: 'login',
          loginMethod: 'phone',
          inputX: 0,
          inputWidth: 100,
        ),
        accountLength: 3,
      );
      final HudSemanticsNode send =
          nodes.firstWhere((HudSemanticsNode n) => n.id == 'form:send-code');
      expect(send.enabled, isFalse);
    });
  });

  group('Android 无障碍桥默认关闭（AndroidWindow.cpp:53-71）', () {
    test('android 且未设置 RHINE_ANDROID_ACCESSIBILITY 时策略为关', () {
      expect(
        AndroidAccessibilityBridge.enabled(android: true, forceEnv: false),
        isFalse,
      );
      expect(
        AndroidAccessibilityBridge.enabled(android: true, forceEnv: true),
        isTrue,
      );
      expect(
        AndroidAccessibilityBridge.enabled(android: false, forceEnv: false),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Widget：真实输入栈（EditableText ↔ TextInputClient）、焦点迁移、按钮
  // ---------------------------------------------------------------------------

  group('TextInputOverlay 使用真实 TextInputClient', () {
    testWidgets('检索框是 EditableText，字号/缩放/光标/动作都来自 layout', (WidgetTester tester) async {
      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 0.5,
            modal: 'search',
            inputX: 100,
            inputY: 200,
            inputWidth: 800,
            query: '晴天',
            rhineFontFamily: 'Rhine Sans',
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(EditableText), findsOneWidget);
      final EditableText editable =
          tester.widget<EditableText>(find.byType(EditableText));
      // Overlay.qml:533 / 532 / 537 / 550-552
      expect(editable.style.fontSize, closeTo(11, 1e-9));
      expect(editable.style.fontFamily, 'Rhine Sans');
      expect(editable.textScaler, TextScaler.noScaling);
      expect(editable.showCursor, isTrue);
      expect(editable.readOnly, isFalse);
      expect(editable.maxLines, 1);
      expect(editable.obscureText, isFalse);
      expect(editable.textInputAction, TextInputAction.done);
      // 未声明 maximumLength → Qt 默认 32767（Overlay.qml:519-562）。
      expect(
        (editable.inputFormatters!.single as LengthLimitingTextInputFormatter)
            .maxLength,
        32767,
      );
      // 可见性迁移已把 state.query 写入真实 controller（Overlay.qml:543）。
      expect(editable.controller.text, '晴天');
      expect(editable.controller.selection.isCollapsed, isTrue);
      expect(editable.controller.selection.baseOffset, 2);
    });

    testWidgets('占位仅在提交文本为空且无组合时可见（Overlay.qml:555）', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);
      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 0.5,
            modal: 'search',
            inputX: 100,
            inputY: 200,
            inputWidth: 800,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('搜索歌曲、歌手、专辑或歌单'), findsOneWidget);
      // 占位文字被 ExcludeSemantics 排除；Accessible.name 只由输入框语义节点发布一次。
      expect(find.bySemanticsLabel('搜索歌曲、歌手、专辑或歌单'), findsOneWidget);

      await tester.tap(find.byType(EditableText));
      await tester.pump();

      // 预编辑：Qt 的 text 仍为空、preeditText 为 zhong → 占位隐藏。
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'zhong',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();
      expect(find.text('搜索歌曲、歌手、专辑或歌单'), findsNothing);
      // 组合态不上报 query（Qt onTextEdited 只在 text 变化时触发）。
      expect(ports.calls, isEmpty);

      // 提交：只发一次 query，且提交文本不含预编辑。
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      expect(ports.calls, <String>['query:中']);
      expect(find.text('搜索歌曲、歌手、专辑或歌单'), findsNothing);
    });

    testWidgets('Return 走 onSubmitted：searchAccepted(text, control=false)', (WidgetTester tester) async {
      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 0.5,
            modal: 'search',
            inputX: 100,
            inputY: 200,
            inputWidth: 800,
            query: '晴天',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(EditableText));
      await tester.pump();

      // editable_text.dart:1485-1496：tester.sendKeyEvent(enter) 不会触发 onSubmitted，
      // 必须模拟引擎的 done action。
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(ports.calls, <String>['searchAccepted:晴天:false']);
      // Qt 的 Return 只提交，不迁移焦点（Overlay.qml:550-552 没有 focus 改动）。
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'text_input_overlay.musicSearchInput',
      );
    });

    testWidgets('Escape 走祖先 Focus：close-modal 且焦点留在本框（Overlay.qml:549）', (WidgetTester tester) async {
      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 0.5,
            modal: 'search',
            inputX: 100,
            inputY: 200,
            inputWidth: 800,
            query: '晴天',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(EditableText));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(ports.calls, <String>['action:close-modal']);
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'text_input_overlay.musicSearchInput',
      );
    });

    testWidgets('可见性迁移：隐藏时把焦点交回输入层，再显示时写入 query 并抢焦点', (WidgetTester tester) async {
      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 0.5,
            modal: 'search',
            inputX: 100,
            inputY: 200,
            inputWidth: 800,
            query: '晴天',
          ),
        ),
      );
      await tester.pump();

      final _HostState host = tester.state<_HostState>(find.byType(_Host));

      host.update(
        const TextInputStageState(
          stageScale: 0.5,
          modal: '',
          inputX: 100,
          inputY: 200,
          inputWidth: 800,
        ),
      );
      await tester.pump();
      expect(ports.calls, contains('focusInputLayer'));
      expect(find.byType(EditableText), findsNothing);

      host.update(
        const TextInputStageState(
          stageScale: 0.5,
          // 只有真正的检索页会让检索框重新可见并抢焦点；`saved` 不算（见
          // TextInputStageState.searchVisible 的注释）。
          modal: 'search',
          inputX: 100,
          inputY: 200,
          inputWidth: 800,
          query: 'abc',
        ),
      );
      await tester.pump();
      expect(find.byType(EditableText), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'abc',
      );
      expect(
        tester.binding.focusManager.primaryFocus?.debugLabel,
        'text_input_overlay.musicSearchInput',
      );
    });

    testWidgets('登录表单：两个字段的长度限制与键盘类型来自 layout', (WidgetTester tester) async {
      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 1,
            modal: 'login',
            loginMethod: 'phone',
            inputX: 0,
            inputWidth: 400,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(EditableText), findsNWidgets(2));
      final List<EditableText> fields =
          tester.widgetList<EditableText>(find.byType(EditableText)).toList();
      // 树序：accountField 先于 captchaField（Overlay.qml:384、443）。
      expect(fields[0].keyboardType, TextInputType.number);
      expect(fields[1].keyboardType, TextInputType.number);
      expect(fields[0].inputFormatters, isNotNull);
      expect(fields[1].inputFormatters, isNotNull);
      expect(
        (fields[0].inputFormatters!.single as LengthLimitingTextInputFormatter)
            .maxLength,
        11,
      );
      expect(
        (fields[1].inputFormatters!.single as LengthLimitingTextInputFormatter)
            .maxLength,
        8,
      );
      // Qt.ImhSensitiveData：关联想/个性化，但绝不遮挡（obscureText 恒 false）。
      expect(fields[1].obscureText, isFalse);
      expect(fields[1].autocorrect, isFalse);
      expect(fields[1].enableSuggestions, isFalse);
      expect(fields[0].autocorrect, isTrue);
    });

    testWidgets('按钮语义名逐字可被无障碍找到，点击触发提交并清空验证码', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 1,
            modal: 'login',
            loginMethod: 'phone',
            inputX: 0,
            inputWidth: 400,
          ),
        ),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('发送短信验证码'), findsOneWidget);
      expect(find.bySemanticsLabel('提交表单'), findsOneWidget);
      expect(find.text('发送验证码'), findsOneWidget);
      expect(find.text('登录 →'), findsOneWidget);

      // 在验证码框输入，再点提交（Overlay.qml:479-482 的 MouseArea）。
      await tester.tap(find.byType(EditableText).last);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '1234',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('登录 →'));
      await tester.pump();

      expect(ports.calls, contains('submitForm::1234'));
      // Overlay.qml:375：提交后 captchaField.text = ""。
      expect(find.text('1234'), findsNothing);
    });

    testWidgets('发送验证码按钮在账号不足 11 位时不可点（Overlay.qml:414、430-433）', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final RecordingPorts ports = RecordingPorts();
      await tester.pumpWidget(
        _Host(
          ports: ports,
          initial: const TextInputStageState(
            stageScale: 1,
            modal: 'login',
            loginMethod: 'phone',
            inputX: 0,
            inputWidth: 400,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('发送验证码'));
      await tester.pump();
      expect(ports.calls, isEmpty);
    });
  });
}

/// 空端口：纯逻辑断言不需要副作用落地。
class _NoopPorts implements TextInputPorts {
  const _NoopPorts();

  @override
  void action(String action) {}

  @override
  void query(String text) {}

  @override
  void searchAccepted(String text, {required bool control}) {}

  @override
  void submitForm(String account, String captcha) {}

  @override
  void sendLoginCode(String phone) {}

  @override
  void settingEditText(String text) {}

  @override
  void settingEditAccepted() {}

  @override
  void settingEditCancel() {}

  @override
  void focusInputLayer() {}
}

/// 用 MaterialApp 提供 Directionality / MediaQuery / Localizations，只搭一层可换状态的宿主。
class _Host extends StatefulWidget {
  const _Host({required this.ports, required this.initial});

  final TextInputPorts ports;
  final TextInputStageState initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late TextInputStageState state = widget.initial;

  void update(TextInputStageState next) {
    setState(() {
      state = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 540,
            height: 540,
            child: TextInputOverlay(state: state, ports: widget.ports),
          ),
        ),
      ),
    );
  }
}
