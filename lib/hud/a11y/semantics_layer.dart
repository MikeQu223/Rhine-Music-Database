/// 无障碍语义层：把 Qt 的 Accessible.role / Accessible.name / Accessible.onPressAction
/// 1:1 投影成 Flutter Semantics，并给出可静态审查的节点清单。
///
/// ## hits 的 delegate（Overlay.qml:185-220 的 Repeater，:187-199 是 delegate 本体）
///     Repeater {
///         model: rhine.hits
///         delegate: Item {
///             required property var modelData
///             property rect area: overlay.hitArea(modelData)
///             x: area.x
///             y: area.y + (rhine.state.modal && !modelData.fixed
///                          ? rhine.state.modalOffset || 0 : 0)
///             width: area.width
///             height: area.height
///             Accessible.role: Accessible.Button                       // :194
///             Accessible.name: modelData.label                         // :195
///             Accessible.onPressAction: rhine.action(modelData.action) // :196
/// area = Qt.rect(x - pad, y - pad, width + 2pad, height + 2pad)（Overlay.qml:40-43），
/// pad = android ? 16 : 0（Overlay.qml:38）。这与 hit_layer.dart 的
/// [HitLayer.effectiveRect] / [HitLayer.offsetY] 是同一套算法，本层直接复用，绝不另算一份
/// 几何——语义矩形与命中矩形必须永远来自同一次 frame generation。
///
/// ## label 的来源：不回落、不新造
/// Qt/src/NativeHud.cpp:102-109：
///     hits.append(QJsonObject{{"x", x}, {"y", y}, {"width", width}, {"height", height},
///                             {"action", action},
///                             {"label", label.isNull() ? action : label}});
/// 只有「未提供 label」（null）才回落 action；显式空串原样保留。也就是说空 label 的命中在
/// Qt 里就是一个没有名字的 Button（Accessible.name 为空），而不是「label 为空就显示 action」。
/// 本层逐字透传 [HudHit.label]：不回落、不 trim、不补默认文案。wire 缺字段时的回落发生在
///  的 decodeHudHits（hud_hit.dart），本层不重复也不改写。
///
/// ## 顶部导航就是 hits，不是另一套节点
/// NativeHud.cpp:121-124 的 control() 直接 hit(x - 10, y, width + 20, 54, action, label)，
/// 导航行在 :348-355：
/// - 文件夹视图 '文件夹管理 ＋'，否则 '发现音乐 ↗'
/// - '音乐检索  /'（两个空格，逐字）
/// - '本地曲库' / '＋ 我的音乐' / '＋ 塞壬曲库'（取决于 isLocal / isSiren）
/// - updater.available() ? '设置 · 更新' : '设置'
/// 文案本身在 C++ 侧随状态变化，所以 Dart 侧只能取 hit.label：任何重写这四个字符串的做法都会
/// 与画面文案脱钩。Qt 的每个 delegate 只有一个 Accessible，因此 hitNodes(...) 与
/// navigationNodes(...) 是**重叠集合**，禁止相加后一起挂载（那会把一个 delegate 朗读两遍）；
/// [RhineSemanticsLayer.fromHits] 从构造上避免了这种拼法。
///
/// ## 输入框与表单按钮
/// - Overlay.qml:398 账号框 Accessible.name（playlist-form ? '歌单名称' : '手机号码'）
/// - Overlay.qml:458 验证码框 '短信验证码'
/// - Overlay.qml:539 检索框 localMusic
///   ? '检索本地歌曲、歌手、专辑或文件夹' : '搜索歌曲、歌手、专辑或歌单'
/// - Overlay.qml:590 设置框 '设置文本'
/// 这四个都只有 name，没有 role、没有 onPressAction：Qt 的 TextInput 自己发布可编辑语义
/// （角色、值、选区、预编辑）。:423-429（发送短信验证码）与 :476-478（提交表单）才是
/// Button + onPressAction。对应字符串在 text_input_overlay.dart 里已经是
/// [TextInputLayout.accessibilityName] / [FormButtonLayout.accessibilityName]，本层只引用，
/// 不复制字面量。
///
/// ## 顺序
/// Qt 的语义树顺序 = Repeater 的 delegate 创建顺序 = hits 顺序。本层按同一个 List 顺序铺
/// Semantics，且不设 sortKey（Stack 的 child 顺序就是遍历顺序），故 id 为 hit:<i> 的节点与
/// hits[i] 一一对应，节点总数恒等于 hits.length。
///
/// ## 与指针通路的关系（禁止互相顶替）
/// Qt 里指针走 hits 的 MouseArea（Overlay.qml:197-220），无障碍走 Accessible.onPressAction
/// （:196），两条通路互不重叠；按下即触发 / 抬起且释放点在同一命中才触发这类平台差异
/// （[HitLayer.firesOnPress]）只属于指针。本层的语义节点一律包在 IgnorePointer 里：同一次
/// 点击不允许被 pointer_router 与 Semantics 各触发一次。
///
/// ## 与 TextInputOverlay 的关系（避免重复朗读）
/// 输入框的值 / 选区 / 预编辑由真实 EditableText 发布（它同时发布 isTextField + value +
/// selection），TextInputOverlay 已用 MergeSemantics 把 Accessible.name 合到同一个节点上。
/// 因此 [inputNodes] 默认只承担「文案与几何来源」的静态对账，[RhineSemanticsLayer] 默认跳过
/// text-field 节点；只有宿主接管输入框、不再挂 EditableText 时才打开 includeTextFieldNodes。
///
/// ## Android 无障碍桥
/// Qt 在 Android 上默认关掉整座桥（AndroidWindow.cpp:62-71），策略表达在
/// [AndroidAccessibilityBridge]，本层不据此自己隐藏语义树（Flutter 没有
/// QAccessible::setActive(false) 的等价运行时开关）。
library;


import 'package:flutter/widgets.dart';

import '../input/hit_layer.dart';
import '../input/text_input_overlay.dart';
import '../protocol/hud_hit.dart';

/// Qt Accessible.role 在本工程用到的两个取值。
///
/// 它只回答「Qt 那个 Accessible 节点是什么」，不是 Flutter 的 SemanticsRole：dart:ui 的同名
/// 枚举里根本没有 button 成员，Flutter 的按钮身份是 Semantics(button: true)
/// （见 [RhineSemanticsLayer.build]），本文件不设置 Semantics.role，两者不会打架；
/// package:flutter/widgets.dart 也不导出 dart:ui 的 SemanticsRole，所以这个本地类不会造成
/// import 歧义。
class SemanticsRole {
  const SemanticsRole._();

  /// Accessible.Button（Overlay.qml:194、423、476）。
  static const String button = 'button';

  /// 可编辑文本：QML 里没有显式 role 声明，Qt 的 TextInput 自身发布可编辑语义。
  static const String textField = 'text-field';
}

/// 顶部导航的 action 常量：Qt/src/NativeHud.cpp:348-355 传给 control(...) 的 action。
class NavigationAction {
  const NavigationAction._();

  static const String discover = 'discover';
  static const String search = 'search';
  static const String saved = 'saved';
  static const String settings = 'settings';

  /// 全部导航 action（顺序与 NativeHud.cpp:348-355 一致）。
  static const List<String> all = <String>[discover, search, saved, settings];

  static bool isNavigation(String action) => all.contains(action);
}

/// 表单按钮的语义命令。宿主据此调用端口；载荷必须取实时 controller 文本
/// （Qt 的 onPressAction 也是现读 accountField.text，Overlay.qml:427）。
enum SemanticsCommand { sendCode, submit }

/// 一个无障碍节点：Qt 的（role, name, pressAction）+ 屏幕矩形（逻辑坐标）。
class HudSemanticsNode {
  const HudSemanticsNode({
    required this.id,
    required this.rect,
    required this.role,
    required this.label,
    this.enabled = true,
    this.action,
    this.command,
    this.value,
    this.selection,
    this.composing,
    this.focused = false,
    this.maxLength,
  });

  /// 稳定标识（测试与 diff 用）：hit:<index>、nav:<action>、input:<objectName>、
  /// form:send-code。
  ///
  /// 同序即可对齐 hits：hit:<i> 永远是 hits[i]，没有 sortKey 参与重排。
  final String id;

  /// 逻辑坐标矩形（舞台坐标 * stageScale），与命中判定同源。
  final Rect rect;

  /// [SemanticsRole] 之一。
  final String role;

  /// Accessible.name，逐字来自 Qt（空串就是空串）。
  final String label;

  /// Qt 的 enabled（失能按钮不触发 onPressAction：Overlay.qml:426 的 if (enabled) 守卫）。
  final bool enabled;

  /// rhine.action(...) 的参数（hit delegate 原样透传，Overlay.qml:196）。
  final String? action;

  /// 表单按钮命令（非 hit 节点才有）。
  final SemanticsCommand? command;

  /// 真实输入框的文本（TextEditingValue.text），text-field 节点才有；null = 调用方未提供。
  ///
  /// 必须来自那个真正挂在 EditableText 上的 TextEditingController —— 它是唯一持有
  /// TextInputClient 的真相，任何在这里重新拼接、补默认值或按 placeholder 填充的做法都会让
  /// 读屏念出与画面不一致的值。
  final String? value;

  /// 真实输入框的选区（同一个 TextEditingValue.selection）。
  ///
  /// 注意：Flutter 的 Semantics 组件没有 textSelection 参数（SemanticsConfiguration 不携带
  /// 选区），选区只能由真实 EditableText / TextInputClient 发布。本字段供静态对账与测试断言
  /// 「语义层的值、选区、矩形确实取自同一份输入状态」，不用于自造选区语义。
  final TextSelection? selection;

  /// 真实输入框的预编辑区（同一个 TextEditingValue.composing）。
  final TextRange? composing;

  /// 该输入框当前是否持有焦点（真实 FocusNode.hasFocus / activeFocus）。
  final bool focused;

  /// Qt 的 maximumLength（原样取 TextInputLayout.maxLength，本层不改写）：检索框未声明
  /// maximumLength，产品层按 Qt 默认 32767 显式对齐；账户框 login 11 / playlist-form 100、
  /// 验证码 8、设置框 32767。Qt 的 QAccessibleTextInterface 不暴露最大长度，所以该值只留在
  /// 数据模型供对账，不投影成 Semantics.maxValueLength。
  final int? maxLength;

  bool get isButton => role == SemanticsRole.button;

  bool get isTextField => role == SemanticsRole.textField;

  @override
  String toString() => 'HudSemanticsNode($id, $role, $label)';
}

/// hits 列表的语义节点：Accessible.role / name / onPressAction 的 1:1 投影
/// （Overlay.qml:187-196）。
///
/// 矩形 = rectToLogical(effectiveRect(hit))：pad 只消费侧（android ? 16 : 0），modalOffset
/// 只加非 fixed，与命中判定完全同一份算法，不在这里重算。
///
/// Qt 的 Accessible 不区分命中是否被播放条屏蔽（屏蔽只作用于指针，见
/// [HitLayer.isShielded]），故这里也不做屏蔽过滤；也不丢弃空 label 的命中。
List<HudSemanticsNode> hitNodes(HitLayer layer, List<HudHit> hits) {
  final List<HudSemanticsNode> nodes = <HudSemanticsNode>[];
  for (int index = 0; index < hits.length; index++) {
    final HudHit hit = hits[index];
    nodes.add(
      HudSemanticsNode(
        id: 'hit:$index',
        rect: layer.geometry.rectToLogical(layer.effectiveRect(hit)),
        role: SemanticsRole.button,
        label: hit.label,
        enabled: true,
        action: hit.action,
      ),
    );
  }
  return nodes;
}

/// 顶部导航的语义视图：hits 里 action 属于 [NavigationAction.all] 的那几个，文案直接取
/// hit.label（NativeHud.cpp:348-355），不另写字面量。
///
/// 这是 [hitNodes] 的**子集视图**，用于「只关心导航」的断言与调试。Qt 的每个 delegate 只有
/// 一个 Accessible，所以不得把它和 hitNodes 的结果相加后一起挂到 [RhineSemanticsLayer]
/// （同一命中会被朗读两遍）。需要整棵树时只用 hitNodes。
List<HudSemanticsNode> navigationNodes(HitLayer layer, List<HudHit> hits) {
  final List<HudSemanticsNode> nodes = <HudSemanticsNode>[];
  for (final HudHit hit in hits) {
    if (!NavigationAction.isNavigation(hit.action)) {
      continue;
    }
    nodes.add(
      HudSemanticsNode(
        id: 'nav:${hit.action}',
        rect: layer.geometry.rectToLogical(layer.effectiveRect(hit)),
        role: SemanticsRole.button,
        label: hit.label,
        enabled: true,
        action: hit.action,
      ),
    );
  }
  return nodes;
}

/// 四个输入框与两个表单按钮的语义节点（Overlay.qml:398、424、458、477、539、590）。
///
/// label 直接引用 [TextInputLayout.accessibilityName] /
/// [FormButtonLayout.accessibilityName]，不复制字符串；几何直接用 [TextInputLayout.rect]，
/// 与输入层绘制同一个矩形。
///
/// [values] 与 [focused] 必须由宿主从**真实的** TextEditingController / FocusNode 取：
/// text-field 节点的 value / selection / composing / focused 只是把它们搬到节点上供对账，
/// 本层不生成、不推断、不补默认值。缺省（不传）时这些字段保持 null / false。
///
/// 默认情形下不要把它与 [TextInputOverlay] 一起当成语义树挂载：输入框的可编辑语义由
/// EditableText 自己发布，再叠一层会重复朗读。它的职责是让「文案与几何来自哪里」可被静态
/// 审查，以及在宿主不用内联 Semantics 时接管。
List<HudSemanticsNode> inputNodes(
  TextInputOverlayLogic logic,
  TextInputStageState state, {
  required int accountLength,
  Map<TextFieldKind, TextEditingValue> values =
      const <TextFieldKind, TextEditingValue>{},
  TextFieldKind? focused,
}) {
  const List<TextFieldKind> order = <TextFieldKind>[
    TextFieldKind.search,
    TextFieldKind.account,
    TextFieldKind.captcha,
    TextFieldKind.settingEdit,
  ];
  final List<HudSemanticsNode> nodes = <HudSemanticsNode>[];
  for (final TextFieldKind kind in order) {
    final TextInputLayout layout = logic.layout(kind, state);
    if (!layout.visible) {
      continue;
    }
    final TextEditingValue? editing = values[kind];
    nodes.add(
      HudSemanticsNode(
        id: 'input:${kind.objectName}',
        rect: layout.rect,
        role: SemanticsRole.textField,
        label: layout.accessibilityName,
        enabled: layout.enabled,
        value: editing?.text,
        selection: editing?.selection,
        composing: editing?.composing,
        focused: focused == kind,
        maxLength: layout.maxLength,
      ),
    );
  }
  for (final FormButtonKind kind in FormButtonKind.values) {
    final FormButtonLayout layout = logic.button(
      kind,
      state,
      accountLength: accountLength,
    );
    if (!layout.visible) {
      continue;
    }
    nodes.add(
      HudSemanticsNode(
        id: 'form:${kind == FormButtonKind.sendCode ? 'send-code' : 'submit'}',
        rect: layout.rect,
        role: SemanticsRole.button,
        label: layout.accessibilityName,
        enabled: layout.enabled,
        command: kind == FormButtonKind.sendCode
            ? SemanticsCommand.sendCode
            : SemanticsCommand.submit,
      ),
    );
  }
  return nodes;
}

/// 把语义节点铺成 Flutter Semantics 树。
///
/// [nodes] 只喂 [hitNodes] 的结果（导航 hit 已包含在内，label 就是 control() 给的那串）。
/// 禁止再拼 [navigationNodes]（重叠集合）。要少写点代码就用 [RhineSemanticsLayer.fromHits]。
///
/// 全部节点包在 IgnorePointer 里：Qt 的无障碍激活通路与指针通路是分开的
/// （Overlay.qml:196 vs :197-220），Flutter 侧也不能让语义层抢触摸。
///
/// text-field 节点默认不铺（EditableText 自己发布，见 [inputNodes]）；打开
/// [includeTextFieldNodes] 时按节点里的真实 value / focused 投影。
class RhineSemanticsLayer extends StatelessWidget {
  const RhineSemanticsLayer({
    super.key,
    required this.child,
    required this.nodes,
    this.onActivate,
    this.includeTextFieldNodes = false,
  });

  /// 直接用命中层与命中列表构造：nodes = hitNodes(layer, hits)。
  ///
  /// 语义矩形因此与那一次 frame 的命中矩形同源，构造上也不可能误把导航节点重复铺一遍。
  RhineSemanticsLayer.fromHits({
    super.key,
    required this.child,
    required HitLayer layer,
    required List<HudHit> hits,
    this.onActivate,
    this.includeTextFieldNodes = false,
  }) : nodes = hitNodes(layer, hits);

  /// 底层画面（舞台 + TextInputOverlay）。
  final Widget child;

  /// 语义节点，顺序即遍历顺序（与 hits 顺序一致）。
  final List<HudSemanticsNode> nodes;

  /// 无障碍激活。Qt 里 hit 的 onPressAction 是 rhine.action(modelData.action)，
  /// 宿主一般实现为 ports.action(node.action)。
  final void Function(HudSemanticsNode node)? onActivate;

  /// 是否把 text-field 角色的节点也铺出来。默认 false：那部分由 EditableText 自己发布，
  /// 叠一层会重复；只有宿主接管输入框时才打开。
  final bool includeTextFieldNodes;

  @override
  Widget build(BuildContext context) {
    final List<Widget> layers = <Widget>[child];
    for (final HudSemanticsNode node in nodes) {
      if (!includeTextFieldNodes && node.isTextField) {
        continue;
      }
      // 负尺寸只能是坏 wire 数据：Qt 的命中矩形来自布局（长宽恒 >= 0），而 Positioned 的
      // 紧约束会直接断言失败。这里只挡这一种不可能值，不改动任何合法节点（含 0 尺寸）。
      if (node.rect.width < 0 || node.rect.height < 0) {
        continue;
      }
      layers.add(
        Positioned.fromRect(
          rect: node.rect,
          child: IgnorePointer(
            child: Semantics(
              container: true,
              // 诊断用稳定标识（不朗读、不影响 role/name）：测试可按 id 断言节点身份，
              // Qt 侧没有对应声明。
              identifier: node.id,
              label: node.label,
              enabled: node.enabled,
              // Qt 的 Button 身份：Semantics(button: true)。dart:ui 的 SemanticsRole 没有
              // button 成员，所以这里不用 role 参数。
              button: node.isButton,
              textField: node.isTextField,
              value: node.isTextField ? node.value : null,
              focused: node.isTextField ? node.focused : null,
              // 失能按钮不给 onTap：Qt 里失能的 Button 不会触发 onPressAction
              // （Overlay.qml:426 的 if (enabled) 守卫）。文本输入框没有
              // Accessible.onPressAction，激活它是输入法/焦点通路的事，这里也不给 onTap。
              onTap: node.isButton && node.enabled && onActivate != null
                  ? () => onActivate!(node)
                  : null,
            ),
          ),
        ),
      );
    }
    return Stack(fit: StackFit.expand, children: layers);
  }
}

/// Android 无障碍桥开关策略（Qt/src/AndroidWindow.cpp:62-71）。
///
/// Qt 在 Android 上默认关掉整座桥：configureAndroidAccessibility() 在
/// RHINE_ANDROID_ACCESSIBILITY != 1 时 installUpdateHandler(swallowAccessibilityUpdate) +
/// QAccessible::setActive(false)（原因见 AndroidWindow.h:11-21：QtAccessibilityDelegate 用
/// BlockingQueuedConnection 递归遍历，滑动时把主线程打满导致 Input dispatching timed out /
/// ANR）。[forceEnv] 对应 RHINE_ANDROID_ACCESSIBILITY=1 的保留原行为路径，非 Android 恒开。
///
/// 只表达「策略上是否该暴露语义」：Flutter 没有 QAccessible::setActive(false) 的等价运行时
/// 开关，SemanticsBinding 会自行桥接语义树，真正等价关闭要在引擎层屏蔽语义树，超出这里范围
/// （TBD，不臆造实现，也不据此在本层偷偷隐藏节点）。
class AndroidAccessibilityBridge {
  const AndroidAccessibilityBridge._();

  static bool enabled({required bool android, required bool forceEnv}) =>
      !android || forceEnv;
}
