// HUD 键盘入口（Overlay.qml:118-120 → Engine.cpp:952-1012 → NativeHudController.cpp:887-943）。
//
// 被测生产代码：
//   * lib/basic/basic_app.dart 的 Focus.onKeyEvent → EngineKeyRouter → HudKeyRouter
//     → _onAction 接线；
//   * 同文件的 basicHudKeyEvent / basicHudKeySymbol（桥接层：Flutter 键 → Qt 的
//     (key, modifiers, text) 三元组，Engine.cpp:952-1012 的判定顺序交给
//     EngineKeyRouter，翻译表只有一份真值）。
//
// 这层在 161 之前**不存在**：HUD 根只有 Focus 节点、没有 onKeyEvent，用户看得到
// 「←→ 切换来源 / ↑↓ 选曲 / ENTER 查看 / 检索」却按不出动作。本文件钉住翻译表与
// 路由落点，设备侧的按键收据由 FINAL-CLOSURE-161.json 记录。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/hud/input/key_router.dart';
import 'package:rhine_music_database/hud/input/wheel_router.dart';

KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

class _RecordingPorts implements HudKeyPorts {
  final List<String> actions = <String>[];
  final List<String> viewer = <String>[];
  int plays = 0;
  int toggles = 0;

  @override
  void action(String action) => actions.add(action);

  @override
  void play() => plays += 1;

  @override
  void togglePlayer() => toggles += 1;

  @override
  void viewerKey(String value) => viewer.add(value);
}

HudKeySnapshot _snapshot({String modal = '', bool empty = false}) => HudKeySnapshot(
      frameEmpty: empty,
      modal: modal,
      closing: false,
      viewer: false,
      settingsContentBottom: 0,
      desktopLyricsContentBottom: 0,
    );

/// EngineKeyRouter 的端口桥：key(...) 直接交给受测的 HudKeyRouter。
class _EnginePorts implements EngineKeyPorts {
  _EnginePorts(this.ports, {this.snapshot = const HudKeySnapshot()});

  final HudKeySnapshot snapshot;

  final _RecordingPorts ports;
  final HudKeyRouter _router = HudKeyRouter(ports: _NullHudPorts());
  final HudScrollOffsets _offsets = HudScrollOffsets();

  @override
  void action(String action) => ports.action(action);

  @override
  void key(String value, bool command) {
    // 用同一份端口记录 HUD 动作，保证断言看的是产品路径的输出。
    HudKeyRouter(ports: ports).key(_snapshotForEngine(), _offsets, value: value, command: command);
  }

  @override
  void query(String text) {}

  HudKeySnapshot _snapshotForEngine() => snapshot;
}

class _NullHudPorts implements HudKeyPorts {
  @override
  void action(String action) {}

  @override
  void play() {}

  @override
  void togglePlayer() {}

  @override
  void viewerKey(String value) {}
}

void main() {
  group('basicHudKeySymbol（Engine.cpp:963-995 的翻译输入）', () {
    test('方向键 / Enter / Escape / Tab / 空格 / 五个媒体键都有 Qt 语义名', () {
      expect(basicHudKeySymbol(LogicalKeyboardKey.arrowLeft), KeySymbol.arrowLeft);
      expect(basicHudKeySymbol(LogicalKeyboardKey.arrowRight), KeySymbol.arrowRight);
      expect(basicHudKeySymbol(LogicalKeyboardKey.arrowUp), KeySymbol.arrowUp);
      expect(basicHudKeySymbol(LogicalKeyboardKey.arrowDown), KeySymbol.arrowDown);
      expect(basicHudKeySymbol(LogicalKeyboardKey.enter), KeySymbol.enter);
      expect(basicHudKeySymbol(LogicalKeyboardKey.numpadEnter), KeySymbol.enter);
      expect(basicHudKeySymbol(LogicalKeyboardKey.escape), KeySymbol.escape);
      expect(basicHudKeySymbol(LogicalKeyboardKey.tab), KeySymbol.tab);
      expect(basicHudKeySymbol(LogicalKeyboardKey.space), KeySymbol.space);
      expect(basicHudKeySymbol(LogicalKeyboardKey.mediaPlayPause), KeySymbol.mediaTogglePlayPause);
      expect(basicHudKeySymbol(LogicalKeyboardKey.mediaPlay), KeySymbol.mediaPlay);
      expect(basicHudKeySymbol(LogicalKeyboardKey.mediaPause), KeySymbol.mediaPause);
      expect(basicHudKeySymbol(LogicalKeyboardKey.mediaTrackNext), KeySymbol.mediaNext);
      expect(basicHudKeySymbol(LogicalKeyboardKey.mediaTrackPrevious), KeySymbol.mediaPrevious);
    });

    test("普通键没有语义名，文字走 event.text（'/' 与 'a' 都在这里）", () {
      expect(basicHudKeySymbol(LogicalKeyboardKey.slash), isNull);
      expect(basicHudKeySymbol(LogicalKeyboardKey.keyA), isNull);
      final HudKeyEvent slash = basicHudKeyEvent(_down(LogicalKeyboardKey.slash, character: '/'));
      expect(slash.symbol, isEmpty);
      expect(slash.text, '/');
      final HudKeyEvent a = basicHudKeyEvent(_down(LogicalKeyboardKey.keyA, character: 'a'));
      expect(a.text, 'a');
      final HudKeyEvent space = basicHudKeyEvent(_down(LogicalKeyboardKey.space));
      expect(space.text, KeySymbol.space);
      final HudKeyEvent cmd = basicHudKeyEvent(
        _down(LogicalKeyboardKey.enter),
        command: true,
      );
      expect(cmd.symbol, KeySymbol.enter);
      expect(cmd.command, isTrue);
    });
  });

  group('EngineKeyRouter（Engine.cpp:952-1012）→ HudKeyRouter（:887-943）', () {
    test('媒体键直接发播放器动作，且 accepted=true', () {
      final _RecordingPorts ports = _RecordingPorts();
      final EngineKeyOutcome outcome = EngineKeyRouter(ports: _EnginePorts(ports)).keyEvent(
        basicHudKeyEvent(_down(LogicalKeyboardKey.mediaPlayPause)),
      );
      expect(outcome.accepted, isTrue);
      expect(ports.actions, <String>[HudAction.playerToggle]);
    });

    test("非翻译键只要有 text 就 accepted=true 并交给 hud.key（'/' → 检索）", () {
      final _RecordingPorts ports = _RecordingPorts();
      final EngineKeyOutcome outcome = EngineKeyRouter(ports: _EnginePorts(ports)).keyEvent(
        basicHudKeyEvent(_down(LogicalKeyboardKey.slash, character: '/')),
      );
      expect(outcome.accepted, isTrue);
      expect(ports.actions, <String>[HudAction.search]);
    });

    test('没有 text 也没有语义名的键不被接受（Engine.cpp:999-1001）', () {
      final _RecordingPorts ports = _RecordingPorts();
      final EngineKeyOutcome outcome = EngineKeyRouter(ports: _EnginePorts(ports))
          .keyEvent(basicHudKeyEvent(_down(LogicalKeyboardKey.keyB)));
      expect(outcome.accepted, isFalse);
      expect(ports.actions, isEmpty);
    });
  });

  group('键 → NativeHud::key 动作表（:930-942）', () {
    test('Enter 发出 open，方向键发出列切换与选曲，/ 发出检索', () {
      final _RecordingPorts ports = _RecordingPorts();
      final HudKeyRouter router = HudKeyRouter(ports: ports);
      final HudScrollOffsets offsets = HudScrollOffsets();

      expect(router.key(_snapshot(), offsets, value: KeySymbol.enter, command: false).consumed, isTrue);
      expect(router.key(_snapshot(), offsets, value: KeySymbol.arrowDown, command: false).consumed, isTrue);
      expect(router.key(_snapshot(), offsets, value: KeySymbol.arrowUp, command: false).consumed, isTrue);
      expect(router.key(_snapshot(), offsets, value: KeySymbol.arrowRight, command: false).consumed, isTrue);
      expect(router.key(_snapshot(), offsets, value: KeySymbol.arrowLeft, command: false).consumed, isTrue);
      expect(router.key(_snapshot(), offsets, value: KeySymbol.slash, command: false).consumed, isTrue);

      expect(ports.actions, <String>[
        HudAction.open,
        HudAction.next,
        HudAction.prev,
        HudAction.columnNext,
        HudAction.columnPrev,
        HudAction.search,
      ]);
    });

    test('Escape 三级：无弹层 → back；有弹层 → close-modal；命令键 Enter 播放', () {
      final _RecordingPorts ports = _RecordingPorts();
      final HudKeyRouter router = HudKeyRouter(ports: ports);
      final HudScrollOffsets offsets = HudScrollOffsets();

      router.key(_snapshot(), offsets, value: KeySymbol.escape, command: false);
      router.key(_snapshot(modal: 'search'), offsets, value: KeySymbol.escape, command: false);
      router.key(_snapshot(), offsets, value: KeySymbol.enter, command: true);
      router.key(_snapshot(), offsets, value: KeySymbol.space, command: false);

      expect(ports.actions, <String>[HudAction.back, HudAction.closeModal]);
      expect(ports.plays, 1);
      expect(ports.toggles, 1);
    });

    test('frame 为空时 HUD 不动作；Engine 仍按 text 非空返回 accepted（两条语义分开）', () {
      final _RecordingPorts ports = _RecordingPorts();
      final HudKeyRouter router = HudKeyRouter(ports: ports);
      final HudKeyOutcome outcome = router.key(
        _snapshot(empty: true),
        HudScrollOffsets(),
        value: KeySymbol.enter,
        command: false,
      );
      // HUD 层：这是 consumed=false（NativeHudController.cpp:888-890 直接返回）。
      expect(outcome.consumed, isFalse);
      expect(ports.actions, isEmpty);
      // Engine 层：Enter 被翻译成非空 text，Engine.cpp:1296-1301 恒 true。
      final EngineKeyOutcome engine =
          EngineKeyRouter(ports: _EnginePorts(ports, snapshot: _snapshot(empty: true)))
              .keyEvent(basicHudKeyEvent(_down(LogicalKeyboardKey.enter)));
      expect(engine.accepted, isTrue);
      expect(ports.actions, isEmpty);
    });

    test('设置弹层上下键把真实偏移写进 offsets 并按 contentBottom clamp', () {
      final _RecordingPorts ports = _RecordingPorts();
      final HudKeyRouter router = HudKeyRouter(ports: ports);
      final HudScrollOffsets offsets = HudScrollOffsets();
      // 与生产同算法：contentBottom = viewportTop(176) + maxScroll(500) + 视口(660)，
      // 于是 contentHeight = maxScroll + 660、上界正好 500。
      final HudKeySnapshot settings = HudKeySnapshot(
        modal: 'settings',
        closing: false,
        viewer: false,
        settingsContentBottom: HudWheelConstants.settingsViewportTop +
            500 +
            (HudWheelConstants.settingsViewportBottom - HudWheelConstants.settingsViewportTop),
      );
      for (int i = 0; i < 10; i++) {
        router.key(settings, offsets, value: KeySymbol.arrowDown, command: false);
      }
      expect(offsets.settingsScroll, 500);
      expect(ports.actions, isEmpty);
      router.key(settings, offsets, value: KeySymbol.arrowUp, command: false);
      expect(offsets.settingsScroll, 500 - HudWheelConstants.settingsStepPixels);
    });
  });
}
