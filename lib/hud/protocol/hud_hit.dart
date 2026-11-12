/// Native HUD hit target model and decoder.
///
/// Wire source: `NativeHud::hit` inserts exactly six fields
/// (`Qt/src/NativeHud.cpp:102-108`): x, y, width, height, action, label.
/// `label` falls back to `action` when the C++ QString is null
/// (`label.isNull() ? action : label`). Only `Qt/src/PlayerBar.cpp:46-53`
/// adds `fixed: true` after the six fields; it is not a z index, it only tells
/// the modal overlay to skip its modal offset (`Qt/qml/Overlay.qml:191`).
/// [HudHit] therefore keeps the six required fields plus the optional
/// [HudHit.fixed] marker, the decoder retains a `true`, and
/// [appendHudPlayerBarFixed] remains for producers that start from a plain
/// six-field map. It is never inferred from the action prefix.
///
/// Order is semantics: the table is append-only inside a frame and the Qt
/// overlay walks it in order (`Qt/qml/Overlay.qml:185-220`), so nothing here
/// sorts, merges or deduplicates. The Android touch padding of 16 is applied
/// only at the consumption site (`Qt/qml/Overlay.qml:38-43`) and is never
/// written back into these source rectangles.
library;

/// One decoded hit target, in delivery order.
final class HudHit {
  const HudHit({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.action,
    required this.label,
    this.fixed = false,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  /// Interaction id consumed by the overlay, for example `music:like-current`.
  final String action;

  /// Accessibility/announcement label; defaults to [action] when the producer
  /// emitted a null QString.
  ///
  /// The fallback is keyed on `QString::isNull()`, not `isEmpty()`
  /// (`Qt/src/NativeHud.cpp:108`, default argument `QString label = {}` at
  /// `Qt/src/NativeHud.h:257`): only an absent/null label becomes [action], an
  /// explicitly empty string stays empty because Qt passes it through
  /// unchanged and the overlay announces `modelData.label`
  /// (`Qt/qml/Overlay.qml:195`).
  final String label;

  /// True only for a player-bar target (`Qt/src/PlayerBar.cpp:46-53`).
  ///
  /// The modal overlay skips its offset for a fixed target
  /// (`Qt/qml/Overlay.qml:191`), so a consumer must keep this flag attached to
  /// the hit. It is not a z index and it is never derived from [action].
  final bool fixed;

  /// Serializes the hit in Qt key order.
  ///
  /// The six required keys match `Qt/src/NativeHud.cpp:103-108`: `x`, `y`,
  /// `width`, `height`, `action`, `label`. A fixed target appends
  /// `"fixed": true` last, exactly where `Qt/src/PlayerBar.cpp:47-53` writes
  /// it, so decoding and re-publishing a full frame cannot silently drop the
  /// flag. An ordinary target never gains `fixed: false`.
  Map<String, Object?> toJson() => <String, Object?>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'action': action,
        'label': label,
        if (fixed) hudPlayerBarFixedField: true,
      };

  @override
  bool operator ==(Object other) =>
      other is HudHit &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.action == action &&
      other.label == label &&
      other.fixed == fixed;

  @override
  int get hashCode => Object.hash(x, y, width, height, action, label, fixed);

  @override
  String toString() =>
      'HudHit($action $x,$y ${width}x${height} label=$label fixed=$fixed)';
}

/// The optional hit key a player-bar producer appends after the six fields.
const String hudPlayerBarFixedField = 'fixed';

/// Returns [hit] with `fixed: true` appended, for player-bar targets only.
///
/// `Qt/src/PlayerBar.cpp:46-53` is the only producer of that flag in the Qt
/// app - `NativeHud::hit` writes the six fields and nothing else
/// (`Qt/src/NativeHud.cpp:102-108`) - and the overlay only reads it to skip
/// the modal offset (`Qt/qml/Overlay.qml:191`). It is not a z index and it
/// must never be inferred from the action prefix: `music:like-current` is a
/// player-bar target (`Qt/src/PlayerBar.cpp:170`), so a `music:` prefix does
/// not mean "not fixed" and a `player:` prefix does not mean "fixed".
///
/// The map is copied, so a hit shared with the six-field table is never
/// mutated, and an already fixed map is returned unchanged. A [HudHit] whose
/// [HudHit.fixed] is true already emits the marker through [HudHit.toJson], so
/// this helper is only needed when starting from a plain map.
Map<String, Object?> appendHudPlayerBarFixed(Map<String, Object?> hit) {
  if (hit[hudPlayerBarFixedField] == true) return hit;
  return <String, Object?>{...hit, hudPlayerBarFixedField: true};
}

/// One hit target the decoder had to repair or drop, addressed by wire index.
final class HudHitIssue {
  const HudHitIssue({
    required this.index,
    required this.action,
    required this.detail,
    required this.dropped,
  });

  final int index;
  final String action;
  final String detail;

  /// True when the target could not be used at all; false when it was kept with
  /// a repaired label.
  final bool dropped;

  @override
  String toString() => 'HudHitIssue(#$index $action: $detail)';
}

/// Decoded hit table plus every repair or drop.
final class HudHitDecode {
  const HudHitDecode({required this.hits, required this.issues});

  /// Targets in wire order, never reordered or deduplicated.
  final List<HudHit> hits;

  final List<HudHitIssue> issues;

  bool get hasDroppedHits => issues.any((issue) => issue.dropped);
}

/// Decodes a delivered hit array.
///
/// A target whose geometry is missing or not numeric is dropped and reported,
/// because a hit rectangle that cannot be trusted must not steal touches from
/// the rest of the overlay. A target whose label is not a string is kept with
/// `label = action` and reported, matching the Qt null-label fallback; an
/// absent label takes the same fallback, while an explicitly empty string is
/// preserved (Qt tests `isNull()`, `Qt/src/NativeHud.cpp:108`).
///
/// A target whose action is present but is not a string is dropped and
/// reported. Unlike the label it has no fallback, because the action is the
/// payload the consumer forwards verbatim (`Qt/qml/Overlay.qml:196,205`) and
/// Qt's producer always writes a string one (`Qt/src/NativeHud.cpp:102-108`).
///
/// Delivery order is preserved. The optional `fixed` marker is read with Qt's
/// `QJsonValue::toBool` semantics: only a JSON `true` sets [HudHit.fixed];
/// absent, `false`, or any other type leaves it false. The flag is retained
/// rather than discarded (`Qt/src/PlayerBar.cpp:46-53`), so a full
/// decode/re-publish round trip keeps it. Nothing here infers it from the
/// action prefix: player-bar targets also carry non-`player:` actions such as
/// `music:like-current` (`Qt/src/PlayerBar.cpp:170`).
HudHitDecode decodeHudHits(List<Object?> raw) {
  final hits = <HudHit>[];
  final issues = <HudHitIssue>[];

  for (var index = 0; index < raw.length; index++) {
    final entry = raw[index];
    if (entry is! Map) {
      issues.add(HudHitIssue(
        index: index,
        action: '',
        detail: 'hit is ${entry.runtimeType}, expected an object',
        dropped: true,
      ));
      continue;
    }
    final map = entry;
    final actionValue = map['action'];
    final action = actionValue is String ? actionValue : '';
    final x = _geometry(map, 'x');
    final y = _geometry(map, 'y');
    final width = _geometry(map, 'width');
    final height = _geometry(map, 'height');

    if (x == null || y == null || width == null || height == null) {
      final missing = <String>[
        if (x == null) 'x',
        if (y == null) 'y',
        if (width == null) 'width',
        if (height == null) 'height',
      ].join(', ');
      issues.add(HudHitIssue(
        index: index,
        action: action,
        detail: 'geometry is missing or not numeric: $missing',
        dropped: true,
      ));
      continue;
    }
    if (actionValue is! String) {
      issues.add(HudHitIssue(
        index: index,
        action: action,
        detail: 'action is ${actionValue.runtimeType}, expected a string',
        dropped: true,
      ));
      continue;
    }

    final labelValue = map['label'];
    var label = action;
    if (labelValue != null) {
      if (labelValue is String) {
        label = labelValue;
      } else {
        issues.add(HudHitIssue(
          index: index,
          action: action,
          detail: 'label is ${labelValue.runtimeType}, fell back to action',
          dropped: false,
        ));
      }
    }

    hits.add(HudHit(
      x: x,
      y: y,
      width: width,
      height: height,
      action: action,
      label: label,
      fixed: map[hudPlayerBarFixedField] == true,
    ));
  }

  return HudHitDecode(
    hits: List<HudHit>.unmodifiable(hits),
    issues: List<HudHitIssue>.unmodifiable(issues),
  );
}

double? _geometry(Map<Object?, Object?> map, String field) {
  final value = map[field];
  return value is num ? value.toDouble() : null;
}
