/// T32-80-W4：无障碍语义层（lib/hud/a11y/semantics_layer.dart）的静态断言集。
///
/// 本文件按任务禁令**只写不跑**：没有执行过 flutter test / dart test / analyze，
/// 因此下列断言既没有 RED 记录也没有 GREEN 记录，全部记为「未执行」。
///
/// ## 跨树集成依赖（预期未解析，不是缺陷）
/// semantics_layer.dart 依赖 lib/hud/protocol/hud_hit.dart（HudHit，唯一真相在 T30 树
/// dev-hud-protocol 分支）与同一 generation 的 hud_frame.dart。本树按计划尚未集成，
/// 故本文件的 HudHit 相关 import 在本树**预期不可解析**，与 lib/hud/input/hit_layer.dart:39
/// 的现状一致；最终由 T30 分支合并提供。禁止在本树复制一份 hud_hit.dart 造成平行模型。
///
/// ## 断言与 Qt 原文的一一对应
/// - 187-196 hits delegate：Accessible.role/name/onPressAction + area/offset
/// - 38、40-43 命中外扩 pad = android ? 16 : 0（Qt.rect 同算法）
/// - NativeHud.cpp:102-109 hit()：label.isNull() ? action : label（空串保留）
/// - NativeHud.cpp:121-124 control()：导航也是 hit，文案取 label
/// - NativeHud.cpp:348-355 导航四行文案（含「音乐检索  /」的两个空格）
/// - Overlay.qml:398、458、539、590 四个输入框的 Accessible.name
/// - Overlay.qml:423-429、476-478 两个表单按钮的 role/name/onPressAction
/// - AndroidWindow.cpp:62-71 Android 默认关桥
library;


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/a11y/semantics_layer.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/input/text_input_overlay.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 只记录副作用，不改任何状态（与 ime_test.dart 同构）。
class RecordingPorts implements TextInputPorts {
  final List<String> calls = <String>[];

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
  expect(actual.left, closeTo(expected.left, 1e-9));
  expect(actual.top, closeTo(expected.top, 1e-9));
  expect(actual.width, closeTo(expected.width, 1e-9));
  expect(actual.height, closeTo(expected.height, 1e-9));
}

void main() {
  final RecordingPorts ports = RecordingPorts();
  final TextInputOverlayLogic logic = TextInputOverlayLogic(ports: ports);

  HitLayer stageLayer({bool android = true, String modal = '', double modalOffset = 0}) =>
      HitLayer(
        geometry: const StageGeometry(logicalWidth: 1080, logicalHeight: 1080),
        android: android,
        modal: modal,
        modalOffset: modalOffset,
      );

  /// NativeHud.cpp:348-355 的四个导航 control()，label 逐字（含 / 前的两个空格）。
  List<HudHit> navHits() => <HudHit>[
        const HudHit(
          x: 10,
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

  const TextInputStageState searchState = TextInputStageState(
    stageScale: 1,
    modal: 'search',
    inputX: 0,
    inputY: 0,
    inputWidth: 100,
  );

  // ---------------------------------------------------------------------------
  // hits：Accessible.role/name/onPressAction 的 1:1 投影
  // ---------------------------------------------------------------------------
  group('hits → button 节点（Overlay.qml:187-196）', () {
    test('每个 hit 一个节点：id 有序、role=button、label/action 逐字、顺序不变', () {
      final HitLayer layer = stageLayer();
      final List<HudHit> hits = navHits();
      final List<HudSemanticsNode> nodes = hitNodes(layer, hits);

      expect(nodes.length, hits.length);
      for (int i = 0; i < hits.length; i++) {
        expect(nodes[i].id, 'hit:$i');
        expect(nodes[i].role, SemanticsRole.button);
        expect(nodes[i].isButton, isTrue);
        expect(nodes[i].isTextField, isFalse);
        expect(nodes[i].label, hits[i].label);
        expect(nodes[i].action, hits[i].action);
        expect(nodes[i].command, isNull);
        expect(nodes[i].enabled, isTrue);
      }
      // Qt 的 Repeater 顺序 = 语义树顺序：id 递增即已覆盖，且本层不设 sortKey。
      expect(
        nodes.map((HudSemanticsNode n) => n.id).toList(),
        <String>['hit:0', 'hit:1', 'hit:2', 'hit:3'],
      );
    });

    test('rect 与命中矩形同源：rectToLogical(effectiveRect(hit))，不在这里重算 pad/offset', () {
      final HitLayer layer = HitLayer(
        geometry: const StageGeometry(logicalWidth: 1080, logicalHeight: 1080),
        android: true,
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
      for (int i = 0; i < hits.length; i++) {
        expectRect(nodes[i].rect, layer.geometry.rectToLogical(layer.effectiveRect(hits[i])));
      }
      // Android pad 16 + 非 fixed 的 modalOffset 40（Overlay.qml:190-192、40-43）。
      expect(nodes[0].rect.top, closeTo(100 - 16 + 40, 1e-9));
      expect(nodes[1].rect.top, closeTo(100 - 16, 1e-9));
    });

    test('触摸外扩只消费侧：非 Android 的 pad 恒为 0（Overlay.qml:38）', () {
      final List<HudHit> hits = <HudHit>[
        const HudHit(x: 10, y: 20, width: 100, height: 50, action: 'a', label: 'a'),
      ];
      final List<HudSemanticsNode> off = hitNodes(stageLayer(android: false), hits);
      expectRect(off.single.rect, const Rect.fromLTWH(10, 20, 100, 50));
      final List<HudSemanticsNode> on = hitNodes(stageLayer(), hits);
      expectRect(on.single.rect, const Rect.fromLTWH(-6, 4, 132, 82));
    });

    test('空 label 原样保留，绝不回落 action（NativeHud.cpp:108）', () {
      final List<HudSemanticsNode> nodes = hitNodes(stageLayer(), <HudHit>[
        const HudHit(x: 0, y: 0, width: 10, height: 10, action: 'player:toggle', label: ''),
      ]);
      expect(nodes.single.label, isEmpty);
      expect(nodes.single.label, isNot('player:toggle'));
      expect(nodes.single.action, 'player:toggle');
    });

    test('语义层不做播放条屏蔽过滤：Qt 的 Accessible 不区分指针屏蔽', () {
      // playerBar 覆盖该命中：指针被屏蔽（hit_layer.dart isShielded），但 Qt 的
      // Accessible 节点依然存在且可被读屏激活，故语义节点数量不变。
      final HitLayer layer = HitLayer(
        geometry: const StageGeometry(logicalWidth: 1080, logicalHeight: 1080),
        android: false,
        playerBounds: const Rect.fromLTWH(0, 1000, 1080, 80),
      );
      final List<HudHit> hits = <HudHit>[
        const HudHit(x: 0, y: 1000, width: 200, height: 60, action: 'x', label: 'x'),
      ];
      // 逻辑坐标 == 舞台坐标（logicalHeight 1080 => stageScale 1）；该点同时落在命中与播放条上。
      expect(layer.isShieldedLogical(const Offset(100, 1030)), isTrue);
      expect(hitNodes(layer, hits).length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // 顶部导航：hits 的子集视图
  // ---------------------------------------------------------------------------
  group('顶部导航节点就是 hits 的子集（NativeHud.cpp:121-124、348-355）', () {
    test('label/action/id 逐字，且不是第二套文案', () {
      final List<HudHit> hits = navHits();
      final List<HudSemanticsNode> nav = navigationNodes(stageLayer(), hits);
      expect(nav.map((HudSemanticsNode n) => n.label).toList(), <String>[
        '发现音乐 ↗',
        '音乐检索  /',
        '本地曲库',
        '设置',
      ]);
      expect(nav.map((HudSemanticsNode n) => n.action).toList(), NavigationAction.all);
      expect(nav.map((HudSemanticsNode n) => n.id).toList(), <String>[
        'nav:discover',
        'nav:search',
        'nav:saved',
        'nav:settings',
      ]);
      expect(nav.every((HudSemanticsNode n) => n.isButton), isTrue);
      // 导航节点只能来自 hit：不得带表单命令，也不是另写的一套文案对象。
      expect(nav.every((HudSemanticsNode n) => n.command == null), isTrue);
      expect(NavigationAction.isNavigation('discover'), isTrue);
      expect(NavigationAction.isNavigation('player:toggle'), isFalse);

      // 子集：同一批 hit 用 hitNodes 得到的是全量，二者不得相加（Qt 每个 delegate
      // 只有一个 Accessible）。
      final List<HudSemanticsNode> all = hitNodes(stageLayer(), hits);
      expect(all.length, hits.length);
      expect(nav.length, hits.length);
      expect(
        nav.every((HudSemanticsNode n) => all.any((HudSemanticsNode a) => a.action == n.action)),
        isTrue,
      );
    });

    test('非导航 action（music:result:N / music:expand:N / 播放器）不进入导航视图', () {
      final List<HudSemanticsNode> nav = navigationNodes(stageLayer(), <HudHit>[
        const HudHit(x: 0, y: 0, width: 1, height: 1, action: 'music:result:3', label: '晴天'),
        const HudHit(x: 0, y: 0, width: 1, height: 1, action: 'music:expand:3', label: '展开'),
        const HudHit(x: 0, y: 0, width: 1, height: 1, action: 'player:toggle', label: '播放'),
      ]);
      expect(nav, isEmpty);
      // 但它们在全量视图里一个都不能少。
      expect(
        hitNodes(stageLayer(), <HudHit>[
          const HudHit(x: 0, y: 0, width: 1, height: 1, action: 'music:result:3', label: '晴天'),
          const HudHit(x: 0, y: 0, width: 1, height: 1, action: 'music:expand:3', label: '展开'),
          const HudHit(x: 0, y: 0, width: 1, height: 1, action: 'player:toggle', label: '播放'),
        ]).length,
        3,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 输入框与表单按钮
  // ---------------------------------------------------------------------------
  group('输入框节点：值/选区/预编辑/焦点只搬真实 TextEditingValue', () {
    test('search：label 与 Accessible.name 同串、rect 与 layout 同源', () {
      final List<HudSemanticsNode> nodes =
          inputNodes(logic, searchState, accountLength: 0);
      expect(nodes.length, 1);
      expect(nodes.single.id, 'input:musicSearchInput');
      expect(nodes.single.role, SemanticsRole.textField);
      expect(nodes.single.isTextField, isTrue);
      expect(nodes.single.isButton, isFalse);
      expect(nodes.single.label, '搜索歌曲、歌手、专辑或歌单');
      expect(nodes.single.enabled, isTrue);
      // 检索框未声明 maximumLength，产品层按 Qt 默认 32767 显式对齐
      // （text_input_overlay.dart:519-522，ime_test.dart:311 同值）。
      expect(nodes.single.maxLength, 32767);
      expectRect(nodes.single.rect, logic.layout(TextFieldKind.search, searchState).rect);
    });

    test('传 values/focused 时逐字透传 text/selection/composing/focused', () {
      const TextEditingValue value = TextEditingValue(
        text: '周杰伦',
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
        composing: TextRange(start: 1, end: 2),
      );
      final List<HudSemanticsNode> nodes = inputNodes(
        logic,
        searchState,
        accountLength: 0,
        values: const <TextFieldKind, TextEditingValue>{
          TextFieldKind.search: value,
        },
        focused: TextFieldKind.search,
      );
      final HudSemanticsNode node = nodes.single;
      expect(node.value, '周杰伦');
      expect(node.selection, const TextSelection(baseOffset: 1, extentOffset: 3));
      expect(node.composing, const TextRange(start: 1, end: 2));
      expect(node.focused, isTrue);
    });

    test('不传 values/focused 时保持 null/false（不造默认值、不按 placeholder 填充）', () {
      final List<HudSemanticsNode> nodes =
          inputNodes(logic, searchState, accountLength: 0);
      expect(nodes.single.value, isNull);
      expect(nodes.single.selection, isNull);
      expect(nodes.single.composing, isNull);
      expect(nodes.single.focused, isFalse);
    });

    test('login：字段顺序、按钮 command 与逐字 Accessible.name（Overlay.qml:398、424、458、477）', () {
      const TextInputStageState state = TextInputStageState(
        stageScale: 1,
        modal: 'login',
        loginMethod: 'phone',
        inputX: 0,
        inputWidth: 100,
      );
      final List<HudSemanticsNode> nodes = inputNodes(logic, state, accountLength: 11);
      expect(nodes.map((HudSemanticsNode n) => n.id).toList(), <String>[
        'input:accountField',
        'input:captchaField',
        'form:send-code',
        'form:submit',
      ]);
      expect(nodes[0].label, '手机号码');
      expect(nodes[1].label, '短信验证码');
      expect(nodes[2].label, '发送短信验证码');
      expect(nodes[2].label, isNot('发送验证码'));
      expect(nodes[2].command, SemanticsCommand.sendCode);
      expect(nodes[2].isButton, isTrue);
      expect(nodes[2].enabled, isTrue);
      expect(nodes[3].label, '提交表单');
      expect(nodes[3].label, isNot('登录 →'));
      expect(nodes[3].command, SemanticsCommand.submit);
    });

    test('账号不足 11 位时发送按钮语义失能（Overlay.qml:414-429）', () {
      const TextInputStageState state = TextInputStageState(
        stageScale: 1,
        modal: 'login',
        loginMethod: 'phone',
        inputX: 0,
        inputWidth: 100,
      );
      final List<HudSemanticsNode> nodes = inputNodes(logic, state, accountLength: 3);
      final HudSemanticsNode send =
          nodes.firstWhere((HudSemanticsNode n) => n.id == 'form:send-code');
      expect(send.enabled, isFalse);
      expect(send.label, '发送短信验证码');
    });
  });

  // ---------------------------------------------------------------------------
  // 语义树挂载
  // ---------------------------------------------------------------------------
  group('RhineSemanticsLayer：从 hits 构造，不铺重复节点', () {
    test('fromHits 的 nodes 与 hitNodes 完全一致（构造上禁止叠加导航视图）', () {
      final HitLayer layer = stageLayer();
      final List<HudHit> hits = navHits();
      final RhineSemanticsLayer widget = RhineSemanticsLayer.fromHits(
        layer: layer,
        hits: hits,
        child: const SizedBox.expand(),
      );
      final List<HudSemanticsNode> expected = hitNodes(layer, hits);
      expect(widget.nodes.length, expected.length);
      for (int i = 0; i < expected.length; i++) {
        expect(widget.nodes[i].id, expected[i].id);
        expect(widget.nodes[i].label, expected[i].label);
        expect(widget.nodes[i].action, expected[i].action);
        expectRect(widget.nodes[i].rect, expected[i].rect);
      }
      expect(widget.includeTextFieldNodes, isFalse);
      expect(widget.onActivate, isNull);
    });

    test('text-field 节点默认不参与铺树（EditableText 自己发布）', () {
      final HudSemanticsNode field = inputNodes(logic, searchState, accountLength: 0).single;
      expect(field.isTextField, isTrue);
      final RhineSemanticsLayer widget = RhineSemanticsLayer(
        nodes: <HudSemanticsNode>[field],
        child: const SizedBox.expand(),
      );
      expect(widget.includeTextFieldNodes, isFalse);
    });
  });

  group('语义树 widget（只断言 finder 可定位，不遍历内部结构）', () {
    testWidgets('每个 hit 一个带 identifier 的节点，label 可被 bySemanticsLabel 命中', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);
      final List<HudHit> hits = navHits();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RhineSemanticsLayer.fromHits(
            layer: stageLayer(),
            hits: hits,
            child: const SizedBox.expand(),
          ),
        ),
      );
      for (int i = 0; i < hits.length; i++) {
        expect(find.bySemanticsIdentifier('hit:$i'), findsOneWidget);
      }
      expect(find.bySemanticsLabel('发现音乐 ↗'), findsOneWidget);
      expect(find.bySemanticsLabel('音乐检索  /'), findsOneWidget);
    });

    testWidgets('语义层不抢触摸：点击命中矩形不会触发 onActivate', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);
      final List<HudSemanticsNode> activated = <HudSemanticsNode>[];
      final HudHit hit =
          const HudHit(x: 100, y: 100, width: 200, height: 54, action: 'discover', label: '发现音乐 ↗');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RhineSemanticsLayer.fromHits(
            layer: stageLayer(android: false),
            hits: <HudHit>[hit],
            onActivate: activated.add,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.tapAt(const Offset(200, 127));
      await tester.pump();
      expect(activated, isEmpty);
    });

    testWidgets('includeTextFieldNodes 打开后才铺 text-field 节点', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);
      final HudSemanticsNode field = inputNodes(logic, searchState, accountLength: 0).single;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RhineSemanticsLayer(
            nodes: <HudSemanticsNode>[field],
            child: const SizedBox.expand(),
          ),
        ),
      );
      expect(find.bySemanticsIdentifier('input:musicSearchInput'), findsNothing);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RhineSemanticsLayer(
            nodes: <HudSemanticsNode>[field],
            includeTextFieldNodes: true,
            child: const SizedBox.expand(),
          ),
        ),
      );
      expect(find.bySemanticsIdentifier('input:musicSearchInput'), findsOneWidget);
      expect(find.bySemanticsLabel('搜索歌曲、歌手、专辑或歌单'), findsOneWidget);
    });
  });

  group('Android 无障碍桥默认关闭（AndroidWindow.cpp:62-71）', () {
    test('android 且未设 RHINE_ANDROID_ACCESSIBILITY=1 时策略为关', () {
      expect(AndroidAccessibilityBridge.enabled(android: true, forceEnv: false), isFalse);
      expect(AndroidAccessibilityBridge.enabled(android: true, forceEnv: true), isTrue);
      expect(AndroidAccessibilityBridge.enabled(android: false, forceEnv: false), isTrue);
      expect(AndroidAccessibilityBridge.enabled(android: false, forceEnv: true), isTrue);
    });
  });
}
