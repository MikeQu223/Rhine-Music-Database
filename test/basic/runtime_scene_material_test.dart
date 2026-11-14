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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const String _rendererPath = 'web/basic_preview/renderer.js';
const String _rhiScenePath = 'Qt/src/RhiScene.cpp';
const String _fragPath = 'Qt/shaders/enhancement/opticalSurface.frag';
const String _cameraPath = 'Qt/src/NativeSceneCamera.cpp';
const String _modelsPath = 'lib/basic/basic_models.dart';
const String _controllerPath = 'lib/basic/siren_controller.dart';

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

  // F2 — the pane's flat field was the floor eaten by detail-endpoint fog,
  // because applyView hard-coded detail = 1 inside an archive-page pane.
  group('detail blend and Qt fog are derived, not hard-coded', () {
    test('applyView derives the pose from the detail blend instead of a literal 1', () {
      final String applyView = _jsBlock(_stripJsComments(_read(_rendererPath)), 'function applyView() {');
      expect(applyView, contains('computePose(viewWidth, viewHeight, posedDetail, ACTOR_POSITION);'));
      expect(applyView, contains('const posedDetail = sceneDetailEased;'));
      expect(applyView.contains('computePose(viewWidth, viewHeight, 1,'), isFalse,
          reason: 'the hard-coded detail = 1 was the F2 defect');
    });

    test('fog near/far use the Qt theme+detail interpolation on the rendered distance', () {
      final String camera = _read(_cameraPath);
      expect(camera, contains('m_fogNear = renderedDistance + lerp(5 - 4 * theme, -1, m_detail);'));
      expect(camera, contains('m_fogFar = renderedDistance + lerp(25 - 9 * theme, 12, m_detail);'));

      final String applyView = _jsBlock(_stripJsComments(_read(_rendererPath)), 'function applyView() {');
      expect(applyView,
          contains('scene.fog.near = renderedDistance + lerp(5 - 4 * theme, -1, posedDetail);'));
      expect(applyView,
          contains('scene.fog.far = renderedDistance + lerp(25 - 9 * theme, 12, posedDetail);'));
      // The literal endpoints were the bug: they fog the archive composition at
      // the detail distance, so the floor plane reads as a solid box.
      expect(applyView.contains('renderedDistance - 1;'), isFalse,
          reason: 'fogNear must keep the Qt interpolation, not a detail-only endpoint');
      expect(applyView.contains('renderedDistance + 12;'), isFalse,
          reason: 'fogFar must keep the Qt interpolation, not a detail-only endpoint');
      // Qt measures from the rendered eye/aim pair (:94), never from the
      // requested distance.
      expect(applyView, contains('const renderedDistance = Math.sqrt('));
    });

    test('distance and span keep the Qt detail endpoints', () {
      final String pose = _jsBlock(
          _stripJsComments(_read(_rendererPath)),
          'function computePose(width, height, detail, actorPosition) {');
      expect(pose, contains('const distance = lerp(lerp(28 + 7 * orbit, 140, settle), 72, detail);'));
      expect(pose, contains('const baseSpan = lerp(span, 5.9, detail);'));

      final String camera = _read(_cameraPath);
      expect(camera, contains('const auto distance = lerp(lerp(28 + 7 * orbit, 140, settle), 72, m_detail);'));
      expect(camera, contains('const auto baseSpan = lerp(span, 5.9, m_detail);'));
    });

    test('the archive lens shift is the Qt projection offset and re-syncs the inverse', () {
      final String camera = _read(_cameraPath);
      expect(camera, contains('const auto detailProgress = SceneMotion::smooth((m_detail - 0.25) / 0.55);'));
      // Qt gates the shift on the camera mode itself (:101): boot and cinema
      // hold the offset at zero, so their first frame is unshifted.
      expect(
          camera,
          contains(
              'const auto archiveOffset = cinema || m_mode == "boot" ? 0.0 : 1 - detailProgress;'));
      expect(camera, contains('m_projection.values[8] += 0.16 * archiveOffset;'));
      expect(camera, contains('m_projection.values[9] += 0.20 * archiveOffset;'));

      final String js = _stripJsComments(_read(_rendererPath));
      final String shift =
          _jsBlock(js, 'function applyArchiveLensShift(target, mode, detail) {');
      expect(shift, contains('const detailProgress = smooth((detail - 0.25) / 0.55);'));
      // The port gates on the mode it was actually sent, not on a comment
      // about a mode it cannot be sent: that was F2-M1.
      expect(shift, contains("const archiveOffset = mode === 'boot' ? 0 : 1 - detailProgress;"));
      expect(shift, contains('target.projectionMatrix.elements[8] += 0.16 * archiveOffset;'));
      expect(shift, contains('target.projectionMatrix.elements[9] += 0.20 * archiveOffset;'));
      // A boot frame therefore adds exactly zero to both entries; the matrix
      // multiplication still runs, so nothing silently skips the block.
      final String applyView = _jsBlock(js, 'function applyView() {');
      expect(applyView, contains('applyArchiveLensShift(camera, sceneMode, posedDetail);'));

      // Pick() raycasts through the projection matrix; a stale inverse would
      // offset every hit test by exactly the lens shift.
      expect(shift, contains('target.projectionMatrixInverse.copy(target.projectionMatrix).invert();'));

      // The offset must be applied after the rebuild, or it is discarded.
      final int rebuildAt = applyView.indexOf('camera.updateProjectionMatrix();');
      final int shiftAt = applyView.indexOf('applyArchiveLensShift(camera, sceneMode, posedDetail);');
      expect(rebuildAt, greaterThanOrEqualTo(0));
      expect(shiftAt, greaterThan(rebuildAt),
          reason: 'applyArchiveLensShift must run after updateProjectionMatrix');
    });

    test('setMode accepts exactly the three Qt mode strings and re-derives the view', () {
      final String js = _stripJsComments(_read(_rendererPath));
      final String bridge = _jsBlock(js, 'window.__rhineBasicScene = {');
      final String setMode = _jsBlock(bridge, 'setMode: function (mode) {');
      expect(setMode, contains('const known = resolveSceneMode(mode);'));
      expect(setMode, contains('if (known === null) return;'));
      expect(setMode, contains('sceneMode = known;'));
      expect(setMode, contains("sceneDetail = known === 'detail' ? 1 : 0;"));
      expect(setMode, contains('applyView();'));
      // An unknown spelling is ignored, and it is never coerced into a phase.
      expect(setMode.contains("sceneMode = 'archive';"), isFalse,
          reason: 'an unknown mode must not silently re-frame the camera');
      expect(setMode.contains("sceneMode = 'boot';"), isFalse);
    });

    test('the launch phase is boot, and only an explicit mode may say so', () {
      // lib/basic/basic_models.dart:442 is the enum declaration
      // 'enum BasicPhase { boot, library, detail, lyrics }'; the launch value is
      // :451 'this.phase = BasicPhase.boot,' seeded from
      // lib/basic/siren_controller.dart:131 'BasicPhase _phase = BasicPhase.boot;'.
      // lib/basic/basic_hud.dart:519-523 therefore mounts this pane at boot, not at a
      // first-page library, and the old comment claiming otherwise was wrong.
      expect(_read(_modelsPath), contains('this.phase = BasicPhase.boot,'));
      expect(_read(_controllerPath), contains('BasicPhase _phase = BasicPhase.boot;'));

      final String js = _stripJsComments(_read(_rendererPath));
      // Boot never rides on an absent query value: the resolver falls back to
      // archive, and boot needs the literal spelling.
      expect(js,
          contains("let sceneMode = resolveSceneMode(query.get('mode')) || 'archive';"));
      expect(js, contains('const nextMode = resolveSceneMode(next.mode);'));
      expect(js.contains("let sceneMode = resolveSceneMode(query.get('mode')) || 'boot';"),
          isFalse,
          reason: 'a boot default would compose an unshifted frame for every host');
      expect(_read(_rendererPath),
          contains("let sceneDetail = clamp01(finiteNumber(query.get('detail'), 0));"));
      expect(_read(_rendererPath),
          isNot(contains("let sceneDetail = clamp01(finiteNumber(query.get('detail'), 1));")),
          reason: 'a detail default renders the pane on the wrong page');
    });

    test('boot -> archive -> detail keeps the adopted mode and the blend in step', () {
      final String js = _stripJsComments(_read(_rendererPath));
      final String bridge = _jsBlock(js, 'window.__rhineBasicScene = {');
      final String setMode = _jsBlock(bridge, 'setMode: function (mode) {');
      final int resolveAt = setMode.indexOf('resolveSceneMode(mode)');
      final int rejectAt = setMode.indexOf('if (known === null) return;');
      final int adoptAt = setMode.indexOf('sceneMode = known;');
      final int blendAt = setMode.indexOf("sceneDetail = known === 'detail' ? 1 : 0;");
      final int drawAt = setMode.indexOf('applyView();');
      for (final int at in <int>[resolveAt, rejectAt, adoptAt, blendAt, drawAt]) {
        expect(at, greaterThanOrEqualTo(0));
      }
      expect(rejectAt, greaterThan(resolveAt));
      expect(adoptAt, greaterThan(rejectAt));
      expect(blendAt, greaterThan(adoptAt));
      expect(drawAt, greaterThan(blendAt),
          reason: 'the redraw must see the adopted mode, or the shift uses the old one');

      final String setScene = _jsBlock(bridge, 'setScene: function (next) {');
      final int adoptPushAt = setScene.indexOf('sceneMode = nextMode;');
      final int pushDrawAt = setScene.indexOf('if (changed) applyView();');
      expect(adoptPushAt, greaterThanOrEqualTo(0));
      expect(pushDrawAt, greaterThan(adoptPushAt),
          reason: 'a pushed mode must be adopted before the redraw');
      // A message that omits mode (theme-only update) must not reset the
      // phase: the adoption stays inside the non-null branch.
      expect(setScene, contains('if (nextMode !== null) {'));
    });

    test('setTheme re-derives the view because fog reads the theme', () {
      final String bridge =
          _jsBlock(_stripJsComments(_read(_rendererPath)), 'window.__rhineBasicScene = {');
      final String setTheme = _jsBlock(bridge, 'setTheme: function (value) {');
      expect(setTheme, contains('applyThemeColors();'));
      // Scoped to setTheme: setMode also calls applyView(), so an unscoped
      // indexOf would stay green even if setTheme stopped re-deriving the view.
      expect(setTheme, contains('applyView();'),
          reason: 'Qt/src/NativeSceneCamera.cpp:95-97 makes fog distances theme dependent');
    });
  });

  // F2b — the night palette. git log -S darkHexFor shows d1c7018 already
  // shipped it, so this atom is a parity pin rather than a rewrite: it fails if
  // either side of the day/dark pair drifts, or if a shipped part stops
  // resolving to the colour Qt would give it.
  group('night palette parity with Qt dark(name)', () {
    test('every Qt dark() entry is byte-identical in DARK_COLORS', () {
      final String qt = _cppBlock(_read(_rhiScenePath), 'QVector3D dark(QString name) {');
      final Map<String, int> qtColors = <String, int>{
        for (final RegExpMatch match
            in RegExp(r'\{"([A-Za-z_]+)",\s*0x([0-9a-f]{6})\}').allMatches(qt))
          match.group(1)!: int.parse(match.group(2)!, radix: 16),
      };
      expect(qtColors.length, 9, reason: 'RhiScene.cpp:1423-1426 lists nine parts');

      final String object =
          _jsBlock(_stripJsComments(_read(_rendererPath)), 'const DARK_COLORS = {');
      final Map<String, int> port = <String, int>{
        for (final RegExpMatch match
            in RegExp(r'([A-Za-z_]+):\s*0x([0-9a-f]{6})').allMatches(object))
          match.group(1)!: int.parse(match.group(2)!, radix: 16),
      };
      expect(port, equals(qtColors));
    });

    test('the fallback chain mirrors colors.value(name, ... ? 0xbb8850 : 0x969f9f)', () {
      final String qt = _cppBlock(_read(_rhiScenePath), 'QVector3D dark(QString name) {');
      expect(qt, contains('name.contains("Orange") ? 0xbb8850 : 0x969f9f'));

      final String body =
          _jsBlock(_stripJsComments(_read(_rendererPath)), 'function darkHexFor(part) {');
      expect(body, contains('return DARK_COLORS[part];'));
      expect(body, contains("if (part && part.indexOf('Orange') >= 0) return DARK_ORANGE;"));
      expect(body, contains('return DARK_DEFAULT;'));
      // Order matters: Qt looks the table up first, so a future part called
      // e.g. Orange_Edges must not shortcut the Orange fallback.
      expect(body.indexOf('DARK_COLORS[part]'), lessThan(body.indexOf("indexOf('Orange')")));
      expect(body.indexOf("indexOf('Orange')"), lessThan(body.indexOf('return DARK_DEFAULT;')));

      final String js = _read(_rendererPath);
      expect(js, contains('const DARK_DEFAULT = 0x969f9f;'));
      expect(js, contains('const DARK_ORANGE = 0xbb8850;'));
    });

    test('every day override has a dark pair, so no shell can stay day-lit at night', () {
      final String js = _stripJsComments(_read(_rendererPath));
      final String overrides = _jsBlock(js, 'const PART_OVERRIDES = {');
      final String table = _jsBlock(js, 'const DARK_COLORS = {');
      final Set<String> overrideNames = RegExp(r'([A-Za-z_]+): \{ color:')
          .allMatches(overrides)
          .map((RegExpMatch match) => match.group(1)!)
          .toSet();
      expect(overrideNames.length, 3, reason: 'SceneAppearance.cpp:86-103 overrides three parts');
      for (final String name in overrideNames) {
        expect(table, contains('$name: 0x'),
            reason: '$name is day-overridden but has no Qt dark colour, so it would keep '
                'day material under the night theme');
      }
    });

    test('every shipped assembly node resolves to a Qt dark colour', () {
      final Map<String, int> table = <String, int>{
        for (final RegExpMatch match in RegExp(r'([A-Za-z_]+):\s*0x([0-9a-f]{6})').allMatches(
            _jsBlock(_stripJsComments(_read(_rendererPath)), 'const DARK_COLORS = {')))
          match.group(1)!: int.parse(match.group(2)!, radix: 16),
      };
      // Count raw nodes first: the exporter duplicates each part per sub-mesh
      // (.012/.010/.003/.001/...), so the 22 shipped nodes collapse to 16
      // normalised families and a family-count threshold would be misleading.
      final List<String> nodeNames = _glbNodeNames('Assets/models/archive-assembly.glb');
      expect(nodeNames.length, greaterThan(20),
          reason: 'the assembly must expose the part families the palette names');
      final Set<String> parts = nodeNames
          .map(_normalizePartName)
          .where((String name) => name.isNotEmpty)
          .toSet();
      expect(parts.length, greaterThanOrEqualTo(16),
          reason: 'Qt dark() names 9 of these families, so the enum cannot shrink silently');

      final Set<String> tableHits = <String>{};
      final Set<String> defaultHits = <String>{};
      for (final String part in parts) {
        if (table.containsKey(part)) {
          tableHits.add(part);
        } else {
          expect(part.contains('Orange'), isFalse,
              reason: '$part would silently take the Orange fallback at night');
          defaultHits.add(part);
        }
      }
      for (final String shell in <String>[
        'Frosted_Polymer',
        'Ivory_Edges',
        'Optical_Diffuser',
        'Optical_Edges',
        'Subsurface_Optics',
        'Titanium_Fasteners',
        'Index_Inlay',
      ]) {
        expect(tableHits, contains(shell),
            reason: '$shell is a lit shell and must take the Qt dark colour, not a fallback');
      }
      // Qt has no table entry for the optical film (RhiScene.cpp:1427 falls back
      // to 0x969f9f), so the port must not invent one.
      expect(defaultHits, contains('Optical_Film'));
      expect(table.containsKey('Optical_Film'), isFalse);
    });

    test('theme 1 lands on the Qt dark colour, never on the live colour', () {
      final String body = _jsBlock(
          _stripJsComments(_read(_rendererPath)), 'function prepareMaterialTheme(material, part) {');
      expect(body,
          contains('material.rhineDarkColor = new THREE.Color().setHex(darkHexFor(part), '
              'THREE.SRGBColorSpace);'));
      expect(body,
          contains('material.color.copy(material.rhineDayColor).lerp(material.rhineDarkColor, theme);'));
      // Deriving dark from the live colour would pin day == dark on the second
      // prepare pass, which is exactly how a night pane silently stays day-lit.
      expect(body.contains('rhineDarkColor = material.color'), isFalse);
    });
  });

  // F6 — the pane read as a grey glass box because the shell kept Qt's day
  // transmission values. RhiScene::musicDraws() (RhiScene.cpp:1472-1571) zeroes
  // transmission for Frosted_Polymer / Ivory_Edges / Optical_Diffuser, paints
  // Titanium_Fasteners near-black and thins the optical film, and it runs on
  // every frame of whichever template is loaded (RhiScene.cpp:3525). The cull
  // stays the SceneAppearance card set because the export pruned the rest; the
  // cassette additionally drops its own Carbon_Ink through ALWAYS_SKIP_PARTS.
  group('both templates: draw-list cull and musicDraws rules', () {
    test('the assembly is culled by the SceneAppearance card set', () {
      // The export prunes Internal_Ceramic / Optical_Edges / Subsurface_Optics /
      // Optical_Film_Edge / Amber_Optical_Inlay before Qt loads the mesh
      // (scripts/export-assets.py:84-95); the shipped GLB still carries them, so
      // the card set — not musicDraws' shorter list — reproduces Qt's draws.
      final String js = _stripJsComments(_read(_rendererPath));
      final String loader = _jsBlock(js, 'function onModelLoaded(gltf) {');
      expect(loader, contains('const cullParts = HIDDEN_PARTS;'));
      expect(loader, contains('cullParts.indexOf(part) >= 0'));
      // The predicate has two arms: the card set and the Carbon_Ink skip. Pinning
      // only the first would let the ink layer render on the cassette while the
      // family-set test below stayed green, because that test reads the
      // constants rather than this condition (R3-M1).
      expect(loader, contains('|| ALWAYS_SKIP_PARTS.indexOf(part) >= 0'),
          reason: 'Carbon_Ink is culled by ALWAYS_SKIP_PARTS, not by HIDDEN_PARTS');
      expect(
          loader.contains('if (part && (cullParts.indexOf(part) >= 0 || '
              'ALWAYS_SKIP_PARTS.indexOf(part) >= 0))'),
          isTrue,
          reason: 'the traverse must keep both arms in one condition');
      expect(loader.contains('ASSEMBLY_CULL_PARTS'), isFalse,
          reason: 'a four-name list keeps six parts that Qt pruned at export (Optical_Edges x3, Subsurface_Optics, Optical_Film_Edge x2)');
      expect(loader.contains('HIDDEN_PARTS.indexOf(part)'), isFalse,
          reason: 'the traverse must read the binding declared right above it');

      final String appearance = _read('Qt/src/SceneAppearance.cpp');
      final RegExpMatch? hiddenBlock =
          RegExp(r'const QSet<QString> hidden\{([^}]*)\}').firstMatch(appearance);
      expect(hiddenBlock, isNotNull, reason: 'SceneAppearance.cpp:10-11 hidden set not found');
      final Set<String> qtHidden = RegExp(r'"([A-Za-z_]+)"')
          .allMatches(hiddenBlock!.group(1)!)
          .map((RegExpMatch match) => match.group(1)!)
          .toSet();
      expect(qtHidden.length, 7);
      expect(_jsStringList(js, 'const HIDDEN_PARTS = ['), qtHidden);
    });

    test('the export pruning is why the card set fits the assembly', () {
      final String exporter = _read('scripts/export-assets.py');
      for (final String pruned in <String>[
        'Carbon_Ink',
        'Optical_Film_Edge',
        'Internal_Ceramic',
        'Subsurface_Optics',
        'Optical_Edges',
        'Amber_Optical_Inlay',
      ]) {
        expect(exporter, contains('"$pruned"'),
            reason: '$pruned is dropped by the exporter, so Qt never draws it');
      }
      // Optical_Film is the one film family that survives both the export and
      // the draw list (SceneAppearance.cpp:8-9); culling it would flatten the
      // shell exactly the way the stale RhiScene comment warned about.
      expect(exporter.contains('"Optical_Film"'), isFalse);
      final String js = _stripJsComments(_read(_rendererPath));
      expect(_jsStringList(js, 'const HIDDEN_PARTS = [').contains('Optical_Film'), isFalse);
      expect(_jsStringList(js, 'const ALWAYS_SKIP_PARTS = ['), <String>{'Carbon_Ink'});
    });

    test('shells turn transmission off and stay opaque, as Qt bakes the frost', () {
      final String qt = _read(_rhiScenePath);
      expect(qt, contains('const bool shell ='));
      expect(qt, contains('d["transmission"] = 0;'));
      expect(qt, contains('d["side"] = d["instanced"].toBool() ? 0 : 2;'));

      final String rules = _jsBlock(
          _stripJsComments(_read(_rendererPath)), 'function applyMusicDrawRules(material, part) {');
      expect(rules, contains('ASSEMBLY_SHELL_PARTS.indexOf(part) >= 0'));
      expect(rules, contains('material.transmission = 0;'));
      expect(rules, contains('material.side = THREE.DoubleSide;'));
      expect(rules, contains('material.transparent = false;'));
      expect(rules, contains('material.depthWrite = true;'));
      expect(rules, contains('material.opacity = 1;'));
      // Without needsUpdate three keeps the previous transmission pipeline state.
      expect(rules, contains('material.needsUpdate = true;'));
    });

    test('fasteners take the baked near-black day colour', () {
      final String qt = _read(_rhiScenePath);
      expect(qt, contains('d["color"] = QJsonArray{0.065, 0.075, 0.08};'));

      final String js = _stripJsComments(_read(_rendererPath));
      final String constant = _jsBlock(js, 'const FASTENER_DAY_COLOR = {');
      expect(constant, contains('r: 0.065'));
      expect(constant, contains('g: 0.075'));
      expect(constant, contains('b: 0.08'));
      final String rules = _jsBlock(js, 'function applyMusicDrawRules(material, part) {');
      expect(rules, contains("part === 'Titanium_Fasteners'"));
      expect(rules, contains('THREE.LinearSRGBColorSpace'),
          reason: 'Qt writes linear floats, so the port must not re-encode them as sRGB');
    });

    test('the optical film stays a transparent, depth-write-off layer at 0.35', () {
      final String qt = _read(_rhiScenePath);
      expect(qt, contains('d["transparent"] = true;'));
      expect(qt, contains('d["depthWrite"] = false;'));
      expect(qt, contains('d["opacity"] = 0.35;'));

      final String js = _stripJsComments(_read(_rendererPath));
      final RegExpMatch? opacity = RegExp(r'const OPTICAL_FILM_OPACITY = ([\d.]+);').firstMatch(js);
      expect(opacity, isNotNull);
      expect(_d(opacity!.group(1)!), 0.35);

      final String rules = _jsBlock(js, 'function applyMusicDrawRules(material, part) {');
      expect(rules, contains("part.indexOf('Optical_Film') === 0"));
      expect(rules, contains("part.indexOf('Optical_Glass') === 0"));
      expect(rules, contains("part === 'Optical_Bridge_Glass'"));
      expect(rules, contains('material.opacity = OPTICAL_FILM_OPACITY;'));
    });

    test('both admitted models take the same draw rules', () {
      // RhiScene::update() computes musicDraws(frame) for every frame of
      // whichever template is loaded (RhiScene.cpp:3525); it never asks which
      // GLB is mounted. Gating the port on the assembly left the cassette with
      // its GLB transmission (0.9 / 0.65) and an opaque Optical_Film, which is
      // the grey-glass-box defect this group exists for.
      final String raw = _read(_rendererPath);
      final String js = _stripJsComments(raw);
      expect(js.contains('ASSEMBLY_MODEL'), isFalse,
          reason: 'a template-named constant is how the gate came back last time');
      expect(js.contains('modelKey ==='), isFalse);

      final String loader = _jsBlock(js, 'function onModelLoaded(gltf) {');
      final int callAt = loader.indexOf('applyMusicDrawRules(materials[i], part);');
      expect(callAt, greaterThanOrEqualTo(0));
      final int lineStart = loader.lastIndexOf('\n', callAt) + 1;
      final String callLine = loader.substring(lineStart, callAt).trim();
      expect(callLine, isEmpty,
          reason: 'the call must not be wrapped in a model condition: $callLine');
      expect(loader.contains('if (modelKey'), isFalse);

      // Both templates really are admitted, so the rule above is not vacuous.
      expect(js.contains("'Assets/models/archive-assembly.glb'"), isTrue);
      expect(js.contains("'Assets/models/archive-cassette.glb'"), isTrue);

      final String qt = _read(_rhiScenePath);
      expect(qt, contains('auto draws = musicDraws(frame);'));
      expect(qt.contains('musicDraws(frame) &&'), isFalse);
    });

    test('the shell branch reproduces only the unselected Qt arm', () {
      // Qt's shell branch forks on selectedShell = Frosted_Polymer &&
      // musicSelected (RhiScene.cpp:1500-1516). This preview has no selection
      // channel, so it may only implement the unselected arm; writing the
      // 0.20 / 0.62 / 0.14 opacities without a selection would misreport the
      // pane. The selected arm stays with the OptionB consumer work.
      final String qt = _read(_rhiScenePath);
      expect(qt, contains('const bool selectedShell = name == "Frosted_Polymer" && '
          'd["musicSelected"].toBool();'));
      expect(qt, contains('d["transparent"] = selectedShell;'));
      expect(qt, contains('d["depthWrite"] = !selectedShell;'));
      expect(qt, contains('opacity = detailMode ? 0.20 : 0.62;'));
      expect(qt, contains('opacity = 0.14;'));

      final String raw = _read(_rendererPath);
      final String rules = _jsBlock(
          _stripJsComments(raw), 'function applyMusicDrawRules(material, part) {');
      expect(rules, contains('material.transparent = false;'));
      expect(rules, contains('material.depthWrite = true;'));
      expect(rules, contains('material.opacity = 1;'));
      for (final String selectedValue in <String>['0.20', '0.62', '0.14']) {
        expect(rules.contains(selectedValue), isFalse,
            reason: 'selected-shell opacity $selectedValue must not appear '
                'without a musicSelected input');
      }
      // The absence is documented where a reader will look for it.
      expect(raw, contains('musicSelected'));
      expect(raw, contains('RhiScene.cpp:1501-1516'));
    });

    test('both models cull to the same visible family set', () {
      // The cull is the SceneAppearance card set for every template
      // (renderer.js:669-680), so the cassette drops its own Carbon_Ink and the
      // seven pruned families while keeping Optical_Film, exactly like the
      // assembly. This mirror reads the shipped GLB node names and applies the
      // renderer's own predicate; it does not execute three.js's traverse, and
      // per-node multiplicity (Optical_Edges x3, Case_Engraving_Highlight x2) is
      // therefore deliberately not asserted.
      const Set<String> familyVocabulary = <String>{
        'Frosted_Polymer',
        'Ivory_Edges',
        'Optical_Diffuser',
        'Optical_Film',
        'Index_Inlay',
        'Case_Engraving',
        'Case_Engraving_Highlight',
        'Titanium_Fasteners',
        'Moulded_Lettering',
        'Internal_Ceramic',
        'Optical_Edges',
        'Subsurface_Optics',
        'Optical_Film_Edge',
        'Amber_Optical_Inlay',
        'Champagne_Index',
        'Printed_Label',
        'Carbon_Ink',
      };
      const Set<String> visibleFamilies = <String>{
        'Frosted_Polymer',
        'Ivory_Edges',
        'Optical_Diffuser',
        'Optical_Film',
        'Index_Inlay',
        'Case_Engraving',
        'Case_Engraving_Highlight',
        'Titanium_Fasteners',
        'Moulded_Lettering',
      };

      final String js = _stripJsComments(_read(_rendererPath));
      final Set<String> hidden = _jsStringList(js, 'const HIDDEN_PARTS = [');
      final Set<String> alwaysSkip = _jsStringList(js, 'const ALWAYS_SKIP_PARTS = [');

      // Every shipped node is 'carrier__Name.012' style, so normalising gives
      // the family directly. Nothing is filtered by the vocabulary here: a
      // family that a future GLB adds must fail this test instead of being
      // silently dropped by the mirror (R3-S4).
      Set<String> familiesIn(String model) => _glbNodeNames(model)
          .map(_normalizePartName)
          .where((String name) => name.isNotEmpty)
          .toSet();

      final Set<String> assembly = familiesIn('Assets/models/archive-assembly.glb');
      final Set<String> cassette = familiesIn('Assets/models/archive-cassette.glb');

      expect(assembly.difference(familyVocabulary), isEmpty,
          reason: 'classify every family the assembly ships');
      expect(cassette.difference(familyVocabulary), isEmpty,
          reason: 'classify every family the cassette ships');

      // Raw families: the cassette carries Carbon_Ink, the assembly does not.
      expect(assembly, familyVocabulary.difference(<String>{'Carbon_Ink'}));
      expect(cassette, familyVocabulary);

      Set<String> visible(Set<String> families) =>
          families.difference(hidden).difference(alwaysSkip);
      expect(visible(assembly), visibleFamilies);
      expect(visible(cassette), visibleFamilies,
          reason: 'the cassette keeps Optical_Film and loses Carbon_Ink');
      // The difference between the two models is real, not an artefact of the
      // mirror: exactly one extra family is culled for the cassette.
      expect(cassette.difference(assembly), <String>{'Carbon_Ink'});
      expect(hidden.intersection(visibleFamilies), isEmpty);
    });

    test('the rules run before the day/dark snapshot', () {
      final String loader = _jsBlock(
          _stripJsComments(_read(_rendererPath)), 'function onModelLoaded(gltf) {');
      final int rulesAt = loader.indexOf('applyMusicDrawRules(materials[i], part);');
      final int snapshotAt = loader.indexOf('prepareMaterialTheme(materials[i], part);');
      expect(rulesAt, greaterThanOrEqualTo(0));
      expect(snapshotAt, greaterThan(rulesAt),
          reason: 'the fastener day colour must be snapshotted after Qt replaces it');
    });
  });

  // F5 — the pane must move only when Qt would move it: no invented spin, and
  // the detail blend travels at Qt's own rate instead of snapping.
  group('Qt detail easing and the frame clock', () {
    final String js = _stripJsComments(_read(_rendererPath));
    final String update = _read('Qt/src/NativeSceneUpdate.cpp');

    test('the blend rate and the frame clamp are the Qt constants', () {
      expect(update, contains('const auto seconds = std::min(elapsed, 0.05);'));
      expect(update, contains('const auto blend = 1 - std::exp(-seconds * (m_reduced ? 35 : 2.8));'));

      final String clock = _jsBlock(js, 'function stepDetailBlend(now) {');
      expect(clock,
          contains('const seconds = Math.min(Math.max((now - previous) / 1000, 0), MAX_FRAME_SECONDS);'));
      expect(clock, contains('const blend = 1 - Math.exp(-seconds * DETAIL_BLEND_RATE);'));
      expect(js, contains('const DETAIL_BLEND_RATE = 2.8;'));
      expect(js, contains('const MAX_FRAME_SECONDS = 0.05;'));
      expect(clock, contains('const before = sceneDetailEased;'));
      // Without the snap the new return stays true forever, so the snap is what
      // makes the termination proof hold and it must stay asserted.
      expect(clock, contains('sceneDetailEased = sceneDetail;'));
      expect(clock,
          contains('return sceneDetailEased !== sceneDetail || sceneDetailEased !== before;'));
    });

    test('the eased value is what the pose and the fog read', () {
      final String applyView = _jsBlock(js, 'function applyView() {');
      expect(applyView, contains('const posedDetail = sceneDetailEased;'));
      expect(applyView, contains('computePose(viewWidth, viewHeight, posedDetail, ACTOR_POSITION);'));
      // Eased detail still drives the offset, while the mode is the discrete
      // gate Qt holds at zero for boot (Qt/src/NativeSceneCamera.cpp:100-101).
      expect(applyView, contains('applyArchiveLensShift(camera, sceneMode, posedDetail);'));
      expect(applyView, contains('lerp(5 - 4 * theme, -1, posedDetail)'));
      expect(applyView, contains('lerp(25 - 9 * theme, 12, posedDetail)'));
      // Reading the target here is exactly what made a mode switch snap.
      expect(applyView.contains(', sceneDetail,'), isFalse);
      expect(applyView.contains('theme, 12, sceneDetail)'), isFalse);
    });

    test('only the render is gated on the blend, the loop itself stays armed', () {
      final String loop = _jsBlock(js, 'function loop(now) {');
      // The rAF self-schedule is unconditional (it must survive an idle pane);
      // the GL work is what the settling flag gates.
      expect(loop, contains('window.requestAnimationFrame(loop);'));
      expect(loop.indexOf('window.requestAnimationFrame(loop);'),
          lessThan(loop.indexOf('if (!settling && !needsRender) return;')));
      expect(loop, contains('const settling = stepDetailBlend('));
      expect(loop, contains('if (!settling && !needsRender) return;'));
      expect(loop, contains('if (settling) applyView();'));
      expect(loop, contains('renderer.render(scene, camera);'));
      // Qt goes further and stops its render loop entirely after four stable
      // frames with nothing pending (Qt/src/Engine.cpp:1222-1225); this port only
      // stops drawing, which the title above already says.
      final String engine = _read('Qt/src/Engine.cpp');
      expect(engine, contains('m_stableFrames >= 4 && !scene.changed()'));
      expect(engine, contains('m_sceneSleeping = true;'));
    });

    test('nothing invented rotates the scene on a timer', () {
      expect(js.contains('setInterval'), isFalse);
      // The Qt disc clock (Engine.cpp:1231-1248) belongs to the CD label, which
      // this port has no geometry for; a rotation here would be invention.
      expect(js.contains('discAngle'), isFalse);
      expect(js.contains('rotation.y +='), isFalse);
      expect(js.contains('rotation.y -='), isFalse);
      expect(js.contains('modelRoot.rotation.z +='), isFalse);
      // Exactly two rAF references: the self-schedule inside loop() and the
      // single boot() kick that starts it.
      expect(RegExp(r'requestAnimationFrame').allMatches(js).length, 2);
    });

    test('a mode switch moves the target and lets the clock catch up', () {
      final String setMode = _jsBlock(js, 'setMode: function (mode) {');
      expect(setMode, contains('sceneMode = known;'));
      expect(setMode, contains("sceneDetail = known === 'detail' ? 1 : 0;"));
      expect(setMode, contains('applyView();'));
      // Still a target move, never a snap of the eased blend.
      expect(setMode.contains('sceneDetailEased ='), isFalse);
      final String setScene = _jsBlock(js, 'setScene: function (next) {');
      expect(setScene.contains('sceneDetailEased ='), isFalse);
    });
  });
}

/// Mirrors normalizePartName() in web/basic_preview/renderer.js:316-332 so the
/// asset test resolves node names exactly the way the renderer does.
String _normalizePartName(String raw) {
  String name = raw.trim();
  final int cut = name.lastIndexOf('__');
  if (cut >= 0) name = name.substring(cut + 2);
  final int dot = name.lastIndexOf('.');
  if (dot > 0) {
    final String tail = name.substring(dot + 1);
    if (tail.isNotEmpty && int.tryParse(tail) != null) name = name.substring(0, dot);
  }
  return name;
}

/// glTF binary layout: 12-byte header, then chunk 0 is the JSON chunk
/// (length at 12, type 'JSON' at 16, payload from 20).
List<String> _glbNodeNames(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  expect(bytes.length, greaterThan(20), reason: 'missing or truncated GLB: $path');
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'glTF');
  expect(String.fromCharCodes(bytes.sublist(16, 20)), 'JSON');
  final ByteData view = ByteData.sublistView(bytes);
  final int chunkLength = view.getUint32(12, Endian.little);
  final Map<String, dynamic> root =
      jsonDecode(utf8.decode(bytes.sublist(20, 20 + chunkLength))) as Map<String, dynamic>;
  final List<dynamic> nodes = (root['nodes'] as List<dynamic>?) ?? <dynamic>[];
  return nodes
      .map((dynamic node) => ((node as Map<String, dynamic>)['name'] as String?) ?? '')
      .where((String name) => name.isNotEmpty)
      .toList();
}

/// Extracts a JavaScript array of bare string literals, e.g.
/// const HIDDEN_PARTS = ['A', 'B']; — the balanced span is taken from '[' to
/// the first ']' because these lists never nest.
Set<String> _jsStringList(String source, String marker) {
  final int at = source.indexOf(marker);
  expect(at, greaterThanOrEqualTo(0), reason: 'missing renderer list: $marker');
  final int open = source.indexOf('[', at);
  final int close = source.indexOf(']', open);
  expect(close, greaterThan(open), reason: 'unterminated renderer list: $marker');
  return RegExp(r"'([A-Za-z_]+)'")
      .allMatches(source.substring(open, close + 1))
      .map((RegExpMatch match) => match.group(1)!)
      .toSet();
}
