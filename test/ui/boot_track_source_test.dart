/// A56：boot 实测曲线源（boot_track_source.dart）的静态单元测试。
///
/// 状态：**authored only / 未执行**。本卡禁令禁止 flutter test / dart test / analyze / build，
/// 因此下面的断言不声称任何 PASS；它们只把 boot-tracks.json 的解析与 Qt 采样语义钉成契约。
///
/// 证据：
/// - Qt/src/BootTimeline.cpp:26-62  载入与特殊键映射（brandX/logo.draw/orbit.sides/orbit.orbit）。
/// - Qt/src/BootTimeline.cpp:64-67  未命中 key → 0。
/// - Qt/src/SceneMotion.cpp:52-95   track() 单调 Hermite（端点保留斜率、内部异号切线归零）。
/// - pubspec.yaml:65-67             `Assets/animation/` 已声明。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show AssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/ui/pages/boot_page.dart';
import 'package:rhine_music_database/ui/pages/boot_track_source.dart';

class _StringBundle extends AssetBundle {
  _StringBundle(this.source);

  final String source;

  @override
  Future<ByteData> load(String key) async => throw UnimplementedError();

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key != kBootTracksAssetPath) {
      throw FlutterError('missing asset: $key');
    }
    return source;
  }
}

class _ThrowingBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('missing asset: $key');
  }
}

class _Clock implements BootClock {
  double seconds = 0;

  @override
  double nowSeconds() => seconds;
}

const Map<String, Object?> _sample = <String, Object?>{
  'brandX': <Object?>[234, 216],
  'logo.draw': <Object?>[
    <Object?>[0, 0.1, 0.9],
    <Object?>[10, 0.2, 1.0],
  ],
  'orbit.sides': <Object?>[
    <Object?>[544, 100, 200, 300, 400, 40, 10, 100, 30, 60],
  ],
  'orbit.orbit': <Object?>[
    <Object?>[0, 969.5, 539.5],
  ],
  'highlightKeys': <Object?>[
    <Object?>[588, 4],
    <Object?>[589, 39],
  ],
  'scan.radius': <Object?>[
    <Object?>[500, 300],
  ],
};

void main() {
  group('BootTrackCurves.parse：Qt 载入语义（BootTimeline.cpp:26-62）', () {
    final BootTrackCurves curves = BootTrackCurves.parse(_sample);

    test('brandX：数组下标即帧', () {
      expect(curves.value('brandX', 0), 234);
      expect(curves.value('brandX', 1), 216);
      expect(curves.value('brandX', 0.5), closeTo(225, 1e-9));
    });

    test('logo.draw 拆成 drawStart/drawEnd', () {
      expect(curves.hasKey('logo.draw'), isFalse);
      expect(curves.value('logo.drawStart', 5), closeTo(0.15, 1e-9));
      expect(curves.value('logo.drawEnd', 5), closeTo(0.95, 1e-9));
    });

    test('orbit.sides 拆成 orbit.column0..8', () {
      expect(curves.value('orbit.column0', 544), 100);
      expect(curves.value('orbit.column1', 544), 200);
      expect(curves.value('orbit.column2', 544), 300);
      expect(curves.value('orbit.column3', 544), 400);
      expect(curves.value('orbit.column4', 544), 40);
      expect(curves.value('orbit.column5', 544), 10);
      expect(curves.value('orbit.column6', 544), 100);
      expect(curves.value('orbit.column7', 544), 30);
      expect(curves.value('orbit.column8', 544), 60);
    });

    test('orbit.orbit 拆成 angle/radius（以 959.5/539.5 为圆心）', () {
      expect(curves.value('orbit.angle', 0), closeTo(0, 1e-12));
      expect(curves.value('orbit.radius', 0), closeTo(10, 1e-12));
    });

    test('普通键保留原名', () {
      expect(curves.value('highlightKeys', 588), 4);
      expect(curves.value('highlightKeys', 589), 39);
      expect(curves.value('scan.radius', 500), 300);
    });

    test('非严格递增帧 / 非数值 / 根不是对象 → FormatException', () {
      expect(
        () => BootTrackCurves.parse(<String, Object?>{
          'x': <Object?>[
            <Object?>[1, 1],
            <Object?>[1, 2],
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => BootTrackCurves.parse(<String, Object?>{'x': <Object?>[<Object?>[0, 'nope']]}),
        throwsFormatException,
      );
      expect(() => BootTrackCurves.parse(<Object?>[]), throwsFormatException);
    });
  });

  group('bootTrackValue：单调 Hermite（SceneMotion.cpp:52-95）', () {
    const List<BootTrackKey> keys = <BootTrackKey>[
      BootTrackKey(0, 0),
      BootTrackKey(10, 10),
      BootTrackKey(20, 0),
    ];

    test('端点外钳制、端点内插值', () {
      expect(bootTrackValue(keys, -1), 0);
      expect(bootTrackValue(keys, 25), 0);
      expect(bootTrackValue(keys, 10), 10);
    });

    test('内部切线：异号斜率归零（中点被端点斜率拉高，不是线性 5）', () {
      // 第一段 a=.5：t0=1（端点斜率）、t1=0（a*b<=0）⇒ 6.25，而不是线性 5。
      expect(bootTrackValue(keys, 5), closeTo(6.25, 1e-12));
      // 第二段 a=.5：t1=0、t2=-1（末端点保留斜率）⇒ 5 + 1.25 = 6.25。
      expect(bootTrackValue(keys, 15), closeTo(6.25, 1e-12));
    });

    test('空曲线 → 0；缺失 key → 0', () {
      expect(bootTrackValue(const <BootTrackKey>[], 3), 0);
      const BootTrackCurves empty = BootTrackCurves.empty();
      expect(empty.value('scan.radius', 3), 0);
      expect(empty.value('never.seen', 3), 0);
    });

    test('同斜率端点的 Hermite 退化为直线', () {
      const List<BootTrackKey> linear = <BootTrackKey>[
        BootTrackKey(0, 0),
        BootTrackKey(10, 10),
      ];
      expect(bootTrackValue(linear, 5), closeTo(5, 1e-12));
    });
  });

  group('loadBootTrackCurves / AssetBootTrackSource：失败降级不抛', () {
    test('成功载入：曲线可查询，无错误', () async {
      final BootTrackLoad load = await loadBootTrackCurves(
        bundle: _StringBundle(jsonEncode(_sample)),
      );
      expect(load.loaded, isTrue);
      expect(load.error, isNull);
      expect(load.curves!.value('brandX', 0), 234);
    });

    test('资产缺失 → BootTrackLoad.failed，不抛', () async {
      final BootTrackLoad load = await loadBootTrackCurves(bundle: _ThrowingBundle());
      expect(load.loaded, isFalse);
      expect(load.error, isNotNull);
      expect(load.curves, isNull);
    });

    test('JSON 非法 → BootTrackLoad.failed，不抛', () async {
      final BootTrackLoad load = await loadBootTrackCurves(bundle: _StringBundle('{not json'));
      expect(load.loaded, isFalse);
      expect(load.error, isNotNull);
    });

    test('AssetBootTrackSource：载入前 0；载入后真实值；只通知一次', () async {
      final AssetBootTrackSource source = AssetBootTrackSource(
        bundle: _StringBundle(jsonEncode(_sample)),
      );
      int notifications = 0;
      source.addListener(() => notifications++);

      expect(source.value('brandX', 0), 0);
      expect(source.loaded, isFalse);
      expect(source.degraded, isFalse);

      await source.load();
      expect(source.loaded, isTrue);
      expect(source.degraded, isFalse);
      expect(source.loadError, isNull);
      expect(source.value('brandX', 0), 234);
      expect(notifications, 1);

      await source.load(); // 幂等
      expect(notifications, 1);
      source.dispose();
    });

    test('AssetBootTrackSource 降级：value 保持 0，loadError 可诊断', () async {
      final AssetBootTrackSource source = AssetBootTrackSource(bundle: _ThrowingBundle());
      await source.load();
      expect(source.loaded, isFalse);
      expect(source.degraded, isTrue);
      expect(source.loadError, isNotNull);
      expect(source.value('scan.radius', 500), 0);
      source.dispose();
    });
  });

  group('生产默认源不是 Zero（A56 根因回归）', () {
    test('BootController 默认使用 AssetBootTrackSource；显式注入仍可覆盖', () {
      final BootController byDefault = BootController(clock: _Clock());
      expect(byDefault.tracks, isA<AssetBootTrackSource>());
      byDefault.dispose();

      final BootController injected = BootController(
        clock: _Clock(),
        tracks: const ZeroBootTrackSource(),
      );
      expect(injected.tracks, isA<ZeroBootTrackSource>());
      injected.dispose();
    });
  });
}
