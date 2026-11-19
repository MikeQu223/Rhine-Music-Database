/// Viewer state machine: opening, closing, reset, clarity and the frosted
/// surface, ported from the Qt 3D viewer overlay.
///
/// Source of truth (baseline 708677579626f8eaeeef77e8588125ecadab4858):
///  * `Qt/src/NativeViewer.cpp` (355 lines) and `Qt/src/NativeViewer.h`
///    (68 lines) — the whole state machine: `open` (:39-64), `reduced`
///    (:65-76), `reset` (:77-91), `interrupt` (:92-98), `action` (:108-130),
///    `key` (:131-166), `update` (:208-274) and the `viewerState` block of
///    `frame` (:276-355).
///  * `Qt/src/NativeHud.cpp:242-251` and `:280-288` — the 500 ms wall-clock
///    detail fade that takes `std::max` with the pseudo-clock `frame[detail]`
///    value: "500 ms 淡入，与场景曲线同形（smoothstep）。取两者较大值：正常路径完全
///    由 frame[detail] 主导，只有伪时钟被截断时墙钟才会接管".
///  * `Qt/src/NativeScene.cpp:274-284` — `review("viewer")` sets the scene mode
///    to `detail` and then opens the viewer, which is why closing the viewer
///    resumes the detail page (fallback: whatever `mode` the scene reported).
///  * `Qt/src/SceneMotion.cpp:113-119` — the critically damped spring, already
///    ported as `Spring` in `lib/scene/scene_math.dart`; this file only drives
///    it with Qt's rates and rest thresholds.
///
/// Time sources, the point of this file
///  * The **frame clock** (`AnimationClock`) is the pseudo clock the scene is
///    sampled with. Its per-frame delta is
///    `std::min(m_last != 0 ? time - m_last : 1.0 / 60, 0.05)`
///    (`NativeViewer.cpp:225`), i.e. the first frame after `open` advances by
///    one 60 Hz tick and no frame ever advances by more than 50 ms.
///  * The **wall clock** is only used by `DetailFadeClock`, and only as the
///    hand-over rule above: the wall-clock fade is maxed with, never folded
///    into, the pseudo-clock value.
///
/// What this file deliberately does NOT own
///  * The camera: pose interpolation, the spherical goal
///    (`NativeViewer.cpp:240-267`), drag/wheel/pan and the radius clamps are a
///    separate concern. `reset` here keeps only the part the state machine
///    reports (`resetting` + its `resetElapsed` progress), and the camera
///    matrices are supplied to `SceneFrame` from outside.
///  * Mesh loading and rendering. `ready` is a plain flag the caller sets, Qt's
///    `m_ready = !m_meshes.isEmpty()` (`NativeViewer.cpp:62`) collapsed to its
///    observable effect.
///  * Flutter. This library is pure Dart on purpose: no `package:flutter` and
///    no `dart:ui`, so the state machine is unit-testable without a binding.
library;

import 'dart:collection';
import 'dart:convert';

import 'scene_frame.dart';
import 'scene_math.dart';

// Timing constants — every value cites the Qt line it was taken from.

/// `open` pending window (`NativeViewer.cpp:47`:
/// `m_pendingUntil = m_reduced ? time : time + 0.38`).
const double kOpeningSeconds = 0.38;

/// `close` fade (`NativeViewer.cpp:117`:
/// `m_closeAt = m_reduced ? time : time + 0.22`).
const double kClosingSeconds = 0.22;

/// `reset` interpolation (`NativeViewer.cpp:252`: `m_resetElapsed / 0.56`).
const double kResetSeconds = 0.56;

/// Clarity spring rate (`NativeViewer.cpp:231`: `m_clarity.damp(target, 8, seconds)`).
const double kClarityRate = 8.0;

/// Spread spring rate (`NativeViewer.cpp:232`: `m_spread.damp(target, 5.5, seconds)`).
const double kSpreadRate = 5.5;

/// Rest threshold on the value (`NativeViewer.cpp:234,237`: `< 0.0001`).
const double kSpringRestValue = 0.0001;

/// Rest threshold on the velocity (`NativeViewer.cpp:234,237`: `< 0.001`).
const double kSpringRestVelocity = 0.001;

/// Largest frame step the springs may take (`NativeViewer.cpp:225`: `0.05`).
const double kMaxFrameStep = 0.05;

/// The step substituted before the clock has a previous sample
/// (`NativeViewer.cpp:225`: `1.0 / 60`).
const double kFirstFrameStep = 1.0 / 60.0;

/// Wall-clock detail fade window (`NativeHud.cpp:282`: `/ 500.0`).
const double kDetailFadeSeconds = 0.5;

/// Wall-clock milliseconds per second, so the divide reads like the C++.
const double _msPerSecond = 1000.0;

/// Transition the state machine reports in `viewerState["transition"]`
/// (`NativeViewer.h:63`: `QString m_transition = "closed"`).
enum ViewerTransition {
  closed('closed'),
  opening('opening'),
  open('open'),
  closing('closing');

  const ViewerTransition(this.wire);

  /// The exact string Qt stores in `m_transition`.
  final String wire;

  /// Read Qt's string, `null` for anything the machine never writes.
  static ViewerTransition? fromWire(String wire) {
    for (final ViewerTransition value in ViewerTransition.values) {
      if (value.wire == wire) {
        return value;
      }
    }
    return null;
  }
}

/// Surface finish of the glass wrap (`NativeViewer.h:64`:
/// `QString m_surface = "clear"`; actions `clear` / `frosted` at
/// `NativeViewer.cpp:121-124`).
enum ViewerSurface {
  clear('clear'),
  frosted('frosted');

  const ViewerSurface(this.wire);

  final String wire;

  static ViewerSurface? fromWire(String wire) {
    for (final ViewerSurface value in ViewerSurface.values) {
      if (value.wire == wire) {
        return value;
      }
    }
    return null;
  }
}

/// The actions `NativeViewer::action` accepts (`NativeViewer.cpp:108-130`).
///
/// The wire strings are the ones `NativeHud` emits as `viewer:<action>`
/// (`NativeHudDetail.cpp:518-528`: `viewer:close`, `viewer:clear`,
/// `viewer:frosted`, `viewer:reset`), so `name` and `wire` coincide by
/// construction — they are kept separate so a future Qt rename cannot silently
/// change the Dart enum.
enum ViewerAction {
  close('close'),
  clear('clear'),
  frosted('frosted'),
  explode('explode'),
  assemble('assemble'),
  reset('reset');

  const ViewerAction(this.wire);

  final String wire;

  static ViewerAction? fromWire(String wire) {
    for (final ViewerAction value in ViewerAction.values) {
      if (value.wire == wire) {
        return value;
      }
    }
    return null;
  }
}

// Frame clock.

/// The scene's pseudo clock and Qt's per-frame delta rule.
///
/// `NativeViewer::update` computes (`NativeViewer.cpp:225-226`):
///
///     const auto seconds = std::min(m_last != 0 ? time - m_last : 1.0 / 60, 0.05);
///     m_last = time;
///
/// Two consequences the port must keep:
///  * the first frame after a `rebase()` advances by one 60 Hz tick, not by the
///    whole time since the previous session;
///  * `std::min` also clamps a *negative* step (a clock that moved backwards
///    keeps its negative delta), which is why `advance` does not clamp at zero.
///
/// `seek` only records the time (`m_time = time`), without touching the delta
/// bookkeeping; `reset` deliberately never touches it either, so resetting the
/// camera cannot make the springs jump.
final class AnimationClock {
  AnimationClock({double time = 0}) : _time = time;

  double _time;
  double _last = 0;

  /// `m_time` — the time of the last applied frame.
  double get time => _time;

  /// `m_last` — the previous frame time, `0` when unset.
  double get last => _last;

  /// True once a frame has been applied since the last `rebase`.
  bool get hasSample => _last != 0;

  /// `m_time = time` without advancing the delta bookkeeping.
  void seek(double time) {
    _time = time;
  }

  /// `m_last = 0` — `NativeViewer::open` (`:53`) does this so the first frame
  /// after opening uses the fallback step instead of the gap between sessions.
  void rebase() {
    _last = 0;
  }

  /// Apply one frame and return the seconds the springs may use.
  ///
  /// Mirrors `NativeViewer.cpp:225-226` exactly, including the `m_last != 0`
  /// sentinel: a frame that lands exactly on `0` re-arms the fallback step, just
  /// like the C++.
  double advance(double time) {
    _time = time;
    final double step = _last != 0 ? time - _last : kFirstFrameStep;
    final double seconds = step < kMaxFrameStep ? step : kMaxFrameStep;
    _last = time;
    return seconds;
  }
}

// Wall-clock detail fade.

/// The 500 ms wall-clock hand-over of the detail page fade.
///
/// `NativeHud::draw` latches the wall clock when the frame reports the detail
/// page (`NativeHud.cpp:242-251`):
///
///     inDetail = frame["mode"] == "detail";
///     if (inDetail && m_detailEnterWallMs < 0) m_detailEnterWallMs = now;
///     else if (!inDetail) m_detailEnterWallMs = -1;
///
/// and then takes the larger of the frame's own `detail` value and the eased
/// wall-clock ramp (`:280-288`):
///
///     const double wall = std::clamp((now - m_detailEnterWallMs) / 500.0, 0.0, 1.0);
///     const double eased = wall * wall * (3 - 2 * wall);
///     opacity = std::max(opacity, eased);
///
/// The normal path is therefore entirely pseudo-clock driven; the wall clock
/// only takes over when the frame clock was truncated (a frozen scene, a
/// backgrounded app), which is exactly the "墙钟与伪时钟取 max" rule of this
/// 文件. The ramp shape is the same smoothstep as `SceneMotion::smooth`
/// (`SceneMotion.cpp:42-49`), spelled out here because Qt spells it out too.
final class DetailFadeClock {
  /// `m_detailEnterWallMs`; `-1` means "not in the detail page".
  int _enterWallMs = -1;

  /// Wall clock at which the detail page was entered, or `null`.
  int? get enterWallMs => _enterWallMs < 0 ? null : _enterWallMs;

  /// True while the detail page is latched.
  bool get isArmed => _enterWallMs >= 0;

  /// Latch or clear the entry, exactly like `NativeHud.cpp:246-251`.
  void sample({required bool inDetail, required int wallMs}) {
    if (inDetail && _enterWallMs < 0) {
      _enterWallMs = wallMs;
    } else if (!inDetail) {
      _enterWallMs = -1;
    }
  }

  /// The fade opacity for this frame: `max(frameDetail, smoothstep(wall))`.
  ///
  /// [pseudoDetail] is `frame["detail"]` (`NativeSceneFrame.cpp:116`); [wallMs]
  /// is the wall clock sampled this frame. Outside the detail page Qt never
  /// computes this ramp (the latch is `-1` and the branch is not taken), so the
  /// pseudo value is returned unchanged.
  double opacity(double pseudoDetail, {required int wallMs}) {
    if (_enterWallMs < 0) {
      return pseudoDetail;
    }
    double wall = (wallMs - _enterWallMs) / (_msPerSecond * kDetailFadeSeconds);
    if (wall < 0) {
      wall = 0;
    } else if (wall > 1) {
      wall = 1;
    }
    final double eased = _smoothStep(wall);
    return pseudoDetail > eased ? pseudoDetail : eased;
  }

  /// Clear the latch (a new detail page, a viewer session, a fresh surface).
  void reset() {
    _enterWallMs = -1;
  }

  /// `v * v * (3 - 2 * v)` — `NativeHud.cpp:284`, the same curve as
  /// `SceneMotion::ease`.
  static double _smoothStep(double value) => value * value * (3 - 2 * value);
}

// Close outcome.

/// What the HUD must show once `close` finished fading.
///
/// Qt has no such value: `NativeViewer::update` simply sets `m_open = false`
/// (`NativeViewer.cpp:215-222`) and the next HUD draw falls through to
/// `frame["mode"]` (`NativeHud.cpp:267-305`). Since the only Qt opener is the
/// detail page (`NativeHudDetail.cpp:74` → `NativeScene.cpp:274-284` sets
/// `mode = "detail"` first), the resume mode is `detail` unless the caller says
/// otherwise. Returning it explicitly keeps that decision out of the widget
/// tree, and the `time` lets the surface rebuild against the same frame clock.
final class ViewerCloseOutcome {
  const ViewerCloseOutcome({required this.resumeMode, required this.time});

  /// The frame mode to resume — `SceneFrame`'s `mode` vocabulary.
  final String resumeMode;

  /// The frame time at which the close completed.
  final double time;

  @override
  String toString() =>
      'ViewerCloseOutcome(resumeMode: ' + resumeMode + ', time: ' + time.toString() + ')';
}

// Viewer state.

/// The Qt viewer overlay state machine.
///
/// Lifecycle: `open` → `opening` → `open` → `closing` → `closed`. The overlay
/// holds a scene frame and its own projection while open; `update` advances the
/// springs and reports the moment the overlay released the screen.
///
/// Faithfulness notes that are easy to get wrong:
///  * `act` is a no-op while closed *and* while closing
///    (`NativeViewer.cpp:109-111`: `if (!m_open || m_closing) return;`), so a
///    repeated `close` during the closing fade cannot extend or shorten it. The
///    fade end is latched in `closeAt` when the first `close` arrives.
///  * Every action except `close` additionally requires `ready`
///    (`:119-120`): an overlay whose meshes never arrived ignores
///    clear/frosted/explode/assemble/reset, but still closes.
///  * `clear` and `frosted` are mutually exclusive by construction: both write
///    the same `targetClarity` (1 or 0) and the same `surface`, so the last
///    action wins and no intermediate state can be "both".
///  * `reset` never touches the frame clock (`NativeViewer.cpp:77-91` only
///    touches the camera and the reset progress), which is why a reset during
///    playback cannot re-time the animation.
final class ViewerState {
  ViewerState({
    bool reduced = false,
    this.ready = false,
    this.resumeMode = kFrameModeDetail,
    AnimationClock? clock,
  })  : _reduced = reduced,
        clock = clock ?? AnimationClock();

  /// The pseudo clock this machine reads and advances.
  final AnimationClock clock;

  /// Mesh readiness (`m_ready`). Qt derives it from the loaded mesh list
  /// (`NativeViewer.cpp:62`); here the caller states it, and `update` clears it
  /// again when the overlay closes (`:218`).
  bool ready;

  /// Mode to resume when the overlay closes — see `ViewerCloseOutcome`.
  String resumeMode;

  bool _open = false;
  bool _closing = false;
  bool _reduced;
  bool _resetting = false;
  ViewerTransition _transition = ViewerTransition.closed;
  ViewerSurface _surface = ViewerSurface.clear;
  double _pendingUntil = 0;
  double _closeAt = 0;
  double _resetElapsed = 0;
  double _targetClarity = 1;
  double _targetSpread = 0;
  Spring _clarity = Spring(1, 0);
  Spring _spread = Spring(0, 0);

  /// `m_open` — the overlay owns the screen.
  bool get isOpen => _open;

  /// `m_closing` — the close fade is running.
  bool get isClosing => _closing;

  /// `m_transition` — what `viewerState["transition"]` reports.
  ViewerTransition get transition => _transition;

  /// `m_surface` — `clear` or `frosted`.
  ViewerSurface get surface => _surface;

  /// `m_reduced` — reduced motion (no pending window, no spring travel).
  bool get reduced => _reduced;

  /// `m_resetting` — a `reset` interpolation is running.
  bool get resetting => _resetting;

  /// `m_resetElapsed` — seconds accumulated into the running reset.
  double get resetElapsed => _resetElapsed;

  /// `m_targetClarity` — 1 for clear, 0 for frosted.
  double get targetClarity => _targetClarity;

  /// Current clarity, i.e. `m_clarity.value`.
  double get clarity => _clarity.value;

  /// Current clarity spring, for callers that need the velocity too.
  Spring get claritySpring => _clarity;

  /// `m_targetSpread` — 1 when exploded, 0 when assembled.
  double get targetSpread => _targetSpread;

  /// Current spread, i.e. `m_spread.value`.
  double get spread => _spread.value;

  /// Current spread spring.
  Spring get spreadSpring => _spread;

  /// `m_pendingUntil` — the frame time at which `opening` becomes `open`.
  double get pendingUntil => _pendingUntil;

  /// `m_closeAt` — the frame time at which `closing` becomes `closed`.
  double get closeAt => _closeAt;

  /// `NativeViewer::pending` (`:20-25`):
  /// `m_open && (m_closing || m_time < m_pendingUntil)`.
  bool get pending => _open && (_closing || clock.time < _pendingUntil);

  /// True when the exploded target is exactly `1`
  /// (`NativeViewer.cpp:349-352` compares `m_targetSpread == 1`).
  bool get exploded => _targetSpread == 1;

  /// Open the overlay — `NativeViewer.cpp:39-64`.
  ///
  /// Idempotent: an already open overlay is left untouched (`:40`). [ready]
  /// plays the role of Qt's mesh-load result; when omitted the current value is
  /// kept.
  void open(double time, {bool? ready}) {
    if (_open) {
      return;
    }
    _open = true;
    _closing = false;
    _transition = ViewerTransition.opening;
    clock.seek(time);
    clock.rebase();
    _pendingUntil = _reduced ? time : time + kOpeningSeconds;
    _spread = Spring();
    _targetSpread = 0;
    _clarity = Spring(1, 0);
    _targetClarity = 1;
    _surface = ViewerSurface.clear;
    if (ready != null) {
      this.ready = ready;
    }
    reset(animated: false);
  }

  /// `NativeViewer::reset(bool animated)` — `:77-91`.
  ///
  /// Only the parts this machine reports are modelled: `resetting` and
  /// `resetElapsed`. Qt also snaps or re-aims the camera here; the camera is
  /// outside this file. A non-animated reset (or one under reduced motion)
  /// finishes immediately, exactly like the `else` branch of the C++.
  void reset({required bool animated}) {
    if (animated && !_reduced) {
      _resetElapsed = 0;
      _resetting = true;
    } else {
      _resetting = false;
    }
  }

  /// `NativeViewer::interrupt()` — `:92-98`: a drag interrupts a reset.
  void interrupt() {
    if (_resetting) {
      _resetting = false;
    }
  }

  /// `NativeViewer::reduced(bool)` — `:65-76`.
  ///
  /// Turning reduced motion on collapses the pending window and snaps both
  /// springs to their targets by re-seating them with zero velocity.
  void setReduced(bool value) {
    _reduced = value;
    if (value) {
      _pendingUntil = clock.time;
      _clarity = Spring(_targetClarity, 0);
      _spread = Spring(_targetSpread, 0);
    }
  }

  /// `NativeViewer::action` — `:108-130`.
  ///
  /// [time] is the frame clock at which the action arrived; it only matters for
  /// the close latch (reduced motion closes immediately).
  void act(ViewerAction action, double time) {
    if (!_open || _closing) {
      return;
    }
    if (action == ViewerAction.close) {
      _closing = true;
      _transition = ViewerTransition.closing;
      _closeAt = _reduced ? time : time + kClosingSeconds;
      return;
    }
    if (!ready) {
      return;
    }
    if (action == ViewerAction.clear) {
      _targetClarity = 1;
      _surface = ViewerSurface.clear;
      return;
    }
    if (action == ViewerAction.frosted) {
      _targetClarity = 0;
      _surface = ViewerSurface.frosted;
      return;
    }
    if (action == ViewerAction.explode) {
      _targetSpread = 1;
      return;
    }
    if (action == ViewerAction.assemble) {
      _targetSpread = 0;
      return;
    }
    if (action == ViewerAction.reset) {
      reset(animated: true);
    }
  }

  /// Apply a Qt wire action string. Unknown strings are ignored, like `:110-117`
  /// which only compares against known literals.
  ///
  /// Returns whether the string named a known action.
  bool applyWire(String action, double time) {
    final ViewerAction? parsed = ViewerAction.fromWire(action);
    if (parsed == null) {
      return false;
    }
    act(parsed, time);
    return true;
  }

  /// `NativeViewer::key` — `:131-166`, restricted to the keys this file owns.
  ///
  /// `Escape` closes even when the meshes never loaded (`:132-134`); every other
  /// key requires a ready, non-closing overlay (`:136-138`). `Home` performs an
  /// animated reset (`:139-142`). The camera keys (`+`, `=`, `-`, arrows) are
  /// camera scope and are ignored here.
  void key(String key, double time) {
    if (key == 'Escape') {
      act(ViewerAction.close, time);
      return;
    }
    if (!ready || _closing) {
      return;
    }
    if (key == 'Home') {
      reset(animated: true);
    }
  }

  /// `NativeViewer::update` — `:208-274`.
  ///
  /// Returns `null` while the overlay keeps the screen and a
  /// `ViewerCloseOutcome` on the frame that completes the close, which is the
  /// port's replacement for Qt's silent `m_open = false` plus the HUD's
  /// fall-through to `frame["mode"]`.
  ///
  /// Order matters and follows the C++: the close check happens before the
  /// delta is computed, so the closing frame does not advance the springs and
  /// does not update `m_last` (`:214-226`).
  ViewerCloseOutcome? update(double time) {
    if (!_open) {
      return null;
    }
    clock.seek(time);
    if (_closing && time >= _closeAt) {
      _open = false;
      _closing = false;
      ready = false;
      _transition = ViewerTransition.closed;
      return ViewerCloseOutcome(resumeMode: resumeMode, time: time);
    }
    if (!_closing && time >= _pendingUntil) {
      _transition = ViewerTransition.open;
    }
    final double seconds = clock.advance(time);
    if (_reduced) {
      _clarity = Spring(_targetClarity, 0);
      _spread = Spring(_targetSpread, 0);
    } else {
      _clarity.damp(_targetClarity, kClarityRate, seconds);
      _spread.damp(_targetSpread, kSpreadRate, seconds);
      _settle(_clarity, _targetClarity);
      _settle(_spread, _targetSpread);
    }
    if (_resetting && !_reduced) {
      _resetElapsed += seconds > 0 ? seconds : 0;
      if (_resetElapsed / kResetSeconds >= 1) {
        _resetting = false;
      }
    }
    return null;
  }

  /// The `viewerState` object Qt writes into the frame —
  /// `NativeViewer.cpp:342-355`.
  ///
  /// `exploded` is a **string** in Qt (`m_targetSpread == 1 ? "true" : "false"`,
  /// `:351`), not a JSON boolean; the HUD parses it as text. [stats] is the
  /// caller's stats map, serialised compactly with sorted keys to match
  /// `QJsonDocument::Compact` (`:354`).
  Map<String, Object?> toViewerStateJson({Map<String, Object?>? stats}) {
    final Map<String, Object?> state = <String, Object?>{
      'transition': _transition.wire,
      'surface': _surface.wire,
      'exploded': exploded ? 'true' : 'false',
    };
    if (stats != null) {
      state['stats'] = jsonEncode(SplayTreeMap<String, Object?>.of(stats));
    }
    return state;
  }

  /// The subset of Qt's `stats` object this machine can fill honestly.
  ///
  /// Qt writes `ready`, `clarity`, `targetClarity`, `spread`, `target`,
  /// `distance`, `targetPosition`, `requestedTarget`, `requestedDistance`,
  /// `cameraPosition`, `resetting`, `azimuth` and `polar`
  /// (`NativeViewer.cpp:344-353`). The camera fields belong to the camera model,
  /// so they are absent here rather than filled with a guess.
  Map<String, Object?> statsSnapshot() => <String, Object?>{
        'ready': ready,
        'clarity': clarity,
        'targetClarity': _targetClarity,
        'spread': spread,
        'resetting': _resetting,
      };

  /// Bring a spring to rest exactly on its target once Qt's thresholds are met —
  /// `NativeViewer.cpp:234-239`:
  ///
  ///     if (std::abs(m_clarity.value - m_targetClarity) < 0.0001 &&
  ///         std::abs(m_clarity.velocity) < 0.001) {
  ///         m_clarity = {m_targetClarity, 0};
  ///     }
  static void _settle(Spring spring, double target) {
    if ((spring.value - target).abs() < kSpringRestValue &&
        spring.velocity.abs() < kSpringRestVelocity) {
      spring.value = target;
      spring.velocity = 0;
    }
  }

  @override
  String toString() => 'ViewerState(open: ' +
      _open.toString() +
      ', transition: ' +
      _transition.wire +
      ', surface: ' +
      _surface.wire +
      ', clarity: ' +
      clarity.toStringAsFixed(4) +
      ', spread: ' +
      spread.toStringAsFixed(4) +
      ')';
}
