/// 文本输入层：Qt/qml/Overlay.qml:354-602（formFields / searchInput / settingEditInput）
/// 1:1 迁移到 Flutter，并把「输入框几何来自 state」固化成可静态审查的契约。
///
/// ## 位置契约（state → 逻辑矩形）
/// 舞台坐标恒由 state 给出，逻辑坐标 = 舞台坐标 * stageScale。
/// 这个 stageScale 由 PortraitStage 唯一注入（PortraitBands.stageScale），
/// 本层只消费、绝不按 height / 1080 重新推导。
/// 四类输入框的每一条边都有唯一来源，不得由 Widget 自算，也不得用 hit 反推：
/// - search：x=(inputX||0)*s、y=((inputY||302)+(modalOffset||0))*s、w=(inputWidth||0)*s、
///   h=54*s（Overlay.qml:528-531）。
/// - account：容器 formFields 的 x=(inputX||0)*s、y=(modalOffset||0)*s、w=(inputWidth||0)*s
///   （Overlay.qml:358-360）；字段自身 x=14*s、y=430*s、w=parent.w-(login?208:28)*s、h=55*s
///   （Overlay.qml:387-390）。
/// - captcha：同容器，x=14*s、y=541*s、w=parent.w-28*s、h=55*s（Overlay.qml:447-450）。
/// - settingEdit：背景 (editingSettingX||0)*s、((editingSettingY||0)+(modalOffset||0))*s、
///   (editingSettingWidth||0)*s、(editingSettingHeight||0)*s（Overlay.qml:567-570）；
///   字段 x=bg.x+12*s、y=bg.y、w=max(0,bg.w-24*s)、h=bg.h（Overlay.qml:579-582）。
/// 所有以 || 出现的回退都是 QML 原文里的默认值（inputY 缺省 302 等），不是本层发明的兜底。
///
/// ## 真实文本输入栈（不可替换）
/// 组合态与选区必须来自真实的 TextEditingController.value（TextEditingValue.composing /
/// selection），即真实的 Flutter TextInputClient 通路：EditableText -> TextInputConnection ->
/// 平台输入法。不得用自造 String 冒充组合态，也不得用 TextField/InputDecorator 顶替：
/// InputDecorator 有 48 逻辑像素的最小高度，而手机横屏 stageScale 可低到约 0.38，
/// 54*0.38 约 20.5 会被撑破，且 contentPadding 无法精确等于 18*s / 14*s
/// （Overlay.qml:523-524、531）。
///
/// ## Qt 与 Flutter 文本语义差异（逐条核对，不臆造）
/// - Qt 的 TextInput.text 不含预编辑，preeditText 单独暴露；Flutter 的 TextEditingValue.text
///   含预编辑，组合区间在 composing。故必须剥离：committedText() / preeditText()。
/// - Qt 的 onTextEdited 只在提交文本变化时发；Flutter 的 onChanged 连组合态变化也发。
///   故按提交文本去重（TextCommitTracker），且程序化赋值 text 不得触发上报
///   （QML 里赋值 text 不产生 textEdited，Overlay.qml:543、594）。
/// - Qt 的 Keys.onReturnPressed 在单行 TextInput 上不迁移焦点；Flutter 的 EditableText 在
///   onEditingComplete 为 null 时会 clearComposing + unfocus（editable_text.dart:3914-3985），
///   故必须给一个空 onEditingComplete 阻止默认行为，保持 Qt 的焦点不迁移语义。
/// - 硬件 Return：引擎在真机上把 enter 翻译成 done action 才回调 onSubmitted
///   （editable_text.dart:1485-1496 原文），因此 Return 走 onSubmitted 是正确通路；不得在
///   Focus.onKeyEvent 里再处理 Enter（会双发）。
/// - Escape：Android 上框架不安装 disabling text shortcuts
///   （default_text_editing_shortcuts.dart:981-996 对 android 返回 null），Escape 不被框架
///   消费，故由祖先 Focus.onKeyEvent 承接并返回 handled。
///
/// ## 副作用边界
/// 所有 rhine.* 调用走 TextInputPorts（与 pointer_router.dart 的 PointerPorts 同风格）；
/// 文本赋值与焦点迁移属于 Widget 侧状态，以 TextInputEffect 列表返回给 Widget 执行。
/// 判定与渲染分离，便于静态审查与后续单测。
///
/// ## 已知 TBD（不臆造，等设备/宿主证据）
/// - QML 只写 text = ...（Overlay.qml:543、594），未声明赋值后光标落点；本层统一落尾
///   （valueForText），标 TBD。
/// - QML 未声明 cursor / selection 颜色；本层用文字色作光标色，标 TBD。
/// - renderType: Text.NativeRendering（Overlay.qml:525）在 Flutter 无对应物（引擎恒定走自身
///   栅格化），记录为不可映射项。
/// - rhineFontFamily 由 C++ 注入根上下文（Qt/src/main.cpp:1074）；Flutter 侧只能由宿主传入
///   同名字族，未注入时为 null（平台默认），标 TBD。
/// - ImhSensitiveData（Overlay.qml:457）在 Qt 只是「别缓存、别学习」提示，不遮挡文本；
///   Flutter 映射为关联想、关自动更正、关个性化学习，绝不用 obscureText。
/// - ImhDigitsOnly（Overlay.qml:397、457）是输入法提示而非校验器，故只映射键盘类型，
///   不加数字过滤 formatter（那会凭空收紧 Qt 允许的输入）。
/// - Qt 的 enabled:false 只是失能，不隐藏也不改文案；本层映射为 readOnly + 不可交互。
///   Qt 在失能时会顺带清掉 activeFocus；本层不主动 unfocus（不猜失能时序），只隐藏光标。
/// - selectByMouse（Overlay.qml:538、588）默认 false，本层字面映射到
///   enableInteractiveSelection；触屏长按选区在 Qt 上的实际行为需设备核对。
/// - 无障碍节点形状（合并成单节点）需 a11y inspector 在设备上核对，本层按 MergeSemantics
///   合并 RenderEditable 自己发布的 textField 节点（rendering/editable.dart:1380-1384）。
/// - 本文件 import key_router.dart（仅 HudAction）→ wheel_router.dart → hit_layer.dart →
///   ../protocol/hud_hit.dart；后者只存在于  树、本树未集成，故整条导入链在本树预期
///   不可解析，属跨树 integration dependency，不是本层缺陷（禁止把 hud_hit.dart 复制进本层）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'hit_layer.dart' show StageGeometry;
import 'key_router.dart' show HudAction;

/// 四个文本输入框的身份。objectName 与 QML 逐字一致，供测试与宿主定位
/// （Overlay.qml:386、445、521、577）。
enum TextFieldKind {
  search('musicSearchInput'),
  account('accountField'),
  captcha('captchaField'),
  settingEdit('musicSettingEditInput');

  const TextFieldKind(this.objectName);

  final String objectName;
}

/// 承载输入框的三个 QML 容器（各有独立的 onVisibleChanged 语义，禁止合并处理）。
enum TextInputContainer {
  formFields('formFields'),
  searchInput('searchInput'),
  settingEditInput('settingEditInput');

  const TextInputContainer(this.qmlId);

  final String qmlId;
}

/// 表单里的两个按钮（与输入框同属 formFields，Overlay.qml:408-434、462-483）。
enum FormButtonKind { sendCode, submit }

/// state 的本地投影：只取本层需要的键。字段名与 Qt/src/NativeHud.cpp:175-221 的 state() 键
/// 逐字一致，不新增真相，也不解析 wire envelope。
class TextInputStageState {
  /// 遗留构造：保留给未迁移测试/静态样例显式指定 scale。
  ///
  /// 生产竖屏路径必须使用 [TextInputStageState.fromGeometry]，让唯一
  /// [StageGeometry.stageScale] 贯穿绘制与命中；本构造不得再新增调用方。
  const TextInputStageState({
    required this.stageScale,
    required this.modal,
    this.inputX,
    this.inputY,
    this.inputWidth,
    this.inputHeight,
    this.inputFontSize,
    this.modalOffset = 0.0,
    this.modalOpacity = 0.0,
    this.closing = false,
    this.localMusic = false,
    this.dark = false,
    this.query,
    this.loginMethod = '',
    this.loginBusy = false,
    this.smsRetrySeconds = 0,
    this.editingSetting = false,
    this.editingSettingValue,
    this.editingSettingX,
    this.editingSettingY,
    this.editingSettingWidth,
    this.editingSettingHeight,
    this.performanceIdle = false,
    this.rhineFontFamily,
    this.formFieldRect,
    this.formFieldBackdropRect,
    this.formSubmitRect,
    this.formInitialText,
    this.formIdentity,
    this.formInputFormatters,
  });

  /// 用唯一 [StageGeometry] 构造 state。
  ///
  /// stageScale 只从 geometry 读一次，调用方不再自行计算 height / 1080；
  /// 这样 TextInputStageState、HitLayer、PointerRouter 消费的是同一个 scale。
  TextInputStageState.fromGeometry(
    StageGeometry geometry, {
    required this.modal,
    this.inputX,
    this.inputY,
    this.inputWidth,
    this.inputHeight,
    this.inputFontSize,
    this.modalOffset = 0.0,
    this.modalOpacity = 0.0,
    this.closing = false,
    this.localMusic = false,
    this.dark = false,
    this.query,
    this.loginMethod = '',
    this.loginBusy = false,
    this.smsRetrySeconds = 0,
    this.editingSetting = false,
    this.editingSettingValue,
    this.editingSettingX,
    this.editingSettingY,
    this.editingSettingWidth,
    this.editingSettingHeight,
    this.performanceIdle = false,
    this.rhineFontFamily,
    this.formFieldRect,
    this.formFieldBackdropRect,
    this.formSubmitRect,
    this.formInitialText,
    this.formIdentity,
    this.formInputFormatters,
  }) : stageScale = geometry.stageScale;

  /// 「上一状态」占位：所有容器都不可见。仅用于 Widget 挂载时补一次可见性迁移。
  static const TextInputStageState inactive =
      TextInputStageState(stageScale: 1, modal: '');

  /// 唯一注入的 stageScale（PortraitBands.stageScale）。
  ///
  /// 不得在本层按 Overlay.qml:22 的 height / 1080 重新推导；命中层用同一值
  /// 构造 StageGeometry.withScale。
  final double stageScale;

  /// state.modal：''、search、saved、login、playlist-form、…
  final String modal;

  final double? inputX;
  final double? inputY;
  final double? inputWidth;

  /// 输入框高度（舞台单位，绘制时乘 [stageScale]）。
  ///
  /// Qt 的 state() 一直带着 `inputHeight`（Qt/src/NativeHud.cpp:257-274、compact 由
  /// Qt/src/ResponsiveHudLayout.cpp:397 从 `input` 字段矩形转出），QML 侧
  /// `Overlay.qml:571` 直接读它；本类原先没接，检索框因此恒用 QML 缺省 54——竖屏
  /// 输入框实际是 44 网格（≈121 舞台单位），54 会让文字贴在框顶（实机
  /// device7/s1-search.png：「dx」小字顶在框上沿）。
  final double? inputHeight;

  /// 输入框字号（舞台单位，绘制时乘 [stageScale]）。null = 沿用 QML 的 22。
  ///
  /// 只有检索框需要覆盖：Qt compact 描 14 网格（ResponsiveHudPages.cpp:330、
  /// Overlay.qml:542-543 的 `14 * compactUnit`），本类原先按横屏 22 画，竖屏就成了
  /// 框里的小字。
  final double? inputFontSize;
  final double modalOffset;
  final double modalOpacity;

  /// state.closing：收场动画期间输入框失能（Overlay.qml:527）。
  final bool closing;

  /// state.localMusic：决定检索框文案（Overlay.qml:539、556）。
  final bool localMusic;

  /// state.dark：决定全部文字/背景配色。
  final bool dark;

  /// state.query：检索框变可见时被写入（Overlay.qml:543）。
  final String? query;

  /// state.loginMethod：只有 phone 才展开手机号表单（Overlay.qml:357）。
  final String loginMethod;

  /// state.loginBusy：登录请求进行中，输入与按钮失能（Overlay.qml:396、414、456、465）。
  final bool loginBusy;

  /// state.smsRetrySeconds：验证码倒计时（Overlay.qml:414、419）。
  final int smsRetrySeconds;

  /// state.editingSetting（bool）。
  final bool editingSetting;

  /// state.editingSettingValue：设置项编辑初值（Overlay.qml:594）。
  final String? editingSettingValue;

  final double? editingSettingX;
  final double? editingSettingY;
  final double? editingSettingWidth;
  final double? editingSettingHeight;

  /// rhine.performance.idle（Qt/src/Engine.cpp:270）：睡眠时隐藏光标（Overlay.qml:394、454、
  /// 537、589）。它不在 state() 里，是独立的 performance 通道。
  final bool performanceIdle;

  /// C++ 注入的字族（Qt/src/main.cpp:1074）。null = 宿主尚未注入（TBD）。
  final String? rhineFontFamily;

  /// 可选：playlist-form 的字段矩形（stage 单位，绘制时乘 [stageScale]）。
  ///
  /// 非 null 时只覆盖 formFields 的 account 字段几何；可见性、键盘类型、maxLength、
  /// 提交语义仍走本类既有分支。默认 null 保持 Overlay.qml:387-390 的登录几何不变。
  final Rect? formFieldRect;

  /// 可选：playlist-form 的字段背景矩形（stage 单位）。null 时回落到 [formFieldRect]
  /// 或既有登录背景几何，避免调用方只给文字框时画出错位的背景。
  final Rect? formFieldBackdropRect;

  /// 可选：playlist-form 的提交按钮矩形（stage 单位）。null 时保持既有登录按钮几何。
  final Rect? formSubmitRect;

  /// 可选：playlist-form 的初始文本。null 表示不启用 playlist-form 的初值语义，
  /// 仍按既有 onVisibleChanged 清空；非 null（含空串）时变可见/表单身份变化会写入该值。
  final String? formInitialText;

  /// 可选：playlist-form 的表单身份（formKind + formPID）。变化时重设初值并抢焦点。
  final String? formIdentity;

  /// 可选：playlist-form 的输入 formatter（如按 UTF-16 码元截断的旧实现）。
  /// null 时沿用 [TextInputLayout] 的 LengthLimitingTextInputFormatter，保持既有四 kind 不变。
  final List<TextInputFormatter>? formInputFormatters;

  bool get loginMode => modal == 'login';

  /// Overlay.qml:357 —— 手机号表单的可见条件。
  bool get formVisible =>
      modal == 'playlist-form' || (loginMode && loginMethod == 'phone');

  /// Overlay.qml:526 —— 检索框的可见条件。
  bool get searchVisible => modal == 'search' || modal == 'saved';

  /// Overlay.qml:566 / 578 —— 设置文本编辑框的可见条件。
  bool get settingEditVisible => editingSetting;
}

/// 输入框背后那层 Rectangle（QML 里每个输入框都是「背景 Rectangle + TextInput」成对出现）。
class TextInputBackdrop {
  const TextInputBackdrop({
    required this.rect,
    required this.color,
    required this.opacity,
    this.borderColor,
    this.borderWidth = 0.0,
  });

  final Rect rect;
  final Color color;
  final double opacity;
  final Color? borderColor;
  final double borderWidth;
}

/// 一个输入框的全部渲染与无障碍参数（一次算清，Widget 不再做任何几何判断）。
class TextInputLayout {
  const TextInputLayout({
    required this.kind,
    required this.visible,
    required this.enabled,
    required this.rect,
    required this.fontSize,
    required this.fontFamily,
    required this.textColor,
    required this.opacity,
    required this.clip,
    required this.selectByMouse,
    required this.cursorVisible,
    required this.maxLength,
    required this.digitsOnly,
    required this.sensitive,
    required this.accessibilityName,
    required this.padding,
    this.placeholder,
    this.placeholderColor,
    this.backdrop,
    this.inputFormatters,
  });

  final TextFieldKind kind;
  final bool visible;
  final bool enabled;

  /// 逻辑坐标（舞台坐标 * stageScale），直接交给 Positioned。
  final Rect rect;
  final double fontSize;
  final String? fontFamily;
  final Color textColor;

  /// 最终合成不透明度（含容器 modalOpacity），已钳制到 [0,1]。
  final double opacity;
  final bool clip;
  final bool selectByMouse;

  /// Overlay.qml:394/454/537/589 去掉 activeFocus 那一半：Widget 侧与 enabled 相与，
  /// EditableText 内部再与聚焦相与。
  final bool cursorVisible;
  final int? maxLength;
  final bool digitsOnly;
  final bool sensitive;

  /// Accessible.name，逐字拷贝。
  final String accessibilityName;

  /// Qt TextInput 未声明 padding 即 0；只有检索框声明 18/14（Overlay.qml:523-524）。
  final EdgeInsets padding;

  /// 占位文案：只有检索框有（Overlay.qml:553-561），且与 Accessible.name 同一字面量。
  final String? placeholder;
  final Color? placeholderColor;
  final TextInputBackdrop? backdrop;

  /// QML 的 verticalAlignment: TextInput.AlignVCenter（四个框都写了）。
  bool get verticallyCentered => true;

  TextStyle get textStyle =>
      TextStyle(fontFamily: fontFamily, fontSize: fontSize, color: textColor);

  /// account / captcha / settingEdit 没有 placeholder 元素，恒不绘制。
  bool get hasPlaceholder => placeholder != null;

  /// 可选：覆盖 LengthLimitingTextInputFormatter 的 formatter 链。
  /// 仅 playlist-form 使用（Qt QString 按 UTF-16 码元截断）；null 保持原行为。
  final List<TextInputFormatter>? inputFormatters;
}

/// 表单按钮的渲染与无障碍参数（Overlay.qml:408-434、462-483）。
class FormButtonLayout {
  const FormButtonLayout({
    required this.kind,
    required this.visible,
    required this.enabled,
    required this.rect,
    required this.color,
    required this.opacity,
    required this.label,
    required this.labelColor,
    required this.fontSize,
    required this.accessibilityName,
  });

  final FormButtonKind kind;
  final bool visible;
  final bool enabled;
  final Rect rect;
  final Color color;

  /// 最终合成不透明度 = formFields.opacity × 自身 enabled?1:0.5（Overlay.qml:362、416/469）。
  ///
  /// 注意先钳制 formFields.opacity：Qt 的 opacity 属性在赋值时就钳到 [0,1]，子项的
  /// 有效不透明度用的是钳制后的父值，不是原始 modalOpacity。
  final double opacity;

  /// 可见文案（发送验证码 / N 秒后重发 / 登录 → / 保存 →）。
  final String label;
  final Color labelColor;
  final double fontSize;

  /// Accessible.name（发送短信验证码 / 提交表单），与可见文案不同，禁止互相替代。
  final String accessibilityName;
}

/// rhine.* 副作用端口。与 pointer_router.dart 的 PointerPorts 同构，逻辑里不得直接摸状态。
abstract class TextInputPorts {
  /// rhine.action(...)：Escape 关闭弹窗（Overlay.qml:406、460、549）。
  void action(String action);

  /// rhine.query(text)：检索框提交文本变化（Overlay.qml:540）。
  void query(String text);

  /// rhine.searchAccepted(text, event.modifiers)（Overlay.qml:551）-> Qt/src/Engine.cpp:1006-1012。
  /// Engine 只判 `modifiers & Qt::ControlModifier` 这一个位（Engine.cpp:1007），故本层上报
  /// 归一化后的 Control 布尔；key_router.dart:44-49 的 DEV-1 已删掉 QtModifierBits，桥接层
  /// 直接携带已解析的 bool control（与 Engine.cpp:1003 下传的 command 同源），此处不抄行号。
  void searchAccepted(String text, {required bool control});

  /// rhine.submitForm(account, captcha)（Overlay.qml:374）。
  void submitForm(String account, String captcha);

  /// rhine.sendLoginCode(phone)（Overlay.qml:427、432）。
  void sendLoginCode(String phone);

  /// rhine.settingEditText(text)（Overlay.qml:591）。
  void settingEditText(String text);

  /// rhine.settingEditAccepted()（Overlay.qml:600）。
  void settingEditAccepted();

  /// rhine.settingEditCancel()（Overlay.qml:601）—— 它不是 close-modal。
  void settingEditCancel();

  /// inputLayer.forceActiveFocus()（Overlay.qml:546、597）：把焦点交回输入层。
  void focusInputLayer();
}

/// 归一化后的按键事件（只保留本层用到的三个自由度）。
class TextInputKeyEvent {
  const TextInputKeyEvent({
    this.isReturn = false,
    this.isEscape = false,
    this.control = false,
  });

  final bool isReturn;
  final bool isEscape;

  /// Return 是否带 Control（Qt 的 event.modifiers & Qt::ControlModifier，Engine.cpp:1003-1004；
  /// Qt 在 macOS 把 Cmd 映射到 ControlModifier，故 macOS 上 Meta 也算）。
  final bool control;
}

/// Widget 侧要执行的界面操作（业务副作用走 TextInputPorts，不在这里）。
class TextInputEffect {
  const TextInputEffect.setText(this.field, this.text) : kind = kindSetText;

  const TextInputEffect.clearText(this.field)
      : kind = kindClearText,
        text = null;

  const TextInputEffect.focusField(this.field)
      : kind = kindFocus,
        text = null;

  const TextInputEffect.focusInputLayer()
      : kind = kindFocusInputLayer,
        field = null,
        text = null;

  static const String kindSetText = 'set-text';
  static const String kindClearText = 'clear-text';
  static const String kindFocus = 'focus';
  static const String kindFocusInputLayer = 'focus-input-layer';

  final String kind;
  final TextFieldKind? field;
  final String? text;
}

/// 组合区间里的文本；无组合（或区间非法）返回空串。
///
/// 与 Qt 的 preeditText 同义（Qt/tests/InputMethodChecks.cpp:28-71：预编辑 ceshi 时
/// preeditText == ceshi 且 text == 空）。
String preeditText(TextEditingValue value) {
  final range = value.composing;
  if (!range.isValid || range.isCollapsed || range.end > value.text.length) {
    return '';
  }
  return value.text.substring(range.start, range.end);
}

/// 剥离组合区间后的提交文本；等价于 Qt 的 TextInput.text。
String committedText(TextEditingValue value) {
  final range = value.composing;
  if (!range.isValid || range.isCollapsed || range.end > value.text.length) {
    return value.text;
  }
  return value.text.substring(0, range.start) + value.text.substring(range.end);
}

/// Overlay.qml:555 —— placeholder 只在「提交文本为空」且「无组合文本」时可见。
///
/// 两条条件都是 Qt 原文：searchInput.text.length === 0 && !searchInput.preeditText。
/// 因为 Flutter 的 value.text 含预编辑，不剥离就会在「正在输入中文」时错误隐藏占位。
bool showsPlaceholder(TextEditingValue value) =>
    committedText(value).isEmpty && preeditText(value).isEmpty;

/// Qt 的 opacity 属性在赋值时被钳制到 [0, 1]；Flutter 的 Opacity 对越界值直接断言，
/// 故在投影层复现同一钳制，避免 state 抖动把越界值带进渲染层。
double _clampOpacity(double value) => value.clamp(0.0, 1.0).toDouble();

/// QML 的 `value || fallback`：null 与 0 都回退（JS 里 0 为假）。
/// 只用于 inputY：其余 `|| 0` 的回退值与 `?? 0` 等价。
double _qmlOr(double? value, double fallback) =>
    (value == null || value == 0) ? fallback : value;

/// 程序化写入文本时构造的 TextEditingValue：光标落尾。
///
/// TBD：QML 只写 text = ...（Overlay.qml:543、594），未声明光标位置；这里对齐 Qt 赋值后
/// 光标到末尾的实际行为，待设备复核。
TextEditingValue valueForText(String text) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );

/// 提交文本去重：QML 的 onTextEdited 只在提交文本真的变化时发；Flutter 的 onChanged 连组合态
/// 变化也发（每次预编辑都回调），故按提交文本去重。
///
/// 这里只去重「同一提交文本不重复上报」，不对合法重复命令做其它语义去重
/// （Qt/tests/InputMethodChecks.cpp:60-71 要求连续相同中文提交得到 测试测试）。
class TextCommitTracker {
  String? _last = ''; // 初始基线为空串：挂载时的空文本不发事件。

  /// 返回需要上报的提交文本；null 表示这次变化只是组合态，不该发 query/settingEditText。
  String? acceptText(String committed) {
    if (committed == _last) {
      return null;
    }
    _last = committed;
    return committed;
  }

  /// 程序化赋值后同步基线：QML 里写 text 不触发 onTextEdited，故不得因此上报。
  void resetTo(String? text) {
    _last = text;
  }

  String? get last => _last;
}

/// 全部判定：几何、可见性迁移、按键分支、文本上报。纯函数式，不持有 Widget 状态。
class TextInputOverlayLogic {
  const TextInputOverlayLogic({required this.ports});

  final TextInputPorts ports;

  /// 单个输入框的完整布局。stageScale 逐字来自 state（Overlay.qml:22），不做二次换算。
  TextInputLayout layout(TextFieldKind kind, TextInputStageState state) {
    final s = state.stageScale;
    switch (kind) {
      case TextFieldKind.search:
        return _searchLayout(state, s);
      case TextFieldKind.account:
        return _accountLayout(state, s);
      case TextFieldKind.captcha:
        return _captchaLayout(state, s);
      case TextFieldKind.settingEdit:
        return _settingEditLayout(state, s);
    }
  }

  TextInputLayout _searchLayout(TextInputStageState state, double s) {
    final dark = state.dark;
    final visible = state.searchVisible;
    final name =
        state.localMusic ? '检索本地歌曲、歌手、专辑或文件夹' : '搜索歌曲、歌手、专辑或歌单';
    // Overlay.qml:528-531（高度 :531 的缺省 54 只在宿主没给 inputHeight 时生效）
    final rect = Rect.fromLTWH(
      (state.inputX ?? 0) * s,
      ((_qmlOr(state.inputY, 302) + state.modalOffset) * s),
      (state.inputWidth ?? 0) * s,
      (state.inputHeight ?? 54) * s,
    );
    return TextInputLayout(
      kind: TextFieldKind.search,
      visible: visible,
      // Overlay.qml:527
      enabled: !state.closing,
      rect: rect,
      // Overlay.qml:533（compact 走 :542-543 的 14 * compactUnit，由宿主折算成舞台单位传入）
      fontSize: (state.inputFontSize ?? 22) * s,
      // Overlay.qml:532
      fontFamily: state.rhineFontFamily,
      // Overlay.qml:534
      textColor: visible
          ? (dark ? const Color(0xFFE9E7DA) : const Color(0xFF222A25))
          : (dark ? const Color(0xFFEBEBEB) : const Color(0xFF141613)),
      // Overlay.qml:535
      opacity: _clampOpacity(state.modalOpacity),
      // Overlay.qml:536
      clip: true,
      // Overlay.qml:538
      selectByMouse: true,
      // Overlay.qml:537
      cursorVisible: !state.performanceIdle,
      // 未声明 maximumLength：Qt TextInput.maximumLength 默认 32767，显式对齐；
      // Flutter 的 LengthLimitingTextInputFormatter 按字素截断，与 Qt 按 UTF-16 单元的
      // 极端增补平面差异记 TBD（UI 实际不可达）。
      maxLength: 32767,
      digitsOnly: false,
      sensitive: false,
      // Overlay.qml:539
      accessibilityName: name,
      // Overlay.qml:523-524
      padding: EdgeInsets.only(left: 18 * s, right: 14 * s),
      // Overlay.qml:553-561
      placeholder: name,
      placeholderColor: visible
          ? (dark ? const Color(0xFFA2AA9D) : const Color(0xFF626B60))
          : const Color(0xFF777777),
      // Overlay.qml:509-518：检索条背景由原生面板绘制，search/saved 时 opacity 恒 0。
      backdrop: TextInputBackdrop(
        rect: rect,
        color: dark ? const Color(0xFFFFFFFF) : const Color(0xFF141613),
        opacity: visible ? 0.0 : _clampOpacity(state.modalOpacity * 0.045),
      ),
    );
  }

  TextInputLayout _accountLayout(TextInputStageState state, double s) {
    final dark = state.dark;
    final login = state.loginMode;
    final formWidth = (state.inputWidth ?? 0) * s;
    // Overlay.qml:387-390。playlist-form 由宿主注入真实表单矩形；登录路径保持原值。
    final Rect rect = state.formFieldRect == null
        ? Rect.fromLTWH(
            ((state.inputX ?? 0) + 14) * s,
            (state.modalOffset + 430) * s,
            math.max(0.0, formWidth - (login ? 208 : 28) * s),
            55 * s,
          )
        : _scaledRect(state.formFieldRect!, s);
    return TextInputLayout(
      kind: TextFieldKind.account,
      // Overlay.qml:357 的容器可见性
      visible: state.formVisible,
      // Overlay.qml:396
      enabled: !login || !state.loginBusy,
      rect: rect,
      // Overlay.qml:393
      fontSize: 19 * s,
      // account/captcha 没有 font.family，用平台默认（Overlay.qml:384-407、443-461）。
      fontFamily: null,
      // Overlay.qml:392
      textColor: dark ? const Color(0xFFEEEEEB) : const Color(0xFF161914),
      // 继承 formFields 的 opacity（Overlay.qml:362）。
      opacity: _clampOpacity(state.modalOpacity),
      // 未声明 clip（QML Item.clip 默认 false）。
      clip: false,
      // 未声明 selectByMouse（默认 false）。
      selectByMouse: false,
      // Overlay.qml:394
      cursorVisible: !state.performanceIdle,
      // Overlay.qml:395
      maxLength: login ? 11 : 100,
      // playlist-form 可注入 Qt QString 口径的 formatter；登录路径保持 null。
      inputFormatters: state.formInputFormatters,
      // Overlay.qml:397：login 时 Qt.ImhDigitsOnly
      digitsOnly: login,
      sensitive: false,
      // Overlay.qml:398
      accessibilityName: state.modal == 'playlist-form' ? '歌单名称' : '手机号码',
      padding: EdgeInsets.zero,
      // Overlay.qml:377-383：整行背景；登录时右让 180*s 给发送验证码按钮。
      backdrop: TextInputBackdrop(
        rect: state.formFieldBackdropRect != null
            ? _scaledRect(state.formFieldBackdropRect!, s)
            : state.formFieldRect != null
                ? rect
                : Rect.fromLTWH(
                    (state.inputX ?? 0) * s,
                    (state.modalOffset + 430) * s,
                    math.max(0.0, login ? formWidth - 180 * s : formWidth),
                    55 * s,
                  ),
        color: dark ? const Color(0xFF30312B) : const Color(0xFFD9D8CE),
        opacity: _clampOpacity(state.modalOpacity),
      ),
    );
  }

  Rect _scaledRect(Rect rect, double s) => Rect.fromLTWH(
        rect.left * s,
        rect.top * s,
        rect.width * s,
        rect.height * s,
      );

  TextInputLayout _captchaLayout(TextInputStageState state, double s) {
    final dark = state.dark;
    final formWidth = (state.inputWidth ?? 0) * s;
    return TextInputLayout(
      kind: TextFieldKind.captcha,
      // Overlay.qml:446 的 visible 只判 login；loginMethod 的收窄由父容器 formFields 完成
      // （Overlay.qml:357），故这里取两者的有效可见性。
      visible: state.formVisible && state.loginMode,
      // Overlay.qml:456
      enabled: !state.loginBusy,
      // Overlay.qml:447-450
      rect: Rect.fromLTWH(
        ((state.inputX ?? 0) + 14) * s,
        (state.modalOffset + 541) * s,
        math.max(0.0, formWidth - 28 * s),
        55 * s,
      ),
      // Overlay.qml:453
      fontSize: 19 * s,
      fontFamily: null,
      // Overlay.qml:452
      textColor: dark ? const Color(0xFFEEEEEB) : const Color(0xFF161914),
      opacity: _clampOpacity(state.modalOpacity),
      clip: false,
      selectByMouse: false,
      // Overlay.qml:454
      cursorVisible: !state.performanceIdle,
      // Overlay.qml:455
      maxLength: 8,
      // Overlay.qml:457
      digitsOnly: true,
      sensitive: true,
      // Overlay.qml:458
      accessibilityName: '短信验证码',
      padding: EdgeInsets.zero,
      // Overlay.qml:435-442：整行背景。
      backdrop: TextInputBackdrop(
        rect: Rect.fromLTWH(
          (state.inputX ?? 0) * s,
          (state.modalOffset + 541) * s,
          math.max(0.0, formWidth),
          55 * s,
        ),
        color: dark ? const Color(0xFF30312B) : const Color(0xFFD9D8CE),
        opacity: _clampOpacity(state.modalOpacity),
      ),
    );
  }

  TextInputLayout _settingEditLayout(TextInputStageState state, double s) {
    final dark = state.dark;
    // Overlay.qml:567-570
    final bgRect = Rect.fromLTWH(
      (state.editingSettingX ?? 0) * s,
      ((state.editingSettingY ?? 0) + state.modalOffset) * s,
      (state.editingSettingWidth ?? 0) * s,
      (state.editingSettingHeight ?? 0) * s,
    );
    final inner = bgRect.width - 24 * s;
    // Overlay.qml:579-582，width 里的 Math.max(0, ...) 逐字保留。
    final rect = Rect.fromLTWH(
      bgRect.left + 12 * s,
      bgRect.top,
      inner < 0 ? 0.0 : inner,
      bgRect.height,
    );
    return TextInputLayout(
      kind: TextFieldKind.settingEdit,
      // Overlay.qml:578
      visible: state.settingEditVisible,
      // settingEditInput 没有 enabled 声明，QML 默认 true。
      enabled: true,
      rect: rect,
      // Overlay.qml:585
      fontSize: 16 * s,
      // Overlay.qml:584
      fontFamily: state.rhineFontFamily,
      // Overlay.qml:586
      textColor: dark ? const Color(0xFFE9E7DA) : const Color(0xFF222A25),
      // 未声明 opacity，且不在 formFields 内（Overlay.qml:575 是根 Item 的直接子项）。
      opacity: 1.0,
      // Overlay.qml:587
      clip: true,
      // Overlay.qml:588
      selectByMouse: true,
      // Overlay.qml:589
      cursorVisible: !state.performanceIdle,
      // 未声明 maximumLength：Qt TextInput.maximumLength 默认 32767，显式对齐（同 search）。
      maxLength: 32767,
      digitsOnly: false,
      sensitive: false,
      // Overlay.qml:590
      accessibilityName: '设置文本',
      padding: EdgeInsets.zero,
      // Overlay.qml:564-574
      backdrop: TextInputBackdrop(
        rect: bgRect,
        color: dark ? const Color(0xFF2B332C) : const Color(0xFFE5E7DA),
        opacity: 1.0,
        borderColor: dark ? const Color(0xFF4A554B) : const Color(0xFFAAB0A0),
        // Overlay.qml:572
        borderWidth: 1 * s,
      ),
    );
  }

  /// 表单按钮布局。accountLength 取提交文本长度（QML 读 accountField.text.length，而 Qt 的
  /// text 不含预编辑，Overlay.qml:414）。
  FormButtonLayout button(
    FormButtonKind kind,
    TextInputStageState state, {
    required int accountLength,
  }) {
    final s = state.stageScale;
    final login = state.loginMode;
    final formWidth = (state.inputWidth ?? 0) * s;
    switch (kind) {
      case FormButtonKind.sendCode:
        // Overlay.qml:414
        final enabled = !state.loginBusy &&
            state.smsRetrySeconds == 0 &&
            accountLength == 11;
        return FormButtonLayout(
          kind: kind,
          // Overlay.qml:409
          visible: state.formVisible && login,
          enabled: enabled,
          // Overlay.qml:410-413
          rect: Rect.fromLTWH(
            (state.inputX ?? 0) * s + math.max(0.0, formWidth - 170 * s),
            (state.modalOffset + 430) * s,
            math.max(0.0, 170 * s),
            math.max(0.0, 55 * s),
          ),
          // Overlay.qml:415
          color: const Color(0xFF777B60),
          // Overlay.qml:416 的自身 opacity × 父容器 formFields 的 opacity（Overlay.qml:362）。
          // 父 opacity 先被 Qt 钳到 [0,1]，再与子项相乘。
          opacity: _clampOpacity(state.modalOpacity) * (enabled ? 1.0 : 0.5),
          // Overlay.qml:419
          label: state.smsRetrySeconds > 0
              ? state.smsRetrySeconds.toString() + ' 秒后重发'
              : '发送验证码',
          // Overlay.qml:420
          labelColor: const Color(0xFFF0EEE5),
          // Overlay.qml:421
          fontSize: 14 * s,
          // Overlay.qml:424
          accessibilityName: '发送短信验证码',
        );
      case FormButtonKind.submit:
        // Overlay.qml:465
        final enabled = !login || !state.loginBusy;
        return FormButtonLayout(
          kind: kind,
          // 该 Rectangle 未声明 visible，随 formFields 容器可见性。
          visible: state.formVisible,
          enabled: enabled,
          // Overlay.qml:463-467；playlist-form 由宿主注入提交按钮矩形。
          rect: state.formSubmitRect == null
              ? Rect.fromLTWH(
                  (state.inputX ?? 0) * s + math.max(0.0, formWidth - 170 * s),
                  (state.modalOffset + (login ? 611 : 530)) * s,
                  math.max(0.0, 170 * s),
                  math.max(0.0, 36 * s),
                )
              : _scaledRect(state.formSubmitRect!, s),
          // Overlay.qml:468
          color: const Color(0xFF777B60),
          // Overlay.qml:469 的自身 opacity × 父容器 formFields 的 opacity（Overlay.qml:362）。
          // 父 opacity 先被 Qt 钳到 [0,1]，再与子项相乘。
          opacity: _clampOpacity(state.modalOpacity) * (enabled ? 1.0 : 0.5),
          // Overlay.qml:472
          label: login ? '登录 →' : '保存 →',
          // Overlay.qml:473
          labelColor: const Color(0xFFF0EEE5),
          // Overlay.qml:474
          fontSize: 14 * s,
          // Overlay.qml:477
          accessibilityName: '提交表单',
        );
    }
  }

  /// 可见性迁移（QML 的 onVisibleChanged）。Widget 在 initState / didUpdateWidget 里比对前后
  /// 可见性后调用。三个容器的语义互不相同，必须分开：
  /// - formFields（Overlay.qml:363-369）：变可见与变隐藏都清空两个字段；只有变可见才
  ///   accountField.forceActiveFocus()，变隐藏不碰焦点。
  /// - searchInput（Overlay.qml:541-548）：变可见写入 state.query 并抢焦点；变隐藏把焦点交回
  ///   输入层。
  /// - settingEditInput（Overlay.qml:592-599）：变可见写入 editingSettingValue 并抢焦点；
  ///   变隐藏把焦点交回输入层。
  List<TextInputEffect> visibilityEffects(
    TextInputContainer container, {
    required bool wasVisible,
    required bool isVisible,
    required TextInputStageState state,
  }) {
    if (wasVisible == isVisible) {
      return const <TextInputEffect>[];
    }
    switch (container) {
      case TextInputContainer.formFields:
        // playlist-form 与 login 共用 formFields，但初值语义不同：playlist-form 需要把
        // rename 目标名写入 account（不能空框），login 仍按 Overlay.qml:363-369 清空。
        // formInitialText 为 null 时完全走既有 login 分支，保证四类既有输入框不回归。
        if (isVisible &&
            state.modal == 'playlist-form' &&
            state.formInitialText != null) {
          return <TextInputEffect>[
            TextInputEffect.setText(
              TextFieldKind.account,
              state.formInitialText!,
            ),
            const TextInputEffect.clearText(TextFieldKind.captcha),
            const TextInputEffect.focusField(TextFieldKind.account),
          ];
        }
        final effects = <TextInputEffect>[
          const TextInputEffect.clearText(TextFieldKind.account),
          const TextInputEffect.clearText(TextFieldKind.captcha),
        ];
        if (isVisible) {
          effects.add(const TextInputEffect.focusField(TextFieldKind.account));
        }
        return effects;
      case TextInputContainer.searchInput:
        if (isVisible) {
          return <TextInputEffect>[
            TextInputEffect.setText(TextFieldKind.search, state.query ?? ''),
            const TextInputEffect.focusField(TextFieldKind.search),
          ];
        }
        return const <TextInputEffect>[TextInputEffect.focusInputLayer()];
      case TextInputContainer.settingEditInput:
        if (isVisible) {
          return <TextInputEffect>[
            TextInputEffect.setText(
              TextFieldKind.settingEdit,
              state.editingSettingValue ?? '',
            ),
            const TextInputEffect.focusField(TextFieldKind.settingEdit),
          ];
        }
        return const <TextInputEffect>[TextInputEffect.focusInputLayer()];
    }
  }

  /// 文本编辑上报（QML 的 onTextEdited，Overlay.qml:540、591）。
  ///
  /// account/captcha 没有 onTextEdited：它们的文本只在提交时被读取，故这里什么都不发。
  void textEdited(TextFieldKind kind, String committed) {
    switch (kind) {
      case TextFieldKind.search:
        ports.query(committed);
        break;
      case TextFieldKind.settingEdit:
        ports.settingEditText(committed);
        break;
      case TextFieldKind.account:
      case TextFieldKind.captcha:
        break;
    }
  }

  /// formFields.submit()（Overlay.qml:370-376）：login 且 loginBusy 时直接返回，否则
  /// submitForm(account, captcha) 并清空验证码。
  List<TextInputEffect> submit(
    TextInputStageState state, {
    required String account,
    required String captcha,
  }) {
    // Overlay.qml:371
    if (state.loginMode && state.loginBusy) {
      return const <TextInputEffect>[];
    }
    // Overlay.qml:374
    ports.submitForm(account, captcha);
    // Overlay.qml:375
    return const <TextInputEffect>[TextInputEffect.clearText(TextFieldKind.captcha)];
  }

  /// 发送验证码（Overlay.qml:427、432）。Engine 只在 login + phone 下真的发码。
  void sendLoginCode(TextInputStageState state, {required String account}) {
    if (!state.loginMode || state.loginMethod != 'phone') {
      return;
    }
    ports.sendLoginCode(account);
  }

  /// Return / Escape 分支。业务副作用立即经 ports 发出，界面侧改动（焦点）以 effects 返回。
  /// [text] 是本框当前提交文本；[account] / [captcha] 是另一框的提交文本，只有 submit 分支
  /// 需要（Qt 的 submit() 直接读两个框的 text，Overlay.qml:374）。
  List<TextInputEffect> handleKey(
    TextFieldKind kind,
    TextInputKeyEvent event, {
    required TextInputStageState state,
    required String text,
    String account = '',
    String captcha = '',
  }) {
    if (event.isEscape) {
      return _onEscape(kind);
    }
    if (event.isReturn) {
      return _onReturn(
        kind,
        event,
        state: state,
        text: text,
        account: account,
        captcha: captcha,
      );
    }
    return const <TextInputEffect>[];
  }

  List<TextInputEffect> _onEscape(TextFieldKind kind) {
    switch (kind) {
      case TextFieldKind.search:
      case TextFieldKind.account:
      case TextFieldKind.captcha:
        // Overlay.qml:406、460、549
        ports.action(HudAction.closeModal);
        break;
      case TextFieldKind.settingEdit:
        // Overlay.qml:601 —— 设置项编辑的 Escape 是取消编辑，不是关弹窗。
        ports.settingEditCancel();
        break;
    }
    return const <TextInputEffect>[];
  }

  List<TextInputEffect> _onReturn(
    TextFieldKind kind,
    TextInputKeyEvent event, {
    required TextInputStageState state,
    required String text,
    required String account,
    required String captcha,
  }) {
    switch (kind) {
      case TextFieldKind.search:
        // Overlay.qml:550-552 -> Engine.cpp:1006-1012
        ports.searchAccepted(text, control: event.control);
        return const <TextInputEffect>[];
      case TextFieldKind.account:
        // Overlay.qml:399-405：login 时把焦点交给验证码，否则直接提交表单。
        if (state.loginMode) {
          return const <TextInputEffect>[
            TextInputEffect.focusField(TextFieldKind.captcha),
          ];
        }
        // playlist-form 下 Qt 也提交两个框的 text，但 Engine 只取 account 作歌单名。
        return submit(state, account: text, captcha: captcha);
      case TextFieldKind.captcha:
        // Overlay.qml:459
        return submit(state, account: account, captcha: text);
      case TextFieldKind.settingEdit:
        // Overlay.qml:600
        ports.settingEditAccepted();
        return const <TextInputEffect>[];
    }
  }
}

/// 文本输入层的 Widget：把 [TextInputLayout] / [FormButtonLayout] 铺成真实控件，并把
/// EditableText 的真实 TextEditingValue（含 selection / composing）接进判定逻辑。
///
/// 本 Widget 不持有任何业务真相：几何、可见性、使能全部来自 [TextInputStageState]；
/// 文本、选区、组合态全部来自 controller.value（真实 TextInputClient 通路）。
class TextInputOverlay extends StatefulWidget {
  const TextInputOverlay({
    super.key,
    required this.state,
    required this.ports,
    this.accountFieldKey,
    this.submitButtonKey,
  });

  final TextInputStageState state;
  final TextInputPorts ports;

  /// 可选：account 字段（EditableText）的稳定 Key，供宿主命中/测试定位。
  /// 默认 null，既有调用方无需改动。
  final Key? accountFieldKey;

  /// 可选：submit 按钮的稳定 Key。默认 null，既有调用方无需改动。
  final Key? submitButtonKey;

  @override
  State<TextInputOverlay> createState() => _TextInputOverlayState();
}

class _TextInputOverlayState extends State<TextInputOverlay> {
  final Map<TextFieldKind, TextEditingController> _controllers =
      <TextFieldKind, TextEditingController>{};
  final Map<TextFieldKind, FocusNode> _focusNodes = <TextFieldKind, FocusNode>{};
  final Map<TextFieldKind, TextCommitTracker> _trackers =
      <TextFieldKind, TextCommitTracker>{};

  /// 逻辑对象是纯判定，按端口现取即可（无状态，构造开销可忽略）。
  TextInputOverlayLogic get _logic => TextInputOverlayLogic(ports: widget.ports);

  @override
  void initState() {
    super.initState();
    for (final kind in TextFieldKind.values) {
      _controllers[kind] = TextEditingController();
      _focusNodes[kind] = FocusNode(
        debugLabel: 'text_input_overlay.' + kind.objectName,
      );
      _trackers[kind] = TextCommitTracker();
    }
    // QML 的组件从创建即存在，创建期不触发 onVisibleChanged；Flutter 侧挂载可能发生在弹窗
    // 已经打开之后（重建、热重启），若不补一次迁移，输入框会停在空文本且没有焦点。
    // 故按「上一状态三容器全不可见」走一次迁移。该差异记入 TBD（见报告）。
    _applyVisibility(TextInputStageState.inactive, widget.state);
  }

  @override
  void didUpdateWidget(TextInputOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyVisibility(oldWidget.state, widget.state);
    // 可见性不变但表单身份变化（rename 切到另一首歌单、create/rename 互切）时，
    // onVisibleChanged 不会触发；playlist-form 必须在这里重设初值，否则会复用上一首的文本。
    // formInitialText 为 null 的既有调用方不受影响。
    if (widget.state.modal == 'playlist-form' &&
        widget.state.formInitialText != null &&
        (oldWidget.state.formIdentity != widget.state.formIdentity ||
            oldWidget.state.formInitialText != widget.state.formInitialText)) {
      _apply(<TextInputEffect>[
        TextInputEffect.setText(
          TextFieldKind.account,
          widget.state.formInitialText!,
        ),
        const TextInputEffect.focusField(TextFieldKind.account),
      ]);
    }
    // playlist-form → 其他 formFields（典型是 login phone）：两者 formVisible 都为 true，
    // visibilityEffects 不会清空；这里补一次清空，保持 login 不会继承歌单名。
    if (oldWidget.state.modal == 'playlist-form' &&
        widget.state.modal != 'playlist-form' &&
        widget.state.formVisible) {
      _apply(const <TextInputEffect>[
        TextInputEffect.clearText(TextFieldKind.account),
        TextInputEffect.clearText(TextFieldKind.captcha),
      ]);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 绘制顺序照 QML 的 z 序：formFields(355-484) -> searchInput(519-562) ->
    // settingEditInput(575-602)。后画的在上层。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ..._fieldSlot(TextFieldKind.account),
        ..._buttonSlot(FormButtonKind.sendCode),
        ..._fieldSlot(TextFieldKind.captcha),
        ..._buttonSlot(FormButtonKind.submit),
        ..._fieldSlot(TextFieldKind.search),
        ..._fieldSlot(TextFieldKind.settingEdit),
      ],
    );
  }

  /// 一个输入框的「背景 Rectangle + TextInput」（QML 里成对出现）。
  List<Widget> _fieldSlot(TextFieldKind kind) {
    final TextInputLayout layout = _logic.layout(kind, widget.state);
    if (!layout.visible) {
      return const <Widget>[];
    }
    final TextInputBackdrop? backdrop = layout.backdrop;
    return <Widget>[
      if (backdrop != null)
        Positioned.fromRect(
          rect: backdrop.rect,
          child: Opacity(
            opacity: backdrop.opacity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: backdrop.color,
                border: backdrop.borderColor == null || backdrop.borderWidth <= 0
                    ? null
                    : Border.all(
                        color: backdrop.borderColor!,
                        width: backdrop.borderWidth,
                      ),
              ),
            ),
          ),
        ),
      Positioned.fromRect(
        rect: layout.rect,
        child: Opacity(
          opacity: layout.opacity,
          child: _fieldBody(kind, layout),
        ),
      ),
    ];
  }

  Widget _fieldBody(TextFieldKind kind, TextInputLayout layout) {
    final TextEditingController controller = _controllers[kind]!;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        // 命中面按 layout.rect 推导，不用 EditableText 的自然尺寸：Qt 的 TextInput
        // 整个 width×height 都可点选。文字行高之外的上下留白由这里兜底请求焦点；
        // 语义节点仍只由下方 MergeSemantics 发布（ExcludeSemantics 只挡语义，不挡命中）。
        Positioned.fill(
          child: ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: layout.enabled
                  ? () => _focusNodes[kind]!.requestFocus()
                  : null,
            ),
          ),
        ),
        // Escape 通路：Android 上框架不消费 Escape
        // （default_text_editing_shortcuts.dart:981-996 返回 null），故由祖先 Focus 承接
        // （Overlay.qml:406、460、549、601）。canRequestFocus 为 false：焦点只能由
        // onVisibleChanged 的 forceActiveFocus 语义显式请求，避免 Tab 遍历改变 Qt 的焦点路径。
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (FocusNode node, KeyEvent event) => _handleKey(kind, event),
          child: Padding(
            padding: layout.padding,
            child: Align(
              alignment: Alignment.centerLeft,
              // 撑满可用宽度（Align 会给子级松约束）：Qt TextInput 的 width 是整段，
              // 点右侧空白也要落在文本命中的 x 上，而不是只命中文字宽度。
              child: SizedBox(
                width: double.infinity,
                child: MergeSemantics(
                  child: Semantics(
                    // RenderEditable 自己就发布 isTextField 节点
                    // （rendering/editable.dart:1380-1384），故 label 必须合并进那个节点，
                    // 不能另起一个兄弟节点。节点形状待设备 a11y inspector 复核（TBD）。
                    label: layout.accessibilityName,
                    enabled: layout.enabled,
                    readOnly: !layout.enabled,
                    // Qt 的 enabled:false 连鼠标/触摸都不接收（不能靠点击取得焦点）；
                    // readOnly 只挡编辑，故再包一层 IgnorePointer。语义节点仍保留。
                    child: IgnorePointer(
                      ignoring: !layout.enabled,
                      child: _editable(kind, layout),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 占位文案（Overlay.qml:553-561）：与输入框同层、同样左内边距、垂直居中，
        // 只在「提交文本空且无组合文本」时出现；IgnorePointer 保证它不吃触摸。
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (BuildContext context, TextEditingValue value, Widget? child) {
            if (!layout.hasPlaceholder || !showsPlaceholder(value)) {
              return const SizedBox.shrink();
            }
            return IgnorePointer(
              child: Padding(
                // QML 只抄了 leftPadding（Overlay.qml:558），rightPadding 保持默认 0。
                padding: EdgeInsets.only(left: layout.padding.left),
                child: Align(
                  alignment: Alignment.centerLeft,
                  // 占位只是视觉提示；Accessible.name 已挂在输入框语义节点上，
                  // 不让这段文字再发布一次 label（QML 里它没有 Accessible 附加对象）。
                  child: ExcludeSemantics(
                    child: Text(
                      layout.placeholder!,
                      style: TextStyle(
                        fontFamily: layout.fontFamily,
                        fontSize: layout.fontSize,
                        color: layout.placeholderColor,
                      ),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      // Qt 的 pixelSize 不吃系统字体缩放；Text 默认吃 MediaQuery。
                      textScaler: TextScaler.noScaling,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// 真实文本输入栈：EditableText 的 State 本身就是 TextInputClient 实现，
  /// controller.value.composing 即平台组合态。
  ///
  /// 用 Align 而不是 SizedBox 固定高度：RenderEditable 在自己的高度内顶对齐，Qt 的
  /// AlignVCenter（Overlay.qml:391、451、522、583）要求单行文本在框内垂直居中，
  /// 故让它保持自然高度再由 Align 居中。
  Widget _editable(TextFieldKind kind, TextInputLayout layout) {
    return EditableText(
      key: kind == TextFieldKind.account ? widget.accountFieldKey : null,
      controller: _controllers[kind]!,
      focusNode: _focusNodes[kind]!,
      style: layout.textStyle,
      // QML 未声明 cursorColor，这里用文字色（TBD）。
      cursorColor: layout.textColor,
      backgroundCursorColor: layout.textColor,
      // Qt 的 enabled:false 只是失能：映射为只读 + 不可交互，不隐藏、不清空。
      readOnly: !layout.enabled,
      // ImhSensitiveData 不遮挡文本（Overlay.qml:457），绝不用 obscureText。
      obscureText: false,
      // Qt TextInput 默认单行；maxLines == 1 时 EditableText 还会追加
      // FilteringTextInputFormatter.singleLineFormatter（editable_text.dart:965-972），
      // 等价于禁止输入换行。
      maxLines: 1,
      // Qt 的 font.pixelSize 不吃系统字体缩放（Overlay.qml:533、393、453、585）。
      textScaler: TextScaler.noScaling,
      textAlign: TextAlign.start,
      textInputAction: TextInputAction.done,
      // ImhDigitsOnly 只是输入法提示，故只映射键盘类型，不加数字过滤 formatter。
      keyboardType:
          layout.digitsOnly ? TextInputType.number : TextInputType.text,
      // maximumLength（Overlay.qml:395、455）在 Qt 是硬截断，用限长 formatter 对齐。
      // playlist-form 可注入按 UTF-16 码元计数的旧实现；其余 kind 仍用默认限长。
      inputFormatters: layout.inputFormatters ??
          (layout.maxLength == null
              ? null
              : <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(layout.maxLength!), // 公共 final 字段不做字段提升。
                ]),
      // selectByMouse（Overlay.qml:538、588）字面映射到交互式选区。
      enableInteractiveSelection: layout.selectByMouse,
      // Overlay.qml:394/454/537/589：activeFocus && !performance.idle。
      showCursor: layout.cursorVisible && layout.enabled,
      // Overlay.qml:536、587 的 clip。
      clipBehavior: layout.clip ? Clip.hardEdge : Clip.none,
      // ImhSensitiveData：只关「联想/自动更正/个性化学习」，不改显示。
      autocorrect: !layout.sensitive,
      enableSuggestions: !layout.sensitive,
      enableIMEPersonalizedLearning: !layout.sensitive,
      onChanged: (String value) => _onChanged(kind),
      // 空实现：EditableText 在 onEditingComplete != null 时只调用它，跳过默认的
      // clearComposing + unfocus（editable_text.dart:3914-3985），保持 Qt 中 Return
      // 不迁移焦点的语义。
      onEditingComplete: () {},
      onSubmitted: (String value) => _onReturn(kind),
    );
  }

  /// QML 的 onTextEdited（Overlay.qml:540、591）。Flutter 的 onChanged 连组合态变化也会回调，
  /// 故按提交文本去重；这里不 setState：占位文案与 sendCode 的使能都由 ValueListenableBuilder
  /// 跟随 controller.value 重算，等价于 QML 的绑定重算。
  void _onChanged(TextFieldKind kind) {
    final String committed = committedText(_controllers[kind]!.value);
    final String? accepted = _trackers[kind]!.acceptText(committed);
    if (accepted == null) {
      return;
    }
    _logic.textEdited(kind, accepted);
  }

  /// 硬件 Return：引擎把 enter 翻译成 done action 后才回调 onSubmitted
  /// （editable_text.dart:1485-1496），故这里是唯一的 Return 通路。
  void _onReturn(TextFieldKind kind) {
    // QML 的 enabled:false 会同时切断按键通路（Overlay.qml:396、456、527）；本层不主动
    // unfocus（见文件头 TBD），但绝不能把失能期间的 done action 继续当成 Return 处理。
    if (!_logic.layout(kind, widget.state).enabled) {
      return;
    }
    final List<TextInputEffect> effects = _logic.handleKey(
      kind,
      TextInputKeyEvent(isReturn: true, control: _controlDown()),
      state: widget.state,
      text: committedText(_controllers[kind]!.value),
      account: committedText(_controllers[TextFieldKind.account]!.value),
      captcha: committedText(_controllers[TextFieldKind.captcha]!.value),
    );
    _apply(effects);
  }

  /// Escape 通路（Qt 的 Keys.onEscapePressed）。
  KeyEventResult _handleKey(TextFieldKind kind, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // 同 _onReturn：Qt 的 disabled TextInput 不接收 Escape（Overlay.qml:396、456、527）。
    if (!_logic.layout(kind, widget.state).enabled) {
      return KeyEventResult.ignored;
    }
    final List<TextInputEffect> effects = _logic.handleKey(
      kind,
      const TextInputKeyEvent(isEscape: true),
      state: widget.state,
      text: committedText(_controllers[kind]!.value),
    );
    _apply(effects);
    return KeyEventResult.handled;
  }

  /// Qt 的 event.modifiers & Qt::ControlModifier（Engine.cpp:1003-1004）。Qt 在 macOS 把 Cmd
  /// 映射到 ControlModifier，故 macOS 上 Meta 也算。
  bool _controlDown() {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) {
      return true;
    }
    return defaultTargetPlatform == TargetPlatform.macOS &&
        keyboard.isMetaPressed;
  }

  /// 执行界面侧改动。文本赋值后同步去重基线：QML 里程序化赋值 text 不产生 onTextEdited
  /// （Overlay.qml:543、594）。
  void _apply(List<TextInputEffect> effects) {
    for (final TextInputEffect effect in effects) {
      final TextFieldKind? field = effect.field;
      switch (effect.kind) {
        case TextInputEffect.kindSetText:
        case TextInputEffect.kindClearText:
          if (field == null) {
            continue;
          }
          final String text = effect.text ?? '';
          _controllers[field]!.value = valueForText(text);
          _trackers[field]!.resetTo(text);
          break;
        case TextInputEffect.kindFocus:
          if (field == null) {
            continue;
          }
          _focusNodes[field]!.requestFocus();
          break;
        case TextInputEffect.kindFocusInputLayer:
          widget.ports.focusInputLayer();
          break;
      }
    }
  }

  /// 可见性迁移的执行（QML onVisibleChanged）。
  void _applyVisibility(TextInputStageState previous, TextInputStageState next) {
    _apply(
      _logic.visibilityEffects(
        TextInputContainer.formFields,
        wasVisible: previous.formVisible,
        isVisible: next.formVisible,
        state: next,
      ),
    );
    _apply(
      _logic.visibilityEffects(
        TextInputContainer.searchInput,
        wasVisible: previous.searchVisible,
        isVisible: next.searchVisible,
        state: next,
      ),
    );
    _apply(
      _logic.visibilityEffects(
        TextInputContainer.settingEditInput,
        wasVisible: previous.settingEditVisible,
        isVisible: next.settingEditVisible,
        state: next,
      ),
    );
  }

  List<Widget> _buttonSlot(FormButtonKind kind) {
    if (kind == FormButtonKind.sendCode) {
      // Overlay.qml:414 的 enabled 依赖 accountField.text.length，QML 靠绑定重算；
      // Flutter 侧用 ValueListenableBuilder 跟随 account controller 重算。
      return <Widget>[
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controllers[TextFieldKind.account]!,
          builder: (BuildContext context, TextEditingValue value, Widget? child) {
            return _buttonBody(
              _logic.button(
                FormButtonKind.sendCode,
                widget.state,
                accountLength: committedText(value).length,
              ),
            );
          },
        ),
      ];
    }
    return <Widget>[
      KeyedSubtree(
        key: widget.submitButtonKey,
        child: _buttonBody(
          _logic.button(
            FormButtonKind.submit,
            widget.state,
            accountLength:
                committedText(_controllers[TextFieldKind.account]!.value).length,
          ),
        ),
      ),
    ];
  }

  Widget _buttonBody(FormButtonLayout layout) {
    if (!layout.visible) {
      return Positioned.fromRect(rect: Rect.zero, child: const SizedBox.shrink());
    }
    return Positioned.fromRect(
      rect: layout.rect,
      child: Opacity(
        opacity: layout.opacity,
        child: MergeSemantics(
          child: Semantics(
            button: true,
            enabled: layout.enabled,
            // Overlay.qml:424、477 的 Accessible.name，与可见文案不同。
            label: layout.accessibilityName,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // QML 里子 MouseArea 随父 Rectangle.enabled 一起失能（Overlay.qml:414、465），
              // 且发送验证码的 onPressAction 另有 if (enabled) 守卫（Overlay.qml:425-429）。
              onTap: layout.enabled ? () => _activateButton(layout.kind) : null,
              child: ColoredBox(
                color: layout.color,
                child: Center(
                  // 可见文案不再发布第二个 label：Qt 的 Accessible.name 已覆盖它
                  // （Overlay.qml:424、477），MergeSemantics 只保留 button/enabled/onTap。
                  child: ExcludeSemantics(
                    child: Text(
                      layout.label,
                      style: TextStyle(
                        fontSize: layout.fontSize,
                        color: layout.labelColor,
                      ),
                      maxLines: 1,
                      textScaler: TextScaler.noScaling,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 按钮激活（Qt 的 MouseArea.onClicked 与 Accessible.onPressAction 汇到同一处）。
  void _activateButton(FormButtonKind kind) {
    final TextInputStageState state = widget.state;
    final String account =
        committedText(_controllers[TextFieldKind.account]!.value);
    if (kind == FormButtonKind.sendCode) {
      // Overlay.qml:427、432
      _logic.sendLoginCode(state, account: account);
      return;
    }
    // Overlay.qml:370-376、478
    final String captcha =
        committedText(_controllers[TextFieldKind.captcha]!.value);
    _apply(_logic.submit(state, account: account, captcha: captcha));
  }
}

