// RUNTIME-MATERIAL-97 — scene material / key-light contract tests.
//
// These tests compare web/basic_preview/renderer.js against the Qt sources that
// the renderer claims to port, so a drift on either side fails:
//   Qt/src/RhiScene.cpp:1422-1433          dark(name) sRGB table + fallbacks
//   Qt/src/RhiScene.cpp:1402,1419-1420     opticalLight vector / emission colour
//   Qt/shaders/enhancement/opticalSurface.frag:51,53  KEY_LIGHT + hero-only gate
//   Qt/src/NativeSceneCamera.cpp:98        perspective near/far = 5/300
//
// They are WRITTEN ONLY. This worktree forbids flutter test / pub get / gradle,
// so RED and GREEN are both unexecuted here. Planned entry point:
//   flutter test test/basic/runtime_scene_material_test.dart
//
// A passing run proves the *source contract* (constants, direction, blending
// structure, absence of the retired PointLight). It does not prove pixels.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _rendererPath = 'web/basic_preview/renderer.js';
const String _rhiScenePath = 'Qt/src/RhiScene.cpp';
const String _fragPath = 'Qt/shaders/enhancement/opticalSurface.frag';
const String _cameraPath = 'Qt/src/NativeSceneCamera.cpp';

String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: 'missing required source: $path');
  return file.readAsStringSync();
}

/// Removes JS block and line comments. Line comments are only stripped when
/// '//' is not part of a URL scheme, so comment prose can never satisfy an
/// assertion about executable code.
String _stripJsComments(String text) {
  final String noBlocks = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlocks.replaceAllMapped(
    RegExp(r'(^|[^:])//[^\n]*'),
    (Match match) => match.group(1)!,
  );
}

/// The balanced brace span that follows [marker], e.g. a function body or an
/// object literal. Brace counting (not "first '};'") matters because these
/// blocks close with both `};` and `}`, and the port has nested closures.
String _jsBlock(String source, String marker) {
  final int markerAt = source.indexOf(marker);
  expect(markerAt, greaterThanOrEqualTo(0), reason: 'missing renderer block: $marker');
  final int open = source.indexOf('{', markerAt);
  expect(open, greaterThanOrEqualTo(0), reason: 'no opening brace after: $marker');
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unterminated renderer block: $marker');
}

/// Same balanced-span rule for a C++ function body.
String _cppBlock(String source, String marker) {
  final int markerAt = source.indexOf(marker);
  expect(markerAt, greaterThanOrEqualTo(0), reason: 'missing Qt block: $marker');
  final int open = source.indexOf('{', markerAt);
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unterminated Qt block: $marker');
}

double _d(String raw) => double.parse(raw);

/// name -> 0xrrggbb for the Qt RhiScene::dark() table.
///
/// Scoped to the function body so an unrelated hex pair elsewhere in
/// RhiScene.cpp cannot inflate or silently replace the table.
Map<String, int> _qtDarkTable(String rhiScene) {
  final String body = _cppBlock(rhiScene, 'QVector3D dark(QString name) {');
  final Map<String, int> table = <String, int>{};
  for (final RegExpMatch m
      in RegExp(r'\{"([A-Za-z_]+)",\s*0x([0-9a-fA-F]{6})\}').allMatches(body)) {
    table[m.group(1)!] = int.parse(m.group(2)!, radix: 16);
  }
  return table;
}

void main() {
  group('Qt dark() colour table is mirrored exactly', () {
    test('every Qt part maps to the same sRGB hex in the renderer', () {
      final Map<String, int> qt = _qtDarkTable(_read(_rhiScenePath));
      expect(qt.length, 9, reason: 'Qt dark() table should hold 9 parts');

      final String js = _read(_rendererPath);
      final Map<String, int> ported = <String, int>{};
      for (final RegExpMatch m in RegExp(r'([A-Za-z_]+):\s*0x([0-9a-fA-F]{6})')
          .allMatches(_jsBlock(js, 'const DARK_COLORS = {'))) {
        ported[m.group(1)!] = int.parse(m.group(2)!, radix: 16);
      }

      expect(ported.keys.toSet(), qt.keys.toSet(),
          reason: 'part set must not diverge from RhiScene.cpp dark()');
      for (final String part in qt.keys) {
        expect(ported[part], qt[part],
            reason: '$part dark colour must equal Qt 0x${qt[part]!.toRadixString(16)}');
      }
    });

    test('default and Orange fallbacks match the Qt ternary', () {
      final String darkBody = _cppBlock(_read(_rhiScenePath), 'QVector3D dark(QString name) {');
      final RegExpMatch? fallback = RegExp(
              r'contains\("Orange"\)\s*\?\s*0x([0-9a-fA-F]{6})\s*:\s*0x([0-9a-fA-F]{6})')
          .firstMatch(darkBody);
      expect(fallback, isNotNull, reason: 'Qt dark() fallback ternary not found');
      // expect() does not promote nullability, so bind the non-null match.
      final RegExpMatch fb = fallback!;

      final String js = _read(_rendererPath);
      final RegExpMatch? orange = RegExp(r'DARK_ORANGE = 0x([0-9a-fA-F]{6})').firstMatch(js);
      final RegExpMatch? fallbackDefault =
          RegExp(r'DARK_DEFAULT = 0x([0-9a-fA-F]{6})').firstMatch(js);
      expect(orange, isNotNull);
      expect(fallbackDefault, isNotNull);

      expect(int.parse(orange!.group(1)!, radix: 16), int.parse(fb.group(1)!, radix: 16));
      expect(int.parse(fallbackDefault!.group(1)!, radix: 16), int.parse(fb.group(2)!, radix: 16));
    });

    test('darkHexFor keeps the Qt lookup order: table, Orange, default', () {
      final String body = _jsBlock(_read(_rendererPath), 'function darkHexFor(part) {');
      final int tableAt = body.indexOf('hasOwnProperty.call(DARK_COLORS, part)');
      final int orangeAt = body.indexOf("indexOf('Orange')");
      final int defaultAt = body.indexOf('return DARK_DEFAULT');
      expect(tableAt, greaterThanOrEqualTo(0));
      expect(orangeAt, greaterThan(tableAt), reason: 'Orange must be checked after the table');
      expect(defaultAt, greaterThan(orangeAt), reason: 'default must be the last fallback');
    });
  });

  group('KEY_LIGHT direction mirrors the Qt shader', () {
    test('direction equals opticalSurface.frag:51 and is normalised', () {
      final String frag = _read(_fragPath);
      final RegExpMatch? qt = RegExp(
              r'KEY_LIGHT\s*=\s*normalize\(vec3\(([-\d.]+),\s*([-\d.]+),\s*([-\d.]+)\)\)')
          .firstMatch(frag);
      expect(qt, isNotNull, reason: 'Qt KEY_LIGHT normalize(vec3(...)) not found');

      final String js = _read(_rendererPath);
      final RegExpMatch? ported = RegExp(
              r'KEY_LIGHT_DIRECTION = normalize3\(\{\s*x:\s*([-\d.]+),\s*y:\s*([-\d.]+),\s*z:\s*([-\d.]+)\s*\}\)')
          .firstMatch(_stripJsComments(js));
      expect(ported, isNotNull,
          reason: 'renderer must wrap the Qt direction in normalize3, not a raw vector');

      for (int i = 0; i < 3; i++) {
        expect(_d(ported!.group(i + 1)!), closeTo(_d(qt!.group(i + 1)!), 1e-12),
            reason: 'KEY_LIGHT component $i must match the Qt shader');
      }
    });

    test('Qt gates the key light to hero surfaces, and the port documents it', () {
      final String frag = _read(_fragPath);
      expect(
        RegExp(r'if \(v_mode < 0\.5\) \{\s*return base;').hasMatch(frag),
        isTrue,
        reason: 'Qt keyLight() must still be hero-only (v_mode gate)',
      );
      // The port applies one directional light globally; that gap must stay
      // documented instead of being silently implied as exact.
      expect(_read(_rendererPath), contains('GAP-3'));
    });
  });

  group('materials blend day -> dark per theme without accumulation', () {
    test('prepareMaterialTheme snapshots the day colour exactly once', () {
      final String body =
          _jsBlock(_read(_rendererPath), 'function prepareMaterialTheme(material, part) {');
      expect(body, contains('if (!material.rhineDayColor) {'));
      expect(body, contains('material.rhineDayColor = material.color.clone();'));
      expect(body, contains('setHex(darkHexFor(part), THREE.SRGBColorSpace)'));
      expect(body, contains('material.color.copy(material.rhineDayColor).lerp(material.rhineDarkColor, theme);'));
      expect(body, contains('Own properties, not userData'),
          reason: 'shared userData between clones would cross-contaminate day colours');
    });

    test('applyMaterialTheme re-blends from the snapshot, never the live colour', () {
      final String body = _jsBlock(_read(_rendererPath), 'function applyMaterialTheme(themeValue) {');
      expect(body, contains('modelRoot.traverse'));
      expect(body, contains('material.color.copy(material.rhineDayColor).lerp(material.rhineDarkColor, themeValue);'));
      // Re-blending from the live colour would compound across successive theme
      // switches; the copy-from-day is what prevents that.
      expect(
        RegExp(r'color\.lerp\(').hasMatch(body),
        isFalse,
        reason: 'must copy the day snapshot first, not lerp the live colour',
      );
    });

    test('onModelLoaded themes every mesh and fails loudly on an empty GLB', () {
      final String body = _jsBlock(_read(_rendererPath), 'function onModelLoaded(gltf) {');
      // Without this call site the day/dark snapshot is never installed and
      // applyMaterialTheme becomes a silent no-op, so deleting it must fail here.
      expect(body, contains('prepareMaterialTheme(materials[i], part);'),
          reason: 'the theme snapshot must be taken where the GLB materials are built');
      expect(body, contains('meshes.push(child);'));
      expect(body, contains('if (meshes.length === 0) {'));
      expect(
        body,
        contains("fail('glb', 'GLB has no visible meshes after Qt part filtering');"),
        reason: 'an invisible GLB must report a real failure, not render an empty scene',
      );
      expect(body, contains('postReady();'));
    });

    test('Qt mixes the same pair by v_theme, which is why per-material blend is right', () {
      final String frag = _read(_fragPath);
      expect(frag, contains('mix(m.color.rgb, m.darkColor.rgb, v_theme)'));
    });

    test('sRGB->linear transfer matches the Qt dark() channel lambda', () {
      final String darkBody = _cppBlock(_read(_rhiScenePath), 'QVector3D dark(QString name) {');
      expect(darkBody, contains('.04045f'), reason: 'Qt channel() threshold');
      expect(darkBody, contains('12.92f'), reason: 'Qt channel() linear slope');

      final String js = _read(_rendererPath);
      final RegExpMatch? threshold =
          RegExp(r'function srgbToLinear1\(channel\) \{\s*return channel < ([\d.]+)')
              .firstMatch(js);
      expect(threshold, isNotNull);
      expect(_d(threshold!.group(1)!), 0.04045);
      expect(js, contains('0.0773993808'), reason: 'exactly 1 / 12.92');
    });

    test('lerp is plain linear interpolation so theme 1 lands exactly on dark', () {
      final String body = _jsBlock(_read(_rendererPath), 'function lerp(');
      expect(
        RegExp(r'return a \+ \(b - a\) \* t;').hasMatch(body),
        isTrue,
        reason: 'a non-linear lerp would not reproduce Qt mix()',
      );
    });
  });

  group('theme changes reach materials at runtime', () {
    test('applyThemeColors drives the material blend, not just background/fog/floor', () {
      final String body = _jsBlock(_read(_rendererPath), 'function applyThemeColors() {');
      expect(body, contains('applyMaterialTheme(theme);'));
      expect(body, contains('blendLinear(hexToLinear(BACKGROUND_DAY)'));
      expect(body, contains('blendLinear(hexToLinear(FLOOR_DAY)'));
    });

    test('the bridge setTheme path updates theme and re-applies colours', () {
      final String js = _read(_rendererPath);
      final String bridge = _jsBlock(js, 'window.__rhineBasicScene = {');
      expect(bridge, contains('setTheme: function (value) {'));
      expect(bridge, contains('theme = clamp01(next);'));
      expect(bridge, contains('applyThemeColors();'));
    });

    test('boot applies the requested theme before the GLB is themed', () {
      final String js = _read(_rendererPath);
      expect(js, contains("let theme = clamp01(finiteNumber(query.get('theme'), 1));"));
      expect(js, contains('applyThemeColors();'));
      // Empty-string query params must fall back instead of becoming theme 0.
      expect(js, contains("if (value === null || value === undefined || value === '') return fallback;"));
      // Presence alone would pass even if the scene were themed only after the
      // GLB request started, so assert the ordering inside boot().
      final String boot = _jsBlock(js, 'function boot() {');
      final int themedAt = boot.indexOf('applyThemeColors();');
      final int loadAt = boot.indexOf('loader.load(');
      expect(themedAt, greaterThanOrEqualTo(0));
      expect(loadAt, greaterThan(themedAt),
          reason: 'boot must theme the scene before the GLB request starts');
    });
  });

  group('the retired PointLight optical light does not come back', () {
    test('no point light, shadow-position light or decay survives in code', () {
      final String code = _stripJsComments(_read(_rendererPath));
      for (final String banned in <String>[
        'PointLight',
        'qt-optical-light',
        'SHADOW_LIGHT_POS',
        'OPTICAL_DECAY',
        'EMISSION_COLOR',
        '.decay',
      ]) {
        expect(code.contains(banned), isFalse,
            reason: '$banned was retired: Qt opticalLight is a scalar on the baked '
                'light atlas (RhiScene.cpp:1402,1419), not a positional light');
      }
    });

    test('exactly one directional light, aimed from the Qt direction', () {
      final String code = _stripJsComments(_read(_rendererPath));
      expect(RegExp(r'new THREE\.DirectionalLight\(').allMatches(code).length, 1);
      expect(code, contains("key.name = 'qt-key-light-direction';"));
      expect(code, contains('key.target.position.set(0, 0, 0);'));
      expect(code, contains('key.target.updateMatrixWorld();'));
      // A DirectionalLight without its target in the scene keeps Three's default
      // target at the origin only by accident; adding it is the explicit fix.
      expect(code, contains('scene.add(key.target);'));
      // Name and target alone survive a (0,0,0) position, which would zero N.L.
      for (final String axis in <String>['x', 'y', 'z']) {
        expect(code, contains('KEY_LIGHT_DIRECTION.$axis * 20'),
            reason: 'key.position must derive from the Qt KEY_LIGHT ${axis} component');
      }
    });

    test('the optical-light gap stays documented instead of being faked', () {
      expect(_read(_rendererPath), contains('GAP-4'));
    });
  });

  group('transport and camera contract survive the material port', () {
    test('near/far planes still equal the Qt perspective call', () {
      final String camera = _read(_cameraPath);
      final RegExpMatch? qt =
          RegExp(r'perspective\(m_fov,\s*aspect,\s*([\d.]+),\s*([\d.]+)\)').firstMatch(camera);
      expect(qt, isNotNull, reason: 'NativeSceneCamera.cpp:98 perspective not found');

      final String js = _read(_rendererPath);
      final RegExpMatch? near = RegExp(r'NEAR_PLANE = ([\d.]+);').firstMatch(js);
      final RegExpMatch? far = RegExp(r'FAR_PLANE = ([\d.]+);').firstMatch(js);
      expect(near, isNotNull);
      expect(far, isNotNull);
      expect(_d(near!.group(1)!), _d(qt!.group(1)!));
      expect(_d(far!.group(1)!), _d(qt.group(2)!));
    });

    test('bridge payload, selection meshIndex and bridge surface are intact', () {
      final String code = _stripJsComments(_read(_rendererPath));
      expect(code, contains('bridge.postMessage(JSON.stringify(message));'));
      expect(code, contains('child.userData.rhineMeshIndex = meshes.length;'));
      expect(code, contains('meshIndex: Number.isInteger(mesh.userData.rhineMeshIndex)'));
      expect(code, contains('window.__rhineBasicScene = {'));
      expect(code, contains('setYaw: function (radians) {'));
      expect(code, contains('resetView: function () {'));
    });

    test('a GLB whose parts were all filtered out fails loudly', () {
      final String code = _stripJsComments(_read(_rendererPath));
      expect(
        RegExp(r'if \(meshes\.length === 0\) \{[\s\S]{0,120}fail\(').hasMatch(code),
        isTrue,
        reason: 'an empty model must report an error, not post a ready with 0 meshes',
      );
    });
  });
}
