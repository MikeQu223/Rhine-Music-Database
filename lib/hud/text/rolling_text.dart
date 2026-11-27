//! rolling_text.dart - 区块索引: [runtime] [frame] [request] [test-hooks]
//
// 共享滚动文字运行时：把 lib/hud/text/rolling_label.dart 的字符槽状态从
// "每次调用新建" 提升为 "每个稳定 key 一份、跨帧保留"。
//
// 真值：Qt/src/UiMotion.cpp RollingLabel::render（本文件不重算动画，只调度），
// Qt/src/NativeHud.cpp:97-101 roll() = fit() 后 rollingText()。Qt 的 NativeHud
// 每帧被 paint 调用，RollingLabel 的 Slot 在 NativeHud 成员里跨帧存活；本类
// 补的就是这层存活 + 帧时钟注入。
//
// 本类**不带时钟、不申请 repaint**：时钟由宿主（BasicHudSurface 的 Ticker）
// 推进并在 begin() 传入；本类只按当前 time 重放命令，[end] 返回是否还需要续帧。
// 这样滚动文字既能跟随既有帧循环，"初始/暂停/不触摸" 时也能靠 ticker 推进到
// 可见的终态，而不是靠业务轮询或硬编码标题。

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../pages/chrome.dart' show HudWireCommand;
import 'rolling_label.dart';

// [runtime]
/// 每个 [key] 一个 [RollingLabel]；同一 key 的调用必须来自同一语义位置
/// （music-brand / music-number 等），否则字符槽会在两个值之间来回卷动。
class HudRollingText {
  HudRollingText({required this.measure});

  /// Qt 传给 RollingLabel::render 的是 Glyphs::width，量的是同一
  /// (text, size, weight, tracking) 的 advance，不是整段文本宽度。
  final RollingMeasure measure;

  final Map<String, RollingLabel> _labels = <String, RollingLabel>{};

  double _time = 0;
  void Function(HudWireCommand command)? _emit;
  bool _open = false;
  bool _animating = false;

  /// 当前帧时钟（秒）。单位与 kReelDuration 一致。
  double get time => _time;

  /// 上一帧是否仍有标签在动：宿主据此继续 ticker。
  bool get animating => _animating;

  @visibleForTesting
  int get labelCount => _labels.length;

  /// 测试入口：读某个 key 的标签，验证槽状态是跨帧保留的同一个对象。
  @visibleForTesting
  RollingLabel? labelFor(String key) => _labels[key];

  // [frame]
  /// 开始一帧：绑定本帧 sink 与时钟。命令必须按 Qt 发射顺序进 sink。
  void begin({required double time, required void Function(HudWireCommand) emit}) {
    _time = time;
    _emit = emit;
    _open = true;
    _animating = false;
  }

  /// 结束一帧：解绑 sink，返回"还需要下一帧"（仍有字符槽在 kReelDuration 内）。
  bool end() {
    final bool animating = _animating;
    _open = false;
    _emit = null;
    _animating = false;
    return animating;
  }

  // [request]
  /// Qt NativeHud::roll 的落点：立即把 [RollingLabel.render] 的命令写进本帧 sink。
  ///
  /// [animate] 为 false 时走 render(animated: false)：只发一条静态 text
  /// （Qt 在无动画/静止时同样是单条 text 命令）。未 [begin] 时只计数不发射，
  /// 保持本端口在没有帧时钟的旧调用点上的既有语义。
  void request({
    required String key,
    required String value,
    required double x,
    required double y,
    required double size,
    required String weight,
    required double tracking,
    required bool numeric,
    required List<Object?> ink,
    required bool animate,
  }) {
    final void Function(HudWireCommand command)? emit = _emit;
    if (!_open || emit == null) {
      return;
    }
    final RollingLabel label = _labels.putIfAbsent(key, RollingLabel.new);
    final List<List<Object?>> commands = label.render(
      next: value,
      x: x,
      y: y,
      size: size,
      weight: weight,
      tracking: tracking,
      time: _time,
      animated: animate,
      numeric: numeric,
      ink: ink,
      measure: measure,
    );
    for (final List<Object?> command in commands) {
      emit(command);
    }
    if (animate && label.active(_time)) {
      _animating = true;
    }
  }
}
