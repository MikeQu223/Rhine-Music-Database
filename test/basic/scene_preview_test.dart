// BASIC-89 lane C — pure Dart tests for the 3D preview boundary.
//
// Contract under test: lib/basic/scene_preview.dart (owner C), the Kotlin host
// BasicSceneView.kt / BasicSceneViewFactory.kt, and the offline web assets.
//
// These tests are WRITTEN ONLY. This worktree forbids flutter test / pub get /
// gradle, so RED and GREEN are both unexecuted here. Planned entry point:
//   flutter test test/basic/scene_preview_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/scene_preview.dart';

/// Removes Kotlin line and block comments (same convention as the app contract
/// test, so a comment that explains a forbidden call cannot satisfy an assert).
String _stripKotlinComments(String text) {
  final String noBlocks = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlocks.replaceAll(RegExp(r'//[^\n]*'), '');
}

void main() {
  group('BasicSceneAssetPolicy.isAllowedUri', () {
    test('accepts only the virtual origin and clean paths', () {
      for (final String raw in <String>[
        'https://basic-preview.local/',
        'https://basic-preview.local/index.html',
        'https://basic-preview.local/renderer.js',
        'https://basic-preview.local/vendor/three/build/three.module.js',
        'https://basic-preview.local/vendor/three/examples/jsm/loaders/GLTFLoader.js',
        'https://basic-preview.local/Assets/models/archive-assembly.glb',
        'https://basic-preview.local/Assets/models/archive-cassette.glb',
        'https://basic-preview.local/index.html?model=Assets%2Fmodels%2Farchive-assembly.glb&yaw=0.1',
      ]) {
        expect(
          BasicSceneAssetPolicy.isAllowedUri(Uri.parse(raw)),
          isTrue,
          reason: raw,
        );
      }
    });

    test('rejects other schemes, hosts, ports, userinfo and traversal', () {
      for (final String raw in <String>[
        'http://basic-preview.local/renderer.js',
        'https://evil.local/renderer.js',
        'https://basic-preview.local.evil.local/renderer.js',
        'file:///android_asset/web/basic_preview/index.html',
        'javascript:alert(1)',
        'https://user:pass@basic-preview.local/renderer.js',
        'https://basic-preview.local:8443/renderer.js',
        'https://basic-preview.local/vendor/../secret.js',
        'https://basic-preview.local//renderer.js',
        'https://basic-preview.local/%2e%2e/secret.js',
        'https://basic-preview.local/',
      ]) {
        if (raw == 'https://basic-preview.local/') continue;
        expect(
          BasicSceneAssetPolicy.isAllowedUri(Uri.parse(raw)),
          isFalse,
          reason: raw,
        );
      }
    });
  });

  group('BasicSceneAssetPolicy.assetKeyFor', () {
    test('maps the four served prefixes to flutter asset keys', () {
      expect(
        BasicSceneAssetPolicy.assetKeyFor(
          Uri.parse('https://basic-preview.local/'),
        ),
        'web/basic_preview/index.html',
      );
      expect(
        BasicSceneAssetPolicy.assetKeyFor(
          Uri.parse('https://basic-preview.local/renderer.js'),
        ),
        'web/basic_preview/renderer.js',
      );
      expect(
        BasicSceneAssetPolicy.assetKeyFor(
          Uri.parse('https://basic-preview.local/vendor/three/build/three.module.js'),
        ),
        'web/basic_preview/vendor/three/build/three.module.js',
      );
      expect(
        BasicSceneAssetPolicy.assetKeyFor(
          Uri.parse('https://basic-preview.local/Assets/models/archive-assembly.glb'),
        ),
        'Assets/models/archive-assembly.glb',
      );
      expect(
        BasicSceneAssetPolicy.assetKeyFor(
          Uri.parse('https://basic-preview.local/Assets/models/archive-cassette.glb'),
        ),
        'Assets/models/archive-cassette.glb',
      );
    });

    test('refuses anything outside the allow-list', () {
      for (final String raw in <String>[
        'https://basic-preview.local/Assets/models/unknown.glb',
        'https://basic-preview.local/assets/models/archive-assembly.glb',
        'https://basic-preview.local/Assets/models/../pubspec.yaml',
        'https://basic-preview.local/pubspec.yaml',
        'https://basic-preview.local/vendor/three/../../secret.js',
        'https://basic-preview.local/index.html/extra',
      ]) {
        expect(
          BasicSceneAssetPolicy.assetKeyFor(Uri.parse(raw)),
          isNull,
          reason: raw,
        );
      }
    });
  });

  group('BasicSceneAssetPolicy.mimeTypeFor', () {
    test('uses explicit types, never sniffing', () {
      const Map<String, String> expected = <String, String>{
        'a.html': 'text/html',
        'a.js': 'text/javascript',
        'a.mjs': 'text/javascript',
        'a.css': 'text/css',
        'a.json': 'application/json',
        'a.glb': 'model/gltf-binary',
        'a.gltf': 'model/gltf+json',
        'a.wasm': 'application/wasm',
        'a.png': 'image/png',
        'a.jpg': 'image/jpeg',
        'a.jpeg': 'image/jpeg',
        'a.svg': 'image/svg+xml',
        'a.txt': 'text/plain',
        'a.md': 'text/plain',
        'A.HTML': 'text/html',
      };
      expected.forEach((String key, String mime) {
        expect(BasicSceneAssetPolicy.mimeTypeFor(key), mime, reason: key);
      });
      expect(BasicSceneAssetPolicy.mimeTypeFor('no-extension'), isNull);
      expect(BasicSceneAssetPolicy.mimeTypeFor('a.'), isNull);
      expect(BasicSceneAssetPolicy.mimeTypeFor('a.exe'), isNull);
    });
  });

  group('BasicSceneCreationParams', () {
    test('round-trips a valid map', () {
      const BasicSceneCreationParams params = BasicSceneCreationParams(
        songId: 'song-1',
        albumId: 'album-1',
        model: basicSceneCassetteModel,
        initialYaw: 0.5,
        theme: 0.25,
      );
      final BasicSceneCreationParams decoded =
          BasicSceneCreationParams.fromMap(params.toMap());
      expect(decoded.songId, 'song-1');
      expect(decoded.albumId, 'album-1');
      expect(decoded.model, basicSceneCassetteModel);
      expect(decoded.initialYaw, closeTo(0.5, 1e-9));
      expect(decoded.theme, closeTo(0.25, 1e-9));
    });

    test('falls back, wraps yaw and clamps theme', () {
      final BasicSceneCreationParams decoded =
          BasicSceneCreationParams.fromMap(<Object?, Object?>{
        'songId': 42,
        'albumId': null,
        'model': 'Assets/models/evil.glb',
        'initialYaw': 3 * math.pi,
        'theme': 4,
      });
      expect(decoded.songId, '');
      expect(decoded.albumId, '');
      expect(decoded.model, basicSceneDefaultModel);
      expect(decoded.initialYaw, closeTo(math.pi, 1e-9));
      expect(decoded.theme, 1.0);

      final BasicSceneCreationParams low =
          BasicSceneCreationParams.fromMap(<Object?, Object?>{
        'initialYaw': double.nan,
        'theme': -2,
      });
      expect(low.initialYaw, 0);
      expect(low.theme, 0.0);
    });

    test('toMap carries exactly the platform keys', () {
      const BasicSceneCreationParams params = BasicSceneCreationParams(
        songId: 's',
        albumId: 'a',
      );
      expect(params.toMap().keys.toSet(), <String>{
        'songId',
        'albumId',
        'model',
        'initialYaw',
        'theme',
        'mode',
      });
      expect(params.toMap()['model'], basicSceneDefaultModel);
      expect(params.toMap()['initialYaw'], 0);
      expect(params.toMap()['theme'], 1);
      expect(params.toMap()['mode'], basicSceneArchiveMode);
    });

    test('decodes every Qt mode and falls back to the archive framing', () {
      for (final String spelling in BasicSceneCreationParams.allowedModes) {
        final BasicSceneCreationParams decoded =
            BasicSceneCreationParams.fromMap(<Object?, Object?>{'mode': spelling});
        expect(decoded.mode, spelling, reason: spelling);
      }
      expect(
        BasicSceneCreationParams.fromMap(<Object?, Object?>{'mode': 'boot'}).mode,
        basicSceneBootMode,
      );
      // Boot is opt-in. A malformed or absent value must never enable it, or
      // the unshifted boot framing would leak onto the archive page
      // (Qt/src/NativeSceneCamera.cpp:101 gates that shift on the mode).
      for (final Object? hostile in <Object?>[null, '', 'BOOT', 'boot ', 7, ' DETAIL ']) {
        final BasicSceneCreationParams decoded =
            BasicSceneCreationParams.fromMap(<Object?, Object?>{'mode': hostile});
        expect(decoded.mode, basicSceneArchiveMode, reason: '$hostile');
      }
      expect(BasicSceneCreationParams.allowedModes, <String>[
        basicSceneArchiveMode,
        basicSceneDetailMode,
        basicSceneBootMode,
      ]);
      expect(basicSceneBootMode, 'boot');
    });
  });

  group('BasicSceneEvent parser', () {
    test('parses a ready event with measured fields', () {
      final BasicSceneEvent? event = BasicSceneEvent.fromPlatformMessage(
        'ready',
        <Object?, Object?>{
          'viewId': 7,
          'model': basicSceneDefaultModel,
          'meshes': 12,
          'triangles': 3456,
          'yaw': 0.25,
          'webgl2': true,
        },
      );
      expect(event, isNotNull);
      expect(event!.kind, BasicSceneEventKind.ready);
      expect(event.viewId, 7);
      expect(event.model, basicSceneDefaultModel);
      expect(event.meshCount, 12);
      expect(event.triangleCount, 3456);
      expect(event.yawRadians, closeTo(0.25, 1e-9));
      expect(event.webgl2, isTrue);
    });

    test('drops events without an int viewId', () {
      expect(BasicSceneEvent.fromPlatformMessage('ready', <Object?, Object?>{}), isNull);
      expect(
        BasicSceneEvent.fromPlatformMessage('ready', <Object?, Object?>{'viewId': 1.5}),
        isNull,
      );
      expect(BasicSceneEvent.fromPlatformMessage('ready', null), isNull);
      expect(BasicSceneEvent.fromPlatformMessage('ready', 'nope'), isNull);
    });

    test('accepts selection only with a real non-blank part name', () {
      final BasicSceneEvent? selected = BasicSceneEvent.fromPlatformMessage(
        'selection',
        <Object?, Object?>{'viewId': 3, 'partName': '  Frosted_Polymer  '},
      );
      expect(selected?.kind, BasicSceneEventKind.selection);
      expect(selected?.partName, 'Frosted_Polymer');
      expect(
        BasicSceneEvent.fromPlatformMessage(
          'selection',
          <Object?, Object?>{'viewId': 3, 'partName': '   '},
        ),
        isNull,
      );
      expect(
        BasicSceneEvent.fromPlatformMessage(
          'selection',
          <Object?, Object?>{'viewId': 3},
        ),
        isNull,
      );
    });

    test('rejects non-finite yaw and defaults error text', () {
      expect(
        BasicSceneEvent.fromPlatformMessage(
          'yaw',
          <Object?, Object?>{'viewId': 1, 'radians': double.nan},
        ),
        isNull,
      );
      expect(
        BasicSceneEvent.fromPlatformMessage(
          'yaw',
          <Object?, Object?>{'viewId': 1, 'radians': double.infinity},
        ),
        isNull,
      );
      final BasicSceneEvent? error = BasicSceneEvent.fromPlatformMessage(
        'error',
        <Object?, Object?>{'viewId': 1},
      );
      expect(error?.message, 'unknown scene error');
      expect(
        BasicSceneEvent.fromPlatformMessage(
          'not-a-real-method',
          <Object?, Object?>{'viewId': 1},
        ),
        isNull,
      );
    });

    test('fromMethodCall delegates to the pure parser', () {
      final BasicSceneEvent? event = BasicSceneEvent.fromMethodCall(
        MethodCall('yaw', <Object?, Object?>{'viewId': 9, 'radians': -1.5}),
      );
      expect(event?.kind, BasicSceneEventKind.yaw);
      expect(event?.viewId, 9);
      expect(event?.yawRadians, closeTo(-1.5, 1e-9));
    });
  });

  group('ScenePreview frozen surface', () {
    test('keeps the contract parameters and default values', () {
      const ScenePreview preview = ScenePreview(songId: 's', albumId: 'a');
      expect(preview.songId, 's');
      expect(preview.albumId, 'a');
      expect(preview.initialYaw, 0);
      expect(preview.model, basicSceneDefaultModel);
      expect(preview.theme, 1);
      expect(preview.mode, basicSceneArchiveMode);
      expect(preview.onReady, isNull);
    });

    test('unsupported platforms are labelled honestly in the source', () {
      final String source =
          File('lib/basic/scene_preview.dart').readAsStringSync();
      expect(source.contains('3D 场景预览仅在 Android 可用'), isTrue);
      expect(source.contains('这里不渲染模型、截图或旋转动画'), isTrue);
    });
  });

  group('ScenePreview live transport (setScene)', () {
    final String source =
        File('lib/basic/scene_preview.dart').readAsStringSync();

    test('pushes updates instead of recreating the platform view', () {
      expect(
        source.contains('void didUpdateWidget(_BasicSceneHost oldWidget)'),
        isTrue,
      );
      // One channel per view id, so a push can only reach the view it names.
      expect(
        source.contains("channelFor(viewId).invokeMethod<void>('setScene'"),
        isTrue,
      );
      expect(source.contains('basicSceneChannelFor(viewId)'), isTrue);
      expect(source.contains("'viewId': viewId"), isTrue);
      expect(source.contains("update['theme'] = widget.params.theme;"), isTrue);
      expect(source.contains("update['mode'] = widget.params.mode;"), isTrue);
      // The model is the one field that cannot be pushed: a different GLB needs
      // a new WebView, and the widget key is what makes that honest.
      expect(source.contains('key: ValueKey<String>(widget.params.model)'), isTrue);
      expect(source.contains("update['model']"), isFalse);
    });

    test('re-asserts the Dart state once the scene is ready', () {
      // _blockAfter stops at the first brace-balanced close, which is the end of
      // the inner setState call, so the push that follows it would fall outside
      // the slice. The ready case ends at the last break that precedes the next
      // case label; the first break inside it is the 'if (_ready) break;'
      // early exit, which would cut the slice down to two lines (R2-M3).
      final int at = source.indexOf('case BasicSceneEventKind.ready:');
      expect(at, isNonNegative);
      final int nextCase = source.indexOf('case BasicSceneEventKind.error:', at);
      expect(nextCase, greaterThan(at));
      final int terminator = source.lastIndexOf('break;', nextCase);
      expect(terminator, greaterThan(at));
      final String ready = source.substring(at, terminator);
      expect(ready, contains("case BasicSceneEventKind.ready:"));
      expect(ready.contains('_pushScene(<String, Object?>{'), isTrue);
      expect(ready.contains("'theme': widget.params.theme"), isTrue);
      expect(ready.contains("'mode': widget.params.mode"), isTrue);
      // The re-assertion happens after readiness flips, not before it.
      expect(ready.indexOf('_pushScene('), greaterThan(ready.indexOf('setState(')));
    });

    test('a replaced view cannot inherit the old banner or failure report', () {
      // Every creation path is preceded by a rebuild that already applied the
      // reset, so clearing the banner needs no repaint of its own (R2-S6 — the
      // earlier deferred repaint was unreachable and was removed).
      final String created =
          _blockAfter(source, 'void _onPlatformViewCreated(int id) {');
      expect(created.contains('_resetViewLifecycle();'), isTrue);
      expect(
        created.indexOf('_resetViewLifecycle();'),
        lessThan(created.indexOf('BasicSceneBridge.attach(id, _handleEvent);')),
      );
      expect(created.contains('addPostFrameCallback'), isFalse,
          reason: 'the tree is being built here; a repaint must come from '
              'state that the rebuild already applies');

      final String reset = _blockAfter(source, 'void _resetViewLifecycle() {');
      for (final String cleared in <String>[
        '_ready = false;',
        '_readyLogged = false;',
        '_failureReported = false;',
        '_error = null;',
      ]) {
        expect(reset, contains(cleared));
      }
      expect(reset.contains('_assetChecked'), isFalse,
          reason: 'the asset gate is structural and survives a view lifecycle');
      expect(reset.contains('_assetMissing'), isFalse);

      // The keyed model swap is the path that carries a live banner into a
      // replacement, and it resets before re-running the gate.
      final String update = _blockAfter(source, 'void didUpdateWidget(');
      final int resetAt = update.indexOf('_resetViewLifecycle();');
      final int gateAt = update.indexOf('unawaited(_verifyBundledModel());');
      expect(resetAt, greaterThanOrEqualTo(0));
      expect(gateAt, greaterThan(resetAt));
    });

    test('boot is opt-in per mount and still pushes without remounting', () {
      const ScenePreview boot = ScenePreview(
        songId: 's',
        albumId: 'a',
        mode: basicSceneBootMode,
      );
      expect(boot.mode, basicSceneBootMode);
      // The default stays the archive framing so every existing caller keeps
      // the composition it already had.
      const ScenePreview legacy = ScenePreview(songId: 's', albumId: 'a');
      expect(legacy.mode, basicSceneArchiveMode);
      // A later phase change is a message, not a new platform view: the host
      // skips the push until the page reports ready, then the ready handler
      // re-asserts the current theme/mode exactly once (the latest values).
      expect(source.contains('if (!_ready) return;'), isTrue);
      expect(source.contains("update['mode'] = widget.params.mode;"), isTrue);
    });

    test('a failed push is attributed to the generation that sent it', () {
      // The bridge stopped swallowing: a silent catch is what made a torn-down
      // view look like an applied update (F1-I5). The host catches instead,
      // and only reports the failure if its view/generation is still current.
      final String applyScene =
          _blockAfter(source, 'static Future<void> applyScene(');
      expect(applyScene.contains('on PlatformException'), isFalse);
      expect(applyScene.contains('on MissingPluginException'), isFalse);

      final String push = _blockAfter(source, 'Future<void> _applyScene(');
      expect(push.contains('} catch (error) {'), isTrue);
      expect(
        push.contains(
          'if (_viewId != viewId || _pushGeneration != generation) return;',
        ),
        isTrue,
      );
      expect(push.contains('basic scene update failed view='), isTrue);
      // Repeated identical failures must not spam the log, and the key may not
      // embed the generation: that changes on every push, so it could never
      // match a previous line (R2-S3).
      expect(push.contains(r"final String signature = 'view=$viewId $error';"), isTrue);
      expect(push.contains('if (signature == _lastPushFailure) return;'), isTrue);
      expect(push.contains('if (bounded == _lastPushFailure) return;'), isFalse);
      expect(push.contains('debugPrint(bounded)'), isTrue);
      expect(source.contains('_pushGeneration++;'), isTrue);
    });
  });

  group('Android host source contract', () {
    final String factory = _stripKotlinComments(File(
      'android/app/src/main/kotlin/rhine/music/database/basic/BasicSceneViewFactory.kt',
    ).readAsStringSync());
    final String view = _stripKotlinComments(File(
      'android/app/src/main/kotlin/rhine/music/database/basic/BasicSceneView.kt',
    ).readAsStringSync());

    test('factory registers the frozen view type', () {
      expect(
        factory.contains('const val VIEW_TYPE = "rhine/basic_scene"'),
        isTrue,
      );
      expect(
        factory.contains('PlatformViewFactory(StandardMessageCodec.INSTANCE)'),
        isTrue,
      );
      expect(factory.contains('fun install(engine: FlutterEngine)'), isTrue);
      expect(factory.contains('registerViewFactory('), isTrue);
      expect(factory.contains('VIEW_TYPE,'), isTrue);
    });

    test('view pins the virtual origin, bridge and channel', () {
      expect(
        view.contains('const val ORIGIN = "https://basic-preview.local"'),
        isTrue,
      );
      expect(
        view.contains('const val CHANNEL = "rhine.music.database/basic_scene"'),
        isTrue,
      );
      expect(view.contains('const val BRIDGE_NAME = "RhineSceneBridge"'), isTrue);
      expect(view.contains('addJavascriptInterface'), isTrue);
      expect(view.contains('shouldInterceptRequest'), isTrue);
      expect(view.contains('shouldOverrideUrlLoading'), isTrue);
      expect(view.contains('raw.optString("partName"'), isTrue);
      expect(view.contains('raw.optInt("meshIndex"'), isTrue);
    });

    test('start URL and setScene carry the Qt mode and detail blend', () {
      expect(view.contains('fun startUrl('), isTrue);
      expect(view.contains(r'&detail=$detail'), isTrue);
      expect(view.contains('if (resolved == MODE_DETAIL) 1 else 0'), isTrue);
      // Boot and archive both ride at detail 0 (Qt/src/NativeSceneCamera.cpp:101
      // separates them by mode), so the initial URL has to carry the mode too.
      expect(view.contains(r'&mode=$resolved'), isTrue);
      expect(view.contains('"setScene" -> {'), isTrue);
      expect(view.contains('if (target != null && target != viewId)'), isTrue);
      expect(view.contains('window.__rhineBasicScene.setScene('), isTrue);
      expect(view.contains('private var mode: String ='), isTrue);
    });

    test('view closes file/content access and keeps explicit MIME types', () {
      for (final String rule in <String>[
        'settings.allowFileAccess = false',
        'settings.allowContentAccess = false',
        'settings.allowFileAccessFromFileURLs = false',
        'settings.allowUniversalAccessFromFileURLs = false',
        'settings.javaScriptEnabled = true',
        'settings.domStorageEnabled = true',
        '"js", "mjs" -> "text/javascript"',
        '"glb" -> "model/gltf-binary"',
        '"html" -> "text/html"',
        '"wasm" -> "application/wasm"',
      ]) {
        expect(view.contains(rule), isTrue, reason: rule);
      }
      expect(view.contains('file://'), isFalse);
    });
  });

  group('Offline web asset contract', () {
    final String index =
        File('web/basic_preview/index.html').readAsStringSync();
    final String renderer =
        File('web/basic_preview/renderer.js').readAsStringSync();

    test('index loads a local import map and a local module', () {
      expect(index.contains('type="importmap"'), isTrue);
      expect(
        index.contains(
          '"three":"./vendor/three/build/three.module.js"',
        ),
        isTrue,
      );
      expect(
        index.contains(
          '"three/addons/":"./vendor/three/examples/jsm/"',
        ),
        isTrue,
      );
      expect(index.contains('src="./renderer.js"'), isTrue);
      expect(index.contains('id="scene-canvas"'), isTrue);
    });

    test('bridge exposes one live setScene entry point', () {
      final String bridge = renderer.substring(
        renderer.indexOf('window.__rhineBasicScene = {'),
      );
      expect(bridge.contains('setScene: function (next)'), isTrue);
      // One resolver owns the three Qt spellings; the bridge itself only
      // adopts what the resolver accepted.
      expect(bridge.contains('resolveSceneMode(next.mode)'), isTrue);
      expect(bridge.contains("next.mode === 'boot'"), isFalse,
          reason: 'the bridge must not grow a second mode vocabulary');
      expect(bridge.contains('applyThemeColors();'), isTrue);
      expect(bridge.contains('applyView();'), isTrue);
      expect(bridge.contains('if (!next || typeof next !== \'object\') return;'),
          isTrue);
    });

    test('renderer uses the real loader, real GLBs and a measured ready event', () {
      expect(renderer.contains("from 'three/addons/loaders/GLTFLoader.js'"), isTrue);
      expect(renderer.contains('Assets/models/archive-assembly.glb'), isTrue);
      expect(renderer.contains('Assets/models/archive-cassette.glb'), isTrue);
      expect(renderer.contains("post('ready'"), isTrue);
      expect(renderer.contains('meshes: visibleMeshes'), isTrue);
      expect(renderer.contains('triangles: Math.round(triangles)'), isTrue);
      expect(renderer.contains('partName: mesh.userData.rhinePart'), isTrue);
      expect(renderer.contains('raycaster.intersectObject'), isTrue);
      expect(renderer.contains('window.__rhineBasicScene'), isTrue);
      expect(renderer.contains('RhineSceneBridge'), isTrue);
      expect(renderer.contains('unpkg'), isFalse);
      expect(renderer.contains('http://'), isFalse);
      expect(renderer.contains('https://'), isFalse);
    });

    test('MIT license and vendor provenance ship with the local copy', () {
      expect(
        File('web/basic_preview/vendor/three/LICENSE').readAsStringSync(),
        contains('MIT License'),
      );
      expect(
        File('web/basic_preview/vendor/three/VENDOR.md').readAsStringSync(),
        contains('three'),
      );
    });
  });

  // F7 — exactly one bounded ready-metrics line, and no other new logging.
  group('ready metrics log', () {
    test('the ready payload carries counts, not the part names', () {
      final BasicSceneEvent? event =
          BasicSceneEvent.fromPlatformMessage('ready', <String, Object?>{
        'viewId': 7,
        'model': 'Assets/models/archive-assembly.glb',
        'meshes': 10,
        'triangles': 123456,
        'webgl2': true,
        'fovDeg': 6.125,
        'parts': <String>['Frosted_Polymer', 'Ivory_Edges', 'Optical_Film'],
        'bounds': <String, Object?>{'min': 0},
      });
      expect(event, isNotNull);
      expect(event!.partCount, 3);
      expect(event.fovDeg, closeTo(6.125, 1e-9));
      expect(event.meshCount, 10);
    });

    test('a malformed payload degrades to nulls instead of throwing', () {
      final BasicSceneEvent? event =
          BasicSceneEvent.fromPlatformMessage('ready', <String, Object?>{
        'viewId': 3,
        'parts': 'Frosted_Polymer',
        'fovDeg': 'wide',
      });
      expect(event, isNotNull);
      expect(event!.partCount, isNull);
      expect(event.fovDeg, isNull);
    });

    test('the line names counts, one basename and nothing else', () {
      const BasicSceneEvent event = BasicSceneEvent(
        kind: BasicSceneEventKind.ready,
        viewId: 7,
        model: 'Assets/models/archive-assembly.glb',
        meshCount: 10,
        triangleCount: 123456,
        webgl2: true,
        fovDeg: 6.125,
        partCount: 3,
      );
      final String line = basicSceneReadyMetricsLine(event);
      expect(line, contains('view=7'));
      expect(line, contains('model=archive-assembly.glb'));
      expect(line, contains('meshes=10'));
      expect(line, contains('triangles=123456'));
      expect(line, contains('fov=6.125'));
      expect(line, contains('parts=3'));
      expect(line, contains('webgl2=true'));
      expect(line.contains('Assets/models/'), isFalse);
      // Nothing that grows with the asset: no part names, no bounds, no newline.
      expect(line.contains('Frosted_Polymer'), isFalse);
      expect(line.contains('\n'), isFalse);
      expect(line.length, lessThanOrEqualTo(basicSceneReadyMetricsMaxLength));
    });

    test('the line is clipped to the ceiling for a hostile model string', () {
      const BasicSceneEvent event = BasicSceneEvent(
        kind: BasicSceneEventKind.ready,
        viewId: 1,
        model: 'A' * 5000,
      );
      final String line = basicSceneReadyMetricsLine(event);
      expect(line.length, basicSceneReadyMetricsMaxLength);
      expect(basicSceneReadyMetricsLine(event, maxLength: 32).length, 32);
    });

    test('missing fields fall back to zeroes instead of null text', () {
      const BasicSceneEvent event = BasicSceneEvent(
        kind: BasicSceneEventKind.ready,
        viewId: 2,
      );
      final String line = basicSceneReadyMetricsLine(event);
      expect(line, contains('meshes=0'));
      expect(line, contains('fov=0.000'));
      expect(line, contains('parts=0'));
      expect(line, contains('webgl2=false'));
      expect(line.contains('null'), isFalse);
    });

    test('the host logs once per view, inside the ready branch only', () {
      final String source = _read('lib/basic/scene_preview.dart');
      // Exactly two sites by design: the once-per-view ready metrics line, and
      // the bounded, de-duplicated update-failure line added for F1-I5.
      expect(RegExp(r'debugPrint\(').allMatches(source).length, 2);
      final String handler = _blockAfter(source, 'void _handleEvent(BasicSceneEvent event) {');
      expect(handler, contains('if (!_readyLogged) {'));
      expect(handler, contains('debugPrint(basicSceneReadyMetricsLine(event));'));
      final int logAt = handler.indexOf('debugPrint(');
      expect(logAt, greaterThan(handler.indexOf('setState(() {')));
      expect(logAt, greaterThan(handler.indexOf('_pushScene(<String, Object?>{')));
      expect(logAt, greaterThan(handler.indexOf('widget.onReady?.call(true);')));
      expect(logAt, lessThan(handler.indexOf('case BasicSceneEventKind.error:')));
      final String created = _blockAfter(source, 'void _onPlatformViewCreated(int id) {');
      // Every created view routes through the same reset, so a same-model
      // recreation cannot inherit a stale banner or a spent failure report.
      expect(created, contains('_resetViewLifecycle();'));
      final String reset = _blockAfter(source, 'void _resetViewLifecycle() {');
      expect(reset, contains('_readyLogged = false;'));
      expect(reset, contains('_error = null;'));
      expect(reset, contains('_failureReported = false;'));
      // The failure line is neither per frame nor unbounded.
      final String push = _blockAfter(source, 'Future<void> _applyScene(');
      expect(push, contains('if (signature == _lastPushFailure) return;'));
      expect(
        source,
        contains('const int basicSceneUpdateFailureMaxLength = 240;'),
      );
    });
  });

  // ---------------------------------------------------------------------
  // ATOM2: the widget seam, not a source grep.
  //
  // The groups above read the implementation as text. The failures this atom
  // fixes (two live views, a torn-down view's late events, a stale async
  // failure) only exist once a real AndroidView is created and real channel
  // messages travel, so this group mounts the production widget over the
  // engine's own platform-view protocol and the per-view method channels.
  // ---------------------------------------------------------------------
  group('ScenePreview over the real platform-view seam', () {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<int> created;
    late Map<int, List<MethodCall>> pushes;
    late Map<int, Future<Object?> Function(MethodCall call)> answers;
    late List<String> logs;
    late List<bool> readiness;
    late DebugPrintCallback originalDebugPrint;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      created = <int>[];
      pushes = <int, List<MethodCall>>{};
      answers = <int, Future<Object?> Function(MethodCall call)>{};
      logs = <String>[];
      readiness = <bool>[];
      // flutter_test ships no AssetManifest.bin, so the host's asset gate reads
      // through this seam (see basicSceneAvailableAssets in scene_preview.dart).
      basicSceneAvailableAssets = () async => <String>{
            basicSceneDefaultModel,
            basicSceneCassetteModel,
          };
      messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (MethodCall call) async {
          switch (call.method) {
            case 'create':
              final Map<Object?, Object?> args =
                  call.arguments as Map<Object?, Object?>;
              final int id = args['id']! as int;
              created.add(id);
              // Seed the list: a view that has not reported ready yet receives
              // no push, and asserting on a missing key would compare null
              // against isEmpty rather than an empty list (R2-M2).
              pushes[id] = <MethodCall>[];
              expect(args['viewType'], basicSceneViewType);
              // A real BasicSceneView would register its channel in init{}; the
              // mock native side registers the same per-view name here so the
              // Dart bridge really has a peer to talk to.
              messenger.setMockMethodCallHandler(
                MethodChannel(basicSceneChannelFor(id)),
                (MethodCall push) async {
                  pushes[id]!.add(push);
                  final Future<Object?> Function(MethodCall call)? answer =
                      answers[id];
                  return answer == null ? null : answer(push);
                },
              );
              return id;
            case 'resize':
              return 0;
            default:
              return null;
          }
        },
      );
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
      debugDefaultTargetPlatformOverride = null;
      basicSceneAvailableAssets = defaultBasicSceneAvailableAssets;
      BasicSceneBridge.detachAll();
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      for (final int id in created) {
        messenger.setMockMethodCallHandler(
          MethodChannel(basicSceneChannelFor(id)),
          null,
        );
      }
    });

    Widget volume(List<Widget> previews) {
      return MediaQuery(
        data: const MediaQueryData(size: Size(320, 240)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(mainAxisSize: MainAxisSize.min, children: previews),
        ),
      );
    }

    Widget preview({
      required Key key,
      required String songId,
      double theme = 0.25,
      String model = basicSceneDefaultModel,
      String mode = basicSceneArchiveMode,
    }) {
      return SizedBox(
        width: 120,
        height: 90,
        child: ScenePreview(
          key: key,
          songId: songId,
          albumId: 'album-$songId',
          model: model,
          theme: theme,
          mode: mode,
          onReady: readiness.add,
        ),
      );
    }

    /// Delivers one native event on the view's own channel and lets the widget
    /// rebuild. Written this way because the test binding's fake async only
    /// advances microtasks when it is pumped.
    Future<void> emit(
      WidgetTester tester,
      int viewId,
      String method, [
      Map<String, Object?> payload = const <String, Object?>{},
    ]) async {
      final Future<ByteData?> answer = messenger.handlePlatformMessage(
        basicSceneChannelFor(viewId),
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, <String, Object?>{'viewId': viewId, ...payload}),
        ),
        (ByteData? data) {},
      );
      await tester.pump();
      await answer;
      await tester.pump();
    }

    testWidgets('two live views are two platform views on two channels',
        (WidgetTester tester) async {
      await tester.pumpWidget(volume(<Widget>[
        preview(key: const ValueKey<String>('a'), songId: 'a'),
      ]));
      await tester.pump();
      await tester.pump();
      expect(created.length, 1);
      final int a = created.single;
      expect(pushes[a], isEmpty,
          reason: 'a view that never reported ready cannot be pushed to');

      await tester.pumpWidget(volume(<Widget>[
        preview(key: const ValueKey<String>('a'), songId: 'a'),
        preview(key: const ValueKey<String>('b'), songId: 'b', theme: 0.75),
      ]));
      await tester.pump();
      await tester.pump();
      expect(created.length, 2);
      final int b = created[1];
      expect(b, isNot(a));

      await emit(tester, a, 'ready', <String, Object?>{'meshes': 10});
      expect(pushes[a]!.single.arguments, <String, Object?>{
        'viewId': a,
        'theme': 0.25,
        'mode': basicSceneArchiveMode,
      });
      // The other live view is untouched: with one shared channel the newest
      // view would have stolen this push (F1-I2).
      expect(pushes[b], isEmpty);

      await emit(tester, b, 'ready');
      expect(pushes[b]!.single.arguments['theme'], 0.75);
      expect(pushes[a]!.length, 1);
    });

    testWidgets('a change before ready is replayed once with the latest values',
        (WidgetTester tester) async {
      Widget tree(double theme, String mode) => volume(<Widget>[
            preview(
              key: const ValueKey<String>('a'),
              songId: 'a',
              theme: theme,
              mode: mode,
            ),
          ]);

      await tester.pumpWidget(tree(0.2, basicSceneBootMode));
      await tester.pump();
      await tester.pump();
      final int a = created.single;

      // Still loading: the page cannot accept the mode yet, and the update must
      // not turn into a reload.
      await tester.pumpWidget(tree(0.9, basicSceneDetailMode));
      await tester.pump();
      expect(created.length, 1, reason: 'a mode change is a push, not a remount');
      expect(pushes[a], isEmpty);

      await emit(tester, a, 'ready');
      expect(pushes[a]!.length, 1);
      expect(pushes[a]!.single.arguments, <String, Object?>{
        'viewId': a,
        'theme': 0.9,
        'mode': basicSceneDetailMode,
      });

      // Once ready, only changed fields travel: theme and mode both move here so
      // the push really carries a mode (a same-mode push carries none, R2-M1).
      await tester.pumpWidget(tree(0.1, basicSceneArchiveMode));
      await tester.pump();
      expect(pushes[a]!.length, 2);
      expect(pushes[a]!.last.arguments['theme'], 0.1);
      expect(pushes[a]!.last.arguments['mode'], basicSceneArchiveMode);
    });

    testWidgets("a recreated view ignores the torn-down view's late events",
        (WidgetTester tester) async {
      Widget tree(String model) => volume(<Widget>[
            preview(
              key: const ValueKey<String>('a'),
              songId: 'a',
              model: model,
            ),
          ]);

      await tester.pumpWidget(tree(basicSceneDefaultModel));
      await tester.pump();
      await tester.pump();
      final int old = created.single;
      await emit(tester, old, 'ready');
      expect(readiness, <bool>[true]);

      // A different GLB means a different platform view (the AndroidView key),
      // and the old handler must not stay attached to the new view's slot.
      await tester.pumpWidget(tree(basicSceneCassetteModel));
      await tester.pump();
      await tester.pump();
      expect(created.length, 2);
      final int fresh = created[1];
      expect(pushes[fresh], isEmpty);

      await emit(tester, old, 'error', <String, Object?>{'message': 'torn down'});
      await emit(tester, old, 'ready');
      expect(readiness, <bool>[true], reason: 'the dead view cannot report again');
      expect(find.textContaining('3D 场景不可用'), findsNothing);
      expect(pushes[fresh], isEmpty);

      // A stale event can also arrive on the live channel while naming the dead
      // view; the bridge drops it on viewId before the host sees it.
      await emit(tester, fresh, 'ready', <String, Object?>{'viewId': old});
      expect(readiness, <bool>[true]);
      expect(pushes[fresh], isEmpty);

      await emit(tester, fresh, 'ready');
      expect(pushes[fresh]!.single.arguments['viewId'], fresh);
    });

    testWidgets('a failed push is logged once and does not kill the view',
        (WidgetTester tester) async {
      final Completer<Object?> gate = Completer<Object?>();
      Widget tree(double theme) => volume(<Widget>[
            preview(key: const ValueKey<String>('a'), songId: 'a', theme: theme),
          ]);

      await tester.pumpWidget(tree(0.4));
      await tester.pump();
      await tester.pump();
      final int a = created.single;
      await emit(tester, a, 'ready');

      answers[a] = (MethodCall call) => gate.future;
      await tester.pumpWidget(tree(0.6));
      await tester.pump();
      expect(pushes[a]!.length, 2);

      gate.completeError(PlatformException(code: 'renderer_gone', message: 'gone'));
      await tester.pump();

      final Iterable<String> failures = logs.where(
        (String line) => line.contains('basic scene update failed'),
      );
      expect(failures.length, 1);
      expect(failures.single, contains('view=$a'));
      expect(failures.single, contains('generation='));
      // Fail closed only on the asset gate: a runtime failure is a banner, and
      // the view keeps working (F1-I4).
      expect(find.textContaining('3D 场景不可用'), findsNothing);
      expect(find.byType(AndroidView), findsOneWidget);

      // The same failure on a later generation is still one line: the dedupe
      // key is the failure itself, not the generation-stamped line (R2-S3).
      answers[a] = (MethodCall call) async => throw PlatformException(
            code: 'renderer_gone',
            message: 'gone',
          );
      await tester.pumpWidget(tree(0.2));
      await tester.pump();
      expect(pushes[a]!.length, 3);
      expect(failures.length, 1,
          reason: 'a repeated failure is de-duplicated, not re-logged');

      answers.remove(a);
      await tester.pumpWidget(tree(0.1));
      await tester.pump();
      expect(pushes[a]!.length, 4);
      expect(find.byType(AndroidView), findsOneWidget);
    });

    testWidgets('a failure that lands after the view is gone is not reported',
        (WidgetTester tester) async {
      final Completer<Object?> gate = Completer<Object?>();
      Widget tree(double theme) => volume(<Widget>[
            preview(key: const ValueKey<String>('a'), songId: 'a', theme: theme),
          ]);

      await tester.pumpWidget(tree(0.4));
      await tester.pump();
      await tester.pump();
      final int a = created.single;
      await emit(tester, a, 'ready');

      answers[a] = (MethodCall call) => gate.future;
      await tester.pumpWidget(tree(0.6));
      await tester.pump();

      await tester.pumpWidget(volume(const <Widget>[]));
      await tester.pump();
      gate.completeError(PlatformException(code: 'renderer_gone'));
      await tester.pump();

      expect(
        logs.where((String line) => line.contains('basic scene update failed')),
        isEmpty,
      );
    });

    testWidgets('a scene error is a banner and a later ready clears it',
        (WidgetTester tester) async {
      Widget tree(double theme) => volume(<Widget>[
            preview(key: const ValueKey<String>('a'), songId: 'a', theme: theme),
          ]);

      await tester.pumpWidget(tree(0.4));
      await tester.pump();
      await tester.pump();
      final int a = created.single;
      await emit(tester, a, 'error', <String, Object?>{'message': 'webgl lost'});
      expect(find.textContaining('3D 场景不可用'), findsOneWidget);
      // The view is not unmounted, so recovery is actually reachable.
      expect(find.byType(AndroidView), findsOneWidget);

      await emit(tester, a, 'ready');
      expect(find.textContaining('3D 场景不可用'), findsNothing);
      expect(readiness, <bool>[false, true]);
    });

    testWidgets('a model change re-runs the asset gate',
        (WidgetTester tester) async {
      // Only the assembly is bundled. Swapping to the cassette must fail closed
      // instead of mounting a view that would 404, and the previous model's
      // "present" answer may not be carried over (R2-S1).
      basicSceneAvailableAssets = () async => <String>{basicSceneDefaultModel};
      Widget tree(String model) => volume(<Widget>[
            preview(key: const ValueKey<String>('a'), songId: 'a', model: model),
          ]);

      await tester.pumpWidget(tree(basicSceneDefaultModel));
      await tester.pump();
      await tester.pump();
      expect(created.length, 1);
      expect(find.byType(AndroidView), findsOneWidget);

      await tester.pumpWidget(tree(basicSceneCassetteModel));
      await tester.pump();
      await tester.pump();
      expect(created.length, 1, reason: 'the absent model never mounts');
      expect(find.byType(AndroidView), findsNothing);
      expect(find.textContaining('资源清单中缺少'), findsOneWidget);
      expect(readiness, <bool>[false]);
    });

    testWidgets('a blocked asset gate recovers on a model that is bundled',
        (WidgetTester tester) async {
      // The gate must not be a tombstone: a mount that failed closed has to be
      // able to come back once a bundled model is requested (R2-S5).
      basicSceneAvailableAssets = () async => <String>{};
      Widget tree(String model) => volume(<Widget>[
            preview(key: const ValueKey<String>('a'), songId: 'a', model: model),
          ]);

      await tester.pumpWidget(tree(basicSceneDefaultModel));
      await tester.pump();
      await tester.pump();
      expect(created, isEmpty);
      expect(find.byType(AndroidView), findsNothing);
      expect(find.textContaining('资源清单中缺少'), findsOneWidget);
      // A blocked gate reports the failure once, like any other mount failure.
      expect(readiness, <bool>[false]);

      basicSceneAvailableAssets = () async => <String>{basicSceneCassetteModel};
      await tester.pumpWidget(tree(basicSceneCassetteModel));
      await tester.pump();
      await tester.pump();
      expect(created.length, 1, reason: 'the bundled model mounts');
      expect(find.byType(AndroidView), findsOneWidget);
      expect(find.textContaining('资源清单中缺少'), findsNothing);
      expect(readiness, <bool>[false], reason: 'the mount is not ready yet');

      await emit(tester, created.single, 'ready');
      expect(readiness, <bool>[false, true]);
      expect(pushes[created.single]!.last.arguments, <String, Object?>{
        'viewId': created.single,
        'theme': 0.25,
        'mode': basicSceneArchiveMode,
      });
    });

    testWidgets('a recreated view starts without the old banner',
        (WidgetTester tester) async {
      // An error belongs to the view that raised it. The keyed model swap resets
      // the lifecycle before the replacement is created, so the stale banner is
      // gone even though the new view never reports anything (R2-S6).
      Widget tree(String model) => volume(<Widget>[
            preview(key: const ValueKey<String>('a'), songId: 'a', model: model),
          ]);

      await tester.pumpWidget(tree(basicSceneDefaultModel));
      await tester.pump();
      await tester.pump();
      final int first = created.single;
      await emit(tester, first, 'error', <String, Object?>{
        'message': 'render process gone',
      });
      expect(find.textContaining('3D 场景不可用'), findsOneWidget);

      await tester.pumpWidget(tree(basicSceneCassetteModel));
      await tester.pump();
      await tester.pump();
      // One more pump so the re-run asset gate can mount the replacement.
      await tester.pump();
      expect(created.length, 2);
      expect(find.textContaining('3D 场景不可用'), findsNothing);
      expect(find.byType(AndroidView), findsOneWidget);
      expect(readiness, <bool>[false], reason: 'the new view is not ready yet');
      expect(pushes[created.last], isEmpty, reason: 'no push before ready');
    });

    testWidgets('a missing asset keeps the platform view unmounted',
        (WidgetTester tester) async {
      basicSceneAvailableAssets = () async => <String>{};
      await tester.pumpWidget(volume(<Widget>[
        preview(key: const ValueKey<String>('a'), songId: 'a'),
      ]));
      await tester.pump();
      await tester.pump();
      expect(created, isEmpty);
      expect(find.byType(AndroidView), findsNothing);
      expect(find.textContaining('资源清单中缺少'), findsOneWidget);
      expect(readiness, <bool>[false]);
    });
  });
}

/// Reads a repository-relative file as text (same idiom as the surrounding
/// source-contract tests; dart:io is imported above).
String _read(String path) => File(path).readAsStringSync();

/// Returns the brace-balanced block that starts at the first '{' after
/// [marker]. Used to scope source-contract assertions to one method body.
String _blockAfter(String source, String marker) {
  final int at = source.indexOf(marker);
  expect(at, greaterThanOrEqualTo(0), reason: 'missing source marker: $marker');
  final int start = source.indexOf('{', at);
  expect(start, greaterThanOrEqualTo(0), reason: 'no block after: $marker');
  int depth = 0;
  for (int index = start; index < source.length; index++) {
    final String ch = source[index];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(at, index + 1);
    }
  }
  return source.substring(at);
}
