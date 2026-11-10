/// key_router 的分支级测试：逐条对齐 Qt/src/Engine.cpp:952-1012、
/// Qt/src/NativeHudController.cpp:887-943、Qt/qml/Overlay.qml:50-62/158-178。
///
/// 只写不跑：本轮禁止执行 flutter/dart test、analyze、build。另外本树缺
/// lib/hud/protocol/hud_hit.dart（T30 跨树缺口），key_router 经 wheel_router →
/// hit_layer 传递依赖它，因此本文件在本树预期不可解析——与 test/hud/hit_layer_test.dart
/// 头注释属同一类已声明缺口，不是本模块的缺陷。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/input/key_router.dart';
import 'package:rhine_music_database/hud/input/wheel_router.dart'
    show HudScrollOffsets;

/// Engine 端口的记录器（Engine.cpp:966 / :1003 / :1010 三个调用点）。
class _EngineRec implements EngineKeyPorts {
  final List<String> calls = <String>[];

  @override
  void action(String action) => calls.add('action:' + action);

  @override
  void key(String value, bool command) =>
      calls.add('key:' + value + ':' + command.toString());

  @override
  void query(String text) => calls.add('query:' + text);
}

/// NativeHud 端口的记录器（:906 / :910 / :915-919 / :931）。
class _HudRec implements HudKeyPorts {
  final List<String> calls = <String>[];

  @override
  void play() => calls.add('play');

  @override
  void viewerKey(String value) => calls.add('viewerKey:' + value);

  @override
  void action(String action) => calls.add('action:' + action);

  @override
  void togglePlayer() => calls.add('togglePlayer');
}

/// 快捷键端口的记录器（Overlay.qml:167 / :172 / :177）。
class _ShortcutRec implements ShortcutPorts {
  final List<String> calls = <String>[];

  @override
  void quit() => calls.add('quit');

  @override
  void toggleFullscreen() => calls.add('fullscreen');

  @override
  void toggleProfiler() => calls.add('profiler');
}

/// 字段层端口的记录器：answer 模拟 text_input_overlay 的返回值（event.accepted）。
class _FieldRec implements FieldKeySink {
  _FieldRec({this.answer = true});

  final bool answer;
  final List<String> calls = <String>[];

  @override
  bool fieldKey(KeyFocusTarget target, HudKeyEvent event) {
    calls.add(target.layer + '|' + target.field + '|' + event.symbol);
    return answer;
  }
}

void main() {
  group('KeySymbol / KeyCodec —— Engine.cpp:963-995', () {
    test('7 个被翻译的键名与 translated 集合一致', () {
      expect(KeySymbol.arrowLeft, 'ArrowLeft');
      expect(KeySymbol.arrowRight, 'ArrowRight');
      expect(KeySymbol.arrowUp, 'ArrowUp');
      expect(KeySymbol.arrowDown, 'ArrowDown');
      expect(KeySymbol.enter, 'Enter');
      expect(KeySymbol.escape, 'Escape');
      expect(KeySymbol.tab, 'Tab');
      expect(KeySymbol.translated.length, 7);
      expect(
        KeySymbol.translated,
        containsAll(<String>[
          'ArrowLeft',
          'ArrowRight',
          'ArrowUp',
          'ArrowDown',
          'Enter',
          'Escape',
          'Tab',
        ]),
      );
    });

    test('空格与斜杠来自 text()，不是翻译结果', () {
      expect(KeySymbol.space, ' ');
      expect(KeySymbol.slash, '/');
      expect(KeySymbol.translated.contains(KeySymbol.space), isFalse);
      expect(KeySymbol.translated.contains(KeySymbol.slash), isFalse);
    });

    test('五个媒体键各不相同', () {
      final media = <String>{
        KeySymbol.mediaTogglePlayPause,
        KeySymbol.mediaPlay,
        KeySymbol.mediaPause,
        KeySymbol.mediaNext,
        KeySymbol.mediaPrevious,
      };
      expect(media.length, 5);
    });

    test('媒体键 → 动作：toggle 三键合一，next / prev 各自独立', () {
      expect(KeyCodec.mediaAction(KeySymbol.mediaTogglePlayPause),
          HudAction.playerToggle);
      expect(KeyCodec.mediaAction(KeySymbol.mediaPlay), HudAction.playerToggle);
      expect(KeyCodec.mediaAction(KeySymbol.mediaPause), HudAction.playerToggle);
      expect(KeyCodec.mediaAction(KeySymbol.mediaNext), HudAction.playerNext);
      expect(
          KeyCodec.mediaAction(KeySymbol.mediaPrevious), HudAction.playerPrev);
      expect(KeyCodec.mediaAction(KeySymbol.arrowLeft), isNull);
      expect(KeyCodec.mediaAction(''), isNull);
    });

    test('translatedName 只认 7 个翻译键', () {
      for (final symbol in KeySymbol.translated) {
        expect(KeyCodec.translatedName(symbol), symbol);
      }
      expect(KeyCodec.translatedName(KeySymbol.mediaNext), isNull);
      expect(KeyCodec.translatedName('j'), isNull);
      expect(KeyCodec.translatedName(''), isNull);
    });
  });

  group('HudAction 符号固定（text_input_overlay.dart:894 引用 closeModal）', () {
    test('十三个字面量不得改动', () {
      expect(HudAction.closeModal, 'close-modal');
      expect(HudAction.back, 'back');
      expect(HudAction.desktopLyricsBack, 'desktop-lyrics:back');
      expect(HudAction.archiveTabMode, 'archive:tab-mode');
      expect(HudAction.columnPrev, 'column-prev');
      expect(HudAction.columnNext, 'column-next');
      expect(HudAction.prev, 'prev');
      expect(HudAction.next, 'next');
      expect(HudAction.open, 'open');
      expect(HudAction.search, 'search');
      expect(HudAction.playerToggle, 'player:toggle');
      expect(HudAction.playerNext, 'player:next');
      expect(HudAction.playerPrev, 'player:prev');
    });
  });

  group('EngineKeyRouter.keyEvent —— Engine.cpp:961-1005', () {
    test('媒体键先于 text：text 非空也直接发动作且 accepted', () {
      final ports = _EngineRec();
      final outcome = EngineKeyRouter(ports: ports)
          .keyEvent(const HudKeyEvent(symbol: KeySymbol.mediaPlay, text: 'x'));
      expect(outcome.accepted, isTrue);
      expect(outcome.effects, <String>['player:toggle']);
      expect(ports.calls, <String>['action:player:toggle']);
    });

    test('媒体键 next / previous 分别走 player:next / player:prev', () {
      final ports = _EngineRec();
      EngineKeyRouter(ports: ports)
          .keyEvent(const HudKeyEvent(symbol: KeySymbol.mediaNext));
      EngineKeyRouter(ports: ports)
          .keyEvent(const HudKeyEvent(symbol: KeySymbol.mediaPrevious));
      expect(ports.calls, <String>['action:player:next', 'action:player:prev']);
    });

    test('翻译键覆盖 event.text（Qt 是赋值，不是取值回退）', () {
      final ports = _EngineRec();
      final outcome = EngineKeyRouter(ports: ports).keyEvent(
        const HudKeyEvent(symbol: KeySymbol.arrowDown, text: 'junk'),
      );
      expect(outcome.accepted, isTrue);
      expect(outcome.effects, <String>['key:ArrowDown']);
      expect(ports.calls, <String>['key:ArrowDown:false']);
    });

    test('Enter 语义名归一（Key_Return/Key_Enter 的合流在桥接层，本层只收到 Enter）', () {
      final ports = _EngineRec();
      EngineKeyRouter(ports: ports)
          .keyEvent(const HudKeyEvent(symbol: KeySymbol.enter, text: '\n'));
      expect(ports.calls, <String>['key:Enter:false']);
    });

    test('普通字符键用 text 原样下传（含空格与斜杠）', () {
      final ports = _EngineRec();
      final router = EngineKeyRouter(ports: ports);
      router.keyEvent(const HudKeyEvent(text: 'q'));
      router.keyEvent(const HudKeyEvent(text: ' '));
      router.keyEvent(const HudKeyEvent(text: '/'));
      expect(ports.calls, <String>['key:q:false', 'key: :false', 'key:/:false']);
    });

    test('command 位原样下传（Engine.cpp:1003）', () {
      final ports = _EngineRec();
      EngineKeyRouter(ports: ports)
          .keyEvent(const HudKeyEvent(symbol: KeySymbol.enter, command: true));
      expect(ports.calls, <String>['key:Enter:true']);
    });

    test('text 为空且不是媒体键 → accepted=false 且不调用端口（:999-1001）', () {
      final ports = _EngineRec();
      final outcome =
          EngineKeyRouter(ports: ports).keyEvent(const HudKeyEvent());
      expect(outcome.accepted, isFalse);
      expect(outcome.effects, isEmpty);
      expect(ports.calls, isEmpty);
    });

    test('媒体键即使 text 为空也认领；非媒体名 + 空 text → false', () {
      final media = _EngineRec();
      final mediaOutcome = EngineKeyRouter(ports: media)
          .keyEvent(const HudKeyEvent(symbol: KeySymbol.mediaNext));
      expect(mediaOutcome.accepted, isTrue);
      expect(media.calls, <String>['action:player:next']);
      final other = _EngineRec();
      final otherOutcome = EngineKeyRouter(ports: other)
          .keyEvent(const HudKeyEvent(symbol: 'F10'));
      expect(otherOutcome.accepted, isFalse);
      expect(other.calls, isEmpty);
    });
  });

  group('EngineKeyRouter.searchAccepted —— Engine.cpp:1006-1012', () {
    test('命令键 → key("Enter", true)（等价于播放）', () {
      final ports = _EngineRec();
      final effect = EngineKeyRouter(ports: ports)
          .searchAccepted('随便什么', control: true);
      expect(effect, 'key:Enter');
      expect(ports.calls, <String>['key:Enter:true']);
    });

    test('非命令键 → query(text)', () {
      final ports = _EngineRec();
      final effect =
          EngineKeyRouter(ports: ports).searchAccepted('hello', control: false);
      expect(effect, 'query');
      expect(ports.calls, <String>['query:hello']);
    });
  });

  group('HudKeyRouter —— NativeHudController.cpp:887-943', () {
    test('frame 为空是第一道门（:888-890）：不认领、不动偏移', () {
      final ports = _HudRec();
      final offsets = HudScrollOffsets();
      final outcome = HudKeyRouter(ports: ports).key(
        const HudKeySnapshot(frameEmpty: true),
        offsets,
        value: KeySymbol.arrowDown,
        command: false,
      );
      expect(outcome.consumed, isFalse);
      expect(outcome.region, 'none');
      expect(ports.calls, isEmpty);
      expect(offsets.settingsScroll, 0.0);
      expect(offsets.desktopLyricsScroll, 0.0);
    });

    test('settings：下键 +66，上键 −66，且就地吞掉', () {
      final ports = _HudRec();
      final offsets = HudScrollOffsets();
      final outcome = HudKeyRouter(ports: ports).key(
        const HudKeySnapshot(modal: 'settings'),
        offsets,
        value: KeySymbol.arrowDown,
        command: false,
      );
      expect(outcome.consumed, isTrue);
      expect(outcome.region, 'settings');
      expect(outcome.effects, <String>['settingsScroll']);
      expect(offsets.settingsScroll, 66.0);
      expect(ports.calls, isEmpty, reason: '滚动只改偏移，不经过 ports');
    });

    test('settings 滚动步长与上限（66 来自 NativeHudController.cpp:892；viewport 来自 NativeHud.h:115-127）', () {
      final offsets = HudScrollOffsets();
      final router = const HudKeyRouter(ports: _NoopHudPorts());
      const snapshot = HudKeySnapshot(modal: 'settings');
      router.key(snapshot, offsets, value: KeySymbol.arrowDown, command: false);
      expect(offsets.settingsScroll, 66.0);
      for (var i = 0; i < 19; i++) {
        router.key(snapshot, offsets,
            value: KeySymbol.arrowDown, command: false);
      }
      // contentHeight = 1600-176 = 1424，viewport = 836-176 = 660，上限 764。
      expect(offsets.settingsScroll, 764.0);
      router.key(snapshot, offsets, value: KeySymbol.arrowUp, command: false);
      expect(offsets.settingsScroll, 698.0);
    });

    test('settings 向上不会越过 0（clampOffset 下界）', () {
      final offsets = HudScrollOffsets();
      final router = const HudKeyRouter(ports: _NoopHudPorts());
      const snapshot = HudKeySnapshot(modal: 'settings');
      router.key(snapshot, offsets, value: KeySymbol.arrowUp, command: false);
      router.key(snapshot, offsets, value: KeySymbol.arrowUp, command: false);
      expect(offsets.settingsScroll, 0.0);
    });

    test('settings 的内容高度参与上限计算（自定义 1000 → 164）', () {
      final offsets = HudScrollOffsets();
      final router = const HudKeyRouter(ports: _NoopHudPorts());
      const snapshot =
          HudKeySnapshot(modal: 'settings', settingsContentBottom: 1000.0);
      for (var i = 0; i < 3; i++) {
        router.key(snapshot, offsets,
            value: KeySymbol.arrowDown, command: false);
      }
      // contentHeight = 1000-176 = 824，viewport = 660，上限 164。
      expect(offsets.settingsScroll, 164.0);
    });

    test('closing 时 settings 不滚动，落到弹层拦截（:923-925）', () {
      final ports = _HudRec();
      final offsets = HudScrollOffsets();
      final outcome = HudKeyRouter(ports: ports).key(
        const HudKeySnapshot(modal: 'settings', closing: true),
        offsets,
        value: KeySymbol.arrowDown,
        command: false,
      );
      expect(outcome.consumed, isTrue);
      expect(outcome.region, 'none');
      expect(outcome.effects, isEmpty);
      expect(offsets.settingsScroll, 0.0);
      expect(ports.calls, isEmpty);
    });

    test('desktop-lyrics 同形：+66、上限 780、region 标签', () {
      final offsets = HudScrollOffsets();
      final router = const HudKeyRouter(ports: _NoopHudPorts());
      const snapshot = HudKeySnapshot(modal: 'desktop-lyrics');
      final outcome = router.key(snapshot, offsets,
          value: KeySymbol.arrowDown, command: false);
      expect(outcome.region, 'desktop-lyrics');
      expect(outcome.effects, <String>['desktopLyricsScroll']);
      expect(offsets.desktopLyricsScroll, 66.0);
      for (var i = 0; i < 19; i++) {
        router.key(snapshot, offsets,
            value: KeySymbol.arrowDown, command: false);
      }
      // contentHeight = 1600-200 = 1400，viewport = 820-200 = 620，上限 780。
      expect(offsets.desktopLyricsScroll, 780.0);
      expect(offsets.settingsScroll, 0.0, reason: '两个偏移互不影响');
    });

    test('desktop-lyrics closing 时不滚动', () {
      final offsets = HudScrollOffsets();
      const HudKeyRouter(ports: _NoopHudPorts()).key(
        const HudKeySnapshot(modal: 'desktop-lyrics', closing: true),
        offsets,
        value: KeySymbol.arrowUp,
        command: false,
      );
      expect(offsets.desktopLyricsScroll, 0.0);
    });

    test('命令键 + Enter 先于弹层拦截：settings 里按 Ctrl+Enter 是播放', () {
      final ports = _HudRec();
      final outcome = HudKeyRouter(ports: ports).key(
        const HudKeySnapshot(modal: 'settings'),
        HudScrollOffsets(),
        value: KeySymbol.enter,
        command: true,
      );
      expect(outcome.consumed, isTrue);
      expect(outcome.effects, <String>['play']);
      expect(ports.calls, <String>['play']);
    });

    test('viewer 先于 Escape：viewer 打开时 Escape 也转发给 viewerKey', () {
      final ports = _HudRec();
      final outcome = HudKeyRouter(ports: ports).key(
        const HudKeySnapshot(viewer: true, modal: 'search'),
        HudScrollOffsets(),
        value: KeySymbol.escape,
        command: false,
      );
      expect(outcome.region, 'viewer');
      expect(outcome.effects, <String>['viewerKey:Escape']);
      expect(ports.calls, <String>['viewerKey:Escape']);
    });

    test('Escape 三级：desktop-lyrics / 无弹层 / 其它', () {
      const router = HudKeyRouter(ports: _NoopHudPorts());
      final a = router.key(const HudKeySnapshot(modal: 'desktop-lyrics'),
          HudScrollOffsets(),
          value: KeySymbol.escape, command: false);
      expect(a.effects, <String>[HudAction.desktopLyricsBack]);
      final b = router.key(const HudKeySnapshot(), HudScrollOffsets(),
          value: KeySymbol.escape, command: false);
      expect(b.effects, <String>[HudAction.back]);
      final c = router.key(const HudKeySnapshot(modal: 'search'),
          HudScrollOffsets(),
          value: KeySymbol.escape, command: false);
      expect(c.effects, <String>[HudAction.closeModal]);
      expect(a.consumed && b.consumed && c.consumed, isTrue);
    });

    test('有弹层时 Tab / 空格 / 动作表全部不生效', () {
      const router = HudKeyRouter(ports: _NoopHudPorts());
      const snapshot = HudKeySnapshot(modal: 'search');
      for (final value in <String>[
        KeySymbol.tab,
        KeySymbol.space,
        KeySymbol.arrowRight,
        KeySymbol.enter,
        KeySymbol.slash,
      ]) {
        final outcome = router.key(snapshot, HudScrollOffsets(),
            value: value, command: false);
        expect(outcome.consumed, isTrue, reason: '键被吞掉: ' + value);
        expect(outcome.effects, isEmpty, reason: '无副作用: ' + value);
        expect(outcome.region, 'none');
      }
    });

    test('Tab 只在 !command 时切 archive:tab-mode', () {
      const router = HudKeyRouter(ports: _NoopHudPorts());
      final on = router.key(const HudKeySnapshot(), HudScrollOffsets(),
          value: KeySymbol.tab, command: false);
      expect(on.effects, <String>[HudAction.archiveTabMode]);
      final off = router.key(const HudKeySnapshot(), HudScrollOffsets(),
          value: KeySymbol.tab, command: true);
      expect(off.consumed, isFalse, reason: 'Tab+command 不命中任何分支');
      expect(off.effects, isEmpty);
    });

    test('空格切换播放（:930-933）', () {
      final ports = _HudRec();
      final outcome = HudKeyRouter(ports: ports).key(
        const HudKeySnapshot(),
        HudScrollOffsets(),
        value: KeySymbol.space,
        command: false,
      );
      expect(outcome.effects, <String>['togglePlayer']);
      expect(ports.calls, <String>['togglePlayer']);
    });

    test('六项动作表逐项命中（:934-942）', () {
      const router = HudKeyRouter(ports: _NoopHudPorts());
      const expected = <String, String>{
        KeySymbol.arrowLeft: HudAction.columnPrev,
        KeySymbol.arrowRight: HudAction.columnNext,
        KeySymbol.arrowUp: HudAction.prev,
        KeySymbol.arrowDown: HudAction.next,
        KeySymbol.enter: HudAction.open,
        KeySymbol.slash: HudAction.search,
      };
      expected.forEach((value, action) {
        final outcome = router.key(const HudKeySnapshot(), HudScrollOffsets(),
            value: value, command: false);
        expect(outcome.consumed, isTrue, reason: value);
        expect(outcome.effects, <String>[action], reason: value);
      });
    });

    test('表外键落到函数末尾：不认领、无动作（:942-943）', () {
      const router = HudKeyRouter(ports: _NoopHudPorts());
      for (final value in <String>['a', 'F10', '', '\n', '\t']) {
        final outcome = router.key(const HudKeySnapshot(), HudScrollOffsets(),
            value: value, command: false);
        expect(outcome.consumed, isFalse, reason: value);
        expect(outcome.effects, isEmpty, reason: value);
        expect(outcome.region, 'none');
      }
    });
  });

  group('ShortcutRouter —— Overlay.qml:158-178', () {
    test('序列表：quit 单条、fullscreen 在 osx 上两条、profiler 单条', () {
      final osx = ShortcutRouter.sequences(osx: true);
      final other = ShortcutRouter.sequences(osx: false);
      expect(osx['quit'], <String>['StandardKey.Quit']);
      expect(osx['fullscreen'], <String>['StandardKey.FullScreen', 'F11']);
      expect(other['fullscreen'], <String>['F11']);
      expect(osx['profiler'], <String>['F10']);
      expect(other['profiler'], <String>['F10']);
    });

    test('context：windows 看 controlledHost，其它平台看 hasHostWindow', () {
      expect(
        ShortcutRouter.shortcutContext(
            windows: true, controlledHost: true, hasHostWindow: true),
        ShortcutContext.applicationShortcut,
      );
      expect(
        ShortcutRouter.shortcutContext(
            windows: true, controlledHost: false, hasHostWindow: true),
        ShortcutContext.windowShortcut,
      );
      expect(
        ShortcutRouter.shortcutContext(
            windows: false, controlledHost: false, hasHostWindow: true),
        ShortcutContext.windowShortcut,
      );
      expect(
        ShortcutRouter.shortcutContext(
            windows: false, controlledHost: true, hasHostWindow: false),
        ShortcutContext.applicationShortcut,
      );
    });

    test('三条序列各自触发对应端口，顺序 Quit → Fullscreen → Profiler', () {
      final ports = _ShortcutRec();
      final router = ShortcutRouter(ports: ports);
      final quit = router.activate('StandardKey.Quit',
          osx: false, windows: false, controlledHost: false, hasHostWindow: true)!;
      final full = router.activate('F11',
          osx: false, windows: false, controlledHost: false, hasHostWindow: true)!;
      final prof = router.activate('F10',
          osx: false, windows: false, controlledHost: false, hasHostWindow: true)!;
      expect(quit.action, 'quit');
      expect(quit.context, ShortcutContext.windowShortcut);
      expect(full.action, 'toggleFullscreen');
      expect(prof.action, 'toggleProfiler');
      expect(ports.calls, <String>['quit', 'fullscreen', 'profiler']);
    });

    test('未知序列不触发任何动作', () {
      final ports = _ShortcutRec();
      final outcome = ShortcutRouter(ports: ports)
          .activate('F12',
              osx: true,
              windows: true,
              controlledHost: true,
              hasHostWindow: false);
      expect(outcome, isNull);
      expect(ports.calls, isEmpty);
    });
  });

  group('KeyFocusResolver —— Overlay.qml:50-62', () {
    test('非 windows 一律回 inputLayer', () {
      final target = KeyFocusResolver.restoreFocus(
        const KeyFocusState(
          windows: false,
          searchVisible: true,
          searchEnabled: true,
          formVisible: true,
          accountEnabled: true,
        ),
      );
      expect(target.layer, KeyFocusLayer.inputLayer);
      expect(target.field, '');
    });

    test('windows 上搜索框优先于表单', () {
      final target = KeyFocusResolver.restoreFocus(
        const KeyFocusState(
          windows: true,
          searchVisible: true,
          searchEnabled: true,
          formVisible: true,
          accountEnabled: true,
        ),
      );
      expect(target.layer, KeyFocusLayer.searchInput);
    });

    test('搜索框不可用时退到表单账号框', () {
      final target = KeyFocusResolver.restoreFocus(
        const KeyFocusState(
          windows: true,
          searchVisible: true,
          searchEnabled: false,
          formVisible: true,
          accountEnabled: true,
        ),
      );
      expect(target.layer, KeyFocusLayer.formFields);
      expect(target.field, KeyFocusTarget.accountField);
    });

    test('都不满足时回 inputLayer', () {
      expect(
        KeyFocusResolver.restoreFocus(const KeyFocusState(windows: true)).layer,
        KeyFocusLayer.inputLayer,
      );
      expect(
        KeyFocusResolver.restoreFocus(const KeyFocusState(
          windows: true,
          formVisible: true,
          accountEnabled: false,
        )).layer,
        KeyFocusLayer.inputLayer,
      );
    });
  });

  group('KeyFocusRouter.dispatch —— Overlay.qml:87-120 的排他分派', () {
    test('字段层只问 sink，不问 Engine', () {
      final fields = _FieldRec();
      final engine = _EngineRec();
      final router =
          KeyFocusRouter(fields: fields, engine: EngineKeyRouter(ports: engine));
      final outcome = router.dispatch(
        const KeyFocusTarget.searchInput(),
        const HudKeyEvent(symbol: KeySymbol.enter, text: '阿'),
      );
      expect(outcome.layer, KeyFocusLayer.searchInput);
      expect(outcome.accepted, isTrue);
      expect(fields.calls, <String>['searchInput||Enter']);
      expect(engine.calls, isEmpty);
      expect(outcome.effects, isEmpty);
    });

    test('formFields 带上具体字段名，sink 返回值即 accepted', () {
      final fields = _FieldRec(answer: false);
      final engine = _EngineRec();
      final router =
          KeyFocusRouter(fields: fields, engine: EngineKeyRouter(ports: engine));
      final outcome = router.dispatch(
        const KeyFocusTarget.formField(KeyFocusTarget.captchaField),
        const HudKeyEvent(symbol: KeySymbol.escape, text: ''),
      );
      expect(outcome.layer, KeyFocusLayer.formFields);
      expect(outcome.field, KeyFocusTarget.captchaField);
      expect(outcome.accepted, isFalse);
      expect(fields.calls, <String>['formFields|captchaField|Escape']);
      expect(engine.calls, isEmpty, reason: '字段层不回落给 Engine');
    });

    test('settingEdit 层同样排他', () {
      final fields = _FieldRec();
      final engine = _EngineRec();
      KeyFocusRouter(fields: fields, engine: EngineKeyRouter(ports: engine))
          .dispatch(const KeyFocusTarget.settingEdit(),
              const HudKeyEvent(symbol: KeySymbol.enter));
      expect(fields.calls.single,
          'settingEditInput||Enter');
      expect(engine.calls, isEmpty);
    });

    test('inputLayer 走 Engine：accepted 与 effects 原样透传', () {
      final fields = _FieldRec();
      final engine = _EngineRec();
      final outcome =
          KeyFocusRouter(fields: fields, engine: EngineKeyRouter(ports: engine))
              .dispatch(const KeyFocusTarget.inputLayer(),
                  const HudKeyEvent(text: 'q'));
      expect(outcome.layer, KeyFocusLayer.inputLayer);
      expect(outcome.accepted, isTrue);
      expect(outcome.effects, <String>['key:q']);
      expect(engine.calls, <String>['key:q:false']);
      expect(fields.calls, isEmpty);
    });

    test('inputLayer + 空事件 → accepted=false，不产生调用', () {
      final fields = _FieldRec();
      final engine = _EngineRec();
      final outcome =
          KeyFocusRouter(fields: fields, engine: EngineKeyRouter(ports: engine))
              .dispatch(
                  const KeyFocusTarget.inputLayer(), const HudKeyEvent());
      expect(outcome.accepted, isFalse);
      expect(engine.calls, isEmpty);
    });

  });
}

/// 只为让上面的分支形状断言能构造 router 而存在；不记录任何调用。
class _NoopHudPorts implements HudKeyPorts {
  const _NoopHudPorts();

  @override
  void play() {}

  @override
  void viewerKey(String value) {}

  @override
  void action(String action) {}

  @override
  void togglePlayer() {}
}

/// 记录器/Noop 之上不再需要快捷键侧 Noop：ShortcutRouter 的用例一律用 _ShortcutRec。
