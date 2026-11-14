// RUNTIME-97 atom F1 — cross-file contract for the live setScene transport.
//
// The three files below must agree on one payload; each of them can be correct
// in isolation while the pair is broken, which is exactly the failure this test
// exists to catch. Written only: this worktree forbids dart/flutter/gradle and
// no device is attached, so RED/GREEN are both unexecuted here.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/scene_preview.dart';

const String _dartPath = 'lib/basic/scene_preview.dart';
const String _kotlinPath =
    'android/app/src/main/kotlin/rhine/music/database/basic/BasicSceneView.kt';
const String _rendererPath = 'web/basic_preview/renderer.js';

String _read(String path) => File(path).readAsStringSync();

String _stripKotlinComments(String text) {
  final String noBlocks = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlocks.replaceAll(RegExp(r'//[^\n]*'), '');
}

String _stripJsComments(String text) {
  final String noBlocks = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlocks.replaceAll(RegExp(r'(^|[^:])//[^\n]*'), r'$1');
}

String _jsBlock(String source, String marker) {
  final int at = source.indexOf(marker);
  expect(at, greaterThanOrEqualTo(0), reason: 'missing renderer marker: $marker');
  final int start = source.indexOf('{', at);
  expect(start, greaterThanOrEqualTo(0), reason: 'no block after: $marker');
  int depth = 0;
  for (int index = start; index < source.length; index++) {
    final String ch = source[index];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(start, index + 1);
    }
  }
  return source.substring(start);
}

void main() {
  // The bridge group below drives the real binary messenger, which needs the
  // test binding (and the platform channels) installed before any test runs.
  TestWidgetsFlutterBinding.ensureInitialized();

  final String dart = _read(_dartPath);
  final String kotlin = _stripKotlinComments(_read(_kotlinPath));
  final String js = _stripJsComments(_read(_rendererPath));

  group('channel and method names agree across the three files', () {
    test('one channel name, one view type', () {
      expect(basicSceneChannel, 'rhine.music.database/basic_scene');
      expect(
        kotlin.contains('const val CHANNEL = "rhine.music.database/basic_scene"'),
        isTrue,
      );
      expect(dart.contains("const String basicSceneChannel ="),
          isTrue);
      expect(basicSceneViewType, 'rhine/basic_scene');
    });

    test('the per-view channel name is derived the same way on both sides', () {
      // One channel per platform view: the native suffix must be the same id
      // Dart appends, otherwise a mounted view would never hear its own pushes.
      expect(basicSceneChannelFor(7), 'rhine.music.database/basic_scene/7');
      // Raw strings: the literals themselves contain Dart interpolation syntax.
      expect(
        dart.contains(
          r"String basicSceneChannelFor(int viewId) => '$basicSceneChannel/$viewId';",
        ),
        isTrue,
      );
      expect(
        kotlin.contains(
          r'fun channelName(viewId: Int): String = "${BasicSceneView.CHANNEL}/$viewId"',
        ),
        isTrue,
      );
      expect(
        kotlin.contains(
          'MethodChannel(messenger, BasicSceneAssets.channelName(viewId))',
        ),
        isTrue,
      );
      // The shared literal stays the base of both sides.
      expect(basicSceneChannel, 'rhine.music.database/basic_scene');
    });

    test('Dart sends setScene and Kotlin answers it', () {
      expect(dart.contains("channelFor(viewId).invokeMethod<void>('setScene'"),
          isTrue);
      expect(kotlin.contains('"setScene" -> {'), isTrue);
      // An unhandled method would fall through Kotlin's else branch and come
      // back as a MissingPluginException instead of a silent success.
      expect(kotlin.contains('result.notImplemented()'), isTrue);
    });

    test('the payload keys are the ones the renderer consumes', () {
      for (final String key in <String>['viewId', 'theme', 'mode']) {
        expect(dart.contains("'$key'"), isTrue, reason: 'Dart never sends $key');
        expect(kotlin.contains('"$key"'), isTrue, reason: 'Kotlin never reads $key');
      }
      final String bridge = _jsBlock(js, 'setScene: function (next) {');
      expect(bridge.contains('next.theme'), isTrue);
      expect(bridge.contains('next.mode'), isTrue);
      // viewId is transport-only: the page has one scene and must not trust it.
      expect(bridge.contains('next.viewId'), isFalse);
    });
  });

  group('mode vocabulary is identical everywhere', () {
    test('all three spellings exist in Dart, Kotlin and the renderer', () {
      expect(basicSceneArchiveMode, 'archive');
      expect(basicSceneDetailMode, 'detail');
      // Boot is a real Qt mode (Qt/src/NativeScene.cpp:165-198) and the phase
      // the HUD actually mounts at (lib/basic/basic_models.dart:451), so it
      // has to be spellable on all three sides of the bridge.
      expect(basicSceneBootMode, 'boot');
      expect(kotlin.contains('const val MODE_ARCHIVE = "archive"'), isTrue);
      expect(kotlin.contains('const val MODE_DETAIL = "detail"'), isTrue);
      expect(kotlin.contains('const val MODE_BOOT = "boot"'), isTrue);
      final String setMode = _jsBlock(js, 'setMode: function (mode) {');
      expect(setMode.contains('resolveSceneMode(mode)'), isTrue);
      final String setScene = _jsBlock(js, 'setScene: function (next) {');
      expect(setScene.contains('resolveSceneMode(next.mode)'), isTrue);
      // One resolver owns the page-side vocabulary, so a fourth spelling
      // cannot enter through a single entry point and be ignored elsewhere.
      final String resolver = _jsBlock(js, 'function resolveSceneMode(value) {');
      expect(resolver.contains("value === 'boot'"), isTrue);
      expect(resolver.contains("value === 'archive'"), isTrue);
      expect(resolver.contains("value === 'detail'"), isTrue);
      expect(resolver.contains('return null;'), isTrue);
    });

    test('an unknown mode degrades to the archive framing, never to boot', () {
      final String normalize =
          _blockOf(kotlin, 'fun normalizeMode(value: Any?): String =');
      expect(normalize.contains('MODE_BOOT -> MODE_BOOT'), isTrue);
      expect(normalize.contains('MODE_DETAIL -> MODE_DETAIL'), isTrue);
      expect(normalize.contains('else -> MODE_ARCHIVE'), isTrue);
      // The fallback is the archive page (Qt/src/NativeApplication.cpp:56 ->
      // NativeScene.cpp:188), never the boot framing: a malformed string must
      // not silently enable boot, which is what this atom exists to fix.
      expect(normalize.contains('else -> MODE_BOOT'), isFalse);
      expect(
        BasicSceneCreationParams.fromMap(<Object?, Object?>{'mode': 'loading'}).mode,
        basicSceneArchiveMode,
      );
      expect(
        BasicSceneCreationParams.fromMap(<Object?, Object?>{'mode': 'boot'}).mode,
        basicSceneBootMode,
      );
    });
  });

  group('the initial URL carries what creationParams carry', () {
    test('startUrl emits model, yaw, theme, the detail flag and the mode', () {
      final String startUrl = _blockOf(kotlin, 'fun startUrl(');
      expect(startUrl.contains(r'?model=$model&yaw='), isTrue);
      expect(startUrl.contains('&theme='), isTrue);
      expect(startUrl.contains(r'&detail=$detail'), isTrue);
      expect(startUrl.contains('if (resolved == MODE_DETAIL) 1 else 0'), isTrue);
      // boot and archive both ride at detail 0 (Qt/src/NativeSceneCamera.cpp:101
      // separates them by mode, not by the blend), so the URL has to carry the
      // resolved mode as well or the page cannot tell the two apart.
      expect(startUrl.contains('val resolved = normalizeMode(mode)'), isTrue);
      expect(startUrl.contains(r'&mode=$resolved'), isTrue);
      expect(startUrl.contains('&mode=boot'), isFalse,
          reason: 'the URL must not hard-code the boot framing');
      // The same fields must be the ones the Dart side hands over once.
      final Map<String, Object?> created = const BasicSceneCreationParams(
        songId: 's',
        albumId: 'a',
        theme: 0.4,
        mode: basicSceneDetailMode,
      ).toMap();
      expect(created['theme'], 0.4);
      expect(created['mode'], basicSceneDetailMode);
    });

    test('the page reads detail and mode from the query with archive defaults', () {
      expect(js.contains("query.get('detail')"), isTrue);
      expect(js.contains("finiteNumber(query.get('detail'), 0)"), isTrue);
      expect(js.contains("query.get('mode')"), isTrue);
      expect(js.contains("resolveSceneMode(query.get('mode')) || 'archive'"), isTrue);
      // An absent mode keeps the archive framing; boot is opt-in only.
      expect(js.contains("resolveSceneMode(query.get('mode')) || 'boot'"), isFalse);
    });

    test('the mode is decoded from the creation args before the first load', () {
      final int decodeAt = kotlin.indexOf('private var mode: String =');
      final int loadAt = kotlin.indexOf('webView.loadUrl(BasicSceneAssets.startUrl(');
      expect(decodeAt, greaterThanOrEqualTo(0));
      expect(loadAt, greaterThanOrEqualTo(0));
      expect(loadAt, greaterThan(decodeAt),
          reason: 'the view must know its mode before it builds the initial URL');
      expect(kotlin.contains('BasicSceneAssets.normalizeMode(argsMap["mode"])'), isTrue);
    });
  });

  group('numbers cross the bridge deterministically', () {
    test('Kotlin formats with Locale.US so the JS Number() parse cannot drift', () {
      expect(kotlin.contains('Locale.US'), isTrue);
      expect(kotlin.contains('"%.6f"'), isTrue);
    });

    test('the renderer clamps the theme it receives', () {
      final String setScene = _jsBlock(js, 'setScene: function (next) {');
      expect(setScene.contains('clamp01(value)'), isTrue);
      expect(setScene.contains('Number.isFinite(value)'), isTrue);
    });
  });

// ---------------------------------------------------------------------
  // ATOM2: the native host's half of the readiness contract.
  //
  // The widget group proves the Dart side; the Kotlin side cannot run here, so
  // its shape is pinned: hold the newest theme/mode until the page is ready,
  // then replay once on the UI thread instead of reloading the WebView.
  // ---------------------------------------------------------------------
  group('the native host replays instead of reloading', () {
    test('readiness is remembered, and pushes wait for it', () {
      expect(kotlin.contains('private var sceneReady = false'), isTrue);
      expect(kotlin.contains('private var pendingSceneReplay = false'), isTrue);
      expect(kotlin.contains('if (sceneReady) {'), isTrue);
      expect(kotlin.contains('pendingSceneReplay = true'), isTrue);
      expect(kotlin.contains('private fun pushScene()'), isTrue);
      expect(kotlin.contains('private fun replayPendingScene()'), isTrue);
      expect(kotlin.contains('if (!pendingSceneReplay) return'), isTrue);
    });

    test('the replay runs on the UI thread before ready reaches Dart', () {
      final String dispatch =
          _blockOf(kotlin, 'private fun dispatch(type: String, payload: Map<String, Any?>)');
      final int post = dispatch.indexOf('mainHandler.post {');
      final int replay = dispatch.indexOf('replayPendingScene()');
      final int invoke = dispatch.indexOf('channel?.invokeMethod(type, outgoing)');
      expect(post, greaterThanOrEqualTo(0));
      // evaluateJavascript is illegal on the JS bridge thread that reports
      // ready, so the replay may only happen inside the posted block.
      expect(replay, greaterThan(post));
      expect(invoke, greaterThan(replay));
    });

    test('setScene never reloads or remounts the page', () {
      final String setScene = _blockOf(kotlin, '"setScene" -> {');
      expect(setScene.contains('loadUrl'), isFalse);
      expect(setScene.contains('reload()'), isFalse);
      expect(setScene.contains('pushScene()'), isTrue);
      // A wrong target is a caller bug, not a silent no-op.
      expect(setScene.contains('wrong_view'), isTrue);
      expect(setScene.contains('result.success(null)'), isTrue,
          reason: 'the addressed view still reports success');
    });
  });

  // ---------------------------------------------------------------------
  // ATOM2: the real binary messenger, not a source grep.
  //
  // Everything above reads the three files as text. That cannot tell whether
  // two mounted views actually end up on two channel names, so this group
  // drives the same messenger production uses and captures real payloads.
  // ---------------------------------------------------------------------
  group('the bridge routes each view over its own channel', () {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final Map<int, List<MethodCall>> outgoing = <int, List<MethodCall>>{};
    final Map<int, List<BasicSceneEvent>> received =
        <int, List<BasicSceneEvent>>{};

    void mockChannel(int viewId) {
      outgoing.putIfAbsent(viewId, () => <MethodCall>[]);
      messenger.setMockMethodCallHandler(
        MethodChannel(basicSceneChannelFor(viewId)),
        (MethodCall call) async {
          outgoing[viewId]!.add(call);
          return null;
        },
      );
    }

    Future<void> deliver(
      int viewId,
      String method, [
      Map<String, Object?> payload = const <String, Object?>{},
    ]) async {
      await messenger.handlePlatformMessage(
        basicSceneChannelFor(viewId),
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, <String, Object?>{'viewId': viewId, ...payload}),
        ),
        (ByteData? data) {},
      );
    }

    setUp(() {
      outgoing.clear();
      received.clear();
      BasicSceneBridge.detachAll();
      mockChannel(101);
      mockChannel(202);
    });

    tearDown(() {
      BasicSceneBridge.detachAll();
      for (final int viewId in <int>[101, 202, 303]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(basicSceneChannelFor(viewId)),
          null,
        );
      }
    });

    test('setScene reaches only the view it names', () async {
      await BasicSceneBridge.applyScene(101, <String, Object?>{'theme': 0.5});
      expect(outgoing[101]!.length, 1);
      expect(outgoing[101]!.single.method, 'setScene');
      expect(outgoing[101]!.single.arguments, <String, Object?>{
        'viewId': 101,
        'theme': 0.5,
      });
      // The second view is mounted the whole time and must stay untouched.
      expect(outgoing[202], isEmpty);

      await BasicSceneBridge.applyScene(202, <String, Object?>{'mode': 'boot'});
      expect(outgoing[101]!.length, 1);
      expect(outgoing[202]!.single.arguments, <String, Object?>{
        'viewId': 202,
        'mode': 'boot',
      });
    });

    test('an event on one view channel never reaches another listener',
        () async {
      BasicSceneBridge.attach(101, (BasicSceneEvent event) {
        received.putIfAbsent(101, () => <BasicSceneEvent>[]).add(event);
      });
      BasicSceneBridge.attach(202, (BasicSceneEvent event) {
        received.putIfAbsent(202, () => <BasicSceneEvent>[]).add(event);
      });

      await deliver(101, 'ready', <String, Object?>{'meshes': 10});
      expect(received[101]!.single.meshCount, 10);
      expect(received.containsKey(202), isFalse);

      await deliver(202, 'yaw', <String, Object?>{'radians': 1.5});
      expect(received[202]!.single.yawRadians, closeTo(1.5, 1e-9));
      expect(received[101]!.length, 1);
    });

    test('detach stops delivery for that view and only that view', () async {
      final List<BasicSceneEvent> a = <BasicSceneEvent>[];
      final List<BasicSceneEvent> b = <BasicSceneEvent>[];
      BasicSceneBridge.attach(101, a.add);
      BasicSceneBridge.attach(202, b.add);

      // The old view is torn down while the new one keeps its handler.
      BasicSceneBridge.detach(101);
      await deliver(101, 'ready');
      await deliver(202, 'ready');
      expect(a, isEmpty);
      expect(b.length, 1);
    });

    test('an undeliverable update fails loudly instead of reporting success',
        () async {
      messenger.setMockMethodCallHandler(
        MethodChannel(basicSceneChannelFor(101)),
        (MethodCall call) async {
          throw PlatformException(code: 'renderer_gone', message: 'gone');
        },
      );
      await expectLater(
        BasicSceneBridge.applyScene(101, <String, Object?>{'theme': 0.1}),
        throwsA(isA<PlatformException>()),
      );

      // No handler at all (the view never registered, or was already gone).
      await expectLater(
        BasicSceneBridge.applyScene(303, <String, Object?>{'theme': 0.1}),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });
}

/// Returns the balanced body that follows [marker]: either the next '{...}'
/// block or, for an expression-bodied declaration, the text up to the next
/// blank line.
String _blockOf(String source, String marker) {
  final int at = source.indexOf(marker);
  expect(at, greaterThanOrEqualTo(0), reason: 'missing marker: $marker');
  final int brace = source.indexOf('{', at);
  final int newline = source.indexOf('\n\n', at);
  if (brace >= 0 && (newline < 0 || brace < newline + 2)) {
    int depth = 0;
    for (int index = brace; index < source.length; index++) {
      final String ch = source[index];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(at, index + 1);
      }
    }
  }
  return source.substring(at, newline < 0 ? source.length : newline);
}
