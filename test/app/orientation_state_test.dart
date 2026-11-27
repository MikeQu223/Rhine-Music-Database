// RED/GREEN: NOT EXECUTED
//
// 本文件按任务禁令「只写不跑」：未执行 flutter test / dart test / analyze / pub get，
// 因此本文件的 RED 与 GREEN 一律记为 NOT EXECUTED（见报告 RED_GREEN 字段）。
//
// 为什么 import package:flutter_test 而不是任务书写的 package:test：
//   * pubspec.yaml:38-40 的 dev_dependencies 只有 flutter_test（sdk: flutter），没有 test；
//   * pubspec.lock 只有 test_api（随 flutter_test 传递），无独立 test 包条目；
//   * pubspec.yaml 属禁改文件，不能为引入 package:test 而改依赖；
//   * 本树既有测试（例如 test/widget_test.dart:9）统一 import package:flutter_test。
//   故沿用仓库既有约定，并把该偏离写进报告 decisions 供父级裁决。
//
// 覆盖范围（任务书 4 条 + 五 lane/目录栈）：
//   1. 旋转前后 item key 与相对偏移不变、绝对像素按新 extent 换算（plan:371）；
//      列表/单曲/详情/队列四个锚走同一出口
//   2. 白名单外 modal 旋转后不恢复；白名单七项恢复且保留 closing/offset（plan:376）；
//      只有磁盘 sessionState 在 closing 时写空名（MusicSession.cpp:222）
//   3. selection / musicCollection / settingsScroll 越界夹取（MusicSession.cpp:246-262）
//   4. 同一曲线代次在旋转后不递增（plan:376）
//   5. 五 lane + 目录栈 + 每层游标 round-trip 相等（MusicSession.cpp:106-135）
//
// 数值全部手算并注明来源；断言里的每一处夹取范围都能在 lib/app/orientation_state.dart
// 的注释中找到对应 Qt 行号。

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/app/orientation_state.dart';

/// 横屏基准：800x360 @3x。stageScale = 360/1080 = 1/3，stageWidth = 800/(1/3) = 2400。
const StageMetrics landscapeMetrics = StageMetrics(
  orientation: OrientationKind.landscape,
  stageScale: 1 / 3,
  stageWidth: 2400,
  stageHeight: 1080,
  logicalWidth: 800,
  logicalHeight: 360,
  devicePixelRatio: 3,
  insets: StageInsets.zero,
  cameraCompact: false,
);

/// 竖屏基准：360x800 @3x，即上例旋转 90 度。stageScale = 360/1080 = 1/3（短边不变），
/// stageWidth = 1080，stageHeight = 800/(1/3) = 2400。
const StageMetrics portraitMetrics = StageMetrics(
  orientation: OrientationKind.portrait,
  stageScale: 1 / 3,
  stageWidth: 1080,
  stageHeight: 2400,
  logicalWidth: 360,
  logicalHeight: 800,
  devicePixelRatio: 3,
  insets: StageInsets.zero,
  cameraCompact: false,
);

StageMetrics compute(double w, double h, {double dpr = 1, StageInsets insets = StageInsets.zero}) =>
    StageMetrics.compute(StageInputs(
      logicalWidth: w,
      logicalHeight: h,
      devicePixelRatio: dpr,
      insets: insets,
    ));

void main() {
  // -------------------------------------------------------------------------
  // 1. 方向判定 + stage 重算（Qt 证据：NativeSceneCamera.cpp:55-57；Main.qml:32-33）
  // -------------------------------------------------------------------------
  group('方向判定与 stage 重算', () {
    test('横屏沿用 Qt 舞台高 1080，stageScale = height/1080', () {
      final StageMetrics m = compute(800, 360, dpr: 3);
      expect(m.orientation, OrientationKind.landscape);
      expect(m.isLandscape, isTrue);
      expect(m.stageScale, closeTo(1 / 3, 1e-12));
      expect(m.stageWidth, closeTo(2400, 1e-9));
      expect(m.stageHeight, closeTo(qtStageHeightUnits, 1e-9));
      // 物理像素域与 Qt 的 m_width/m_height 同域（Engine.cpp:1353）。
      expect(m.physicalStageScale, closeTo(1, 1e-9));
    });

    test('竖屏舞台宽 1080，stageScale = width/1080', () {
      final StageMetrics m = compute(360, 800, dpr: 3);
      expect(m.orientation, OrientationKind.portrait);
      expect(m.isPortrait, isTrue);
      expect(m.stageScale, closeTo(1 / 3, 1e-12));
      expect(m.stageWidth, closeTo(portraitStageWidthUnits, 1e-9));
      expect(m.stageHeight, closeTo(2400, 1e-9));
    });

    test('1:1 窗口按 aspect<1.05 判为竖屏', () {
      final StageMetrics m = compute(1080, 1080);
      expect(m.orientation, OrientationKind.portrait);
      expect(m.stageScale, closeTo(1, 1e-12));
      expect(m.stageWidth, closeTo(1080, 1e-9));
      expect(m.stageHeight, closeTo(1080, 1e-9));
    });

    test('aspect 恰好 1.05 属于横屏（阈值是严格小于）', () {
      // 1134/1080 = 1.05 精确十进制，双精度下与字面量 1.05 同一值。
      final StageMetrics m = compute(1134, 1080);
      expect(m.orientation, OrientationKind.landscape);
      expect(m.stageScale, closeTo(1, 1e-12));
      expect(m.stageWidth, closeTo(1134, 1e-9));
      expect(m.cameraCompact, isFalse, reason: '物理宽 1134 >= 1100');
    });

    test('classifyOrientation 与 StageMetrics.compute 一致，且退化窗口按横屏', () {
      expect(classifyOrientation(logicalWidth: 800, logicalHeight: 360), OrientationKind.landscape);
      expect(classifyOrientation(logicalWidth: 360, logicalHeight: 800), OrientationKind.portrait);
      expect(classifyOrientation(logicalWidth: 0, logicalHeight: 800), OrientationKind.landscape);
      expect(classifyOrientation(logicalWidth: 800, logicalHeight: -1), OrientationKind.landscape);
      expect(compute(0, 800).orientation, OrientationKind.landscape);
    });

    test('紧凑相机分支比较物理宽（Qt 的 m_width 是渲染面像素）', () {
      final StageMetrics compact = compute(1000, 700, dpr: 1);
      expect(compact.orientation, OrientationKind.landscape);
      expect(compact.cameraCompact, isTrue, reason: '1000 < 1100');

      final StageMetrics sameGeometryHighDpr = compute(1000, 700, dpr: 3);
      expect(sameGeometryHighDpr.cameraCompact, isFalse, reason: '1000*3 = 3000 >= 1100');
      // dpr 不改 stage 几何：物理 stageScale 只是逻辑值乘 dpr（比值不变）。
      expect(sameGeometryHighDpr.stageScale, closeTo(compact.stageScale, 1e-12));
      expect(sameGeometryHighDpr.stageWidth, closeTo(compact.stageWidth, 1e-9));
      expect(sameGeometryHighDpr.stageHeight, closeTo(compact.stageHeight, 1e-9));
    });

    test('insets/IME 不参与 stage 换算，只作为竖向容器用的派生量', () {
      const StageInsets insets = StageInsets(top: 24, imeBottom: 300);
      final StageMetrics plain = compute(800, 360, dpr: 3);
      final StageMetrics withInsets = compute(800, 360, dpr: 3, insets: insets);
      expect(withInsets.geometryEquals(plain), isTrue);
      expect(withInsets.stageScale, closeTo(1 / 3, 1e-12));
      // 300 逻辑像素 / (1/3) 逻辑像素每舞台单位 = 900 舞台单位。
      expect(withInsets.imeStageInset, closeTo(900, 1e-9));
      expect(withInsets.safeTopStage, closeTo(72, 1e-9));
      expect(withInsets.safeBottomStage, closeTo(0, 1e-9));
    });

    test('竖屏工厂先扣 safe 再算 layoutH，IME 不参与（layout.md:287/:299）', () {
      const StageInsets insets = StageInsets(top: 24, bottom: 16, imeBottom: 300);
      final StageInputs inputs = StageInputs.portraitFromWindow(
        logicalWidth: 360,
        windowHeight: 800,
        insets: insets,
        devicePixelRatio: 3,
      );
      expect(inputs.logicalWidth, 360);
      expect(inputs.logicalHeight, closeTo(760, 1e-12), reason: '800 - 24 - 16，IME 不减');
      expect(inputs.insets, insets);
      final StageMetrics m = StageMetrics.compute(inputs);
      expect(m.orientation, OrientationKind.portrait);
      // 短边 360 / 1080 = 1/3；stageHeight = 760 / (1/3) = 2280。
      expect(m.stageScale, closeTo(1 / 3, 1e-12));
      expect(m.stageHeight, closeTo(2280, 1e-9));
      // 再扣一次会变成 720/(1/3)=2160，这里明确防止双重扣减。
      expect(m.stageHeight, isNot(closeTo(2160, 1e-9)));
      // 竖屏没有窗口高时不得给出负 layoutH。
      expect(
        StageInputs.portraitFromWindow(logicalWidth: 360, windowHeight: 20, insets: insets)
            .logicalHeight,
        0,
      );
    });

    test('退化窗口（任一边 0）给出 Qt 的 1920 兜底且 stageScale 为 0', () {
      final StageMetrics m = compute(0, 0);
      expect(m.stageScale, 0);
      expect(m.stageWidth, closeTo(qtStageWidthFallbackUnits, 1e-9));
      expect(m.stageHeight, closeTo(qtStageHeightUnits, 1e-9));
      expect(m.logicalWidth, 0);
      expect(m.logicalHeight, 0);
      // 退化度量不抛错：Qt/src/Engine.cpp:841-843 对 height <= 0 静默 return、
      // 保留上一有效尺寸，还原路径对应地返回快照里的上一有效状态。
      const OrientationViewState before = OrientationViewState(selected: 7, currentLane: 2);
      final OrientationSnapshot snap = captureOrientationState(before, m);
      final OrientationViewState restored = restoreOrientationState(snap, m);
      expect(restored, before.sanitized(), reason: '退化帧不得改变状态、不得抛错');
      expect(restored.selected, 7);
      expect(m.stageOf(100), 0, reason: 'stageScale 为 0 时不得产生 inf');
    });

    test('旋转不改 stageScale，只交换舞台宽高', () {
      final StageMetrics land = compute(800, 360, dpr: 3);
      final StageMetrics port = compute(360, 800, dpr: 3);
      expect(port.stageScale, closeTo(land.stageScale, 1e-12));
      expect(port.stageWidth, isNot(closeTo(land.stageWidth, 1)));
      expect(port.geometryEquals(land), isFalse);
      expect(recomputeStage(const StageInputs(logicalWidth: 360, logicalHeight: 800))
          .orientation, OrientationKind.portrait);
    });

    test('geometryEquals 用容差比较，微小抖动不算重排', () {
      const StageMetrics a = StageMetrics(
        orientation: OrientationKind.landscape,
        stageScale: 0.5,
        stageWidth: 1600,
        stageHeight: 1080,
        logicalWidth: 800,
        logicalHeight: 400,
        devicePixelRatio: 2,
        insets: StageInsets.zero,
        cameraCompact: true,
      );
      const StageMetrics b = StageMetrics(
        orientation: OrientationKind.landscape,
        stageScale: 0.5 + 1e-9,
        stageWidth: 1600,
        stageHeight: 1080,
        logicalWidth: 800,
        logicalHeight: 400,
        devicePixelRatio: 2,
        insets: StageInsets.zero,
        cameraCompact: true,
      );
      expect(a.geometryEquals(b), isTrue);
      expect(b.geometryEquals(a, tolerance: 1e-12), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 2. 滚动锚：item key + 相对偏移不变，绝对像素按新 extent 换算（plan:371）
  // -------------------------------------------------------------------------
  group('滚动锚跨旋转', () {
    // 100 项 * 72 单位，视口 720 => maximum = 7200 - 720 = 6480。
    const ScrollExtent landscapeExtent =
        ScrollExtent(itemExtent: 72, itemCount: 100, viewportExtent: 720);

    test('capture 把绝对偏移消去为 (itemIndex, withinItem)', () {
      final ScrollAnchor anchor = ScrollAnchor.capture(
        itemKey: 'track-42',
        itemIndex: 17,
        pixelOffset: 1260, // 17*72 = 1224，余 36 = 0.5 项
        itemExtent: 72,
        itemCount: 100,
        viewportExtent: 720,
      );
      expect(anchor.itemKey, 'track-42');
      expect(anchor.itemIndex, 17);
      expect(anchor.withinItem, closeTo(0.5, 1e-12));
      // 同一 extent 下可无损还原。
      expect(anchor.pixelOffsetFor(landscapeExtent), closeTo(1260, 1e-9));
    });

    test('旋转后 item key 与相对偏移不变，绝对像素按新 extent 换算', () {
      final ScrollAnchor anchor = ScrollAnchor.capture(
        itemKey: 'track-42',
        itemIndex: 17,
        pixelOffset: 1260,
        itemExtent: 72,
        itemCount: 100,
        viewportExtent: 720,
      );
      // 竖屏行高 96、视口 900：同一个锚，绝对偏移变成 17.5*96 = 1680。
      const ScrollExtent portraitExtent =
          ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900);
      final double rotated = anchor.pixelOffsetFor(portraitExtent);
      expect(anchor.itemKey, 'track-42', reason: 'key 不随旋转变化');
      expect(anchor.itemIndex, 17, reason: 'index 不随旋转变化');
      expect(anchor.withinItem, closeTo(0.5, 1e-12), reason: '相对偏移不随旋转变化');
      expect(rotated, closeTo(1680, 1e-9));
      expect(rotated, isNot(closeTo(1260, 1e-9)), reason: '绝不能沿用旧绝对像素');
      // 相对位置守恒：两边都停在 17.5 项处。
      expect(rotated / portraitExtent.itemExtent, closeTo(1260 / landscapeExtent.itemExtent, 1e-12));
    });

    test('锚偏移夹取到 [0, maximum] 且 withinItem 落在 [0,1]', () {
      final ScrollAnchor tooFar = ScrollAnchor.capture(
        itemKey: 'k',
        itemIndex: 17,
        pixelOffset: 999999,
        itemExtent: 72,
        itemCount: 100,
        viewportExtent: 720,
      );
      expect(tooFar.withinItem, 1);
      expect(tooFar.pixelOffsetFor(landscapeExtent), closeTo(1296, 1e-9)); // 18*72
      final ScrollAnchor negative = ScrollAnchor.capture(
        itemKey: 'k',
        itemIndex: 17,
        pixelOffset: -500,
        itemExtent: 72,
        itemCount: 100,
        viewportExtent: 720,
      );
      expect(negative.withinItem, 0);
      expect(negative.pixelOffsetFor(landscapeExtent), closeTo(1224, 1e-9)); // 17*72
    });

    test('空表 / 零行高不产生 NaN 或 inf', () {
      final ScrollAnchor empty = ScrollAnchor.capture(
        itemKey: 'none',
        itemIndex: 5,
        pixelOffset: 100,
        itemExtent: 0,
        itemCount: 0,
        viewportExtent: 720,
      );
      expect(empty.itemIndex, 0);
      expect(empty.withinItem, 0);
      expect(empty.pixelOffsetFor(const ScrollExtent(itemExtent: 0, itemCount: 0, viewportExtent: 0)), 0);
    });

    test('resolveScrollOffsets 是唯一的绝对像素出口，按新 extent 现算', () {
      final OrientationViewState state = OrientationViewState(
        listAnchor: ScrollAnchor.capture(
          itemKey: 'album-7',
          itemIndex: 3,
          pixelOffset: 252, // 3.5 * 72
          itemExtent: 72,
          itemCount: 100,
          viewportExtent: 720,
        ),
        trackAnchor: ScrollAnchor.capture(
          itemKey: 'track-42',
          itemIndex: 17,
          pixelOffset: 1260,
          itemExtent: 72,
          itemCount: 100,
          viewportExtent: 720,
        ),
        bodyAnchor: ScrollAnchor.capture(
          itemKey: 'body-1',
          itemIndex: 0,
          pixelOffset: 36,
          itemExtent: 72,
          itemCount: 100,
          viewportExtent: 720,
        ),
        queueAnchor: ScrollAnchor.capture(
          itemKey: 'queue-9',
          itemIndex: 5,
          pixelOffset: 396, // 5.5 * 72
          itemExtent: 72,
          itemCount: 100,
          viewportExtent: 720,
        ),
        settingsScroll: 400,
      );
      final ResolvedScrollOffsets resolved = resolveScrollOffsets(
        state,
        list: const ScrollExtent(itemExtent: 72, itemCount: 100, viewportExtent: 720),
        track: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
        body: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
        queue: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
      );
      expect(resolved.list, closeTo(252, 1e-9));
      expect(resolved.track, closeTo(1680, 1e-9));
      expect(resolved.body, closeTo(48, 1e-9)); // 0.5 * 96
      expect(resolved.queue, closeTo(528, 1e-9)); // 5.5 * 96
      expect(resolved.settings, 400, reason: '设置页偏移是舞台单位，方向无关');
    });
  });

  // -------------------------------------------------------------------------
  // 3. modal 白名单 / closing（MusicSession.cpp:222,243）
  // -------------------------------------------------------------------------
  group('modal 跨旋转恢复', () {
    test('白名单七项全部恢复，offset 原样保留', () {
      expect(restorableModalNames.length, 7);
      for (final String name in <String>[
        'saved',
        'search',
        'discover',
        'queue',
        'settings',
        'player',
        'local',
      ]) {
        expect(restorableModalNames.contains(name), isTrue, reason: name);
        final ModalState restored = ModalState(name: name, offset: 24).sanitized();
        expect(restored.name, name, reason: '白名单项必须恢复：$name');
        expect(restored.offset, closeTo(24, 1e-12), reason: 'modalOffset 是舞台单位，方向无关');
        expect(restored.isOpen, isTrue);
      }
    });

    test('白名单外 modal 旋转后不恢复', () {
      for (final String name in <String>[
        'confirm',
        'detail-sort',
        'quality',
        'lyrics-offset',
        'login',
        'toast',
      ]) {
        final ModalState restored = ModalState(name: name, offset: 24).sanitized();
        expect(restored.name, isNull, reason: '非白名单不得恢复：$name');
        expect(restored.isOpen, isFalse);
        expect(restored, ModalState.none);
      }
    });

    test('closing 中的 modal 跨旋转保留名字/进度/offset，只有落盘写空名', () {
      // Qt 运行时只有关闭动画走完才清 modal（NativeHud.cpp:263-265）；旋转没有该复位。
      final ModalState closing = ModalState(name: 'queue', closing: true, offset: 30).sanitized();
      expect(closing.name, 'queue');
      expect(closing.closing, isTrue);
      expect(closing.offset, closeTo(30, 1e-12));
      expect(closing.isOpen, isTrue);
      // 磁盘 sessionState 才按 MusicSession.cpp:222 "hud.closing ? QString() : hud.modal"。
      expect(closing.diskModalName, '');
      expect(const ModalState(name: 'saved').diskModalName, 'saved');
      expect(ModalState.none.diskModalName, '');
    });

    test('空名 / null 名都是 none', () {
      expect(const ModalState(name: '').sanitized(), ModalState.none);
      expect(const ModalState().sanitized(), ModalState.none);
      expect(const ModalState().isOpen, isFalse);
    });

    test('capture -> restore 整条链路上非白名单 modal 被丢弃', () {
      const OrientationViewState dirty = OrientationViewState(
        modal: ModalState(name: 'confirm', offset: 12),
      );
      final OrientationSnapshot snap = captureOrientationState(dirty, landscapeMetrics);
      expect(snap.state.modal, ModalState.none);
      final OrientationViewState restored = restoreOrientationState(snap, portraitMetrics);
      expect(restored.modal, ModalState.none);

      const OrientationViewState keep = OrientationViewState(
        modal: ModalState(name: 'settings', offset: 12),
      );
      final OrientationViewState kept =
          restoreOrientationState(captureOrientationState(keep, landscapeMetrics), portraitMetrics);
      expect(kept.modal.name, 'settings');
      expect(kept.modal.offset, closeTo(12, 1e-12));

      // closing 中的白名单项：旋转链路保留，磁盘表达仍为空名。
      const OrientationViewState closing = OrientationViewState(
        modal: ModalState(name: 'queue', closing: true, offset: 30),
      );
      final OrientationViewState closingKept = restoreOrientationState(
          captureOrientationState(closing, landscapeMetrics), portraitMetrics);
      expect(closingKept.modal.name, 'queue');
      expect(closingKept.modal.closing, isTrue);
      expect(closingKept.modal.offset, closeTo(30, 1e-12));
      expect(closingKept.modal.diskModalName, '');
    });
  });

  // -------------------------------------------------------------------------
  // 4. 夹取：selected / musicCollection / settingsScroll（MusicSession.cpp:246-262）
  // -------------------------------------------------------------------------
  group('越界夹取', () {
    test('selected 夹到 [0,39]（Qt:260）', () {
      expect(const OrientationViewState(selected: 137).sanitized().selected, 39);
      expect(const OrientationViewState(selected: -5).sanitized().selected, 0);
      expect(const OrientationViewState(selected: 39).sanitized().selected, 39);
      expect(const OrientationViewState(selected: 0).sanitized().selected, 0);
      expect(const OrientationViewState(selected: 21).sanitized().selected, 21);
    });

    test('musicCollection 夹到 [1,4]（Qt:257）', () {
      expect(const OrientationViewState(musicCollection: 9).sanitized().musicCollection, 4);
      expect(const OrientationViewState(musicCollection: 0).sanitized().musicCollection, 1);
      expect(const OrientationViewState(musicCollection: -3).sanitized().musicCollection, 1);
      expect(const OrientationViewState(musicCollection: 1).sanitized().musicCollection, 1);
      expect(const OrientationViewState(musicCollection: 4).sanitized().musicCollection, 4);
      expect(const OrientationViewState(musicCollection: 3).sanitized().musicCollection, 3);
    });

    test('settingsScroll 夹到 [0, settingsScrollMaximum]（Qt:247 + NativeHud.h:132-135）', () {
      // 1600 - 176 = 1424 内容；836 - 176 = 660 视口 => 上限 764。
      expect(settingsScrollMaximumFor(1600), closeTo(764, 1e-12));
      expect(const OrientationViewState().settingsScrollMaximum, closeTo(764, 1e-12));
      expect(const OrientationViewState(settingsScroll: 9999).sanitized().settingsScroll, closeTo(764, 1e-12));
      expect(const OrientationViewState(settingsScroll: -10).sanitized().settingsScroll, 0);
      expect(const OrientationViewState(settingsScroll: 400).sanitized().settingsScroll, closeTo(400, 1e-12));

      // 内容变高后上限跟着变（2400 - 176 = 2224；减 660 = 1564）。
      const OrientationViewState taller =
          OrientationViewState(settingsScroll: 9999, settingsContentBottom: 2400);
      expect(taller.settingsScrollMaximum, closeTo(1564, 1e-12));
      expect(taller.sanitized().settingsScroll, closeTo(1564, 1e-12));
    });

    test('HudScroll 的 maximum/clampOffset 与 Qt 同式（HudScroll.h:13-19）', () {
      expect(hudScrollMaximum(1600, 660), closeTo(940, 1e-12));
      expect(hudScrollMaximum(100, 660), 0, reason: '内容比视口矮时上限为 0');
      expect(hudScrollClamp(9999, 1600, 660), closeTo(940, 1e-12));
      expect(hudScrollClamp(-3, 1600, 660), 0);
      expect(hudScrollClamp(500, 1600, 660), closeTo(500, 1e-12));
    });

    test('currentLane 夹到 [0,4]，laneRowMemory 每项夹到 [0,7]（Qt:111,132）', () {
      final OrientationViewState state = const OrientationViewState(
        currentLane: 7,
        laneRowMemory: <int>[9, -1, 3, 7, 5],
      ).sanitized();
      expect(state.currentLane, 4);
      expect(state.laneRowMemory, <int>[7, 0, 3, 7, 5]);

      expect(const OrientationViewState(currentLane: -1).sanitized().currentLane, 0);
      // 记忆数组长度不足五时补齐，保证五 lane 永远可索引。
      final OrientationViewState short = const OrientationViewState(laneRowMemory: <int>[2]).sanitized();
      expect(short.laneRowMemory.length, laneCount);
      expect(short.laneRowMemory, <int>[2, 0, 0, 0, 0]);
    });

    test('目录层五个游标按 Qt 各自的范围夹取（MusicSession.cpp:127-134）', () {
      const DirectoryFrame dirty = DirectoryFrame(
        itemKey: 'album-1',
        cursor: 999,
        index: 999,
        anchor: 999,
        albumCursor: -5,
        parentPhysical: 999,
        parentLane: 9,
        idCount: 20,
        songCount: 50,
      );
      final DirectoryFrame clean = dirty.sanitized();
      expect(clean.cursor, 20, reason: 'cursor 夹到 [0, idCount]');
      expect(clean.index, 49, reason: 'index 夹到 [0, songCount-1]');
      expect(clean.anchor, 39, reason: 'anchor 夹到 [0,39]');
      expect(clean.albumCursor, 0, reason: 'albumCursor 非负');
      expect(clean.parentPhysical, 39, reason: 'parentPhysical 夹到 [0,39]');
      expect(clean.parentLane, 4, reason: 'parentLane 夹到 [0,4]');
      expect(clean.itemKey, 'album-1');
    });

    test('目录页起点由 index 推导（Qt:130 的 /40*40）', () {
      expect(const DirectoryFrame(index: 0).page, 0);
      expect(const DirectoryFrame(index: 39).page, 0);
      expect(const DirectoryFrame(index: 40).page, 40);
      expect(const DirectoryFrame(index: 41).page, 40);
      expect(const DirectoryFrame(index: 119, songCount: 120).page, 80);
    });

    test('目录栈超过 64 层时保留最深 64 层（Qt:43/100）', () {
      final List<DirectoryFrame> deep = <DirectoryFrame>[];
      for (int i = 0; i < 70; i++) {
        deep.add(DirectoryFrame(itemKey: 'dir-$i', cursor: i, idCount: 100, songCount: 200));
      }
      final OrientationViewState state = OrientationViewState(directoryStack: deep).sanitized();
      expect(state.directoryStack.length, directoryStackLimit);
      // 栈顶在末尾，截断从栈底开始：留下的第一层是 i=6。
      expect(state.directoryStack.first.itemKey, 'dir-6');
      expect(state.directoryStack.last.itemKey, 'dir-69');
      expect(state.directoryStack.last.cursor, 69);
    });

    test('文本输入的 selection/composing 夹到文本域内', () {
      final TextInputState dirty = const TextInputState(
        text: 'hello',
        selectionBase: 99,
        selectionExtent: -2,
        composingStart: 3,
        composingEnd: 99,
        focused: true,
      ).sanitized();
      expect(dirty.selectionBase, 5);
      expect(dirty.selectionExtent, -2);
      expect(dirty.selectionStart, 3);
      expect(dirty.selectionEnd, 5);
      expect(dirty.composingStart, 3);
      expect(dirty.composingEnd, 5);
      expect(dirty.hasComposing, isTrue);
      expect(dirty.focused, isTrue, reason: 'focus 不得被夹取逻辑重置');
      expect(dirty.text, 'hello', reason: '文本原样跨旋转保留');

      final TextInputState noComposing =
          const TextInputState(text: 'ab', composingStart: -1, composingEnd: 3).sanitized();
      expect(noComposing.composingStart, -1);
      expect(noComposing.composingEnd, -1);
      expect(noComposing.hasComposing, isFalse);
    });

    test('编辑中的设置项 key 与光标（Overlay.qml:568,591）', () {
      const SettingEditState edit =
          SettingEditState(settingKey: 'listenbrainz.token', text: 'ab', cursor: 99);
      expect(edit.active, isTrue);
      expect(edit.sanitized().cursor, 2);
      expect(edit.sanitized().settingKey, 'listenbrainz.token');
      expect(const SettingEditState().active, isFalse, reason: '空 key 即没有在编辑');
      expect(const SettingEditState(text: 'x', cursor: -1).sanitized().cursor, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 5. 滚动曲线代次不重启（plan:376）
  // -------------------------------------------------------------------------
  group('滚动曲线代次', () {
    test('resumeAcrossRotation 不递增代次，nextGeneration 才递增', () {
      const CurveToken token = CurveToken(id: 'settings-scroll', generation: 7);
      final CurveToken resumed = token.resumeAcrossRotation();
      expect(resumed.generation, 7, reason: '旋转只 resume');
      expect(resumed.sameCurveAs(token), isTrue);
      expect(resumed, token);
      expect(token.nextGeneration().generation, 8);
      expect(token.nextGeneration().sameCurveAs(token), isFalse);
    });

    test('整条 capture -> restore 链路上曲线代次不变', () {
      const OrientationViewState state = OrientationViewState(
        curve: CurveToken(id: 'marquee', generation: 4),
      );
      final OrientationSnapshot snap = captureOrientationState(state, landscapeMetrics);
      expect(snap.state.curve.generation, 4);
      final OrientationViewState restored = restoreOrientationState(snap, portraitMetrics);
      expect(restored.curve.generation, 4, reason: '旋转不得让曲线从头开始');
      expect(restored.curve.id, 'marquee');
      expect(restored.curve.sameCurveAs(state.curve), isTrue);
      // sanitized 也走 resume 路径，不能偷偷 +1。
      expect(state.sanitized().curve.generation, 4);
    });

    test('不同曲线 identity 不因旋转混同', () {
      const CurveToken a = CurveToken(id: 'settings-scroll', generation: 4);
      const CurveToken b = CurveToken(id: 'volume', generation: 4);
      expect(a.sameCurveAs(b), isFalse);
      expect(a.resumeAcrossRotation().sameCurveAs(b.resumeAcrossRotation()), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 6. 五 lane + 目录栈 + 每层游标 round-trip
  // -------------------------------------------------------------------------
  group('跨旋转 round-trip', () {
    final OrientationViewState full = OrientationViewState(
      currentLane: 3,
      laneRowMemory: const <int>[0, 7, 2, 5, 1],
      directoryStack: const <DirectoryFrame>[
        DirectoryFrame(
          itemKey: 'liked',
          cursor: 20,
          index: 41,
          anchor: 17,
          albumCursor: 3,
          parentPhysical: 12,
          parentLane: 2,
          idCount: 60,
          songCount: 120,
        ),
        DirectoryFrame(
          itemKey: 'playlist-9',
          cursor: 0,
          index: 5,
          anchor: 8,
          albumCursor: 0,
          parentPhysical: 39,
          parentLane: 4,
          idCount: 40,
          songCount: 40,
        ),
        DirectoryFrame(
          itemKey: 'album-77',
          cursor: 12,
          index: 99,
          anchor: 31,
          albumCursor: 7,
          parentPhysical: 3,
          parentLane: 0,
          idCount: 12,
          songCount: 100,
        ),
      ],
      listAnchor: const ScrollAnchor(itemKey: 'album-7', itemIndex: 3, withinItem: 0.5),
      trackAnchor: const ScrollAnchor(itemKey: 'track-42', itemIndex: 17, withinItem: 0.5),
      bodyAnchor: const ScrollAnchor(itemKey: 'body-1', itemIndex: 0, withinItem: 0.5),
      queueAnchor: const ScrollAnchor(itemKey: 'queue-9', itemIndex: 5, withinItem: 0.5),
      selected: 22,
      musicCollection: 3,
      settingsScroll: 400,
      input: const TextInputState(
        text: 'rhine',
        selectionBase: 2,
        selectionExtent: 3,
        composingStart: 1,
        composingEnd: 4,
        focused: true,
      ),
      settingEdit: const SettingEditState(settingKey: 'server.url', text: 'http://a', cursor: 4),
      modal: const ModalState(name: 'queue', offset: 40),
      curve: const CurveToken(id: 'queue-scroll', generation: 2),
    );

    test('横屏 -> 竖屏：状态逐字段相等', () {
      final OrientationSnapshot snap = captureOrientationState(full, landscapeMetrics);
      expect(snap.crossesOrientation(portraitMetrics), isTrue);
      final OrientationViewState restored = restoreOrientationState(snap, portraitMetrics);
      expect(restored, full.sanitized());
      expect(restored.currentLane, 3);
      expect(restored.laneRowMemory, <int>[0, 7, 2, 5, 1]);
      expect(restored.selected, 22);
      expect(restored.musicCollection, 3);
      expect(restored.settingsScroll, closeTo(400, 1e-12));
      expect(restored.input.text, 'rhine');
      expect(restored.input.focused, isTrue);
      expect(restored.settingEdit.settingKey, 'server.url');
      expect(restored.modal.name, 'queue');
      expect(restored.queueAnchor.itemKey, 'queue-9');
      expect(restored.queueAnchor.withinItem, closeTo(0.5, 1e-12));
      expect(restored.curve.generation, 2);
    });

    test('目录栈每层游标逐层相等（含 index/anchor/page）', () {
      final OrientationViewState restored = restoreOrientationState(
        captureOrientationState(full, landscapeMetrics),
        portraitMetrics,
      );
      expect(restored.directoryStack.length, 3);
      for (int i = 0; i < full.directoryStack.length; i++) {
        final DirectoryFrame before = full.directoryStack[i].sanitized();
        final DirectoryFrame after = restored.directoryStack[i];
        expect(after, before, reason: '第 $i 层必须逐字段相等');
        expect(after.itemKey, before.itemKey);
        expect(after.cursor, before.cursor);
        expect(after.index, before.index);
        expect(after.anchor, before.anchor);
        expect(after.albumCursor, before.albumCursor);
        expect(after.parentPhysical, before.parentPhysical);
        expect(after.parentLane, before.parentLane);
        expect(after.page, before.page);
      }
      expect(restored.directoryStack[0].page, 40);
      expect(restored.directoryStack[2].page, 80);
    });

    test('竖屏 -> 横屏再回来：两次旋转后仍与原始状态相等（幂等）', () {
      final OrientationSnapshot once = captureOrientationState(full, landscapeMetrics);
      final OrientationViewState portrait = restoreOrientationState(once, portraitMetrics);
      final OrientationSnapshot twice = captureOrientationState(portrait, portraitMetrics);
      final OrientationViewState back = restoreOrientationState(twice, landscapeMetrics);
      expect(back, full.sanitized());
      expect(back.listAnchor.itemKey, 'album-7');
      expect(back.listAnchor.withinItem, closeTo(0.5, 1e-12));
    });

    test('滚动锚在两次旋转后仍解出同一相对位置', () {
      final OrientationViewState restored = restoreOrientationState(
        captureOrientationState(full, landscapeMetrics),
        portraitMetrics,
      );
      final ResolvedScrollOffsets resolved = resolveScrollOffsets(
        restored,
        list: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
        track: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
        body: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
        queue: const ScrollExtent(itemExtent: 96, itemCount: 100, viewportExtent: 900),
      );
      expect(resolved.list, closeTo(3.5 * 96, 1e-9));
      expect(resolved.track, closeTo(17.5 * 96, 1e-9));
      expect(resolved.body, closeTo(0.5 * 96, 1e-9));
      expect(resolved.queue, closeTo(5.5 * 96, 1e-9));
    });

    test('快照签名记录来源方向与缩放，但不参与还原计算', () {
      final OrientationSnapshot snap = captureOrientationState(full, landscapeMetrics);
      expect(snap.sourceOrientation, OrientationKind.landscape);
      expect(snap.sourceStageScale, closeTo(1 / 3, 1e-12));
      expect(snap.sourceStageWidth, closeTo(2400, 1e-9));
      expect(snap.sourceStageHeight, closeTo(1080, 1e-9));
      // 纯旋转短边不变 => 舞台缩放不变，只有舞台宽高互换。
      expect(snap.rescaleFactor(portraitMetrics), closeTo(1, 1e-12));
      expect(snap.crossesOrientation(landscapeMetrics), isFalse);
      // 还原结果只取决于快照状态，与传入的 metrics 数值无关（退化帧也原样返回，不抛错）。
      const StageMetrics otherPortrait = StageMetrics(
        orientation: OrientationKind.portrait,
        stageScale: 0.5,
        stageWidth: 1080,
        stageHeight: 2000,
        logicalWidth: 540,
        logicalHeight: 1000,
        devicePixelRatio: 2,
        insets: StageInsets.zero,
        cameraCompact: false,
      );
      expect(restoreOrientationState(snap, otherPortrait), restoreOrientationState(snap, portraitMetrics));
    });

    test('退化 resize 不抛错，随后有效 resize 继续沿用同一状态', () {
      final StageMetrics degenerate = compute(0, 0);
      final StageMetrics halfDegenerate = compute(1000, 0);
      expect(degenerate.stageScale, 0, reason: '退化输入的可度量标记：stageScale == 0');
      expect(halfDegenerate.stageScale, 0, reason: '任一边 <= 0 都是退化帧');
      final OrientationSnapshot snap = captureOrientationState(full, landscapeMetrics);
      // Qt/src/Engine.cpp:841-843：退化尺寸静默保留上一有效尺寸，从不抛错；
      // 对应地这里静默返回快照里的上一有效状态，而不是把异常锁成期望。
      final OrientationViewState duringDegenerate = restoreOrientationState(snap, degenerate);
      expect(duringDegenerate, full.sanitized());
      expect(duringDegenerate.selected, 22);
      expect(duringDegenerate.currentLane, 3);
      expect(restoreOrientationState(snap, halfDegenerate), duringDegenerate);
      // 退化帧之后再拿到有效度量：状态没有被清零或锁死，旋转仍只是舞台交换。
      final OrientationViewState afterValid = restoreOrientationState(snap, portraitMetrics);
      expect(afterValid, duringDegenerate, reason: '退化帧不改变后续有效帧的还原结果');
      final OrientationSnapshot recaptured = captureOrientationState(afterValid, portraitMetrics);
      expect(recaptured.sourceStageScale, closeTo(1 / 3, 1e-12));
      expect(recaptured.crossesOrientation(landscapeMetrics), isTrue);
      expect(restoreOrientationState(recaptured, landscapeMetrics), duringDegenerate);
    });
  });

  // -------------------------------------------------------------------------
  // 7. 纯函数性：capture/restore 不改输入，不持有外部状态
  // -------------------------------------------------------------------------
  group('纯函数性', () {
    test('capture 不修改传入的 state，restore 不修改快照', () {
      const OrientationViewState dirty = OrientationViewState(
        selected: 137,
        currentLane: 9,
        modal: ModalState(name: 'confirm'),
      );
      final OrientationSnapshot snap = captureOrientationState(dirty, landscapeMetrics);
      expect(dirty.selected, 137, reason: '输入对象不可变，capture 只产出新值');
      expect(dirty.currentLane, 9);
      expect(dirty.modal.name, 'confirm');
      final OrientationViewState restored = restoreOrientationState(snap, portraitMetrics);
      expect(identical(restored, snap.state), isFalse, reason: 'restore 返回新实例，不与快照共享可变引用');
      expect(snap.state.selected, 39);
    });

    test('sanitized 幂等：再规范化一次不再变化', () {
      const OrientationViewState dirty = OrientationViewState(
        selected: 137,
        musicCollection: 9,
        settingsScroll: 9999,
        currentLane: 9,
        laneRowMemory: <int>[9, -1, 300, 7, 5],
        modal: ModalState(name: 'queue', offset: 40),
        input: TextInputState(text: 'abc', selectionBase: 99, selectionExtent: 9),
      );
      final OrientationViewState once = dirty.sanitized();
      final OrientationViewState twice = once.sanitized();
      expect(twice, once);
      expect(twice.selected, 39);
      expect(twice.musicCollection, 4);
      expect(twice.settingsScroll, closeTo(764, 1e-12));
      expect(twice.currentLane, 4);
      expect(twice.laneRowMemory, <int>[7, 0, 7, 7, 5]);
      expect(twice.input.selectionBase, 3);
      expect(twice.input.selectionExtent, 0);
    });

    test('五 lane 的 rowMemory 与 lane 索引一一对应，不被重排', () {
      const OrientationViewState state = OrientationViewState(
        laneRowMemory: <int>[1, 2, 3, 4, 5],
      );
      expect(state.sanitized().laneRowMemory, <int>[1, 2, 3, 4, 5]);
      expect(state.sanitized().laneRowMemory.length, laneCount);
      expect(rowsPerPage, 8);
      expect(pageSize, 40);
    });
  });
}
