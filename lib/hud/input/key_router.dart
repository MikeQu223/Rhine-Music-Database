/// 键盘 / 快捷键输入路由：Qt/src/Engine.cpp:952-1012（keyEvent / keyEventImpl /
/// searchAccepted）、Qt/src/NativeHudController.cpp:887-943（NativeHud::key）、
/// Qt/qml/Overlay.qml:50-62（焦点恢复）、:118-120（inputLayer 的 Keys.onPressed）与
/// :158-178（三条全局 Shortcut）的 1:1 迁移。
///
/// 分层（与 Qt 调用链一一对应，不得合并）：
///   1. ShortcutRouter  —— QML Shortcut（Overlay.qml:164-178）。由 Qt 自己的 shortcutMap
///                         匹配，不经过 rhine.keyEvent，所以单独成一层。
///   2. EngineKeyRouter —— Engine::keyEvent（Engine.cpp:961-1005）与独立的
///                         Engine::searchAccepted（:1006-1012）。
///   3. HudKeyRouter    —— NativeHud::key(value, command)（NativeHudController.cpp:887-943），
///                         即 Engine::key 的落点。
///   4. KeyFocusRouter  —— Overlay.qml:50-62 的焦点恢复规则与 :87-120 的按键分派：
///                         决定这次按键交给输入框还是交给第 2、3 层。
///
/// 归属表（谁实现哪段 QML 分支；本文件刻意不复制下面任何一条分支体）：
///   | QML 出处                       | 键           | 归属                                              |
///   | Overlay.qml:118-120            | 全部键       | 本文件第 2、3 层（焦点在 inputLayer 时）           |
///   | Overlay.qml:399-406 / :459-460 | Return/Esc   | TextInputOverlayLogic.handleKey（account/captcha） |
///   | Overlay.qml:549-552            | Return/Esc   | TextInputOverlayLogic.handleKey（search）          |
///   | Overlay.qml:600-601            | Return/Esc   | TextInputOverlayLogic.handleKey（settingEdit）     |
///
/// 输入框层与 inputLayer 在 QML 里是兄弟节点、不是祖先链：Keys 处理器只发给 activeFocus
/// 项，所以输入框吃掉 Return/Escape 后事件不会继续冒泡到 inputLayer。本文件据此把
/// 字段层做成**排他**路由——字段层没接住时也绝不回落到 Engine，否则会凭空多出一次动作。
///
/// 不可变约束（逐条有出处）：
/// - accepted 语义：QML 里是 event.accepted = rhine.keyEvent(...)（Overlay.qml:119），
///   false 表示事件不被消费、继续交给平台。故本文件把 accepted 作为返回值，而不只返回副作用。
/// - 媒体键不看 text，直接发动作（Engine.cpp:963-973）——这是唯一在 text 为空时也 accepted 的路径。
/// - 只有命令键位会被下传（:1003），注释原文指出 Qt 在 macOS 把命令键映射到 ControlModifier，
///   因此 command 表示「命令键」而非字面的 Ctrl。
/// - NativeHud::key 的第一道门是 frame.isEmpty()（:888-890），先于一切分支。
/// - settings / desktop-lyrics 的上下键在弹层里被就地吞掉（:891-904），不落到全局动作表；
///   两者都要求 !closing，滚动量固定 ±66（NativeHud.h:115-127 的 viewport 常数）。
/// - 命令键 + Enter 播放（:905-908）先于 viewer 与 Escape 之外的后续所有分支。
/// - Escape 三级（:913-922）：desktop-lyrics → "desktop-lyrics:back"；无弹层 → "back"；
///   其它 → "close-modal"。
/// - 有弹层时 Tab / 空格 / 六项动作表全部不生效（:923-925）。
/// - Tab 只在 !command 时切 "archive:tab-mode"（:926-929）。
/// - 动作表固定 6 项（:934-939）：ArrowLeft→column-prev、ArrowRight→column-next、
///   ArrowUp→prev、ArrowDown→next、Enter→open、"/"→search。
///
/// 与初版草稿的偏差（DEV，均给出理由）：
/// - DEV-1 删掉 QtModifierBits（草稿里的 control = 0x04000000）。该位值在树内确有出处
///   （third_party/qt/qtbase/src/corelib/global/qnamespace.h:1080，ControlModifier =
///   0x04000000），但把它抄进 Dart 等于在本层重实现一遍 Qt 枚举语义，还要再复刻 Engine.cpp:1002
///   注明的 macOS command 映射；改为吃桥接层已解析的 bool control（与 Engine.cpp:1003 下传的
///   command 同源），[HudKeyEvent] 因此不再携带 int modifiers。
/// - DEV-2 删掉草稿的 FieldKeyRouter / FieldKeyPorts / FieldKeyOutcome / KeyField。
///   上面归属表里的四个输入框 Return/Escape 分支已经由 text_input_overlay.dart 的
///   TextInputOverlayLogic.handleKey 完整实现（它转给 _onEscape / _onReturn，且被真正的
///   Widget 的 onSubmitted 调用），再写一遍就是第三份真相。本文件只保留
///   [FieldKeySink] 这一条窄端口：谁持有输入框状态谁实现它，接线时由宿主把
///   [KeyFocusTarget] 映射成 text_input_overlay 的 TextFieldKind（一次 map，两侧都不改）。
/// - DEV-3 brief 写的 "Qt/src/NativeHudInput.cpp key 分支" 实际不存在：key 分支在
///   Qt/src/NativeHudController.cpp:887-943，NativeHudInput.* 只有 query / pointer。
library;

import 'wheel_router.dart' show HudScroll, HudScrollOffsets, HudWheelConstants;

// ─────────────────────────────────────────────────────────────────────────────
// 键的语义名与事件
// ─────────────────────────────────────────────────────────────────────────────

/// Engine 交给 NativeHud::key 的 value 字符串（Engine.cpp:974-995 的翻译结果），
/// 以及由 event.text 直接透传的空格与 "/"。
class KeySymbol {
  const KeySymbol._();

  static const String arrowLeft = 'ArrowLeft';
  static const String arrowRight = 'ArrowRight';
  static const String arrowUp = 'ArrowUp';
  static const String arrowDown = 'ArrowDown';
  static const String enter = 'Enter';
  static const String escape = 'Escape';
  static const String tab = 'Tab';

  /// 由 QKeyEvent::text() 透传，不是翻译结果（Engine.cpp:999-1001 直接用 text）。
  static const String space = ' ';

  /// NativeHudController.cpp:940 的动作表键，同样来自 text()。
  static const String slash = '/';

  /// Engine.cpp:963-973 的五个媒体键（Key_MediaTogglePlayPause / Key_MediaPlay /
  /// Key_MediaPause / Key_MediaNext / Key_MediaPrevious）。
  static const String mediaTogglePlayPause = 'MediaTogglePlayPause';
  static const String mediaPlay = 'MediaPlay';
  static const String mediaPause = 'MediaPause';
  static const String mediaNext = 'MediaNext';
  static const String mediaPrevious = 'MediaPrevious';

  /// Engine.cpp:974-995 —— 键码被翻译成文本的那 7 个键。
  ///
  /// 桥接层把 Qt 键码映射到这些符号后，[KeyCodec.translatedName] 再还原成 Qt 会写进
  /// text 的字符串；返回 null 表示「不是被翻译的键」，此时用 event.text。
  static const Set<String> translated = <String>{
    arrowLeft,
    arrowRight,
    arrowUp,
    arrowDown,
    enter,
    escape,
    tab,
  };
}

/// 一次按键事件：Qt 的 (key, modifiers, text) 三元组（Overlay.qml:119），
/// 外加桥接层解析出的语义符号与命令键标志。
class HudKeyEvent {
  const HudKeyEvent({
    this.symbol = '',
    this.key = 0,
    this.text = '',
    this.command = false,
  });

  /// 桥接层解析出的 Qt::Key 语义名（[KeySymbol]）；普通字符键留空。
  final String symbol;

  /// 原始 Qt 键码，仅用于日志 / 探针（Engine.cpp:956 的 RHINE_KEY_PROBE），不参与判断。
  final int key;

  /// QKeyEvent::text()。
  final String text;

  /// modifiers & Qt::ControlModifier（Engine.cpp:1003 的语义；见 DEV-1）。
  final bool command;

  @override
  String toString() =>
      'HudKeyEvent(symbol=$symbol key=$key text=$text command=$command)';
}

/// action(...) 的字面量表：键盘路径上会发出的全部动作名，逐条有 Qt 出处。
///
/// 单独成类的原因：同目录 text_input_overlay.dart 的 _onEscape 也发同一个 "close-modal"
/// （IME 的 Escape 与 QML 的 Keys.onEscapePressed 是同一条动作），两处必须共用一份
/// 字面量，否则拼错无法被静态审查发现。
class HudAction {
  const HudAction._();

  /// Overlay.qml:406、:460、:549 —— Escape 关闭当前弹层。
  static const String closeModal = 'close-modal';

  /// NativeHudController.cpp:917 —— 无弹层时的返回。
  static const String back = 'back';

  /// NativeHudController.cpp:915 —— 桌面歌词弹层的返回。
  static const String desktopLyricsBack = 'desktop-lyrics:back';

  /// NativeHudController.cpp:928 —— Tab 切换归档列模式。
  static const String archiveTabMode = 'archive:tab-mode';

  /// NativeHudController.cpp:934-939 的六项单键动作表。
  static const String columnPrev = 'column-prev';
  static const String columnNext = 'column-next';
  static const String prev = 'prev';
  static const String next = 'next';
  static const String open = 'open';
  static const String search = 'search';

  /// Engine.cpp:966、:969、:972 —— 媒体键。
  static const String playerToggle = 'player:toggle';
  static const String playerNext = 'player:next';
  static const String playerPrev = 'player:prev';
}

/// Qt 键码语义名 → Engine 写进 text 的字符串（Engine.cpp:974-995），
/// 以及媒体键的动作（:963-973）。
class KeyCodec {
  const KeyCodec._();

  /// Engine.cpp:963-973 —— 媒体键直接动作，不看 text，且 accepted = true。
  static String? mediaAction(String symbol) {
    switch (symbol) {
      case KeySymbol.mediaTogglePlayPause:
      case KeySymbol.mediaPlay:
      case KeySymbol.mediaPause:
        return HudAction.playerToggle;
      case KeySymbol.mediaNext:
        return HudAction.playerNext;
      case KeySymbol.mediaPrevious:
        return HudAction.playerPrev;
      default:
        return null;
    }
  }

  /// Engine.cpp:974-995 —— 7 个被翻译的键；其余键返回 null（走 event.text）。
  static String? translatedName(String symbol) =>
      KeySymbol.translated.contains(symbol) ? symbol : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 第 1 层：QML 全局快捷键（Overlay.qml:158-178）
// ─────────────────────────────────────────────────────────────────────────────

/// Qt.ShortcutContext 的两个取值（Overlay.qml:158-163 只在这两者间取舍）。
class ShortcutContext {
  const ShortcutContext._();

  static const String windowShortcut = 'WindowShortcut';
  static const String applicationShortcut = 'ApplicationShortcut';
}

/// 快捷键侧的端口：三条 Shortcut 的 onActivated。
abstract class ShortcutPorts {
  /// Overlay.qml:167 —— Qt.quit()。
  void quit();

  /// Overlay.qml:172 —— rhine.toggleFullscreen()。
  void toggleFullscreen();

  /// Overlay.qml:177 —— profiler.toggleVisible()。
  void toggleProfiler();
}

/// 一条被命中的快捷键。
class ShortcutOutcome {
  const ShortcutOutcome({
    required this.sequence,
    required this.context,
    required this.action,
  });

  /// 命中的序列标签：StandardKey.Quit / StandardKey.FullScreen / F11 / F10。
  final String sequence;

  /// 该 Shortcut 生效时的 context（Overlay.qml:158-163）。
  final String context;

  final String action;

  @override
  String toString() =>
      'ShortcutOutcome(sequence=$sequence context=$context action=$action)';
}

/// Overlay.qml:158-178 的三条全局 Shortcut。
///
/// :143-157 的注释解释了 context 为何要跟着宿主变：FG 是离屏 QQuickRenderControl 窗口，
/// 没有平台窗口，isActive() 恒 false、requestActivate() 无效，QShortcutMap 因此匹配不到
/// WindowShortcut；而 QML Shortcut 只在平台事件路径上经 shortcutMap.tryShortcut 处理，
/// FgShell::eventFilter 里 sendEvent 的直接投递完全不经过快捷键地图，任何 context 都不触发。
/// 于是有平台窗口时用 WindowShortcut，没有时退回 ApplicationShortcut。
class ShortcutRouter {
  const ShortcutRouter({required this.ports});

  final ShortcutPorts ports;

  /// Overlay.qml:158-163 —— 原样保留的取舍规则，包括 windows 与其它平台的判断顺序不同、
  /// 以及 windows 只在 controlledHost 时才用 ApplicationShortcut 这两点。
  static String shortcutContext({
    required bool windows,
    required bool controlledHost,
    required bool hasHostWindow,
  }) {
    if (windows) {
      return controlledHost
          ? ShortcutContext.applicationShortcut
          : ShortcutContext.windowShortcut;
    }
    return hasHostWindow
        ? ShortcutContext.windowShortcut
        : ShortcutContext.applicationShortcut;
  }

  /// Overlay.qml:165 / :170 / :175 —— 三条 Shortcut 的序列表，一个字面量都不改。
  ///
  /// StandardKey.* 由宿主按平台解析（Qt 的 QKeySequence 表不在本仓库源内）；
  /// osx 上 Fullscreen 是 [StandardKey.FullScreen, "F11"] 两条序列（:170）。
  static Map<String, List<String>> sequences({required bool osx}) {
    return <String, List<String>>{
      'quit': const <String>['StandardKey.Quit'],
      'fullscreen': osx
          ? const <String>['StandardKey.FullScreen', 'F11']
          : const <String>['F11'],
      'profiler': const <String>['F10'],
    };
  }

  /// 命中的序列标签 → 动作。标签必须来自 [sequences]，否则返回 null。
  ///
  /// 匹配优先级即 QML 里的声明顺序：Quit（:164）→ Fullscreen（:169）→ Profiler（:174）。
  ShortcutOutcome? activate(
    String sequence, {
    required bool osx,
    required bool windows,
    required bool controlledHost,
    required bool hasHostWindow,
  }) {
    final table = sequences(osx: osx);
    final context = shortcutContext(
      windows: windows,
      controlledHost: controlledHost,
      hasHostWindow: hasHostWindow,
    );
    if (table['quit']!.contains(sequence)) {
      ports.quit();
      return ShortcutOutcome(sequence: sequence, context: context, action: 'quit');
    }
    if (table['fullscreen']!.contains(sequence)) {
      ports.toggleFullscreen();
      return ShortcutOutcome(
        sequence: sequence,
        context: context,
        action: 'toggleFullscreen',
      );
    }
    if (table['profiler']!.contains(sequence)) {
      ports.toggleProfiler();
      return ShortcutOutcome(
        sequence: sequence,
        context: context,
        action: 'toggleProfiler',
      );
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 第 2 层：Engine 的 keyEvent / searchAccepted（Engine.cpp:952-1012）
// ─────────────────────────────────────────────────────────────────────────────

/// Engine 侧的端口：Engine.cpp 里真正被调用的三处。
abstract class EngineKeyPorts {
  /// Engine.cpp:966 等 —— app->action(...)。
  void action(String action);

  /// Engine.cpp:1003 —— hud.key(value, command)。
  void key(String value, bool command);

  /// Engine.cpp:1010 —— query(text)。
  void query(String text);
}

/// Engine::keyEvent 的结果。
class EngineKeyOutcome {
  const EngineKeyOutcome({required this.accepted, this.effects = const <String>[]});

  /// Engine.cpp:953 的返回值：QML 直接把它赋给 event.accepted（Overlay.qml:119）。
  final bool accepted;

  final List<String> effects;

  @override
  String toString() => 'EngineKeyOutcome(accepted=$accepted effects=$effects)';
}

/// Engine.cpp:952-1012 的 1:1 迁移。
class EngineKeyRouter {
  const EngineKeyRouter({required this.ports});

  final EngineKeyPorts ports;

  /// Engine.cpp:961-1005。
  ///
  /// 顺序：媒体键 → 7 个翻译键 → 否则 event.text → 空则 false → key(value, command) 并 true。
  EngineKeyOutcome keyEvent(HudKeyEvent event) {
    // :963-973
    final media = KeyCodec.mediaAction(event.symbol);
    if (media != null) {
      ports.action(media);
      return EngineKeyOutcome(accepted: true, effects: <String>[media]);
    }
    // :974-998 —— 被翻译的键覆盖掉 event.text（Qt 是赋值，不是取值回退）。
    final translated = KeyCodec.translatedName(event.symbol);
    final value = translated ?? event.text;
    // :999-1001
    if (value.isEmpty) {
      return const EngineKeyOutcome(accepted: false);
    }
    // :1003
    ports.key(value, event.command);
    return EngineKeyOutcome(accepted: true, effects: <String>['key:$value']);
  }

  /// Engine.cpp:1006-1012 —— 搜索框回车：命令键时等价于 key("Enter", true)（播放），
  /// 否则把文本作为查询提交。QML 里是 fire-and-forget，没有 accepted 回传。
  ///
  /// Qt 读的是 modifiers & Qt::ControlModifier；该位由桥接层解析成 bool（见 DEV-1），
  /// 与 inputLayer 路径上的 command 同源，本层不复制位值。
  String searchAccepted(String text, {required bool control}) {
    if (control) {
      ports.key(KeySymbol.enter, true);
      return 'key:Enter';
    }
    ports.query(text);
    return 'query';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 第 3 层：NativeHud::key（NativeHudController.cpp:887-943）
// ─────────────────────────────────────────────────────────────────────────────

/// NativeHud 侧的端口：每个方法对应 Qt 里一处真正的调用。
abstract class HudKeyPorts {
  /// :906 —— m_music->play()。
  void play();

  /// :910 —— m_scene.viewerKey(value)。
  void viewerKey(String value);

  /// :915、:917、:919（Escape 三级）、:928（archive:tab-mode）、:941（六项动作表）—— action(...)。
  void action(String action);

  /// :931 —— m_music->player.toggle()。
  void togglePlayer();
}

/// NativeHud::key 的结果。
///
/// [consumed] 表示「本层认领了这个键」：true 包括真的发了动作、以及在弹层里被就地吞掉
/// 这两种情况；false 只有两种——frame 为空的首门（:888-890）与落到函数末尾的表外键。
/// 注意它不是 Engine 的 accepted：那是由 [EngineKeyRouter] 在调用 hud.key 之前就返回的。
class HudKeyOutcome {
  const HudKeyOutcome({
    this.consumed = false,
    this.region = 'none',
    this.effects = const <String>[],
  });

  final bool consumed;

  /// 命中的区域：'settings' / 'desktop-lyrics'（QML 的 modal 字符串）、'viewer'、
  /// 或 'none'（未认领）。与 wheel_router 的 WheelRegion 不共用类型：这里只是诊断标签。
  final String region;

  final List<String> effects;

  @override
  String toString() =>
      'HudKeyOutcome(region=$region consumed=$consumed effects=$effects)';
}

/// NativeHudController.cpp:887-943 的 1:1 迁移。
class HudKeyRouter {
  const HudKeyRouter({required this.ports});

  final HudKeyPorts ports;

  /// NativeHudController.cpp:934-939 —— 六项固定表，顺序即源码书写顺序
  /// （:940-942 是 contains + action(actions[value])）。
  static const Map<String, String> _actions = <String, String>{
    KeySymbol.arrowLeft: HudAction.columnPrev,
    KeySymbol.arrowRight: HudAction.columnNext,
    KeySymbol.arrowUp: HudAction.prev,
    KeySymbol.arrowDown: HudAction.next,
    KeySymbol.enter: HudAction.open,
    KeySymbol.slash: HudAction.search,
  };

  /// [s] 提供 frame / modal / closing / viewer 与内容高度；[offsets] 被就地修改
  /// （Qt 里 settingsScroll / desktopLyricsScroll 是 NativeHud 的成员变量）。
  HudKeyOutcome key(
    HudKeySnapshot s,
    HudScrollOffsets offsets, {
    required String value,
    required bool command,
  }) {
    // :888-890
    if (s.frameEmpty) {
      return const HudKeyOutcome();
    }
    // :891-897 —— 设置弹层里上下键就是滚动，且被就地吞掉，不落到动作表。
    if (s.modal == 'settings' &&
        !s.closing &&
        (value == KeySymbol.arrowDown || value == KeySymbol.arrowUp)) {
      final movement = value == KeySymbol.arrowDown
          ? HudWheelConstants.settingsStepPixels
          : -HudWheelConstants.settingsStepPixels;
      offsets.settingsScroll = HudScroll.clampOffset(
        offsets.settingsScroll + movement,
        s.settingsContentBottom - HudWheelConstants.settingsViewportTop,
        HudWheelConstants.settingsViewportBottom -
            HudWheelConstants.settingsViewportTop,
      );
      return const HudKeyOutcome(
        consumed: true,
        region: 'settings',
        effects: <String>['settingsScroll'],
      );
    }
    // :898-904
    if (s.modal == 'desktop-lyrics' &&
        !s.closing &&
        (value == KeySymbol.arrowDown || value == KeySymbol.arrowUp)) {
      final movement = value == KeySymbol.arrowDown
          ? HudWheelConstants.desktopLyricsStepPixels
          : -HudWheelConstants.desktopLyricsStepPixels;
      offsets.desktopLyricsScroll = HudScroll.clampOffset(
        offsets.desktopLyricsScroll + movement,
        s.desktopLyricsContentBottom - HudWheelConstants.desktopLyricsViewportTop,
        HudWheelConstants.desktopLyricsViewportBottom -
            HudWheelConstants.desktopLyricsViewportTop,
      );
      return const HudKeyOutcome(
        consumed: true,
        region: 'desktop-lyrics',
        effects: <String>['desktopLyricsScroll'],
      );
    }
    // :905-908 —— 命令键 + Enter 播放（先于 viewer 与 Escape 之外的后续分支）。
    if (value == KeySymbol.enter && command) {
      ports.play();
      return const HudKeyOutcome(consumed: true, effects: <String>['play']);
    }
    // :909-912 —— viewer 打开时所有键交给 m_scene.viewerKey。
    if (s.viewer) {
      ports.viewerKey(value);
      return HudKeyOutcome(
        consumed: true,
        region: 'viewer',
        effects: <String>['viewerKey:$value'],
      );
    }
    // :913-922 —— Escape 三级。
    if (value == KeySymbol.escape) {
      if (s.modal == 'desktop-lyrics') {
        ports.action(HudAction.desktopLyricsBack);
        return const HudKeyOutcome(
          consumed: true,
          effects: <String>[HudAction.desktopLyricsBack],
        );
      }
      if (s.modal.isEmpty) {
        ports.action(HudAction.back);
        return const HudKeyOutcome(
          consumed: true,
          effects: <String>[HudAction.back],
        );
      }
      ports.action(HudAction.closeModal);
      return const HudKeyOutcome(
        consumed: true,
        effects: <String>[HudAction.closeModal],
      );
    }
    // :923-925 —— 有弹层时下面一切都不生效（无副作用，但键已被吞掉）。
    if (s.modal.isNotEmpty) {
      return const HudKeyOutcome(consumed: true);
    }
    // :926-929
    if (value == KeySymbol.tab && !command) {
      ports.action(HudAction.archiveTabMode);
      return const HudKeyOutcome(
        consumed: true,
        effects: <String>[HudAction.archiveTabMode],
      );
    }
    // :930-933
    if (value == KeySymbol.space) {
      ports.togglePlayer();
      return const HudKeyOutcome(consumed: true, effects: <String>['togglePlayer']);
    }
    // :934-942
    final mapped = _actions[value];
    if (mapped != null) {
      ports.action(mapped);
      return HudKeyOutcome(consumed: true, effects: <String>[mapped]);
    }
    // 表外按键在 Qt 里落到函数末尾：无动作、也没有 accepted，此处同形。
    return const HudKeyOutcome();
  }
}

/// HudKeyRouter 需要的状态投影（NativeHud 的 frame / state 子集）。
class HudKeySnapshot {
  const HudKeySnapshot({
    this.frameEmpty = false,
    this.modal = '',
    this.closing = false,
    this.viewer = false,
    this.settingsContentBottom = 1600.0,
    this.desktopLyricsContentBottom = 1600.0,
  });

  /// NativeHudController.cpp:888 的 frame.isEmpty()。
  final bool frameEmpty;

  /// QML 的 modal 字符串：'' / 'settings' / 'desktop-lyrics' / 'search' / 'login' ...
  final String modal;

  /// 弹层关闭动画进行中；settings 与 desktop-lyrics 的滚动分支都要求 !closing。
  final bool closing;

  /// frame["viewer"].toBool()（NativeHudController.cpp:909）。
  final bool viewer;

  /// 内容高度；与 wheel_router 的 HudWheelSnapshot 同源（缺省 1600.0 也一致）。
  final double settingsContentBottom;
  final double desktopLyricsContentBottom;

  @override
  String toString() =>
      'HudKeySnapshot(frameEmpty=$frameEmpty modal=$modal closing=$closing '
      'viewer=$viewer)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 第 4 层：焦点层与按键分派（Overlay.qml:50-62、:87-120）
// ─────────────────────────────────────────────────────────────────────────────

/// 焦点层：QML 里能接住按键的四个节点（id 或 objectName 原样保留）。
class KeyFocusLayer {
  const KeyFocusLayer._();

  /// Overlay.qml:87 —— MouseArea inputLayer，focus: true，Keys.onPressed 在这里。
  static const String inputLayer = 'inputLayer';

  /// Overlay.qml:521 —— TextInput musicSearchInput（:526 可见、:527 enabled）。
  static const String searchInput = 'searchInput';

  /// Overlay.qml:356 —— formFields，内含 accountField / captchaField。
  static const String formFields = 'formFields';

  /// Overlay.qml:577 —— TextInput musicSettingEditInput。
  static const String settingEditInput = 'settingEditInput';

  /// 三个输入框容器层（它们的 Return/Escape 归 text_input_overlay.dart 的 handleKey）。
  static bool isField(String layer) =>
      layer == searchInput || layer == formFields || layer == settingEditInput;
}

/// 一次按键该交给谁：容器层 + 具体字段。
///
/// field 只在 [KeyFocusLayer.formFields] 下有值（accountField / captchaField），
/// 其余层留空——具体字段由持有输入框状态的宿主给出，这里不复制 text_input_overlay 的枚举。
class KeyFocusTarget {
  const KeyFocusTarget._(this.layer, this.field);

  const KeyFocusTarget.inputLayer() : this._(KeyFocusLayer.inputLayer, '');
  const KeyFocusTarget.searchInput() : this._(KeyFocusLayer.searchInput, '');
  const KeyFocusTarget.settingEdit() : this._(KeyFocusLayer.settingEditInput, '');
  const KeyFocusTarget.formField(String field)
      : this._(KeyFocusLayer.formFields, field);

  /// Overlay.qml:386 —— accountField 的 objectName。
  static const String accountField = 'accountField';

  /// Overlay.qml:445 —— captchaField 的 objectName。
  static const String captchaField = 'captchaField';

  final String layer;
  final String field;

  @override
  String toString() => 'KeyFocusTarget(layer=$layer field=$field)';
}

/// 焦点恢复需要的状态（Overlay.qml:50-62 读到的五个值）。
class KeyFocusState {
  const KeyFocusState({
    this.windows = false,
    this.searchVisible = false,
    this.searchEnabled = false,
    this.formVisible = false,
    this.accountEnabled = false,
  });

  /// Overlay.qml:27 —— readonly property bool windows: Qt.platform.os === "windows"。
  final bool windows;

  /// searchInput.visible（Overlay.qml:526）/ searchInput.enabled（:527）。
  final bool searchVisible;
  final bool searchEnabled;

  /// formFields.visible（:357）/ accountField.enabled。
  final bool formVisible;
  final bool accountEnabled;
}

/// Overlay.qml:50-62 —— restoreInputFocus() 的焦点选择，编辑态优先。
///
/// 非 windows 平台一律回到 inputLayer（离屏窗口在别的平台上没有可靠的输入框焦点语义）；
/// windows 上先看搜索框，再看表单的账号框，都没有才回 inputLayer。:49 的注释写明
/// 「不能把输入框焦点一律交回快捷键层」，所以这里必须按可见性/可用性挑，而不是永远
/// 返回 inputLayer。
class KeyFocusResolver {
  const KeyFocusResolver._();

  static KeyFocusTarget restoreFocus(KeyFocusState s) {
    if (!s.windows) {
      return const KeyFocusTarget.inputLayer();
    }
    if (s.searchVisible && s.searchEnabled) {
      return const KeyFocusTarget.searchInput();
    }
    if (s.formVisible && s.accountEnabled) {
      return const KeyFocusTarget.formField(KeyFocusTarget.accountField);
    }
    return const KeyFocusTarget.inputLayer();
  }
}

/// 输入框侧的窄端口：实现方持有输入框状态与本层字段语义。
///
/// 真实实现是 text_input_overlay.dart 的 TextInputOverlayLogic.handleKey 的接线适配器。
/// 返回值的语义与 QML 的 event.accepted 对齐：只有 Return / Escape 会被接住，其它键交给平台
/// 文本输入。注意 Qt 里这四个框的 Keys.onReturnPressed / onEscapePressed 是恒消费的（没有
/// 不消费的分支），所以真实实现恒返回 true；保留 bool 只是为了让字段层与 inputLayer 层同形。
abstract class FieldKeySink {
  bool fieldKey(KeyFocusTarget target, HudKeyEvent event);
}

/// 一次分派的结果。
class KeyDispatchOutcome {
  const KeyDispatchOutcome({
    required this.layer,
    this.field = '',
    this.accepted = false,
    this.effects = const <String>[],
  });

  final String layer;
  final String field;

  /// QML 的 event.accepted（Overlay.qml:119）：inputLayer 层取 Engine 的返回值，
  /// 字段层取 [FieldKeySink] 的返回值。
  final bool accepted;

  final List<String> effects;

  @override
  String toString() =>
      'KeyDispatchOutcome(layer=$layer field=$field accepted=$accepted '
      'effects=$effects)';
}

/// Overlay.qml:87-120 的按键分派 + :50-62 的焦点解析。
///
/// 排他规则：字段层只问 [FieldKeySink]，无论它接不接住都不再问 Engine——QML 里两者是
/// 兄弟节点，Keys 处理器不会跨节点冒泡；未知层同理，既不消费也不发动作（不猜）。
class KeyFocusRouter {
  const KeyFocusRouter({required this.fields, required this.engine});

  final FieldKeySink fields;
  final EngineKeyRouter engine;

  KeyDispatchOutcome dispatch(KeyFocusTarget target, HudKeyEvent event) {
    if (KeyFocusLayer.isField(target.layer)) {
      final accepted = fields.fieldKey(target, event);
      return KeyDispatchOutcome(
        layer: target.layer,
        field: target.field,
        accepted: accepted,
      );
    }
    if (target.layer == KeyFocusLayer.inputLayer) {
      final outcome = engine.keyEvent(event);
      return KeyDispatchOutcome(
        layer: KeyFocusLayer.inputLayer,
        accepted: outcome.accepted,
        effects: outcome.effects,
      );
    }
    return KeyDispatchOutcome(layer: target.layer, field: target.field);
  }
}
