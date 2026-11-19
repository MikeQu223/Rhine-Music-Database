import 'hud_command.dart';
import 'hud_hit.dart';

/// Native HUD frame envelope: one atomic snapshot of the scene frame, the
/// command array and the hit table, plus the generation that ties them
/// together.
///
/// Source facts: the Qt HUD derives commands, hits and the frame it draws from
/// a single `step`/`draw` pass (`Qt/src/NativeApplication.cpp:110,131,147-151`);
/// `NativeHud::draw` clears the tables and re-emits them in one call
/// (`Qt/src/NativeHud.cpp:252-256`). Qt therefore has no generation field to
/// compare - the Flutter envelope adds one so a stale or split delivery can be
/// rejected, and the rule is all-or-nothing: a snapshot whose generation is not
/// newer is discarded whole, never merged field by field.
///
/// Provenance of the envelope fields (local adapter only): Qt returns
/// `{commands, hits, state, current, cover}` together with the scene frame from
/// a single step (`Qt/src/NativeApplication.cpp:147-151`, frame at
/// `:110,131`) and has no `generation` key anywhere, while
/// `MusicBridge/worker.cjs` carries no HUD field at all. Assembling
/// `generation` + `frame` + `commands` + `hits` + `state` into one envelope is
/// therefore a local-adapter responsibility, never a Qt wire fact, and the
/// legacy worker must not be extended to emit these fields.

/// Envelope fields that exist only because the Flutter local adapter assembles
/// them; none of them is a Qt wire field.
///
/// `frame`, `commands`, `hits` and `state` do travel in Qt's own step result
/// (`Qt/src/NativeApplication.cpp:147-151`), but as four sibling keys of one
/// pass, not as members of an envelope, and `generation` has no Qt counterpart
/// at all.
const List<String> hudLocalAdapterFrameEnvelopeFields = <String>[
  'generation',
  'frame',
  'commands',
  'hits',
  'state',
];

/// The 31 frame keys `NativeScene::emitFrame` writes literally, in emit order
/// (`Qt/src/NativeSceneFrame.cpp:87-119`).
///
/// This is the count the task description called "31"; it is a real subset of
/// the delivery, not the delivery itself.
const List<String> hudQtLiteralFrameKeys = <String>[
  'pendingAnimations',
  'pointerCursor',
  'aoProjection',
  'reference',
  'near',
  'far',
  'viewer',
  'viewerReady',
  'viewerState',
  'mode',
  'selected',
  'culledCards',
  'shadowCards',
  'returningCards',
  'returningPartNodes',
  'globalSubdued',
  'returningMusicKeys',
  'returningAgeMax',
  'time',
  'draws',
  'view',
  'projection',
  'eye',
  'background',
  'fogColor',
  'fogNear',
  'fogFar',
  'detail',
  'boot',
  'focus',
  'aperture',
];

/// Keys added to the frame after the literal block of `emitFrame`.
///
/// `culledCards`/`shadowCards`-`draws` are overwritten there too; these four are
/// new keys (`Qt/src/NativeSceneFrame.cpp:164-166,195`).
const List<String> hudQtFrameKeysAddedAfterLiterals = <String>[
  'actorTemplate',
  'appearanceRevision',
  'actors',
  'stats',
];

/// Keys that `NativeCards::expand` deletes again before the frame is delivered
/// (`Qt/src/NativeCards.cpp:303-304`, Darwin `Qt/src/NativeCards.cpp:236-237`).
///
/// They are added by `emitFrame` and must never appear in a delivered frame.
const List<String> hudQtFrameKeysRemovedByCardsExpand = <String>[
  'actorTemplate',
  'actors',
];

/// The 33 top-level frame keys a delivered frame actually carries.
///
/// Derivation (`.json`): `NativeScene::emitFrame`
/// builds 31 keys literally (`Qt/src/NativeSceneFrame.cpp:87-119`), then adds
/// actorTemplate/appearanceRevision/actors (`:164-166`) and stats (`:195`);
/// `NativeCards::expand` removes actorTemplate and actors again
/// (`Qt/src/NativeCards.cpp:303-304`, Darwin `:236-237`), leaving 33 delivered
/// keys: `hudQtLiteralFrameKeys` (31) plus the two additions that survive,
/// `appearanceRevision` and `stats` (`actorTemplate` and `actors` are removed
/// again, see [hudQtFrameKeysRemovedByCardsExpand]). The 31 literal keys keep
/// their emit order below and the two survivors follow them; that order exists
/// so reports and diffs stay stable, not because
/// the wire preserves it - `QJsonObject` serialises keys sorted, so only
/// membership is a protocol fact. Unknown top-level keys stay readable through
/// [HudFrameView.raw] and must be ignored (contract §4.1, in the  worktree
/// at `docs/flutter-migration/contracts/hud-protocol.md`; this worktree has no
/// contracts directory), never used to change HUD layout.
const List<String> hudDeliveredFrameKeys = <String>[
  ...hudQtLiteralFrameKeys,
  'appearanceRevision',
  'stats',
];

/// Read-only typed view over the delivered frame object.
///
/// Only the keys the HUD family actually consumes are typed here, each one
/// verified against its Qt read site:
///
/// - `mode`: `Qt/src/NativeHud.cpp:89,218,246,257,269,272,279,309`
///   (`frame["mode"]`, compared against the string literals archive/detail/boot).
/// - `viewer`: `Qt/src/NativeHud.cpp:219,257,267` (`frame["viewer"].toBool()`).
/// - `detail`: `Qt/src/NativeHud.cpp:280,295`
///   (`frame["detail"].toDouble()`; `:283` is a comment line, not a read
///   site).
/// - `boot`: `Qt/src/NativeHudBoot.cpp:156`
///   (`frame["boot"].toObject()`), an object because
///   `BootTimeline::sample` returns QJsonObject
///   (`Qt/src/SceneMotion.h:84`, emitted at `Qt/src/NativeSceneFrame.cpp:117`).
///   Contract §4.1 types it as a number; the Qt source and
///   `reports/.json` (D2) both say object, and
///   `toObject()` on a scalar would silently read an empty object.
/// - `selected`: read with `toInt()` at every site (`Qt/src/NativeHud.cpp:469`,
///   `Qt/src/MusicLibrary.cpp:682`, `Qt/src/MusicDirectory.cpp:59,167,462`,
///   `Qt/src/MusicSiren.cpp:204,325`, `Qt/src/NativeApplication.cpp:122`).
///
/// Everything else stays available through [raw] so scene/viewer work can read
/// it without this file pretending to own those fields. No key outside this
/// list may influence HUD layout (contract §4.1 last paragraph).
final class HudFrameView {
  const HudFrameView(this.raw);

  final Map<String, Object?> raw;

  /// `frame["mode"].toString()`; empty when the producer omitted it.
  String get mode => raw['mode'] is String ? raw['mode']! as String : '';

  /// `frame["viewer"].toBool()`.
  bool get viewer => raw['viewer'] == true;

  /// `frame["detail"].toDouble()`; zero when absent, matching QJsonValue.
  double get detail {
    final value = raw['detail'];
    return value is num ? value.toDouble() : 0.0;
  }

  /// `frame["selected"].toInt().toDouble()`.
  ///
  /// Qt truncates towards zero at each read site, so a fractional producer
  /// value truncates here too instead of keeping its fraction. The fractional
  /// case is untested on device; the truncation is semantic, the magnitude
  /// is not.
  double get selected {
    final value = raw['selected'];
    return value is num ? value.toInt().toDouble() : 0.0;
  }

  /// The `boot` motion object, or null when the producer omitted it.
  ///
  /// It is an object (`SceneMotion::BootTimeline::sample` returns QJsonObject,
  /// `Qt/src/SceneMotion.h:84`, emitted at `Qt/src/NativeSceneFrame.cpp:117`),
  /// never a scalar.
  Map<String, Object?>? get boot {
    final value = raw['boot'];
    if (value is! Map) {
      return null;
    }
    return Map<String, Object?>.from(value);
  }

  /// Keys delivered beyond [hudDeliveredFrameKeys], in delivery order.
  List<String> get unexpectedKeys {
    final known = hudDeliveredFrameKeys.toSet();
    return <String>[
      for (final key in raw.keys)
        if (!known.contains(key)) key,
    ];
  }
}

/// Raised when a delivered snapshot cannot be interpreted at all.
///
/// Structural violations throw instead of degrading: a half-understood
/// snapshot must not be painted, because the HUD is a single atomic pass.
final class HudProtocolException implements Exception {
  const HudProtocolException(this.message);

  final String message;

  @override
  String toString() => 'HudProtocolException: $message';
}

/// One atomic HUD snapshot.
///
/// Provenance: every field below is assembled by the Flutter local adapter from
/// one Qt step result; see the file header. None of them may be read out of a
/// Qt frame key, and the legacy worker must not be asked to emit them.
final class HudFrameEnvelope {
  const HudFrameEnvelope({
    required this.generation,
    required this.frame,
    required this.commands,
    required this.hits,
    required this.state,
  });

  /// Monotonic snapshot counter owned by the Flutter local adapter.
  ///
  /// Origin (local, not a Qt wire fact): the adapter increments it once per
  /// assembled snapshot and no Qt value feeds it, because Qt publishes a step's
  /// `frame`/`commands`/`hits`/`state` without any counter
  /// (`Qt/src/NativeApplication.cpp:110,131,147-151`). Contract §1.3 forbids
  /// citing a Qt file:line as evidence for this field, so none is cited here;
  /// the field exists only so a stale or split delivery can be rejected whole.
  final int generation;

  final HudFrameView frame;
  final HudCommandDecode commands;
  final HudHitDecode hits;

  /// Playback/overlay state that travels with the same draw pass.
  final Map<String, Object?> state;

  /// Decodes the envelope, rejecting structurally invalid deliveries.
  ///
  /// `generation`, `frame`, `commands`, `hits` and `state` must all be
  /// present: they are the local adapter's envelope
  /// ([hudLocalAdapterFrameEnvelopeFields]), which is encoded and decoded on
  /// the Flutter side. `commands`, `hits` and `state` must be present even
  /// when empty, because the HUD publishes all three from one pass and a
  /// missing key means the snapshot was split. Decoding never reaches for a Qt
  /// frame key to fill a missing envelope field.
  factory HudFrameEnvelope.decode(Map<String, Object?> json) {
    final generation = json['generation'];
    if (generation is! int || generation < 0) {
      throw HudProtocolException(
        'generation must be a non-negative integer, got ${generation.runtimeType}',
      );
    }
    final frameRaw = json['frame'];
    if (frameRaw is! Map) {
      throw HudProtocolException(
        'frame must be an object, got ${frameRaw.runtimeType}',
      );
    }
    final commandsRaw = json['commands'];
    if (commandsRaw is! List) {
      throw HudProtocolException(
        'commands must be an array, got ${commandsRaw.runtimeType}',
      );
    }
    final hitsRaw = json['hits'];
    if (hitsRaw is! List) {
      throw HudProtocolException(
        'hits must be an array, got ${hitsRaw.runtimeType}',
      );
    }
    final stateRaw = json['state'];
    if (stateRaw is! Map) {
      throw HudProtocolException(
        'state must be an object, got ${stateRaw.runtimeType}',
      );
    }
    try {
      return HudFrameEnvelope(
        generation: generation,
        frame: HudFrameView(Map<String, Object?>.from(frameRaw)),
        commands: decodeHudCommands(commandsRaw),
        hits: decodeHudHits(hitsRaw),
        state: Map<String, Object?>.unmodifiable(
          Map<String, Object?>.from(stateRaw),
        ),
      );
    } on TypeError catch (error) {
      throw HudProtocolException('snapshot contains non-string keys: $error');
    }
  }

  /// True when this snapshot may replace one that was already applied.
  bool isNewerThan(int? appliedGeneration) =>
      appliedGeneration == null || generation > appliedGeneration;
}

/// Tracks which snapshot generation is currently on screen.
///
/// Applying is all-or-nothing: a snapshot that is not newer is dropped whole,
/// because mixing commands and hits from different draws would describe a UI
/// that never existed (`Qt/src/NativeHud.cpp:252-256`).
///
/// The counter this gate compares is the local-adapter generation of
/// [HudFrameEnvelope]; contract §1.3 marks the whole envelope as a proposed
/// Flutter-side object that Qt never emits, so a gate decision is never
/// evidence about Qt ordering.
final class HudFrameGate {
  HudFrameGate([this._appliedGeneration]);

  int? _appliedGeneration;

  int? get appliedGeneration => _appliedGeneration;

  bool shouldApply(HudFrameEnvelope envelope) =>
      envelope.isNewerThan(_appliedGeneration);

  /// Applies the snapshot when it is newer and returns whether it was applied.
  bool markApplied(HudFrameEnvelope envelope) {
    if (!shouldApply(envelope)) {
      return false;
    }
    _appliedGeneration = envelope.generation;
    return true;
  }
}

/// Stage geometry shared by paint, hit testing and text measurement.
///
/// Source: `stageScale = height > 0 ? height / 1080 : 1` and
/// `stageWidth = width / stageScale` in `Qt/qml/Overlay.qml:22-23` and
/// `Qt/qml/Main.qml:32-33`. The engine-side HUD is drawn with
/// `m_height > 0 ? m_width / (m_height / 1080) : 1920`
/// (`Qt/src/Engine.cpp:1353`), which is the same stage width without the
/// zero-height guard fallback of 1.
final class HudStage {
  const HudStage({required this.scale, required this.width, required this.height});

  /// Logical pixels per stage unit.
  final double scale;

  /// Stage-space width used by the command stream.
  final double width;

  /// Stage-space height.
  ///
  /// 1080 for the full-window landscape reading of the Qt overlay. A portrait
  /// subtree mounted by PortraitStage instead carries PortraitBands.stageHeight
  /// with [scale] pinned to 1.0.
  final double height;

  /// Full-window landscape conversion: derive scale from the logical height.
  ///
  /// forbids calling this inside a subtree that PortraitStage has
  /// already scaled. Portrait must consume the single injected stage instead:
  /// HudStage(scale: 1.0, width: 1080, height: PortraitBands.stageHeight).
  /// Kept for the legacy HudStagePainter fallback (lib/hud/render/hud_painter.dart:221),
  /// which runs outside PortraitStage.
  factory HudStage.fromLogicalSize({
    required double width,
    required double height,
  }) {
    final scale = height > 0 ? height / 1080.0 : 1.0;
    return HudStage(scale: scale, width: width / scale, height: height / scale);
  }

  /// The width the engine would report for the same logical size.
  static double engineHudWidth({
    required double width,
    required double height,
  }) =>
      height > 0 ? width / (height / 1080.0) : 1920.0;
}
