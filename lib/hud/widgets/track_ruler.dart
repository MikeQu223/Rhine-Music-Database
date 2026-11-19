///  / W4 - archive track list and track ruler (曲目表 + 刻度标尺).
///
/// 1:1 port of the Qt Android reference implementation:
///   * Qt/src/NativeHud.h:168-173    - struct TrackRulerRow
///   * Qt/src/NativeHud.cpp:516-533  - NativeHud::archiveTrackPosition
///   * Qt/src/NativeHud.cpp:535-593  - NativeHud::archiveTrackList
///   * Qt/src/NativeHud.cpp:595-624  - NativeHud::archiveTrackRuler
///   * Qt/src/UiMotion.h:12-22 and Qt/src/UiMotion.cpp:58-84 - UiMotion::ReelCurve
///   * Qt/src/Glyphs.cpp:312-338     - Glyphs::bounds (vertical metrics, see HudGlyphBoundsPort)
///
/// Contract: chrome.dart owns HudWireCommand (wire alias) / HudHit (re-exported from
/// protocol/hud_hit.dart) / HudSurfaceSink / HudTextPort /
/// hudInk / hudFill / hudPath. This library only consumes them; nothing here is re-declared
/// and no Material widget, no Flutter widget and no texture is used.
///
/// Command shapes emitted here (parity plan 4.2, docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:189-205):
///   ['save'] / ['restore'] / ['alpha', v] / ['clip', x, y, w, h]
///   ['text', value, x, y, size, weight, tracking, color]
///   ['path', d, penWidth, color] / ['fill-path', d, color]
/// Hits are emitted in the same loop as the drawing, in source order, and are never
/// reordered or deduplicated (parity plan 4.3).
///
/// Known integration requirements:
///   N1. Vertical glyph metrics: HudTextPort carries only horizontal metrics, while Qt needs
///       bounds(...).y/.height. Inject HudGlyphBoundsPort (constructor argument, else the text
///       port itself if it implements the interface). Without it the ruler anchors on the
///       baseline - see HudTrackRuler.glyphBoundsAvailable.
///   N2. ReelCurve.samplePair mirrors Qt std::array<double,2> (value, velocity); the W4
///       contract also requires the value-only form ReelCurve.sample(double) -> double.
library;

import 'dart:math' as math;

import '../pages/chrome.dart';

// UiMotion::ReelCurve

/// Qt UiMotion::ReelCurve (UiMotion.h:12-22, UiMotion.cpp:58-84).
///
/// The constructor precomputes a fixed 49 point table; sample() linearly interpolates it
/// and returns both the value and the instantaneous velocity.
class ReelCurve {
  ReelCurve(this.from, this.to, this.velocity, this.startTime, [this.duration = 0.46]) {
    // UiMotion.cpp:65-67.
    final displacement = from - to;
    final cap = (math.max(displacement.abs(), 1.0) * 12) / duration;
    final impulse = _clamp(velocity, -cap, cap) * duration;
    // UiMotion.cpp:68-73: exactly 49 points, index 48 is forced to target.
    for (var i = 0; i <= 48; i++) {
      final t = i / 48.0;
      _points[i] = i == 48
          ? to
          : to + (displacement + (impulse + 10 * displacement) * t) * math.exp(-10 * t);
    }
  }

  /// UiMotion.cpp:63 constructor arguments, kept public as in UiMotion.h:17-18.
  final double from;
  final double to;
  final double velocity;

  /// UiMotion.h:17 `double start`; the W4 contract names the parameter startTime.
  final double startTime;

  /// UiMotion.h:18 `double duration = 0.46`. The track list always constructs the curve
  /// with 0.64 explicitly (NativeHud.cpp:525 and NativeHud.cpp:528).
  double duration;

  /// UiMotion.h:21 `std::array<double, 49> m_points{}`.
  final List<double> _points = List<double>.filled(49, 0);

  /// Qt ReelCurve::sample (UiMotion.cpp:76-84) returns std::array<double, 2>:
  /// element 0 is the position, element 1 the velocity that the next curve inherits
  /// (NativeHud.cpp:528 passes position[1] straight back into the constructor).
  List<double> samplePair(double time) {
    final position = _clamp((time - startTime) / duration, 0.0, 1.0) * 48;
    if (position >= 48) {
      return <double>[_points[48], 0];
    }
    final index = position.floor();
    return <double>[
      _points[index] + (_points[index + 1] - _points[index]) * (position - index),
      ((_points[index + 1] - _points[index]) * 48) / duration,
    ];
  }

  /// Value-only entry point required by the W4 contract: exactly samplePair(time)[0].
  double sample(double time) => samplePair(time)[0];
}

// Glyphs::bounds - vertical text metrics

/// Qt Glyphs::bounds() result (Glyphs.cpp:312-338): the outline bounding box of one laid
/// out run in the run local frame, y relative to the baseline origin (negative above it).
class GlyphBounds {
  const GlyphBounds({required this.x, required this.y, required this.width, required this.height});

  final double x;
  final double y;
  final double width;
  final double height;

  /// Neutral element: baseline anchor with no vertical extent. Used only when no
  /// HudGlyphBoundsPort was injected (see HudTrackRuler.glyphBoundsAvailable).
  static const GlyphBounds zero = GlyphBounds(x: 0, y: 0, width: 0, height: 0);
}

/// Vertical-metric companion of HudTextPort.
///
/// archiveTrackList needs bounds(...).y/.height twice: NativeHud.cpp:545-546 for 音乐 and
/// NativeHud.cpp:579-580 for every row. The frozen chrome.dart contract exposes only
/// glyphWidth / glyphInset / fit / rolling, so the vertical half is injected here - either
/// as the glyphBounds constructor argument of HudTrackRuler, or by making the injected text
/// port implement this interface.
abstract class HudGlyphBoundsPort {
  GlyphBounds glyphBounds(String value, double size, [String weight = 'regular']);
}

// Data types

/// Qt NativeHud::TrackRulerRow (NativeHud.h:168-173).
class TrackRulerRow {
  TrackRulerRow({this.centerY = 0, this.textRight = 0, this.emphasis = 0, this.opacity = 1});

  double centerY;
  double textRight;
  double emphasis;
  double opacity;
}

/// One element of m_music->libraryItems() as consumed by archiveTrackList
/// (NativeHud.cpp:537, :560, :576). Only kind == 'song' rows are drawn.
class TrackListItem {
  const TrackListItem({required this.title, required this.kind});

  final String title;
  final String kind;
}

/// Collection identity of archiveTrackPosition (NativeHud.cpp:518-520).
class TrackListScope {
  const TrackListScope({
    required this.provider,
    required this.directoryIdentity,
    required this.hasDirectory,
    required this.selectedLane,
    required this.groupName,
  });

  final String provider;

  /// Qt uses QString::number(quintptr(m_music->directory.get())) - the identity of the live
  /// MusicDirectory object, not a path. The caller supplies the equivalent stable identity
  /// string for its current collection object.
  final String directoryIdentity;

  /// Qt `m_music->directory ? QString() : ...`: the lane number only takes part in the key
  /// when there is no directory.
  final bool hasDirectory;

  final int selectedLane;
  final String groupName;

  /// NativeHud.cpp:518-520, literally:
  /// provider + ':' + directoryIdentity + ':' + (hasDirectory ? '' : selectedLane) + ':' + groupName
  String get scopeKey =>
      '$provider:$directoryIdentity:${hasDirectory ? '' : selectedLane}:$groupName';
}

// HudTrackRuler

/// 列表裁剪窗口（也是可拖动/可点选窗口）的锚点，Qt `NativeHud.cpp:543-555` 的常量：
/// 选中行基线上移到 `titleY`，窗口上沿在 `titleY - trackRulerWindowTopOffset`，
/// 高 `trackRulerWindowHeight`（上 290 / 下 320，本来就不对称）。
///
/// 这三个量是「列表块在舞台里的位置」的唯一真值：竖屏把列表搬进第二带时要减掉
/// `trackRulerWindowTopOffset`（否则会多平移一整块表头空档），命中矩形与绘制都
/// 从这里取，不许各自拍一套数字。
const double trackRulerTitleY = 509.0;
const double trackRulerWindowTopOffset = 290.0;
const double trackRulerWindowHeight = 610.0;

/// 窗口上沿相对列表块原点的 y（= 219）。竖屏把窗口上沿对齐到带顶时用它换算。
const double trackRulerWindowTop = trackRulerTitleY - trackRulerWindowTopOffset;

/// Draws the archive track list and the ruler that shares its displacement
/// (NativeHud.cpp:535-624).
///
/// Stateless by construction: the curve, scope and target that Qt keeps in
/// m_trackListCurve / m_trackListScope / m_trackListTarget (NativeHud.h:202-204) are passed
/// in by the page and handed back through the onCurve outlet, so the page owns the state.
class HudTrackRuler {
  HudTrackRuler(this.sink, this.text, {this.dark = false, HudGlyphBoundsPort? glyphBounds})
      : _glyphBounds =
            glyphBounds ?? (text is HudGlyphBoundsPort ? text as HudGlyphBoundsPort : null);

  /// Injection outlet for commands and hits (chrome.dart).
  final HudSurfaceSink sink;

  /// Glyph / text port (chrome.dart). This library never measures glyphs itself.
  final HudTextPort text;

  /// Qt `dark` theme flag, used verbatim at NativeHud.cpp:550 and NativeHud.cpp:597.
  final bool dark;

  final HudGlyphBoundsPort? _glyphBounds;

  /// False when neither the constructor argument nor the injected text port supplies
  /// vertical glyph metrics. The list then anchors on the baseline instead of the visual
  /// text centre - a documented degradation, never a fabricated metric.
  bool get glyphBoundsAvailable => _glyphBounds != null;

  GlyphBounds _bounds(String value, double size, String weight) =>
      _glyphBounds?.glyphBounds(value, size, weight) ?? GlyphBounds.zero;

  /// 用连续曲目索引驱动整行位移；快速反向选曲接续当前的位置和速度。
  /// (NativeHud.cpp:516)
  ///
  /// Qt returns position[0] and mutates m_trackListCurve / m_trackListScope /
  /// m_trackListTarget. Here the caller passes lastScope / lastTarget / curve and receives
  /// the adopted curve, scope and target through onCurve - called on every path, exactly
  /// like Qt lines 530-531 run unconditionally.
  double archiveTrackPosition({
    required int selected,
    required TrackListScope scope,
    required String? lastScope,
    required int lastTarget,
    required bool reduced,
    required double lastTime,
    required ReelCurve? curve,
    required void Function(ReelCurve curve, TrackListScope scope, int target) onCurve,
  }) {
    // NativeHud.cpp:518-520.
    final scopeKey = scope.scopeKey;
    // NativeHud.cpp:521.
    final sameCollection = scopeKey == lastScope;
    // NativeHud.cpp:522-523.
    final sampled = curve != null
        ? curve.samplePair(lastTime)
        : <double>[selected.toDouble(), 0];
    var position = sampled[0];
    late ReelCurve next;
    // NativeHud.cpp:524-526.
    if (reduced || !sameCollection || curve == null || (selected - position).abs() > 8) {
      next = ReelCurve(selected.toDouble(), selected.toDouble(), 0, lastTime - 0.64, 0.64);
      position = selected.toDouble();
    } else if (lastTarget != selected) {
      // NativeHud.cpp:527-529: continue from the sampled position and velocity.
      next = ReelCurve(position, selected.toDouble(), sampled[1], lastTime, 0.64);
    } else {
      next = curve;
    }
    // NativeHud.cpp:530-531: m_trackListScope = scope; m_trackListTarget = selected;
    onCurve(next, scope, selected);
    // NativeHud.cpp:532.
    return position;
  }

  /// 整首歌曲和对应刻度共用位移，不再使用逐字滚动；静止时保留原歌名字体和锚点。
  /// (NativeHud.cpp:535)
  void archiveTrackList({
    required double x,
    required double width,
    required List<TrackListItem> values,
    required int selected,
    required String selectedTitle,
    required double position,
  }) {
    // NativeHud.cpp:539-541.
    if (selected < 0 || selected >= values.length) {
      return;
    }
    // NativeHud.cpp:543-544.
    const titleY = trackRulerTitleY;
    const titleSize = 28.0;
    // NativeHud.cpp:545-546.
    final titleBounds = _bounds('音乐', titleSize, 'bold');
    final centerY = titleY + titleBounds.y + titleBounds.height / 2;
    // NativeHud.cpp:548-549.
    final rulerX = width - 160;
    final textWidth = math.max(1.0, rulerX - x - 68);
    // NativeHud.cpp:550.
    final gray = dark ? <double>[0.61, 0.62, 0.59, 1] : <double>[0.49, 0.49, 0.46, 1];
    final rows = <TrackRulerRow>[];
    // NativeHud.cpp:552-553.
    final first = math.max(0, position.floor() - 5);
    final last = math.min(values.length - 1, position.ceil() + 5);
    // NativeHud.cpp:554-555.
    sink.op(<Object?>['save']);
    sink.op(<Object?>['clip', x - 4, titleY - trackRulerWindowTopOffset, width - x, trackRulerWindowHeight]);
    // NativeHud.cpp:556-590.
    for (var index = first; index <= last; index++) {
      final relative = index - position;
      final distance = relative.abs();
      final opacity = _clamp(5 - distance, 0.0, 1.0);
      // NativeHud.cpp:560-562.
      if (opacity <= 0.001 || values[index].kind != 'song') {
        continue;
      }
      // NativeHud.cpp:563-565.
      final offset = distance <= 1 ? distance * 88 : 88 + (distance - 1) * 52;
      final rowY = titleY + _copySign(offset, relative);
      final emphasis = math.max(0.0, 1 - distance);
      // NativeHud.cpp:567-574: ink() blended towards gray, and the blended color is
      // rebuilt as a 4 element array (the calibrated marker of ink() is dropped there).
      var color = hudInk(dark);
      if (emphasis < 0.9999) {
        final blended = <double>[
          for (var channel = 0; channel < 3; channel++)
            gray[channel] * (1 - emphasis) + (color[channel] as double) * emphasis,
        ];
        color = <Object?>[blended[0], blended[1], blended[2], 1];
      }
      // NativeHud.cpp:575-576.
      final name = index == selected ? selectedTitle : values[index].title;
      // NativeHud.cpp:577-581.
      final shown = text.fit(name, titleSize, textWidth, 'bold');
      final left = x - text.glyphInset(shown, titleSize, 'bold');
      final rowBounds = _bounds(shown, titleSize, 'bold');
      rows.add(TrackRulerRow(
        centerY: rowY + rowBounds.y + rowBounds.height / 2,
        textRight: left + text.glyphWidth(shown, titleSize, 'bold'),
        emphasis: emphasis,
        opacity: opacity,
      ));
      // NativeHud.cpp:582-585.
      sink.op(<Object?>['save']);
      sink.op(<Object?>['alpha', opacity]);
      sink.op(<Object?>['text', shown, left, rowY, titleSize, 'bold', 0, color]);
      sink.op(<Object?>['restore']);
      // NativeHud.cpp:586-589: hit emitted in the same pass as the row it belongs to.
      if (rowY >= titleY - 270 && rowY <= titleY + 270 && opacity > 0.5) {
        sink.hit(HudHit(
          x: x,
          y: rowY - 4,
          width: textWidth,
          height: 44,
          action: index == selected ? 'open' : 'music:index:$index',
          label: name,
        ));
      }
    }
    // NativeHud.cpp:591-592.
    archiveTrackRuler(x: rulerX, centerY: centerY, rows: rows);
    sink.op(<Object?>['restore']);
  }

  /// 刻度与歌曲继续同步滑动；鞍座和箭头始终固定在当前行锚点，不跟随切歌重复入场。
  /// (NativeHud.cpp:595)
  void archiveTrackRuler({
    required double x,
    required double centerY,
    required List<TrackRulerRow> rows,
  }) {
    // NativeHud.cpp:597.
    final color = dark ? <double>[0.65, 0.67, 0.55, 0.8] : <double>[0.46, 0.48, 0.37, 0.75];
    // NativeHud.cpp:598 fill(x, centerY - 272, 1.5, 544, color);
    hudFill(sink, color, x, centerY - 272, 1.5, 544);
    // NativeHud.cpp:599-610.
    for (final row in rows) {
      sink.op(<Object?>['save']);
      sink.op(<Object?>['alpha', row.opacity]);
      // NativeHud.cpp:602-608.
      final length = 14 + 36 * row.emphasis;
      final leaderStart = math.min(x - length - 8, row.textRight + 20);
      final leader = <double>[
        color[0],
        color[1],
        color[2],
        0.12 + 0.16 * row.emphasis,
      ];
      hudFill(sink, leader, leaderStart, row.centerY - 0.4,
          math.max(0.0, x - length - leaderStart), 0.8);
      hudFill(sink, color, x - length, row.centerY - 0.6, length, 1.2);
      sink.op(<Object?>['restore']);
    }
    // NativeHud.cpp:611-623: saddle, bar and arrow are built by QString::arg from x/centerY.
    final y = centerY;
    final saddle = _saddlePath(x, y);
    hudPath(sink, saddle, 2, color);
    hudFill(sink, color, x + 10, y - 1, 16, 2);
    sink.op(<Object?>['fill-path', _arrowPath(x, y), color]);
  }

  /// NativeHud.cpp:612-618:
  /// M (x-6) (y-7) L (x-6) (y+4) Q (x-6) (y+11) (x+2) (y+11) Q (x+10) (y+11) (x+10) (y+4) L (x+10) (y-7)
  String _saddlePath(double x, double y) {
    final left = _num(x - 6);
    final right = _num(x + 10);
    final mid = _num(x + 2);
    final top = _num(y - 7);
    final low = _num(y + 4);
    final bulge = _num(y + 11);
    return 'M $left $top L $left $low Q $left $bulge $mid $bulge '
        'Q $right $bulge $right $low L $right $top';
  }

  /// NativeHud.cpp:621-622:
  /// M (x+18) y L (x+29) (y-5) L (x+29) (y+5) Z
  String _arrowPath(double x, double y) {
    final start = _num(x + 18);
    final tip = _num(x + 29);
    final center = _num(y);
    final up = _num(y - 5);
    final down = _num(y + 5);
    return 'M $start $center L $tip $up L $tip $down Z';
  }
}

// Local helpers

/// C++17 std::clamp, used verbatim at NativeHud.cpp:559 and UiMotion.cpp:67 and :77.
/// Mirrors the standard rather than num.clamp (which throws when low > high).
double _clamp(double value, double low, double high) {
  if (value < low) {
    return low;
  }
  return value > high ? high : value;
}

/// std::copysign(magnitude, sign), used verbatim at NativeHud.cpp:565, including the sign
/// bit of -0.0 (index == position) which keeps Qt's +offset result.
double _copySign(double magnitude, double sign) => sign.isNegative ? -magnitude : magnitude;

/// Number text inside SVG path data. Qt builds these strings with QString::arg(double)
/// (NativeHud.cpp:612-622) using the 'g' format; whole numbers therefore print without a
/// decimal point. Fractional values print the shortest round tripping decimal, which is
/// identical to Qt for the integral coordinates and differs from Qt's 6 significant digit
/// text only beyond the 6th digit (see report note V1).
String _num(double value) {
  if (!value.isFinite) {
    return value.toString();
  }
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toString();
}
