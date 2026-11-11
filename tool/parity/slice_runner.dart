/// Slice runner for the T10 parity slice (Qt -> Flutter).
///
/// Contracts (read-only inputs):
/// * `docs/flutter-migration/01-slice.md` — steps S0-S9,
///   sampling rules, ROI table, checks, thresholds, unmeasured list.
/// * `test/fixtures/slice_cases.json` — schema `slice-cases/v1`.
///
/// Hard rules enforced here:
/// * Pure Dart: only `dart:` imports. No Flutter, no third-party packages.
/// * One slice: candidates may only carry id/name/track/entry/unsupported.
///   steps/rois/checks/thresholds/unmeasured/overrides/tolerance are rejected.
/// * Thresholds and criteria come from the fixture only. The CLI accepts no
///   threshold, tolerance, step, ROI or check override.
/// * Verdicts are per step and per ROI. No global score exists.
/// * Missing sampling, missing ROI evidence, unsupported candidates and any
///   unfrozen threshold are UNMEASURED, never PASS.
/// * commands/hits are compared as ordered tokens: no sorting, no dedup, no
///   default injection, no merging of equal neighbours.
/// * One unit's commands/hits/frame/state must share one generation; otherwise
///   the whole snapshot is discarded (contracts/hud-protocol.md 4.5).
/// * Exit codes: 0 PASS, 1 FAIL, 2 UNMEASURED/NOT_APPLICABLE, 3 usage/input.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Schema identifiers
// ---------------------------------------------------------------------------

const String fixtureSchemaId = 'slice-cases/v1';
const String unitSchemaId = 'slice-unit/v1';
const String exportSchemaId = 'slice-export/v1';
const String reportSchemaId = 'slice-report/v1';
const String roiManifestSchemaId = 'slice-roi-manifest/v1';

// ---------------------------------------------------------------------------
// Contract constants (mirroring oneSliceRule and the slice doc)
// ---------------------------------------------------------------------------

/// Candidate keys allowed by oneSliceRule. Any other key fails structural
/// parity: a candidate may not carry its own slice.
const List<String> oneSliceAllowedCandidateFields = <String>[
  'id',
  'name',
  'track',
  'entry',
  'unsupported',
];

/// Candidate keys that would let a candidate carry its own slice.
const List<String> oneSliceForbiddenCandidateFields = <String>[
  'steps',
  'rois',
  'checks',
  'thresholds',
  'unmeasured',
  'overrides',
  'tolerance',
];

/// ROI compare kinds declared by the slice doc.
const List<String> roiCompareKinds = <String>[
  'pixels',
  'text',
  'glyph',
  'layout',
  'scene3d',
];

/// Every hit must carry exactly these six keys.
const List<String> hitFields = <String>[
  'x',
  'y',
  'width',
  'height',
  'action',
  'label',
];

/// The seventh key, allowed only on PlayerBar hits (Qt PlayerBar::hit).
const String playerBarHitField = 'fixed';

/// Unit fields declared by capture.unitFields (schema slice-unit/v1).
const List<String> unitFields = <String>[
  'schema',
  'candidate',
  'step',
  'unit',
  'generation',
  'tMonotonicMs',
  'wallClock',
  'commands',
  'hits',
  'frame',
  'state',
  'current',
  'session',
];

/// Threshold statuses the slice doc defines.
const List<String> thresholdStatuses = <String>[
  'FROZEN',
  'PROPOSED_UNFROZEN',
  'UNMEASURED',
  'NO_THRESHOLD',
];

final RegExp _stepIdPattern = RegExp(r'^S[0-9]+$');

// ---------------------------------------------------------------------------
// Verdicts
// ---------------------------------------------------------------------------

/// Per-ROI / per-step / per-check verdict. There is no numeric score.
enum SliceVerdict {
  pass,
  fail,
  unmeasured,
  notApplicable,
}

extension SliceVerdictInfo on SliceVerdict {
  /// Worst-wins rank: a FAIL outranks an UNMEASURED, which outranks PASS.
  int get rank => switch (this) {
        SliceVerdict.pass => 0,
        SliceVerdict.notApplicable => 1,
        SliceVerdict.unmeasured => 2,
        SliceVerdict.fail => 3,
      };

  /// Wire spelling used in reports.
  String get wire => switch (this) {
        SliceVerdict.pass => 'PASS',
        SliceVerdict.fail => 'FAIL',
        SliceVerdict.unmeasured => 'UNMEASURED',
        SliceVerdict.notApplicable => 'NOT_APPLICABLE',
      };

  /// Lower-case key used in tallies.
  String get key => switch (this) {
        SliceVerdict.pass => 'pass',
        SliceVerdict.fail => 'fail',
        SliceVerdict.unmeasured => 'unmeasured',
        SliceVerdict.notApplicable => 'notApplicable',
      };

  /// Process exit code for a verdict.
  int get exitCode => switch (this) {
        SliceVerdict.pass => 0,
        SliceVerdict.fail => 1,
        SliceVerdict.unmeasured => 2,
        SliceVerdict.notApplicable => 2,
      };
}

/// Aggregates verdicts worst-wins. An empty aggregate is UNMEASURED: absence of
/// evidence is never a PASS.
SliceVerdict worstOf(Iterable<SliceVerdict> verdicts) {
  var worst = SliceVerdict.pass;
  var seen = false;
  for (final verdict in verdicts) {
    seen = true;
    if (verdict.rank > worst.rank) {
      worst = verdict;
    }
  }
  return seen ? worst : SliceVerdict.unmeasured;
}

/// Counts verdicts by [SliceVerdictInfo.key].
Map<String, int> tally(Iterable<SliceVerdict> verdicts) {
  final counts = <String, int>{
    'pass': 0,
    'fail': 0,
    'unmeasured': 0,
    'notApplicable': 0,
  };
  for (final verdict in verdicts) {
    counts[verdict.key] = (counts[verdict.key] ?? 0) + 1;
  }
  return counts;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Input / contract violation. Always exits with code 3.
class SliceError implements Exception {
  SliceError(this.code, this.message, [List<String> path = const <String>[]])
      : path = List<String>.unmodifiable(path);

  /// Stable machine-readable code (for example `oneSliceRule.candidateForbiddenField`).
  final String code;

  /// Human-readable explanation.
  final String message;

  /// JSON-pointer-ish location inside the input.
  final List<String> path;

  String get pointer => path.isEmpty ? '' : ' at ' + path.join('/');

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'message': message,
        'path': path,
      };

  @override
  String toString() => 'SliceError(' + code + '): ' + message + pointer;
}

Never _fail(
  String code,
  String message, [
  List<String> path = const <String>[],
]) =>
    throw SliceError(code, message, path);

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Map<String, Object?> asObject(
  Object? value,
  String code,
  List<String> path,
) {
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  _fail(code, 'expected a JSON object', path);
}

List<Object?> asArray(Object? value, String code, List<String> path) {
  if (value is List) {
    return List<Object?>.from(value);
  }
  _fail(code, 'expected a JSON array', path);
}

String asText(Object? value, String code, List<String> path) {
  if (value is String) {
    return value;
  }
  _fail(code, 'expected a JSON string', path);
}

String? optionalText(Object? value, String code, List<String> path) {
  if (value == null) {
    return null;
  }
  return asText(value, code, path);
}

num asNumber(Object? value, String code, List<String> path) {
  if (value is num) {
    return value;
  }
  _fail(code, 'expected a JSON number', path);
}

int asInteger(Object? value, String code, List<String> path) {
  if (value is int) {
    return value;
  }
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  _fail(code, 'expected a JSON integer', path);
}

List<String> asTextList(Object? value, String code, List<String> path) {
  final array = asArray(value, code, path);
  final out = <String>[];
  for (var i = 0; i < array.length; i++) {
    out.add(asText(array[i], code, <String>[...path, i.toString()]));
  }
  return out;
}

/// Deep copy of decoded JSON with typed maps and stable key order.
Object? copyJson(Object? value) {
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((key, entry) {
      out[key.toString()] = copyJson(entry);
    });
    return out;
  }
  if (value is List) {
    return <Object?>[for (final entry in value) copyJson(entry)];
  }
  return value;
}

// ---------------------------------------------------------------------------
// Stage geometry
// ---------------------------------------------------------------------------

/// A stage-space rectangle: x, y, width, height in stage units.
class StageRect {
  const StageRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  static StageRect fromJson(
    Object? value,
    String code,
    List<String> path,
  ) {
    final array = asArray(value, code, path);
    if (array.length != 4) {
      _fail(code, 'expected [x, y, width, height]', path);
    }
    return StageRect(
      asNumber(array[0], code, <String>[...path, '0']).toDouble(),
      asNumber(array[1], code, <String>[...path, '1']).toDouble(),
      asNumber(array[2], code, <String>[...path, '2']).toDouble(),
      asNumber(array[3], code, <String>[...path, '3']).toDouble(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  /// Largest absolute component difference. Element-wise absolute tolerance,
  /// matching th.stage.metric semantics (no relative scaling).
  double maxDelta(StageRect other) {
    final deltas = <double>[
      (x - other.x).abs(),
      (y - other.y).abs(),
      (width - other.width).abs(),
      (height - other.height).abs(),
    ];
    var max = deltas.first;
    for (final delta in deltas.skip(1)) {
      if (delta > max) {
        max = delta;
      }
    }
    return max;
  }

  bool withinTolerance(StageRect other, double tolerance) =>
      maxDelta(other) <= tolerance;

  @override
  String toString() => '[' + x.toString() + ',' + y.toString() + ',' +
      width.toString() + ',' + height.toString() + ']';
}

// ---------------------------------------------------------------------------
// Ordered token equality
// ---------------------------------------------------------------------------

/// First difference between two JSON token trees.
class TokenDiff {
  const TokenDiff(this.kind, this.path, this.left, this.right);

  /// One of: value, type, numberType, length, missingLeft, missingRight,
  /// tolerance.
  final String kind;

  /// Path such as `commands[3][7]` or `hits[2].label`.
  final String path;

  final Object? left;
  final Object? right;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'path': path,
        'left': left,
        'right': right,
      };

  @override
  String toString() => kind + ' at ' + path;
}

/// Ordered, type-strict token equality for `commands` and `hits`.
///
/// Arrays keep their order and duplicates. Object key order is irrelevant, but
/// key sets must match exactly: no default field injection and no key dropping.
/// Numbers are type-strict (1 != 1.0) so a capture cannot silently change a
/// token's JSON type.
TokenDiff? firstTokenDifference(
  Object? left,
  Object? right, {
  String path = r'$',
}) {
  if (identical(left, right)) {
    return null;
  }
  if (left is Map && right is Map) {
    for (final key in left.keys) {
      if (!right.containsKey(key)) {
        return TokenDiff('missingRight', path + '.' + key.toString(), left[key], null);
      }
    }
    for (final key in right.keys) {
      if (!left.containsKey(key)) {
        return TokenDiff('missingLeft', path + '.' + key.toString(), null, right[key]);
      }
    }
    for (final key in left.keys) {
      final diff = firstTokenDifference(
        left[key],
        right[key],
        path: path + '.' + key.toString(),
      );
      if (diff != null) {
        return diff;
      }
    }
    return null;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return TokenDiff('length', path + '.length', left.length, right.length);
    }
    for (var i = 0; i < left.length; i++) {
      final diff = firstTokenDifference(
        left[i],
        right[i],
        path: path + '[' + i.toString() + ']',
      );
      if (diff != null) {
        return diff;
      }
    }
    return null;
  }
  if (left is num && right is num) {
    if ((left is int) != (right is int)) {
      return TokenDiff('numberType', path, left, right);
    }
    if (left != right) {
      return TokenDiff('value', path, left, right);
    }
    return null;
  }
  if (left.runtimeType != right.runtimeType) {
    return TokenDiff('type', path, left, right);
  }
  if (left != right) {
    return TokenDiff('value', path, left, right);
  }
  return null;
}

bool tokenEquals(Object? left, Object? right) =>
    firstTokenDifference(left, right) == null;

/// Element-wise absolute comparison for `frame` (see th.frame.matrix).
///
/// Structural differences (missing key, length change, type change) are always
/// differences; numbers use the frozen absolute tolerance.
TokenDiff? firstFrameDifference(
  Object? left,
  Object? right,
  double tolerance, {
  String path = r'$frame',
}) {
  if (identical(left, right)) {
    return null;
  }
  if (left is num && right is num) {
    final delta = (left.toDouble() - right.toDouble()).abs();
    if (delta > tolerance) {
      return TokenDiff('tolerance', path, left, right);
    }
    return null;
  }
  if (left is Map && right is Map) {
    for (final key in left.keys) {
      if (!right.containsKey(key)) {
        return TokenDiff(
            'missingRight', path + '.' + key.toString(), left[key], null);
      }
    }
    for (final key in right.keys) {
      if (!left.containsKey(key)) {
        return TokenDiff(
            'missingLeft', path + '.' + key.toString(), null, right[key]);
      }
    }
    for (final key in left.keys) {
      final diff = firstFrameDifference(
        left[key],
        right[key],
        tolerance,
        path: path + '.' + key.toString(),
      );
      if (diff != null) {
        return diff;
      }
    }
    return null;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return TokenDiff('length', path + '.length', left.length, right.length);
    }
    for (var i = 0; i < left.length; i++) {
      final diff = firstFrameDifference(
        left[i],
        right[i],
        tolerance,
        path: path + '[' + i.toString() + ']',
      );
      if (diff != null) {
        return diff;
      }
    }
    return null;
  }
  return firstTokenDifference(left, right, path: path);
}

// ---------------------------------------------------------------------------
// Hits
// ---------------------------------------------------------------------------

/// A hit-contract violation.
class HitViolation {
  const HitViolation(this.code, this.index, this.path, this.detail);

  final String code;
  final int index;
  final String path;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'index': index,
        'path': path,
        'detail': detail,
      };
}

/// PlayerBar hits are the only source of `fixed: true` (PlayerBar.cpp:46-53).
bool isPlayerBarAction(String action) =>
    action.startsWith('player:') || action == 'music:like-current';

/// Validates one unit's hits against the six-field contract.
///
/// Returns every violation; an empty list means the hits are structurally
/// valid. Order and duplicates are preserved by the caller.
List<HitViolation> validateHits(Object? hits, {String path = 'hits'}) {
  final violations = <HitViolation>[];
  if (hits is! List) {
    return <HitViolation>[
      HitViolation('hits.notArray', -1, path, 'hits must be a JSON array'),
    ];
  }
  for (var i = 0; i < hits.length; i++) {
    final hit = hits[i];
    final hitPath = path + '[' + i.toString() + ']';
    if (hit is! Map) {
      violations.add(HitViolation(
          'hit.notObject', i, hitPath, 'a hit must be a JSON object'));
      continue;
    }
    final keys = <String>{for (final key in hit.keys) key.toString()};
    for (final field in hitFields) {
      if (!keys.contains(field)) {
        violations.add(HitViolation(
          'hit.missingKey',
          i,
          hitPath + '.' + field,
          'missing hit field ' + field,
        ));
      }
    }
    for (final key in keys) {
      if (hitFields.contains(key) || key == playerBarHitField) {
        continue;
      }
      violations.add(HitViolation(
        'hit.extraKey',
        i,
        hitPath + '.' + key,
        'seventh key on a hit: ' + key,
      ));
    }
    final action = hit['action'];
    if (action is! String || action.isEmpty) {
      violations.add(HitViolation(
        'hit.action.type',
        i,
        hitPath + '.action',
        'action must be a non-empty string',
      ));
    }
    final label = hit['label'];
    if (label is! String) {
      violations.add(HitViolation(
        'hit.label.type',
        i,
        hitPath + '.label',
        'label must be a string (null must already fall back to action; an '
            'explicit empty string is preserved)',
      ));
    }
    for (final field in <String>['x', 'y', 'width', 'height']) {
      if (hit[field] is! num) {
        violations.add(HitViolation(
          'hit.rect.numeric',
          i,
          hitPath + '.' + field,
          field + ' must be numeric',
        ));
      }
    }
    final playerBar =
        action is String && isPlayerBarAction(action);
    if (keys.contains(playerBarHitField)) {
      final fixed = hit[playerBarHitField];
      if (fixed is! bool) {
        violations.add(HitViolation(
          'hit.fixed.notBoolean',
          i,
          hitPath + '.fixed',
          'fixed must be a boolean (Qt only writes true)',
        ));
      } else if (!fixed) {
        violations.add(HitViolation(
          'hit.fixed.notTrue',
          i,
          hitPath + '.fixed',
          'fixed, when present, must be true',
        ));
      }
      if (!playerBar) {
        violations.add(HitViolation(
          'hit.fixedNotPlayerBar',
          i,
          hitPath + '.fixed',
          'fixed is only allowed on PlayerBar hits '
              '(player:* / music:like-current)',
        ));
      }
    }
    if (playerBar && label is String && label.isEmpty) {
      violations.add(HitViolation(
        'hit.playerBarLabelEmpty',
        i,
        hitPath + '.label',
        'PlayerBar hit labels must be non-empty (PlayerBar::hit does not fall '
            'back to action)',
      ));
    }
  }
  return violations;
}

// ---------------------------------------------------------------------------
// Units and generations
// ---------------------------------------------------------------------------

/// Generation stamps carried by one unit.
///
/// The Flutter bridge envelope field is `generation` (contracts/hud-protocol.md 1.3);
/// Qt has no such field, so captures must write null. Per-component stamps are
/// accepted so a broken producer can be detected instead of trusted: if they
/// disagree, the whole snapshot is discarded (never a single array).
class GenerationStamp {
  const GenerationStamp({
    this.envelope,
    this.commands,
    this.hits,
    this.frame,
    this.state,
  });

  final Object? envelope;
  final Object? commands;
  final Object? hits;
  final Object? frame;
  final Object? state;

  factory GenerationStamp.of(SliceUnit unit) {
    final raw = unit.raw;
    final fallback = raw['generation'];
    return GenerationStamp(
      envelope: fallback,
      commands: raw['commandsGeneration'] ?? fallback,
      hits: raw['hitsGeneration'] ?? fallback,
      frame: raw['frameGeneration'] ?? fallback,
      state: raw['stateGeneration'] ?? fallback,
    );
  }

  Map<String, Object?> get components => <String, Object?>{
        'commands': commands,
        'hits': hits,
        'frame': frame,
        'state': state,
      };

  /// True when every present stamp agrees (and the envelope agrees with them).
  bool get isCoherent {
    final present = <String, Object?>{}
      ..addAll(components)
      ..removeWhere((_, value) => value == null);
    if (present.isEmpty) {
      return true;
    }
    final first = present.values.first;
    for (final value in present.values.skip(1)) {
      if (!tokenEquals(first, value)) {
        return false;
      }
    }
    if (envelope != null) {
      for (final value in present.values) {
        if (!tokenEquals(envelope, value)) {
          return false;
        }
      }
    }
    return true;
  }

  /// Human-readable stamp list, only for incoherent stamps.
  List<String> get conflicts {
    if (isCoherent) {
      return const <String>[];
    }
    final out = <String>[
      'generation=' + _stampText(envelope),
    ];
    components.forEach((name, value) {
      out.add(name + '=' + _stampText(value));
    });
    return out;
  }
}

String _stampText(Object? value) => value == null ? 'null' : jsonEncode(value);

/// One capture unit (one JSONL record).
class SliceUnit {
  SliceUnit({
    required this.raw,
    required this.source,
    required this.line,
    required this.candidate,
    required this.stepId,
    required this.unitIndex,
    required this.generation,
    required this.tMonotonicMs,
    required this.wallClock,
    required this.commands,
    required this.hits,
    required this.frame,
    required this.state,
    required this.current,
    required this.session,
  });

  /// Decoded record, kept verbatim (unknown keys preserved).
  final Map<String, Object?> raw;
  final String source;
  final int line;
  final String candidate;
  final String stepId;
  final int unitIndex;
  final Object? generation;
  final num tMonotonicMs;
  final String wallClock;
  final List<Object?> commands;
  final List<Object?> hits;
  final Map<String, Object?> frame;
  final Map<String, Object?> state;
  final Map<String, Object?>? current;
  final Map<String, Object?>? session;

  GenerationStamp get stamp => GenerationStamp.of(this);

  String get label => candidate + '/' + stepId + '/' + unitIndex.toString();
}

/// Parses one unit record. Field names and types come from slice-unit/v1.
SliceUnit parseUnit(
  Object? value, {
  required String source,
  int line = 0,
}) {
  final path = <String>[source + ':' + line.toString()];
  final map = asObject(value, 'unit.type', path);
  final schema = asText(map['schema'], 'unit.schema', <String>[...path, 'schema']);
  if (schema != unitSchemaId) {
    _fail('unit.schema', 'expected ' + unitSchemaId + ', found ' + schema, path);
  }
  final candidate =
      asText(map['candidate'], 'unit.candidate', <String>[...path, 'candidate']);
  if (candidate.isEmpty) {
    _fail('unit.candidate', 'candidate must be non-empty', path);
  }
  final stepId = asText(map['step'], 'unit.step', <String>[...path, 'step']);
  if (!_stepIdPattern.hasMatch(stepId)) {
    _fail('unit.step.format', 'step must match S<digits>; found ' + stepId,
        <String>[...path, 'step']);
  }
  final unitIndex =
      asInteger(map['unit'], 'unit.unit', <String>[...path, 'unit']);
  if (unitIndex < 0) {
    _fail('unit.unit.negative', 'unit index must be >= 0',
        <String>[...path, 'unit']);
  }
  final tMonotonicMs = asNumber(
      map['tMonotonicMs'], 'unit.tMonotonicMs', <String>[...path, 'tMonotonicMs']);
  final wallClock =
      asText(map['wallClock'], 'unit.wallClock', <String>[...path, 'wallClock']);
  final commands =
      asArray(map['commands'], 'unit.commands', <String>[...path, 'commands']);
  final hits = asArray(map['hits'], 'unit.hits', <String>[...path, 'hits']);
  final frame = asObject(map['frame'], 'unit.frame', <String>[...path, 'frame']);
  final state = asObject(map['state'], 'unit.state', <String>[...path, 'state']);
  final current = map['current'] == null
      ? null
      : asObject(map['current'], 'unit.current', <String>[...path, 'current']);
  final session = map['session'] == null
      ? null
      : asObject(map['session'], 'unit.session', <String>[...path, 'session']);
  return SliceUnit(
    raw: Map<String, Object?>.from(map),
    source: source,
    line: line,
    candidate: candidate,
    stepId: stepId,
    unitIndex: unitIndex,
    generation: map['generation'],
    tMonotonicMs: tMonotonicMs,
    wallClock: wallClock,
    commands: commands,
    hits: hits,
    frame: frame,
    state: state,
    current: current,
    session: session,
  );
}

/// Parses a JSONL capture file. Blank lines are ignored; every other line must
/// be a slice-unit/v1 record.
List<SliceUnit> parseUnitsJsonl(String text, {required String source}) {
  final units = <SliceUnit>[];
  var lineNumber = 0;
  for (final line in const LineSplitter().convert(text)) {
    lineNumber += 1;
    if (line.trim().isEmpty) {
      continue;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      _fail('unit.json.invalid',
          source + ':' + lineNumber.toString() + ': ' + error.message);
    }
    units.add(parseUnit(decoded, source: source, line: lineNumber));
  }
  return units;
}

/// A snapshot discarded because its generation stamps disagree.
class UnitDiscard {
  const UnitDiscard({
    required this.unit,
    required this.code,
    required this.detail,
  });

  final SliceUnit unit;
  final String code;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'candidate': unit.candidate,
        'step': unit.stepId,
        'unit': unit.unitIndex,
        'source': unit.source,
        'line': unit.line,
        'code': code,
        'detail': detail,
      };
}

/// Drops every unit whose commands/hits/frame/state do not share one
/// generation. The discard covers the whole snapshot, not one array.
List<SliceUnit> dropIncoherentUnits(
  Iterable<SliceUnit> units, {
  List<UnitDiscard>? discards,
}) {
  final kept = <SliceUnit>[];
  for (final unit in units) {
    final stamp = unit.stamp;
    if (stamp.isCoherent) {
      kept.add(unit);
      continue;
    }
    discards?.add(UnitDiscard(
      unit: unit,
      code: 'unit.generationMismatch',
      detail: 'commands/hits/frame/state 不同代: ' + stamp.conflicts.join(', '),
    ));
  }
  return kept;
}

// ---------------------------------------------------------------------------
// Captures
// ---------------------------------------------------------------------------

/// Raw text of one capture file (one collection round).
class CaptureSource {
  const CaptureSource(this.path, this.text);

  final String path;
  final String text;
}

/// One capture CLI argument: candidate id plus one or more JSONL rounds.
class CaptureInput {
  const CaptureInput({required this.candidateId, required this.sources});

  final String candidateId;
  final List<CaptureSource> sources;
}

/// Parsed, generation-filtered capture of one candidate.
class CandidateCapture {
  CandidateCapture({
    required this.candidateId,
    required this.sources,
    required this.kept,
    required this.discards,
  }) : _byStep = _groupUnits(kept);

  final String candidateId;
  final List<CaptureSource> sources;

  /// Units kept after the generation filter.
  final List<SliceUnit> kept;

  /// Units discarded by the generation filter.
  final List<UnitDiscard> discards;

  final Map<String, SplayTreeMap<int, List<SliceUnit>>> _byStep;

  static Map<String, SplayTreeMap<int, List<SliceUnit>>> _groupUnits(
    List<SliceUnit> units,
  ) {
    final grouped = <String, SplayTreeMap<int, List<SliceUnit>>>{};
    for (final unit in units) {
      final step = grouped.putIfAbsent(
        unit.stepId,
        () => SplayTreeMap<int, List<SliceUnit>>(),
      );
      step.putIfAbsent(unit.unitIndex, () => <SliceUnit>[]).add(unit);
    }
    return grouped;
  }

  Iterable<SliceUnit> unitsFor(String stepId) {
    final step = _byStep[stepId];
    if (step == null) {
      return const <SliceUnit>[];
    }
    return step.values.expand((group) => group);
  }

  /// Unit index -> units in collection order (one entry per round).
  SplayTreeMap<int, List<SliceUnit>> groupsFor(String stepId) =>
      _byStep[stepId] ?? SplayTreeMap<int, List<SliceUnit>>();

  /// Distinct unit indices for a step (the sampling gate).
  int unitCountFor(String stepId) => _byStep[stepId]?.length ?? 0;

  /// Unit records for a step (rounds included).
  int recordCountFor(String stepId) {
    final step = _byStep[stepId];
    if (step == null) {
      return 0;
    }
    return step.values.fold(0, (total, group) => total + group.length);
  }

  int get distinctUnits =>
      _byStep.values.fold(0, (total, step) => total + step.length);

  int get records => kept.length;

  List<UnitDiscard> discardsFor(String stepId) => <UnitDiscard>[
        for (final discard in discards)
          if (discard.unit.stepId == stepId) discard,
      ];

  Map<String, Object?> toJson() => <String, Object?>{
        'candidate': candidateId,
        'sources': <String>[for (final source in sources) source.path],
        'records': records,
        'distinctUnits': distinctUnits,
        'discarded': <Object?>[for (final discard in discards) discard.toJson()],
        'steps': <String, Object?>{
          for (final entry in _byStep.entries)
            entry.key: <String, Object?>{
              'units': entry.value.length,
              'records': recordCountFor(entry.key),
            },
        },
      };
}

/// Builds a candidate capture from JSONL text, validating candidate/step
/// membership against the fixture.
CandidateCapture buildCandidateCapture({
  required SliceFixture fixture,
  required String candidateId,
  required List<CaptureSource> sources,
}) {
  final parsed = <SliceUnit>[];
  for (final source in sources) {
    final units = parseUnitsJsonl(source.text, source: source.path);
    for (final unit in units) {
      if (unit.candidate != candidateId) {
        _fail(
          'capture.candidateMismatch',
          source.path +
              ': unit candidate is ' +
              unit.candidate +
              ', but --capture said ' +
              candidateId,
        );
      }
      if (fixture.stepById(unit.stepId) == null) {
        _fail(
          'capture.unknownStep',
          source.path + ': unit step ' + unit.stepId + ' is not in the fixture',
        );
      }
    }
    parsed.addAll(units);
  }
  final discards = <UnitDiscard>[];
  final kept = dropIncoherentUnits(parsed, discards: discards);
  return CandidateCapture(
    candidateId: candidateId,
    sources: sources,
    kept: kept,
    discards: discards,
  );
}

// ---------------------------------------------------------------------------
// ROI manifest
// ---------------------------------------------------------------------------

/// Keys that would turn the ROI manifest into a single global score.
const List<String> _aggregateScoreKeys = <String>[
  'globalscore',
  'overallscore',
  'score',
  'scores',
  'ssim',
  'deltae',
  'aggregate',
  'aggregatescore',
  'meanscore',
  'summaryscore',
  'passrate',
];

/// Recorded conditional state of one ROI (the slice doc requires the condition
/// value to be recorded; a conditional ROI must never be silently skipped).
class RoiCondition {
  const RoiCondition({required this.holds, required this.values});

  final bool holds;
  final Map<String, Object?> values;

  Map<String, Object?> toJson() => <String, Object?>{
        'holds': holds,
        'values': copyJson(values),
      };
}

/// Per-step ROI evidence supplied by the collector.
class StepRoiManifest {
  const StepRoiManifest({
    required this.present,
    required this.rects,
    required this.conditions,
    required this.stage,
  });

  /// ROI ids whose crop exists on disk.
  final List<String> present;

  /// Measured stage rects, per ROI id.
  final Map<String, StageRect> rects;

  /// Condition snapshots, per conditional ROI id.
  final Map<String, RoiCondition> conditions;

  /// Measured stage metrics (stageWidth/stageScale/stageHeight).
  final Map<String, num> stage;
}

class CandidateRoiManifest {
  const CandidateRoiManifest({required this.steps});

  final Map<String, StepRoiManifest> steps;
}

/// Optional ROI evidence file. Schema `slice-roi-manifest/v1`.
class RoiManifest {
  const RoiManifest({required this.candidates, required this.raw});

  final Map<String, CandidateRoiManifest> candidates;
  final Map<String, Object?> raw;

  static RoiManifest empty() => const RoiManifest(
        candidates: <String, CandidateRoiManifest>{},
        raw: <String, Object?>{},
      );

  StepRoiManifest? stepManifest(String candidateId, String stepId) {
    final candidate = candidates[candidateId];
    if (candidate == null) {
      return null;
    }
    return candidate.steps[stepId];
  }
}

RoiManifest parseRoiManifest(Object? decoded, {String sourcePath = '<inline>'}) {
  final root = asObject(decoded, 'roiManifest.type', const <String>[]);
  _rejectAggregateScore(root, const <String>[]);
  final schema = asText(root['schema'], 'roiManifest.schema', const <String>['schema']);
  if (schema != roiManifestSchemaId) {
    _fail('roiManifest.schema',
        'expected ' + roiManifestSchemaId + ', found ' + schema);
  }
  _rejectUnknownKeys(
    root,
    const <String>['schema', 'candidate', 'candidates', 'steps', 'note'],
    const <String>[],
  );
  final candidates = <String, CandidateRoiManifest>{};
  final candidatesValue = root['candidates'];
  if (candidatesValue != null) {
    final candidatesMap = asObject(
        candidatesValue, 'roiManifest.candidates', const <String>['candidates']);
    candidatesMap.forEach((candidateId, value) {
      candidates[candidateId] = _parseCandidateManifest(
          value, <String>['candidates', candidateId]);
    });
  }
  if (root['steps'] != null) {
    final candidateId = optionalText(
        root['candidate'], 'roiManifest.candidate', const <String>['candidate']);
    if (candidateId == null || candidateId.isEmpty) {
      _fail('roiManifest.candidate',
          'top-level steps require a candidate id', const <String>['steps']);
    }
    candidates[candidateId] = _parseCandidateManifest(
      <String, Object?>{'steps': root['steps']},
      const <String>[],
    );
  }
  if (candidates.isEmpty) {
    _fail('roiManifest.empty', 'ROI manifest carries no candidate data');
  }
  return RoiManifest(
    candidates: candidates,
    raw: Map<String, Object?>.from(root),
  );
}

CandidateRoiManifest _parseCandidateManifest(
  Object? value,
  List<String> path,
) {
  final map = asObject(value, 'roiManifest.candidate.type', path);
  _rejectUnknownKeys(map, const <String>['steps', 'note'], path);
  final steps = <String, StepRoiManifest>{};
  final stepsValue = map['steps'];
  if (stepsValue != null) {
    final stepsMap =
        asObject(stepsValue, 'roiManifest.steps', <String>[...path, 'steps']);
    stepsMap.forEach((stepId, stepValue) {
      steps[stepId] =
          _parseStepManifest(stepValue, <String>[...path, 'steps', stepId]);
    });
  }
  return CandidateRoiManifest(steps: steps);
}

StepRoiManifest _parseStepManifest(Object? value, List<String> path) {
  final map = asObject(value, 'roiManifest.step.type', path);
  _rejectUnknownKeys(
      map, const <String>['present', 'rects', 'conditions', 'stage', 'note'], path);
  final present = map['present'] == null
      ? const <String>[]
      : asTextList(map['present'], 'roiManifest.present', <String>[...path, 'present']);
  final rects = <String, StageRect>{};
  final rectsValue = map['rects'];
  if (rectsValue != null) {
    final rectsMap =
        asObject(rectsValue, 'roiManifest.rects', <String>[...path, 'rects']);
    rectsMap.forEach((roiId, rectValue) {
      rects[roiId] = StageRect.fromJson(
          rectValue, 'roiManifest.rect', <String>[...path, 'rects', roiId]);
    });
  }
  final conditions = <String, RoiCondition>{};
  final conditionsValue = map['conditions'];
  if (conditionsValue != null) {
    final conditionsMap = asObject(conditionsValue, 'roiManifest.conditions',
        <String>[...path, 'conditions']);
    conditionsMap.forEach((roiId, conditionValue) {
      if (conditionValue is bool) {
        conditions[roiId] =
            RoiCondition(holds: conditionValue, values: const <String, Object?>{});
        return;
      }
      final conditionPath = <String>[...path, 'conditions', roiId];
      final conditionMap =
          asObject(conditionValue, 'roiManifest.condition', conditionPath);
      _rejectUnknownKeys(
          conditionMap, const <String>['holds', 'values', 'expr', 'note'], conditionPath);
      final holds = conditionMap['holds'];
      if (holds is! bool) {
        _fail('roiManifest.condition.holds', 'condition requires a boolean holds',
            <String>[...conditionPath, 'holds']);
      }
      final values = conditionMap['values'] == null
          ? const <String, Object?>{}
          : asObject(conditionMap['values'], 'roiManifest.condition.values',
              <String>[...conditionPath, 'values']);
      conditions[roiId] = RoiCondition(holds: holds, values: values);
    });
  }
  final stage = <String, num>{};
  final stageValue = map['stage'];
  if (stageValue != null) {
    final stageMap =
        asObject(stageValue, 'roiManifest.stage', <String>[...path, 'stage']);
    stageMap.forEach((key, entry) {
      stage[key] = asNumber(
          entry, 'roiManifest.stage.value', <String>[...path, 'stage', key]);
    });
  }
  return StepRoiManifest(
    present: present,
    rects: rects,
    conditions: conditions,
    stage: stage,
  );
}

void _rejectUnknownKeys(
  Map<String, Object?> map,
  List<String> allowed,
  List<String> path,
) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      _fail('roiManifest.unknownKey',
          'unexpected ROI manifest key: ' + key, <String>[...path, key]);
    }
  }
}

void _rejectAggregateScore(Object? value, List<String> path) {
  if (value is Map) {
    value.forEach((key, entry) {
      final name = key.toString();
      if (_aggregateScoreKeys.contains(name.toLowerCase())) {
        _fail(
          'roiManifest.aggregateScore',
          'ROI manifest must not carry a global score / aggregate: ' + name,
          <String>[...path, name],
        );
      }
      _rejectAggregateScore(entry, <String>[...path, name]);
    });
    return;
  }
  if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _rejectAggregateScore(value[i], <String>[...path, i.toString()]);
    }
  }
}

RoiManifest loadRoiManifest(String path) {
  final text = _readText(path);
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    _fail('roiManifest.json.invalid', path + ': ' + error.message);
  }
  return parseRoiManifest(decoded, sourcePath: path);
}

// ---------------------------------------------------------------------------
// Scene 3D structure
// ---------------------------------------------------------------------------

/// Structural problems with a frame that claims a real 3D draw. Only reads
/// frame.draws/view/projection/eye (chk.scene.real3d); pixel comparison is a
/// separate, currently UNMEASURED, concern.
List<String> scene3dProblems(Map<String, Object?> frame) {
  final problems = <String>[];
  final draws = frame['draws'];
  if (draws is! List || draws.isEmpty) {
    problems.add('frame.draws 为空或缺失（静态图/视频帧不算真 3D）');
  }
  if (!_isMatrix(frame['view'])) {
    problems.add('frame.view 不是 16 元素数值矩阵');
  }
  if (!_isMatrix(frame['projection'])) {
    problems.add('frame.projection 不是 16 元素数值矩阵');
  }
  if (!_isVector(frame['eye'], 3)) {
    problems.add('frame.eye 不是 3 元素数值向量');
  }
  return problems;
}

bool _isMatrix(Object? value) {
  final flat = _flattenNumbers(value);
  return flat != null && flat.length == 16;
}

bool _isVector(Object? value, int length) {
  final flat = _flattenNumbers(value);
  return flat != null && flat.length == length;
}

List<num>? _flattenNumbers(Object? value) {
  if (value is num) {
    return <num>[value];
  }
  if (value is List) {
    final out = <num>[];
    for (final item in value) {
      final nested = _flattenNumbers(item);
      if (nested == null) {
        return null;
      }
      out.addAll(nested);
    }
    return out;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Per-ROI evaluation
// ---------------------------------------------------------------------------

/// Verdict plus evidence for exactly one ROI of one step.
class RoiEvaluation {
  RoiEvaluation({
    required this.stepId,
    required this.roiId,
    required this.compare,
    required this.verdict,
    required this.expected,
    this.measured,
    this.toleranceThresholdId,
    this.tolerance,
    this.condition,
    this.conditionExpr,
    this.crop,
    this.notes = const <String>[],
  });

  final String stepId;
  final String roiId;
  final String compare;
  final SliceVerdict verdict;
  final StageRect expected;
  final StageRect? measured;
  final String? toleranceThresholdId;
  final double? tolerance;
  final RoiCondition? condition;
  final String? conditionExpr;
  final bool? crop;
  final List<String> notes;

  double? get delta {
    final other = measured;
    if (other == null) {
      return null;
    }
    return expected.maxDelta(other);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': roiId,
        'compare': compare,
        'verdict': verdict.wire,
        'expected': expected.toJson(),
        'measured': measured?.toJson(),
        'delta': delta,
        'tolerance': toleranceThresholdId == null
            ? null
            : <String, Object?>{
                'threshold': toleranceThresholdId,
                'value': tolerance,
              },
        'conditional': conditionExpr,
        'condition': condition?.toJson(),
        'crop': crop,
        'notes': notes,
      };
}

/// Evaluates one ROI for one step of one candidate. The only comparable kinds
/// today are `layout` (th.stage.metric, frozen) and `scene3d` (frame structure).
RoiEvaluation evaluateRoi({
  required SliceFixture fixture,
  required SliceStep step,
  required SliceRoi roi,
  required StepRoiManifest? manifestStep,
  required List<SliceUnit> units,
}) {
  final notes = <String>[];
  if (roi.expr.toUpperCase().contains('UNMEASURED')) {
    notes.add('fixture 已把该 ROI 几何标为 UNMEASURED（expr 注明），不得当作已测量值');
  }
  final crop = manifestStep == null ? null : manifestStep.present.contains(roi.id);
  RoiCondition? condition;
  if (roi.conditional != null) {
    condition = manifestStep == null ? null : manifestStep.conditions[roi.id];
    if (condition == null) {
      notes.add('conditional ROI 未记录条件值（"' + roi.conditional! +
          '"）：不得静默跳过，本 ROI 判 UNMEASURED');
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: SliceVerdict.unmeasured,
        expected: roi.rect,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
    }
    if (!condition.holds) {
      notes.add('条件不成立（"' + roi.conditional! + '"），不采像素；条件值已记录');
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: SliceVerdict.notApplicable,
        expected: roi.rect,
        condition: condition,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
    }
    notes.add('条件成立（"' + roi.conditional! + '"）');
  }
  switch (roi.compare) {
    case 'layout':
      final measured = manifestStep == null ? null : manifestStep.rects[roi.id];
      final tolerance = fixture.frozenTolerance('th.stage.metric');
      if (measured == null) {
        notes.add('缺该 ROI 的实测 rect（ROI 清单未提供）：UNMEASURED，不是 PASS');
        return RoiEvaluation(
          stepId: step.id,
          roiId: roi.id,
          compare: roi.compare,
          verdict: SliceVerdict.unmeasured,
          expected: roi.rect,
          condition: condition,
          conditionExpr: roi.conditional,
          crop: crop,
          notes: notes,
        );
      }
      if (tolerance == null) {
        notes.add('th.stage.metric 没有冻结值：拒绝自造容差');
        return RoiEvaluation(
          stepId: step.id,
          roiId: roi.id,
          compare: roi.compare,
          verdict: SliceVerdict.unmeasured,
          expected: roi.rect,
          measured: measured,
          condition: condition,
          conditionExpr: roi.conditional,
          crop: crop,
          notes: notes,
        );
      }
      final delta = roi.rect.maxDelta(measured);
      final verdict =
          delta <= tolerance ? SliceVerdict.pass : SliceVerdict.fail;
      if (verdict == SliceVerdict.fail) {
        notes.add('rect 偏差 ' + delta.toString() + ' 超出 th.stage.metric=' +
            tolerance.toString());
      }
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: verdict,
        expected: roi.rect,
        measured: measured,
        toleranceThresholdId: 'th.stage.metric',
        tolerance: tolerance,
        condition: condition,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
    case 'scene3d':
      if (units.isEmpty) {
        notes.add('缺该 step 的 unit 采样：无法判定 3D 绘制');
        return RoiEvaluation(
          stepId: step.id,
          roiId: roi.id,
          compare: roi.compare,
          verdict: SliceVerdict.unmeasured,
          expected: roi.rect,
          condition: condition,
          conditionExpr: roi.conditional,
          crop: crop,
          notes: notes,
        );
      }
      final problems = <String>[];
      for (final unit in units) {
        for (final problem in scene3dProblems(unit.frame)) {
          problems.add('unit ' + unit.unitIndex.toString() + ': ' + problem);
        }
      }
      if (problems.isEmpty) {
        notes.add('frame.draws 非空且 view/projection/eye 结构完整');
        return RoiEvaluation(
          stepId: step.id,
          roiId: roi.id,
          compare: roi.compare,
          verdict: SliceVerdict.pass,
          expected: roi.rect,
          condition: condition,
          conditionExpr: roi.conditional,
          crop: crop,
          notes: notes,
        );
      }
      notes.addAll(problems.take(6));
      notes.add('共 ' + problems.length.toString() + ' 处 3D 结构问题');
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: SliceVerdict.fail,
        expected: roi.rect,
        condition: condition,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
    case 'pixels':
      notes.add('无同设备同场景 Qt 基线截图；th.pixels.ssim/th.pixels.deltaE '
          '为 PROPOSED_UNFROZEN，不是门');
      notes.add('本 ROI 只登记裁切与几何，判 UNMEASURED');
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: SliceVerdict.unmeasured,
        expected: roi.rect,
        condition: condition,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
    case 'text':
    case 'glyph':
      notes.add('跨引擎文本/字形度量无基线（见 fixture.unmeasured）：不出像素结论');
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: SliceVerdict.unmeasured,
        expected: roi.rect,
        condition: condition,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
    default:
      notes.add('未知 compare 类型 ' + roi.compare + '：UNMEASURED');
      return RoiEvaluation(
        stepId: step.id,
        roiId: roi.id,
        compare: roi.compare,
        verdict: SliceVerdict.unmeasured,
        expected: roi.rect,
        condition: condition,
        conditionExpr: roi.conditional,
        crop: crop,
        notes: notes,
      );
  }
}

// ---------------------------------------------------------------------------
// Fixture model
// ---------------------------------------------------------------------------

/// One candidate. Only id/name/track/entry/unsupported are allowed: a candidate
/// may never carry its own steps, rois, checks, thresholds, unmeasured,
/// overrides or tolerance.
class CandidateSpec {
  const CandidateSpec({
    required this.id,
    required this.name,
    required this.track,
    required this.entry,
    required this.unsupported,
    required this.fields,
  });

  final String id;
  final String name;
  final String track;
  final String entry;

  /// step id -> reason. `*` means every step of this candidate.
  final Map<String, String> unsupported;

  /// Original key list, for the structural report.
  final List<String> fields;

  bool isUnsupported(String stepId) =>
      unsupported.containsKey(stepId) || unsupported.containsKey('*');

  String? unsupportedReason(String stepId) =>
      unsupported[stepId] ?? unsupported['*'];

  factory CandidateSpec.parse(Object? value, int index) {
    final path = <String>['candidates', index.toString()];
    final map = asObject(value, 'fixture.candidate.type', path);
    for (final key in map.keys) {
      if (oneSliceAllowedCandidateFields.contains(key)) {
        continue;
      }
      if (oneSliceForbiddenCandidateFields.contains(key)) {
        _fail(
          'oneSliceRule.candidateForbiddenField',
          'candidate ' +
              asText(map['id'], 'fixture.candidate.id', <String>[...path, 'id']) +
              ' carries the slice field "' +
              key +
              '": candidates must not own steps/rois/checks/thresholds/'
                  'unmeasured/overrides/tolerance',
          <String>[...path, key],
        );
      }
      _fail(
        'oneSliceRule.candidateUnknownField',
        'candidate carries an unlisted field "' +
            key +
            '" (oneSliceRule.allowedCandidateFields)',
        <String>[...path, key],
      );
    }
    final id = asText(map['id'], 'fixture.candidate.id', <String>[...path, 'id']);
    if (id.isEmpty) {
      _fail('fixture.candidate.id', 'candidate id must be non-empty',
          <String>[...path, 'id']);
    }
    return CandidateSpec(
      id: id,
      name: asText(map['name'], 'fixture.candidate.name', <String>[...path, 'name']),
      track:
          asText(map['track'], 'fixture.candidate.track', <String>[...path, 'track']),
      entry:
          asText(map['entry'], 'fixture.candidate.entry', <String>[...path, 'entry']),
      unsupported: _parseUnsupported(
          map['unsupported'], <String>[...path, 'unsupported']),
      fields: map.keys.toList(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'track': track,
        'entry': entry,
        if (unsupported.isNotEmpty) 'unsupported': unsupported,
      };
}

Map<String, String> _parseUnsupported(Object? value, List<String> path) {
  if (value == null) {
    return const <String, String>{};
  }
  if (value is String) {
    if (value.trim().isEmpty) {
      _fail('fixture.unsupported.emptyReason', 'unsupported reason must be non-empty', path);
    }
    return <String, String>{'*': value};
  }
  if (value is List) {
    final out = <String, String>{};
    for (var i = 0; i < value.length; i++) {
      final item = value[i];
      if (item is String) {
        _fail(
          'fixture.unsupported.missingReason',
          'unsupported entries must carry a reason ({step, reason}); a bare step '
              'id is not enough',
          <String>[...path, i.toString()],
        );
      }
      final entryPath = <String>[...path, i.toString()];
      final map = asObject(item, 'fixture.unsupported.type', entryPath);
      final step = asText(map['step'], 'fixture.unsupported.step',
          <String>[...entryPath, 'step']);
      final reason = asText(map['reason'], 'fixture.unsupported.reason',
          <String>[...entryPath, 'reason']);
      if (reason.trim().isEmpty) {
        _fail('fixture.unsupported.emptyReason',
            'unsupported reason must be non-empty', <String>[...entryPath, 'reason']);
      }
      out[step] = reason;
    }
    return out;
  }
  if (value is Map) {
    final out = <String, String>{};
    value.forEach((key, entry) {
      if (entry is! String || entry.trim().isEmpty) {
        _fail('fixture.unsupported.emptyReason',
            'unsupported reason must be a non-empty string',
            <String>[...path, key.toString()]);
      }
      out[key.toString()] = entry;
    });
    return out;
  }
  _fail('fixture.unsupported.type',
      'unsupported must be a string, a list or a map', path);
}

/// One step of the slice.
class SliceStep {
  const SliceStep({
    required this.id,
    required this.kind,
    required this.title,
    required this.inputs,
    required this.expectedState,
    required this.sampling,
    required this.roiIds,
    required this.preconditions,
    required this.notes,
    required this.evidence,
    required this.raw,
  });

  final String id;
  final String kind;
  final String title;
  final List<Map<String, Object?>> inputs;
  final Map<String, Object?> expectedState;
  final List<String> sampling;
  final List<String> roiIds;
  final List<String> preconditions;
  final List<String> notes;
  final List<String> evidence;
  final Map<String, Object?> raw;

  factory SliceStep.parse(Object? value, int index) {
    final path = <String>['steps', index.toString()];
    final map = asObject(value, 'fixture.step.type', path);
    final id = asText(map['id'], 'fixture.step.id', <String>[...path, 'id']);
    if (!_stepIdPattern.hasMatch(id)) {
      _fail('fixture.step.id.format',
          'step id must match S<digits>; found ' + id, <String>[...path, 'id']);
    }
    final inputs = <Map<String, Object?>>[];
    final inputsValue = map['inputs'];
    if (inputsValue != null) {
      final inputsArray = asArray(
          inputsValue, 'fixture.step.inputs', <String>[...path, 'inputs']);
      for (var i = 0; i < inputsArray.length; i++) {
        inputs.add(asObject(inputsArray[i], 'fixture.step.input',
            <String>[...path, 'inputs', i.toString()]));
      }
    }
    return SliceStep(
      id: id,
      kind: asText(map['kind'], 'fixture.step.kind', <String>[...path, 'kind']),
      title:
          asText(map['title'], 'fixture.step.title', <String>[...path, 'title']),
      inputs: inputs,
      expectedState: asObject(map['expectedState'],
          'fixture.step.expectedState', <String>[...path, 'expectedState']),
      sampling: asTextList(
          map['sampling'], 'fixture.step.sampling', <String>[...path, 'sampling']),
      roiIds:
          asTextList(map['rois'], 'fixture.step.rois', <String>[...path, 'rois']),
      preconditions: map['preconditions'] == null
          ? const <String>[]
          : asTextList(map['preconditions'], 'fixture.step.preconditions',
              <String>[...path, 'preconditions']),
      notes: map['notes'] == null
          ? const <String>[]
          : asTextList(
              map['notes'], 'fixture.step.notes', <String>[...path, 'notes']),
      evidence: map['evidence'] == null
          ? const <String>[]
          : asTextList(map['evidence'], 'fixture.step.evidence',
              <String>[...path, 'evidence']),
      raw: Map<String, Object?>.from(map),
    );
  }

  Map<String, Object?> toJson(SliceFixture fixture) => <String, Object?>{
        'id': id,
        'kind': kind,
        'title': title,
        'requiredUnits': fixture.requiredUnits(id),
        'minUnitsPerStep': fixture.capture.minUnitsPerStep,
        'extraUnits': fixture.capture.extraUnits[id] ?? 0,
        'inputs': <Object?>[for (final input in inputs) copyJson(input)],
        'sampling': sampling,
        'expectedState': copyJson(expectedState),
        if (preconditions.isNotEmpty) 'preconditions': preconditions,
        if (notes.isNotEmpty) 'notes': notes,
        if (evidence.isNotEmpty) 'evidence': evidence,
        'rois': <Object?>[
          for (final roiId in roiIds) fixture.roiById(roiId)!.toJson(),
        ],
      };
}

/// One ROI of the fixture table.
class SliceRoi {
  const SliceRoi({
    required this.id,
    required this.rect,
    required this.expr,
    required this.compare,
    required this.conditional,
    required this.source,
  });

  final String id;
  final StageRect rect;
  final String expr;
  final String compare;
  final String? conditional;
  final String source;

  bool get rectStatus =>
      expr.toUpperCase().contains('UNMEASURED') ? false : true;

  factory SliceRoi.parse(Object? value, int index) {
    final path = <String>['rois', index.toString()];
    final map = asObject(value, 'fixture.roi.type', path);
    final id = asText(map['id'], 'fixture.roi.id', <String>[...path, 'id']);
    if (!id.startsWith('roi.')) {
      _fail('fixture.roi.id.format',
          'roi id must start with "roi."; found ' + id, <String>[...path, 'id']);
    }
    final compare =
        asText(map['compare'], 'fixture.roi.compare', <String>[...path, 'compare']);
    if (!roiCompareKinds.contains(compare)) {
      _fail(
        'fixture.roi.compare.unknown',
        'roi ' + id + ' has unknown compare "' + compare + '" (expected ' +
            roiCompareKinds.join('|') + ')',
        <String>[...path, 'compare'],
      );
    }
    return SliceRoi(
      id: id,
      rect: StageRect.fromJson(
          map['rect'], 'fixture.roi.rect', <String>[...path, 'rect']),
      expr: asText(map['expr'], 'fixture.roi.expr', <String>[...path, 'expr']),
      compare: compare,
      conditional: optionalText(
          map['conditional'], 'fixture.roi.conditional',
          <String>[...path, 'conditional']),
      source:
          asText(map['source'], 'fixture.roi.source', <String>[...path, 'source']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'rect': rect.toJson(),
        'expr': expr,
        'compare': compare,
        'conditional': conditional,
        'rectStatus': rectStatus ? 'DECLARED' : 'UNMEASURED',
        'source': source,
      };
}

/// One machine-declared check of the slice.
class SliceCheck {
  const SliceCheck({
    required this.id,
    required this.kind,
    required this.steps,
    required this.assertion,
    required this.source,
  });

  final String id;
  final String kind;
  final List<String> steps;
  final String assertion;
  final String source;

  factory SliceCheck.parse(Object? value, int index) {
    final path = <String>['checks', index.toString()];
    final map = asObject(value, 'fixture.check.type', path);
    final id = asText(map['id'], 'fixture.check.id', <String>[...path, 'id']);
    if (!id.startsWith('chk.')) {
      _fail('fixture.check.id.format',
          'check id must start with "chk."; found ' + id, <String>[...path, 'id']);
    }
    return SliceCheck(
      id: id,
      kind:
          asText(map['kind'], 'fixture.check.kind', <String>[...path, 'kind']),
      steps: map['steps'] == null
          ? const <String>[]
          : asTextList(
              map['steps'], 'fixture.check.steps', <String>[...path, 'steps']),
      assertion: asText(
          map['assert'], 'fixture.check.assert', <String>[...path, 'assert']),
      source: asText(map['source'], 'fixture.check.source',
          <String>[...path, 'source']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind,
        'steps': steps,
        'assert': assertion,
        'source': source,
      };
}

/// One threshold. Only a FROZEN numeric value may be used as a gate.
class SliceThreshold {
  const SliceThreshold({
    required this.id,
    required this.value,
    required this.status,
    required this.appliesTo,
    required this.provenance,
  });

  final String id;
  final num? value;
  final String status;
  final String appliesTo;
  final String provenance;

  bool get isFrozen => status == 'FROZEN' && value != null;

  factory SliceThreshold.parse(Object? value, int index) {
    final path = <String>['thresholds', index.toString()];
    final map = asObject(value, 'fixture.threshold.type', path);
    final id = asText(map['id'], 'fixture.threshold.id', <String>[...path, 'id']);
    if (!id.startsWith('th.')) {
      _fail('fixture.threshold.id.format',
          'threshold id must start with "th."; found ' + id,
          <String>[...path, 'id']);
    }
    final status = asText(
        map['status'], 'fixture.threshold.status', <String>[...path, 'status']);
    if (!thresholdStatuses.contains(status)) {
      _fail(
        'fixture.threshold.status.unknown',
        'threshold ' + id + ' has unknown status "' + status + '"',
        <String>[...path, 'status'],
      );
    }
    final rawValue = map['value'];
    if (rawValue != null && rawValue is! num) {
      _fail('fixture.threshold.value',
          'threshold ' + id + ' value must be numeric or null',
          <String>[...path, 'value']);
    }
    if (status == 'FROZEN' && rawValue == null) {
      _fail('fixture.threshold.frozenWithoutValue',
          'FROZEN threshold ' + id + ' must carry a numeric value',
          <String>[...path, 'value']);
    }
    return SliceThreshold(
      id: id,
      value: rawValue is num ? rawValue : null,
      status: status,
      appliesTo: asText(
          map['appliesTo'], 'fixture.threshold.appliesTo',
          <String>[...path, 'appliesTo']),
      provenance: asText(
          map['provenance'], 'fixture.threshold.provenance',
          <String>[...path, 'provenance']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'value': value,
        'status': status,
        'appliesTo': appliesTo,
        'provenance': provenance,
      };
}

/// The capture contract of the fixture.
class CaptureSpec {
  const CaptureSpec({
    required this.unitSchema,
    required this.unitFields,
    required this.order,
    required this.sameGeneration,
    required this.minUnitsPerStep,
    required this.extraUnits,
    required this.generationNote,
    required this.sessionNote,
    required this.naming,
    required this.roiCrop,
    required this.screenshot,
    required this.exportFormats,
  });

  final String unitSchema;
  final List<String> unitFields;
  final String order;
  final String sameGeneration;
  final int minUnitsPerStep;
  final Map<String, int> extraUnits;
  final String? generationNote;
  final String? sessionNote;
  final Map<String, Object?> naming;
  final String? roiCrop;
  final String? screenshot;
  final Map<String, Object?> exportFormats;

  factory CaptureSpec.parse(Object? value) {
    final path = <String>['capture'];
    final map = asObject(value, 'fixture.capture.type', path);
    final unitSchema = asText(
        map['unitSchema'], 'fixture.capture.unitSchema',
        <String>[...path, 'unitSchema']);
    if (unitSchema != unitSchemaId) {
      _fail(
        'fixture.capture.unitSchema',
        'expected unit schema ' + unitSchemaId + ', found ' + unitSchema,
        <String>[...path, 'unitSchema'],
      );
    }
    final declaredFields = asTextList(map['unitFields'],
        'fixture.capture.unitFields', <String>[...path, 'unitFields']);
    final declaredSet = declaredFields.toSet();
    if (declaredSet.length != unitFields.length ||
        !declaredSet.containsAll(unitFields)) {
      _fail(
        'fixture.capture.unitFields',
        'unitFields must equal the 13 fields of slice-unit/v1; found ' +
            declaredFields.join(','),
        <String>[...path, 'unitFields'],
      );
    }
    final minUnitsPerStep = asInteger(map['minUnitsPerStep'],
        'fixture.capture.minUnitsPerStep', <String>[...path, 'minUnitsPerStep']);
    if (minUnitsPerStep < 1) {
      _fail('fixture.capture.minUnitsPerStep',
          'minUnitsPerStep must be >= 1', <String>[...path, 'minUnitsPerStep']);
    }
    final extraUnits = <String, int>{};
    final extraValue = map['extraUnits'];
    if (extraValue != null) {
      final extraMap = asObject(
          extraValue, 'fixture.capture.extraUnits', <String>[...path, 'extraUnits']);
      extraMap.forEach((stepId, countValue) {
        final count = asInteger(countValue, 'fixture.capture.extraUnits',
            <String>[...path, 'extraUnits', stepId]);
        if (count < 0) {
          _fail('fixture.capture.extraUnits.negative',
              'extra units must be >= 0', <String>[...path, 'extraUnits', stepId]);
        }
        extraUnits[stepId] = count;
      });
    }
    return CaptureSpec(
      unitSchema: unitSchema,
      unitFields: declaredFields,
      order: asText(map['order'], 'fixture.capture.order', <String>[...path, 'order']),
      sameGeneration: asText(map['sameGeneration'],
          'fixture.capture.sameGeneration', <String>[...path, 'sameGeneration']),
      minUnitsPerStep: minUnitsPerStep,
      extraUnits: extraUnits,
      generationNote: optionalText(map['generationNote'],
          'fixture.capture.generationNote', <String>[...path, 'generationNote']),
      sessionNote: optionalText(map['sessionNote'],
          'fixture.capture.sessionNote', <String>[...path, 'sessionNote']),
      naming: map['naming'] == null
          ? const <String, Object?>{}
          : asObject(map['naming'], 'fixture.capture.naming',
              <String>[...path, 'naming']),
      roiCrop: optionalText(map['roiCrop'], 'fixture.capture.roiCrop',
          <String>[...path, 'roiCrop']),
      screenshot: optionalText(map['screenshot'], 'fixture.capture.screenshot',
          <String>[...path, 'screenshot']),
      exportFormats: map['exportFormats'] == null
          ? const <String, Object?>{}
          : asObject(map['exportFormats'], 'fixture.capture.exportFormats',
              <String>[...path, 'exportFormats']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'unitSchema': unitSchema,
        'unitFields': unitFields,
        'order': order,
        'sameGeneration': sameGeneration,
        'minUnitsPerStep': minUnitsPerStep,
        'extraUnits': extraUnits,
        'generationNote': generationNote,
        'sessionNote': sessionNote,
        'naming': copyJson(naming),
        'roiCrop': roiCrop,
        'screenshot': screenshot,
        'exportFormats': copyJson(exportFormats),
      };
}

/// Parsed slice-cases/v1 fixture. Construction validates the one-slice rule and
/// every cross reference.
class SliceFixture {
  SliceFixture({
    required this.sourcePath,
    required this.raw,
    required this.schema,
    required this.sliceId,
    required this.sliceVersion,
    required this.atom,
    required this.plan,
    required this.status,
    required this.statusNote,
    required this.baselineCommit,
    required this.oneSliceRule,
    required this.candidates,
    required this.steps,
    required this.rois,
    required this.checks,
    required this.thresholds,
    required this.capture,
    required this.deviceProfile,
    required this.stageMetrics,
    required this.unmeasured,
    required this.roiResolution,
    required this.verdictPolicy,
    required this.evidencePaths,
    required this.notInThisAtom,
  });

  final String sourcePath;
  final Map<String, Object?> raw;
  final String schema;
  final String sliceId;
  final Object? sliceVersion;
  final String? atom;
  final String? plan;
  final String status;
  final String? statusNote;
  final String? baselineCommit;
  final Map<String, Object?> oneSliceRule;
  final List<CandidateSpec> candidates;
  final List<SliceStep> steps;
  final List<SliceRoi> rois;
  final List<SliceCheck> checks;
  final List<SliceThreshold> thresholds;
  final CaptureSpec capture;
  final Map<String, Object?> deviceProfile;
  final Map<String, Object?> stageMetrics;
  final List<String> unmeasured;
  final Map<String, Object?> roiResolution;
  final Map<String, Object?> verdictPolicy;
  final Map<String, Object?> evidencePaths;
  final List<String> notInThisAtom;

  CandidateSpec? candidateById(String id) {
    for (final candidate in candidates) {
      if (candidate.id == id) {
        return candidate;
      }
    }
    return null;
  }

  SliceStep? stepById(String id) {
    for (final step in steps) {
      if (step.id == id) {
        return step;
      }
    }
    return null;
  }

  SliceRoi? roiById(String id) {
    for (final roi in rois) {
      if (roi.id == id) {
        return roi;
      }
    }
    return null;
  }

  SliceThreshold? thresholdById(String id) {
    for (final threshold in thresholds) {
      if (threshold.id == id) {
        return threshold;
      }
    }
    return null;
  }

  /// Frozen absolute tolerance, or null when the threshold is not usable. Never
  /// falls back to a built-in default.
  double? frozenTolerance(String thresholdId) {
    final threshold = thresholdById(thresholdId);
    if (threshold == null || !threshold.isFrozen) {
      return null;
    }
    return threshold.value!.toDouble();
  }

  int requiredUnits(String stepId) =>
      capture.minUnitsPerStep + (capture.extraUnits[stepId] ?? 0);
}

void _validateOneSliceRule(Map<String, Object?> rule) {
  final allowed = asTextList(
    rule['allowedCandidateFields'],
    'fixture.oneSliceRule.allowedCandidateFields',
    const <String>['oneSliceRule', 'allowedCandidateFields'],
  );
  final allowedSet = allowed.toSet();
  if (allowedSet.length != allowed.length) {
    _fail('fixture.oneSliceRule.duplicateAllowed',
        'allowedCandidateFields contains duplicates');
  }
  if (allowedSet.length != oneSliceAllowedCandidateFields.length ||
      !allowedSet.containsAll(oneSliceAllowedCandidateFields)) {
    _fail(
      'fixture.oneSliceRule.allowedMismatch',
      'allowedCandidateFields must be exactly ' +
          oneSliceAllowedCandidateFields.join(',') +
          '; found ' +
          allowed.join(','),
    );
  }
  final forbidden = asTextList(
    rule['forbiddenCandidateFields'],
    'fixture.oneSliceRule.forbiddenCandidateFields',
    const <String>['oneSliceRule', 'forbiddenCandidateFields'],
  );
  for (final key in oneSliceForbiddenCandidateFields) {
    if (!forbidden.contains(key)) {
      _fail(
        'fixture.oneSliceRule.forbiddenIncomplete',
        'forbiddenCandidateFields is missing "' + key + '"',
      );
    }
  }
  for (final key in allowed) {
    if (forbidden.contains(key)) {
      _fail(
        'fixture.oneSliceRule.contradiction',
        'field "' + key + '" is both allowed and forbidden',
      );
    }
  }
}

/// Parses and validates a slice-cases/v1 fixture.
SliceFixture parseFixture(Object? decoded, {String sourcePath = '<inline>'}) {
  final root = asObject(decoded, 'fixture.type', const <String>[]);
  final schema = asText(root['schema'], 'fixture.schema', const <String>['schema']);
  if (schema != fixtureSchemaId) {
    _fail('fixture.schema',
        'expected ' + fixtureSchemaId + ', found ' + schema, const <String>['schema']);
  }
  final oneSliceRule = asObject(
      root['oneSliceRule'], 'fixture.oneSliceRule',
      const <String>['oneSliceRule']);
  _validateOneSliceRule(oneSliceRule);
  final candidateList = asArray(
      root['candidates'], 'fixture.candidates', const <String>['candidates']);
  if (candidateList.isEmpty) {
    _fail('fixture.candidates.empty', 'candidates must not be empty');
  }
  final candidates = <CandidateSpec>[];
  for (var i = 0; i < candidateList.length; i++) {
    candidates.add(CandidateSpec.parse(candidateList[i], i));
  }
  _requireUnique(candidates.map((candidate) => candidate.id).toList(),
      'fixture.candidates.duplicate', 'candidate id');
  final roiList = asArray(root['rois'], 'fixture.rois', const <String>['rois']);
  final rois = <SliceRoi>[];
  for (var i = 0; i < roiList.length; i++) {
    rois.add(SliceRoi.parse(roiList[i], i));
  }
  _requireUnique(rois.map((roi) => roi.id).toList(), 'fixture.rois.duplicate',
      'roi id');
  final roiIds = <String>{for (final roi in rois) roi.id};
  final stepList = asArray(root['steps'], 'fixture.steps', const <String>['steps']);
  if (stepList.isEmpty) {
    _fail('fixture.steps.empty', 'steps must not be empty');
  }
  final steps = <SliceStep>[];
  for (var i = 0; i < stepList.length; i++) {
    steps.add(SliceStep.parse(stepList[i], i));
  }
  _requireUnique(steps.map((step) => step.id).toList(),
      'fixture.steps.duplicate', 'step id');
  final stepIds = <String>{for (final step in steps) step.id};
  for (final step in steps) {
    if (step.roiIds.isEmpty) {
      _fail('fixture.step.rois.empty', 'step ' + step.id + ' has no ROI',
          <String>['steps', step.id, 'rois']);
    }
    for (final roiId in step.roiIds) {
      if (!roiIds.contains(roiId)) {
        _fail(
          'fixture.step.rois.unknown',
          'step ' + step.id + ' references unknown ROI ' + roiId,
          <String>['steps', step.id, 'rois'],
        );
      }
    }
  }
  final checkList =
      asArray(root['checks'], 'fixture.checks', const <String>['checks']);
  final checks = <SliceCheck>[];
  for (var i = 0; i < checkList.length; i++) {
    checks.add(SliceCheck.parse(checkList[i], i));
  }
  _requireUnique(checks.map((check) => check.id).toList(),
      'fixture.checks.duplicate', 'check id');
  for (final check in checks) {
    for (final stepId in check.steps) {
      if (!stepIds.contains(stepId)) {
        _fail(
          'fixture.check.steps.unknown',
          'check ' + check.id + ' references unknown step ' + stepId,
          <String>['checks', check.id, 'steps'],
        );
      }
    }
  }
  final thresholdList = asArray(
      root['thresholds'], 'fixture.thresholds', const <String>['thresholds']);
  final thresholds = <SliceThreshold>[];
  for (var i = 0; i < thresholdList.length; i++) {
    thresholds.add(SliceThreshold.parse(thresholdList[i], i));
  }
  _requireUnique(thresholds.map((threshold) => threshold.id).toList(),
      'fixture.thresholds.duplicate', 'threshold id');
  final capture = CaptureSpec.parse(root['capture']);
  for (final stepId in capture.extraUnits.keys) {
    if (!stepIds.contains(stepId)) {
      _fail(
        'fixture.capture.extraUnits.unknown',
        'extraUnits references unknown step ' + stepId,
        <String>['capture', 'extraUnits', stepId],
      );
    }
  }
  return SliceFixture(
    sourcePath: sourcePath,
    raw: Map<String, Object?>.from(root),
    schema: schema,
    sliceId: asText(root['sliceId'], 'fixture.sliceId', const <String>['sliceId']),
    sliceVersion: root['sliceVersion'],
    atom: optionalText(root['atom'], 'fixture.atom', const <String>['atom']),
    plan: optionalText(root['plan'], 'fixture.plan', const <String>['plan']),
    status: asText(root['status'], 'fixture.status', const <String>['status']),
    statusNote: optionalText(
        root['statusNote'], 'fixture.statusNote', const <String>['statusNote']),
    baselineCommit: optionalText(root['baselineCommit'], 'fixture.baselineCommit',
        const <String>['baselineCommit']),
    oneSliceRule: oneSliceRule,
    candidates: candidates,
    steps: steps,
    rois: rois,
    checks: checks,
    thresholds: thresholds,
    capture: capture,
    deviceProfile: root['deviceProfile'] == null
        ? const <String, Object?>{}
        : asObject(root['deviceProfile'], 'fixture.deviceProfile',
            const <String>['deviceProfile']),
    stageMetrics: root['stageMetrics'] == null
        ? const <String, Object?>{}
        : asObject(root['stageMetrics'], 'fixture.stageMetrics',
            const <String>['stageMetrics']),
    unmeasured: root['unmeasured'] == null
        ? const <String>[]
        : asTextList(root['unmeasured'], 'fixture.unmeasured',
            const <String>['unmeasured']),
    roiResolution: root['roiResolution'] == null
        ? const <String, Object?>{}
        : asObject(root['roiResolution'], 'fixture.roiResolution',
            const <String>['roiResolution']),
    verdictPolicy: root['verdicts'] == null
        ? const <String, Object?>{}
        : asObject(
            root['verdicts'], 'fixture.verdicts', const <String>['verdicts']),
    evidencePaths: root['evidencePaths'] == null
        ? const <String, Object?>{}
        : asObject(root['evidencePaths'], 'fixture.evidencePaths',
            const <String>['evidencePaths']),
    notInThisAtom: root['notInThisAtom'] == null
        ? const <String>[]
        : asTextList(root['notInThisAtom'], 'fixture.notInThisAtom',
            const <String>['notInThisAtom']),
  );
}

void _requireUnique(List<String> values, String code, String label) {
  final seen = <String>{};
  final duplicates = <String>{};
  for (final value in values) {
    if (!seen.add(value)) {
      duplicates.add(value);
    }
  }
  if (duplicates.isNotEmpty) {
    _fail(code, 'duplicate ' + label + ': ' + duplicates.join(', '));
  }
}

// ---------------------------------------------------------------------------
// Step evaluation
// ---------------------------------------------------------------------------

/// Verdict and evidence for one step of one candidate.
class StepEvaluation {
  StepEvaluation({
    required this.candidateId,
    required this.stepId,
    required this.verdict,
    required this.requiredUnits,
    required this.unitCount,
    required this.recordCount,
    required this.reasons,
    required this.discarded,
    required this.rois,
  });

  final String candidateId;
  final String stepId;
  final SliceVerdict verdict;
  final int requiredUnits;
  final int unitCount;
  final int recordCount;

  /// Why this step is not PASS (sampling shortfall, missing capture,
  /// unsupported candidate, generation discards).
  final List<String> reasons;

  final List<UnitDiscard> discarded;
  final List<RoiEvaluation> rois;

  Map<String, Object?> toJson() => <String, Object?>{
        'candidate': candidateId,
        'step': stepId,
        'verdict': verdict.wire,
        'requiredUnits': requiredUnits,
        'unitCount': unitCount,
        'recordCount': recordCount,
        'reasons': reasons,
        'discarded': <Object?>[for (final discard in discarded) discard.toJson()],
        'roiVerdicts': <String, Object?>{
          for (final roi in rois) roi.roiId: roi.verdict.wire,
        },
        'rois': <Object?>[for (final roi in rois) roi.toJson()],
      };
}

/// Aggregates verdicts with a fail > unmeasured > pass > not-applicable order.
/// NOT_APPLICABLE never outranks a PASS, and an empty aggregate is UNMEASURED.
SliceVerdict aggregateVerdicts(Iterable<SliceVerdict> verdicts) {
  var sawPass = false;
  var sawUnmeasured = false;
  var sawNotApplicable = false;
  for (final verdict in verdicts) {
    if (verdict == SliceVerdict.fail) {
      return SliceVerdict.fail;
    }
    if (verdict == SliceVerdict.unmeasured) {
      sawUnmeasured = true;
    } else if (verdict == SliceVerdict.pass) {
      sawPass = true;
    } else {
      sawNotApplicable = true;
    }
  }
  if (sawUnmeasured) {
    return SliceVerdict.unmeasured;
  }
  if (sawPass) {
    return SliceVerdict.pass;
  }
  if (sawNotApplicable) {
    return SliceVerdict.notApplicable;
  }
  return SliceVerdict.unmeasured;
}

/// Evaluates one step: sampling gate, generation discards, unsupported
/// candidates, then every ROI of the step.
StepEvaluation evaluateStep({
  required SliceFixture fixture,
  required CandidateSpec candidate,
  required SliceStep step,
  required CandidateCapture capture,
  required RoiManifest manifest,
}) {
  final reasons = <String>[];
  final required = fixture.requiredUnits(step.id);
  final unitCount = capture.unitCountFor(step.id);
  final recordCount = capture.recordCountFor(step.id);
  if (candidate.isUnsupported(step.id)) {
    reasons.add('candidate ' + candidate.id + ' 标记 ' + step.id +
        ' unsupported：' + (candidate.unsupportedReason(step.id) ?? ''));
  }
  if (recordCount == 0) {
    reasons.add('没有 ' + step.id + ' 的采集 unit（candidate ' + candidate.id + '）');
  } else if (unitCount < required) {
    reasons.add('采样不足：' + unitCount.toString() + '/' +
        required.toString() + ' 个不同 unit（minUnitsPerStep=' +
        fixture.capture.minUnitsPerStep.toString() +
        (fixture.capture.extraUnits[step.id] == null
            ? ''
            : ' + extraUnits=' +
                fixture.capture.extraUnits[step.id].toString()) +
        '）');
  }
  final discarded = capture.discardsFor(step.id);
  for (final discard in discarded) {
    reasons.add('整快照丢弃：' + discard.unit.stepId + ' unit ' +
        discard.unit.unitIndex.toString() + ' 第 ' +
        discard.unit.line.toString() + ' 行 [' + discard.code + '] ' +
        discard.detail);
  }
  final rois = <RoiEvaluation>[];
  for (final roiId in step.roiIds) {
    final roi = fixture.roiById(roiId);
    if (roi == null) {
      _fail('step.rois.unknown', 'step ' + step.id + ' references unknown ROI ' + roiId);
    }
    rois.add(evaluateRoi(
      fixture: fixture,
      step: step,
      roi: roi,
      manifestStep: manifest.stepManifest(candidate.id, step.id),
      units: capture.unitsFor(step.id).toList(),
    ));
  }
  var sawFail = false;
  var sawUnmeasured = false;
  var sawPass = false;
  for (final roi in rois) {
    if (roi.verdict == SliceVerdict.fail) {
      sawFail = true;
    } else if (roi.verdict == SliceVerdict.unmeasured) {
      sawUnmeasured = true;
    } else if (roi.verdict == SliceVerdict.pass) {
      sawPass = true;
    }
  }
  var verdict = SliceVerdict.pass;
  if (reasons.isNotEmpty) {
    // A sampling shortfall, an unsupported step or a discarded snapshot makes
    // every ROI conclusion untrustworthy: the step stays UNMEASURED even when a
    // partial frame would fail a structural check.
    verdict = SliceVerdict.unmeasured;
  } else if (sawFail) {
    verdict = SliceVerdict.fail;
  } else if (sawUnmeasured) {
    verdict = SliceVerdict.unmeasured;
  } else if (!sawPass) {
    verdict = SliceVerdict.notApplicable;
    reasons.add('该 step 的全部 ROI 均 NOT_APPLICABLE（条件不成立），没有可判定的 ROI');
  }
  return StepEvaluation(
    candidateId: candidate.id,
    stepId: step.id,
    verdict: verdict,
    requiredUnits: required,
    unitCount: unitCount,
    recordCount: recordCount,
    reasons: reasons,
    discarded: discarded,
    rois: rois,
  );
}

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

/// Verdict for one fixture check. The decidable flag is false when this atom
/// has no pure-Dart evaluator: such a check is reported UNMEASURED and is
/// excluded from the overall verdict instead of silently passing.
class CheckEvaluation {
  CheckEvaluation({
    required this.candidateId,
    required this.checkId,
    required this.kind,
    required this.steps,
    required this.verdict,
    required this.decidable,
    required this.reason,
    required this.details,
  });

  final String candidateId;
  final String checkId;
  final String kind;
  final List<String> steps;
  final SliceVerdict verdict;
  final bool decidable;
  final String reason;
  final List<String> details;

  Map<String, Object?> toJson() => <String, Object?>{
        'candidate': candidateId,
        'check': checkId,
        'kind': kind,
        'steps': steps,
        'verdict': verdict.wire,
        'decidable': decidable,
        'reason': reason,
        'details': details,
      };
}

/// Checks with no evaluator in this atom. Every entry stays UNMEASURED until a
/// real oracle exists; the reason is copied into the report.
const Map<String, String> checkGapReasons = <String, String>{
  'chk.commands.unknownOpSkip':
      '需要 T04 的命令解码差分才能判定未知 op 跳过；本执行器没有 Qt 侧解码器',
  'chk.commands.textBaseline':
      '文本基线需要 glyph 级对照（fixture.unmeasured），本执行器不出文本结论',
  'chk.commands.calibrated': '校准值属于 glyph 证据（fixture.unmeasured），无基线',
  'chk.ime.commitOnce': 'IME commit-once 依赖输入法/宿主事件记录，采集面未接线',
  'chk.ime.focus': 'IME focus 依赖输入法/宿主焦点事件，采集面未接线',
  'chk.ime.stageInvariant': 'stage 不变量需要输入法事件与 stage 指标联动，采集面未接线',
  'chk.tap.triggerSplit': 'tap 触发切分需要 Qt 侧 hit 分派日志，不在 unit 契约内',
  'chk.a11y.labels': '无障碍标签需要 Semantics 树导出，fixture 未提供',
  'chk.a11y.unmeasured': '无障碍判定在 fixture 中为 UNMEASURED，不得升级为 PASS',
  'chk.media.metadata': '媒体元数据依赖真实曲库/解码器，fixture 未提供',
  'chk.media.survivesRotation': '媒体跨旋转存活依赖真实播放器，fixture 未提供',
  'chk.media.actions': '该 check 未声明任何 step，无法采样',
  'chk.state.rotationContinuity': '旋转连续性需要旋转前后的完整 state 基线，fixture 未提供',
  'chk.state.noStaleHits': '陈旧 hit 判定需要 Qt 侧 hit 生命周期日志',
  'chk.back.libraryDetail': '返回栈断言需要导航栈日志，unit 契约未包含',
};

bool _isFixityViolation(String code) =>
    code == 'hit.fixed.notBoolean' ||
    code == 'hit.fixed.notTrue' ||
    code == 'hit.fixedNotPlayerBar' ||
    code == 'hit.playerBarLabelEmpty';

CheckEvaluation _unmeasuredCheck(
  CandidateSpec candidate,
  SliceCheck check,
  String reason, {
  List<String> details = const <String>[],
}) =>
    CheckEvaluation(
      candidateId: candidate.id,
      checkId: check.id,
      kind: check.kind,
      steps: check.steps,
      verdict: SliceVerdict.unmeasured,
      decidable: false,
      reason: reason,
      details: details,
    );

/// Evaluates one fixture check against one candidate capture. Only the checks
/// whose oracle is pure Dart are decidable here.
CheckEvaluation evaluateCandidateCheck(
  SliceFixture fixture,
  CandidateSpec candidate,
  SliceCheck check,
  CandidateCapture capture,
) {
  if (check.steps.isEmpty) {
    return _unmeasuredCheck(candidate, check,
        checkGapReasons[check.id] ?? '该 check 未声明 step，无法采样');
  }
  final unsupportedSteps = <String>[
    for (final stepId in check.steps)
      if (candidate.isUnsupported(stepId)) stepId,
  ];
  if (unsupportedSteps.isNotEmpty) {
    return _unmeasuredCheck(
      candidate,
      check,
      'candidate ' + candidate.id + ' 标记 ' + unsupportedSteps.join(',') +
          ' unsupported：对应 check 无法测量',
    );
  }
  if (check.id == 'chk.hit.sixFields' || check.id == 'chk.hit.fixedOnlyPlayerBar') {
    final fixedOnly = check.id == 'chk.hit.fixedOnlyPlayerBar';
    var units = 0;
    final details = <String>[];
    for (final stepId in check.steps) {
      for (final unit in capture.unitsFor(stepId)) {
        units += 1;
        for (final violation in validateHits(unit.hits)) {
          if (fixedOnly && !_isFixityViolation(violation.code)) {
            continue;
          }
          details.add(stepId + ' unit ' + unit.unitIndex.toString() + ' 第 ' +
              unit.line.toString() + ' 行: ' + violation.code + ' at ' +
              violation.path +
              (violation.detail.isEmpty ? '' : ' (' + violation.detail + ')'));
        }
      }
    }
    if (units == 0) {
      return _unmeasuredCheck(candidate, check,
          '没有 ' + check.steps.join(',') + ' 的采集 unit，check 无法判定');
    }
    return CheckEvaluation(
      candidateId: candidate.id,
      checkId: check.id,
      kind: check.kind,
      steps: check.steps,
      verdict: details.isEmpty ? SliceVerdict.pass : SliceVerdict.fail,
      decidable: true,
      reason: details.isEmpty ? '全部 hit 通过六字段/PlayerBar fixed 契约' : '存在 hit 契约违规',
      details: details,
    );
  }
  if (check.id == 'chk.scene.real3d') {
    var units = 0;
    final details = <String>[];
    for (final stepId in check.steps) {
      for (final unit in capture.unitsFor(stepId)) {
        units += 1;
        for (final problem in scene3dProblems(unit.frame)) {
          details.add(stepId + ' unit ' + unit.unitIndex.toString() + ': ' + problem);
        }
      }
    }
    if (units == 0) {
      return _unmeasuredCheck(candidate, check,
          '没有 ' + check.steps.join(',') + ' 的采集 unit，3D 结构无法判定');
    }
    return CheckEvaluation(
      candidateId: candidate.id,
      checkId: check.id,
      kind: check.kind,
      steps: check.steps,
      verdict: details.isEmpty ? SliceVerdict.pass : SliceVerdict.fail,
      decidable: true,
      reason: details.isEmpty ? 'frame 携带非空 draws 与完整 view/projection/eye' : 'frame 缺少真 3D 结构',
      details: details,
    );
  }
  if (check.id == 'chk.scene.sameGeneration') {
    var records = 0;
    final details = <String>[];
    for (final stepId in check.steps) {
      records += capture.recordCountFor(stepId);
      for (final discard in capture.discardsFor(stepId)) {
        details.add(stepId + ' unit ' + discard.unit.unitIndex.toString() +
            ' 第 ' + discard.unit.line.toString() + ' 行: ' + discard.detail);
      }
    }
    if (records == 0) {
      return _unmeasuredCheck(candidate, check,
          '没有 ' + check.steps.join(',') + ' 的采集 unit，generation 一致性无法判定');
    }
    return CheckEvaluation(
      candidateId: candidate.id,
      checkId: check.id,
      kind: check.kind,
      steps: check.steps,
      verdict: details.isEmpty ? SliceVerdict.pass : SliceVerdict.fail,
      decidable: true,
      reason: details.isEmpty
          ? 'commands/hits/frame/state 的 generation 全部一致'
          : '存在整快照 generation 不一致（已按契约丢弃，仍计 FAIL）',
      details: details,
    );
  }
  return _unmeasuredCheck(
    candidate,
    check,
    checkGapReasons[check.id] ?? '本原子没有该 check 的纯 Dart 评判器',
  );
}

// ---------------------------------------------------------------------------
// Cross-candidate equivalence
// ---------------------------------------------------------------------------

class EquivalenceStep {
  EquivalenceStep({
    required this.stepId,
    required this.verdict,
    required this.pairs,
    required this.commandsDiffs,
    required this.hitsDiffs,
    required this.frameDiffs,
    required this.stateDivergences,
    required this.reasons,
    required this.details,
  });

  final String stepId;
  final SliceVerdict verdict;
  final int pairs;
  final int commandsDiffs;
  final int hitsDiffs;
  final int frameDiffs;
  final int stateDivergences;
  final List<String> reasons;
  final List<String> details;

  Map<String, Object?> toJson() => <String, Object?>{
        'step': stepId,
        'verdict': verdict.wire,
        'pairs': pairs,
        'commandsDiffs': commandsDiffs,
        'hitsDiffs': hitsDiffs,
        'frameDiffs': frameDiffs,
        'stateDivergences': stateDivergences,
        'reasons': reasons,
        'details': details,
      };
}

class EquivalenceReport {
  EquivalenceReport({
    required this.reference,
    required this.candidates,
    required this.steps,
    required this.reasons,
    required this.frameTolerance,
  });

  final String reference;
  final List<String> candidates;
  final List<EquivalenceStep> steps;
  final List<String> reasons;
  final double? frameTolerance;

  int get pairs {
    var total = 0;
    for (final step in steps) {
      total += step.pairs;
    }
    return total;
  }

  SliceVerdict get verdict {
    if (steps.isEmpty) {
      return SliceVerdict.unmeasured;
    }
    final inner = <SliceVerdict>[for (final step in steps) step.verdict];
    final aggregate = aggregateVerdicts(inner);
    if (aggregate == SliceVerdict.fail) {
      return SliceVerdict.fail;
    }
    if (reasons.isNotEmpty || pairs == 0 || aggregate != SliceVerdict.pass) {
      return SliceVerdict.unmeasured;
    }
    return SliceVerdict.pass;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'reference': reference,
        'candidates': candidates,
        'frameToleranceThreshold': 'th.frame.matrix',
        'frameTolerance': frameTolerance,
        'pairs': pairs,
        'verdict': verdict.wire,
        'reasons': reasons,
        'steps': <Object?>[for (final step in steps) step.toJson()],
      };
}

String _renderToken(Object? value) {
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return value.toString();
  }
}

String _renderDiff(TokenDiff diff) =>
    diff.path + ' [' + diff.kind + '] left=' + _renderToken(diff.left) +
    ' right=' + _renderToken(diff.right);

/// Compares captures of several candidates for one slice. The first candidate
/// id is the reference. Alignment is by step, then unit index, then round —
/// never by list position alone and never by sorting the payloads.
EquivalenceReport evaluateEquivalence(
  SliceFixture fixture,
  Map<String, CandidateCapture> captures,
  List<String> candidateIds,
) {
  final reference = candidateIds.first;
  final reasons = <String>[];
  final frameTolerance = fixture.frozenTolerance('th.frame.matrix');
  if (frameTolerance == null) {
    reasons.add('th.frame.matrix 不是 FROZEN 阈值：frame 比较无法判定');
  }
  final steps = <EquivalenceStep>[];
  for (final step in fixture.steps) {
    final referenceCapture = captures[reference];
    final referenceGroups =
        referenceCapture == null ? <int, List<SliceUnit>>{} : referenceCapture.groupsFor(step.id);
    final stepReasons = <String>[];
    final details = <String>[];
    var pairs = 0;
    var commandsDiffs = 0;
    var hitsDiffs = 0;
    var frameDiffs = 0;
    var stateDivergences = 0;
    if (referenceCapture == null) {
      stepReasons.add('缺少参照候选 ' + reference + ' 的采集');
    }
    for (final candidateId in candidateIds.skip(1)) {
      final capture = captures[candidateId];
      if (capture == null) {
        stepReasons.add('缺少候选 ' + candidateId + ' 的采集');
        continue;
      }
      final groups = capture.groupsFor(step.id);
      if (groups.length != referenceGroups.length) {
        stepReasons.add(step.id + ': ' + reference + ' 有 ' +
            referenceGroups.length.toString() + ' 个 unit，' + candidateId +
            ' 有 ' + groups.length.toString() + ' 个 unit');
      }
      for (final entry in referenceGroups.entries) {
        final left = entry.value;
        final right = groups[entry.key];
        if (right == null) {
          stepReasons.add(step.id + ' unit ' + entry.key.toString() + ': ' +
              candidateId + ' 缺少该 unit');
          continue;
        }
        final rounds = left.length < right.length ? left.length : right.length;
        if (left.length != right.length) {
          stepReasons.add(step.id + ' unit ' + entry.key.toString() + ': ' +
              reference + ' ' + left.length.toString() + ' 轮，' + candidateId +
              ' ' + right.length.toString() + ' 轮，只比较前 ' + rounds.toString() +
              ' 轮');
        }
        for (var round = 0; round < rounds; round += 1) {
          final a = left[round];
          final b = right[round];
          final label = step.id + ' unit ' + entry.key.toString() + ' round ' +
              round.toString() + ' (' + reference + ' vs ' + candidateId + ')';
          if (!tokenEquals(a.state, b.state)) {
            stateDivergences += 1;
            details.add(label + ': state 不同 generation/内容，按契约丢弃该对比');
            continue;
          }
          pairs += 1;
          final commandsDiff = firstTokenDifference(a.commands, b.commands, path: r'$commands');
          if (commandsDiff != null) {
            commandsDiffs += 1;
            details.add(label + ': commands ' + _renderDiff(commandsDiff));
          }
          final hitsDiff = firstTokenDifference(a.hits, b.hits, path: r'$hits');
          if (hitsDiff != null) {
            hitsDiffs += 1;
            details.add(label + ': hits ' + _renderDiff(hitsDiff));
          }
          if (frameTolerance != null) {
            final frameDiff =
                firstFrameDifference(a.frame, b.frame, frameTolerance);
            if (frameDiff != null) {
              frameDiffs += 1;
              details.add(label + ': frame ' + _renderDiff(frameDiff));
            }
          }
        }
      }
    }
    if (referenceCapture == null) {
      reasons.add(step.id + ': 缺少参照候选采集');
    }
    final stepVerdict = (commandsDiffs + hitsDiffs + frameDiffs) > 0
        ? SliceVerdict.fail
        : (stepReasons.isNotEmpty || stateDivergences > 0 || pairs == 0
            ? SliceVerdict.unmeasured
            : SliceVerdict.pass);
    steps.add(EquivalenceStep(
      stepId: step.id,
      verdict: stepVerdict,
      pairs: pairs,
      commandsDiffs: commandsDiffs,
      hitsDiffs: hitsDiffs,
      frameDiffs: frameDiffs,
      stateDivergences: stateDivergences,
      reasons: stepReasons,
      details: details,
    ));
  }
  return EquivalenceReport(
    reference: reference,
    candidates: candidateIds,
    steps: steps,
    reasons: reasons,
    frameTolerance: frameTolerance,
  );
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

/// The compare report. The overall verdict is the worst of every considered
/// unit: per-step verdicts, decidable checks and cross-candidate equivalence.
class SliceReport {
  SliceReport({
    required this.schema,
    required this.mode,
    required this.fixturePath,
    required this.fixture,
    required this.candidates,
    required this.steps,
    required this.checks,
    required this.equivalence,
    required this.manifestPath,
    required this.notes,
  });

  final String schema;
  final String mode;
  final String fixturePath;
  final SliceFixture fixture;
  final List<String> candidates;
  final List<StepEvaluation> steps;
  final List<CheckEvaluation> checks;
  final EquivalenceReport? equivalence;
  final String? manifestPath;
  final List<String> notes;

  List<CheckEvaluation> get decidableChecks =>
      <CheckEvaluation>[for (final check in checks) if (check.decidable) check];

  List<CheckEvaluation> get unmeasurableChecks =>
      <CheckEvaluation>[for (final check in checks) if (!check.decidable) check];

  /// Everything that actually has an oracle in this atom.
  List<SliceVerdict> get considered => <SliceVerdict>[
        for (final step in steps) step.verdict,
        for (final check in decidableChecks) check.verdict,
        if (equivalence != null) equivalence!.verdict,
      ];

  SliceVerdict get verdict => aggregateVerdicts(considered);

  Map<String, Object?> toJson() {
    final counts = tally(considered);
    return <String, Object?>{
      'schema': schema,
      'mode': mode,
      'fixture': <String, Object?>{
        'path': fixturePath,
        'schema': fixture.schema,
        'sliceId': fixture.sliceId,
        'baselineCommit': fixture.baselineCommit,
        'status': fixture.status,
      },
      'roiManifest': <String, Object?>{
        'path': manifestPath,
        'provided': manifestPath != null,
      },
      'candidates': candidates,
      'verdict': verdict.wire,
      'exitCode': verdict.exitCode,
      'tally': counts,
      'steps': <Object?>[for (final step in steps) step.toJson()],
      'checks': <Object?>[for (final check in checks) check.toJson()],
      'decidableChecks': <String>[for (final check in decidableChecks) check.checkId],
      'unmeasurableChecks': <String>[
        for (final check in unmeasurableChecks) check.checkId,
      ],
      'equivalence': equivalence?.toJson(),
      'measurementGaps': fixture.unmeasured,
      'notes': notes,
    };
  }
}

/// Runs a full comparison from capture sources.
SliceReport compareCaptures(
  SliceFixture fixture,
  Map<String, List<CaptureSource>> captureSources, {
  RoiManifest? manifest,
  String fixturePath = '',
  String? manifestPath,
}) {
  final notes = <String>[];
  final candidateIds = <String>[for (final id in captureSources.keys) id]..sort();
  if (candidateIds.isEmpty) {
    _fail('capture.noCandidates', 'compare needs at least one candidate capture');
  }
  final candidateSpecs = <CandidateSpec>[];
  for (final id in candidateIds) {
    final candidate = fixture.candidateById(id);
    if (candidate == null) {
      _fail('capture.unknownCandidate', 'fixture has no candidate "' + id + '"');
    }
    candidateSpecs.add(candidate);
    final sources = captureSources[id] ?? const <CaptureSource>[];
    if (sources.isEmpty) {
      _fail('capture.noSources', 'candidate ' + id + ' has no capture files');
    }
  }
  final resolvedManifest = manifest ?? RoiManifest.empty();
  if (manifest == null) {
    notes.add('未提供 ROI 清单：layout/像素/文本类 ROI 一律 UNMEASURED，不会给出全局分数');
  }
  final captures = <String, CandidateCapture>{};
  for (final candidate in candidateSpecs) {
    captures[candidate.id] = buildCandidateCapture(
      fixture: fixture,
      candidateId: candidate.id,
      sources: captureSources[candidate.id] ?? const <CaptureSource>[],
    );
  }
  final steps = <StepEvaluation>[];
  final checks = <CheckEvaluation>[];
  for (final candidate in candidateSpecs) {
    final capture = captures[candidate.id]!;
    for (final step in fixture.steps) {
      steps.add(evaluateStep(
        fixture: fixture,
        candidate: candidate,
        step: step,
        capture: capture,
        manifest: resolvedManifest,
      ));
    }
    for (final check in fixture.checks) {
      checks.add(evaluateCandidateCheck(fixture, candidate, check, capture));
    }
  }
  EquivalenceReport? equivalence;
  if (candidateIds.length >= 2) {
    equivalence =
        evaluateEquivalence(fixture, captures, candidateIds);
  } else {
    notes.add('只有一个候选采集：跨候选等价性未评估');
  }
  return SliceReport(
    schema: reportSchemaId,
    mode: 'compare',
    fixturePath: fixturePath,
    fixture: fixture,
    candidates: candidateIds,
    steps: steps,
    checks: checks,
    equivalence: equivalence,
    manifestPath: manifestPath,
    notes: notes,
  );
}

/// Builds the export view of the fixture: inputs, sampling, ROI expectations,
/// checks and thresholds in normalized form. The criteria are data copied from
/// the fixture; nothing here can be overridden from the command line.
Map<String, Object?> buildExportReport(
  SliceFixture fixture, {
  String fixturePath = '',
}) {
  final rule = fixture.oneSliceRule;
  final criteria = <String, Object?>{
    'thresholdOverridesAccepted': false,
    'builtInDefaultThresholds': false,
    'globalScore': false,
    'perRoiVerdicts': true,
    'exitCodes': <String, Object?>{
      'pass': 0,
      'fail': 1,
      'unmeasured': 2,
      'notApplicable': 2,
      'inputError': 3,
    },
  };
  return <String, Object?>{
    'schema': exportSchemaId,
    'mode': 'export',
    'fixture': <String, Object?>{
      'path': fixturePath,
      'schema': fixture.schema,
      'sliceId': fixture.sliceId,
      'sliceVersion': fixture.sliceVersion,
      'atom': fixture.atom,
      'plan': fixture.plan,
      'status': fixture.status,
      'statusNote': fixture.statusNote,
      'baselineCommit': fixture.baselineCommit,
    },
    'oneSliceRule': <String, Object?>{
      'allowedCandidateFields': rule['allowedCandidateFields'] == null
          ? const <String>[]
          : asTextList(
              rule['allowedCandidateFields'],
              'export.oneSliceRule.allowedCandidateFields',
              const <String>['oneSliceRule', 'allowedCandidateFields'],
            ),
      'forbiddenCandidateFields': rule['forbiddenCandidateFields'] == null
          ? const <String>[]
          : asTextList(
              rule['forbiddenCandidateFields'],
              'export.oneSliceRule.forbiddenCandidateFields',
              const <String>['oneSliceRule', 'forbiddenCandidateFields'],
            ),
      'statement': optionalText(
        rule['statement'],
        'export.oneSliceRule.statement',
        const <String>['oneSliceRule', 'statement'],
      ),
      'onUnsupported': optionalText(
        rule['onUnsupported'],
        'export.oneSliceRule.onUnsupported',
        const <String>['oneSliceRule', 'onUnsupported'],
      ),
      'planFailCondition': optionalText(
        rule['planFailCondition'],
        'export.oneSliceRule.planFailCondition',
        const <String>['oneSliceRule', 'planFailCondition'],
      ),
    },
    'candidates': <Object?>[for (final candidate in fixture.candidates) candidate.toJson()],
    'deviceProfile': fixture.deviceProfile,
    'capture': fixture.capture.toJson(),
    'steps': <Object?>[for (final step in fixture.steps) step.toJson(fixture)],
    'checks': <Object?>[for (final check in fixture.checks) check.toJson()],
    'thresholds': <Object?>[for (final threshold in fixture.thresholds) threshold.toJson()],
    'stageMetrics': fixture.stageMetrics,
    'roiResolution': fixture.roiResolution,
    'verdictPolicy': fixture.verdictPolicy,
    'evidencePaths': fixture.evidencePaths,
    'unmeasured': fixture.unmeasured,
    'notInThisAtom': fixture.notInThisAtom,
    'criteria': criteria,
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

class CaptureArg {
  const CaptureArg(this.candidateId, this.path);

  final String candidateId;
  final String path;
}

sealed class RunCommand {
  const RunCommand();
}

class HelpCommand extends RunCommand {
  const HelpCommand();
}

class ExportCommand extends RunCommand {
  const ExportCommand({required this.fixturePath, this.outPath});

  final String fixturePath;
  final String? outPath;
}

class CompareCommand extends RunCommand {
  const CompareCommand({
    required this.fixturePath,
    required this.captures,
    this.roiManifestPath,
    this.outPath,
  });

  final String fixturePath;
  final List<CaptureArg> captures;
  final String? roiManifestPath;
  final String? outPath;
}

/// Flags that would let the caller override the fixture's thresholds or
/// criteria. Rejecting them is part of the contract, not a courtesy.
const Map<String, String> rejectedCliFlags = <String, String>{
  '--threshold': 'cli.thresholdOverride',
  '--thresholds': 'cli.thresholdOverride',
  '--tolerance': 'cli.thresholdOverride',
  '--epsilon': 'cli.thresholdOverride',
  '--ssim': 'cli.thresholdOverride',
  '--delta-e': 'cli.thresholdOverride',
  '--deltae': 'cli.thresholdOverride',
  '--min-ssim': 'cli.thresholdOverride',
  '--steps': 'cli.criteriaOverride',
  '--rois': 'cli.criteriaOverride',
  '--checks': 'cli.criteriaOverride',
  '--override': 'cli.criteriaOverride',
  '--overrides': 'cli.criteriaOverride',
  '--skip': 'cli.criteriaOverride',
  '--min-units': 'cli.criteriaOverride',
  '--extra-units': 'cli.criteriaOverride',
  '--global-score': 'cli.criteriaOverride',
  '--score': 'cli.criteriaOverride',
};

const Set<String> knownCliFlags = <String>{
  '--fixture',
  '--out',
  '--capture',
  '--roi-manifest',
};

RunCommand parseInvocation(List<String> argv) {
  if (argv.isEmpty) {
    return const HelpCommand();
  }
  final command = argv[0];
  if (command == 'help' || command == '--help' || command == '-h') {
    return const HelpCommand();
  }
  if (command != 'export' && command != 'compare') {
    _fail('cli.unknownCommand',
        'unknown command "' + command + '" (expected export|compare|help)');
  }
  String? fixturePath;
  String? outPath;
  String? manifestPath;
  final captures = <CaptureArg>[];
  var index = 1;
  while (index < argv.length) {
    final raw = argv[index];
    if (raw == '--help' || raw == '-h') {
      return const HelpCommand();
    }
    final separator = raw.indexOf('=');
    final name = separator < 0 ? raw : raw.substring(0, separator);
    final inline = separator < 0 ? null : raw.substring(separator + 1);
    final rejectedCode = rejectedCliFlags[name];
    if (rejectedCode != null) {
      _fail(
        rejectedCode,
        'thresholds and criteria come from the fixture only: the CLI rejects ' +
            name,
      );
    }
    if (!knownCliFlags.contains(name)) {
      _fail('cli.unknownFlag', 'unknown flag "' + name + '"');
    }
    String takeValue() {
      if (inline != null) {
        if (inline.isEmpty) {
          _fail('cli.missingValue', name + ' needs a non-empty value');
        }
        return inline;
      }
      if (index + 1 >= argv.length) {
        _fail('cli.missingValue', name + ' is missing its value');
      }
      index += 1;
      return argv[index];
    }

    if (name == '--fixture') {
      if (fixturePath != null) {
        _fail('cli.duplicateFlag', '--fixture repeated');
      }
      fixturePath = takeValue();
    } else if (name == '--out') {
      if (outPath != null) {
        _fail('cli.duplicateFlag', '--out repeated');
      }
      outPath = takeValue();
    } else if (name == '--roi-manifest') {
      if (manifestPath != null) {
        _fail('cli.duplicateFlag', '--roi-manifest repeated');
      }
      manifestPath = takeValue();
    } else {
      final value = takeValue();
      final equals = value.indexOf('=');
      if (equals <= 0 || equals == value.length - 1) {
        _fail('cli.captureFormat',
            '--capture expects <candidate>=<unit.jsonl>, got "' + value + '"');
      }
      captures.add(CaptureArg(
        value.substring(0, equals),
        value.substring(equals + 1),
      ));
    }
    index += 1;
  }
  if (fixturePath == null || fixturePath.isEmpty) {
    _fail('cli.missingFixture', 'missing --fixture <path>');
  }
  if (command == 'export') {
    if (captures.isNotEmpty) {
      _fail('cli.flagNotAllowed', 'export does not accept --capture');
    }
    if (manifestPath != null) {
      _fail('cli.flagNotAllowed', 'export does not accept --roi-manifest');
    }
    return ExportCommand(fixturePath: fixturePath, outPath: outPath);
  }
  if (captures.isEmpty) {
    _fail('cli.missingCapture',
        'compare needs at least one --capture <candidate>=<unit.jsonl>');
  }
  return CompareCommand(
    fixturePath: fixturePath,
    captures: captures,
    roiManifestPath: manifestPath,
    outPath: outPath,
  );
}

String _readText(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _fail('io.missingFile', 'file not found: ' + path);
  }
  return file.readAsStringSync();
}

SliceFixture loadFixture(String path) {
  final text = _readText(path);
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    _fail('fixture.json.invalid', path + ': ' + error.message);
  }
  return parseFixture(decoded, sourcePath: path);
}

void _emit(Map<String, Object?> report, String? outPath, StringSink sink) {
  final text = const JsonEncoder.withIndent('  ').convert(report);
  if (outPath == null) {
    sink.writeln(text);
    return;
  }
  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text + '\n');
  sink.writeln('wrote ' + outPath);
}

const String usageText = 'slice-runner: fixture-driven slice executor (slice-cases/v1)\n'
    '\n'
    'Usage:\n'
    '  slice_runner.dart export --fixture <path> [--out <path>]\n'
    '  slice_runner.dart compare --fixture <path> --capture <candidate>=<unit.jsonl> [--capture ...] [--roi-manifest <path>] [--out <path>]\n'
    '  slice_runner.dart help\n'
    '\n'
    'Thresholds, sampling minimums and checks always come from the fixture.\n'
    '--threshold, --tolerance, --steps, --rois, --checks and every other\n'
    'override flag are rejected (exit code 3).\n'
    '\n'
    'Exit codes: 0 PASS, 1 FAIL, 2 UNMEASURED or NOT_APPLICABLE, 3 input error.\n';

/// CLI entry point with injectable sinks so dispatch can be tested without
/// spawning a process.
int runCli(List<String> argv, {StringSink? out, StringSink? err}) {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  try {
    final command = parseInvocation(argv);
    if (command is HelpCommand) {
      outSink.write(usageText);
      return 0;
    }
    if (command is ExportCommand) {
      final fixture = loadFixture(command.fixturePath);
      final report = buildExportReport(fixture, fixturePath: command.fixturePath);
      _emit(report, command.outPath, outSink);
      return 0;
    }
    if (command is CompareCommand) {
      final fixture = loadFixture(command.fixturePath);
      final manifest = command.roiManifestPath == null
          ? null
          : loadRoiManifest(command.roiManifestPath!);
      final grouped = <String, List<CaptureSource>>{};
      for (final capture in command.captures) {
        grouped
            .putIfAbsent(capture.candidateId, () => <CaptureSource>[])
            .add(CaptureSource(capture.path, _readText(capture.path)));
      }
      final report = compareCaptures(
        fixture,
        grouped,
        manifest: manifest,
        fixturePath: command.fixturePath,
        manifestPath: command.roiManifestPath,
      );
      _emit(report.toJson(), command.outPath, outSink);
      return report.verdict.exitCode;
    }
    _fail('cli.unreachable', 'no command matched');
  } on SliceError catch (error) {
    errSink.writeln('slice-runner: error [' + error.code + ']: ' + error.message +
        error.pointer);
    return 3;
  } on FileSystemException catch (error) {
    errSink.writeln('slice-runner: io error: ' + error.message + ' (' +
        error.path.toString() + ')');
    return 3;
  } on FormatException catch (error) {
    errSink.writeln('slice-runner: json error: ' + error.message);
    return 3;
  }
}

void main(List<String> arguments) {
  exitCode = runCli(arguments);
}
