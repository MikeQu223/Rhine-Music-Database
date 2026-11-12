// BASIC-89 lane C — pure Dart tests for the 3D preview boundary.
//
// Contract under test: lib/basic/scene_preview.dart (owner C), the Kotlin host
// BasicSceneView.kt / BasicSceneViewFactory.kt, and the offline web assets.
//
// These tests are WRITTEN ONLY. This worktree forbids flutter test / pub get /
// gradle, so RED and GREEN are both unexecuted here. Planned entry point:
//   flutter test test/basic/scene_preview_test.dart

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
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
      });
      expect(params.toMap()['model'], basicSceneDefaultModel);
      expect(params.toMap()['initialYaw'], 0);
      expect(params.toMap()['theme'], 1);
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
      expect(preview.onReady, isNull);
    });

    test('unsupported platforms are labelled honestly in the source', () {
      final String source =
          File('lib/basic/scene_preview.dart').readAsStringSync();
      expect(source.contains('3D 场景预览仅在 Android 可用'), isTrue);
      expect(source.contains('这里不渲染模型、截图或旋转动画'), isTrue);
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
}
