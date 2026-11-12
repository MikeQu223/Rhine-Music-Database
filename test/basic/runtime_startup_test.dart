import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/ui/pages/consent_page.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';

/// 只记录调用的音频端口：启动测试不接任何平台通道。
class _SilentAudio implements BasicAudioPort {
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];
  BasicAudioState _state = BasicAudioState.idle;

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) =>
      _listeners.add(listener);

  @override
  void removeListener(void Function(BasicAudioState) listener) =>
      _listeners.remove(listener);

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
    _listeners.clear();
    _state = BasicAudioState.idle;
  }
}

/// 只数启动/重试次数：真实 boot 会读网络曲库，这里不触网。
class _CountingController extends BasicController {
  _CountingController({required BasicAudioPort audio}) : super(audio: audio);

  int bootCount = 0;
  int retryCount = 0;
  bool failFirstBoot = false;

  @override
  Future<void> boot() async {
    bootCount += 1;
    if (failFirstBoot) {
      failFirstBoot = false;
      throw StateError('测试注入的启动失败');
    }
  }

  @override
  Future<void> retry() async {
    retryCount += 1;
  }
}

/// 资源读取必失败：把字形装载变成可见错误，而不是永远停在“正在装载”。
class _FailingBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('测试资源包不提供 $key');
  }
}

void main() {
  testWidgets('BasicApp 启动恰一次 boot，且不再出现未接遥测的同意页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _SilentAudio audio = _SilentAudio();
    final _CountingController controller = _CountingController(audio: audio);
    addTearDown(controller.dispose);

    await tester.pumpWidget(BasicApp(
      controller: controller,
      audio: audio,
      bundle: _FailingBundle(),
    ));
    await tester.pump();
    await tester.pump();

    expect(controller.bootCount, 1);
    expect(find.byType(ConsentPage), findsNothing);

    // 旋转只重建 widget，不重建 State：boot 不得重复。
    tester.view.physicalSize = const Size(1080, 1920);
    await tester.pump();
    await tester.pump();
    expect(controller.bootCount, 1);
    expect(find.byType(ConsentPage), findsNothing);

    // 资源失败是可见、可重试的真实错误（92 会永远停在“正在装载”）。
    expect(find.textContaining('字形资源装载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('启动失败可见可重试，重试走 controller.retry 而不是第二次 boot', (WidgetTester tester) async {
    final _SilentAudio audio = _SilentAudio();
    final _CountingController controller = _CountingController(audio: audio);
    controller.failFirstBoot = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(BasicApp(
      controller: controller,
      audio: audio,
      bundle: _FailingBundle(),
    ));
    await tester.pump();
    await tester.pump();

    expect(controller.bootCount, 1);
    expect(find.textContaining('曲库启动失败'), findsOneWidget);

    await tester.tap(find.text('重试').first);
    await tester.pump();
    await tester.pump();

    expect(controller.retryCount, 1);
    expect(controller.bootCount, 1);
    expect(find.textContaining('曲库启动失败'), findsNothing);
  });
}
