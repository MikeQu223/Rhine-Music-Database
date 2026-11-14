import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

/// BASIC-89 lane C — Siren 3D preview (real GLB inside an Android WebView).
///
/// The public surface is frozen by the cross-lane contract v1, extended
/// additively by v2 (mode + the setScene push):
///   * [basicSceneViewType] == 'rhine/basic_scene'
///   * [ScenePreview] constructor: songId, albumId, initialYaw, model, theme,
///     mode, onReady
///
/// The widget mounts a PlatformView only on Android. Everywhere else it renders
/// an explicit "not available" panel; it never fakes a 3D scene with images or
/// CSS transforms.
///
/// The GLB is verified against Flutter's [AssetManifest] before the view is
/// created, then served to the WebView by the native request interceptor from
/// the same flutter_assets bundle (the only channel through which a WebView can
/// read packaged assets). No network, no file scheme, no CDN.
const String basicSceneViewType = 'rhine/basic_scene';

/// Base MethodChannel name shared with BasicSceneView.kt (contract v1).
///
/// Every mounted platform view uses its own suffix derived from its view id —
/// see [basicSceneChannelFor] — because the engine messenger keeps exactly one
/// handler per channel name.
const String basicSceneChannel = 'rhine.music.database/basic_scene';

/// The channel one platform view is addressed on: `<base>/<viewId>`.
///
/// A single shared channel cannot route between live previews: each
/// BasicSceneView would register its handler on the same name, the newest view
/// would replace every older one at the messenger, and an update addressed to a
/// still-live view could only be dropped by the receiver — reported to the
/// caller as success (reports/RUNTIME-MATERIAL-97-F1-IMMUTABLE-bed982f-review.json
/// F1-I2). The native side builds the same name from the id it was created with
/// (BasicSceneAssets.channelName), so a view id now selects the handler instead
/// of being filtered after the fact.
String basicSceneChannelFor(int viewId) => '$basicSceneChannel/$viewId';

/// The single virtual origin the preview WebView is allowed to load.
const String basicSceneOrigin = 'https://basic-preview.local';

/// Real, bundled GLB candidates (Assets/models/ is declared in pubspec.yaml).
const String basicSceneDefaultModel = 'Assets/models/archive-assembly.glb';
const String basicSceneCassetteModel = 'Assets/models/archive-cassette.glb';

/// Camera modes the preview can compose.
///
/// Qt spells them 'boot' | 'detail' | 'archive' (Qt/src/NativeScene.cpp:165-198)
/// and maps every non-detail string to m_targetDetail = 0
/// (Qt/src/NativeScene.cpp:188), so all three ride at detail 0 except 'detail'.
/// Boot is the fresh-launch phase (lib/basic/basic_models.dart:451), and Qt
/// zeroes the archive lens offset for it alone
/// (Qt/src/NativeSceneCamera.cpp:101), so a boot host must forward
/// [basicSceneBootMode] explicitly instead of relying on a default.
const String basicSceneArchiveMode = 'archive';
const String basicSceneDetailMode = 'detail';
const String basicSceneBootMode = 'boot';

bool _isSceneMode(String value) =>
    value == basicSceneArchiveMode ||
    value == basicSceneDetailMode ||
    value == basicSceneBootMode;

const Color _sceneBackground = Color(0xFF11181B);
const Color _sceneText = Color(0xFFE7E0D7);
const Color _sceneMuted = Color(0xFF98A2A6);
const Color _sceneWarning = Color(0xFFE3B15C);

/// True only where a real PlatformView implementation exists (lane C ships
/// Android only). Web and desktop deliberately fall through to a placeholder.
bool get basicScenePlatformSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Human readable platform label for the honest placeholder copy.
String basicScenePlatformLabel() =>
    kIsWeb ? 'Web' : defaultTargetPlatform.name;

/// Hard ceiling for [basicSceneReadyMetricsLine].
///
/// One log line, never a dump: logcat drops long lines, and a model string that
/// arrives from the page must not be able to grow the record.
const int basicSceneReadyMetricsMaxLength = 240;

/// Hard ceiling for the one-line update-failure log.
///
/// An update failure carries an exception string from the engine; it is bounded
/// the same way the ready metrics line is, and deduplicated, so a view that
/// fails every frame cannot flood logcat.
const int basicSceneUpdateFailureMaxLength = 240;

/// Injectable asset-manifest probe used by the host before it mounts a view.
///
/// Defaults to the real bundle ([defaultBasicSceneAvailableAssets]). The seam
/// exists because flutter_test ships no `AssetManifest.bin`: without it a widget
/// test could never get past the asset gate to the transport it needs to
/// exercise.
@visibleForTesting
Future<Set<String>> Function() basicSceneAvailableAssets =
    defaultBasicSceneAvailableAssets;

/// Lists every asset key packaged in the running Flutter bundle.
Future<Set<String>> defaultBasicSceneAvailableAssets() async {
  final AssetManifest manifest =
      await AssetManifest.loadFromAssetBundle(rootBundle);
  return manifest.listAssets().toSet();
}

/// The single diagnostic line the port emits when the scene reports ready.
///
/// The ready payload is the only place Flutter can see whether three.js got the
/// whole GLB (node count, triangles, WebGL2, the composed fov and how many parts
/// survived the Qt cull). It carries counts and never the part names or the
/// bounds, and it is clipped to [maxLength] so the record stays bounded no
/// matter what the page sends.
String basicSceneReadyMetricsLine(
  BasicSceneEvent event, {
  int maxLength = basicSceneReadyMetricsMaxLength,
}) {
  final String model = event.model ?? '';
  final int slash = model.lastIndexOf('/');
  final String shortModel =
      slash >= 0 && slash + 1 < model.length ? model.substring(slash + 1) : model;
  final String line = 'basic scene ready view=${event.viewId ?? -1} '
      'model=$shortModel meshes=${event.meshCount ?? 0} '
      'triangles=${event.triangleCount ?? 0} '
      'fov=${(event.fovDeg ?? 0).toStringAsFixed(3)} '
      'parts=${event.partCount ?? 0} webgl2=${event.webgl2 ?? false}';
  return line.length <= maxLength ? line : line.substring(0, maxLength);
}

/// Event names emitted by BasicSceneView.kt over [basicSceneChannel].
enum BasicSceneEventKind { ready, selection, yaw, error }

/// Parsed, immutable view of one native event.
///
/// Parsing is deliberately strict: unknown methods, a missing/non-int viewId,
/// a non-finite yaw or a blank selection name are dropped instead of being
/// forwarded into the widget tree.
@immutable
class BasicSceneEvent {
  const BasicSceneEvent({
    required this.kind,
    this.viewId,
    this.model,
    this.partName,
    this.yawRadians,
    this.message,
    this.meshCount,
    this.triangleCount,
    this.webgl2,
    this.fovDeg,
    this.partCount,
  });

  final BasicSceneEventKind kind;
  final int? viewId;
  final String? model;
  final String? partName;
  final double? yawRadians;
  final String? message;
  final int? meshCount;
  final int? triangleCount;
  final bool? webgl2;

  /// Vertical field of view the page composed, in degrees (ready payload).
  final double? fovDeg;

  /// How many distinct parts the page kept; the names themselves stay in the
  /// WebView, because a log must stay bounded.
  final int? partCount;

  /// Parses the MethodChannel call emitted by BasicSceneView.kt.
  static BasicSceneEvent? fromMethodCall(MethodCall call) =>
      fromPlatformMessage(call.method, call.arguments);

  /// Pure parser used by tests and [fromMethodCall].
  static BasicSceneEvent? fromPlatformMessage(String method, Object? arguments) {
    if (arguments is! Map) return null;
    final viewId = arguments['viewId'];
    if (viewId is! int) return null;

    switch (method) {
      case 'ready':
        return BasicSceneEvent(
          kind: BasicSceneEventKind.ready,
          viewId: viewId,
          model: _asString(arguments['model']),
          meshCount: _asInt(arguments['meshes']),
          triangleCount: _asInt(arguments['triangles']),
          yawRadians: _asFiniteDouble(arguments['yaw']),
          webgl2: arguments['webgl2'] is bool
              ? arguments['webgl2'] as bool
              : null,
          fovDeg: _asFiniteDouble(arguments['fovDeg']),
          partCount: arguments['parts'] is List
              ? (arguments['parts'] as List).length
              : null,
        );
      case 'selection':
        final name = _asString(arguments['partName'])?.trim();
        if (name == null || name.isEmpty) return null;
        return BasicSceneEvent(
          kind: BasicSceneEventKind.selection,
          viewId: viewId,
          partName: name,
        );
      case 'yaw':
        final radians = _asFiniteDouble(arguments['radians']);
        if (radians == null) return null;
        return BasicSceneEvent(
          kind: BasicSceneEventKind.yaw,
          viewId: viewId,
          yawRadians: radians,
        );
      case 'error':
        return BasicSceneEvent(
          kind: BasicSceneEventKind.error,
          viewId: viewId,
          message: _asString(arguments['message']) ?? 'unknown scene error',
        );
      default:
        return null;
    }
  }
}

/// Immutable creation params handed to the PlatformView factory.
///
/// [toMap] is the StandardMessageCodec payload. songId/albumId are carried for
/// the embedding page (selection wiring) even though the native view currently
/// only consumes model/initialYaw/theme.
@immutable
class BasicSceneCreationParams {
  const BasicSceneCreationParams({
    required this.songId,
    required this.albumId,
    this.model = basicSceneDefaultModel,
    this.initialYaw = 0,
    this.theme = 1,
    this.mode = basicSceneArchiveMode,
  });

  final String songId;
  final String albumId;
  final String model;
  final double initialYaw;

  /// 0 = day palette, 1 = night palette (Qt theme blend).
  final double theme;

  /// [basicSceneArchiveMode] = library framing (Qt detail 0),
  /// [basicSceneBootMode] = fresh-launch framing (Qt detail 0 with the archive
  /// lens offset held at zero), or [basicSceneDetailMode] = song-page framing
  /// (Qt detail 1). An unknown or malformed value decodes to
  /// [basicSceneArchiveMode]; it is never guessed to be boot.
  final String mode;

  static const List<String> allowedModels = <String>[
    basicSceneDefaultModel,
    basicSceneCassetteModel,
  ];

  static const List<String> allowedModes = <String>[
    basicSceneArchiveMode,
    basicSceneDetailMode,
    basicSceneBootMode,
  ];

  Map<String, Object?> toMap() => <String, Object?>{
        'songId': songId,
        'albumId': albumId,
        'model': model,
        'initialYaw': initialYaw,
        'theme': theme,
        'mode': mode,
      };

  /// Tolerant decoder for the platform-channel map (tests cover hostile input).
  factory BasicSceneCreationParams.fromMap(Map<Object?, Object?> map) {
    final requestedModel = _asString(map['model']);
    final model = allowedModels.contains(requestedModel)
        ? requestedModel!
        : basicSceneDefaultModel;
    final yaw = _asFiniteDouble(map['initialYaw']) ?? 0;
    final theme = (_asFiniteDouble(map['theme']) ?? 1).clamp(0.0, 1.0);
    final requestedMode = _asString(map['mode']);
    final mode = requestedMode != null && _isSceneMode(requestedMode)
        ? requestedMode
        : basicSceneArchiveMode;
    return BasicSceneCreationParams(
      songId: _asString(map['songId']) ?? '',
      albumId: _asString(map['albumId']) ?? '',
      model: model,
      initialYaw: _wrapRadians(yaw),
      theme: theme.toDouble(),
      mode: mode,
    );
  }
}

/// Pure-Dart mirror of the Kotlin request policy in BasicSceneView.kt.
///
/// The native implementation is authoritative; this mirror exists so the
/// allow-list / MIME rules can be unit tested without an emulator.
@immutable
class BasicSceneAssetPolicy {
  const BasicSceneAssetPolicy._();

  static const String host = 'basic-preview.local';
  static const String assetRoot = 'web/basic_preview';
  static const Set<String> allowedModelAssets = <String>{
    basicSceneDefaultModel,
    basicSceneCassetteModel,
  };

  static final RegExp _segment = RegExp(r'^[A-Za-z0-9._-]+$');

  /// True only for https://basic-preview.local with clean, non-traversing path
  /// segments. It does not imply the path is serveable (see [assetKeyFor]).
  static bool isAllowedUri(Uri uri) {
    if (uri.scheme != 'https') return false;
    if (uri.host.toLowerCase() != host) return false;
    if (uri.hasPort && uri.port != 443) return false;
    if (uri.userInfo.isNotEmpty) return false;
    final path = uri.path;
    if (path.isEmpty || path.length > 512) return false;
    if (path == '/' || path == '/index.html') return true;
    if (!path.startsWith('/')) return false;
    if (path.contains('//')) return false;
    for (final segment in path.substring(1).split('/')) {
      if (segment.isEmpty || segment == '.' || segment == '..') return false;
      if (!_segment.hasMatch(segment)) return false;
    }
    return true;
  }

  /// Maps an allowed request URI to a Flutter asset key, or null when denied.
  static String? assetKeyFor(Uri uri) {
    if (!isAllowedUri(uri)) return null;
    final path = uri.path;
    if (path == '/') return '$assetRoot/index.html';
    if (path.startsWith('/Assets/models/')) {
      final key = path.substring(1);
      return allowedModelAssets.contains(key) ? key : null;
    }
    if (path == '/index.html' ||
        path == '/renderer.js' ||
        path.startsWith('/vendor/three/')) {
      return '$assetRoot$path';
    }
    return null;
  }

  /// Explicit MIME map (the native side must answer with these exact types).
  static String? mimeTypeFor(String assetKey) {
    final dot = assetKey.lastIndexOf('.');
    if (dot < 0 || dot == assetKey.length - 1) return null;
    final extension = assetKey.substring(dot + 1).toLowerCase();
    switch (extension) {
      case 'html':
        return 'text/html';
      case 'js':
      case 'mjs':
        return 'text/javascript';
      case 'css':
        return 'text/css';
      case 'json':
        return 'application/json';
      case 'glb':
        return 'model/gltf-binary';
      case 'gltf':
        return 'model/gltf+json';
      case 'wasm':
        return 'application/wasm';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'svg':
        return 'image/svg+xml';
      case 'txt':
      case 'md':
        return 'text/plain';
      default:
        return null;
    }
  }
}

/// Siren 3D scene preview.
///
/// On Android this is a real WebView PlatformView showing a real bundled GLB
/// via three.js. On any other platform it renders an explicit unavailable panel.
class ScenePreview extends StatelessWidget {
  const ScenePreview({
    super.key,
    required this.songId,
    required this.albumId,
    this.initialYaw = 0,
    this.model = basicSceneDefaultModel,
    this.theme = 1,
    this.mode = basicSceneArchiveMode,
    this.onReady,
  });

  final String songId;
  final String albumId;
  final double initialYaw;

  /// Bundled GLB asset key. Only [BasicSceneCreationParams.allowedModels] are
  /// served; any other value falls back to [basicSceneDefaultModel].
  final String model;

  /// 0 = day palette, 1 = night palette (Qt theme blend).
  final double theme;

  /// [basicSceneArchiveMode] (library framing), [basicSceneBootMode]
  /// (fresh-launch framing, which a boot host opts into because the HUD mounts
  /// at `BasicPhase.boot`), or [basicSceneDetailMode] (song-page framing).
  ///
  /// The default stays [basicSceneArchiveMode] so every existing caller keeps
  /// its framing; a boot host opts in by passing [basicSceneBootMode]. Changing
  /// either this or [theme] after mount pushes a live update instead of
  /// recreating the view.
  final String mode;

  /// Called once with true after the first rendered frame, or once with false
  /// when the asset/bridge/scene fails. Never called for the placeholder path.
  final ValueChanged<bool>? onReady;

  @override
  Widget build(BuildContext context) {
    if (!basicScenePlatformSupported) {
      return _UnsupportedScenePreview(platformLabel: basicScenePlatformLabel());
    }
    final effectiveModel =
        BasicSceneCreationParams.allowedModels.contains(model)
            ? model
            : basicSceneDefaultModel;
    final effectiveTheme =
        theme.isFinite ? theme.clamp(0.0, 1.0).toDouble() : 1.0;
    final effectiveMode = _isSceneMode(mode) ? mode : basicSceneArchiveMode;
    return _BasicSceneHost(
      params: BasicSceneCreationParams(
        songId: songId,
        albumId: albumId,
        model: effectiveModel,
        initialYaw: initialYaw,
        theme: effectiveTheme,
        mode: effectiveMode,
      ),
      onReady: onReady,
    );
  }
}

class _BasicSceneHost extends StatefulWidget {
  const _BasicSceneHost({required this.params, this.onReady});

  final BasicSceneCreationParams params;
  final ValueChanged<bool>? onReady;

  @override
  State<_BasicSceneHost> createState() => _BasicSceneHostState();
}

class _BasicSceneHostState extends State<_BasicSceneHost> {
  int? _viewId;
  bool _assetChecked = false;
  bool _ready = false;

  /// Guards the single ready-metrics log line per view (see
  /// [basicSceneReadyMetricsLine]); a rebuilt WebView logs again from scratch.
  bool _readyLogged = false;
  bool _failureReported = false;

  /// True when the asset gate itself failed, so the WebView must not mount.
  ///
  /// Kept apart from [_error]: a runtime error from a created view is only a
  /// banner, and gating the AndroidView on [_error] made one error permanent —
  /// the view was unmounted and could never report ready again
  /// (reports/RUNTIME-MATERIAL-97-F1-IMMUTABLE-bed982f-review.json F1-I4).
  bool _assetMissing = false;
  String? _error;

  /// Incremented for every push and every new platform view, so an answer that
  /// arrives after the fact can tell it is stale.
  int _pushGeneration = 0;

  /// Last failure line already logged, for de-duplication.
  String? _lastPushFailure;

  @override
  void initState() {
    super.initState();
    _verifyBundledModel();
  }

  /// Fail closed: if Flutter's asset manifest does not contain the requested
  /// GLB, never mount the WebView (the interceptor would 404 it anyway).
  Future<void> _verifyBundledModel() async {
    try {
      final Set<String> present = await basicSceneAvailableAssets();
      if (!mounted) return;
      if (!present.contains(widget.params.model)) {
        _fail('资源清单中缺少 ${widget.params.model}', blocked: true);
        return;
      }
      setState(() => _assetChecked = true);
    } catch (error) {
      if (!mounted) return;
      _fail('无法读取 Flutter 资源清单：$error', blocked: true);
    }
  }

  /// Shows [message]; [blocked] additionally keeps the platform view unmounted.
  ///
  /// Only the asset gate passes [blocked]. A view error is recoverable: the
  /// WebView stays alive, so a later ready from the same view clears the banner.
  void _fail(String message, {bool blocked = false}) {
    setState(() {
      _assetChecked = true;
      if (blocked) _assetMissing = true;
      _error = message;
    });
    _reportFailure();
  }

  /// Forgets everything that belongs to one platform view lifecycle.
  ///
  /// A recreated view (new GLB key) is a fresh page: readiness, the error
  /// banner and the failure report all describe the view that is being torn
  /// down, and carrying them over made a replacement look dead on arrival.
  void _resetViewLifecycle() {
    _ready = false;
    _readyLogged = false;
    _failureReported = false;
    _error = null;
    _pushGeneration++;
  }

  void _reportFailure() {
    if (_failureReported) return;
    _failureReported = true;
    widget.onReady?.call(false);
  }

  void _onPlatformViewCreated(int id) {
    final int? previous = _viewId;
    if (previous != null && previous != id) {
      // The old view is gone (its key changed): detaching before attaching is
      // what keeps two live views from owning one handler slot, and it also
      // stops this widget from ever hearing the torn-down view again
      // (reports/RUNTIME-MATERIAL-97-F1-IMMUTABLE-bed982f-review.json F1-I3).
      BasicSceneBridge.detach(previous);
    }
    _viewId = id;
    // No setState here: this callback can fire while the platform view is still
    // being created, and the previous frame simply stays until the new one
    // arrives. The reset itself must happen for every view, not only for the
    // keyed model swap, so a same-model engine recreation cannot inherit the
    // previous banner or a spent failure report (R2-S2). A banner cannot
    // outlive it either: creation is always preceded by a rebuild (the keyed
    // model swap resets in didUpdateWidget), and a rebuild applies this reset,
    // so clearing state here never has to schedule a repaint of its own (R2-S6).
    _resetViewLifecycle();
    BasicSceneBridge.attach(id, _handleEvent);
  }

  /// creationParams are handed to the platform view exactly once
  /// (platform_view.dart reads them when the view is created), so anything that
  /// changes after mount has to be pushed over the channel. Keeping the push in
  /// one place means the URL query, the initial push and later updates can never
  /// disagree about which fields travel.
  void _pushScene(Map<String, Object?> update) {
    final int? id = _viewId;
    if (id == null || update.isEmpty) return;
    final int generation = ++_pushGeneration;
    unawaited(_applyScene(id, generation, update));
  }

  /// Applies one update and attributes its failure to the view it was for.
  ///
  /// The answer is asynchronous, so by the time it lands the preview may have
  /// moved to another platform view. Only a failure of the *current* view and
  /// the *current* generation is reported, exactly once per distinct line; a
  /// stale one is dropped silently, because the view it describes no longer
  /// exists to be fixed
  /// (reports/RUNTIME-MATERIAL-97-F1-IMMUTABLE-bed982f-review.json F1-I5).
  Future<void> _applyScene(
    int viewId,
    int generation,
    Map<String, Object?> update,
  ) async {
    try {
      await BasicSceneBridge.applyScene(viewId, update);
    } catch (error) {
      if (!mounted) return;
      if (_viewId != viewId || _pushGeneration != generation) return;
      // Dedupe on the failure itself, not on the line: the line carries the
      // generation, which changes on every push, so a generation-keyed guard
      // could never suppress a repeat (R2-S3).
      final String signature = 'view=$viewId $error';
      if (signature == _lastPushFailure) return;
      _lastPushFailure = signature;
      final String line = 'basic scene update failed view=$viewId '
          'generation=$generation $error';
      final String bounded = line.length <= basicSceneUpdateFailureMaxLength
          ? line
          : line.substring(0, basicSceneUpdateFailureMaxLength);
      debugPrint(bounded);
    }
  }

  @override
  void didUpdateWidget(_BasicSceneHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.params.model != widget.params.model) {
      // A different GLB means a different platform view (the AndroidView key is
      // the model), so the old lifecycle is over. Nothing is pushed here: the
      // replacement cannot accept an update before it reports ready.
      _resetViewLifecycle();
      // The asset gate answers for one model. Re-run it, or a host that failed
      // closed for the old GLB would keep the replacement unmounted forever,
      // while a newly absent model would mount and 404 instead of failing
      // closed (R2-S1).
      _assetChecked = false;
      _assetMissing = false;
      unawaited(_verifyBundledModel());
      return;
    }
    if (!_ready) return;
    final update = <String, Object?>{};
    if ((oldWidget.params.theme - widget.params.theme).abs() > 1e-9) {
      update['theme'] = widget.params.theme;
    }
    if (oldWidget.params.mode != widget.params.mode) {
      update['mode'] = widget.params.mode;
    }
    _pushScene(update);
  }

  void _handleEvent(BasicSceneEvent event) {
    if (!mounted) return;
    final int? current = _viewId;
    if (current == null || event.viewId != current) {
      // Per-view channels already address one view, but a message can outlive
      // the handler that was attached when it was queued. Anything not from the
      // current view is stale by definition: a torn-down view's ready must not
      // mark the replacement ready, and its error must not poison it.
      return;
    }
    switch (event.kind) {
      case BasicSceneEventKind.ready:
        if (_ready) break;
        setState(() {
          _ready = true;
          // A view that reports ready has recovered; an earlier error banner
          // described a page this one replaced. The asset gate is untouched: it
          // is structural, and a blocked host has no view to report ready.
          _error = null;
        });
        // Re-assert the Dart-side state once the scene can accept it: the URL
        // only carries the creation values, so ?detail= stays a creation
        // default and every later mode change has to arrive through setScene.
        _pushScene(<String, Object?>{
          'theme': widget.params.theme,
          'mode': widget.params.mode,
        });
        widget.onReady?.call(true);
        // F7: exactly one bounded line per view. The ready payload is the only
        // evidence of what three.js actually loaded, and the device session that
        // motivated this atom had no way to tell a partial GLB from a lighting
        // bug; the names and bounds stay in the WebView. Logged last so the
        // state re-assert above stays the first thing the ready case does.
        if (!_readyLogged) {
          _readyLogged = true;
          debugPrint(basicSceneReadyMetricsLine(event));
        }
        break;
      case BasicSceneEventKind.error:
        _fail(event.message ?? '3D 场景加载失败');
        break;
      case BasicSceneEventKind.selection:
      case BasicSceneEventKind.yaw:
        break;
    }
  }

  @override
  void dispose() {
    final int? id = _viewId;
    // Bumping the generation and clearing the id marks every in-flight push as
    // stale, so a failure that lands after dispose is not reported for a view
    // this widget no longer owns.
    _pushGeneration++;
    _viewId = null;
    if (id != null) BasicSceneBridge.detach(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Siren 3D 场景预览',
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ColoredBox(color: _sceneBackground),
            // Only the asset gate may keep the view unmounted: a runtime error
            // is a banner over a live view, never a tombstone.
            if (_assetChecked && !_assetMissing)
              AndroidView(
                // A different GLB cannot be swapped inside one WebView, so the
                // key recreates the platform view instead of lying about it.
                key: ValueKey<String>(widget.params.model),
                viewType: basicSceneViewType,
                creationParams: widget.params.toMap(),
                creationParamsCodec: const StandardMessageCodec(),
                onPlatformViewCreated: _onPlatformViewCreated,
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
              ),
            if (!_ready || _error != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: _StatusBadge(
                      child: _error != null
                          ? _ErrorStatus(message: _error!)
                          : const _LoadingStatus(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LoadingStatus extends StatelessWidget {
  const _LoadingStatus();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: const <Widget>[
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: _sceneMuted),
        ),
        SizedBox(width: 10),
        Text(
          '正在加载 3D 场景…',
          style: TextStyle(fontSize: 12.5, color: _sceneMuted),
        ),
      ],
    );
  }
}

class _ErrorStatus extends StatelessWidget {
  const _ErrorStatus({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.warning_amber_rounded, size: 18, color: _sceneWarning),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '3D 场景不可用\n$message',
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: _sceneText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD911181B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x33E7E0D7)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: child,
      ),
    );
  }
}

class _UnsupportedScenePreview extends StatelessWidget {
  const _UnsupportedScenePreview({required this.platformLabel});

  final String platformLabel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _sceneBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.view_in_ar_outlined,
                size: 30,
                color: _sceneMuted,
              ),
              const SizedBox(height: 10),
              const Text(
                '3D 场景预览仅在 Android 可用',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _sceneText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '当前平台：$platformLabel。这里不渲染模型、截图或旋转动画；'
                'Android 上通过 WebView 显示真实 GLB。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: _sceneMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-view dispatcher for the per-view engine channels.
///
/// One platform view owns one channel ([basicSceneChannelFor]), so a view id
/// selects the handler instead of being filtered after delivery: two live
/// previews cannot replace each other's handler, and a disposed view cannot
/// take the newest one down with it
/// (reports/RUNTIME-MATERIAL-97-F1-IMMUTABLE-bed982f-review.json F1-I2).
class BasicSceneBridge {
  BasicSceneBridge._();

  static final Map<int, MethodChannel> _channels = <int, MethodChannel>{};
  static final Map<int, void Function(BasicSceneEvent)> _listeners =
      <int, void Function(BasicSceneEvent)>{};

  /// The channel one view id is addressed on.
  @visibleForTesting
  static MethodChannel channelFor(int viewId) => _channels.putIfAbsent(
        viewId,
        () => MethodChannel(basicSceneChannelFor(viewId)),
      );

  static void attach(int viewId, void Function(BasicSceneEvent) listener) {
    _listeners[viewId] = listener;
    channelFor(viewId).setMethodCallHandler((MethodCall call) async {
      final BasicSceneEvent? event = BasicSceneEvent.fromMethodCall(call);
      // A handler outlives the listener it was installed for, so the id and the
      // listener are both re-checked at delivery time.
      if (event == null || event.viewId != viewId) return null;
      _listeners[viewId]?.call(event);
      return null;
    });
  }

  /// Releases one view: its listener first, then the channel handler, so an
  /// event already in flight finds no listener instead of the next view's.
  static void detach(int viewId) {
    _listeners.remove(viewId);
    _channels.remove(viewId)?.setMethodCallHandler(null);
  }

  /// Releases every view. Only tests need this; production detaches the view it
  /// owns.
  @visibleForTesting
  static void detachAll() {
    for (final int viewId in _channels.keys.toList(growable: false)) {
      detach(viewId);
    }
    _listeners.clear();
  }

  /// Pushes a live scene update to one mounted preview.
  ///
  /// The payload still carries the target viewId (BasicSceneView.onMethodCall
  /// rejects a foreign one with `wrong_view`), and the channel is already the
  /// addressed view's. Failures are not swallowed here: the caller owns the
  /// generation that started the push, so it is the only place that can tell a
  /// current failure from a stale one.
  static Future<void> applyScene(
    int viewId,
    Map<String, Object?> update,
  ) {
    return channelFor(viewId).invokeMethod<void>('setScene', <String, Object?>{
      'viewId': viewId,
      ...update,
    });
  }
}

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) =>
    value is num && value.isFinite ? value.toInt() : null;

double? _asFiniteDouble(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

double _wrapRadians(double value) {
  if (!value.isFinite) return 0;
  return math.atan2(math.sin(value), math.cos(value));
}
