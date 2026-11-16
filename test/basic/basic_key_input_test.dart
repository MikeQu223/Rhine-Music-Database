// HUD 键盘入口（Overlay.qml:118-120 → Engine.cpp:952-1012 → NativeHudController.cpp:887-943）。
//
// 被测生产代码：
//   * lib/basic/basic_app.dart 的 Focus.onKeyEvent → HudKeyRouter → _onAction 接线；
//   * 同文件的 basicHudKeyValue（Engine.cpp:974-995 的键名翻译）。
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

void main() {
  group('basicHudKeyValue（Engine.cpp:974-995）', () {
    test('方向键 / Enter / Escape / Tab / 空格被翻译成 Qt 的 value 字符串', () {
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.arrowLeft)), KeySymbol.arrowLeft);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.arrowRight)), KeySymbol.arrowRight);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.arrowUp)), KeySymbol.arrowUp);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.arrowDown)), KeySymbol.arrowDown);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.enter)), KeySymbol.enter);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.numpadEnter)), KeySymbol.enter);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.escape)), KeySymbol.escape);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.tab)), KeySymbol.tab);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.space)), KeySymbol.space);
    });

    test("'/' 只看 event.text（:999-1001），普通字符不成为动作", () {
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.slash, character: '/')), KeySymbol.slash);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.keyA, character: 'a')), isNull);
      expect(basicHudKeyValue(_down(LogicalKeyboardKey.keyB)), isNull);
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

    test('frame 为空时所有键都被吃掉但并不发动作', () {
      final _RecordingPorts ports = _RecordingPorts();
      final HudKeyRouter router = HudKeyRouter(ports: ports);
      final HudKeyOutcome outcome =
          router.key(_snapshot(empty: true), HudScrollOffsets(), value: KeySymbol.enter, command: false);
      expect(outcome.consumed, isFalse);
      expect(ports.actions, isEmpty);
    });
  });
}
