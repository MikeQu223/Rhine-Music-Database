import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/basic_settings.dart';
import 'package:rhine_music_database/basic/basic_settings_store.dart';
import 'package:rhine_music_database/basic/basic_settings_view.dart';
import 'package:rhine_music_database/basic/basic_settings_window.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';

/// 播放端口替身：只记录 dispose，播放方法全部是空操作。
class _FakeAudio implements BasicAudioPort {
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];
  int disposes = 0;
  final BasicAudioState _state = BasicAudioState.idle;

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function(BasicAudioState) listener) {
    _listeners.remove(listener);
  }

  @override
  Future<void> prepare(String url, {required int generation}) async {}

  @override
  Future<void> play({required int generation}) async {}

  @override
  Future<void> pause({required int generation}) async {}

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposes += 1;
  }
}

/// 外壳测试用的 controller：不真的起 ticker / 读网络曲库。
class _ShellController extends BasicController {
  _ShellController({required _FakeAudio audio}) : super(audio: audio);

  int bootCalls = 0;

  @override
  Future<void> boot() async {
    bootCalls += 1;
  }
}

class _StubGlyphBundle extends AssetBundle {
  static const String _glyphTable =
      '{"light":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{}}}';

  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('测试资源包没有字体文件 $key');
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key == basicGlyphTableAsset) {
      return _glyphTable;
    }
    if (key == basicLetteringAsset) {
      return '{}';
    }
    throw FlutterError('测试资源包缺少 $key');
  }
}

/// 外壳 + 真端口：设置页的动作走的是产品里那条唯一链路
/// （命中串 -> typed 命令 -> SharedPreferences 端口 -> controller/场景）。
Future<({_ShellController controller, MemoryBasicSettingsPort port})> pumpShell(
  WidgetTester tester, {
  Map<String, String> values = const <String, String>{},
  BasicSettingsPackageInfo package = BasicSettingsPackageInfo.unknown,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final _FakeAudio audio = _FakeAudio();
  final _ShellController controller = _ShellController(audio: audio);
  final MemoryBasicSettingsPort port =
      MemoryBasicSettingsPort(values: values, package: package);
  await tester.pumpWidget(BasicApp(
    controller: controller,
    audio: audio,
    bundle: _StubGlyphBundle(),
    settingsPort: port,
  ));
  await tester.pump();
  await tester.pump();
  expect(find.byType(BasicHudSurface), findsOneWidget);
  return (controller: controller, port: port);
}

/// 走 HUD 的命中串打开设置页（chrome.dart:171 的真实命中就是 'settings'）。
///
/// m03428：设置窗口现在是真实 Flutter widget 层（BasicSettingsWindow），
/// 不再有 HUD 命中画布；这里返回窗口 widget 本身，行为断言仍走产品里那条
/// 唯一的 action 入口（BasicApp._onSettingsAction）。
Future<BasicSettingsWindow> openSettings(
  WidgetTester tester,
) async {
  tester.widget<BasicHudSurface>(find.byType(BasicHudSurface)).onAction('settings');
  await tester.pump();
  final Finder window = find.byType(BasicSettingsWindow);
  expect(window, findsOneWidget);
  return tester.widget<BasicSettingsWindow>(window);
}

Future<void> act(
  WidgetTester tester,
  BasicSettingsWindow window,
  String action,
) async {
  window.onAction(action);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('gear opens the ONLY14 panel with real rows and no rejected settings',
      (WidgetTester tester) async {
    await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    final List<String> ids = overlay.model.rowIds;
    // 14 项都在（展开子行前就是这 14 个顶层行/分组）。
    expect(ids, contains('theme'));
    expect(ids, contains('startup-animation'));
    expect(ids, contains('replay'));
    expect(ids, contains('detail-autoplay'));
    expect(ids, contains('single-play-mode'));
    expect(ids, contains('archive-mask'));
    expect(ids, contains('graphics-backend'));
    expect(ids, contains('vsync'));
    expect(ids, contains('render-scale'));
    // 唱片旋转/当前版本是 Qt 自定义区里的行（没有 descriptor），
    // 由 BasicSettingsPanelModel 的 discRotation / version 承载。
    expect(overlay.model.discRotation, isFalse);
    // 被否决的旧 Qt 项一个都不许出现。
    for (final String rejected in <String>[
      'official-player',
      'window',
      'close-behavior',
      'desktop-lyrics',
      'gpu-index',
      'fg',
    ]) {
      expect(ids, isNot(contains(rejected)), reason: rejected);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('appearance write persists and flips the real HUD dark state',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    expect(shell.controller.dark, isTrue, reason: '默认深色');

    final BasicSettingsWindow overlay = await openSettings(tester);
    await act(tester, overlay, 'setting:theme:light');

    // 真实落盘（bare panel key，PreferenceStore 自己加 panel/ 前缀）。
    expect(shell.port.values['panel/theme'], 'light');
    // 真实效果：controller 的深色开关被改，HUD 配色随之换。
    expect(shell.controller.dark, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('startup animation toggles persist and the manual replay really animates',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    await act(tester, overlay, 'setting:startup-animation:on');
    expect(shell.port.values['panel/startup-animation'], 'on');

    await act(tester, overlay, 'replay');
    await tester.pump(const Duration(milliseconds: 60));
    // 幕布真的在动：透明度不是 0 也不是 1，且还在走动画。
    final Iterable<Opacity> opacities = tester.widgetList<Opacity>(find.byType(Opacity));
    expect(
      opacities.any((Opacity o) => o.opacity > 0.0 && o.opacity < 1.0),
      isTrue,
      reason: '手动重放必须真的播一段可见动效，而不是只弹提示',
    );
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disc rotation needs the original warning; cancel writes nothing',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    await act(tester, overlay, 'disc-rotation');
    expect(find.byType(BasicDiscWarningOverlay), findsOneWidget);

    await act(tester, overlay, 'disc-rotation:cancel');
    expect(find.byType(BasicDiscWarningOverlay), findsNothing);
    expect(shell.port.values.containsKey('panel/disc-rotation'), isFalse);

    await act(tester, overlay, 'disc-rotation');
    await act(tester, overlay, 'disc-rotation:enable');
    expect(shell.port.values['panel/disc-rotation'], 'on');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('project link opens the real URL through the platform port',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    await act(tester, overlay, 'music:project-lyricsx');
    expect(shell.port.openedUrls, <String>[
      'https://github.com/MxIris-LyricsX-Project/LyricsX',
    ]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('single play mode append reaches the controller queue semantics',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    expect(shell.controller.singlePlayAppend, isFalse, reason: '默认 replace');
    await act(tester, overlay, 'setting:single-play-mode:append');
    expect(shell.port.values['panel/single-play-mode'], 'append');
    expect(shell.controller.singlePlayAppend, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('detail autoplay write reaches the controller, and stays independent',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    expect(shell.controller.detailAutoplay, isFalse);
    await act(tester, overlay, 'setting:detail-autoplay:on');
    expect(shell.port.values['panel/detail-autoplay'], 'on');
    expect(shell.controller.detailAutoplay, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed write says so and keeps the previous value visible',
      (WidgetTester tester) async {
    final _FakeAudio audio = _FakeAudio();
    final _ShellController controller = _ShellController(audio: audio);
    final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(failWrites: true);
    await tester.pumpWidget(BasicApp(
      controller: controller,
      audio: audio,
      bundle: _StubGlyphBundle(),
      settingsPort: port,
    ));
    await tester.pump();
    await tester.pump();

    final BasicSettingsWindow overlay = await openSettings(tester);
    await act(tester, overlay, 'setting:theme:light');

    expect(controller.dark, isTrue, reason: '写失败不许假装改成浅色');
    expect(find.textContaining('写入失败'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('graphics backend keeps requested vs effective and promises next launch',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester, values: <String, String>{'panel/graphics-backend': 'vulkan'});
    final BasicSettingsWindow overlay = await openSettings(tester);

    await act(tester, overlay, 'setting:graphics-backend:opengl');
    expect(shell.port.values['panel/graphics-backend'], 'opengl');
    // 本次运行仍然是启动时那套（vulkan）：重启口径不许当场改口。
    expect(find.textContaining('下次启动生效'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render scale, AA and vsync write their real panel keys',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);

    // Android 的默认渲染分辨率就是 75（SettingsSchema.cpp:566 的
    // androidDefaultRenderScale），写回 75 属于 unchanged，所以这里选 90。
    await act(tester, overlay, 'render-scale:75');
    expect(shell.port.values.containsKey('panel/render-scale'), isFalse);
    await act(tester, overlay, 'render-scale:90');
    expect(shell.port.values['panel/render-scale'], '90');

    // 开关型 hudState 行（垂直同步）在面板里是**裸动作**切换，Qt 侧就是这样
    // toggle 的（NativeHudController.cpp:46/860-880）；不存在 'vsync:off' 这种串。
    await act(tester, overlay, 'vsync');
    expect(shell.port.values['panel/vsync'], 'off');

    // Android 上 AA 档位里没有 MetalFX（那是 Darwin 专用），选 fxaa 才是真值。
    await act(tester, overlay, 'aa-mode:fxaa');
    expect(shell.port.values['panel/aa-mode'], 'fxaa');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('system back closes the open panel instead of leaving the app',
      (WidgetTester tester) async {
    await pumpShell(tester);
    await openSettings(tester);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(BasicSettingsOverlay), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('IME never resizes the stage: Scaffold keeps its body and manifest is adjustNothing',
      (WidgetTester tester) async {
    await pumpShell(tester);
    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.resizeToAvoidBottomInset, isFalse);

    // Manifest 与 Dart 侧必须一致（否则窗口仍会被系统压缩）。
    final String manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest.contains('android:windowSoftInputMode="adjustNothing"'), isTrue);
    expect(manifest.contains('adjustResize'), isFalse);

    // 键盘弹出（viewInsets）不许改变舞台几何。
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pump();
    final Scaffold after = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(after.resizeToAvoidBottomInset, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the panel survives rotation: same runtime, same persisted values, panel open',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    final BasicSettingsWindow overlay = await openSettings(tester);
    await act(tester, overlay, 'archive-mask:80');
    expect(shell.port.values['panel/archive-mask-strength'], '80');

    // 转竖屏：面板仍在，且写进去的值还在（不是重建后回到默认）。
    tester.view.physicalSize = const Size(1080, 1920);
    await tester.pump();
    await tester.pump();
    expect(find.byType(BasicSettingsWindow), findsOneWidget);
    final BasicSettingsWindow rotated =
        tester.widget<BasicSettingsWindow>(find.byType(BasicSettingsWindow));
    expect(rotated.portrait, isTrue);
    expect(rotated.model.rowIds, contains('archive-mask'));
    expect(shell.port.values['panel/archive-mask-strength'], '80');

    await tester.pumpWidget(const SizedBox());
  });
}
