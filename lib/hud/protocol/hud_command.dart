import 'dart:math' as math;

/// One decoded native HUD drawing command, in delivery order.
///
/// Wire source: the Qt dispatch chain in `Qt/src/Glyphs.cpp:637-829`. Every
/// command is a flat JSON array whose element 0 is the op name; there is no
/// object envelope, no id, no sequence number and no z index. The Qt painter
/// walks the array once and applies each command to the accumulated painter
/// state, so order is semantics: this model never sorts, merges or
/// deduplicates commands, and keeps the original wire index on every command.
sealed class HudCommand {
  const HudCommand(this.index);

  /// Zero-based position of the command inside the delivered array.
  final int index;
}

/// `save` - pushes the current painter state (`Qt/src/Glyphs.cpp:644-650`).
final class HudSave extends HudCommand {
  const HudSave(super.index);
}

/// `restore` - pops the painter state (`Qt/src/Glyphs.cpp:651-657`).
///
/// Qt does not require save/restore pairing; an unbalanced restore only warns
/// and leaves the state untouched, which is what the painter must reproduce.
final class HudRestore extends HudCommand {
  const HudRestore(super.index);
}

/// `alpha` - multiplies the accumulated painter opacity
/// (`c.setOpacity(c.opacity() * n(1))`, `Qt/src/Glyphs.cpp:658-659`).
final class HudAlpha extends HudCommand {
  const HudAlpha(super.index, this.value);

  final double value;
}

/// `translate` - translates the painter transform (`Qt/src/Glyphs.cpp:660-661`).
final class HudTranslate extends HudCommand {
  const HudTranslate(super.index, this.x, this.y);

  final double x;
  final double y;
}

/// `scale` - scales the painter transform (`Qt/src/Glyphs.cpp:666-667`).
final class HudScale extends HudCommand {
  const HudScale(super.index, this.sx, this.sy);

  final double sx;
  final double sy;
}

/// `rotate` - rotates the painter transform.
///
/// The wire value is in radians; Qt converts with `n(1) * 180 / pi`
/// (`Qt/src/Glyphs.cpp:671-672`), so the model keeps radians and the painter
/// owns the conversion.
final class HudRotate extends HudCommand {
  const HudRotate(super.index, this.radians);

  final double radians;
}

/// `clip` - intersects the clip region with the given logical rectangle
/// (`c.setClipRect(QRectF(...), Qt::IntersectClip)`, `Qt/src/Glyphs.cpp:676-678`).
final class HudClip extends HudCommand {
  const HudClip(super.index, this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;
}

/// `fill` - fills a rectangle with a solid color
/// (`Qt/src/Glyphs.cpp:684-691`).
final class HudFill extends HudCommand {
  const HudFill(
    super.index,
    this.color,
    this.x,
    this.y,
    this.width,
    this.height,
  );

  final HudColor color;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// `ellipse` - fills the ellipse inscribed in the rectangle with no pen
/// (`Qt/src/Glyphs.cpp:692-701`).
///
/// Qt sets the pen to NoPen and the brush to the decoded color on the painter
/// (:692-701), which leaves painter state behind, but no later branch can see
/// it: `text` passes an explicit ink, `art` sets the brush itself (:726),
/// and `path`/`arc` reset to NoBrush (:759, :773). The decoded op is
/// therefore a one-shot fill in the Flutter painter (the `HudEllipse` branch
/// of `paintHudCommands` draws the oval with a fill paint,
/// lib/hud/render/paint_stack.dart:370-385). This model deliberately does not
/// mirror the invisible brush leak.
final class HudEllipse extends HudCommand {
  const HudEllipse(
    super.index,
    this.color,
    this.x,
    this.y,
    this.width,
    this.height,
  );

  final HudColor color;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// `text` - draws a lettering run at size 1000 glyph space
/// (`Qt/src/Glyphs.cpp:702-716`, body at `Qt/src/Glyphs.cpp:530-564`).
final class HudText extends HudCommand {
  const HudText(
    super.index,
    this.value,
    this.x,
    this.y,
    this.size,
    this.weight,
    this.tracking,
    this.color,
  );

  final String value;
  final double x;
  final double y;
  final double size;

  /// Weight selector as delivered by Qt (`a[5].toString()`); the text layer
  /// owns its interpretation.
  final String weight;
  final double tracking;
  final HudColor color;
}

/// `art` - draws a lettering art run with the current painter brush
/// (`Qt/src/Glyphs.cpp:717-727`, body at `Qt/src/Glyphs.cpp:565-588`).
final class HudArt extends HudCommand {
  const HudArt(
    super.index,
    this.key,
    this.x,
    this.y,
    this.size,
    this.count,
    this.tracking,
    this.color,
  );

  final String key;
  final double x;
  final double y;
  final double size;

  /// Number of glyphs to draw; `a[5].toInt(-1)` means a negative value, or an
  /// absent/non-numeric element (Qt falls back to -1), draws the whole string.
  final int count;
  final double tracking;
  final HudColor color;
}

/// `fill-path` - fills a named prebuilt path (`Qt/src/Glyphs.cpp:728-737`).
final class HudFillPath extends HudCommand {
  const HudFillPath(super.index, this.key, this.color);

  final String key;
  final HudColor color;
}

/// `path` - strokes a named prebuilt path with an optional dash pattern
/// (`Qt/src/Glyphs.cpp:738-760`).
///
/// The dash values stay exactly as delivered. Qt divides each entry and the
/// offset by `qMax(penWidth, .0001)` before handing them to the pen because
/// QPen dash units are multiples of the pen width, so that normalization is
/// execution-time behaviour owned by the painter, not decoding.
final class HudStrokePath extends HudCommand {
  const HudStrokePath(
    super.index,
    this.key,
    this.penWidth,
    this.color,
    this.dashPattern,
    this.dashOffset,
  );

  final String key;
  final double penWidth;
  final HudColor color;

  /// Empty means solid: Qt only calls `setDashPattern` when the normalized
  /// pattern is non-empty, and only then applies the offset.
  final List<double> dashPattern;

  /// Null when element 5 is absent or not numeric; the painter then uses 0 for
  /// the offset, which is what `n(5)` yields when the dash pattern is
  /// non-empty. Null is kept instead of being flattened to 0 so the wire truth
  /// survives decoding.
  final double? dashOffset;
}

/// `arc` - strokes an arc of the circle centred on `(cx, cy)`
/// (`Qt/src/Glyphs.cpp:761-774`).
///
/// Start and sweep are radians with Qt's screen-down sign convention; the
/// painter converts with the negated degrees Qt uses.
final class HudArc extends HudCommand {
  const HudArc(
    super.index,
    this.cx,
    this.cy,
    this.radius,
    this.start,
    this.sweep,
    this.penWidth,
    this.color,
  );

  final double cx;
  final double cy;
  final double radius;
  final double start;
  final double sweep;
  final double penWidth;
  final HudColor color;
}

/// `right-mask` - the archived-view right edge fade
/// (`Qt/src/Glyphs.cpp:775-805`).
///
/// `span` is the gradient length and `right` is the fill rectangle's right
/// edge; the two are independent, and the producer already emits
/// `right = stage width` for a shorter fade (`Qt/src/NativeHud.cpp:325`), so
/// the painter must not derive one from the other.
final class HudRightMask extends HudCommand {
  const HudRightMask(
    super.index,
    this.color,
    this.start,
    this.span,
    this.right,
    this.height,
  );

  final HudColor color;
  final double start;
  final double span;
  final double right;
  final double height;
}

/// `gradient` - the fixed radial background gradient
/// (`Qt/src/Glyphs.cpp:806-812`).
final class HudGradient extends HudCommand {
  const HudGradient(super.index, this.dark);

  /// `a[1].toBool()`, false when the element is absent or not a boolean.
  final bool dark;
}

/// `image` - draws a resolved image by key (`Qt/src/Glyphs.cpp:813-824`).
final class HudImage extends HudCommand {
  const HudImage(
    super.index,
    this.key,
    this.x,
    this.y,
    this.width,
    this.height,
  );

  final String key;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// RGBA color decoded from a HUD color array (`Qt/src/Glyphs.cpp:35-49`).
///
/// Channel order matches Qt: red, green, blue, alpha; alpha defaults to 1.0
/// when element 3 is absent and is never gamma corrected.
final class HudColor {
  const HudColor(this.red, this.green, this.blue, [this.alpha = 1.0]);

  final double red;
  final double green;
  final double blue;
  final double alpha;

  @override
  bool operator ==(Object other) =>
      other is HudColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue &&
      other.alpha == alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);

  @override
  String toString() => 'HudColor($red, $green, $blue, $alpha)';
}

/// Gamma exponent Qt decodes each channel with before sRGB encoding, applied
/// only when element 4 starts with `calibrated` (`Qt/src/Glyphs.cpp:38-47`).
///
/// The full conversion is `srgb(pow(v, 1.8))`; alpha never takes part in it.
const double hudCalibratedGamma = 1.8;

/// sRGB transfer function Qt applies after the calibrated gamma step
/// (`Qt/src/Glyphs.cpp:44`):
/// `linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1/2.4) - 0.055`.
///
/// Kept as its own transform so the calibration is one directly testable step.
/// Qt feeds it an already-linear channel, which is why the threshold compares
/// against [linear] and not against the raw wire value.
double hudSrgbEncode(double linear) => linear <= 0.0031308
    ? 12.92 * linear
    : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;

/// Qt's complete calibrated-channel conversion, `srgb(pow(v, 1.8))`
/// (`Qt/src/Glyphs.cpp:42-44`).
///
/// The gamma step must never be skipped: 0.5 decodes to 0.572314..., while
/// encoding 0.5 directly would give 0.735357.... A negative channel stays
/// IEEE-identical to Qt's `std::pow` (NaN for a fractional exponent).
double hudCalibratedChannel(double value) =>
    hudSrgbEncode(math.pow(value, hudCalibratedGamma).toDouble());

/// Severity-free classification of everything the decoder had to report.
enum HudIssueKind {
  /// Op name is empty or not a string, or is not one of the 17 known ops.
  /// Qt has no trailing `else` branch, so these are skipped silently; here they
  /// are skipped and reported.
  unknownOperation,

  /// The command element itself is not an array.
  nonArrayCommand,

  /// A known op is missing an argument or carries one of the wrong type. Qt
  /// coerces those to 0.0/'' and keeps painting, which is preserved; the issue
  /// exists so a known op is never silently swallowed.
  malformedArgument,
}

/// One decoding report entry, addressed by wire index.
final class HudCommandIssue {
  const HudCommandIssue({
    required this.index,
    required this.op,
    required this.kind,
    required this.detail,
  });

  final int index;
  final String op;
  final HudIssueKind kind;
  final String detail;

  @override
  String toString() =>
      'HudCommandIssue(#$index $op ${kind.name}: $detail)';
}

/// Decoded command stream plus everything the decoder refused to hide.
final class HudCommandDecode {
  const HudCommandDecode({required this.commands, required this.issues});

  /// Commands in wire order, with no sorting, merging or deduplication.
  final List<HudCommand> commands;

  /// Skips and Qt-compatible coercions, in wire order.
  final List<HudCommandIssue> issues;

  bool get hasUnknownOperations =>
      issues.any((issue) => issue.kind == HudIssueKind.unknownOperation);

  bool get hasMalformedCommands =>
      issues.any((issue) => issue.kind != HudIssueKind.unknownOperation);
}

/// The 17 op names Qt dispatches on (`Qt/src/Glyphs.cpp:637-829`).
const Set<String> hudKnownOperationNames = <String>{
  'save',
  'restore',
  'alpha',
  'translate',
  'scale',
  'rotate',
  'clip',
  'fill',
  'ellipse',
  'text',
  'art',
  'fill-path',
  'path',
  'arc',
  'right-mask',
  'gradient',
  'image',
};

/// Decodes a delivered command array without changing its meaning.
///
/// Unknown ops are dropped and reported, exactly like Qt's missing `else`
/// branch; they never clear state or abort the frame. Known ops never abort the
/// decode either: an argument that is absent or mistyped keeps Qt's coercion
/// (0.0, '', opaque black, whole-string `count`, no dash) and is reported, so
/// the caller can surface a producer defect. That covers the optional arguments
/// as well - `path`'s positions 4 and 5, `art`'s position 5 and `gradient`'s
/// position 1 - none of which may be swallowed silently (M12-F2 precedent).
HudCommandDecode decodeHudCommands(List<Object?> raw) {
  final commands = <HudCommand>[];
  final issues = <HudCommandIssue>[];

  for (var index = 0; index < raw.length; index++) {
    final entry = raw[index];
    if (entry is! List) {
      issues.add(HudCommandIssue(
        index: index,
        op: '',
        kind: HudIssueKind.nonArrayCommand,
        detail: 'command is ${entry.runtimeType}, Qt would read it as an empty array',
      ));
      continue;
    }
    final args = entry;
    final opValue = args.isEmpty ? null : args[0];
    final op = opValue is String ? opValue : '';
    if (op.isEmpty) {
      issues.add(HudCommandIssue(
        index: index,
        op: op,
        kind: HudIssueKind.unknownOperation,
        detail: 'element 0 is ${opValue.runtimeType}, not an op name',
      ));
      continue;
    }
    if (!hudKnownOperationNames.contains(op)) {
      issues.add(HudCommandIssue(
        index: index,
        op: op,
        kind: HudIssueKind.unknownOperation,
        detail: 'no Qt dispatch branch handles this op',
      ));
      continue;
    }
    commands.add(_decodeOne(op, args, index, issues));
  }

  return HudCommandDecode(
    commands: List<HudCommand>.unmodifiable(commands),
    issues: List<HudCommandIssue>.unmodifiable(issues),
  );
}

HudCommand _decodeOne(
  String op,
  List<Object?> args,
  int index,
  List<HudCommandIssue> issues,
) {
  double number(int position) =>
      _requiredNumber(args, position, index, op, issues);
  double? optionalNumber(int position) =>
      _optionalNumber(args, position, index, op, issues);
  String text(int position) => _requiredString(args, position, index, op, issues);
  HudColor color(int position) => _requiredColor(args, position, index, op, issues);

  switch (op) {
    case 'save':
      return HudSave(index);
    case 'restore':
      return HudRestore(index);
    case 'alpha':
      return HudAlpha(index, number(1));
    case 'translate':
      return HudTranslate(index, number(1), number(2));
    case 'scale':
      return HudScale(index, number(1), number(2));
    case 'rotate':
      return HudRotate(index, number(1));
    case 'clip':
      return HudClip(index, number(1), number(2), number(3), number(4));
    case 'fill':
      return HudFill(
        index,
        color(1),
        number(2),
        number(3),
        number(4),
        number(5),
      );
    case 'ellipse':
      return HudEllipse(
        index,
        color(1),
        number(2),
        number(3),
        number(4),
        number(5),
      );
    case 'text':
      return HudText(
        index,
        text(1),
        number(2),
        number(3),
        number(4),
        text(5),
        number(6),
        color(7),
      );
    case 'art':
      return HudArt(
        index,
        text(1),
        number(2),
        number(3),
        number(4),
        _artCount(args, index, op, issues),
        number(6),
        color(7),
      );
    case 'fill-path':
      return HudFillPath(index, text(1), color(2));
    case 'path':
      return HudStrokePath(
        index,
        text(1),
        number(2),
        color(3),
        _dashPattern(args, index, op, issues),
        optionalNumber(5),
      );
    case 'arc':
      return HudArc(
        index,
        number(1),
        number(2),
        number(3),
        number(4),
        number(5),
        number(6),
        color(7),
      );
    case 'right-mask':
      return HudRightMask(
        index,
        color(1),
        number(2),
        number(3),
        number(4),
        number(5),
      );
    case 'gradient':
      return HudGradient(index, _darkFlag(args, index, op, issues));
    case 'image':
      return HudImage(
        index,
        text(1),
        number(2),
        number(3),
        number(4),
        number(5),
      );
    default:
      // Unreachable: callers filter with hudKnownOperationNames first.
      throw StateError('unhandled op $op');
  }
}

double _requiredNumber(
  List<Object?> args,
  int position,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (position >= args.length) {
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: 'argument $position is absent, Qt coerces it to 0.0',
    ));
    return 0;
  }
  final value = args[position];
  if (value is num) {
    return value.toDouble();
  }
  issues.add(HudCommandIssue(
    index: index,
    op: op,
    kind: HudIssueKind.malformedArgument,
    detail: 'argument $position is ${value.runtimeType}, Qt coerces it to 0.0',
  ));
  return 0;
}

/// `a[i].toDouble()` for an optional argument: an absent argument yields
/// `null` (the field keeps its "not delivered" meaning), while a mistyped one
/// yields `null` too because Qt reads it as 0.0 - and is reported, so a
/// producer defect never disappears behind a plausible default.
double? _optionalNumber(
  List<Object?> args,
  int position,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (position >= args.length) {
    return null;
  }
  final value = args[position];
  if (value is num) {
    return value.toDouble();
  }
  issues.add(HudCommandIssue(
    index: index,
    op: op,
    kind: HudIssueKind.malformedArgument,
    detail: 'optional argument $position is ${value.runtimeType}, '
        'Qt reads it as 0.0',
  ));
  return null;
}

String _requiredString(
  List<Object?> args,
  int position,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (position >= args.length) {
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: 'string argument $position is absent, Qt yields an empty string',
    ));
    return '';
  }
  final value = args[position];
  if (value is String) {
    return value;
  }
  issues.add(HudCommandIssue(
    index: index,
    op: op,
    kind: HudIssueKind.malformedArgument,
    detail: 'argument $position is ${value.runtimeType}, Qt yields an empty string',
  ));
  return '';
}

HudColor _requiredColor(
  List<Object?> args,
  int position,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (position >= args.length) {
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: 'color argument $position is absent, Qt draws opaque black',
    ));
    return const HudColor(0, 0, 0);
  }
  final value = args[position];
  if (value is! List) {
    // Qt keeps painting opaque black here; the issue exists only so a producer
    // defect is not swallowed by a silently valid-looking color.
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: 'color argument $position is ${value.runtimeType}, '
          'Qt reads it as an empty array and draws opaque black',
    ));
    return decodeHudColor(value);
  }
  if (value.length < 3) {
    // Qt reads the missing channels through `QJsonArray::at`, which yields
    // Undefined and therefore 0.0 (`Qt/src/Glyphs.cpp:35-49`). Dart list
    // indexing would throw a RangeError instead, and that would escape
    // `HudFrameEnvelope.decode` (it absorbs TypeError only) and abort the whole
    // frame - the exact failure the decoder must not have.
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: 'color argument $position has ${value.length} channel(s), '
          'Qt reads the missing ones as 0.0',
    ));
  }
  return decodeHudColor(value);
}

/// `a[5].toInt(-1)`: non-numeric or absent falls back to -1, which the art
/// body reads as "draw the whole string"; fractional values truncate.
int _artCount(
  List<Object?> args,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (args.length <= 5) {
    return -1;
  }
  final value = args[5];
  if (value is num) {
    return value.toInt();
  }
  issues.add(HudCommandIssue(
    index: index,
    op: op,
    kind: HudIssueKind.malformedArgument,
    detail: 'art count argument 5 is ${value.runtimeType}, '
        'Qt reads it as -1 (draw the whole string)',
  ));
  return -1;
}

/// `a.size() > 1 && a[1].toBool()`: only a literal `true` selects the dark
/// background gradient (`Qt/src/Glyphs.cpp:808`); anything else reads as
/// false and is reported.
bool _darkFlag(
  List<Object?> args,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (args.length <= 1) {
    return false;
  }
  final value = args[1];
  if (value is bool) {
    return value;
  }
  issues.add(HudCommandIssue(
    index: index,
    op: op,
    kind: HudIssueKind.malformedArgument,
    detail: 'gradient dark flag 1 is ${value.runtimeType}, Qt reads it as false',
  ));
  return false;
}

List<double> _dashPattern(
  List<Object?> args,
  int index,
  String op,
  List<HudCommandIssue> issues,
) {
  if (args.length <= 4) {
    return const <double>[];
  }
  final value = args[4];
  if (value is! List) {
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: 'dash argument 4 is ${value.runtimeType}, Qt reads it as an '
          'empty dash list (solid stroke)',
    ));
    return const <double>[];
  }
  final pattern = <double>[];
  var coerced = 0;
  for (final entry in value) {
    if (entry is num) {
      pattern.add(entry.toDouble());
    } else {
      coerced++;
      pattern.add(0.0);
    }
  }
  if (coerced > 0) {
    issues.add(HudCommandIssue(
      index: index,
      op: op,
      kind: HudIssueKind.malformedArgument,
      detail: '$coerced dash entry(ies) are not numeric, Qt reads them as 0.0',
    ));
  }
  return List<double>.unmodifiable(pattern);
}

/// Decodes a color array exactly like `Qt/src/Glyphs.cpp:35-49`.
///
/// Element 4 is inspected as a string: only a value starting with
/// `calibrated` switches the per-channel gamma conversion on, and the element
/// is never read as alpha. Alpha comes from element 3 and defaults to 1.0, and
/// it never enters the gamma/sRGB conversion (`Qt/src/Glyphs.cpp:48`).
///
/// Two Qt degenerations are reproduced verbatim rather than smoothed over: a
/// color value that is not an array reads as `QJsonValue::toArray()` on an
/// empty value, i.e. three zero channels and alpha 1.0 - opaque black, never
/// "no color"; and an element 3 that is present but not numeric reads as 0.0
/// through `QJsonValue::toDouble()`, i.e. fully transparent.
///
/// The three channels are read through [_channelAt], so a short array (for
/// example `[]`, `[0.5]` or `[0.5, 0.5]`) decodes to the opaque black Qt reads
/// instead of throwing a RangeError.
HudColor decodeHudColor(Object? raw) {
  if (raw is! List) {
    return const HudColor(0, 0, 0);
  }
  final calibrated = raw.length > 4 &&
      raw[4] is String &&
      (raw[4] as String).startsWith('calibrated');
  final alpha = raw.length > 3 ? _channelValue(raw[3]) : 1.0;
  return HudColor(
    _channelAt(raw, 0, calibrated),
    _channelAt(raw, 1, calibrated),
    _channelAt(raw, 2, calibrated),
    alpha,
  );
}

/// `a.at(i)` semantics for the three color channels.
///
/// Qt reads them with `a.at(0)`/`a.at(1)`/`a.at(2)`
/// (`Qt/src/Glyphs.cpp:35-49`); on an array shorter than three entries
/// `QJsonArray::at` yields Undefined, which `toDouble()` reads as 0.0. Dart's
/// `raw[i]` would throw a RangeError for the same input, and a RangeError
/// escapes `HudFrameEnvelope.decode` (it absorbs TypeError only), so the guard
/// is semantic rather than cosmetic.
double _channelAt(List<Object?> raw, int i, bool calibrated) =>
    i < raw.length ? _channel(raw[i], calibrated) : 0.0;

double _channel(Object? value, bool calibrated) {
  final raw = _channelValue(value);
  if (!calibrated) {
    return raw;
  }
  // Qt first decodes the calibrated channel with the 1.8 display gamma
  // (`std::pow(value, 1.8)`, `Qt/src/Glyphs.cpp:42`) and only then encodes it
  // as sRGB. Skipping the first step would lighten every calibrated color:
  // 0.5 must become 0.5723, not 0.7354.
  return hudCalibratedChannel(raw);
}

/// Qt's `QJsonValue::toDouble()`: anything that is not a number reads as 0.
double _channelValue(Object? value) => value is num ? value.toDouble() : 0.0;
