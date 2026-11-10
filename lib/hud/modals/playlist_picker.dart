/// Flutter port of the Qt landscape `playlist-picker` modal, reproduced 1:1.
///
/// This library is self-contained: it imports nothing (only `dart:core` is used
/// implicitly) and it emits exactly the command/hit lists the Qt HUD emits while
/// `modal == "playlist-picker"`. Every coordinate is a Qt landscape design-stage
/// pixel (1920x1080); no portrait pixel value is invented anywhere — the injected
/// [PlaylistPickerRectHook] is the only placement seam.
///
/// Qt evidence for every number, string and command in this file:
///
/// * Envelope: `Qt/src/NativeHudModal.cpp:81-84` (`save()`, `alpha(motion.opacity)`),
///   scrim `:162-165`, `translate(0, motion.offset)` `:166`, panel fill `:171-172`,
///   hit reset `:173`, `m_modalControls = true` `:174`, then
///   `m_modalControls = false` + `restore()` at `:255-256`.
/// * Bounds: `Qt/src/NativeHud.cpp:153,157,158` —
///   `modalWidth = min(1260, width - 100)`, `left = (width - modalWidth) / 2`,
///   rect `{left, 122, modalWidth, 836}`.
/// * Header: `Qt/src/NativeHudModal.cpp:188` (default category `MUSIC DIRECTORY`),
///   `:198` (category line), `:199-200` (back button), `:201-202` (title, subtitle).
///   Title/subtitle literals: `:36` (`PLAYLIST DIRECTORY`), `:61` (`添加到我的歌单`).
/// * Body: `Qt/src/NativeHudModal.cpp:222-239`.
/// * Primitives: `Qt/src/NativeHud.cpp:10-15` (ink), `:37-39` (fill), `:40-43` (text),
///   `:48-76` (fit), `:77-79` (limited), `:102-109` (hit), `:110-120` (button),
///   `:125-129` (rule), `:19-36` (save/restore/alpha/translate).
/// * Motion: `Qt/src/UiMotion.h:24-42` and `Qt/src/UiMotion.cpp:86-120`; the easing
///   solver is `Qt/src/UiMotion.cpp:7-22`.
/// * Actions/keys: `Qt/src/NativeHudMusic.cpp:255-258` (pager, ±7) and `:352-364`
///   (open / pick), `Qt/src/NativeHudInput.cpp:17,56-58` (wheel, ±1),
///   `Qt/src/NativeHudController.cpp:913-922` (Escape).
library;

/// Measures one text run exactly like Qt `Glyphs::width(text, size, weight)`
/// (the three-argument overload used by `NativeHud::fit`, `Qt/src/NativeHud.cpp:57`).
///
/// [tracking] is passed separately because text commands carry tracking
/// (`Qt/src/NativeHud.cpp:40-43`) while `fit` measures without it; the port never
/// hardcodes glyph widths — truncation and the wrapped expanded detail must call this.
typedef PlaylistPickerMeasureText = double Function(
    String text, double size, String? weight, double tracking);

/// Maps one Qt stage rect to the rect the host actually paints, in this order:
/// `[x, y, width, height]`.
///
/// The default is identity, which keeps every Qt landscape pixel exact. The hook
/// exists for portrait hosts: the port never invents portrait numbers, so a host
/// that re-places the stage does it here. It is applied to the two stage-level
/// rects only (the full-stage scrim and the modal panel), exactly once each; the
/// panel's interior is then authored as Qt's stage offsets from the mapped origin,
/// so applying the hook to interior rects would double-transform them.
typedef PlaylistPickerRectHook = List<double> Function(
    double x, double y, double w, double h);

List<double> _identityRect(double x, double y, double w, double h) =>
    <double>[x, y, w, h];

double _min(double a, double b) => a < b ? a : b;

double _clamp(double value, double lower, double upper) {
  if (value < lower) {
    return lower;
  }
  if (value > upper) {
    return upper;
  }
  return value;
}

/// Qt's anonymous-namespace `bezier` solver (`Qt/src/UiMotion.cpp:7-22`), copied
/// operation for operation: 24 bisection rounds on the x component with a strict
/// `<` comparison, then the y component at the bisected t.
double _bezier(double x, double x1, double y1, double x2, double y2) {
  double component(double t, double a, double b) =>
      3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
  double lower = 0;
  double upper = 1;
  for (int i = 0; i < 24; i++) {
    final double t = (lower + upper) / 2;
    if (component(t, x1, x2) < x) {
      lower = t;
    } else {
      upper = t;
    }
  }
  return component((lower + upper) / 2, y1, y2);
}

List<double> _mapRect(
    PlaylistPickerRectHook hook, double x, double y, double w, double h) {
  final List<double> mapped = hook(x, y, w, h);
  if (mapped.length != 4) {
    throw ArgumentError.value(
        mapped, 'rectHook', 'must return exactly [x, y, width, height]');
  }
  return mapped;
}

/// Port of Qt `UiMotion::SurfaceMotion` (`Qt/src/UiMotion.h:24-42`,
/// `Qt/src/UiMotion.cpp:86-120`) for the modal surface only.
///
/// Field defaults are the Qt member initialisers: `opacity = 0`, `offset = 12`,
/// `duration = 0` (`Qt/src/UiMotion.h:31-33`), so a fresh instance is already
/// "finished" and invisible-offset — the host calls [set] to enter.
class PlaylistPickerMotion {
  PlaylistPickerMotion();

  /// Current surface opacity, lerped from the value captured by [set].
  double opacity = 0;

  /// Current vertical offset in stage pixels; starts at the Qt literal 12.
  double offset = 12;

  /// Remaining animation length in seconds; `0` means settled.
  double duration = 0;

  double _fromOpacity = 0;
  double _fromOffset = 12;
  double _targetOpacity = 0;
  double _targetOffset = 12;
  double _start = 0;
  bool _entering = true;

  /// `Qt/src/UiMotion.h:28-30`: `finished()` is exactly `duration == 0`, and
  /// `sample` collapses the duration to 0 once progress reaches 1
  /// (`Qt/src/UiMotion.cpp:95-97`), so a completed transition reports finished
  /// while a freshly retargeted one does not.
  bool get finished => duration == 0;

  /// `UiMotion::sample` (`Qt/src/UiMotion.cpp:86-98`). A zero duration returns
  /// immediately, which is what makes the reduced-motion path snap.
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
        1);
    opacity = _fromOpacity + (_targetOpacity - _fromOpacity) * amount;
    offset = _fromOffset + (_targetOffset - _fromOffset) * amount;
    if (progress >= 1) {
      duration = 0;
    }
  }

  /// `UiMotion::set` (`Qt/src/UiMotion.cpp:100-120`): sample the running
  /// transition first so a fast open/close continues from the current opacity and
  /// offset, then retarget. Entering: opacity 1 / offset 0 / 0.3 s. Leaving:
  /// opacity 0 / offset 8 / 0.2 s. Reduced motion: 0 s and an instant snap.
  void set({required bool shown, required double time, bool reduced = false}) {
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

/// One row of `music.lists[2]` as the picker paints it: `{id, title, editable}`.
///
/// [editable] is the host's `MusicLibrary::canEditPlaylist` answer
/// (`Qt/src/MusicMutation.cpp:47-65`: not `special`, `kind == "playlist"`,
/// `creatorID == uid`, and for QQ an `owned` row with `dirId` in 1..199).
/// The domain rule stays injected; this file never re-derives it.
class PlaylistPickerRow {
  const PlaylistPickerRow({
    required this.id,
    required this.title,
    required this.editable,
  });

  final String id;
  final String title;
  final bool editable;
}

/// Immutable result of [PlaylistPickerModal.build]: the Qt `commands` and `hits`
/// arrays, in draw order.
class PlaylistPickerFrame {
  const PlaylistPickerFrame({required this.commands, required this.hits});

  /// Qt `op()` shapes, e.g. `['save']`, `['alpha', v]`, `['translate', x, y]`,
  /// `['fill', color, x, y, w, h]`, `['text', value, x, y, size, weight, tracking,
  /// color]`.
  final List<List<Object?>> commands;

  /// Six fields per hit, in this order: `[x, y, width, height, action, label]`
  /// (`Qt/src/NativeHud.cpp:102-109`).
  final List<List<Object?>> hits;
}

/// Every action string this modal can emit, copied verbatim from the Qt source.
///
/// * [closeModal] — the header back button (`Qt/src/NativeHudModal.cpp:199-200`).
///   Escape for any open modal that is not `desktop-lyrics` maps to the same string
///   (`Qt/src/NativeHudController.cpp:913-922`).
/// * [pickPrefix] + id — one per drawn playlist row
///   (`Qt/src/NativeHudModal.cpp:234-235`).
/// * [pagePrev] / [pageNext] — the pager (`Qt/src/NativeHudModal.cpp:237-238`),
///   handled at `Qt/src/NativeHudMusic.cpp:255-258`.
///
/// This body has no `取消` action and no cancel-style button: the only dismissal
/// control here is the back button labelled `← 返回`. (`取消` belongs to the confirm
/// modal, `Qt/src/NativeHudModal.cpp:221`.)
class PlaylistPickerActionTable {
  const PlaylistPickerActionTable._();

  static const String closeModal = 'close-modal';
  static const String pagePrev = 'music:picker-prev';
  static const String pageNext = 'music:picker-next';
  static const String pickPrefix = 'music:playlist-pick:';

  static String pick(String id) => '$pickPrefix$id';

  /// Qt keyboard table restricted to this open modal
  /// (`Qt/src/NativeHudController.cpp:913-925`): the modal is non-empty and is not
  /// `desktop-lyrics`, so Escape is `close-modal`. Every other key is swallowed
  /// while a modal is open (`:923-925`); no Tab focus order exists in Qt, so none
  /// is fabricated here.
  static const Map<String, String> keyActions = <String, String>{
    'Escape': closeModal,
  };

  /// Row stride of the pager, i.e. the shared `listOffset` clamp used by both this
  /// modal's pager and its wheel handler:
  ///
  /// `listOffset = clamp(listOffset ± 7, 0, max(0, playlists.length - 7))` for the
  /// pager buttons (`Qt/src/NativeHudMusic.cpp:255-258`), and the same clamp with
  /// `±1` for one wheel notch — `listOffset + step` where
  /// `step = delta < 0 ? 1 : -1` (`Qt/src/NativeHudInput.cpp:17,56-58`). The wheel
  /// moves a single row, not a page; [pageStride] is the button stride only.
  ///
  /// The offset itself is injected here ([PlaylistPickerModal.listOffset]); this
  /// library only paints the window `[listOffset, listOffset + 7)`.
  static const int pageStride = 7;
}

/// Injected state of the Qt `playlist-picker` modal plus the pure [build] entry
/// point. Nothing here mutates: opacity/offset/closing/dark/reduced/width and every
/// domain value arrive from the host.
class PlaylistPickerModal {
  const PlaylistPickerModal({
    required this.width,
    required this.dark,
    required this.reduced,
    required this.closing,
    required this.search,
    required this.opacity,
    required this.offset,
    required this.provider,
    required this.status,
    required this.listOffset,
    required this.playlists,
    required this.measureText,
    this.rectHook = _identityRect,
  });

  /// Qt stage width in pixels (`NativeHud::width`, `Qt/src/NativeHud.cpp:149,240`).
  final double width;

  /// Qt `dark` theme flag; selects every colour below.
  final bool dark;

  /// Reduced-motion preference. Consumed by [PlaylistPickerMotion.set]; the frame
  /// itself is identical (Qt only shortens the curve, `Qt/src/UiMotion.cpp:109-119`).
  final bool reduced;

  /// The host is running the close curve. Qt keeps painting the same panel until
  /// `closing && motion.finished()` and only then clears the modal
  /// (`Qt/src/NativeHud.cpp:262-266`), so [build] must stay byte-identical here.
  final bool closing;

  /// Mirrors Qt's local `const bool search = modal == "search"`
  /// (`Qt/src/NativeHudModal.cpp:162`). Only the scrim alpha depends on it
  /// (`:164-165`). A playlist picker never takes the `search` bounds branch
  /// (`Qt/src/NativeHud.cpp:154-157`) — the value is injected because the shared
  /// scrim formula is fixed by the eight-modal contract, and it is `false` in real
  /// use because the modal kind is `playlist-picker`.
  final bool search;

  /// Current surface opacity, i.e. `motion.opacity` (`Qt/src/NativeHudModal.cpp:84`).
  final double opacity;

  /// Current surface offset, i.e. `motion.offset` (`Qt/src/NativeHudModal.cpp:166`).
  final double offset;

  /// `music.provider`: `"qq"` gates the editable-only rows and the empty state
  /// (`Qt/src/NativeHudModal.cpp:224-233`).
  final String provider;

  /// `music.status`, painted through `limited()` at `usable - 420` px
  /// (`Qt/src/NativeHudModal.cpp:239`).
  final String status;

  /// `listOffset`: first visible row of `lists[2]`. The window is
  /// `[listOffset, listOffset + 7)` (`Qt/src/NativeHudModal.cpp:229`).
  ///
  /// Paging/wheel semantics (documented, not executed here): the pager buttons move
  /// `±7` with `clamp(listOffset, 0, max(0, playlists.length - 7))`
  /// (`Qt/src/NativeHudMusic.cpp:255-258`); one wheel notch moves `±1` with the same
  /// clamp (`Qt/src/NativeHudInput.cpp:17,56-58`); `listOffset` is reset to 0 on
  /// open (`Qt/src/NativeHudController.cpp:98`).
  final int listOffset;

  /// `music.lists[2]` in platform order; only the visible window is read, but the
  /// QQ empty state inspects *all* rows (`Qt/src/NativeHudModal.cpp:224-228`).
  final List<PlaylistPickerRow> playlists;

  /// Injected text measurement used by `fit()` and by the button label refit.
  final PlaylistPickerMeasureText measureText;

  /// Portrait placement seam; identity by default (`Qt/src/NativeHud.cpp:140-159`).
  final PlaylistPickerRectHook rectHook;

  /// Paints the frame. Pure: no I/O, no mutation of this instance or of the
  /// injected lists.
  PlaylistPickerFrame build() {
    final List<List<Object?>> commands = <List<Object?>>[];
    final List<List<Object?>> hits = <List<Object?>>[];
    final _Painter p = _Painter(
      commands: commands,
      hits: hits,
      dark: dark,
      measureText: measureText,
    );

    // Qt/src/NativeHudModal.cpp:83-84 — the whole modal is one save/restore scope
    // and every command below inherits the surface opacity.
    p.save();
    p.alpha(opacity);

    // Qt/src/NativeHudModal.cpp:162-165 — full-stage scrim, emitted *before* the
    // offset translate, so it does not travel with the panel.
    final List<double> stage = _mapRect(rectHook, 0, 0, width, 1080);
    p.fill(
        stage[0],
        stage[1],
        stage[2],
        stage[3],
        dark
            ? <Object?>[
                17.0 / 255.0,
                24.0 / 255.0,
                27.0 / 255.0,
                search ? 0.15 : 0.6,
              ]
            : <Object?>[
                227.0 / 255.0,
                224.0 / 255.0,
                215.0 / 255.0,
                search ? 0.12 : 0.45,
              ]);

    // Qt/src/NativeHudModal.cpp:166.
    p.translate(0, offset);

    // Qt/src/NativeHud.cpp:153,157,158 — generic bounds, never the search branch.
    final double modalWidth = _min(1260.0, width - 100);
    final double left = (width - modalWidth) / 2;
    final List<double> panel = _mapRect(rectHook, left, 122, modalWidth, 836);
    final double x = panel[0];
    final double y = panel[1];
    final double usable = panel[2];

    // Qt/src/NativeHudModal.cpp:171-172 — the panel fill height is the Qt literal
    // 836 (identical to bounds.height()), independent of the hook's height.
    p.fill(
        x,
        y,
        usable,
        836,
        dark
            ? <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite']
            : <Object?>[0.929, 0.922, 0.894, 1]);

    // Qt/src/NativeHudModal.cpp:173-174 — from here on every button is a "modal
    // control" (tinted fill + inset + refit), and hit #1 is the header back button.
    p.modalControls = true;

    // Header: Qt/src/NativeHudModal.cpp:188,198-202. The category stays the default
    // "MUSIC DIRECTORY" (:188) because this modal is not settings/desktop-lyrics/
    // player/quality (:189-197); the title and subtitle come from :36 and :61.
    p.text('RHINE LAB / MUSIC DATABASE / $_category', x + 53, y + 37, 11);
    p.button(_backLabel, x + usable - 220, y + 18, 167, 54,
        PlaylistPickerActionTable.closeModal, 20, 'demibold');
    p.text(_title, x + 53, y + 91, 38, 'demibold');
    p.text(_subtitle, x + 53, y + 147, 15);

    // Body: Qt/src/NativeHudModal.cpp:222-239.
    p.text(_bodyTitle, x + 53, y + 240, 18);
    if (provider == 'qq' && !_anyEditable) {
      p.text(_emptyState, x + 53, y + 320, 16);
    }
    for (int index = 0; index < PlaylistPickerActionTable.pageStride; index++) {
      final int position = listOffset + index;
      if (position >= playlists.length) {
        break;
      }
      final PlaylistPickerRow row = playlists[position];
      if (provider == 'qq' && !row.editable) {
        // Qt/src/NativeHudModal.cpp:231-233 — the row is skipped but the loop index
        // is still consumed, so following rows keep the skipped slot's y and the
        // page still holds seven positions.
        continue;
      }
      p.button(
          p.fit(row.title, 18, usable - 106),
          x + 53,
          y + 290 + index * 60,
          usable - 106,
          52,
          PlaylistPickerActionTable.pick(row.id),
          18);
    }
    p.button(_previousPageLabel, x + usable - 330, y + 758, 120, 32,
        PlaylistPickerActionTable.pagePrev, 12);
    p.button(_nextPageLabel, x + usable - 190, y + 758, 120, 32,
        PlaylistPickerActionTable.pageNext, 12);
    p.limited(status, x + 53, y + 775, 12, usable - 420);

    // Qt/src/NativeHudModal.cpp:255-256.
    p.modalControls = false;
    p.restore();
    return PlaylistPickerFrame(commands: commands, hits: hits);
  }

  /// `std::none_of(lists[2], canEditPlaylist)` (`Qt/src/NativeHudModal.cpp:224-228`):
  /// computed over every row, not just the visible window.
  bool get _anyEditable {
    for (final PlaylistPickerRow row in playlists) {
      if (row.editable) {
        return true;
      }
    }
    return false;
  }
}

// Strings copied from the Qt source; each cites its line.
const String _category = 'MUSIC DIRECTORY'; // NativeHudModal.cpp:188
const String _title = 'PLAYLIST DIRECTORY'; // NativeHudModal.cpp:36
const String _subtitle = '添加到我的歌单'; // NativeHudModal.cpp:61
const String _bodyTitle = '选择我的歌单'; // NativeHudModal.cpp:223
const String _emptyState = '暂无可编辑的自建普通歌单，请先创建歌单。'; // :227
const String _backLabel = '← 返回'; // :199
const String _previousPageLabel = '↑ 上一页'; // :237
const String _nextPageLabel = '下一页 ↓'; // :238

/// Qt draw primitive set (one instance per frame), mirroring `NativeHud`'s private
/// painters so the command order matches the C++ call order exactly.
class _Painter {
  _Painter({
    required this.commands,
    required this.hits,
    required this.dark,
    required this.measureText,
  });

  final List<List<Object?>> commands;
  final List<List<Object?>> hits;
  final bool dark;
  final PlaylistPickerMeasureText measureText;

  /// Qt `m_modalControls` (`Qt/src/NativeHud.h:222`), enabled for the whole body.
  bool modalControls = false;

  /// Qt `NativeHud::ink` (`Qt/src/NativeHud.cpp:10-15`).
  List<Object?> ink() => dark
      ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
      : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

  /// Qt `ink()` with alpha 0.45 — muted text (`Qt/src/NativeHud.cpp:106-107`).
  /// This body paints no muted text (every `text`/`limited` call uses default ink,
  /// `Qt/src/NativeHudModal.cpp:222-239`); the primitive is kept because the
  /// eight-modal contract fixes the shared primitive set.
  // ignore: unused_element
  List<Object?> mutedInk() {
    final List<Object?> color = ink();
    color[3] = 0.45;
    return color;
  }

  void op(List<Object?> command) => commands.add(command);

  void save() => op(<Object?>['save']); // NativeHud.cpp:19-21

  void restore() => op(<Object?>['restore']); // :22-24

  void alpha(double value) => op(<Object?>['alpha', value]); // :25-27

  void translate(double x, double y) =>
      op(<Object?>['translate', x, y]); // :28-30

  /// Qt `fill` (`Qt/src/NativeHud.cpp:37-39`); an omitted colour falls back to ink.
  void fill(double x, double y, double width, double height,
      [List<Object?>? color]) {
    op(<Object?>['fill', color ?? ink(), x, y, width, height]);
  }

  /// Qt `text` (`Qt/src/NativeHud.cpp:40-43`); weight defaults to `regular`,
  /// tracking to 0 and colour to ink.
  void text(String value, double x, double y, double size,
      [String weight = 'regular', double tracking = 0, List<Object?>? color]) {
    op(<Object?>[
      'text',
      value,
      x,
      y,
      size,
      weight,
      tracking,
      color ?? ink(),
    ]);
  }

  /// Qt `hit` (`Qt/src/NativeHud.cpp:102-109`): six fields, label falls back to the
  /// action when null.
  void hit(double x, double y, double width, double height, String action,
      [String? label]) {
    hits.add(<Object?>[x, y, width, height, action, label ?? action]);
  }

  /// Qt `button` (`Qt/src/NativeHud.cpp:110-120`): hit first, then the tinted fill,
  /// then the inset text whose label is refitted to `width - inset * 2`.
  void button(String label, double x, double y, double width, double height,
      String action, double size,
      [String weight = 'regular']) {
    hit(x, y, width, height, action, label);
    final double inset = modalControls ? _min(10.0, width / 8) : 0;
    if (modalControls) {
      fill(
          x,
          y,
          width,
          height,
          dark
              ? <Object?>[0.55, 0.59, 0.46, 0.13]
              : <Object?>[0.44, 0.49, 0.36, 0.1]);
    }
    text(modalControls ? fit(label, size, width - inset * 2) : label, x + inset,
        y + (height - size) / 2 - 4, size, weight);
  }

  /// Qt `limited` (`Qt/src/NativeHud.cpp:77-79`): `text(fit(value, size, width))`.
  void limited(String value, double x, double y, double size, double width,
      [String weight = 'regular']) {
    text(fit(value, size, width, weight), x, y, size, weight);
  }

  /// Qt `rule` (`Qt/src/NativeHud.cpp:125-129`): a 1 px fill tinted with ink whose
  /// alpha is [opacity]. This body draws no separator
  /// (`Qt/src/NativeHudModal.cpp:222-239`); the primitive is kept because the
  /// eight-modal contract fixes the shared primitive set.
  // ignore: unused_element
  void rule(double x, double y, double width, double opacity) {
    final List<Object?> color = ink();
    color[3] = opacity;
    fill(x, y, width, 1, color);
  }

  /// Qt `NativeHud::fit` (`Qt/src/NativeHud.cpp:48-76`), byte-for-byte:
  ///
  /// * measure the full run with the injected [measureText] (tracking 0, exactly the
  ///   three-argument `Glyphs::width` overload Qt uses);
  /// * if it fits, return it unchanged (Qt keeps the original string);
  /// * otherwise binary-search the longest prefix that fits, then replace its last
  ///   code unit with `…` — Qt does `value.left(length - 1) + "…"` (:71-73), which is
  ///   why a truncated label is one code unit shorter than the measured prefix.
  String fit(String value, double size, double width,
      [String weight = 'regular']) {
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
    if (length != value.length) {
      final int keep = length - 1 < 0 ? 0 : length - 1;
      return '${value.substring(0, keep)}…';
    }
    return value;
  }
}
