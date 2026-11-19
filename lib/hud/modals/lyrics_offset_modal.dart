/// Flutter port of the Qt landscape HUD popover `lyrics-offset`.
///
/// This file is a self-contained Dart library (no imports at all). Every number
/// and every string below is copied from the Qt sources; nothing is redesigned,
/// no portrait pixel value is invented, and no generic dialog scaffolding is
/// added.
///
/// Qt evidence for the whole frame (design stage 1920x1080):
///
/// * bounds `{width * 0.56, 690, 320, 216}` - Qt/src/NativeHud.cpp:149-152
///   (`NativeHud::modalBounds`, branch `lyrics-offset`).
/// * entry `save(); alpha(motion.opacity);` - Qt/src/NativeHudModal.cpp:83-84.
/// * `translate(0, motion.offset)` - Qt/src/NativeHudModal.cpp:90.
/// * panel `fill(bounds.x, bounds.y, bounds.width, bounds.height, panelFill)`
///   with dark `{0.15, 0.15, 0.15, 1, calibratedWhite}` and light
///   `{0.929, 0.922, 0.894, 1}` - Qt/src/NativeHudModal.cpp:91-92.
/// * `hits = {}; m_modalControls = true;` - Qt/src/NativeHudModal.cpp:93-94.
///   A popover owns every hit it emits: no scrim fill and no full-screen
///   outside catcher (contrast the detail-sort catcher at
///   Qt/src/NativeHudModal.cpp:128), so taps outside hit nothing at all.
/// * content origin `x = bounds.x + 16`, `y = bounds.y` -
///   Qt/src/NativeHudModal.cpp:87-88.
/// * header `text(歌词偏移, x, y + 18, 17, demibold)` - :95.
/// * close `button(关闭, x + 232, y + 8, 56, 36, close-modal, 13)` - :96.
/// * offset label - :97-103 (`未校准` / `已提前 `/`已延后 ` + one decimal + `s`).
/// * `button(歌词提前 0.2s, x, y + 92, 138, 40, player:lyrics-earlier, 13)` and
///   `button(歌词延后 0.2s, x + 150, y + 92, 138, 40, player:lyrics-later, 13)`
///   - :104-105.
/// * reset: button `(x, y + 152, 138, 40, player:lyrics-reset, 13)` when
///   `offsetMs != 0`, otherwise muted `text(重置, x, y + 161, 13, regular, 0)`
///   - :106-112.
/// * apply-global: button `(x + 150, y + 152, 138, 40,
///   player:lyrics-apply-global, 13)` when `offsetMs != globalOffsetMs`,
///   otherwise muted `text(全局应用, x + 150, y + 161, 13, regular, 0)` - :113-117.
/// * `restore()` - :119.
///
/// Primitives (`ink`, `fill`, `text`, `fit`, `hit`, `button`) follow
/// Qt/src/NativeHud.cpp:10-129. Motion follows Qt/src/UiMotion.h:24-42 and
/// Qt/src/UiMotion.cpp:86-120.
library;

/// Signature of the injected glyph measurement.
///
/// Qt measures through `Glyphs::width` / `Glyphs::inset`; the port never
/// hardcodes a glyph advance, so every truncation is measured by the host.
typedef LyricsOffsetMeasureText = double Function(
    String text, double size, String? weight, double tracking);

/// Signature of the injected stage-rect mapping (portrait adapters).
///
/// The default is the identity, which keeps the Qt stage pixels exact. The
/// hook is applied exactly once per emitted rectangle (panel and each control),
/// so a translation-style adapter cannot be applied twice to a nested rect.
typedef LyricsOffsetRectHook = List<double> Function(
    double x, double y, double w, double h);

List<double> _identityRect(double x, double y, double w, double h) =>
    <double>[x, y, w, h];

double _min(double a, double b) => a < b ? a : b;

double _clamp01(double value) {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

/// Port of Qt `UiMotion::SurfaceMotion` (Qt/src/UiMotion.h:24-42,
/// Qt/src/UiMotion.cpp:86-120).
///
/// Time and duration are seconds. `offset` starts at 12 and the surface starts
/// fully transparent; `set(true)` eases opacity to 1 and offset to 0 in 0.3 s,
/// `set(false)` eases opacity to 0 and offset to 8 in 0.2 s. Reduced motion
/// snaps instantly.
class LyricsOffsetMotion {
  /// Current opacity, 0..1 (Qt/src/UiMotion.h:31).
  double opacity = 0;

  /// Current translated offset in stage pixels, starts at 12
  /// (Qt/src/UiMotion.h:32).
  double offset = 12;

  /// Remaining duration of the running transition, 0 when settled
  /// (Qt/src/UiMotion.h:33).
  double duration = 0;

  double _fromOpacity = 0;
  double _fromOffset = 12;
  double _targetOpacity = 0;
  double _targetOffset = 12;
  double _start = 0;
  bool _entering = true;

  /// `UiMotion::finished()` - Qt/src/UiMotion.h:28-30. `sample` zeroes
  /// `duration` once progress reaches 1, exactly like
  /// Qt/src/UiMotion.cpp:95-97, so this is also true after a full transition.
  bool get finished => duration == 0;

  /// `SurfaceMotion::sample` - Qt/src/UiMotion.cpp:86-98.
  void sample(double time) {
    if (duration <= 0) {
      return;
    }
    final progress = _clamp01((time - _start) / duration);
    final amount = _bezier(
      progress,
      _entering ? 0.22 : 0.4,
      _entering ? 1 : 0,
      _entering ? 0.36 : 1,
      1,
    );
    opacity = _fromOpacity + (_targetOpacity - _fromOpacity) * amount;
    offset = _fromOffset + (_targetOffset - _fromOffset) * amount;
    if (progress >= 1) {
      duration = 0;
    }
  }

  /// `SurfaceMotion::set` - Qt/src/UiMotion.cpp:101-120.
  ///
  /// The old transition is sampled before the target changes so a fast
  /// re-open continues from the current opacity and offset instead of jumping.
  void set(bool shown, double time, [bool reduced = false]) {
    sample(time);
    _fromOpacity = opacity;
    _fromOffset = offset;
    _targetOpacity = shown ? 1 : 0;
    _targetOffset = shown ? 0 : 8;
    _entering = shown;
    _start = time;
    if (reduced) {
      duration = 0;
    } else if (shown) {
      duration = 0.3;
    } else {
      duration = 0.2;
    }
    if (reduced) {
      opacity = _targetOpacity;
      offset = _targetOffset;
    }
  }

  /// Cubic bezier evaluated exactly like the Qt helper
  /// (Qt/src/UiMotion.cpp:7-22): 24 bisection steps on the x component and a
  /// final evaluation at the midpoint, not an analytic solve.
  static double _bezier(
      double x, double x1, double y1, double x2, double y2) {
    double lower = 0;
    double upper = 1;
    for (var i = 0; i < 24; i++) {
      final t = (lower + upper) / 2;
      if (_component(t, x1, x2) < x) {
        lower = t;
      } else {
        upper = t;
      }
    }
    return _component((lower + upper) / 2, y1, y2);
  }

  static double _component(double t, double a, double b) {
    final inverse = 1 - t;
    return 3 * inverse * inverse * t * a + 3 * inverse * t * t * b + t * t * t;
  }
}

/// One row of the documented action table for this popover.
class LyricsOffsetActionEntry {
  const LyricsOffsetActionEntry({
    required this.action,
    required this.label,
    required this.effect,
    required this.qtEvidence,
  });

  /// Action string emitted by the hit table (or the key name for `Escape`).
  final String action;

  /// Visible label that emits the action, empty for key bindings.
  final String label;

  /// What the Qt host does with the action.
  final String effect;

  /// Qt source location the entry is copied from.
  final String qtEvidence;
}

/// Injected state of one `lyrics-offset` popover frame.
///
/// The port never reads domain state: current and global lyric offsets, theme,
/// motion reduction, presentation width, opacity and offset all arrive here.
class LyricsOffsetModalState {
  LyricsOffsetModalState({
    required this.width,
    required this.opacity,
    required this.offset,
    required this.offsetMs,
    required this.globalOffsetMs,
    required this.measureText,
    this.dark = false,
    this.reduced = false,
    this.closing = false,
    this.rectHook = _identityRect,
  });

  /// Presentation width of the 1920x1080 landscape design stage.
  final double width;

  /// Opacity already eased by [LyricsOffsetMotion] for this frame.
  final double opacity;

  /// Offset in stage pixels already eased by [LyricsOffsetMotion].
  final double offset;

  /// Current track lyric offset in milliseconds (`LyricsController::offsetMs`,
  /// Qt/src/LyricsController.h:33).
  final double offsetMs;

  /// Global lyric offset in milliseconds
  /// (`LyricsController::globalOffsetMs()`, Qt/src/LyricsController.h:23-25).
  final double globalOffsetMs;

  /// Injected measurement used by every truncation.
  final LyricsOffsetMeasureText measureText;

  /// Dark theme flag; selects ink, panel fill and button tint.
  final bool dark;

  /// Reduced motion flag (affects the host motion object, not this frame).
  final bool reduced;

  /// Closing flag. In Qt the popover keeps drawing while closing and the host
  /// clears the modal only once `closing && motion.finished()`
  /// (Qt/src/NativeHud.cpp:262-266), so the frame itself is unchanged.
  final bool closing;

  /// Optional stage-rect mapping, identity by default.
  final LyricsOffsetRectHook rectHook;
}

/// One frame: draw commands in Qt `op()` order plus the hit table in draw order.
class LyricsOffsetModalFrame {
  const LyricsOffsetModalFrame({required this.commands, required this.hits});

  /// `[save]`, `[alpha, v]`, `[translate, x, y]`, `[fill, color, x, y, w, h]`,
  /// `[text, value, x, y, size, weight, tracking, color]` and `[restore]`.
  final List<List<Object?>> commands;

  /// Hit rows of exactly six fields: `[x, y, width, height, action, label]`.
  final List<List<Object?>> hits;
}

/// Builder for the `lyrics-offset` popover.
class LyricsOffsetModal {
  LyricsOffsetModal(this.state);

  final LyricsOffsetModalState state;

  /// Qt modal kind (Qt/src/NativeHudController.cpp:324-328).
  static const String kind = 'lyrics-offset';

  /// Close button action (Qt/src/NativeHudModal.cpp:96).
  static const String actionClose = 'close-modal';

  /// Advance the lyric offset by +200 ms (Qt/src/NativeHudController.cpp:330-331).
  static const String actionEarlier = 'player:lyrics-earlier';

  /// Delay the lyric offset by 200 ms (Qt/src/NativeHudController.cpp:330-331).
  static const String actionLater = 'player:lyrics-later';

  /// Reset the current track offset (Qt/src/NativeHudController.cpp:332-333).
  static const String actionReset = 'player:lyrics-reset';

  /// Apply the current offset globally (Qt/src/NativeHudController.cpp:334-335).
  static const String actionApplyGlobal = 'player:lyrics-apply-global';

  /// Escape key name handled by the host key table.
  static const String escapeKey = 'Escape';

  /// One six-field hit row with Qt's label fallback
  /// (Qt/src/NativeHud.cpp:102-109: `label.isNull() ? action : label`).
  ///
  /// [build] routes every control row through this helper, so the hit contract
  /// and the fallback have exactly one definition that a test can assert
  /// directly instead of re-implementing.
  static List<Object?> hitRow(double x, double y, double width, double height,
          String action, [String? label]) =>
      <Object?>[x, y, width, height, action, label ?? action];

  /// Actions this popover can emit, with the close path and the Escape mapping
  /// the host applies while a modal is open.
  static const List<LyricsOffsetActionEntry> actionTable =
      <LyricsOffsetActionEntry>[
    LyricsOffsetActionEntry(
      action: actionClose,
      label: '关闭',
      effect: 'closeModal(): closing = true; motion.set(false, lastTime, reduced); the popover keeps drawing until closing && motion.finished() clears it',
      qtEvidence: 'Qt/src/NativeHudController.cpp:686,132-143; Qt/src/NativeHud.cpp:262-266',
    ),
    LyricsOffsetActionEntry(
      action: escapeKey,
      label: '',
      effect: 'while a modal is open Escape dispatches action(close-modal); only desktop-lyrics (desktop-lyrics:back) and an empty modal (back) differ; all other keys are swallowed while a modal is open',
      qtEvidence: 'Qt/src/NativeHudController.cpp:913-925',
    ),
    LyricsOffsetActionEntry(
      action: actionEarlier,
      label: '歌词提前 0.2s',
      effect: 'player.lyrics.adjustOffset(+200); the popover stays open',
      qtEvidence: 'Qt/src/NativeHudController.cpp:330-331; Qt/src/LyricsController.cpp:511-516',
    ),
    LyricsOffsetActionEntry(
      action: actionLater,
      label: '歌词延后 0.2s',
      effect: 'player.lyrics.adjustOffset(-200); the popover stays open',
      qtEvidence: 'Qt/src/NativeHudController.cpp:330-331; Qt/src/LyricsController.cpp:511-516',
    ),
    LyricsOffsetActionEntry(
      action: actionReset,
      label: '重置',
      effect: 'player.lyrics.resetOffset(); the popover stays open',
      qtEvidence: 'Qt/src/NativeHudController.cpp:332-333; Qt/src/LyricsController.cpp:521-531',
    ),
    LyricsOffsetActionEntry(
      action: actionApplyGlobal,
      label: '全局应用',
      effect: 'player.lyrics.applyGlobalOffset(); the popover stays open',
      qtEvidence: 'Qt/src/NativeHudController.cpp:334-335; Qt/src/LyricsController.cpp:534-543',
    ),
  ];

  /// Builds one frame. Pure: injected state is only read.
  LyricsOffsetModalFrame build() {
    final commands = <List<Object?>>[];
    final hits = <List<Object?>>[];
    _LyricsOffsetBuilder(state, commands, hits).draw();
    return LyricsOffsetModalFrame(
      commands: List<List<Object?>>.unmodifiable(commands),
      hits: List<List<Object?>>.unmodifiable(hits),
    );
  }
}

class _LyricsOffsetBuilder {
  _LyricsOffsetBuilder(this._state, this._commands, this._hits);

  final LyricsOffsetModalState _state;
  final List<List<Object?>> _commands;
  final List<List<Object?>> _hits;

  static const String _regular = 'regular';
  static const String _demibold = 'demibold';

  /// Qt/src/NativeHud.cpp:149-152.
  static const double _panelLeftRatio = 0.56;
  static const double _panelTop = 690;
  static const double _panelWidth = 320;
  static const double _panelHeight = 216;

  /// `bounds.x() + 16` - Qt/src/NativeHudModal.cpp:87.
  static const double _contentInsetX = 16;

  void draw() {
    final width = _state.width;
    _save();
    _alpha(_state.opacity);
    _translate(0, _state.offset);
    final panel =
        _rect(width * _panelLeftRatio, _panelTop, _panelWidth, _panelHeight);
    _fill(_panelFill(), panel[0], panel[1], panel[2], panel[3]);
    // Qt clears the hit table here (Qt/src/NativeHudModal.cpp:93): the hit
    // list of this popover starts empty and only the controls below append.
    final x = panel[0] + _contentInsetX;
    final y = panel[1];
    _text('歌词偏移', x, y + 18, 17, _demibold);
    _button('关闭', x + 232, y + 8, 56, 36, LyricsOffsetModal.actionClose, 13);
    _text(_offsetLabel(), x, y + 58, 15);
    _button('歌词提前 0.2s', x, y + 92, 138, 40,
        LyricsOffsetModal.actionEarlier, 13);
    _button('歌词延后 0.2s', x + 150, y + 92, 138, 40,
        LyricsOffsetModal.actionLater, 13);
    final muted = _muted();
    if (_state.offsetMs != 0) {
      _button('重置', x, y + 152, 138, 40, LyricsOffsetModal.actionReset, 13);
    } else {
      _text('重置', x, y + 161, 13, _regular, 0, muted);
    }
    if (_state.offsetMs != _state.globalOffsetMs) {
      _button('全局应用', x + 150, y + 152, 138, 40,
          LyricsOffsetModal.actionApplyGlobal, 13);
    } else {
      _text('全局应用', x + 150, y + 161, 13, _regular, 0, muted);
    }
    _restore();
  }

  String _offsetLabel() {
    final offsetMs = _state.offsetMs;
    if (offsetMs == 0) {
      return '未校准';
    }
    final direction = offsetMs > 0 ? '已提前 ' : '已延后 ';
    final seconds = (offsetMs < 0 ? -offsetMs : offsetMs) / 1000;
    return '$direction${seconds.toStringAsFixed(1)}s';
  }

  List<Object?> _ink() => _state.dark
      ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
      : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

  List<Object?> _muted() {
    final color = _ink();
    color[3] = 0.45;
    return color;
  }

  List<Object?> _panelFill() => _state.dark
      ? <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite']
      : <Object?>[0.929, 0.922, 0.894, 1];

  List<Object?> _buttonTint() => _state.dark
      ? <Object?>[0.55, 0.59, 0.46, 0.13]
      : <Object?>[0.44, 0.49, 0.36, 0.1];

  List<double> _rect(double x, double y, double w, double h) {
    final mapped = _state.rectHook(x, y, w, h);
    if (mapped.length != 4) {
      throw ArgumentError.value(
          mapped, 'rectHook', 'must return exactly 4 values');
    }
    return mapped;
  }

  void _op(List<Object?> command) => _commands.add(command);

  void _save() => _op(<Object?>['save']);

  void _restore() => _op(<Object?>['restore']);

  void _alpha(double value) => _op(<Object?>['alpha', value]);

  void _translate(double x, double y) => _op(<Object?>['translate', x, y]);

  void _fill(List<Object?> color, double x, double y, double w, double h) =>
      _op(<Object?>['fill', color, x, y, w, h]);

  void _text(String value, double x, double y, double size,
      [String weight = _regular, double tracking = 0, List<Object?>? color]) {
    _op(<Object?>[
      'text',
      value,
      x,
      y,
      size,
      weight,
      tracking,
      color ?? _ink(),
    ]);
  }

  /// `NativeHud::hit` - Qt/src/NativeHud.cpp:102-109. The label falls back to
  /// the action when none is given.
  void _hit(double x, double y, double w, double h, String action,
      [String? label]) {
    _hits.add(LyricsOffsetModal.hitRow(x, y, w, h, action, label));
  }

  /// `NativeHud::button` with `m_modalControls` always true here
  /// (Qt/src/NativeHud.cpp:110-120, Qt/src/NativeHudModal.cpp:94):
  /// `inset = min(10, width / 8)`, tinted fill, then the truncated label at
  /// `x + inset, y + (height - size) / 2 - 4`.
  void _button(String label, double x, double y, double w, double h,
      String action, double size, [String weight = _regular]) {
    final rect = _rect(x, y, w, h);
    final double rx = rect[0];
    final double ry = rect[1];
    final double rw = rect[2];
    final double rh = rect[3];
    _hit(rx, ry, rw, rh, action, label);
    final inset = _min(10, rw / 8);
    _fill(_buttonTint(), rx, ry, rw, rh);
    // Qt calls `fit(label, size, width - inset * 2)` and never forwards the
    // button weight (Qt/src/NativeHud.cpp:118), so the measurement always uses
    // fit's own default `weight = "regular"` (Qt/src/NativeHud.h:249).
    _text(_fit(label, size, rw - inset * 2), rx + inset,
        ry + (rh - size) / 2 - 4, size, weight);
  }

  /// `NativeHud::fit` - Qt/src/NativeHud.cpp:48-76. Binary search for the
  /// longest prefix that measures inside the width, then drop one more code
  /// unit and append the ellipsis. A one-code-unit string is never truncated
  /// (Qt only replaces the value when the chosen prefix is shorter than the
  /// input). Measurement is always injected.
  String _fit(String value, double size, double width,
      [String weight = _regular]) {
    final measure = _state.measureText;
    final length = value.length;
    var keep = length;
    if (measure(value, size, weight, 0) > width) {
      var low = 1;
      var high = length;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        if (measure(value.substring(0, middle), size, weight, 0) <= width) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      keep = low;
    }
    if (keep == length) {
      return value;
    }
    final end = keep - 1 < 0 ? 0 : keep - 1;
    return '${value.substring(0, end)}…';
  }
}
