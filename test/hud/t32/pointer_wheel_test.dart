/// T32-80-W2 的静态断言集：pointer_router.dart 与 wheel_router.dart 对 Qt 源的 1:1 断言。
///
/// **全部未执行**。本卡（T32-80-W2）禁止 flutter/dart test、analyze、build、run、pub get、
/// formatter 与任何 Node/Python/jq/sh 验证脚本，因此本文件只写不跑：它是「可静态审读的
/// 断言集」，不是跑过的证据。任何结论都必须由 reviewer 读文件得出，不得声称通过。
///
/// 依赖 T30 的 lib/hud/protocol/hud_hit.dart（不在本工作树内，import 在此树无法解析，
/// 与 test/hud/hit_layer_test.dart 的既有状态相同，属预期）。
///
/// 已发现的**跨域偏差**（不在本卡写域，只记录）：本树 lib/hud/input/hit_layer.dart:112
/// 的 offsetY 读了 `hit.fixed`，而 T30 现行 HudHit 只有六个字段、没有 fixed —— fixed 只是
/// PlayerBar 序列化时追加的 map 键（T30 hud_hit.dart:85-98）。本文件因此只构造六字段命中，
/// 不依赖 fixed；精确 patch 见 reports/T32-80-W2.json 的 crossDomainPatch，评审结论见
/// reports/T32-80-W2-R.json 的 F1（hit.fixed）与 F2（T32 树缺 lib/hud/protocol/hud_hit.dart）。
///
/// 断言与 Qt 出处的对应关系逐条写在 test 名与注释里。
library;

import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/input/pointer_router.dart';
import 'package:rhine_music_database/hud/input/wheel_router.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 命中构造器：只用 T30 `HudHit` 的六个必需字段（没有 fixed，见文件头）。
HudHit hitTarget(double x, double y, double width, double height, String action,
        {String? label}) =>
    HudHit(
        x: x,
        y: y,
        width: width,
        height: height,
        action: action,
        label: label ?? action);

const StageGeometry unitGeometry = StageGeometry(logicalWidth: 1080, logicalHeight: 1080);
const StageGeometry halfGeometry = StageGeometry(logicalWidth: 960, logicalHeight: 540);

/// 记录 PointerPorts 的每一次副作用（Overlay.qml 的 rhine.* 调用）。
class RecordingPointerPorts implements PointerPorts {
  final List<String> actions = <String>[];
  final List<PointerForward> pointers = <PointerForward>[];
  final List<List<double>> wheels = <List<double>>[];
  int focusCount = 0;

  @override
  void action(String action) => actions.add(action);

  @override
  void pointer(String type, double x, double y) =>
      pointers.add(PointerForward(type, x, y));

  @override
  void wheel(double x, double y, double pixelDelta, double angleDelta) =>
      wheels.add(<double>[x, y, pixelDelta, angleDelta]);

  @override
  void focusInputLayer() => focusCount++;
}

/// 记录 WheelPorts 的每一次转发。
class RecordingWheelPorts implements WheelPorts {
  final List<WheelForward> forwards = <WheelForward>[];

  @override
  void wheelInput(double x, double y, double pixelDelta, double angleDelta) =>
      forwards.add(WheelForward('raw', x, y, pixelDelta, angleDelta));
}

/// 记录 HudWheelPorts 的每一次副作用。
class RecordingHudWheelPorts implements HudWheelPorts {
  final List<String> calls = <String>[];

  @override
  void cancelSettingEdit() => calls.add('cancelSettingEdit');

  @override
  void sceneWheel(double x, double y, double delta) =>
      calls.add('sceneWheel(' + x.toString() + ',' + y.toString() + ',' + delta.toString() + ')');

  @override
  void loadDiscoverMore() => calls.add('loadDiscoverMore');

  @override
  void loadMoreSource(int collection) => calls.add('loadMoreSource(' + collection.toString() + ')');

  @override
  void loadArtistAlbums() => calls.add('loadArtistAlbums');

  @override
  void loadDirectoryPage() => calls.add('loadDirectoryPage');

  @override
  void loadTrackPage(int offset) => calls.add('loadTrackPage(' + offset.toString() + ')');

  @override
  void musicNext(int step) => calls.add('musicNext(' + step.toString() + ')');
}

HudWheelSnapshot discoverSnapshot({
  Rect? playerBounds,
  Rect viewport = const Rect.fromLTWH(0, 0, 1080, 900),
  double scrollMaximum = 500.0,
  bool more = true,
}) =>
    HudWheelSnapshot(
      modal: 'discover',
      playerBounds: playerBounds,
      discoverViewport: viewport,
      discoverScrollMaximum: scrollMaximum,
      discoverMore: more,
    );

void main() {
  group('PointerRouter · 层级派发顺序（Overlay.qml:179-508）', () {
    test('N1：seek 与 volume 重叠时，后声明的 volume 胜出', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      // Overlay.qml:485-508 的 Repeater 顺序：seek 先、volume 后；Qt 把事件交给最后声明者。
      router.updatePlayerControls(<String, Rect>{
        'seek': const Rect.fromLTWH(0, 0, 400, 40),
        'volume': const Rect.fromLTWH(200, 0, 400, 40),
      });
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(300, 20)));
      expect(out.layer, PointerLayer.playerControl);
      expect(out.consumed, isTrue);
      // Engine.cpp:1016-1021 —— (300 - 200) / 400 = 0.25，QString::number(0.25,'g',16)。
      expect(out.action, 'player:volume-fraction:0.25');
      expect(ports.actions, <String>['player:volume-fraction:0.25']);
    });

    test('N1 补断言：宿主把 Map 反序传入时，volume 仍然胜出', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      // 反序传入：volume 在前、seek 在后。旧实现按「最后一个匹配的 entry 胜出」会在这里
      // 让 seek 赢；N1 修法把优先级写死在 PointerRouter._controlPriority
      // （Overlay.qml:486 的 model 顺序 seek → volume），因此与宿主插入顺序无关。
      router.updatePlayerControls(<String, Rect>{
        'volume': const Rect.fromLTWH(200, 0, 400, 40),
        'seek': const Rect.fromLTWH(0, 0, 400, 40),
      });
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(300, 20)));
      expect(out.layer, PointerLayer.playerControl);
      expect(out.action, 'player:volume-fraction:0.25');
      expect(ports.actions, <String>['player:volume-fraction:0.25']);
    });

    test('N1 补断言：表里没有的控件键排在 seek / volume 之下', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      // 未知键（宿主将来新增控件）与 volume 完全重叠：已知控件必须仍然胜出，
      // 否则一次 QML 新增控件就会悄悄改变 seek/volume 的命中。
      router.updatePlayerControls(<String, Rect>{
        'seek': const Rect.fromLTWH(0, 0, 400, 40),
        'volume': const Rect.fromLTWH(200, 0, 400, 40),
        'future': const Rect.fromLTWH(0, 0, 400, 40),
      });
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(300, 20)));
      expect(out.action, 'player:volume-fraction:0.25');
    });

    test('播放控件先于 searchScrollArea 与 hits', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageWidth: 1080,
          stageHeight: 1080,
          visible: true,
        );
      router.updatePlayerControls(<String, Rect>{'seek': const Rect.fromLTWH(0, 0, 200, 40)});
      router.updateHits(<HudHit>[hitTarget(0, 0, 200, 40, 'music:play')]);
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 20)));
      expect(out.layer, PointerLayer.playerControl);
      expect(out.action, 'player:seek-fraction:0.5');
      expect(ports.actions, hasLength(1));
    });

    test('searchScrollArea 先于 hits delegate（Overlay.qml:222 > :185）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          visible: true,
        );
      router.updateHits(<HudHit>[hitTarget(100, 150, 50, 50, 'music:result:1')]);
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(120, 160)));
      expect(out.layer, PointerLayer.searchScroll);
      expect(out.consumed, isTrue);
      expect(ports.actions, isEmpty, reason: '按下不派发命中动作，抬起才扫描');
    });

    test('hits delegate 先于 playerBarInputShield（Overlay.qml:185 > :123）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(
          geometry: unitGeometry,
          android: true,
          playerBounds: Rect.fromLTWH(0, 900, 1080, 180),
        ),
        ports: ports,
      );
      router.updateHits(<HudHit>[hitTarget(0, 950, 100, 50, 'music:next')]);
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 960)));
      expect(out.layer, PointerLayer.hit);
      expect(ports.actions, <String>['music:next']);
      expect(out.forwards, isEmpty, reason: '命中旁路不产生 cancel/leave');
    });

    test('shield 先于 inputLayer：转发 pointercancel(0,0) 再 pointerleave(0,0)', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(
          geometry: unitGeometry,
          android: true,
          playerBounds: Rect.fromLTWH(0, 900, 1080, 180),
        ),
        ports: ports,
      );
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(10, 910)));
      expect(out.layer, PointerLayer.shield);
      expect(out.forwards, <PointerForward>[
        const PointerForward(PointerPhase.cancel, 0, 0),
        const PointerForward(PointerPhase.leave, 0, 0),
      ]);
      expect(ports.pointers, out.forwards);
      expect(ports.focusCount, 1, reason: 'Overlay.qml:136 的 forceActiveFocus');
    });

    test('shield 第二次按入不再重复 cancel/leave', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(
          geometry: unitGeometry,
          android: true,
          playerBounds: Rect.fromLTWH(0, 900, 1080, 180),
        ),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(10, 910)));
      final second = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(20, 930)));
      expect(second.layer, PointerLayer.shield);
      expect(second.forwards, isEmpty);
    });

    test('inputLayer 兜底：pointerdown 用舞台坐标（Engine.cpp:1053-1058）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: halfGeometry, android: true),
        ports: ports,
      );
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 50)));
      expect(out.layer, PointerLayer.inputLayer);
      // 逻辑 (100,50) / stageScale 0.5 = 舞台 (200,100)。
      expect(out.forwards, <PointerForward>[const PointerForward(PointerPhase.down, 200, 100)]);
      expect(ports.focusCount, 1);
    });

    test('inputLayer 按下不写记录位，也不置 pending', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 50)));
      expect(router.movePending, isFalse);
      expect(router.flush(), isEmpty);
      expect(router.inputLayerPressed, isTrue);
    });
  });

  group('PointerRouter · move 记录与帧末 flush（Engine.cpp:1043-1049、:653-659）', () {
    test('move 不即时转发，同帧多次合并成一次', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 50)));
      final first = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(110, 60)));
      final second = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(120, 70)));
      expect(first.forwards, isEmpty);
      expect(second.forwards, isEmpty);
      expect(router.movePending, isTrue);
      expect(router.flush(),
          <PointerForward>[const PointerForward(PointerPhase.move, 120, 70)]);
      expect(router.movePending, isFalse);
      expect(router.flush(), isEmpty);
    });

    test('同坐标且未 pending 的 move 被丢弃（Engine.cpp:1044）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 50)));
      router.handle(const PointerEvent(phase: PointerPhase.move, position: Offset(130, 80)));
      router.flush();
      router.handle(const PointerEvent(phase: PointerPhase.move, position: Offset(130, 80)));
      expect(router.movePending, isFalse);
      expect(router.flush(), isEmpty);
    });

    test('非 move 相位先 flush 再转发', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 50)));
      router.handle(const PointerEvent(phase: PointerPhase.move, position: Offset(130, 80)));
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(130, 80)));
      expect(out.forwards, <PointerForward>[
        const PointerForward(PointerPhase.move, 130, 80),
        const PointerForward(PointerPhase.up, 130, 80),
      ]);
      expect(ports.pointers, out.forwards);
    });

    test('cancel 前同样先 flush', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(10, 10)));
      router.handle(const PointerEvent(phase: PointerPhase.move, position: Offset(20, 20)));
      final out = router.handle(const PointerEvent(phase: PointerPhase.cancel, position: Offset.zero));
      expect(out.forwards, <PointerForward>[
        const PointerForward(PointerPhase.move, 20, 20),
        const PointerForward(PointerPhase.cancel, 0, 0),
      ]);
    });
  });

  group('PointerRouter · 桌面 hover 转发 pointermove（Overlay.qml:89、:100-105）', () {
    test('hover 落在 inputLayer 上：只记录，帧末 flush 才发一次 pointermove', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: false),
        ports: ports,
      );
      // Overlay.qml:89 的 hoverEnabled: true + :100-105 的 onPositionChanged 没有 pressed 守卫，
      // 桌面 hover 移动同样会调用 rhine.pointer("pointermove", x/stageScale, y/stageScale)。
      final first = router.handle(
          const PointerEvent(phase: PointerPhase.hover, position: Offset(100, 50)));
      expect(first.forwards, isEmpty);
      expect(ports.pointers, isEmpty);
      expect(router.movePending, isTrue);
      final second = router.handle(
          const PointerEvent(phase: PointerPhase.hover, position: Offset(120, 70)));
      expect(second.forwards, isEmpty);
      expect(ports.pointers, isEmpty);
      // Engine.cpp:1043-1049 记录、:653-659 帧末发出：同帧两次 hover 只出一次 move。
      final flushed = router.flush();
      expect(flushed, <PointerForward>[const PointerForward(PointerPhase.move, 120, 70)]);
      expect(ports.pointers, <PointerForward>[const PointerForward(PointerPhase.move, 120, 70)]);
    });

    test('同坐标且未 pending 的 hover 被丢弃（Engine.cpp:1044）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: false),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.hover, position: Offset(100, 50)));
      expect(router.movePending, isTrue);
      expect(router.flush(), hasLength(1));
      // 已 flush、坐标未变、没有新 pending：再次 hover 同一点不重新置 pending。
      router.handle(const PointerEvent(phase: PointerPhase.hover, position: Offset(100, 50)));
      expect(router.movePending, isFalse);
      expect(router.flush(), isEmpty);
    });

    test('hover 落在命中 delegate 上：只发 onEntered 的 leave，不产生 pointermove', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: false),
        ports: ports,
      )..updateHits(<HudHit>[hitTarget(0, 0, 200, 100, 'music:play')]);
      // Overlay.qml:201 —— delegate.onEntered 发 pointerleave(0,0)。
      final entered = router.handle(
          const PointerEvent(phase: PointerPhase.hover, position: Offset(100, 50)));
      expect(entered.layer, PointerLayer.hit);
      expect(entered.forwards, <PointerForward>[const PointerForward(PointerPhase.leave, 0, 0)]);
      // 命中 delegate 只定义 onEntered，没有转发 onPositionChanged 的路径。
      final moved = router.handle(
          const PointerEvent(phase: PointerPhase.hover, position: Offset(110, 60)));
      expect(moved.forwards, isEmpty);
      expect(router.movePending, isFalse);
      expect(router.flush(), isEmpty);
    });

    test('hover 落在 playerBarInputShield 上：首次 cancel+leave，随后不再重复', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(
          geometry: unitGeometry,
          android: false,
          playerBounds: Rect.fromLTWH(0, 900, 1080, 180),
        ),
        ports: ports,
      );
      // Overlay.qml:134-137 —— onEntered 先 pointercancel(0,0) 再 pointerleave(0,0)。
      final entered = router.handle(
          const PointerEvent(phase: PointerPhase.hover, position: Offset(500, 950)));
      expect(entered.layer, PointerLayer.shield);
      expect(entered.forwards, <PointerForward>[
        const PointerForward(PointerPhase.cancel, 0, 0),
        const PointerForward(PointerPhase.leave, 0, 0),
      ]);
      final again = router.handle(
          const PointerEvent(phase: PointerPhase.hover, position: Offset(510, 950)));
      expect(again.forwards, isEmpty);
      expect(router.movePending, isFalse);
    });

    test('捏合激活期间的 hover 不记录（Overlay.qml:100-105 的 active 短路）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: false),
        ports: ports,
      );
      router.setPinchActive(true);
      ports.pointers.clear();
      router.handle(const PointerEvent(phase: PointerPhase.hover, position: Offset(100, 50)));
      expect(router.movePending, isFalse);
      expect(router.flush(), isEmpty);
      expect(ports.pointers, isEmpty);
    });
  });

  group('PointerRouter · Android 按下 / iOS 抬起（Overlay.qml:196-212）', () {
    test('Android（非 iOS）按下即发动作，抬起不再发', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.updateHits(<HudHit>[hitTarget(0, 0, 100, 100, 'music:play')]);
      final down = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 50)));
      expect(down.action, 'music:play');
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(50, 50)));
      expect(up.action, isNull);
      expect(ports.actions, <String>['music:play']);
    });

    test('iOS 抬起且释放点仍在同一命中才发动作', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
        ios: true,
        dragThreshold: 8,
      );
      router.updateHits(<HudHit>[hitTarget(0, 0, 200, 100, 'music:play')]);
      final down = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 50)));
      expect(down.action, isNull, reason: 'iOS 的 onClicked 在抬起才发');
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(52, 51)));
      expect(up.action, 'music:play');
      expect(ports.actions, <String>['music:play']);
    });

    test('iOS 位移超过 start-drag 阈值则不发（dragThreshold > 0 时）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
        ios: true,
        dragThreshold: 8,
      );
      // 命中足够大，确保「同一命中」这一条不成立的原因只剩位移。
      router.updateHits(<HudHit>[hitTarget(0, 0, 400, 400, 'music:play')]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 50)));
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(80, 50)));
      expect(up.action, isNull);
      expect(ports.actions, isEmpty);
    });

    test('iOS 抬起点落到别的命中则不发', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
        ios: true,
      );
      router.updateHits(<HudHit>[
        hitTarget(0, 0, 100, 100, 'music:a'),
        hitTarget(200, 0, 100, 100, 'music:b'),
      ]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 50)));
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(250, 50)));
      expect(up.action, isNull);
      expect(ports.actions, isEmpty);
    });
  });

  group('PointerRouter · pointerleave 保留按下态 / pointercancel 复位（Overlay.qml:112-113）', () {
    test('leave 只转发 pointerleave(0,0)，层状态与 grab 保持', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.updateHits(<HudHit>[hitTarget(0, 0, 400, 400, 'music:play')]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 50)));
      final leave = router.handle(const PointerEvent(phase: PointerPhase.leave, position: Offset.zero));
      expect(leave.layer, PointerLayer.hit);
      expect(leave.forwards, <PointerForward>[const PointerForward(PointerPhase.leave, 0, 0)]);
      // Qt 的 onExited 不释放 grab：后续 move 仍归命中 delegate。
      final move = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(60, 60)));
      expect(move.layer, PointerLayer.hit);
      expect(move.consumed, isTrue);
    });

    test('cancel 复位层状态，下一次按入重新判定', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.updateHits(<HudHit>[hitTarget(0, 0, 100, 100, 'music:play')]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(50, 50)));
      final cancel =
          router.handle(const PointerEvent(phase: PointerPhase.cancel, position: Offset.zero));
      expect(cancel.layer, PointerLayer.hit);
      expect(cancel.forwards, <PointerForward>[const PointerForward(PointerPhase.cancel, 0, 0)]);
      final down = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(600, 600)));
      expect(down.layer, PointerLayer.inputLayer, reason: 'cancel 之后不应再落回 hit 层');
    });
  });

  group('PointerRouter · 捏合短路与 pan（Overlay.qml:319-341）', () {
    test('setPinchActive(true) 先 flush 再发 pointercancel(0,0)', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(10, 10)));
      router.handle(const PointerEvent(phase: PointerPhase.move, position: Offset(30, 40)));
      final out = router.setPinchActive(true);
      expect(out.forwards, <PointerForward>[
        const PointerForward(PointerPhase.move, 30, 40),
        const PointerForward(PointerPhase.cancel, 0, 0),
      ]);
      expect(router.pinchActive, isTrue);
    });

    test('捏合激活期间 down/move/up 都不转发', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      );
      router.setPinchActive(true);
      final down = router
          .handle(const PointerEvent(phase: PointerPhase.down, position: Offset(10, 10)));
      final move = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(30, 30)));
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(30, 30)));
      expect(<List<PointerForward>>[down.forwards, move.forwards, up.forwards],
          everyElement(isEmpty));
      expect(ports.pointers.map((PointerForward f) => f.phase), isNot(contains(PointerPhase.down)));
    });

    test('pan 用舞台坐标转发，并保留 Qt 的量纲不一致', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: halfGeometry, android: true),
        ports: ports,
      )..setPinchActive(true);
      // Overlay.qml:313-317 —— dx 比 stageWidth、dy 比 overlay.height；转发前都除以 stageScale。
      final out = router.handle(const PointerEvent(
          phase: PointerPhase.pan, position: Offset.zero, delta: Offset(100, 20)));
      expect(out.forwards, <PointerForward>[const PointerForward(PointerPhase.pan, 200, 40)]);
    });

    test('pan 超过 0.4 倍舞台宽度时丢弃', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..setPinchActive(true);
      // unit 几何：stageWidth 1080、logicalHeight 1080；1080 * 0.4 = 432。
      final out = router.handle(const PointerEvent(
          phase: PointerPhase.pan, position: Offset.zero, delta: Offset(433, 0)));
      expect(out.forwards, isEmpty);
    });
  });

  group('PointerRouter · searchScrollArea 拖拽（Overlay.qml:232-284）', () {
    test('6px 阈值以内不发滚轮', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          visible: true,
        );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 150)));
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(100, 154)));
      expect(out.wheel, isNull);
      expect(ports.wheels, isEmpty);
    });

    test('越过 6px 后按帧发出 wheelInput，且 surface 是 searchScrollArea', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          visible: true,
        );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 150)));
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(100, 157)));
      // 局部 y 从 50 -> 57；stageOrigin (0,100)；单位 scale。
      expect(out.wheel!.surface, WheelSurface.searchScrollArea);
      expect(out.wheel!.y, 157.0);
      expect(out.wheel!.pixelDeltaY, 7.0);
      expect(ports.wheels, <List<double>>[
        <double>[100.0, 157.0, 7.0, 0.0],
      ]);
    });

    test('closing 时按下不记锚点，后续拖拽不发（Overlay.qml:237-243）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          visible: true,
          closing: true,
        );
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(100, 150)));
      final out = router
          .handle(const PointerEvent(phase: PointerPhase.move, position: Offset(100, 180)));
      expect(out.wheel, isNull);
      expect(ports.wheels, isEmpty);
    });

    test('抬起前缀扫描：扫的是不含 modalOffset 的舞台坐标', () {
      final ports = RecordingPointerPorts();
      // pad = 0（非 Android），让扫描矩形精确等于源矩形，断言才有区分度。
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: false),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          modalOffset: 20,
          visible: true,
        );
      // 命中 y 在 100..110（searchList 空间，不含 modalOffset）。
      router.updateHits(<HudHit>[hitTarget(100, 100, 50, 10, 'music:result:edge')]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(120, 130)));
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(120, 130)));
      // 若漏减 modalOffset，扫描点会是 y=130，落在命中之外，动作不会触发。
      expect(up.action, 'music:result:edge');
      expect(ports.actions, <String>['music:result:edge']);
    });

    test('抬起时已拖拽则不再派发命中（Overlay.qml:262）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          visible: true,
        );
      router.updateHits(<HudHit>[hitTarget(100, 150, 50, 50, 'music:result:1')]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(120, 160)));
      router.handle(const PointerEvent(phase: PointerPhase.move, position: Offset(120, 180)));
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(120, 160)));
      expect(up.action, isNull);
    });

    test('前缀不匹配的命中不派发（Overlay.qml:268-272）', () {
      final ports = RecordingPointerPorts();
      final router = PointerRouter(
        hitLayer: const HitLayer(geometry: unitGeometry, android: true),
        ports: ports,
      )..searchScroll = const SearchScrollState(
          stageY: 100,
          stageWidth: 400,
          stageHeight: 300,
          visible: true,
        );
      router.updateHits(<HudHit>[hitTarget(100, 150, 50, 50, 'music:play')]);
      router.handle(const PointerEvent(phase: PointerPhase.down, position: Offset(120, 160)));
      final up = router
          .handle(const PointerEvent(phase: PointerPhase.up, position: Offset(120, 160)));
      expect(up.action, isNull);
      expect(ports.actions, isEmpty);
    });
  });

  group('OverlayWheelRouter · 三条 wheel 路径与捏合（Overlay.qml:86-341）', () {
    test('inputLayer 路径：逻辑坐标除 stageScale 后照抄 delta', () {
      final ports = RecordingWheelPorts();
      final router = OverlayWheelRouter(geometry: halfGeometry, ports: ports);
      final out = router.inputLayerWheel(
          const Offset(100, 50), const WheelDelta(pixelDeltaY: -12, angleDeltaY: -1));
      expect(out.surface, WheelSurface.inputLayer);
      expect(out.x, 200.0);
      expect(out.y, 100.0);
      expect(out.pixelDeltaY, -12.0);
      expect(out.angleDeltaY, -1.0);
      expect(ports.forwards, <WheelForward>[out]);
    });

    test('hit delegate 路径：mapToItem(inputLayer) 再除 stageScale', () {
      final ports = RecordingWheelPorts();
      final router = OverlayWheelRouter(geometry: halfGeometry, ports: ports);
      // Overlay.qml:213-217：先 mapToItem 得到逻辑坐标，再 /stageScale。
      final mapped =
          router.mapToInputLayer(stageOrigin: const Offset(10, 20), scale: 0.5, local: const Offset(5, 6));
      expect(mapped, const Offset(7.5, 13.0));
      final out = router.hitWheel(
        local: const Offset(5, 6),
        stageOrigin: const Offset(10, 20),
        scale: 0.5,
        delta: const WheelDelta(pixelDeltaY: -30),
      );
      // (7.5,13) / 0.5 = (15,26) = stageOrigin + local。
      expect(out.x, 15.0);
      expect(out.y, 26.0);
      expect(out.surface, WheelSurface.hit);
    });

    test('hit delegate 与 searchScrollArea 是同构路径，靠 surface 区分', () {
      final ports = RecordingWheelPorts();
      final router = OverlayWheelRouter(geometry: unitGeometry, ports: ports);
      final out = router.hitWheel(
        local: const Offset(4, 8),
        stageOrigin: const Offset(2, 3),
        scale: 1.0,
        delta: const WheelDelta(pixelDeltaY: 5),
        surface: WheelSurface.searchScrollArea,
      );
      expect(out.surface, WheelSurface.searchScrollArea);
      expect(out.x, 6.0);
      expect(out.y, 11.0);
    });

    test('playerBarInputShield 只置 accepted，不产生转发（Overlay.qml:139-141）', () {
      final ports = RecordingWheelPorts();
      final router = OverlayWheelRouter(geometry: unitGeometry, ports: ports);
      expect(router.shieldWheel(), isTrue);
      expect(ports.forwards, isEmpty);
    });

    test('viewer 捏合：log(delta) * 350，且守卫 !active / !viewer / 非有限 / <= 0', () {
      final ports = RecordingWheelPorts();
      final router = OverlayWheelRouter(geometry: unitGeometry, ports: ports);
      expect(
          router.viewerPinchWheel(
              active: false, viewer: true, delta: 2.0, centroidLogical: Offset.zero),
          isNull);
      expect(
          router.viewerPinchWheel(
              active: true, viewer: false, delta: 2.0, centroidLogical: Offset.zero),
          isNull);
      expect(
          router.viewerPinchWheel(
              active: true, viewer: true, delta: 0.0, centroidLogical: Offset.zero),
          isNull);
      expect(
          router.viewerPinchWheel(
              active: true,
              viewer: true,
              delta: double.nan,
              centroidLogical: Offset.zero),
          isNull);
      final out = router.viewerPinchWheel(
          active: true, viewer: true, delta: 2.0, centroidLogical: const Offset(50, 60));
      expect(out!.surface, WheelSurface.viewerPinch);
      expect(out.pixelDeltaY, closeTo(0.6931471805599453 * 350.0, 1e-9));
      expect(out.angleDeltaY, 0.0);
      expect(out.x, 50.0);
      expect(out.y, 60.0);
    });
  });

  group('SearchListDragRouter / TouchDragRouter（Overlay.qml:232-261、TouchInput.qml:8-25）', () {
    test('SearchListDragRouter 阈值与 delta 原样（不除 stageScale）', () {
      final ports = RecordingWheelPorts();
      final router = SearchListDragRouter(geometry: halfGeometry, ports: ports);
      router.press(localY: 50, closing: false);
      expect(
          router.drag(
              local: const Offset(100, 55),
              stageOrigin: const Offset(0, 100),
              scale: 0.5,
              closing: false),
          isNull);
      final out = router.drag(
          local: const Offset(100, 60),
          stageOrigin: const Offset(0, 100),
          scale: 0.5,
          closing: false);
      // Overlay.qml:252-259：p = mapToItem(inputLayer, mouse)（逻辑坐标），p / stageScale 才是舞台坐标。
      // delta = current.dy - previous.dy = (100+60)*0.5 - (100+50)*0.5 = 5，原样作为 pixelDelta。
      expect(out!.pixelDeltaY, 5.0);
      expect(out.surface, WheelSurface.searchScrollArea);
      expect(out.x, 100.0, reason: 'toStage((0 + 100) * 0.5)');
      expect(out.y, 160.0, reason: 'toStage((100 + 60) * 0.5)');
      expect(ports.forwards.single.pixelDeltaY, 5.0);
    });

    test('SearchListDragRouter：closing 时 press 无效，release 清 pressed', () {
      final ports = RecordingWheelPorts();
      final router = SearchListDragRouter(geometry: unitGeometry, ports: ports);
      router.press(localY: 10, closing: true);
      expect(
          router.drag(
              local: const Offset(0, 40),
              stageOrigin: Offset.zero,
              scale: 1.0,
              closing: true),
          isNull);
      router.press(localY: 10, closing: false);
      router.drag(local: const Offset(0, 20), stageOrigin: Offset.zero, scale: 1.0, closing: false);
      expect(router.dragged, isTrue);
      router.release(closing: false);
      expect(
          router.drag(
              local: const Offset(0, 60),
              stageOrigin: Offset.zero,
              scale: 1.0,
              closing: false),
          isNull);
    });

    test('TouchDragRouter.captures 平台矩阵（TouchInput.qml:13-15）', () {
      expect(
          TouchDragRouter.captures(
              ios: true, android: false, modal: 'search', mode: '', viewer: false),
          isTrue);
      expect(
          TouchDragRouter.captures(ios: true, android: false, modal: '', mode: '', viewer: false),
          isFalse);
      expect(
          TouchDragRouter.captures(
              ios: true, android: false, modal: '', mode: 'detail', viewer: false),
          isTrue);
      expect(
          TouchDragRouter.captures(ios: false, android: true, modal: '', mode: '', viewer: false),
          isTrue);
      expect(
          TouchDragRouter.captures(
              ios: false, android: true, modal: 'search', mode: '', viewer: true),
          isFalse);
    });

    test('TouchDragRouter.update 除以 stageScale（TouchInput.qml:23）', () {
      final ports = RecordingWheelPorts();
      final router = TouchDragRouter(geometry: halfGeometry, ports: ports);
      expect(
          router.update(centroidLogical: const Offset(100, 50), translationY: 30),
          isNull);
      router.begin();
      final out = router.update(centroidLogical: const Offset(100, 50), translationY: 30);
      expect(out!.surface, WheelSurface.touchDrag);
      expect(out.pixelDeltaY, 60.0, reason: '30 / 0.5');
      expect(out.x, 200.0);
      expect(out.y, 100.0);
      final second = router.update(centroidLogical: const Offset(100, 50), translationY: 30);
      expect(second!.pixelDeltaY, 0.0, reason: 'previousY 已更新为 30');
      router.end();
      expect(
          router.update(centroidLogical: const Offset(100, 50), translationY: 40),
          isNull);
    });
  });

  group('EngineWheelAccumulator（Engine.cpp:171-185、:1013-1015、:1062-1086、:752-766）', () {
    test('常量与平台步进', () {
      expect(EngineWheelConstants.stepPixelsAndroid, 75.0);
      expect(EngineWheelConstants.stepPixelsOther, 15.0);
      expect(EngineWheelConstants.stepPixels(android: true), 75.0);
      expect(EngineWheelConstants.stepPixels(android: false), 15.0);
      expect(EngineWheelConstants.distancePerNotch, 80.0);
      expect(EngineWheelConstants.smoothing, 0.5);
      expect(EngineWheelConstants.distanceTail, 6.0);
      expect(EngineWheelConstants.notchDivisor, 15.0);
      expect(EngineWheelConstants.stageBaseHeight, 1080.0);
    });

    test('像素通路：Android 每 75 舞台像素一步，距离不衰减', () {
      final acc = EngineWheelAccumulator(android: true, reduced: false, logicalHeight: 1080);
      acc.wheel(10, 20, -150, pixels: true);
      final event = acc.flushTick();
      expect(event!.steps, 2);
      expect(event.distance, 150.0);
      expect(event.delta, -150.0);
      expect(acc.flushTick(), isNull);
    });

    test('滚轮格通路：一格立刻 +1 步，距离按 0.5 衰减并在 6px 尾段一次送出', () {
      final acc = EngineWheelAccumulator(android: false, reduced: false, logicalHeight: 1080);
      acc.wheel(0, 0, -2, pixels: false);
      final first = acc.flushTick();
      expect(first!.steps, 1);
      expect(first.distance, closeTo(10.666666666666666 / 2, 1e-12));
      final second = acc.flushTick();
      expect(second!.steps, 0);
      expect(second.distance, closeTo(10.666666666666666 / 2, 1e-12));
      expect(acc.flushTick(), isNull);
    });

    test('reduced 关闭时距离直接累加，不进衰减队列', () {
      final acc = EngineWheelAccumulator(android: false, reduced: true, logicalHeight: 1080);
      acc.wheel(0, 0, -2, pixels: false);
      final event = acc.flushTick();
      expect(event!.steps, 1);
      expect(event.distance, closeTo(10.666666666666666, 1e-12));
      expect(acc.flushTick(), isNull);
    });

    test('wheelInput 优先 pixelDelta，否则 angleDelta / 8', () {
      final pixel = EngineWheelAccumulator(android: false, reduced: true, logicalHeight: 1080);
      pixel.wheelInput(0, 0, -30, -999);
      expect(pixel.flushTick()!.steps, 2, reason: '像素通路 -(-30)/15');
      final angle = EngineWheelAccumulator(android: false, reduced: true, logicalHeight: 1080);
      angle.wheelInput(0, 0, 0, -8);
      final event = angle.flushTick();
      expect(event!.steps, 1, reason: 'angle -8/8 = -1，delta<0 加一步');
      expect(event.delta, -1.0);
    });

    test('delta 为 0 或非有限值直接丢弃', () {
      final acc = EngineWheelAccumulator(android: false, reduced: false, logicalHeight: 1080);
      acc.wheel(0, 0, 0, pixels: true);
      acc.wheel(0, 0, double.nan, pixels: true);
      acc.wheel(0, 0, double.infinity, pixels: true);
      expect(acc.pending, isFalse);
      expect(acc.flushTick(), isNull);
    });
  });

  group('HudScroll（HudScroll.h:11-26）', () {
    test('defaultWheelStep 与 maximum', () {
      expect(HudScroll.defaultWheelStep, 60.0);
      expect(HudScroll.maximum(1000, 200), 800.0);
      expect(HudScroll.maximum(100, 200), 0.0);
    });

    test('clampOffset 夹在 [0, maximum]', () {
      expect(HudScroll.clampOffset(-5, 1000, 200), 0.0);
      expect(HudScroll.clampOffset(900, 1000, 200), 800.0);
      expect(HudScroll.clampOffset(300, 1000, 200), 300.0);
    });

    test('applyWheel：distance 非空且非 0 时优先，否则 steps * stepPixels', () {
      expect(HudScroll.applyWheel(0, 1000, 200, 12.5, 3, 60), 12.5);
      expect(HudScroll.applyWheel(0, 1000, 200, 0, 3, 60), 180.0);
      expect(HudScroll.applyWheel(0, 1000, 200, null, 3, 60), 180.0);
      expect(HudScroll.applyWheel(790, 1000, 200, 100, 3, 60), 800.0);
    });
  });

  group('HudWheelRouter（NativeHudInput.cpp:9-179）', () {
    final router = HudWheelRouter(ports: RecordingHudWheelPorts());

    test('frameEmpty / delta 非有限 / 全零事件都不消费', () {
      final offsets = HudScrollOffsets();
      expect(
          router
              .route(const HudWheelSnapshot(frameEmpty: true), offsets, x: 0, y: 0, delta: -1)
              .consumed,
          isFalse);
      expect(
          router
              .route(const HudWheelSnapshot(), offsets,
                  x: 0, y: 0, delta: double.nan)
              .consumed,
          isFalse);
      expect(
          router
              .route(const HudWheelSnapshot(), offsets, x: 0, y: 0, delta: 0, steps: 0)
              .consumed,
          isFalse);
    });

    test('playerBounds 是闭区间：右下边界吞掉，越界 0.001 就落到 discover', () {
      final s = discoverSnapshot(playerBounds: const Rect.fromLTWH(0, 900, 1080, 180));
      final inside = router.route(s, HudScrollOffsets(), x: 1080, y: 1080, delta: -1);
      expect(inside.consumed, isFalse);
      expect(inside.region, WheelRegion.none);
      final outside = router.route(s, HudScrollOffsets(), x: 1080.001, y: 1080, delta: -1);
      expect(outside.consumed, isTrue);
      expect(outside.region, WheelRegion.discover);
    });

    test('discover 视口也是闭区间：底边算命中，越界 0.001 不算', () {
      final s = discoverSnapshot(viewport: const Rect.fromLTWH(0, 0, 1080, 900));
      final edge = HudScrollOffsets();
      final edgeOutcome = router.route(s, edge, x: 1080, y: 900, delta: -1);
      expect(edgeOutcome.effects, contains('discoverScroll'));
      expect(edge.discoverScroll, 60.0, reason: 'steps * discoverStepPixels');
      final past = HudScrollOffsets();
      final pastOutcome = router.route(s, past, x: 1080.001, y: 900, delta: -1);
      expect(pastOutcome.effects, isEmpty);
      expect(past.discoverScroll, 0.0);
    });

    test('settings：先无条件取消编辑，再判包围盒与 66px 步进', () {
      final s = const HudWheelSnapshot(
        modal: 'settings',
        editingSetting: true,
        modalBounds: Rect.fromLTWH(0, 0, 1080, 1080),
      );
      final inside = HudScrollOffsets();
      final insideOutcome = router.route(s, inside, x: 500, y: 200, delta: -1);
      expect(insideOutcome.region, WheelRegion.settings);
      expect(insideOutcome.effects, contains('cancelSettingEdit'));
      expect(insideOutcome.effects, contains('settingsScroll'));
      expect(inside.settingsScroll, 66.0);
      final outside = HudScrollOffsets();
      final outsideOutcome = router.route(s, outside, x: 10, y: 200, delta: -1);
      expect(outsideOutcome.effects, <String>['cancelSettingEdit']);
      expect(outside.settingsScroll, 0.0);
    });

    test('viewer：把 delta 乘 8 交给场景，modal 为空也走这条分支', () {
      final ports = RecordingHudWheelPorts();
      final viewerRouter = HudWheelRouter(ports: ports);
      final outcome =
          viewerRouter.route(const HudWheelSnapshot(viewer: true), HudScrollOffsets(),
              x: 10, y: 20, delta: -2);
      expect(outcome.region, WheelRegion.viewer);
      expect(outcome.effects, <String>['sceneWheel']);
      expect(ports.calls, <String>['sceneWheel(10.0,20.0,16.0)']);
      final zero = viewerRouter.route(const HudWheelSnapshot(viewer: true), HudScrollOffsets(),
          x: 10, y: 20, delta: 0, steps: 1);
      expect(zero.effects, isEmpty, reason: 'delta == 0 时不发 sceneWheel，但区域仍被消费');
      expect(zero.consumed, isTrue);
    });

    test('playlist-picker：只夹 (0, rowCount - 可见行数)', () {
      final s = const HudWheelSnapshot(modal: 'playlist-picker', pickerRowCount: 10);
      final offsets = HudScrollOffsets(listOffset: 3);
      router.route(s, offsets, x: 0, y: 0, delta: -1);
      expect(offsets.listOffset, 3, reason: '上限 10 - 7 = 3');
      final up = HudScrollOffsets();
      router.route(s, up, x: 0, y: 0, delta: 1, steps: -1);
      expect(up.listOffset, 0);
    });

    test('常量与 NativeHud.h 对齐', () {
      expect(HudWheelConstants.resultListTop, 328.0);
      expect(HudWheelConstants.resultListBottom, 758.0);
      expect(HudWheelConstants.resultRowHeight, 72.0);
      expect(HudWheelConstants.settingsViewportTop, 176.0);
      expect(HudWheelConstants.settingsViewportBottom, 836.0);
      expect(HudWheelConstants.desktopLyricsViewportTop, 200.0);
      expect(HudWheelConstants.desktopLyricsViewportBottom, 820.0);
      expect(HudWheelConstants.albumTrackRowCount, 6);
      expect(HudWheelConstants.settingsStepPixels, 66.0);
      expect(HudWheelConstants.desktopLyricsStepPixels, 66.0);
      expect(HudWheelConstants.discoverStepPixels, 60.0);
      expect(HudWheelConstants.discoverLoadMoreMargin, 120.0);
      expect(HudWheelConstants.listLoadMoreMargin, 160.0);
      expect(HudWheelConstants.modalLeftInset, 53.0);
      expect(HudWheelConstants.modalRightInset, 10.0);
      expect(HudWheelConstants.pickerVisibleRows, 7);
      expect(HudWheelConstants.sceneWheelScale, 8.0);
      expect(HudWheelConstants.layoutLeft, 40.0);
      expect(HudWheelConstants.layoutSidebar, 250.0);
      expect(HudWheelConstants.layoutX, 326.0);
      expect(HudWheelConstants.layoutTop, 260.0);
      expect(HudWheelConstants.layoutRowsY, 434.0);
      expect(HudWheelConstants.layoutRowHeight, 54.0);
      expect(HudWheelConstants.layoutRowCount, 9);
      expect(HudWheelConstants.layoutBottom, 956.0);
    });

    test('区域名与 Qt 的各面板一一对应', () {
      expect(WheelRegion.none, 'none');
      expect(WheelRegion.settings, 'settings');
      expect(WheelRegion.desktopLyrics, 'desktop-lyrics');
      expect(WheelRegion.viewer, 'viewer');
      expect(WheelRegion.playlistPicker, 'playlist-picker');
      expect(WheelRegion.discover, 'discover');
      expect(WheelRegion.playerQueue, 'player');
      expect(WheelRegion.search, 'search');
      expect(WheelRegion.saved, 'saved');
      expect(WheelRegion.detailList, 'detail-list');
      expect(WheelRegion.detailBody, 'detail-body');
      expect(WheelRegion.archive, 'archive');
    });
  });
}
