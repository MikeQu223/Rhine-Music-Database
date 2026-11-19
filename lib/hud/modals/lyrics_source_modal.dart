/// Qt HUD "lyrics-source" popover — a 1:1 port of the landscape stage branch.
///
/// Every number and string below traces back to the Qt sources:
///  * popover branch:      Qt/src/NativeHudModal.cpp:142-161
///  * outer save / alpha:  Qt/src/NativeHudModal.cpp:83-84
///  * popover bounds:      Qt/src/NativeHud.cpp:145-148
///  * primitives (ink / hit / button / fit / text / fill): Qt/src/NativeHud.cpp:10-129
///  * surface motion:      Qt/src/UiMotion.h:24-42, Qt/src/UiMotion.cpp:86-120
///  * cubic-bezier solver: Qt/src/UiMotion.cpp:7-22
///  * action + key table:  Qt/src/NativeHudController.cpp:336-345, :913-925
///
/// The library imports nothing, performs no I/O, keeps every domain value
/// (selected source, text measurement, viewport remap) injected, and never
/// invents portrait pixels: [LyricsSourceRectHook] defaults to the identity, so
/// the emitted coordinates stay exactly the Qt 1920x1080 stage coordinates.
library;

// Injected hooks — contract rules 4 and 5

/// Measures [text] at [size] / [weight] with [tracking], in stage pixels.
///
/// Mirrors the m_glyphs->width(...) call sites of NativeHud::fit()
/// (Qt/src/NativeHud.cpp:57-62); this port never guesses glyph widths.
typedef LyricsSourceMeasureText = double Function(
  String text,
  double size,
  String? weight,
  double tracking,
);

/// Remaps one landscape stage rectangle to the live viewport.
///
/// The default is the identity, so the popover keeps the exact Qt stage
/// coordinates (1920x1080 design stage) and no portrait pixel value is invented.
typedef LyricsSourceRectHook = List<double> Function(
  double x,
  double y,
  double w,
  double h,
);

/// Landscape default: pass the Qt stage rectangle through untouched.
List<double> _identityRect(double x, double y, double w, double h) =>
    <double>[x, y, w, h];

/// std::clamp — Qt/src/UiMotion.cpp:90.
double _clamp(double value, double lower, double upper) {
  if (value < lower) {
    return lower;
  }
  if (value > upper) {
    return upper;
  }
  return value;
}

/// std::min(10.0, width / 8) — Qt/src/NativeHud.cpp:113.
double _minimum(double a, double b) => a < b ? a : b;

// Colours, exactly as the Qt sources build them

/// panelFill, dark — Qt/src/NativeHudModal.cpp:146.
const List<Object?> _darkPanelFill = <Object?>[
  0.15,
  0.15,
  0.15,
  1,
  'calibratedWhite',
];

/// panelFill, light — Qt/src/NativeHudModal.cpp:146 (plain calibrated RGB).
const List<Object?> _lightPanelFill = <Object?>[0.929, 0.922, 0.894, 1];

/// Modal-control button tint, dark — Qt/src/NativeHud.cpp:116.
const List<Object?> _darkButtonTint = <Object?>[0.55, 0.59, 0.46, 0.13];

/// Modal-control button tint, light — Qt/src/NativeHud.cpp:116.
const List<Object?> _lightButtonTint = <Object?>[0.44, 0.49, 0.36, 0.1];

/// ink(), dark — Qt/src/NativeHud.cpp:11-12.
const List<Object?> _darkInk = <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite'];

/// ink(), light — Qt/src/NativeHud.cpp:13-14.
const List<Object?> _lightInk = <Object?>[
  0.08,
  0.085,
  0.075,
  1,
  'calibratedRGB',
];

// Motion — contract rule 6, Qt/src/UiMotion.h:24-42 and UiMotion.cpp:86-120

/// UiMotion::SurfaceMotion: the fade/slide every HUD surface shares.
///
/// Qt seeds the surface fully transparent and slid 12 px down
/// (Qt/src/UiMotion.h:31-33). set() retargets after sampling the running
/// transition, so a fast open/close continues from the current opacity/offset
/// instead of jumping.
class LyricsSourceMotion {
  /// Current opacity, 0..1.
  double opacity = 0;

  /// Current vertical offset in stage pixels; the popover draws at +offset.
  double offset = 12;

  /// Remaining transition length in seconds; 0 means settled.
  double duration = 0;

  double _fromOpacity = 0;
  double _fromOffset = 12;
  double _targetOpacity = 0;
  double _targetOffset = 12;
  double _start = 0;
  bool _entering = true;

  /// SurfaceMotion::finished() — Qt/src/UiMotion.h:28-30.
  bool get finished => duration == 0;

  /// SurfaceMotion::sample() — Qt/src/UiMotion.cpp:86-98.
  ///
  /// progress = clamp((time - start) / duration, 0, 1);
  /// amount   = bezier(progress, entering ? 0.22 : 0.4, entering ? 1 : 0,
  ///                   entering ? 0.36 : 1, 1);
  /// opacity / offset lerp from the captured origin to the target.
  void sample(double time) {
    if (duration <= 0) {
      return;
    }
    final double progress = _clamp((time - _start) / duration, 0, 1);
    final double amount = _bezier(
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

  /// SurfaceMotion::set() — Qt/src/UiMotion.cpp:100-120.
  ///
  /// shown:  target opacity 1, target offset 0, duration 0.3 (entering curve).
  /// hidden: target opacity 0, target offset 8, duration 0.2 (leaving curve).
  /// reduced: duration 0 and both values snap to the target immediately.
  void set(bool shown, double time, {bool reduced = false}) {
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
}

/// bezier() — Qt/src/UiMotion.cpp:7-22: 24-step bisection on the x component,
/// then the y component at the bracketed t. Reproduced operation for operation
/// so the port lands on the same doubles as Qt.
double _bezier(double x, double x1, double y1, double x2, double y2) {
  double lower = 0;
  double upper = 1;
  for (int i = 0; i < 24; ++i) {
    final double t = (lower + upper) / 2;
    if (_bezierComponent(t, x1, x2) < x) {
      lower = t;
    } else {
      upper = t;
    }
  }
  return _bezierComponent((lower + upper) / 2, y1, y2);
}

/// component() — Qt/src/UiMotion.cpp:8-10.
double _bezierComponent(double t, double a, double b) =>
    3.0 * (1.0 - t) * (1.0 - t) * t * a +
    3.0 * (1.0 - t) * t * t * b +
    t * t * t;

// Action + key table — Qt/src/NativeHudController.cpp:336-345, :913-925

/// "player:lyrics-source:" + sources[index] — Qt/src/NativeHudModal.cpp:156.
const String lyricsSourceSelectPrefix = 'player:lyrics-source:';

/// The popover owns no dismiss button and no outside catcher; Qt closes it
/// through the shared "close-modal" action (Qt/src/NativeHudController.cpp:919),
/// which resolves as closeModal().
const String lyricsSourceCloseAction = 'close-modal';

/// The action that toggles this popover — Qt/src/NativeHudController.cpp:336-341.
const String lyricsSourceToggleAction = 'player:lyrics-sources';

/// Qt order of the five popover rows — Qt/src/NativeHudModal.cpp:149.
///
/// Row order only: the action table never validates against this list (the
/// provider whitelist is domain data owned by LyricsController —
/// Qt/src/LyricsController.cpp:13, :231-234).
const List<String> lyricsSourceIds = <String>[
  'auto',
  'local',
  'netease',
  'qq',
  'kugou',
];

/// Effect name for the toggle action (Qt/src/NativeHudController.cpp:337-341).
const String lyricsSourceEffectToggle = 'toggle';

/// Effect name for "close-modal".
const String lyricsSourceEffectClose = 'close';

/// Effect name for a source selection: apply it, reset browse, close
/// (Qt/src/NativeHudController.cpp:342-345).
const String lyricsSourceEffectSelect = 'select';

/// Resolves one action of this popover to its effect, mirroring Qt:
///
///  * [lyricsSourceToggleAction] toggles: it closes the popover when it is
///    already open and not closing, otherwise it opens it.
///  * `player:lyrics-source` — optionally followed by `:<id>` —
///    selects that source, resets the lyrics browse state and closes the
///    popover. Qt only matches `parts.value(1) == "lyrics-source"` together
///    with isLocal() (Qt/src/NativeHudController.cpp:342-345) and hands
///    `parts.value(2)` straight to selectLocalSource; the id is validated
///    nowhere except inside LyricsController (Qt/src/LyricsController.cpp:231-234),
///    where an unknown or missing id merely turns the assignment into a no-op
///    while browse is still reset and the popover still closed.
///  * [lyricsSourceCloseAction] closes the popover.
///
/// Any other action returns null, matching Qt falling through the else-if chain
/// without matching.
String? lyricsSourceActionEffect(String action) {
  if (action == lyricsSourceToggleAction) {
    return lyricsSourceEffectToggle;
  }
  if (action == lyricsSourceCloseAction) {
    return lyricsSourceEffectClose;
  }
  // Qt: parts = action.split(':') (NativeHudController.cpp:485), name =
  // parts.value(1) (:307), and the branch at :342 keys on that name alone. No
  // id membership test happens in the UI layer — the provider list is domain
  // data owned by LyricsController (Qt/src/LyricsController.cpp:13, :232).
  final List<String> parts = action.split(':');
  if (parts.length >= 2 && parts[0] == 'player' && parts[1] == 'lyrics-source') {
    return lyricsSourceEffectSelect;
  }
  return null;
}

/// The source id Qt hands to `LyricsController::selectLocalSource` — the raw
/// third segment, `parts.value(2)` (Qt/src/NativeHudController.cpp:343),
/// passed through unchanged and `''` when the action has no third segment
/// (Qt's null QString behaves the same: the domain guard rejects it and the
/// popover still resets and closes). Deliberately not validated here.
String lyricsSourceSelectId(String action) {
  final List<String> parts = action.split(':');
  return parts.length >= 3 ? parts[2] : '';
}

/// Key mapping while this popover is open — Qt/src/NativeHudController.cpp:913-925.
///
/// Escape maps to "close-modal" (the modal is not desktop-lyrics, so the second
/// branch of :914-920 is not taken). Every other key is swallowed by
/// "if (!modal.isEmpty()) return;" at :923-925, so null is the honest answer:
/// there is no Tab focus order and no arrow scroll in this popover.
String? lyricsSourceKeyAction(String key) =>
    key == 'Escape' ? lyricsSourceCloseAction : null;

// Frame — contract rule 7

/// One frame of the popover: the Qt op stream plus the hit table.
class LyricsSourceModalFrame {
  const LyricsSourceModalFrame({required this.commands, required this.hits});

  /// Qt commands, in op() order — Qt/src/NativeHud.cpp:16-43.
  final List<List<Object?>> commands;

  /// Qt hits, in draw order, six fields each — Qt/src/NativeHud.cpp:102-109.
  final List<List<Object?>> hits;
}

// The modal — contract rule 7 entry point

/// The Qt "lyrics-source" popover (NativeHud::modalDraw branch at
/// Qt/src/NativeHudModal.cpp:142-161).
///
/// This is a popover, not a generic dialog: it draws no scrim and no category
/// header, it never installs an outside catcher, and all five rows are plain
/// button() calls with the modal-control tint.
class LyricsSourceModal {
  LyricsSourceModal({
    required this.width,
    required this.measureText,
    this.dark = false,
    this.reduced = false,
    this.closing = false,
    this.opacity = 0,
    this.offset = 12,
    this.localSource = 'auto',
    this.rectHook = _identityRect,
  });

  /// Landscape stage width in Qt design pixels (NativeHud::width).
  final double width;

  /// Measures every fit() candidate; never guessed.
  final LyricsSourceMeasureText measureText;

  /// Qt dark: selects ink, panel fill and button tint.
  final bool dark;

  /// Qt reduced: the host forwards it to [LyricsSourceMotion.set], where it
  /// collapses the duration to 0 (Qt/src/UiMotion.cpp:109-119). The frame
  /// itself is identical in both modes.
  final bool reduced;

  /// Qt closing: the panel keeps drawing unchanged until the motion settles
  /// ("if (closing && motion.finished())" at Qt/src/NativeHud.cpp:263-266), so
  /// this flag does not alter the frame.
  final bool closing;

  /// Qt motion.opacity — Qt/src/NativeHudModal.cpp:84.
  final double opacity;

  /// Qt motion.offset — Qt/src/NativeHudModal.cpp:144.
  final double offset;

  /// Qt player.lyrics.localSource; only an exactly equal id gets the check
  /// prefix (Qt/src/NativeHudModal.cpp:152-154). Injected, never derived.
  final String localSource;

  /// Optional viewport remap; identity by default (contract rule 5).
  final LyricsSourceRectHook rectHook;

  /// Builds one frame. Pure: fresh lists on every call, no field is mutated.
  LyricsSourceModalFrame build() {
    final List<List<Object?>> commands = <List<Object?>>[];
    final List<List<Object?>> hits = <List<Object?>>[];

    // NativeHudModal.cpp:83-84 — modalDraw() opens with save(); alpha(opacity).
    commands.add(const <Object?>['save']);
    commands.add(<Object?>['alpha', opacity]);

    // NativeHud.cpp:145-148 — bounds = {width * 0.56 + 156, 674, 232, 232}.
    // No scrim and no generic header: the scrim at NativeHudModal.cpp:163-165 is
    // only reached by the full-modal path below this branch.
    final double stagePanelX = width * 0.56 + 156;
    final List<double> panel = rectHook(stagePanelX, 674, 232, 232);

    // NativeHudModal.cpp:144 — translate(0, motion.offset). Qt translate() takes
    // doubles (NativeHud.h:241), so the x operand is 0.0 like the sibling
    // popovers (detail_sort_modal.dart:414), never the int 0.
    commands.add(<Object?>['translate', 0.0, offset]);

    // NativeHudModal.cpp:145-146 — fill(bounds, panelFill).
    _fill(commands, panel[0], panel[1], panel[2], panel[3],
        dark ? _darkPanelFill : _lightPanelFill);

    // NativeHudModal.cpp:147 — hits = {}: the base layer receives no events.
    // There is deliberately no full-screen catcher here (contrast detail-sort at
    // NativeHudModal.cpp:128); an outside tap simply matches nothing.

    // NativeHudModal.cpp:149-157 — five tinted rows, 42 px tall, 10 px inset.
    // Rect transform: Qt computes every row from the RAW modal bounds (:155) and
    // applies exactly one draw transform, so each row is derived from the stage
    // numbers here and mapped exactly once — never from the already-mapped
    // panel, which would apply the viewport hook twice and let the rows drift
    // out of the panel and out of their own hit rects (house convention:
    // detail_sort_modal.dart:429-443 derives rows from the un-mapped bounds[]
    // and maps once inside _button).
    for (int index = 0; index < lyricsSourceIds.length; ++index) {
      final String id = lyricsSourceIds[index];
      final String label =
          (localSource == id ? '✓ ' : '') + _lyricsSourceLabels[index];
      final List<double> row = rectHook(
        stagePanelX + 10,
        674 + 11 + index * 42,
        232 - 20,
        42,
      );
      _button(commands, hits, label, row[0], row[1], row[2], row[3],
          '$lyricsSourceSelectPrefix$id', 15);
    }

    // NativeHudModal.cpp:158-159 — m_modalControls = false; restore().
    commands.add(const <Object?>['restore']);
    return LyricsSourceModalFrame(commands: commands, hits: hits);
  }

  /// NativeHud::hit() — Qt/src/NativeHud.cpp:102-109.
  ///
  /// Field order is fixed: x, y, width, height, action, label; a null label
  /// falls back to the action.
  void _hit(List<List<Object?>> hits, double x, double y, double width,
      double height, String action, [String? label]) {
    hits.add(<Object?>[x, y, width, height, action, label ?? action]);
  }

  /// NativeHud::fill() — Qt/src/NativeHud.cpp:37-39.
  void _fill(List<List<Object?>> commands, double x, double y, double width,
      double height, List<Object?> color) {
    commands.add(<Object?>['fill', color, x, y, width, height]);
  }

  /// NativeHud::text() — Qt/src/NativeHud.cpp:40-43.
  ///
  /// [text, value, x, y, size, weight, tracking, color]; the colour falls back
  /// to ink() exactly like Qt's empty-array default.
  void _text(List<List<Object?>> commands, String value, double x, double y,
      double size,
      {String weight = 'regular', double tracking = 0, List<Object?>? color}) {
    commands.add(<Object?>[
      'text',
      value,
      x,
      y,
      size,
      weight,
      tracking,
      color ?? (dark ? _darkInk : _lightInk),
    ]);
  }

  /// NativeHud::button() with m_modalControls == true —
  /// Qt/src/NativeHud.cpp:110-120.
  ///
  /// The flag is set at NativeHudModal.cpp:148 before the row loop, so all five
  /// rows take the tinted, inset path; it is cleared at :158 after the loop.
  void _button(
    List<List<Object?>> commands,
    List<List<Object?>> hits,
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size, [
    String weight = 'regular',
  ]) {
    _hit(hits, x, y, width, height, action, label);
    final double inset = _minimum(10.0, width / 8);
    _fill(commands, x, y, width, height,
        dark ? _darkButtonTint : _lightButtonTint);
    // Qt calls fit() with fit's own default weight here (NativeHud.cpp:118), so
    // the button weight styles the emitted text op but not the measurement.
    _text(commands, _fit(label, size, width - inset * 2), x + inset,
        y + (height - size) / 2 - 4, size,
        weight: weight);
  }

  /// NativeHud::fit() — Qt/src/NativeHud.cpp:48-76.
  ///
  /// Binary-searches the longest prefix that still fits, drops one further
  /// character and appends the horizontal ellipsis (U+2026). The search runs
  /// over UTF-16 code units, exactly like QString::left(), so surrogate pairs
  /// behave as in Qt.
  String _fit(String value, double size, double width,
      [String weight = 'regular']) {
    if (measureText(value, size, weight, 0) <= width) {
      return value;
    }
    int low = 1;
    int high = value.length;
    while (low < high) {
      final int middle = (low + high + 1) ~/ 2;
      if (measureText(value.substring(0, middle), size, weight, 0) <= width) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final int length = low;
    if (length == value.length) {
      return value;
    }
    final int keep = length - 1 < 0 ? 0 : length - 1;
    return '${value.substring(0, keep)}…';
  }
}

/// Qt labels — Qt/src/NativeHudModal.cpp:150, in sources order.
const List<String> _lyricsSourceLabels = <String>[
  '自动（本地优先）',
  '本地歌词',
  '网易云音乐',
  'QQ 音乐',
  '酷狗音乐',
];
