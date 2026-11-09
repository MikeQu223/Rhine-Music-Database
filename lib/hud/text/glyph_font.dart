// Faithful Dart port of the glyph resource layer in Qt/src/Glyphs.{h,cpp}.
//
// The Qt sources are the only authority for this module:
//
//  * misans-glyphs.json -> { weight: { units, ascent, descent, glyphs } } with
//    weights light/regular/demibold/bold, units = 1000, ascent = 1044,
//    descent = -282 and glyphs[char] = { advance: <em>, path: "<svg>" }.
//                                                              (Glyphs.cpp:75-82)
//  * the four RhineMiSans OTF faces plus NotoSansSymbols2-Regular.ttf are the
//    registered layout and symbol faces.                     (Glyphs.cpp:65-74)
//  * text is anchored on the TOP of the em box; the baseline sits
//    size * 1.044 below that anchor, because 1.044 == ascent / units.
//                                     (Glyphs.cpp:536, 547, 558, 316, 329)
//  * Glyph.path is ALWAYS y-up in font units: outlines read from the JSON
//    resource are stored exactly as authored, and outlines taken from a font
//    are flipped once with QTransform::fromScale(1, -1) so that both sources
//    agree.                                                    (Glyphs.cpp:282-283)
//  * a character with no outline yields the default Glyph, whose advance is
//    1 em and not 0.                                   (Glyphs.h:21, Glyphs.cpp:278)
//  * calibrated colors are linear gamma-1.8 and are converted to sRGB here,
//    never by the platform color pipeline.                    (Glyphs.cpp:35-49)

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

/// Font units per em shipped by misans-glyphs.json (identical for all weights).
const double kGlyphUnits = 1000;

/// Ascent in font units shipped by misans-glyphs.json.
const double kGlyphAscent = 1044;

/// Descent in font units shipped by misans-glyphs.json.
const double kGlyphDescent = -282;

/// Baseline offset below the em-box anchor: ascent / units == 1.044.
const double kBaselineFactor = kGlyphAscent / kGlyphUnits;

/// Advance of a character that has no outline at all (Glyphs.h:21).
const double kMissingGlyphAdvance = 1;

/// Weights shipped both as RhineMiSans-<weight>.otf and in the glyph resource.
const List<String> kGlyphWeights = <String>[
  'light',
  'regular',
  'demibold',
  'bold',
];

/// Weight used when a caller does not name one (Glyphs.h:25 default argument).
const String kDefaultGlyphWeight = 'regular';

/// Key under which the symbol face is registered in Qt (Glyphs.cpp:74).
///
/// The face itself is NotoSansSymbols2-Regular.ttf, which this layer cannot
/// parse; [GlyphFontSet.lookup] treats this key explicitly instead of letting
/// it land on the regular-weight resource table, which would hand out Latin
/// outlines for a request Qt answers from the symbol face.
const String kSymbolFontKey = 'symbols';

/// One outline: advance in em, outline in font units with y pointing up.
class Glyph {
  const Glyph({required this.advance, required this.path, this.bounds});

  /// Advance width in em (1.0 == one full em).
  final double advance;

  /// Outline in font units, y-up. Empty when the character has no outline.
  final ui.Path path;

  /// Tight bounds of [path] in font units, y-up, or null when the resource
  /// carried no point at all.
  ///
  /// Tight means Qt's QPainterPath::boundingRect(): curve extrema are solved
  /// analytically, not the control-point hull that Skia's Path.getBounds()
  /// returns. Qt asks boundingRect() in bounds() and inset()
  /// (Glyphs.cpp:327-330, 344-348), and a control-point hull is measurably
  /// larger for every curved outline, so the number is kept here instead of
  /// being recomputed from [path].
  final ui.Rect? bounds;

  /// True when the resource carried an outline, i.e. Qt's
  /// !path.isEmpty() (element count > 0), NOT "the path has area".
  ///
  /// A degenerate outline (a single moveTo, or a zero-height rectangle) is
  /// empty as a rectangle but still an element in Qt, and Qt still uses its
  /// boundingRect() x for inset(). Deriving this from bounds.isNotEmpty would
  /// silently drop those glyphs.
  bool get hasOutline => bounds != null;
}

/// The glyphs of one weight, keyed by the character string used on the Qt side.
class WeightGlyphs {
  WeightGlyphs({
    required this.weight,
    required this.units,
    required this.ascent,
    required this.descent,
    required Map<String, Glyph> glyphs,
  }) : _glyphs = glyphs;

  final String weight;
  final double units;
  final double ascent;
  final double descent;
  final Map<String, Glyph> _glyphs;

  int get glyphCount => _glyphs.length;

  Glyph? glyphFor(String character) => _glyphs[character];

  bool has(String character) => _glyphs.containsKey(character);

  Iterable<String> get characters => _glyphs.keys;
}

/// Coverage probe for the symbol face.
///
/// Qt asks the mapped NotoSansSymbols2 QRawFont whether it supports a code
/// point. A pure-Dart build cannot query an OTF without carrying a font parser,
/// so the probe is injected. The shipping implementation must answer exactly
/// what NotoSansSymbols2-Regular.ttf covers and must not invent extra ranges.
abstract class SymbolCoverage {
  const SymbolCoverage();

  bool supportsCodePoint(int codePoint);

  /// Fallback used when no probe is injected: the symbol face is treated as
  /// unavailable, which forces the fallback shaper to require real coverage.
  static const SymbolCoverage none = _NoSymbolCoverage();
}

class _NoSymbolCoverage extends SymbolCoverage {
  const _NoSymbolCoverage();

  @override
  bool supportsCodePoint(int codePoint) => false;
}

/// One boot lettering glyph: advance in em plus an outline in font units.
class LetteringGlyph {
  const LetteringGlyph({required this.advance, required this.path});

  final double advance;
  final ui.Path path;
}

/// One boot lettering key from boot-lettering-art.json.
class Lettering {
  Lettering({
    required this.key,
    required this.text,
    required this.weight,
    required this.units,
    required List<LetteringGlyph> letters,
  }) : letters = List<LetteringGlyph>.unmodifiable(letters);

  final String key;
  final String text;
  final String weight;
  final double units;
  final List<LetteringGlyph> letters;

  int get letterCount => letters.length;
}

/// Everything the glyph engine needs at run time.
class GlyphFontSet {
  GlyphFontSet({
    required Map<String, WeightGlyphs> weights,
    required Map<String, Lettering> lettering,
    SymbolCoverage symbols = SymbolCoverage.none,
  })  : _weights = weights,
        _lettering = lettering,
        _symbols = symbols;

  final Map<String, WeightGlyphs> _weights;
  final Map<String, Lettering> _lettering;
  final SymbolCoverage _symbols;

  /// A set with no resources loaded; useful as a null object, never as a
  /// shipping default (Qt fails hard instead, see Glyphs.cpp:28-33).
  static final GlyphFontSet empty = GlyphFontSet(
    weights: <String, WeightGlyphs>{},
    lettering: <String, Lettering>{},
  );

  Iterable<String> get weights => _weights.keys;

  WeightGlyphs? weight(String name) => _weights[name];

  Lettering? letteringFor(String key) => _lettering[key];

  Iterable<String> get letteringKeys => _lettering.keys;

  bool symbolSupports(int codePoint) => _symbols.supportsCodePoint(codePoint);

  /// Mirrors Glyphs::glyph (Glyphs.cpp:266-285).
  ///
  /// Qt's order is: resource glyphs of the requested weight, then that
  /// weight's OTF face, then the symbol face, and only after all three miss
  /// does it return the default glyph (Glyphs.cpp:266-285). This layer has no
  /// OTF parser, so the two face steps are unavailable and the resource table
  /// is the whole of the search: a character it does not carry resolves to the
  /// default glyph (advance 1 em, empty outline). That is narrower than Qt, not
  /// an early return inside an equivalent search.
  ///
  /// Two deliberate approximations stand in for the OTF faces:
  ///
  ///  * an unknown weight falls back to the default weight resource table,
  ///    mirroring Qt fonts.value(weight, fonts.value("regular")) on the font
  ///    side, so a caller that names a face the resource does not ship still
  ///    gets real outlines instead of empty ones;
  ///  * the symbol face contributes no outlines, only coverage through
  ///    [symbolSupports], because NotoSansSymbols2 is a TrueType file and this
  ///    layer has no parser for it. A request for [kSymbolFontKey] therefore
  ///    returns the default glyph rather than borrowing regular outlines, which
  ///    Qt would never hand out for that key.
  Glyph lookup(String character, [String weight = kDefaultGlyphWeight]) {
    if (weight == kSymbolFontKey) {
      return Glyph(advance: kMissingGlyphAdvance, path: ui.Path());
    }
    final table = _weights[weight] ?? _weights[kDefaultGlyphWeight];
    final direct = table?.glyphFor(character);
    if (direct != null) {
      return direct;
    }
    return Glyph(advance: kMissingGlyphAdvance, path: ui.Path());
  }

  /// True when the resource table of [weight] carries [character]. When this is
  /// false the caller must plan a fallback; see fallback_shaper.dart.
  ///
  /// Kept in lockstep with [lookup]: [kSymbolFontKey] never yields a resource
  /// outline, so it reports false here as well.
  bool hasOutline(String character, [String weight = kDefaultGlyphWeight]) {
    if (weight == kSymbolFontKey) {
      return false;
    }
    final table = _weights[weight] ?? _weights[kDefaultGlyphWeight];
    return table?.has(character) ?? false;
  }
}

/// One parsed outline plus its tight bounds in font units.
class SvgOutline {
  const SvgOutline(this.path, this.bounds);

  final ui.Path path;

  /// Tight bounding box in font units, or null when the string carried no
  /// point at all (Qt's QPainterPath::isEmpty()).
  final ui.Rect? bounds;

  bool get hasOutline => bounds != null;
}

/// Parses the path strings stored in misans-glyphs.json and
/// boot-lettering-art.json.
///
/// Mirrors Glyphs::path (Glyphs.cpp:190-265) token for token:
///  * the tokenizer is [a-zA-Z]|[-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.?[0-9]*)(?:[eE][-+]?[0-9]+)?
///  * the initial command is 'M'; the sub-path start is remembered for 'Z'
///  * 'M' repeats implicitly as L, and lowercase commands are relative to the
///    current point captured when the command starts
///  * only M/L/H/V/C/Q/Z are understood; any other command aborts the parse and
///    keeps whatever was built so far
///  * the fill rule is the non-zero winding rule (Qt::WindingFill)
///
/// This is the outline-only view; [parseSvgOutline] is the same parse plus the
/// tight bounds.
ui.Path parseSvgPath(String svg) => parseSvgOutline(svg).path;

/// Parses a path and keeps the tight bounds Qt reports for the same string.
///
/// Qt asks QPainterPath::boundingRect() in bounds() and inset()
/// (Glyphs.cpp:327-330, 344-348). That rectangle is tight: curve extrema are
/// solved analytically. Skia's Path.getBounds() is the control-point hull and
/// is strictly larger for every curved outline, so the bounds are accumulated
/// here, where the segment type is still known.
SvgOutline parseSvgOutline(String svg) {
  final tokens = _svgTokenPattern
      .allMatches(svg)
      .map((match) => match.group(0)!)
      .toList(growable: false);
  final path = ui.Path()..fillType = ui.PathFillType.nonZero;
  final xRange = _AxisRange();
  final yRange = _AxisRange();

  var index = 0;
  var command = _upperM;
  var pointX = 0.0;
  var pointY = 0.0;
  var startX = 0.0;
  var startY = 0.0;

  double number() {
    if (index < tokens.length) {
      return double.tryParse(tokens[index++]) ?? 0;
    }
    return 0;
  }

  void includePoint(double x, double y) {
    xRange.add(x);
    yRange.add(y);
  }

  while (index < tokens.length) {
    final first = tokens[index].codeUnitAt(0);
    if (_isAsciiLetter(first)) {
      command = first;
      index++;
      if (_lower(command) == _lowerZ) {
        path.close();
        pointX = startX;
        pointY = startY;
        continue;
      }
    }

    final relative = command >= _lowerA && command <= _lowerZ;
    final originX = relative ? pointX : 0.0;
    final originY = relative ? pointY : 0.0;

    double pairX() => number() + originX;
    double pairY() => number() + originY;

    final op = _lower(command);
    if (op == _lowerM) {
      pointX = pairX();
      pointY = pairY();
      path.moveTo(pointX, pointY);
      includePoint(pointX, pointY);
      startX = pointX;
      startY = pointY;
      // An immediate second coordinate pair repeats as a line.
      command = relative ? _lowerL : _upperL;
    } else if (op == _lowerL) {
      pointX = pairX();
      pointY = pairY();
      path.lineTo(pointX, pointY);
      includePoint(pointX, pointY);
    } else if (op == _lowerH) {
      pointX = number() + (relative ? pointX : 0.0);
      path.lineTo(pointX, pointY);
      includePoint(pointX, pointY);
    } else if (op == _lowerV) {
      pointY = number() + (relative ? pointY : 0.0);
      path.lineTo(pointX, pointY);
      includePoint(pointX, pointY);
    } else if (op == _lowerC) {
      final firstControlX = pairX();
      final firstControlY = pairY();
      final secondControlX = pairX();
      final secondControlY = pairY();
      final endX = pairX();
      final endY = pairY();
      path.cubicTo(
        firstControlX,
        firstControlY,
        secondControlX,
        secondControlY,
        endX,
        endY,
      );
      xRange.addCubic(pointX, firstControlX, secondControlX, endX);
      yRange.addCubic(pointY, firstControlY, secondControlY, endY);
      pointX = endX;
      pointY = endY;
    } else if (op == _lowerQ) {
      final controlX = pairX();
      final controlY = pairY();
      final endX = pairX();
      final endY = pairY();
      path.quadraticBezierTo(controlX, controlY, endX, endY);
      xRange.addQuadratic(pointX, controlX, endX);
      yRange.addQuadratic(pointY, controlY, endY);
      pointX = endX;
      pointY = endY;
    } else {
      // Unknown command: stop the whole parse, keeping the built sub-paths.
      index = tokens.length;
    }
  }
  final bounds = xRange.isEmpty || yRange.isEmpty
      ? null
      : ui.Rect.fromLTRB(xRange.min, yRange.min, xRange.max, yRange.max);
  return SvgOutline(path, bounds);
}

/// Mirrors the color helper of Glyphs.cpp:35-49.
///
/// The array holds r/g/b, an optional alpha, and an optional fifth entry whose
/// string starts with "calibrated". Calibrated channels are linear gamma-1.8
/// and are converted to sRGB here.
ui.Color calibratedColor(List<Object?> value) {
  final calibrated = value.length > 4 &&
      value[4] is String &&
      (value[4] as String).startsWith('calibrated');

  double channel(int index) {
    var v = index < value.length ? _toDouble(value[index]) : 0.0;
    if (calibrated) {
      final linear = math.pow(v, 1.8).toDouble();
      v = linear <= 0.0031308
          ? 12.92 * linear
          : 1.055 * math.pow(linear, 1 / 2.4).toDouble() - 0.055;
    }
    return v;
  }

  final alpha = value.length > 3 ? _toDouble(value[3]) : 1.0;
  return ui.Color.fromARGB(
    _channelByte(alpha),
    _channelByte(channel(0)),
    _channelByte(channel(1)),
    _channelByte(channel(2)),
  );
}

double _toDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

int _channelByte(double value) => (value.clamp(0.0, 1.0) * 255).round();

/// Builds a [GlyphFontSet] from the two shipped JSON resources.
///
/// [glyphJson] is misans-glyphs.json and [letteringJson] is
/// boot-lettering-art.json. Qt requires both files fatally (Glyphs.cpp:28-33);
/// here the caller decides how to surface a missing asset.
GlyphFontSet parseGlyphResources({
  required String glyphJson,
  required String letteringJson,
  SymbolCoverage symbols = SymbolCoverage.none,
}) {
  final weights = <String, WeightGlyphs>{};
  final decodedGlyphs = jsonDecode(glyphJson);
  if (decodedGlyphs is Map) {
    for (final entry in decodedGlyphs.entries) {
      final name = entry.key.toString();
      final body = entry.value;
      if (body is! Map) {
        continue;
      }
      final glyphs = <String, Glyph>{};
      final rawGlyphs = body['glyphs'];
      if (rawGlyphs is Map) {
        for (final glyphEntry in rawGlyphs.entries) {
          final raw = glyphEntry.value;
          if (raw is! Map) {
            continue;
          }
          final outline = parseSvgOutline(raw['path']?.toString() ?? '');
          glyphs[glyphEntry.key.toString()] = Glyph(
            advance: _toDouble(raw['advance']),
            path: outline.path,
            bounds: outline.bounds,
          );
        }
      }
      weights[name] = WeightGlyphs(
        weight: name,
        units: _toDouble(body['units']),
        ascent: _toDouble(body['ascent']),
        descent: _toDouble(body['descent']),
        glyphs: glyphs,
      );
    }
  }

  final lettering = <String, Lettering>{};
  final decodedArt = jsonDecode(letteringJson);
  if (decodedArt is Map) {
    for (final entry in decodedArt.entries) {
      final key = entry.key.toString();
      final body = entry.value;
      if (body is! Map) {
        continue;
      }
      final letters = <LetteringGlyph>[];
      final rawLetters = body['letters'];
      if (rawLetters is List) {
        for (final raw in rawLetters) {
          if (raw is! Map) {
            continue;
          }
          letters.add(LetteringGlyph(
            advance: _toDouble(raw['width']),
            path: parseSvgPath(raw['path']?.toString() ?? ''),
          ));
        }
      }
      lettering[key] = Lettering(
        key: key,
        text: body['text']?.toString() ?? '',
        weight: body['weight']?.toString() ?? '',
        units: _toDouble(body['units']),
        letters: letters,
      );
    }
  }

  return GlyphFontSet(
    weights: weights,
    lettering: lettering,
    symbols: symbols,
  );
}

/// One axis of a tight bounding box, with the extrema of curve segments.
///
/// A cubic or quadratic can bulge past its control polygon's endpoints, so the
/// interior extremum of each axis is solved instead of being approximated:
/// B'(t) = 0 for the axis, keeping roots strictly inside (0, 1). This is what
/// QPainterPath::boundingRect() reports and what Skia's Path.getBounds() does
/// not.
class _AxisRange {
  double min = double.infinity;
  double max = double.negativeInfinity;

  bool get isEmpty => min > max;

  void add(double value) {
    if (value < min) {
      min = value;
    }
    if (value > max) {
      max = value;
    }
  }

  /// Adds both endpoints and the interior extremum, if any, of one axis of a
  /// quadratic segment.
  void addQuadratic(double p0, double p1, double p2) {
    add(p0);
    add(p2);
    final denominator = p0 - 2 * p1 + p2;
    if (denominator == 0) {
      return;
    }
    final t = (p0 - p1) / denominator;
    if (t > 0 && t < 1) {
      final u = 1 - t;
      add(u * u * p0 + 2 * u * t * p1 + t * t * p2);
    }
  }

  /// Adds both endpoints and the interior extrema, if any, of one axis of a
  /// cubic segment.
  void addCubic(double p0, double p1, double p2, double p3) {
    add(p0);
    add(p3);
    // B'(t) / 3 == a * t^2 + b * t + c.
    final a = -p0 + 3 * p1 - 3 * p2 + p3;
    final b = 2 * (p0 - 2 * p1 + p2);
    final c = p1 - p0;
    if (a == 0) {
      if (b == 0) {
        return;
      }
      final t = -c / b;
      if (t > 0 && t < 1) {
        add(_cubicAt(p0, p1, p2, p3, t));
      }
      return;
    }
    final discriminant = b * b - 4 * a * c;
    if (discriminant < 0) {
      return;
    }
    final root = math.sqrt(discriminant);
    final first = (-b + root) / (2 * a);
    if (first > 0 && first < 1) {
      add(_cubicAt(p0, p1, p2, p3, first));
    }
    final second = (-b - root) / (2 * a);
    if (second > 0 && second < 1) {
      add(_cubicAt(p0, p1, p2, p3, second));
    }
  }
}

double _cubicAt(double p0, double p1, double p2, double p3, double t) {
  final u = 1 - t;
  return u * u * u * p0 +
      3 * u * u * t * p1 +
      3 * u * t * t * p2 +
      t * t * t * p3;
}

final RegExp _svgTokenPattern = RegExp(
  r'[a-zA-Z]|[-+]?(?:[0-9]*\.[0-9]+|[0-9]+\.?[0-9]*)(?:[eE][-+]?[0-9]+)?',
);

const int _upperL = 0x4C;
const int _upperM = 0x4D;
const int _lowerA = 0x61;
const int _lowerC = 0x63;
const int _lowerH = 0x68;
const int _lowerL = 0x6C;
const int _lowerM = 0x6D;
const int _lowerQ = 0x71;
const int _lowerV = 0x76;
const int _lowerZ = 0x7A;

int _lower(int code) => code | 0x20;

bool _isAsciiLetter(int code) =>
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
