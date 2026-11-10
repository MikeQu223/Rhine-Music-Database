// HUD gradient renderers ported 1:1 from the Qt client.
//
// Qt source of truth:
//  * right-mask  -> Qt/src/Glyphs.cpp:775-805 (QLinearGradient + 16-step
//    smoothstep alpha ramp, PadSpread fill).
//  * gradient    -> Qt/src/Glyphs.cpp:806-812 (QRadialGradient centred on the
//    1080p stage, three fixed stops, dark/light pair, PadSpread fill).
//  * colour wire -> Qt/src/Glyphs.cpp:35-49 (`color(a[1])`: calibrated gamma
//    1.8 + sRGB encode for RGB, alpha passed through untouched).
//  * item paint  -> Qt/src/Hud.cpp:18-19 (setOpaquePainting(false),
//    setAntialiasing(true)); the HUD item geometry clips the painted content.
//
// This file owns geometry/colour construction only. The 17-op command stack
// (save/restore/alpha/clip/rotate/dash/arc/...) is the painter atom's job
// (lib/hud/render/hud_painter.dart); the right-mask *fill rectangle*
// `QRectF(start, 0, n(4) - start, n(5))` (Qt/src/Glyphs.cpp:805) is likewise
// applied by the painter, not here.
//
// CITATION NOTE: third_party/qt is an unpopulated submodule in this worktree
// (qtbase/ is empty), so qcolor.cpp line numbers are upstream Qt 6 references,
// not files verified in-tree. Everything cited from Qt/src and Qt/qml was read
// in this tree.
import 'dart:ui' as ui;

/// Number of smoothstep segments in the Qt right-mask gradient.
///
/// `Qt/src/Glyphs.cpp:797`: `constexpr int MaskSteps = 16;` and the loop runs
/// `step <= MaskSteps` (`Qt/src/Glyphs.cpp:798`), so a mask carries
/// [hudRightMaskSteps] + 1 == 17 colour stops.
const int hudRightMaskSteps = 16;

/// Qt's smoothstep easing for one right-mask stop.
///
/// `Qt/src/Glyphs.cpp:800`:
/// `const auto eased = progress * progress * (3 - 2 * progress);`
///
/// The mapping is exact: 0 -> 0, 0.5 -> 0.5, 1 -> 1.
double hudRightMaskEase(double progress) =>
    progress * progress * (3 - 2 * progress);

/// The 17 colour stops of the Qt right-mask ramp, in wire order.
///
/// Mirrors `Qt/src/Glyphs.cpp:798-804`:
/// ```cpp
/// for (int step = 0; step <= MaskSteps; ++step) {
///   const auto progress = double(step) / MaskSteps;
///   const auto eased = progress * progress * (3 - 2 * progress);
///   auto stopColor = baseColor;
///   stopColor.setAlphaF(baseColor.alphaF() * eased);
///   gradient.setColorAt(progress, stopColor);
/// }
/// ```
///
/// Only the alpha changes: RGB is copied from [base] unchanged, exactly like
/// `stopColor = baseColor; stopColor.setAlphaF(...)` (Qt/src/Glyphs.cpp:801-802).
/// `QColor::setAlphaF` clamps to [0, 1] before storing (qcolor.cpp:1673-1683),
/// hence the clamp below.
///
/// Alpha representation note: Flutter's [ui.Color.a] is already the 0..1 float
/// that `QColor::alphaF()` returns (dart:ui painting.dart stores
/// `final double a`), while the frozen contract spells the byte as
/// `round(clamp01(base.a / 255.0 * eased) * 255)` for an 8-bit getter. The
/// emitted alpha *byte* is exactly that expression with `base.a` as the
/// fractional alpha: `round(clamp01(base.a * eased) * 255)`. The stop colour
/// keeps the unquantised float alpha so stop 16 is bit-identical to [base]
/// (Qt stores 16-bit alpha, qcolor.cpp:1673-1683, so quantising to 8 bits here
/// would be a lossy deviation from Qt).
List<ui.Color> hudRightMaskStopColors(ui.Color base) {
  final double baseAlpha = _clamp01(base.a);
  final List<ui.Color> stops = <ui.Color>[];
  for (int step = 0; step <= hudRightMaskSteps; step++) {
    final double progress = step / hudRightMaskSteps;
    final double eased = hudRightMaskEase(progress);
    final double alpha = _clamp01(baseAlpha * eased);
    stops.add(base.withValues(alpha: alpha));
  }
  return List<ui.Color>.unmodifiable(stops);
}

/// Qt's right-mask gradient: `QLinearGradient(QPointF(start, 0),
/// QPointF(start + span, 0))` (`Qt/src/Glyphs.cpp:796`) with the 17 stops of
/// [hudRightMaskStopColors].
///
/// Qt's default gradient spread is PadSpread, so the Flutter shader clamps
/// outside the segment ([ui.TileMode.clamp]); the left half of the fill keeps
/// the transparent stop and the right half keeps the fully opaque one.
///
/// Degenerate input: Qt does not define a `span <= 0` linear gradient
/// (both endpoints coincide). This helper still builds the wire geometry
/// verbatim instead of inventing a fallback; the painter must record a
/// malformed-argument issue for such a command (UNMEASURED: Qt never renders
/// it in the captured 1080p streams).
ui.Gradient hudRightMaskGradient(ui.Color base, double start, double span) {
  final List<double> stops = <double>[
    for (int step = 0; step <= hudRightMaskSteps; step++)
      step / hudRightMaskSteps,
  ];
  return ui.Gradient.linear(
    ui.Offset(start, 0),
    ui.Offset(start + span, 0),
    hudRightMaskStopColors(base),
    stops,
    ui.TileMode.clamp,
  );
}

/// Stage-space centre of the background radial gradient.
///
/// `Qt/src/Glyphs.cpp:807`: `QRadialGradient gradient(QPointF(979.2, 518.4), 1100);`
/// The 1080p stage is 1920x1080 (Qt/qml/Overlay.qml:19-23, 180-183), so the
/// centre sits slightly right of and below the stage centre.
const double hudBackgroundGradientCenterX = 979.2;

/// Stage-space centre of the background radial gradient.
///
/// `Qt/src/Glyphs.cpp:807` (see [hudBackgroundGradientCenterX]).
const double hudBackgroundGradientCenterY = 518.4;

/// Radius of the background radial gradient in stage units.
///
/// `Qt/src/Glyphs.cpp:807`: `QRadialGradient gradient(QPointF(979.2, 518.4), 1100);`
const double hudBackgroundGradientRadius = 1100;

/// The three fixed gradient stops.
///
/// `Qt/src/Glyphs.cpp:809-811` sets colours at 0, .76 and 1; Qt's
/// `setColorAt` takes the position as-is, so the stop list is exactly
/// `[0, .76, 1]` (no re-normalisation).
const List<double> hudBackgroundGradientStops = <double>[0, .76, 1];

/// One of the three fixed background gradient colours.
///
/// `Qt/src/Glyphs.cpp:808-811`:
/// ```cpp
/// const bool dark = a.size() > 1 && a[1].toBool();
/// gradient.setColorAt(0,   dark ? QColor(32, 42, 47)   : QColor(231, 231, 225));
/// gradient.setColorAt(.76, dark ? QColor(23, 33, 37)   : QColor(227, 225, 220));
/// gradient.setColorAt(1,   dark ? QColor(17, 24, 27)   : QColor(228, 223, 219));
/// ```
///
/// `QColor(int, int, int)` is fully opaque, so every returned colour has
/// alpha 255. [stop] outside 0..2 is not a Qt input; it throws [RangeError]
/// instead of silently picking a neighbouring stop.
ui.Color hudBackgroundGradientColor({required bool dark, required int stop}) {
  if (stop == 0) {
    return dark ? const ui.Color(0xFF202A2F) : const ui.Color(0xFFE7E7E1);
  }
  if (stop == 1) {
    return dark ? const ui.Color(0xFF172125) : const ui.Color(0xFFE3E1DC);
  }
  if (stop == 2) {
    return dark ? const ui.Color(0xFF11181B) : const ui.Color(0xFFE4DFDB);
  }
  throw RangeError.range(stop, 0, 2, 'stop');
}

/// Qt's background radial gradient.
///
/// `Qt/src/Glyphs.cpp:807-811`: `QRadialGradient(QPointF(979.2, 518.4), 1100)`
/// with the stops [hudBackgroundGradientStops]. Qt's default spread is
/// PadSpread, mapped to [ui.TileMode.clamp]; [hudBackgroundGradientRect] is the
/// rectangle Qt fills with it (`Qt/src/Glyphs.cpp:812`).
ui.Gradient hudBackgroundGradient({required bool dark}) {
  return ui.Gradient.radial(
    const ui.Offset(hudBackgroundGradientCenterX, hudBackgroundGradientCenterY),
    hudBackgroundGradientRadius,
    <ui.Color>[
      hudBackgroundGradientColor(dark: dark, stop: 0),
      hudBackgroundGradientColor(dark: dark, stop: 1),
      hudBackgroundGradientColor(dark: dark, stop: 2),
    ],
    hudBackgroundGradientStops,
    ui.TileMode.clamp,
  );
}

/// The rectangle Qt fills with [hudBackgroundGradient].
///
/// `Qt/src/Glyphs.cpp:812`: `c.fillRect(QRectF(-4096, -4096, 8192, 8192), gradient);`
///
/// Deliberately `final`, not `const`: `ui.Rect.fromLTWH` is not a const
/// constructor in dart:ui, so the frozen contract's constant cannot be const.
final ui.Rect hudBackgroundGradientRect =
    ui.Rect.fromLTWH(-4096, -4096, 8192, 8192);

double _clamp01(double value) {
  if (value <= 0) {
    return 0.0;
  }
  if (value >= 1) {
    return 1.0;
  }
  return value;
}
