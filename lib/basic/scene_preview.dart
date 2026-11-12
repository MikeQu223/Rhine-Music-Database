import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

/// BASIC-89 lane C — Siren 3D preview (real GLB inside an Android WebView).
///
/// The public surface is frozen by the cross-lane contract v1:
///   * [basicSceneViewType] == 'rhine/basic_scene'
///   * [ScenePreview] constructor: songId, albumId, initialYaw, onReady
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

/// MethodChannel shared with BasicSceneView.kt (contract v1).
const String basicSceneChannel = 'rhine.music.database/basic_scene';

/// The single virtual origin the preview WebView is allowed to load.
const String basicSceneOrigin = 'https://basic-preview.local';

/// Real, bundled GLB candidates (Assets/models/ is declared in pubspec.yaml).
const String basicSceneDefaultModel = 'Assets/models/archive-assembly.glb';
const String basicSceneCassetteModel = 'Assets/models/archive-cassette.glb';

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
  });

  final String songId;
  final String albumId;
  final String model;
  final double initialYaw;

  /// 0 = day palette, 1 = night palette (Qt theme blend).
  final double theme;

  static const List<String> allowedModels = <String>[
    basicSceneDefaultModel,
    basicSceneCassetteModel,
  ];

  Map<String, Object?> toMap() => <String, Object?>{
        'songId': songId,
        'albumId': albumId,
        'model': model,
        'initialYaw': initialYaw,
        'theme': theme,
      };

  /// Tolerant decoder for the platform-channel map (tests cover hostile input).
  factory BasicSceneCreationParams.fromMap(Map<Object?, Object?> map) {
    final requestedModel = _asString(map['model']);
    final model = allowedModels.contains(requestedModel)
        ? requestedModel!
        : basicSceneDefaultModel;
    final yaw = _asFiniteDouble(map['initialYaw']) ?? 0;
    final theme = (_asFiniteDouble(map['theme']) ?? 1).clamp(0.0, 1.0);
    return BasicSceneCreationParams(
      songId: _asString(map['songId']) ?? '',
      albumId: _asString(map['albumId']) ?? '',
      model: model,
      initialYaw: _wrapRadians(yaw),
      theme: theme.toDouble(),
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
    return _BasicSceneHost(
      params: BasicSceneCreationParams(
        songId: songId,
        albumId: albumId,
        model: effectiveModel,
        initialYaw: initialYaw,
        theme: effectiveTheme,
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
  bool _failureReported = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _verifyBundledModel();
  }

  /// Fail closed: if Flutter's asset manifest does not contain the requested
  /// GLB, never mount the WebView (the interceptor would 404 it anyway).
  Future<void> _verifyBundledModel() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final present = manifest.listAssets().contains(widget.params.model);
      if (!mounted) return;
      if (!present) {
        _fail('资源清单中缺少 ${widget.params.model}');
        return;
      }
      setState(() => _assetChecked = true);
    } catch (error) {
      if (!mounted) return;
      _fail('无法读取 Flutter 资源清单：$error');
    }
  }

  void _fail(String message) {
    setState(() {
      _assetChecked = true;
      _error = message;
    });
    _reportFailure();
  }

  void _reportFailure() {
    if (_failureReported) return;
    _failureReported = true;
    widget.onReady?.call(false);
  }

  void _onPlatformViewCreated(int id) {
    _viewId = id;
    BasicSceneBridge.attach(id, _handleEvent);
  }

  void _handleEvent(BasicSceneEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case BasicSceneEventKind.ready:
        if (_ready || _error != null) break;
        setState(() => _ready = true);
        widget.onReady?.call(true);
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
    final id = _viewId;
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
            if (_assetChecked && _error == null)
              AndroidView(
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

/// Per-viewId dispatcher for the single engine MethodChannel.
///
/// Native payloads always carry a viewId; listeners are keyed by it so several
/// previews can coexist without a global "current view".
class BasicSceneBridge {
  BasicSceneBridge._();

  static const MethodChannel channel = MethodChannel(basicSceneChannel);
  static final Map<int, void Function(BasicSceneEvent)> _listeners =
      <int, void Function(BasicSceneEvent)>{};
  static bool _handlerInstalled = false;

  static void attach(int viewId, void Function(BasicSceneEvent) listener) {
    _installHandler();
    _listeners[viewId] = listener;
  }

  static void detach(int viewId) {
    _listeners.remove(viewId);
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    channel.setMethodCallHandler((MethodCall call) async {
      final event = BasicSceneEvent.fromMethodCall(call);
      final viewId = event?.viewId;
      if (event == null || viewId == null) return null;
      _listeners[viewId]?.call(event);
      return null;
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
