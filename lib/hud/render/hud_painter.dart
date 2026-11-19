//  · native HUD render entry — the CustomPainter that replays one decoded
// snapshot onto the stage.
//
// Ownership split (must not blur):
//
//   * wire shape, op names, parameter indices ... lib/hud/protocol/hud_command.dart
//   * op semantics (17 ops, state stack, alpha, clip, dash, arc,
//     right-mask, gradient) ...................... lib/hud/render/paint_stack.dart
//   * stage transform, item clip, delegation ..... this file
//
// Qt paints the overlay through a QQuickPaintedItem whose entire content is one
// command walk:
//
//   void Hud::paint(QPainter *painter) {
//       painter->save();
//       painter->scale(height() / 1080, height() / 1080);
//       m_engine->glyphs()->commands(*painter, m_engine->commands(), ...);
//       painter->restore();
//   }                                              Qt/src/Hud.cpp:118-174
//
// The item is declared as `Hud { anchors.fill: parent; engine: rhine }`
// (Qt/qml/Overlay.qml:81-84), so its geometry is the whole overlay in logical
// pixels, and a QQuickPaintedItem clips its content to that geometry (the item
// also sets `setOpaquePainting(false)` / `setAntialiasing(true)` in
// Qt/src/Hud.cpp:17-20). `painter->scale` keeps the painter's default origin,
// which for a QQuickPaintedItem is the item's top-left corner — the same origin
// QML names as `transformOrigin: Item.TopLeft` for the scaled hit layer
// (Qt/qml/Overlay.qml:184).
//
// One stage unit therefore maps to `stageScale` logical pixels with the origin
// pinned at the item's top-left, and no coordinate is rounded: a stage pixel can
// be smaller than one device pixel and the plan forbids rounding it
// (docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:123).
//
// The wire stays a flat JSON array — element 0 is the op name and there is no
// envelope, id, sequence number or z index (Qt/src/Glyphs.cpp:637-640). This
// file never re-reads that wire: [envelope] is already the decoded result, and
// it never re-derives op semantics; it hands the decoded list to
// [paintHudCommands] unchanged and in order (no sort, no dedupe, no merge).
//
// Local wrapper, not Qt wire: `generation` / `frame` / `hits` / `state` on the
// envelope are assembled on the Flutter side
// (lib/hud/protocol/hud_frame.dart:216-295). This painter consumes only
// `commands`; the same envelope instance carries the hits for the hit layer and
// the frame/state for the widgets, so one snapshot is published whole.
//
// LAYERING: the protocol package is pure Dart; only this render layer imports
// Flutter, and only `package:flutter/rendering.dart` for the [CustomPainter]
// base (which `dart:ui` alone does not provide). No Material, no Widget, no
// theme lookup: the painter draws the wire, nothing else.
//
// CITATION NOTE: third_party/qt is an unpopulated submodule in this worktree
// (qtbase/ is empty), so qpainter.cpp line numbers below are upstream Qt 6
// references, not files verified in-tree. Flutter lines are cited as
// `packages/flutter/lib/src/rendering/custom_paint.dart` relative to the SDK
// root; the behaviour was read from the local SDK checkout, which is outside
// this repository.

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../protocol/hud_command.dart';
import '../protocol/hud_frame.dart';
import 'paint_stack.dart';

/// Resource lookups for the four HUD ops that need something the renderer cannot
/// synthesise on its own.
///
/// The op dispatch reads them as these exact call sites:
///
/// * `text` — `text(c, a[1].toString(), n2, n3, n4, a[5].toString(), n6,
///   color(a[7]))` (Qt/src/Glyphs.cpp:715). The body is
///   Qt/src/Glyphs.cpp:530-564: it translates to `(x, y + size * 1.044)` and
///   scales by `size / 1000` with a flipped y axis, so **the port receives the
///   em-box top-left corner** and the 1.044 baseline shift belongs to the text
///   implementation, never to this port. Signature provenance (read-only,
///   another 文件): `GlyphText.paintText(canvas, text, x, y, size, {weight,
///   tracking, required ui.Paint ink})` in  `lib/hud/text/glyph_run.dart:494`.
///   This port takes a resolved [ui.Color]; the binding layer turns it into
///   that `ui.Paint` ( paints through an ink paint, not a colour).
/// * `art` — `art(c, a[1].toString(), n2, n3, n4, letters, n6)` with
///   `const int letters = a[5].toInt(-1)` (Qt/src/Glyphs.cpp:718,726-727) and a
///   brush already set from `color(a[7])`. Its body (Qt/src/Glyphs.cpp:565-588)
///   translates to `(x, y)` with **no** baseline factor, so `y` is the top of
///   the art box. Signature provenance:  `lib/hud/text/art_run.dart:118`,
///   `paintArt(canvas, fonts, key, x, y, size, {count, tracking, color})` - the
///   font set is bound by the widget layer, so this port exposes the same
///   arguments minus the fonts it cannot own.
/// * `path` — `path(a[1].toString())` for `fill-path`
///   (Qt/src/Glyphs.cpp:737) and for `path` (Qt/src/Glyphs.cpp:748). A null
///   lookup is reported by [paintHudCommands] as
///   [HudPaintIssueKind.missingPath]; it is never dropped silently.
/// * `image` — `image(a[1].toString())` for `image`
///   (Qt/src/Glyphs.cpp:821-824); null becomes
///   [HudPaintIssueKind.missingImage].
///
/// All four are optional because Qt's own texture lookup is optional too: the Qt
/// call site passes a `std::function` that may return a null `QImage`, and each
/// op decides what "missing" means. What differs is that Qt's missing case is a
/// silent no-op, while the paint stack records an issue — the iron rule is that a
/// *known* op must never be swallowed without a trace
/// (docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:584).
final class HudPainterPorts {
  const HudPainterPorts({this.text, this.art, this.path, this.image});

  /// Draws one text run; receives the em-box top-left corner (not the baseline).
  final HudTextDrawFn? text;

  /// Draws one art run; receives the top of the art box (no baseline shift).
  final HudArtDrawFn? art;

  /// Resolves the glyph path a `path` / `fill-path` command names.
  final HudPathLookupFn? path;

  /// Resolves the texture an `image` command names.
  final HudImageLookupFn? image;
}

/// Paints one decoded HUD snapshot: the Qt stage transform, the item clip, and
/// the ordered command walk.
///
/// Usage is a single `CustomPaint` over the overlay:
///
/// ```dart
/// HudStagePainter(envelope: snapshot, ports: ports, onPainted: collect)
/// ```
///
/// The painter is immutable; a new snapshot means a new painter instance (the
/// widget layer rebuilds from one [HudFrameEnvelope]), which is also what
/// [shouldRepaint] keys on.
final class HudStagePainter extends CustomPainter {
  HudStagePainter({
    required this.envelope,
    required this.ports,
    this.stage,
    this.onPainted,
  });

  /// The decoder's output for one snapshot.
  ///
  /// Every command in `envelope.commands.commands` is executed, in list order.
  /// Decode-level defects (unknown op names, malformed arrays) were already
  /// dropped or flagged by lib/hud/protocol/hud_command.dart and stay on
  /// `envelope.commands.issues`; they are not copied into [HudPaintResult],
  /// whose issue set is defined by the paint stack and covers the draw layer
  /// only (missing ports, unbalanced restore, non-positive dash). A caller that
  /// wants one complete report concatenates `envelope.commands.issues` and
  /// `result.issues`, keeping each list's own order.
  final HudFrameEnvelope envelope;

  /// Draw ports handed to the command walk unchanged.
  final HudPainterPorts ports;

  /// Stage override for a caller that already resolved the geometry.
  ///
  /// When null, [paint] derives it with [HudStage.fromLogicalSize], which is
  /// `scale = height > 0 ? height / 1080 : 1` and `width = width / scale`
  /// (Qt/qml/Overlay.qml:22-23) — the same stage the engine reports as
  /// `m_height > 0 ? m_width / (m_height / 1080) : 1920`
  /// (Qt/src/Engine.cpp:1353, cited by lib/hud/protocol/hud_frame.dart:360-365,
  /// `HudStage.engineHudWidth`).
  ///
  /// A supplied stage is authoritative: the golden pins
  /// `1920 x 1080` to `scale = 1`, and a widget may pass the stage it also uses
  /// for hit testing so commands and hits share one coordinate system. This
  /// painter does not validate that `stage.width * stage.scale == size.width`;
  /// Qt has the same single source of truth (the item rect) and would simply
  /// paint the surplus area, so a mismatch is a caller bug, not a painter
  /// branch.
  final HudStage? stage;

  /// Called once per [paint] with the completed paint result.
  ///
  /// The callback runs *after* `canvas.restore()`, so the reported
  /// [HudPaintResult.state] is exactly the stack the frame ended in — Qt ends
  /// every frame with the matching `painter->restore()`
  /// (Qt/src/Hud.cpp:166) and warns only when a command left the stack
  /// unbalanced (third_party/qt/qtbase/src/gui/painting/qpainter.cpp:1603-1606,
  /// surfaced as [HudPaintIssueKind.unbalancedRestore]).
  ///
  /// It is a reporting hook (tests, golden diffing, diagnostics), not a paint
  /// input, so it does not participate in [shouldRepaint]: swapping only the
  /// callback never changes a pixel, and keying repaints on a closure identity
  /// would repaint every frame for a widget that recreates the closure.
  final void Function(HudPaintResult result)? onPainted;

  /// Maps stage units to logical pixels and replays the command list.
  ///
  /// Three steps, mirroring Qt/src/Hud.cpp:151-166:
  ///
  /// 1. `painter->save()` → `canvas.save()`;
  /// 2. the item clip, then `painter->scale(height() / 1080, height() / 1080)`
  ///    → `canvas.clipRect(itemRect)` followed by `canvas.scale(scale, scale)`;
  /// 3. the command walk, then `painter->restore()` → `canvas.restore()`.
  ///
  /// The clip is applied **before** the scale on purpose: in logical pixels the
  /// item rect is `(0, 0, size.width, size.height)`, i.e. exactly the
  /// QQuickPaintedItem geometry, so clipping needs no division by the scale and
  /// cannot drift on a fractional scale. Applying it after the scale with
  /// `size / scale` would compute the same rect through one extra rounding step.
  ///
  /// The item clip is drawn with `doAntiAlias: false`. Qt never antialiases it
  /// either: an integer-aligned `QRectF` clip is routed to
  /// `setClipRect(const QRect &, ...)`, which assigns a `QRegion`
  /// (third_party/qt/qtbase/src/gui/painting/qpainter.cpp:2773-2781 and :2825),
  /// and the item's raster bounds are `qCeil`-rounded whole pixels
  /// (Qt/src/Hud.cpp:182). Antialiasing stays on for the *content*, which is what
  /// `setAntialiasing(true)` buys (Qt/src/Hud.cpp:19) and what the plan demands
  /// for a stage pixel smaller than a device pixel without rounding
  /// (docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:123); it is
  /// not extended to the boundary scissor.
  ///
  /// The base signature is `void paint(Canvas canvas, Size size)`
  /// (Flutter SDK packages/flutter/lib/src/rendering/custom_paint.dart:206);
  /// `ui.Canvas` / `ui.Size` are those same dart:ui types written with an
  /// explicit import prefix, not substitutes.
  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final HudStage resolvedStage =
        stage ?? HudStage.fromLogicalSize(width: size.width, height: size.height);
    final List<HudCommand> commands = envelope.commands.commands;

    canvas.save();
    // QQuickPaintedItem clips its content to the item geometry (Qt/src/Hud.cpp:17-20
    // constructs a plain QQuickPaintedItem; its paint() never widens the clip).
    // The clip is hard-edged, not antialiased: a QRectF clip that lands on
    // integer edges is handed to the QRect overload, which stores a QRegion
    // (qpainter.cpp:2773-2781 -> :2825), and the item's raster bounds are
    // ceil-rounded to whole pixels (Qt/src/Hud.cpp:182,
    // `const QSize logical(qCeil(width()), qCeil(height()))`).
    canvas.clipRect(ui.Offset.zero & size, doAntiAlias: false);
    if (_isPaintableScale(resolvedStage.scale)) {
      // Qt/src/Hud.cpp:151-152 — scale first, origin stays at the item's
      // top-left, no translate. Equivalent to QML `transformOrigin: Item.TopLeft`
      // (Qt/qml/Overlay.qml:184).
      canvas.scale(resolvedStage.scale, resolvedStage.scale);
    } else {
      // A degenerate stage can only come from an explicit caller argument:
      // HudStage.fromLogicalSize guards height == 0 with a scale of 1
      // (Qt/qml/Overlay.qml:22). `painter->scale(0, 0)` is a singular matrix
      // that paints nothing, so the equivalent here is an empty clip. The
      // command walk below still runs so that known ops keep reporting their
      // issues through [onPainted] instead of being swallowed by the guard.
      canvas.clipRect(ui.Rect.zero);
    }

    final HudPaintResult result = paintHudCommands(
      canvas: canvas,
      commands: commands,
      text: ports.text,
      art: ports.art,
      path: ports.path,
      image: ports.image,
    );

    canvas.restore();
    onPainted?.call(result);
  }

  /// Repaints when the snapshot, the ports or the stage change.
  ///
  /// Qt connects `Engine::hudUpdated` to a repaint (Qt/src/Hud.cpp:30), i.e. one
  /// repaint per published step; the Flutter equivalent is one repaint per new
  /// [envelope]. Identity is the right test because a new snapshot is a new
  /// object, and `generation` alone is not enough: the local adapter may re-emit
  /// a snapshot at the same counter after a rebuild, and hits/state ride the same
  /// envelope even when the command list is unchanged.
  ///
  /// Ports compare by identity per port: they are lookups/handlers, and a
  /// different instance can mean different fonts or textures, so equal-looking
  /// closures must still repaint. [onPainted] is excluded — see its doc.
  ///
  /// Narrowing the parameter to [HudStagePainter] is a legal override, not a
  /// signature drift: the base declaration already marks it covariant —
  /// `bool shouldRepaint(covariant CustomPainter oldDelegate)`
  /// (Flutter SDK packages/flutter/lib/src/rendering/custom_paint.dart:271)
  /// — so every call site still passes a [CustomPainter]. The one caller,
  /// `RenderCustomPaint._didUpdatePainter`, only reaches
  /// `newPainter.shouldRepaint(oldPainter)` after the
  /// `newPainter.runtimeType != oldPainter.runtimeType` short-circuit fails
  /// (custom_paint.dart:455-457), so the narrowed parameter can never receive a
  /// foreign painter at runtime. (The covariant parameter is also what the
  /// `covariant` keyword on the base declaration exists for.)
  @override
  bool shouldRepaint(covariant HudStagePainter old) {
    if (!identical(old.envelope, envelope)) {
      return true;
    }
    if (!_samePorts(old.ports, ports)) {
      return true;
    }
    return !_sameStage(old.stage, stage);
  }
}

/// True when [scale] can build a non-singular canvas transform.
bool _isPaintableScale(double scale) => scale.isFinite && scale > 0;

/// Per-port identity comparison; a painter needs a repaint when any port moves.
bool _samePorts(HudPainterPorts a, HudPainterPorts b) =>
    identical(a.text, b.text) &&
    identical(a.art, b.art) &&
    identical(a.path, b.path) &&
    identical(a.image, b.image);

/// Value comparison for the optional stage.
///
/// [HudStage] carries no `==` (lib/hud/protocol/hud_frame.dart:340-358), and it
/// does not need one: the three doubles are the whole state, and a stage that
/// differs in any of them maps stage units to different pixels.
bool _sameStage(HudStage? a, HudStage? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  return a.scale == b.scale && a.width == b.width && a.height == b.height;
}
