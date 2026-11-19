/// Scene frame: the value model of the Qt scene frame that the 3D wall and the
/// 3D viewer share.
///
/// Source of truth (baseline 708677579626f8eaeeef77e8588125ecadab4858):
///  * `Qt/src/NativeSceneFrame.cpp` (214 lines) — the literal frame keys and
///    their emit order (:87-119), the actor identity entries (:126-157) and the
///    viewport-pixel projection Qt uses for the wall corners (:189-193).
///    There is no `NativeSceneFrame.h`: `emitFrame` is declared on
///    `NativeScene` at `Qt/src/NativeScene.h:188`.
///  * `Qt/src/SceneAppearance.cpp:20-38` — `color()` and `blend()`: the frame's
///    `background` and `fogColor` are **linear** RGB triples with no alpha
///    component at all.
///  * `Qt/src/Engine.cpp:1353` — the HUD stage size derived from the offscreen
///    viewport: `m_height > 0 ? m_width / (m_height / 1080) : 1920`.
///  * `Qt/src/NativeScene.h:131-132` — the scene fog defaults `m_fogNear = 22`,
///    `m_fogFar = 47`; `Qt/src/NativeSceneCamera.cpp:96-97` retunes both per
///    frame, which is why the frame carries them instead of the consumer
///    recomputing them.
///  * `lib/scene/scene_math.dart` — the already-ported, column-major
///    `SceneMath::Matrix` (`values[column * 4 + row]`). This file never
///    re-implements matrix maths, it only carries matrices.
///
/// What this file owns
///  * `SceneSize` — the offscreen viewport and the HUD stage it yields.
///  * `LinearRgb` — the alpha-free linear colour triple of
///    `SceneAppearance::color` plus the `blend` used for `background` and
///    `fogColor`.
///  * `SceneActorIdentity` — one entry of the frame's `actors` array
///    (`NativeSceneFrame.cpp:143-146`: `id`, `musicKey` (JSON null when the
///    actor has no track), `selected`, `shadowOnly`).
///  * `SceneFrame` — the typed half of the frame, with a Qt-equivalent
///    constructor (`fromQtFrame`), `copyWith` and a `toQtFrame` that re-emits
///    the same keys. **Unknown keys are preserved verbatim** in `extensions`:
///    the Qt frame grows over time (draws, cards, stats, decryption, pulses…)
///    and a port that silently dropped the keys it does not model would break
///    the HUD protocol envelope that consumes them. `lib/hud/protocol/
///    hud_frame.dart` documents the same rule from the consumer side: unknown
///    top-level keys stay readable and must be ignored, never invented.
///
/// What this file deliberately does NOT own
///  * `draws`, `culledCards`, `shadowCards`, `stats`, `actorTemplate`,
///    `appearanceRevision`, `viewerState` — produced by the card expander
///    (`NativeSceneFrame.cpp:160`) and the viewer overlay; they travel through
///    `extensions` untouched. Typed viewer state lives in
///    `lib/scene/viewer_state.dart`.
///  * The model matrix of a *delivered* frame: Qt composes it inside
///    `emitFrame` (`NativeSceneFrame.cpp:189`:
///    `m_projection * m_view * Matrix::compose(m_actor.position,
///    m_actor.rotation)`) and never ships it as a key of its own, so
///    `SceneFrame.fromQtFrame` takes it out of band.
///  * Qt's mutable frame object: the C++ side writes into one long-lived
///    `QJsonObject frame`; this model is immutable and every step produces a
///    new value.
///
/// Column-major reminder: every matrix here is a `Mat4` from `scene_math.dart`,
/// i.e. 16 doubles in stored order with `index == column * 4 + row`
/// (`Qt/src/SceneMath.h:22`). A frame never transposes anything —
/// `Mat4.toJson()` hands back that stored order, exactly the order Qt writes at
/// `NativeSceneFrame.cpp:114-115`.
library;

import 'dart:math' as math;

import 'scene_math.dart';

// Frame vocabulary — every literal cites the Qt line it was copied from.

/// Scene modes a frame can report (`NativeSceneFrame.cpp:98`).
const String kFrameModeBoot = 'boot';
const String kFrameModeArchive = 'archive';
const String kFrameModeDetail = 'detail';

/// Wall background gradient ends — `NativeSceneFrame.cpp:110-111`.
const String kBackgroundLightHex = '#eae5e1';
const String kBackgroundDarkHex = '#11181b';

/// Fog gradient ends — `NativeSceneFrame.cpp:112-113`.
const String kFogLightHex = '#eae5e1';
const String kFogDarkHex = '#263136';

/// Scene fog defaults — `Qt/src/NativeScene.h:131-132`.
const double kDefaultFogNear = 22.0;
const double kDefaultFogFar = 47.0;

/// HUD stage height: `Qt/src/Engine.cpp:1353` divides the offscreen width by
/// `height / 1080`, so the stage always reports 1080 logical pixels tall.
const double kStageHeight = 1080.0;

/// Degenerate-viewport stage width — the `: 1920` branch of `Engine.cpp:1353`.
const double kStageFallbackWidth = 1920.0;

/// The frame keys this model types. Everything else a frame carries is kept in
/// `SceneFrame.extensions` verbatim.
///
/// This is deliberately *not* the literal key list of
/// `NativeSceneFrame.cpp:87-119`: only keys whose value is a self-contained
/// scene fact are typed here. `viewerState`, `draws`, `stats` and the card
/// counters belong to other layers and stay raw.
const List<String> sceneFrameOwnedKeys = <String>[
  'aoProjection',
  'near',
  'far',
  'viewer',
  'viewerReady',
  'mode',
  'selected',
  'time',
  'view',
  'projection',
  'eye',
  'background',
  'fogColor',
  'fogNear',
  'fogFar',
  'detail',
  'actors',
];

/// Thrown when a frame value cannot be read as the Qt structure it claims to
/// be.
///
/// Qt itself never validates here — a missing key simply reads as a defaulted
/// `QJsonValue`. This model keeps that leniency for *optional* keys and throws
/// only when a typed key is present with a shape the port cannot represent: a
/// 15-element matrix, a 4-component colour, a non-numeric component.
class SceneFrameFormatException implements Exception {
  const SceneFrameFormatException(this.message);

  final String message;

  @override
  String toString() => 'SceneFrameFormatException: ' + message;
}

// Sizes.

/// An offscreen viewport, or the HUD stage derived from it.
///
/// `dart:ui` is unavailable to this library on purpose: the scene layer stays
/// pure Dart so it can be unit-tested without a Flutter binding, so this
/// carries two doubles instead of a `Size`.
final class SceneSize {
  const SceneSize(this.width, this.height);

  /// The stage a degenerate viewport reports — `Qt/src/Engine.cpp:1353`.
  static const SceneSize stageFallback =
      SceneSize(kStageFallbackWidth, kStageHeight);

  final double width;
  final double height;

  /// `width / height` with no zero guard, matching the C++ call sites
  /// (`NativeViewer.cpp:288`, `NativeSceneCamera.cpp:56`): a zero height yields
  /// infinity, never a silent 1.
  double get aspect => width / height;

  /// The HUD stage for this viewport — `Qt/src/Engine.cpp:1353`:
  ///
  ///     stageWidth = m_height > 0 ? m_width / (m_height / 1080) : 1920;
  ///
  /// `NativeHud.cpp:225` states the same rule from the HUD side: the stage
  /// width must equal the offscreen layer width divided by `height / 1080`.
  SceneSize get stage {
    if (height > 0) {
      return SceneSize(width / (height / kStageHeight), kStageHeight);
    }
    return stageFallback;
  }

  /// True when the size cannot produce a usable projection.
  bool get isEmpty => width <= 0 || height <= 0;

  @override
  bool operator ==(Object other) =>
      other is SceneSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() =>
      'SceneSize(' + width.toString() + ', ' + height.toString() + ')';
}

// Linear colour.

/// One linear-RGB colour, alpha-free.
///
/// Qt `SceneAppearance::color` (`Qt/src/SceneAppearance.cpp:20-27`) converts a
/// `QColor` to three linear components and drops alpha:
///
///     const auto linear = [](double component) {
///         return component < 0.04045 ? component * 0.0773993808
///                                    : std::pow(component * 0.9478672986 + 0.0521327014, 2.4);
///     };
///     return {linear(value.red() / 255.0), linear(value.green() / 255.0),
///             linear(value.blue() / 255.0)};
///
/// `SceneAppearance::blend` (`:28-38`) then interpolates indices 0..2 only. The
/// frame's `background` and `fogColor` are exactly these triples, so this type
/// refuses a fourth component: `toJson()` always has length 3 and `fromJson`
/// rejects anything else. That invariant is the port's guarantee that no stray
/// alpha reaches the 3D clear colour.
final class LinearRgb {
  const LinearRgb(this.r, this.g, this.b);

  /// sRGB → linear threshold and coefficients — `SceneAppearance.cpp:22-23`.
  static const double srgbThreshold = 0.04045;
  static const double srgbLowScale = 0.0773993808;
  static const double srgbHighScale = 0.9478672986;
  static const double srgbHighOffset = 0.0521327014;
  static const double srgbGamma = 2.4;

  /// Parse one 6-digit `#rrggbb` literal through Qt's sRGB → linear curve.
  ///
  /// Only the `#rrggbb` form Qt uses for the frame palette is accepted
  /// (`#eae5e1`, `#11181b`, `#263136`). `QColor` also accepts `#rgb` and
  /// `#aarrggbb`; the alpha form cannot be represented here by construction, so
  /// it is a format error rather than a silent drop.
  factory LinearRgb.fromHex(String hex) {
    final String digits = hex.startsWith('#') ? hex.substring(1) : hex;
    if (digits.length != 6) {
      throw SceneFrameFormatException(
        'linear colour needs a 6-digit #rrggbb literal, got ' + hex,
      );
    }
    final int? packed = int.tryParse(digits, radix: 16);
    if (packed == null) {
      throw SceneFrameFormatException(
        'linear colour has non-hex digits: ' + hex,
      );
    }
    return LinearRgb(
      _linear((packed >> 16) & 0xff),
      _linear((packed >> 8) & 0xff),
      _linear(packed & 0xff),
    );
  }

  /// Read one `[r, g, b]` array — `SceneAppearance.cpp:20-27`.
  ///
  /// Strictly three components: a `QJsonArray` of four would mean an alpha
  /// channel the frame never had.
  factory LinearRgb.fromJson(Object? json) {
    if (json is! List) {
      throw SceneFrameFormatException(
        'linear colour must be an array, got ' + _shape(json),
      );
    }
    if (json.length != 3) {
      throw SceneFrameFormatException(
        'linear colour must have exactly 3 components, got ' +
            json.length.toString(),
      );
    }
    return LinearRgb(
      _component(json[0], 'red'),
      _component(json[1], 'green'),
      _component(json[2], 'blue'),
    );
  }

  /// Light-mode background, `#eae5e1` in linear space.
  static final LinearRgb backgroundLight =
      LinearRgb.fromHex(kBackgroundLightHex);

  /// Dark-mode background, `#11181b` in linear space.
  static final LinearRgb backgroundDark = LinearRgb.fromHex(kBackgroundDarkHex);

  /// Light-mode fog, `#eae5e1` in linear space.
  static final LinearRgb fogLight = LinearRgb.fromHex(kFogLightHex);

  /// Dark-mode fog, `#263136` in linear space.
  static final LinearRgb fogDark = LinearRgb.fromHex(kFogDarkHex);

  final double r;
  final double g;
  final double b;

  /// `SceneAppearance::blend` (`:28-38`) — `from + (to - from) * amount` per
  /// component, no clamp, exactly like the C++ (the theme is bounded upstream
  /// by `SceneMotion::Theme`).
  LinearRgb blend(LinearRgb to, double amount) => LinearRgb(
        r + (to.r - r) * amount,
        g + (to.g - g) * amount,
        b + (to.b - b) * amount,
      );

  /// Always length 3 — the alpha-free wire shape of `SceneAppearance::color`.
  List<double> toJson() => <double>[r, g, b];

  /// Qt's sRGB → linear transfer function (`SceneAppearance.cpp:22-23`).
  static double _linear(int channel) {
    final double component = channel / 255.0;
    if (component < srgbThreshold) {
      return component * srgbLowScale;
    }
    return math
        .pow(component * srgbHighScale + srgbHighOffset, srgbGamma)
        .toDouble();
  }

  static double _component(Object? value, String name) {
    if (value is num) {
      return value.toDouble();
    }
    throw SceneFrameFormatException(
      'linear colour component ' + name + ' must be numeric, got ' + _shape(value),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LinearRgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() =>
      'LinearRgb(' + r.toString() + ', ' + g.toString() + ', ' + b.toString() + ')';
}

// Identities.

/// One entry of the frame's `actors` array — `NativeSceneFrame.cpp:143-146`:
///
///     actors.append(QJsonObject{{"id", actor.id},
///                               {"musicKey", actor.musicKey.isEmpty() ? QJsonValue(QJsonValue::Null)
///                                                                    : QJsonValue(actor.musicKey)},
///                               {"selected", selected},
///                               {"shadowOnly", shadow}});
///
/// `id` is an `int` (`Qt/src/NativeScene.h:84`: `int id = 2`). The selected
/// actor is added first with `selected = true` (`:152`); every returning actor
/// follows with `false` (`:153-155`). `shadowOnly` marks an actor that is
/// off-camera but still inside the light frustum (`:132-141`), so it must keep
/// being drawn into the shadow map.
final class SceneActorIdentity {
  const SceneActorIdentity({
    required this.id,
    this.musicKey,
    this.selected = false,
    this.shadowOnly = false,
  });

  factory SceneActorIdentity.fromJson(Map<String, Object?> json) {
    final Object? id = json['id'];
    if (id is! num) {
      throw SceneFrameFormatException(
        'actor id must be numeric, got ' + _shape(id),
      );
    }
    final Object? musicKey = json['musicKey'];
    if (musicKey != null && musicKey is! String) {
      throw SceneFrameFormatException(
        'actor musicKey must be a string or null, got ' + _shape(musicKey),
      );
    }
    return SceneActorIdentity(
      id: id.toInt(),
      musicKey: musicKey as String?,
      selected: _boolean(json['selected'], 'selected'),
      shadowOnly: _boolean(json['shadowOnly'], 'shadowOnly'),
    );
  }

  final int id;

  /// `null` when the actor has no track: Qt writes `QJsonValue::Null`, not an
  /// empty string (`NativeSceneFrame.cpp:144-145` decides on
  /// `Actor::musicKey.isEmpty()`, `Qt/src/NativeScene.h:93`).
  final String? musicKey;

  final bool selected;

  final bool shadowOnly;

  /// The Qt key set, including `musicKey: null` so a round trip keeps the key
  /// present with a null value instead of dropping it.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'musicKey': musicKey,
        'selected': selected,
        'shadowOnly': shadowOnly,
      };

  @override
  bool operator ==(Object other) =>
      other is SceneActorIdentity &&
      other.id == id &&
      other.musicKey == musicKey &&
      other.selected == selected &&
      other.shadowOnly == shadowOnly;

  @override
  int get hashCode => Object.hash(id, musicKey, selected, shadowOnly);

  @override
  String toString() =>
      'SceneActorIdentity(' +
      id.toString() +
      ', musicKey: ' +
      musicKey.toString() +
      ', selected: ' +
      selected.toString() +
      ', shadowOnly: ' +
      shadowOnly.toString() +
      ')';
}

/// Which record a frame is about, when the caller knows it out of band.
///
/// This is **not** a frame key. Qt returns the current record through the step
/// result envelope: `current` travels next to `frame`, `commands`, `hits` and
/// `state` as one sibling of a single pass
/// (`Qt/src/NativeApplication.cpp:147-151`, cited by
/// `lib/hud/protocol/hud_frame.dart`), so `toQtFrame()` never emits it. Keeping
/// it on the frame value keeps "which record is this about" in one place
/// instead of making every consumer re-read the envelope.
final class SceneCurrent {
  const SceneCurrent({this.musicKey, this.index});

  final String? musicKey;

  /// Position of `musicKey` in the visible library, when known.
  final int? index;

  @override
  bool operator ==(Object other) =>
      other is SceneCurrent &&
      other.musicKey == musicKey &&
      other.index == index;

  @override
  int get hashCode => Object.hash(musicKey, index);

  @override
  String toString() => 'SceneCurrent(musicKey: ' +
      musicKey.toString() +
      ', index: ' +
      index.toString() +
      ')';
}

// Palette helpers — NativeSceneFrame.cpp:110-113.

/// `background` for a theme amount — `NativeSceneFrame.cpp:110-111`:
///
///     SceneAppearance::blend(SceneAppearance::color("#eae5e1"),
///                            SceneAppearance::color("#11181b"), theme)
LinearRgb sceneBackground(double theme) =>
    LinearRgb.backgroundLight.blend(LinearRgb.backgroundDark, theme);

/// `fogColor` for a theme amount — `NativeSceneFrame.cpp:112-113`.
LinearRgb sceneFogColor(double theme) =>
    LinearRgb.fogLight.blend(LinearRgb.fogDark, theme);

// The frame.

/// The typed half of the Qt scene frame.
///
/// Construction paths:
///  * `SceneFrame.fromQtFrame` — read a frame map that came off the Qt side (or
///    off `lib/hud/protocol/hud_frame.dart`), keeping every key this model does
///    not type.
///  * the generative constructor — build a frame locally (tests, adapters).
///  * `copyWith` — derive a changed frame without losing extensions.
///
/// `toQtFrame()` emits the typed keys in the Qt emit order and then the
/// preserved keys in their original order, so a round trip preserves both
/// membership and first-seen order. Typed values always win over an extension
/// that happens to share a key name.
final class SceneFrame {
  SceneFrame({
    required this.projection,
    required this.view,
    Mat4? model,
    required this.background,
    required this.fogColor,
    this.fogNear = kDefaultFogNear,
    this.fogFar = kDefaultFogFar,
    this.near = kSceneNear,
    this.far = kSceneFar,
    required this.viewport,
    this.mode = kFrameModeBoot,
    this.selected = 0,
    this.time = 0,
    this.detail = 0,
    this.eye = Vec3.zero,
    this.viewer = false,
    this.viewerReady = false,
    Mat4? aoProjection,
    List<SceneActorIdentity> actors = const <SceneActorIdentity>[],
    this.current,
    Map<String, Object?> extensions = const <String, Object?>{},
  })  : model = model ?? Mat4(),
        aoProjection = aoProjection ?? projection,
        actors = List<SceneActorIdentity>.unmodifiable(actors),
        extensions = Map<String, Object?>.unmodifiable(extensions);

  /// Read a Qt frame map.
  ///
  /// Optional keys fall back to the Qt literal defaults instead of throwing,
  /// because a partial frame is a normal intermediate state; required structure
  /// — the two matrices and the two colours — throws
  /// `SceneFrameFormatException` when absent or malformed, since a frame
  /// without them cannot be drawn.
  ///
  /// [viewport] is required: the frame map carries pixel stats
  /// (`NativeSceneFrame.cpp:192-193`) but not the viewport they were computed
  /// against, and the caller owns the offscreen size.
  factory SceneFrame.fromQtFrame(
    Map<String, Object?> frame, {
    required SceneSize viewport,
    Mat4? model,
    SceneCurrent? current,
  }) {
    final Map<String, Object?> extensions = <String, Object?>{};
    for (final MapEntry<String, Object?> entry in frame.entries) {
      if (!sceneFrameOwnedKeys.contains(entry.key)) {
        extensions[entry.key] = entry.value;
      }
    }
    final Mat4 projection = _matrix(frame['projection'], 'projection');
    final Object? aoProjection = frame['aoProjection'];
    return SceneFrame(
      projection: projection,
      view: _matrix(frame['view'], 'view'),
      model: model,
      background: LinearRgb.fromJson(frame['background']),
      fogColor: LinearRgb.fromJson(frame['fogColor']),
      fogNear: _number(frame['fogNear'], 'fogNear', kDefaultFogNear),
      fogFar: _number(frame['fogFar'], 'fogFar', kDefaultFogFar),
      near: _number(frame['near'], 'near', kSceneNear),
      far: _number(frame['far'], 'far', kSceneFar),
      viewport: viewport,
      mode: _string(frame['mode'], 'mode', kFrameModeBoot),
      selected: _integer(frame['selected'], 'selected', 0),
      time: _number(frame['time'], 'time', 0),
      detail: _number(frame['detail'], 'detail', 0),
      eye: _vector(frame['eye'], 'eye'),
      viewer: _boolean(frame['viewer'], 'viewer'),
      viewerReady: _boolean(frame['viewerReady'], 'viewerReady'),
      aoProjection:
          aoProjection == null ? projection : _matrix(aoProjection, 'aoProjection'),
      actors: _actors(frame['actors']),
      current: current,
      extensions: extensions,
    );
  }

  /// Column-major view-projection of the wall — `NativeSceneFrame.cpp:115`.
  final Mat4 projection;

  /// Column-major view matrix — `NativeSceneFrame.cpp:114`.
  final Mat4 view;

  /// Column-major model matrix of the selected actor — composed by Qt at
  /// `NativeSceneFrame.cpp:189` and never a key of its own.
  final Mat4 model;

  /// Linear, alpha-free background — see `sceneBackground`.
  final LinearRgb background;

  /// Linear, alpha-free fog colour — see `sceneFogColor`.
  final LinearRgb fogColor;

  /// Fog window; `NativeSceneCamera.cpp:96-97` retunes both every frame.
  final double fogNear;
  final double fogFar;

  /// Scene clip planes — the 5 and 300 literals of
  /// `NativeSceneFrame.cpp:96-97`.
  final double near;
  final double far;

  /// The offscreen viewport this frame was sampled in; `stage` derives the HUD
  /// stage from it.
  final SceneSize viewport;

  /// `boot`, `archive` or `detail` — `NativeSceneFrame.cpp:98`.
  final String mode;

  /// Slot of the selected card — `NativeSceneFrame.cpp:99`.
  final int selected;

  /// Scene clock of this frame — `NativeSceneFrame.cpp:106`.
  final double time;

  /// `SceneMotion::smooth((m_detail - 0.25) / 0.55)` —
  /// `NativeSceneFrame.cpp:116`.
  final double detail;

  /// Camera eye — `NativeSceneFrame.cpp:115` writes `m_eye.json()`.
  final Vec3 eye;

  /// True once the viewer overlay owns this frame — `NativeViewer.cpp:277-280`.
  final bool viewer;

  /// Mesh readiness of the viewer — `NativeViewer.cpp:279`.
  final bool viewerReady;

  /// Ambient-occlusion projection — `NativeSceneFrame.cpp:94`.
  ///
  /// Always present on a Qt frame. When reading a map that lacks it this falls
  /// back to the main projection rather than null: every consumer of the AO
  /// pass needs some matrix, and a nullable field would force each call site to
  /// invent the same default.
  final Mat4 aoProjection;

  /// Actor identities — `NativeSceneFrame.cpp:159`.
  ///
  /// Read this together with a delivery caveat: the card expander deletes
  /// `actorTemplate` and `actors` again before the frame is delivered
  /// (`NativeCards.cpp:303-304`, cited by `lib/hud/protocol/hud_frame.dart`), so
  /// a *delivered* frame normally has this list empty and only `selected`
  /// survives as identity. The field stays because the pre-expand frame really
  /// carries it and because the port must not forget a key that arrives.
  final List<SceneActorIdentity> actors;

  /// The record this frame is about, when the caller knows it. Never emitted by
  /// `toQtFrame()` — it is an envelope fact, not a frame key.
  final SceneCurrent? current;

  /// Every frame key this model does not type, preserved verbatim: `draws`,
  /// `viewerState`, `stats`, the card counters, `boot`, `focus`, `aperture`,
  /// `reference`, `pendingAnimations`…
  final Map<String, Object?> extensions;

  /// The HUD stage this frame's viewport produces — `Qt/src/Engine.cpp:1353`.
  SceneSize get stage => viewport.stage;

  /// The identity entry Qt marks `selected`, if the frame still carries the
  /// `actors` array.
  SceneActorIdentity? get selectedActor {
    for (final SceneActorIdentity actor in actors) {
      if (actor.selected) {
        return actor;
      }
    }
    return null;
  }

  /// True when `mode` is the detail page — the only scene mode that opens the
  /// viewer (`NativeHudDetail.cpp:74`, `NativeScene.cpp:274-284`).
  bool get isDetail => mode == kFrameModeDetail;

  /// A copy with the named fields replaced.
  ///
  /// `current` is nullable and therefore needs an explicit clear flag:
  /// `clearCurrent: true` sets it to null, omitting both keeps the old value.
  SceneFrame copyWith({
    Mat4? projection,
    Mat4? view,
    Mat4? model,
    LinearRgb? background,
    LinearRgb? fogColor,
    double? fogNear,
    double? fogFar,
    double? near,
    double? far,
    SceneSize? viewport,
    String? mode,
    int? selected,
    double? time,
    double? detail,
    Vec3? eye,
    bool? viewer,
    bool? viewerReady,
    Mat4? aoProjection,
    List<SceneActorIdentity>? actors,
    SceneCurrent? current,
    bool clearCurrent = false,
    Map<String, Object?>? extensions,
  }) {
    return SceneFrame(
      projection: projection ?? this.projection,
      view: view ?? this.view,
      model: model ?? this.model,
      background: background ?? this.background,
      fogColor: fogColor ?? this.fogColor,
      fogNear: fogNear ?? this.fogNear,
      fogFar: fogFar ?? this.fogFar,
      near: near ?? this.near,
      far: far ?? this.far,
      viewport: viewport ?? this.viewport,
      mode: mode ?? this.mode,
      selected: selected ?? this.selected,
      time: time ?? this.time,
      detail: detail ?? this.detail,
      eye: eye ?? this.eye,
      viewer: viewer ?? this.viewer,
      viewerReady: viewerReady ?? this.viewerReady,
      aoProjection: aoProjection ?? this.aoProjection,
      actors: actors ?? this.actors,
      current: clearCurrent ? null : (current ?? this.current),
      extensions: extensions ?? this.extensions,
    );
  }

  /// Rebuild the Qt frame map.
  ///
  /// Typed keys are written in the Qt emit order
  /// (`NativeSceneFrame.cpp:87-119`) and the preserved keys follow in their
  /// original order. Qt objects serialise with sorted keys (`QJsonObject`), so
  /// only membership and values are protocol facts — the order here exists for
  /// readable diffs, not for wire compatibility.
  ///
  /// `actors` is only emitted when non-empty: a delivered frame has had it
  /// removed again, and re-introducing an empty array would fake a Qt state
  /// that does not exist.
  Map<String, Object?> toQtFrame() {
    final Map<String, Object?> frame = <String, Object?>{
      'aoProjection': aoProjection.toJson(),
      'near': near,
      'far': far,
      'viewer': viewer,
      'viewerReady': viewerReady,
      'mode': mode,
      'selected': selected,
      'time': time,
      'view': view.toJson(),
      'projection': projection.toJson(),
      'eye': <double>[eye.x, eye.y, eye.z],
      'background': background.toJson(),
      'fogColor': fogColor.toJson(),
      'fogNear': fogNear,
      'fogFar': fogFar,
      'detail': detail,
    };
    if (actors.isNotEmpty) {
      frame['actors'] = <Map<String, Object?>>[
        for (final SceneActorIdentity actor in actors) actor.toJson(),
      ];
    }
    for (final MapEntry<String, Object?> entry in extensions.entries) {
      frame.putIfAbsent(entry.key, () => entry.value);
    }
    return frame;
  }

  /// Project a model-space point into viewport pixels — the `project` lambda of
  /// `NativeSceneFrame.cpp:192-193`:
  ///
  ///     return QJsonArray{std::floor((value.x + 1) * m_width / 2 + 0.5),
  ///                       std::floor((1 - value.y) * m_height / 2 + 0.5)};
  ///
  /// The `+ 0.5` before the floor is Qt's pixel-centre rounding and y is
  /// flipped because the projection is OpenGL-style (+y up). Both results are
  /// integral doubles.
  List<double> projectPoint(Vec3 point) {
    final Vec3 ndc = (projection * view * model).point(point);
    return <double>[
      ((ndc.x + 1) * viewport.width / 2 + 0.5).floorToDouble(),
      ((1 - ndc.y) * viewport.height / 2 + 0.5).floorToDouble(),
    ];
  }

  @override
  String toString() => 'SceneFrame(mode: ' +
      mode +
      ', selected: ' +
      selected.toString() +
      ', viewport: ' +
      viewport.toString() +
      ', viewer: ' +
      viewer.toString() +
      ', extensions: ' +
      extensions.length.toString() +
      ')';
}

// Parsing helpers.

/// Render a value's shape for an error message without echoing its contents.
String _shape(Object? value) {
  if (value is List) {
    return value.length.toString() + '-element list';
  }
  if (value == null) {
    return 'null';
  }
  return value.runtimeType.toString();
}

Mat4 _matrix(Object? json, String key) {
  if (json is Mat4) {
    return json;
  }
  if (json is! List || json.length != 16) {
    throw SceneFrameFormatException(
      key + ' must be a 16-element column-major array, got ' + _shape(json),
    );
  }
  final List<double> values = <double>[];
  for (int index = 0; index < 16; index += 1) {
    final Object? value = json[index];
    if (value is! num) {
      throw SceneFrameFormatException(
        key + '[' + index.toString() + '] must be numeric, got ' + _shape(value),
      );
    }
    values.add(value.toDouble());
  }
  return Mat4(values);
}

Vec3 _vector(Object? json, String key) {
  if (json == null) {
    return Vec3.zero;
  }
  if (json is! List || json.length != 3) {
    throw SceneFrameFormatException(
      key + ' must be a 3-element array, got ' + _shape(json),
    );
  }
  final List<double> values = <double>[];
  for (int index = 0; index < 3; index += 1) {
    final Object? value = json[index];
    if (value is! num) {
      throw SceneFrameFormatException(
        key + '[' + index.toString() + '] must be numeric, got ' + _shape(value),
      );
    }
    values.add(value.toDouble());
  }
  return Vec3(values[0], values[1], values[2]);
}

List<SceneActorIdentity> _actors(Object? json) {
  if (json == null) {
    return const <SceneActorIdentity>[];
  }
  if (json is! List) {
    throw SceneFrameFormatException(
      'actors must be an array, got ' + _shape(json),
    );
  }
  final List<SceneActorIdentity> actors = <SceneActorIdentity>[];
  for (final Object? entry in json) {
    if (entry is! Map) {
      throw SceneFrameFormatException(
        'actor entry must be an object, got ' + _shape(entry),
      );
    }
    actors.add(SceneActorIdentity.fromJson(Map<String, Object?>.from(entry)));
  }
  return actors;
}

double _number(Object? json, String key, double fallback) {
  if (json == null) {
    return fallback;
  }
  if (json is num) {
    return json.toDouble();
  }
  throw SceneFrameFormatException(
    key + ' must be numeric, got ' + _shape(json),
  );
}

int _integer(Object? json, String key, int fallback) {
  if (json == null) {
    return fallback;
  }
  if (json is num) {
    return json.toInt();
  }
  throw SceneFrameFormatException(
    key + ' must be numeric, got ' + _shape(json),
  );
}

String _string(Object? json, String key, String fallback) {
  if (json == null) {
    return fallback;
  }
  if (json is String) {
    return json;
  }
  throw SceneFrameFormatException(
    key + ' must be a string, got ' + _shape(json),
  );
}

bool _boolean(Object? json, String key) {
  if (json == null) {
    return false;
  }
  if (json is bool) {
    return json;
  }
  throw SceneFrameFormatException(
    key + ' must be a boolean, got ' + _shape(json),
  );
}
