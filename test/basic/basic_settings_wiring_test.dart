import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/basic_settings_store.dart';
import 'package:rhine_music_database/basic/basic_settings_view.dart';
import 'package:rhine_music_database/basic/basic_settings_window.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/hud/modals/disc_warning_modal.dart';
import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/modals/settings_modal.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/widgets/settings_row.dart';

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

  /// 键盘门要的是「启动完成后的 HUD」，不是 boot 幕布：frameEmpty 时
  /// HudKeyRouter.key 首门直接返回未消费（Qt :888-890），模拟启动态即可。
  BasicViewState? stateOverride;

  @override
  BasicViewState get state => stateOverride ?? super.state;

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
  bool failWrites = false,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final _FakeAudio audio = _FakeAudio();
  final _ShellController controller = _ShellController(audio: audio);
  final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(
    values: values,
    package: package,
    failWrites: failWrites,
  );
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
Future<BasicSettingsWindow> openSettings(WidgetTester tester) async {
  tester.widget<BasicHudSurface>(find.byType(BasicHudSurface)).onAction('settings');
  await tester.pump();
  final Finder window = find.byType(BasicSettingsWindow);
  expect(window, findsOneWidget);
  return tester.widget<BasicSettingsWindow>(window);
}

// ---------------------------------------------------------------------------
// LEAF-159 MUST-2：这里所有交互都点**真实控件**（InkWell / GestureDetector /
/// Semantic 命中的真实 Rect），不再把动作串直接塞进 onAction 回调。
// ---------------------------------------------------------------------------

Finder rowControl(String id) =>
    find.byKey(ValueKey<String>(basicSettingsControlKey(id)));

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// 把控件滚进视口再点它（面板是真实 SingleChildScrollView，视口外的控件点不到）。
Future<void> tapVisible(
  WidgetTester tester,
  Finder target, {
  required String what,
}) async {
  expect(target, findsOneWidget, reason: what);
  await tester.ensureVisible(target);
  await settle(tester);
  await tester.tap(target);
  await settle(tester);
}

/// 点开一行；如果是 choice 行，展开后再点指定的那个真实选项控件。
/// 返回是否真的点到了展开出来的选项（false = 这一次点击本身就是动作）。
Future<bool> activate(
  WidgetTester tester,
  String id,
  String? value,
) async {
  await tapVisible(tester, rowControl(id), what: '设置行 $id 的控件');
  if (value == null) {
    return false;
  }
  final Finder option = rowControl('$id-$value');
  if (option.evaluate().isEmpty) {
    return false;
  }
  await tapVisible(tester, option, what: '设置行 $id 的选项 $value');
  return true;
}

/// stepper：点轨道上某一档的真实命中区块（每档都是独立的 GestureDetector）。
Future<void> setStep(WidgetTester tester, String id, int value) async {
  await tapVisible(
    tester,
    find.byKey(ValueKey<String>('settings-notch-$id-$value')),
    what: 'stepper $id 的档位 $value',
  );
}

/// 唱片旋转风险弹层是 HUD 命中矩形（与 Qt 同一张表）：按真实命中 Rect 点它。
Future<void> tapWarning(WidgetTester tester, String action) async {
  final BasicDiscWarningOverlay overlay =
      tester.widget<BasicDiscWarningOverlay>(find.byType(BasicDiscWarningOverlay));
  final BasicSettingsSink sink = BasicSettingsSink();
  final ModalShellResult shell =
      DiscWarningModal(width: overlay.stage.width, dark: overlay.dark)
          .build(sink, overlay.ports);
  final HudHit hit = shell.hits.lastWhere((HudHit h) => h.action == action);
  final Rect rect = tester.getRect(find.byType(BasicDiscWarningOverlay));
  final double scale = overlay.stage.scale > 0 ? overlay.stage.scale : 1.0;
  await tester.tapAt(rect.topLeft +
      Offset((hit.x + hit.width / 2) * scale, (hit.y + hit.height / 2) * scale));
  await settle(tester);
}

void main() {
  testWidgets('键盘上下键真的滚动面板（161 MUST-B1：偏移不再是死字段）',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    shell.controller.stateOverride = BasicViewState(
      phase: BasicPhase.library,
      catalogLoaded: true,
    );
    await tester.pump();
    await openSettings(tester);
    // 面板打开后 postFrame 才会把真实 maxScrollExtent 公布给外壳。
    await tester.pump();
    await tester.pump();

    final Finder firstRow = find.text('界面配色');
    final double before = tester.getTopLeft(firstRow).dy;

    // NativeHudController.cpp:891-897 的 settings 分支：每步 66 逻辑像素。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final double oneStep = tester.getTopLeft(firstRow).dy;
    expect(oneStep, lessThan(before));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final double twoSteps = tester.getTopLeft(firstRow).dy;
    expect(twoSteps, lessThan(oneStep));
    // 两步位移相同（66 逻辑像素/步，按舞台缩放折算），且不是被吞掉的 0。
    expect((oneStep - before) - (twoSteps - oneStep), closeTo(0, 0.5));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.getTopLeft(firstRow).dy, closeTo(oneStep, 0.5));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gear opens the ONLY14 panel with real rows and no rejected settings',
      (WidgetTester tester) async {
    await pumpShell(tester);
    final BasicSettingsWindow window = await openSettings(tester);

    final List<String> ids = window.model.rowIds;
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
    expect(window.model.discRotation, isFalse);
    // 窗口是真实 widget 树：框架/行/控件/滚动/语义都在，不是命中画布。
    expect(find.byKey(basicSettingsWindowKey), findsOneWidget);
    expect(find.byType(BasicSettingsOverlay), findsNothing);
    // 每一行不是都有控件 widget：项目链接是整块网格项、custom 行由
    // 自定义区承载（唱片旋转/版本），其余行都必须有真控件。
    for (final SettingsSectionModel section in window.model.sections) {
      for (final SettingsRowSpec row in section.rows) {
        if (row.kind == SettingsRowKind.link ||
            row.kind == SettingsRowKind.custom) {
          continue;
        }
        expect(rowControl(row.id), findsOneWidget,
            reason: '缺少真实控件：${row.id} (${row.kind})');
      }
    }
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.byType(InkWell), findsWidgets);
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

    await openSettings(tester);
    expect(await activate(tester, 'theme', 'light'), isTrue,
        reason: '配色是 choice 行，必须点开再点真实选项');

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
    await openSettings(tester);

    await activate(tester, 'startup-animation', 'on');
    expect(shell.port.values['panel/startup-animation'], 'on');

    await tapVisible(tester, rowControl('replay'), what: '手动重放动作行');
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
    await openSettings(tester);

    await tapVisible(tester, rowControl('disc-rotation'), what: '唱片旋转开关');
    expect(find.byType(BasicDiscWarningOverlay), findsOneWidget);

    await tapWarning(tester, 'disc-rotation:cancel');
    expect(find.byType(BasicDiscWarningOverlay), findsNothing);
    expect(shell.port.values.containsKey('panel/disc-rotation'), isFalse);

    await tapVisible(tester, rowControl('disc-rotation'), what: '唱片旋转开关');
    await tapWarning(tester, 'disc-rotation:enable');
    expect(shell.port.values['panel/disc-rotation'], 'on');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('project link opens the real URL through the platform port',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    await openSettings(tester);

    await tapVisible(tester, rowControl('project-lyricsx'), what: '项目链接行');
    expect(shell.port.openedUrls, <String>[
      'https://github.com/MxIris-LyricsX-Project/LyricsX',
    ]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('single play mode append reaches the controller queue semantics',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    await openSettings(tester);

    expect(shell.controller.singlePlayAppend, isFalse, reason: '默认 replace');
    expect(await activate(tester, 'single-play-mode', 'append'), isTrue);
    expect(shell.port.values['panel/single-play-mode'], 'append');
    expect(shell.controller.singlePlayAppend, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('detail autoplay write reaches the controller, and stays independent',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    await openSettings(tester);

    expect(shell.controller.detailAutoplay, isFalse);
    await activate(tester, 'detail-autoplay', 'on');
    expect(shell.port.values['panel/detail-autoplay'], 'on');
    expect(shell.controller.detailAutoplay, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed write says so and keeps the previous value visible',
      (WidgetTester tester) async {
    final _FakeAudio audio = _FakeAudio();
    final _ShellController controller = _ShellController(audio: audio);
    final MemoryBasicSettingsPort port =
        MemoryBasicSettingsPort(failWrites: true);
    await tester.pumpWidget(BasicApp(
      controller: controller,
      audio: audio,
      bundle: _StubGlyphBundle(),
      settingsPort: port,
    ));
    await tester.pump();
    await tester.pump();

    await openSettings(tester);
    await activate(tester, 'theme', 'light');

    expect(controller.dark, isTrue, reason: '写失败不许假装改成浅色');
    expect(find.textContaining('写入失败'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('graphics backend keeps requested vs effective and promises next launch',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester,
            values: <String, String>{'panel/graphics-backend': 'vulkan'});
    await openSettings(tester);

    expect(await activate(tester, 'graphics-backend', 'opengl'), isTrue);
    expect(shell.port.values['panel/graphics-backend'], 'opengl');
    // 本次运行仍然是启动时那套（vulkan）：重启口径不许当场改口。
    expect(find.textContaining('下次启动生效'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('render scale, AA and vsync write their real panel keys',
      (WidgetTester tester) async {
    final ({_ShellController controller, MemoryBasicSettingsPort port}) shell =
        await pumpShell(tester);
    await openSettings(tester);

    // Android 的默认渲染分辨率就是 75（SettingsSchema.cpp:566 的
    // androidDefaultRenderScale），写回 75 属于 unchanged，所以这里选 90。
    await setStep(tester, 'render-scale', 75);
    expect(shell.port.values.containsKey('panel/render-scale'), isFalse);
    await setStep(tester, 'render-scale', 90);
    expect(shell.port.values['panel/render-scale'], '90');

    // 开关型 hudState 行（垂直同步）：面板里是一次真实的控件命中（choice 行
    // 展开成 on/off 两个真控件，Qt 侧是 toggle）——两条路径都落到同一个
    // panel/vsync 写入口，这里只断言真实落盘值。
    await activate(tester, 'vsync', 'off');
    expect(shell.port.values['panel/vsync'], 'off');

    // Android 上 AA 档位里没有 MetalFX（那是 Darwin 专用），选 fxaa 才是真值。
    expect(await activate(tester, 'aa-mode', 'fxaa'), isTrue);
    expect(shell.port.values['panel/aa-mode'], 'fxaa');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the stepper fill and knob follow the Qt mapping (first notch left, last notch right)',
      (WidgetTester tester) async {
    await pumpShell(tester);
    await openSettings(tester);

    // 首档：金色填充长度为 0，knob 贴在轨道左端（Qt settings_row.dart:744
    // 的 selected/(count-1)：index 0 -> 0）。
    await setStep(tester, 'archive-mask', 0);
    final Finder fill =
        find.byKey(const ValueKey<String>('settings-fill-archive-mask'));
    final Finder knob =
        find.byKey(const ValueKey<String>('settings-knob-archive-mask'));
    expect(fill, findsOneWidget);
    expect(knob, findsOneWidget);
    final double fillLeft = tester.getTopLeft(fill).dx;
    expect(tester.getSize(fill).width, 0.0,
        reason: '首档的填充必须是 0，不能是 1/count');
    expect(tester.getTopLeft(knob).dx, fillLeft - 4,
        reason: '首档 knob 必须贴在轨道左端');

    // 末档：填充铺满整条轨道，knob 在右端。
    await setStep(tester, 'archive-mask', 100);
    final double trackWidth = tester.getSize(fill).width;
    expect(trackWidth, greaterThan(0));
    expect(tester.getTopLeft(knob).dx, fillLeft + trackWidth - 4,
        reason: '末档 knob 必须落在轨道右端');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('system back closes the open panel instead of leaving the app',
      (WidgetTester tester) async {
    await pumpShell(tester);
    await openSettings(tester);

    await tester.binding.handlePopRoute();
    await tester.pump();
    // 真实断言对象：产品里真正挂载的窗口（不是早就没人用的 painter 浮层）。
    expect(find.byType(BasicSettingsWindow), findsNothing);
    expect(find.byType(BasicHudSurface), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Back control inside the window closes the panel',
      (WidgetTester tester) async {
    await pumpShell(tester);
    await openSettings(tester);

    final Finder back = find.byKey(const ValueKey<String>('settings-back'));
    expect(back, findsOneWidget);
    await tester.tap(back);
    await settle(tester);
    expect(find.byType(BasicSettingsWindow), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the scroll rail buttons really move the card viewport',
      (WidgetTester tester) async {
    await pumpShell(tester);
    await openSettings(tester);

    final Finder scrollView = find.byType(SingleChildScrollView);
    final ScrollController controller =
        tester.widget<SingleChildScrollView>(scrollView).controller!;
    expect(controller.offset, 0.0);

    final Finder down = find.byKey(const ValueKey<String>('settings-scroll-down'));
    expect(down, findsOneWidget,
        reason: '内容超出视口时，上下滚动按钮必须是真控件');
    await tester.tap(down);
    await settle(tester);
    expect(controller.offset, greaterThan(0.0),
        reason: '滚动按钮必须真的滚动卡片视口，而不是只画个箭头');

    final Finder up = find.byKey(const ValueKey<String>('settings-scroll-up'));
    expect(up, findsOneWidget);
    final double afterDown = controller.offset;
    for (int i = 0; i < 8; i++) {
      await tester.tap(up);
      await settle(tester);
    }
    expect(controller.offset, lessThan(afterDown));

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
    await openSettings(tester);
    await setStep(tester, 'archive-mask', 80);
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
    // 竖屏下控件仍然是真控件（不是回到命中画布）。
    expect(rowControl('archive-mask'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
