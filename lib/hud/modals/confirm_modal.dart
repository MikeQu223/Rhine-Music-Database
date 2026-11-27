/// Flutter HUD port of the Qt landscape modal `confirm`.
///
/// One-to-one port of `NativeHud::modalDraw`'s generic (full-modal) layer plus
/// its `confirm` branch: Qt/src/NativeHudModal.cpp:80-257, branch at :214-221.
///
/// Everything below is Qt stage pixel data for the 1920x1080 design stage.
/// Strings, sizes, weights, colours, hit order and command order are copied
/// from that source; this file invents no string and no pixel. Portrait layout
/// is not invented either: it can only arrive through the injected
/// [ConfirmModalRectHook], whose default is the identity.
///
/// Host order for `confirm:yes` (Qt/src/NativeHudController.cpp:525-532): the
/// controller first exchanges the stored confirm callback out of the HUD
/// (`std::exchange(m_confirm, {})`), then calls `closeModal()`, then runs that
/// callback. The panel therefore starts its closing transition before the
/// mutation runs. The order lives in the host; this draw model only emits the
/// action string.
///
/// Draw order copied from the C++ source (NativeHudModal.cpp:83-84, :162-174,
/// :198-202, :214-221, :255-256):
/// `save; alpha(opacity); scrim; translate(0, offset); panel; controls; restore`.
///
/// Command ops not emitted by this branch (clip/scale/image/art) are therefore
/// not implemented here: the confirm panel draws only fills and text.
library;

/// Signature of the injected text measurer.
///
/// Mirrors Qt `Glyphs::width(text, size, weight, tracking)`
/// (Qt/src/Glyphs.h:25, Qt/src/Glyphs.cpp:286). `fit()` passes the same
/// arguments Qt passes: `fit` itself measures with tracking 0
/// (Qt/src/NativeHud.cpp:57-67), and `button()` measures label fit with the
/// "regular" weight (Qt/src/NativeHud.cpp:118, where Qt's `fit` default weight
/// applies even when the drawn text is "demibold"). No glyph width is ever
/// hardcoded in this file.
typedef ConfirmModalMeasureText = double Function(
  String text,
  double size,
  String? weight,
  double tracking,
);

/// Signature of the injected portrait hook.
///
/// Receives a landscape Qt stage rectangle `(x, y, w, h)` and returns the four
/// mapped values. The default is the identity, so the 1920x1080 Qt stage
/// coordinates stay exact; no portrait pixel value is invented here. The hook
/// must be affine: text origins are mapped as the zero-size rectangle
/// `(x, y, 0, 0)`, which an affine hook maps to the transformed origin.
typedef ConfirmModalRectHook = List<double> Function(
  double x,
  double y,
  double w,
  double h,
);

List<double> _identityRect(double x, double y, double w, double h) =>
    <double>[x, y, w, h];

/// Qt `UiMotion::SurfaceMotion` (Qt/src/UiMotion.h:24-42,
/// Qt/src/UiMotion.cpp:86-120), used by the HUD for the modal surface.
///
/// Offset starts at 12 (UiMotion.h:32). `set(true, t)` targets opacity 1 and
/// offset 0 over 0.3 s; `set(false, t)` targets opacity 0 and offset 8 over
/// 0.2 s (UiMotion.cpp:105-115). With `reduced` the duration becomes 0 and
/// opacity/offset snap to the target immediately (:109-119). `sample` clamps
/// progress to 0..1, eases with the entering/exiting cubic Bezier of :91-92 and
/// marks itself finished once progress reaches 1 (:95-97).
class ConfirmModalMotion {
  /// Current interpolated surface opacity; Qt starts at 0 (UiMotion.h:31).
  double opacity = 0;

  /// Current vertical offset in Qt stage pixels; Qt starts at 12
  /// (UiMotion.h:32).
  double offset = 12;

  /// Remaining transition length in seconds; 0 means settled/finished
  /// (UiMotion.h:28-33, UiMotion.cpp:95-97).
  double duration = 0;

  double _fromOpacity = 0;
  double _fromOffset = 12;
  double _targetOpacity = 0;
  double _targetOffset = 12;
  double _start = 0;
  bool _entering = true;

  /// Qt `finished()` is exactly `duration == 0` (UiMotion.h:28-30).
  bool get finished => duration == 0;

  /// Qt `SurfaceMotion::sample` (UiMotion.cpp:86-98).
  void sample(double time) {
    if (duration <= 0) {
      return;
    }
    final double progress = ((time - _start) / duration).clamp(0.0, 1.0).toDouble();
    final double amount = _bezier(
      progress,
      _entering ? 0.22 : 0.4,
      _entering ? 1.0 : 0.0,
      _entering ? 0.36 : 1.0,
      1.0,
    );
    opacity = _fromOpacity + (_targetOpacity - _fromOpacity) * amount;
    offset = _fromOffset + (_targetOffset - _fromOffset) * amount;
    if (progress >= 1) {
      duration = 0;
    }
  }

  /// Qt `SurfaceMotion::set` (UiMotion.cpp:101-120): samples the running
  /// transition first so a retarget continues from the current values.
  void set(bool shown, double time, [bool reduced = false]) {
    sample(time);
    _fromOpacity = opacity;
    _fromOffset = offset;
    _targetOpacity = shown ? 1.0 : 0.0;
    _targetOffset = shown ? 0.0 : 8.0;
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

  /// Qt `bezier(x, x1, y1, x2, y2)` (UiMotion.cpp:7-22): 24 bisection steps on
  /// the x component, then the y component at the found parameter.
  static double _bezier(double x, double x1, double y1, double x2, double y2) {
    double lower = 0;
    double upper = 1;
    for (int i = 0; i < 24; ++i) {
      final double t = (lower + upper) / 2;
      if (_component(t, x1, x2) < x) {
        lower = t;
      } else {
        upper = t;
      }
    }
    return _component((lower + upper) / 2, y1, y2);
  }

  /// Qt `component(t, a, b)` inside UiMotion.cpp:8-10.
  static double _component(double t, double a, double b) =>
      3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
}

/// Flattened draw result of one confirm-modal frame.
///
/// [commands] use the Qt `op()` shapes and [hits] use the six-field hit order
/// `[x, y, width, height, action, label]` (label falls back to the action when
/// none is drawn). Hits are appended in draw order (Qt/src/NativeHud.cpp:102-120).
class ConfirmModalFrame {
  /// Wraps one built frame; the lists are freshly allocated per build.
  const ConfirmModalFrame({required this.commands, required this.hits});

  /// Draw commands in Qt draw order.
  final List<List<Object?>> commands;

  /// Hit rectangles in Qt draw order, six fields each.
  final List<List<Object?>> hits;
}

/// The Qt landscape modal `confirm`: "CONFIRM DELETE" / "删除确认".
///
/// Opened by `local:remove` (title "移除索引：<root name>") and
/// `music:delete-playlist` (title "删除歌单：<title>")
/// (Qt/src/NativeHudController.cpp:545, Qt/src/NativeHudMusic.cpp:323); both
/// paths are the generic full-modal path, so the scrim, the panel and the
/// shared header are drawn exactly as in Qt.
class ConfirmModal {
  /// Creates the injected frame state. Nothing here is derived from domain
  /// objects: every value arrives from the host.
  ConfirmModal({
    required this.width,
    required this.confirmTitle,
    required this.measureText,
    this.dark = false,
    this.reduced = false,
    this.closing = false,
    this.search = false,
    this.opacity = 1.0,
    this.offset = 0.0,
    this.isLocal = false,
    this.isSiren = false,
    this.providerName = '',
    ConfirmModalRectHook? rectHook,
  }) : rectHook = rectHook ?? _identityRect;

  /// Generic modal top edge, `bounds.y()` (Qt/src/NativeHud.cpp:158).
  static const double modalTop = 122;

  /// Framebuffer height covered by the scrim (Qt/src/NativeHudModal.cpp:163).
  static const double stageHeight = 1080;

  /// Generic modal maximum width (Qt/src/NativeHud.cpp:153).
  static const double modalMaxWidth = 1260;

  /// Generic modal height, both in `modalBounds` and in the panel fill
  /// (Qt/src/NativeHud.cpp:158, Qt/src/NativeHudModal.cpp:171).
  static const double modalHeight = 836;

  /// `width - 100` inside `modalBounds` (Qt/src/NativeHud.cpp:153).
  static const double modalHorizontalMargin = 100;

  /// Category segment of the shared header line
  /// (Qt/src/NativeHudModal.cpp:188; `confirm` keeps the default).
  static const String category = 'MUSIC DIRECTORY';

  /// `modalTitle("confirm")` (Qt/src/NativeHudModal.cpp:37).
  static const String title = 'CONFIRM DELETE';

  /// `modalSubtitle("confirm")` (Qt/src/NativeHudModal.cpp:62).
  static const String subtitle = '删除确认';

  /// Shared header back button label (Qt/src/NativeHudModal.cpp:199).
  static const String backLabel = '← 返回';

  /// Confirm button label (Qt/src/NativeHudModal.cpp:220).
  static const String confirmLabel = '确认删除';

  /// Cancel button label (Qt/src/NativeHudModal.cpp:221).
  static const String cancelLabel = '取消';

  /// Action strings this modal emits, in Qt source order
  /// (Qt/src/NativeHudModal.cpp:220-221).
  static const List<String> actions = <String>['confirm:yes', 'close-modal'];

  /// Qt maps Escape to `action("close-modal")` whenever a modal is open
  /// (Qt/src/NativeHudController.cpp:913-921; the empty-modal "back" and
  /// "desktop-lyrics:back" branches do not apply to this panel). The host keeps
  /// that key table; this constant is the entry it would dispatch for this
  /// modal.
  static const String escapeAction = 'close-modal';

  /// Stage width in Qt coordinates (the host passes the 1920 design stage).
  final double width;

  /// `NativeHud::dark`; selects every colour below.
  final bool dark;

  /// `NativeHud::reduced`. `modalDraw` never branches on it
  /// (Qt/src/NativeHudModal.cpp:80-257); it only reaches `motion.set` in the
  /// host, so it changes no command here.
  final bool reduced;

  /// `NativeHud::closing`. Also unused by `modalDraw`: the host starts the
  /// closing transition and drops the panel when the motion finishes
  /// (Qt/src/NativeHud.cpp:262-266). Carried because the host injects it.
  final bool closing;

  /// The generic layer computes `search = modal == "search"`
  /// (Qt/src/NativeHudModal.cpp:162). `confirm` never equals "search", so this
  /// is false in practice; the field keeps the shared scrim formula exact.
  final bool search;

  /// `NativeHud::motion.opacity` (Qt/src/NativeHudModal.cpp:84).
  final double opacity;

  /// `NativeHud::motion.offset` (Qt/src/NativeHudModal.cpp:166).
  final double offset;

  /// `NativeHud::confirmTitle`, set by the two openers.
  final String confirmTitle;

  /// `MusicLibrary::isLocal()` (Qt/src/NativeHudModal.cpp:216).
  final bool isLocal;

  /// `MusicLibrary::isSiren()` (Qt/src/NativeHudModal.cpp:217).
  final bool isSiren;

  /// `MusicLibrary::providerName()` (Qt/src/NativeHudModal.cpp:218).
  final String providerName;

  /// Injected glyph measurement; see [ConfirmModalMeasureText].
  final ConfirmModalMeasureText measureText;

  /// Injected portrait hook; identity by default (see [ConfirmModalRectHook]).
  final ConfirmModalRectHook rectHook;

  /// Builds the frame. Pure: allocates the two output lists, mutates nothing.
  ConfirmModalFrame build() {
    final List<List<Object?>> commands = <List<Object?>>[];
    final List<List<Object?>> hits = <List<Object?>>[];
    final List<Object?> ink = _ink();

    // NativeHud::modalBounds generic branch (Qt/src/NativeHud.cpp:153-158):
    // modalWidth = min(1260, width - 100); left = (width - modalWidth) / 2;
    // bounds = {left, 122, modalWidth, 836}.
    final double available = width - modalHorizontalMargin;
    final double modalWidth = available < modalMaxWidth ? available : modalMaxWidth;
    final double x = (width - modalWidth) / 2;
    const double y = modalTop;
    final double usable = modalWidth;

    // Qt/src/NativeHudModal.cpp:83-84.
    _save(commands);
    _alpha(commands, opacity);
    // Scrim, generic path only (Qt/src/NativeHudModal.cpp:162-165).
    _fill(commands, _scrim(), 0.0, 0.0, width, stageHeight);
    // Qt/src/NativeHudModal.cpp:166.
    _translate(commands, 0.0, offset);
    // Panel fill (Qt/src/NativeHudModal.cpp:171-172): full 836 height.
    _fill(commands, _panel(), x, y, usable, modalHeight);

    // Shared header (Qt/src/NativeHudModal.cpp:198-202). "confirm" is not
    // "settings", so the header text is size 11 and the subtitle size 15.
    _text(
      commands,
      'RHINE LAB / MUSIC DATABASE / $category',
      x + 53,
      y + 37,
      11,
      'regular',
      0,
      ink,
    );
    // "confirm" is not "desktop-lyrics", so the back button closes the modal.
    _button(commands, hits, backLabel, x + usable - 220, y + 18, 167, 54,
        'close-modal', 20, 'demibold');
    _text(commands, title, x + 53, y + 91, 38, 'demibold', 0, ink);
    _text(commands, subtitle, x + 53, y + 147, 15, 'regular', 0, ink);

    // confirm branch (Qt/src/NativeHudModal.cpp:214-221).
    _limited(commands, confirmTitle, x + 53, y + 260, 24, usable - 106, 'demibold');
    _text(commands, _body(), x + 53, y + 330, 16, 'regular', 0, ink);
    _button(commands, hits, confirmLabel, x + 53, y + 450, 180, 45, 'confirm:yes', 16);
    _button(commands, hits, cancelLabel, x + 270, y + 450, 150, 45, 'close-modal', 16);

    // Qt/src/NativeHudModal.cpp:255-256.
    _restore(commands);
    return ConfirmModalFrame(commands: commands, hits: hits);
  }

  /// Body sentence (Qt/src/NativeHudModal.cpp:216-219).
  String _body() {
    if (isLocal) {
      return '只移除本地索引，磁盘音乐文件保持原样。';
    }
    if (isSiren) {
      return '只删除本机歌单，不会同步到塞壬唱片。';
    }
    return '此操作将同步至$providerName。';
  }

  /// `ink()` (Qt/src/NativeHud.cpp:10-15).
  List<Object?> _ink() => dark
      ? <Object?>[0.92, 0.92, 0.92, 1.0, 'calibratedWhite']
      : <Object?>[0.08, 0.085, 0.075, 1.0, 'calibratedRGB'];

  /// `ink()` with alpha 0.45, the muted text colour (Qt/src/NativeHudModal.cpp:106-107).
  /// The confirm branch draws no muted text, so this stays part of the shared
  /// modal primitive set every modal file exposes.
  // ignore: unused_element
  List<Object?> _muted() {
    final List<Object?> color = _ink();
    color[3] = 0.45;
    return color;
  }

  /// Panel fill (Qt/src/NativeHudModal.cpp:171-172).
  List<Object?> _panel() => dark
      ? <Object?>[0.15, 0.15, 0.15, 1.0, 'calibratedWhite']
      : <Object?>[0.929, 0.922, 0.894, 1.0];

  /// Modal-control button tint (Qt/src/NativeHud.cpp:116).
  List<Object?> _tint() => dark
      ? <Object?>[0.55, 0.59, 0.46, 0.13]
      : <Object?>[0.44, 0.49, 0.36, 0.1];

  /// Scrim fill (Qt/src/NativeHudModal.cpp:163-165): the alpha is
  /// `search ? 0.15 : 0.6` in dark and `search ? 0.12 : 0.45` in light.
  List<Object?> _scrim() {
    if (dark) {
      return <Object?>[
        17.0 / 255.0,
        24.0 / 255.0,
        27.0 / 255.0,
        search ? 0.15 : 0.6,
      ];
    }
    return <Object?>[
      227.0 / 255.0,
      224.0 / 255.0,
      215.0 / 255.0,
      search ? 0.12 : 0.45,
    ];
  }

  void _save(List<List<Object?>> out) => out.add(<Object?>['save']);

  void _restore(List<List<Object?>> out) => out.add(<Object?>['restore']);

  void _alpha(List<List<Object?>> out, double value) =>
      out.add(<Object?>['alpha', value]);

  void _translate(List<List<Object?>> out, double dx, double dy) =>
      out.add(<Object?>['translate', dx, dy]);

  /// `fill(x, y, width, height, color)` (Qt/src/NativeHud.cpp:37-39).
  void _fill(List<List<Object?>> out, List<Object?> color, double x, double y,
      double w, double h) {
    final List<double> rect = rectHook(x, y, w, h);
    out.add(<Object?>['fill', color, rect[0], rect[1], rect[2], rect[3]]);
  }

  /// `text(value, x, y, size, weight, tracking, color)`
  /// (Qt/src/NativeHud.cpp:40-43). The origin is mapped through the same hook
  /// as the rectangles, as a zero-size rectangle.
  void _text(List<List<Object?>> out, String value, double x, double y,
      double size, String weight, double tracking, List<Object?> color) {
    final List<double> point = rectHook(x, y, 0.0, 0.0);
    out.add(<Object?>['text', value, point[0], point[1], size, weight, tracking, color]);
  }

  /// `hit(...)` (Qt/src/NativeHud.cpp:102-109): six fields in Qt order, the
  /// label falling back to the action when none is drawn.
  void _hit(List<List<Object?>> hits, double x, double y, double w, double h,
      String action, [String? label]) {
    final List<double> rect = rectHook(x, y, w, h);
    hits.add(<Object?>[rect[0], rect[1], rect[2], rect[3], action, label ?? action]);
  }

  /// `fit(value, size, width, weight)` (Qt/src/NativeHud.cpp:48-76): binary
  /// search for the longest prefix that fits, then drop one more code unit and
  /// append "…". `QString::size()/left()` count UTF-16 code units, which is
  /// what Dart `String.length/substring` counts as well.
  String _fit(String value, double size, double width, String? weight) {
    int length = value.length;
    if (measureText(value, size, weight, 0) > width) {
      int low = 1;
      int high = length;
      while (low < high) {
        final int middle = (low + high + 1) ~/ 2;
        if (measureText(value.substring(0, middle), size, weight, 0) <= width) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      length = low;
    }
    if (length == value.length) {
      return value;
    }
    final int keep = length - 1 < 0 ? 0 : length - 1;
    return '${value.substring(0, keep)}…';
  }

  /// `limited(value, x, y, size, width, weight)` (Qt/src/NativeHud.cpp:77-79).
  void _limited(List<List<Object?>> out, String value, double x, double y,
      double size, double width, String weight) {
    _text(out, _fit(value, size, width, weight), x, y, size, weight, 0, _ink());
  }

  /// `rule(x, y, width, opacity)` (Qt/src/NativeHud.cpp:125-129). The confirm
  /// branch draws no rule; kept because it is part of the shared primitive set
  /// every modal file exposes.
  // ignore: unused_element
  void _rule(List<List<Object?>> out, double x, double y, double width,
      double opacity) {
    final List<Object?> color = _ink();
    color[3] = opacity;
    _fill(out, color, x, y, width, 1);
  }

  /// `button(label, x, y, w, h, action, size, weight)`
  /// (Qt/src/NativeHud.cpp:110-120) for the modal-controls state, which is
  /// always on inside `modalDraw`: hit first, then the tint, then the label at
  /// `x + inset` and `y + (h - size) / 2 - 4` with `inset = min(10, w / 8)`.
  /// The label is fitted to `w - inset * 2` with Qt's default "regular"
  /// measurement weight and drawn with the requested weight.
  void _button(List<List<Object?>> out, List<List<Object?>> hits, String label,
      double x, double y, double w, double h, String action, double size,
      [String weight = 'regular']) {
    _hit(hits, x, y, w, h, action, label);
    final double inset = w / 8 < 10 ? w / 8 : 10;
    _fill(out, _tint(), x, y, w, h);
    _text(out, _fit(label, size, w - inset * 2, 'regular'), x + inset,
        y + (h - size) / 2 - 4, size, weight, 0, _ink());
  }
}
