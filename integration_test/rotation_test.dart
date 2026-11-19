/// 旋转端到端测试。
///
/// 为什么是 flutter_test 而不是 integration_test：
///   pubspec.yaml 是共享文件，只声明 flutter_test（pubspec.yaml:38-40），没有
///   integration_test 依赖，因此本文件不能用 IntegrationTestWidgetsFlutterBinding。
///   这里用 flutter_test 的 tester.view.physicalSize + MediaQuery.fromView 模拟设备旋转：
///   旋转在 Flutter 侧就是一次 MediaQuery 重建。
///   真机上跑成 integration_test 需要宿主接线、真实传感器与真实 Node/媒体源；
///   设备上的像素/性能需真机验证。
///
/// 覆盖的 Qt 语义：
///   * 白名单七项 modal：Qt/src/MusicSession.cpp:243；磁盘序列化时 closing 存空串：:222。
///     旋转不是落盘，closing 中的 modal 必须保留名字与关闭进度。
///   * 夹取：selected [0,39]（:260）/ musicCollection [1,4]（:257）/
///     settingsScroll [0, settingsScrollMaximum]（:247 + NativeHud.h:132-135）/
///     rowMemory [0,7]（:111）。
///   * stage：Qt/qml/Main.qml:32-33、Qt/src/Engine.cpp:1353、
///     竖屏阈值 Qt/src/NativeSceneCamera.cpp:55-56（aspect < 1.05）。
///   * QR：MusicAccount.cpp:626/:631（300 x 1000ms 墙钟）、:352-379（generation + cancel 屏障）。
///   * 3D：NativeScene.cpp:217-224（旋转只 resize）、:250-259（review 才是 reset）、
///     NativeSceneInput.cpp:141-142（pointercancel -> resetPointer(false)）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/orientation_state.dart';
import 'package:rhine_music_database/app/rotation_continuity.dart';

/// 几何比较容差，与 A1 同值。
const double _tol = stageGeometryTolerance;

/// 横屏样机：2400x1080（Qt 舞台高 1080 在 dpr=1 时 stageScale=1）。
const Size _landscape = Size(2400, 1080);

/// 竖屏样机：1080x2400（竖屏舞台宽 1080 -> stageScale=1）。
const Size _portrait = Size(1080, 2400);

// 测试宿主：所有必须跨旋转存活的东西都活在这里，也就是 Widget 树之外

/// 旋转宿主：把 A1（几何 + 视图状态）与 A2（运行时连续性）接在一起。
///
/// 它存在的意义就是「旋转只重建 MediaQuery」：树里的 Widget 每次重建，
/// 而这里的状态、控制器、宿主对象不会被重建。
class RotationHarness {
  RotationHarness({String provider = 'netease'})
      : host = RotationContinuityHost(provider: provider),
        focusNode = FocusNode(debugLabel: 'query'),
        scrollController = ScrollController();

  final RotationContinuityHost host;

  /// 焦点/滚动控制器：只有它们住在树外，旋转才不会丢焦点或跳回顶部。
  final FocusNode focusNode;
  final ScrollController scrollController;

  /// 输入框文本。
  String queryText = '';

  /// 跨旋转的视图状态（A1）。
  OrientationViewState view = const OrientationViewState();

  /// 当前舞台度量。
  StageMetrics? metrics;

  /// 最近一次旋转的捕获快照（诊断用，不参与还原计算）。
  OrientationSnapshot? lastSnapshot;

  /// Widget 重建次数与真实方向变化次数。
  int rebuilds = 0;
  int orientationChanges = 0;

  /// 观察到的方向序列，用来断言 10 次往返确实产生 20 次方向变化。
  final List<OrientationKind> observedOrientations = <OrientationKind>[];

  /// 每个方向下解出的绝对滚动偏移（唯一的像素出口）。
  final Map<OrientationKind, ResolvedScrollOffsets> resolvedByOrientation =
      <OrientationKind, ResolvedScrollOffsets>{};

  /// 滚动区度量：行高/视口按方向不同，resolveNow 必须按当前
  /// metrics.orientation 选择。若两个方向共用一套 extent，
  /// 「portrait == landscape」只是恒真，无法证明两个方向真的分开。
  ScrollExtent _listExtentFor(OrientationKind orientation) =>
      orientation == OrientationKind.portrait
          ? const ScrollExtent(itemExtent: 32, itemCount: 40, viewportExtent: 720)
          : const ScrollExtent(itemExtent: 24, itemCount: 40, viewportExtent: 720);

  ScrollExtent _trackExtentFor(OrientationKind orientation) =>
      orientation == OrientationKind.portrait
          ? const ScrollExtent(itemExtent: 64, itemCount: 20, viewportExtent: 520)
          : const ScrollExtent(itemExtent: 56, itemCount: 20, viewportExtent: 520);

  ScrollExtent _bodyExtentFor(OrientationKind orientation) =>
      orientation == OrientationKind.portrait
          ? const ScrollExtent(itemExtent: 40, itemCount: 60, viewportExtent: 600)
          : const ScrollExtent(itemExtent: 32, itemCount: 60, viewportExtent: 600);

  /// 播放队列滚动区：A1 的 queueAnchor 需要独立 extent（Qt queueOffset 的上界
  /// 由 PlaybackQueueCard::maximumOffset 给出，见 NativeHudPlayer.cpp:47）。
  ScrollExtent _queueExtentFor(OrientationKind orientation) =>
      orientation == OrientationKind.portrait
          ? const ScrollExtent(itemExtent: 56, itemCount: 20, viewportExtent: 400)
          : const ScrollExtent(itemExtent: 48, itemCount: 20, viewportExtent: 400);

  /// 直接采纳一份已经在方向无关域的视图状态。
  void adoptView(OrientationViewState next) {
    view = next.sanitized();
  }

  ResolvedScrollOffsets resolveNow() {
    final OrientationKind orientation =
        metrics?.orientation ?? OrientationKind.landscape;
    return resolveScrollOffsets(
      view,
      list: _listExtentFor(orientation),
      track: _trackExtentFor(orientation),
      body: _bodyExtentFor(orientation),
      queue: _queueExtentFor(orientation),
    );
  }

  /// 每次 Widget 重建都会走这里：重算 stage，只在方向真的变了时捕获/还原。
  void observe(MediaQueryData mq) {
    final StageInsets insets = StageInsets(
      top: mq.padding.top,
      bottom: mq.padding.bottom,
      left: mq.padding.left,
      right: mq.padding.right,
      imeBottom: mq.viewInsets.bottom,
    );
    final OrientationKind orientation = classifyOrientation(
      logicalWidth: mq.size.width,
      logicalHeight: mq.size.height,
    );
    final StageInputs inputs = orientation == OrientationKind.portrait
        ? StageInputs.portraitFromWindow(
            logicalWidth: mq.size.width,
            windowHeight: mq.size.height,
            insets: insets,
            devicePixelRatio: mq.devicePixelRatio,
          )
        : StageInputs(
            logicalWidth: mq.size.width,
            logicalHeight: mq.size.height,
            devicePixelRatio: mq.devicePixelRatio,
            insets: insets,
          );
    final StageMetrics next = StageMetrics.compute(inputs);
    rebuilds++;
    final StageMetrics? previous = metrics;
    metrics = next;
    observedOrientations.add(next.orientation);
    if (previous == null) {
      return;
    }
    resolvedByOrientation[next.orientation] = resolveNow();
    if (previous.orientation == next.orientation) {
      // 同方向的尺寸变化只重算 stage，不重建会话状态。
      return;
    }
    final OrientationSnapshot snapshot = captureOrientationState(view, previous);
    lastSnapshot = snapshot;
    // 还原是方向无关的：没有任何「旧像素 -> 新像素」的换算。
    view = restoreOrientationState(snapshot, next);
    // 运行时连续性侧：只 resize，绝不重建。
    host.applyViewport(ViewportFrame(
      logicalWidth: next.logicalWidth,
      logicalHeight: next.logicalHeight,
      devicePixelRatio: next.devicePixelRatio,
      insets: ViewportInsets(
        top: mq.padding.top,
        right: mq.padding.right,
        bottom: mq.padding.bottom,
        left: mq.padding.left,
      ),
      imeInset: mq.viewInsets.bottom,
    ));
    orientationChanges++;
  }
}

/// 被测树：不持有任何需要跨旋转存活的对象，全部来自 [RotationHarness]。
class RotationRoot extends StatelessWidget {
  const RotationRoot({super.key, required this.harness});

  final RotationHarness harness;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    harness.observe(mq);
    final StageMetrics metrics = harness.metrics!;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: metrics.logicalWidth,
        height: metrics.logicalHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('orientation:${metrics.orientation.name}'),
            Text('stage:${metrics.stageWidth.toStringAsFixed(1)}x${metrics.stageHeight.toStringAsFixed(1)}@${metrics.stageScale.toStringAsFixed(3)}'),
            // 焦点住在树外：旋转不该丢焦点。
            Focus(
              focusNode: harness.focusNode,
              child: SizedBox(
                height: 24,
                child: Text('query:${harness.queryText}'),
              ),
            ),
            // 滚动控制器住在树外：旋转不该跳回顶部。
            Expanded(
              child: ListView.builder(
                controller: harness.scrollController,
                itemCount: 40,
                itemBuilder: (BuildContext context, int index) => SizedBox(
                  height: 24,
                  child: Text('row $index'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 测试工具

Future<void> _pumpRoot(WidgetTester tester, RotationHarness harness) async {
  await tester.pumpWidget(
    MediaQuery.fromView(
      view: tester.view,
      child: RotationRoot(harness: harness),
    ),
  );
}

/// 旋转 = 改视口尺寸 + 重建（MediaQuery 变化驱动重建）。
Future<void> _rotate(WidgetTester tester, Size logical) async {
  tester.view.physicalSize = logical * tester.view.devicePixelRatio;
  await tester.pump();
}

void _useViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 造一份有内容的会话状态：五 lane、目录栈、游标、选中、输入、白名单 modal、曲线代次。
OrientationViewState _seededView() => const OrientationViewState(
      currentLane: 2,
      laneRowMemory: <int>[1, 2, 3, 4, 5],
      directoryStack: <DirectoryFrame>[
        DirectoryFrame(itemKey: 'root', cursor: 0, index: 0, anchor: 0, albumCursor: 0),
        DirectoryFrame(
          itemKey: 'album/9',
          cursor: 3,
          index: 41,
          anchor: 33,
          albumCursor: 2,
          parentPhysical: 12,
          parentLane: 1,
          idCount: 8,
          songCount: 90,
        ),
      ],
      listAnchor: ScrollAnchor(itemKey: 'song/77', itemIndex: 5, withinItem: 0.25),
      trackAnchor: ScrollAnchor(itemKey: 'track/12', itemIndex: 3, withinItem: 0.5),
      bodyAnchor: ScrollAnchor(itemKey: 'body/1', itemIndex: 9, withinItem: 1),
      queueAnchor: ScrollAnchor(itemKey: 'queue/77', itemIndex: 5, withinItem: 0.5),
      selected: 12,
      musicCollection: 3,
      settingsScroll: 240,
      input: TextInputState(
        text: '夜空',
        selectionBase: 1,
        selectionExtent: 1,
        composingStart: 0,
        composingEnd: 2,
        focused: true,
      ),
      settingEdit: SettingEditState(settingKey: 'player.gain', text: '0.8', cursor: 2),
      modal: ModalState(name: 'queue', offset: 42.5),
      curve: CurveToken(id: 'settings-scroll', generation: 7),
    ).sanitized();

Map<String, Object?> _track(String id) => <String, Object?>{
      'provider': 'netease',
      'id': id,
      'title': 'track $id',
    };

void main() {
  // 1. stage 重算 + 视图状态跨旋转
  testWidgets('横屏 -> 竖屏：stage 按 Qt 重算，视图状态逐字段保持', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    final RotationHarness harness = RotationHarness();
    await _pumpRoot(tester, harness);

    expect(harness.metrics!.orientation, OrientationKind.landscape);
    // Qt/qml/Main.qml:32 "stageScale = height / 1080"。
    expect(harness.metrics!.stageScale, closeTo(1.0, _tol));
    expect(harness.metrics!.stageHeight, closeTo(qtStageHeightUnits, _tol));
    expect(harness.metrics!.stageWidth, closeTo(2400, _tol));

    final OrientationViewState seeded = _seededView();
    harness.adoptView(seeded);
    await tester.pump();

    final ResolvedScrollOffsets landscapeOffsets = harness.resolveNow();
    expect(landscapeOffsets.list, closeTo(5.25 * 24, 1e-9));
    expect(landscapeOffsets.track, closeTo(3.5 * 56, 1e-9));
    expect(landscapeOffsets.body, closeTo(10.0 * 32, 1e-9));
    expect(landscapeOffsets.queue, closeTo(5.5 * 48, 1e-9));
    expect(landscapeOffsets.settings, closeTo(240, _tol));

    await _rotate(tester, _portrait);

    expect(harness.metrics!.orientation, OrientationKind.portrait);
    expect(harness.orientationChanges, 1);
    // 竖屏舞台宽不变量（见 lib/ui/layout/portrait_bands.dart:32）。
    expect(harness.metrics!.stageWidth, closeTo(portraitStageWidthUnits, _tol));
    expect(harness.metrics!.stageScale, closeTo(1.0, _tol));

    // 方向无关域：逐字段相等（这是「任一项归零/重建」的反面）。
    expect(harness.view, seeded);
    expect(harness.view.currentLane, 2);
    expect(harness.view.laneRowMemory, <int>[1, 2, 3, 4, 5]);
    expect(harness.view.directoryStack.length, 2);
    expect(harness.view.directoryStack.last.itemKey, 'album/9');
    expect(harness.view.directoryStack.last.anchor, 33);
    expect(harness.view.directoryStack.last.page, 40);
    expect(harness.view.selected, 12);
    expect(harness.view.musicCollection, 3);
    expect(harness.view.modal, const ModalState(name: 'queue', offset: 42.5));
    expect(harness.view.input.text, '夜空');
    expect(harness.view.input.selectionStart, 1);
    expect(harness.view.input.selectionEnd, 2);
    expect(harness.view.input.hasComposing, isTrue);
    expect(harness.view.input.focused, isTrue);
    expect(
      harness.view.settingEdit,
      const SettingEditState(settingKey: 'player.gain', text: '0.8', cursor: 2),
    );
    expect(harness.view.curve, const CurveToken(id: 'settings-scroll', generation: 7));

    // 相对锚不变，绝对像素按「新方向自己的 extent」现算。
    // 竖屏行高与横屏不同，若两方向共用 extent，这些断言会退化为恒真。
    final ResolvedScrollOffsets portraitOffsets = harness.resolveNow();
    expect(portraitOffsets.list, closeTo(5.25 * 32, 1e-9));
    expect(portraitOffsets.track, closeTo(3.5 * 64, 1e-9));
    expect(portraitOffsets.body, closeTo(10.0 * 40, 1e-9));
    expect(portraitOffsets.queue, closeTo(5.5 * 56, 1e-9));
    expect(portraitOffsets.list, isNot(landscapeOffsets.list));
    expect(portraitOffsets.track, isNot(landscapeOffsets.track));
    expect(portraitOffsets.body, isNot(landscapeOffsets.body));
    expect(portraitOffsets.queue, isNot(landscapeOffsets.queue));
    // 方向无关的锚三元组必须原样存活（capture/restore 不换算像素）。
    expect(harness.view.listAnchor, seeded.listAnchor);
    expect(harness.view.trackAnchor, seeded.trackAnchor);
    expect(harness.view.bodyAnchor, seeded.bodyAnchor);
    expect(harness.view.queueAnchor, seeded.queueAnchor);
    expect(harness.resolvedByOrientation[OrientationKind.portrait]!.track,
        closeTo(3.5 * 64, 1e-9));

    // 同方向改尺寸：只重算 stage，不产生第二次方向变化。
    await _rotate(tester, const Size(1000, 2200));
    expect(harness.orientationChanges, 1);
    expect(harness.metrics!.orientation, OrientationKind.portrait);
    expect(harness.view, seeded);

    // 竖屏安全区：portrait 必须在 compute 前用 layoutH 扣除 safe.top/bottom
    //（见 layout.md:287/:299），且 IME 不参与 stage。
    await _rotate(tester, _portrait);
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 24);
    addTearDown(tester.view.resetPadding);
    await _pumpRoot(tester, harness);
    expect(harness.metrics!.orientation, OrientationKind.portrait);
    expect(harness.metrics!.logicalHeight, closeTo(2336, _tol));
    expect(harness.metrics!.stageScale, closeTo(1.0, _tol));
    expect(harness.metrics!.stageHeight, closeTo(2336, _tol));
    expect(harness.metrics!.stageHeight, isNot(2400));
  });

  // 2. modal 白名单与 closing
  testWidgets('白名单外 modal 不恢复；closing 中的 modal 保留名字与关闭进度，仅落盘名为空', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    final RotationHarness harness = RotationHarness();
    await _pumpRoot(tester, harness);

    // Qt 白名单只有七项（MusicSession.cpp:243）；歌词偏移面板不在其中。
    // 这里必须用非 sanitizing 的 helper 写入 raw modal；否则 .sanitized()
    // 会在 capture 之前就把它清掉，旋转后的断言变成空转。
    harness.view = _withModal(harness.view, const ModalState(name: 'lyrics-offset', offset: 30));
    await tester.pump();
    expect(harness.view.modal.name, 'lyrics-offset');
    await _rotate(tester, _portrait);
    expect(harness.view.modal, ModalState.none);

    // Qt 只在磁盘序列化时把 closing 写成空串（MusicSession.cpp:222）；
    // 运行时旋转必须保留 modal 名、closing 标志和关闭动画位置。
    harness.view = _withModal(harness.view, const ModalState(name: 'queue', closing: true, offset: 12));
    await tester.pump();
    await _rotate(tester, _landscape);
    expect(harness.view.modal, const ModalState(name: 'queue', closing: true, offset: 12));
    expect(harness.view.modal.diskModalName, '');

    // 七项白名单逐个跨旋转存活。
    for (final String name in const <String>[
      'saved',
      'search',
      'discover',
      'queue',
      'settings',
      'player',
      'local',
    ]) {
      harness.view = _withModal(harness.view, ModalState(name: name, offset: 8));
      await tester.pump();
      await _rotate(tester, _portrait);
      expect(harness.view.modal.name, name, reason: name);
      expect(harness.view.modal.offset, closeTo(8, _tol), reason: name);
      await _rotate(tester, _landscape);
    }
  });

  // 3. 10 次往返：不重复登录 / 不重启 Node / 不重建媒体源 / 无泄漏
  testWidgets('10 次横竖往返：login/Node/媒体源各一次，监听器无泄漏', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    final RotationHarness harness = RotationHarness();
    harness.host.startRuntime();
    await _pumpRoot(tester, harness);

    final ResourceLedger ledger = harness.host.ledger;
    expect(ledger.loginCount, 1);
    expect(ledger.nodeStartCount, 1);
    expect(ledger.mediaSourceBuildCount, 1);

    for (int i = 0; i < 10; i++) {
      await _rotate(tester, _portrait);
      await _rotate(tester, _landscape);
    }

    expect(harness.orientationChanges, 20);
    expect(harness.observedOrientations.length, 21);
    // 旋转没有重新登录、没有重启 Node、没有重建媒体源。
    expect(ledger.loginCount, 1);
    expect(ledger.loginAttempts, 1);
    expect(ledger.nodeStartCount, 1);
    expect(ledger.nodeStartAttempts, 1);
    expect(ledger.mediaSourceBuildCount, 1);
    expect(ledger.mediaSourceReuseCount, 20);
    // 监听器是重绑而不是新建。
    expect(ledger.created('stageListener'), 1);
    expect(ledger.live('stageListener'), 1);
    expect(ledger.stageRebindCount, 20);
    expect(harness.host.viewportRevision, 20);

    // 宿主自己持有的资源能释放干净，账目平衡。
    harness.host.dispose();
    expect(ledger.disposed('stageListener'), 1);
    expect(ledger.live('stageListener'), 0);
    expect(ledger.balanced, isTrue);
  });

  // 4. QR：墙钟 + generation + cancel 屏障
  testWidgets('QR 跨旋转：generation/二维码/相位/剩余墙钟不变，旋转不取消登录', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    // production wiring 传 providerIsQq: provider == 'qq'；本用例覆盖 QQ
    // cancel 屏障，host 必须真的是 QQ，否则非 QQ 短路语义会掩盖问题。
    final RotationHarness harness = RotationHarness(provider: 'qq');
    await _pumpRoot(tester, harness);

    final QrLoginContinuity login = harness.host.login;
    expect(login.beginPrepare(0), 1);
    expect(login.acceptKey(1, 'key-a'), isTrue);
    expect(login.acceptImage(1, 'data:image/png;base64,AAAA'), isTrue);
    login.markWaiting(1, scannerName: '手机');
    login.markScanned(1);
    login.observeWallClock(4000);

    final Map<String, Object?> before = Map<String, Object?>.from(
      harness.host.describe()['login']! as Map<String, Object?>);

    await _rotate(tester, _portrait);
    await _rotate(tester, _landscape);

    final Map<String, Object?> after = Map<String, Object?>.from(
      harness.host.describe()['login']! as Map<String, Object?>);
    expect(after, before);
    expect(login.generation, 1);
    expect(login.qrKey, 'key-a');
    expect(login.loginPhase, QrLoginPhase.confirming);
    expect(login.loginMethod, 'qr');
    // 300 x 1000ms 墙钟预算（MusicAccount.cpp:626,:631），旋转不重置。
    expect(login.remainingMs(), 296000);
    expect(login.keyRequestCount, 1);
    expect(login.checkRequestCount, 0);

    // cancel 屏障：请求发起后 generation 前移，屏障挂起。
    expect(login.cancel(observedGeneration: 1), QrCancelOutcome.requested);
    expect(login.cancelRequestCount, 1);
    expect(login.pendingCancel, isNotNull);
    final int banner = login.generation;

    // 屏障挂起期间旋转：既不能完成屏障，也不能丢掉它。
    await _rotate(tester, _portrait);
    expect(login.pendingCancel, isNotNull);
    expect(login.pendingCancel!.completed, isFalse);
    expect(login.generation, banner);
    expect(login.cancelRequestCount, 1);

    // 第二次 closeModal 只能 join，不能再 bump（否则会打断在途请求）。
    expect(login.cancel(observedGeneration: banner), QrCancelOutcome.joined);
    expect(login.cancelRequestCount, 1);

    expect(login.completeCancel('key-a', true), isTrue);
    expect(login.pendingCancel, isNull);
    // 观察到的 generation 比实时旧 => 拒绝，且不碰新码（MusicAccount.cpp:353-356）。
    expect(login.cancel(observedGeneration: 1), QrCancelOutcome.rejectedStale);
    expect(login.generation, banner);
  });

  // 5. 播放 / 队列 / 歌词
  testWidgets('播放队列与歌词偏移跨旋转保留，不重新加载', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    final RotationHarness harness = RotationHarness();
    harness.host.startRuntime();
    await _pumpRoot(tester, harness);

    final PlaybackContinuity playback = harness.host.playback;
    playback.current = _track('song-1');
    playback.queue = <Map<String, Object?>>[_track('song-0'), _track('song-1'), _track('song-2')];
    playback.index = 1;
    playback.mode = 'one';
    playback.position = 43210.5;
    playback.requested = true;
    playback.loading = false;
    playback.preview = false;
    for (int i = 0; i < 5; i++) {
      playback.history.add(_track('hist-$i'));
    }

    final LyricsContinuity lyrics = harness.host.lyrics;
    lyrics.document = <String, Object?>{
      'offsetMs': 120.0,
      'lines': <Map<String, Object?>>[
        <String, Object?>{'startMs': 0.0},
        <String, Object?>{'startMs': 5000.0},
        <String, Object?>{'startMs': 12000.0},
      ],
    };
    lyrics.status = 'ready';
    lyrics.key = 'netease:song-1';
    lyrics.localSource = 'local';
    lyrics.lyricsMode = true;
    lyrics.playingTrack = playback.current;
    lyrics.offsetMs = 1200;
    lyrics.syncPosition(6000);
    final int lineIndexBefore = lyrics.index;
    final Map<String, Object?> lyricsBefore = lyrics.playbackSnapshot();

    await _rotate(tester, _portrait);
    await _rotate(tester, _landscape);

    expect(playback.current, _track('song-1'));
    expect(playback.queue.length, 3);
    expect(playback.index, 1);
    expect(playback.mode, 'one');
    expect(playback.effectivePositionMs, closeTo(43210.5, _tol));
    expect(playback.effectiveRequested, isTrue);
    // history 不在 session archive 里，只靠对象存活（MusicPlayer.h:41）。
    expect(playback.history.length, 5);

    expect(lyrics.offsetMs, 1200);
    expect(lyrics.index, lineIndexBefore);
    expect(lyrics.localSource, 'local');
    expect(lyrics.lyricsMode, isTrue);
    expect(lyrics.playbackSnapshot(), lyricsBefore);
    // 用户偏移的夹取仍按 Qt（LyricsController.cpp:515），旋转不重置也不重新夹取。
    expect(lyrics.adjustOffset(0), 1200);
    expect(lyrics.adjustOffset(999999), kLyricsOffsetLimitMs);
    expect(lyrics.adjustOffset(-999999), -kLyricsOffsetLimitMs);
    lyrics.resetOffset();
    expect(lyrics.offsetMs, 0);
    // 旋转不应推进播放位置（position 由 tick 推，不由旋转推）。
    expect(lyrics.positionMs, 6000);
  });

  // 6. 3D 场景 / viewer / 拖拽
  testWidgets('3D 相机/时钟/boot/viewer 不重置；拖拽被取消而动量与选中卡保留', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    final RotationHarness harness = RotationHarness();
    await _pumpRoot(tester, harness);

    final SceneContinuity scene = harness.host.scene;
    scene.advanceClockTo(12.5);
    scene.setMode('detail');
    scene.selected = 7;
    scene.eye = <double>[1, 2, 3];
    scene.aim = <double>[4, 5, 6];
    scene.detail = 0.4;
    scene.rotation = 0.2;
    scene.scanTime = 29.1;
    final bool opened = scene.viewer.beginOpen(3.0);
    expect(opened, isTrue);
    expect(scene.viewer.openCount, 1);
    final int resetsBefore = scene.viewer.resetCount;
    final String transitionBefore = scene.viewer.transition;
    final double clockBefore = scene.clock;
    final double bootBefore = scene.bootStart;
    final double elapsedBefore = scene.elapsed;

    final DragContinuity drag = harness.host.drag;
    drag.captured = true;
    drag.dragging = true;
    drag.holding = true;
    drag.dragTrack = _track('card-3');
    drag.hoveredCard = _track('card-3');
    drag.hasMomentum = true;
    drag.velocityX = 1.5;
    drag.velocityY = -0.5;
    drag.targetRotation = 0.35;

    final bool cancelled = harness.host.applyViewport(
      const ViewportFrame(logicalWidth: 1080, logicalHeight: 2400, devicePixelRatio: 1),
    );

    // NativeSceneInput.cpp:141-142 -> resetPointer(false)：拖拽被取消，动量保留。
    expect(cancelled, isTrue);
    expect(drag.cancelCount, 1);
    expect(drag.captured, isFalse);
    expect(drag.dragging, isFalse);
    expect(drag.holding, isFalse);
    expect(drag.dragTrack, isNull);
    expect(drag.pendingHover, isNull);
    expect(drag.hasMomentum, isTrue);
    expect(drag.velocityX, 1.5);
    expect(drag.velocityY, -0.5);
    // 选中卡属于 SceneContinuity，resetPointer 不碰它。
    expect(scene.selected, 7);

    // NativeScene.cpp:217-224：只换 viewport，不碰相机/时钟/boot/viewer。
    expect(scene.clock, clockBefore);
    expect(scene.bootStart, bootBefore);
    expect(scene.elapsed, elapsedBefore);
    expect(scene.mode, 'detail');
    expect(scene.eye, <double>[1, 2, 3]);
    expect(scene.aim, <double>[4, 5, 6]);
    expect(scene.detail, 0.4);
    expect(scene.rotation, 0.2);
    expect(scene.viewportChangeCount, 1);
    expect(scene.width, 1080);
    expect(scene.height, 2400);
    // viewer 只被 resize，不被重新打开或 reset（NativeScene.cpp:223）。
    expect(scene.viewer.openCount, 1);
    expect(scene.viewer.resetCount, resetsBefore);
    expect(scene.viewer.transition, transitionBefore);
    expect(scene.viewer.resizeCount, 1);
    expect(scene.viewer.open, isTrue);

    // 没有在拖拽时，旋转不产生 cancel。
    expect(
      harness.host.applyViewport(
        const ViewportFrame(logicalWidth: 2400, logicalHeight: 1080, devicePixelRatio: 1),
      ),
      isFalse,
    );
    expect(drag.cancelCount, 1);
  });

  // 7. 树内焦点/滚动控制器跨旋转仍在
  testWidgets('焦点与滚动控制器住在树外，旋转后不丢', (WidgetTester tester) async {
    _useViewport(tester, _landscape);
    final RotationHarness harness = RotationHarness();
    await _pumpRoot(tester, harness);

    harness.queryText = '夜空';
    harness.focusNode.requestFocus();
    await tester.pump();
    expect(harness.focusNode.hasFocus, isTrue);
    expect(harness.scrollController.hasClients, isTrue);

    await _rotate(tester, _portrait);
    await _rotate(tester, _landscape);

    expect(harness.focusNode.hasFocus, isTrue);
    expect(harness.scrollController.hasClients, isTrue);
    expect(tester.takeException(), isNull);
  });

  // 8. fixture 与 ARCH_BLOCKED 的静态记录
  test('rotation_state.json 是合成 fixture，不是设备证据', () {
    final File file = File('test/fixtures/rotation_state.json');
    expect(file.existsSync(), isTrue, reason: 'T44 fixture 必须存在');
    final Object? decoded = jsonDecode(file.readAsStringSync());
    expect(decoded, isA<Map<String, Object?>>());
    final Map<String, Object?> map = decoded! as Map<String, Object?>;
    final bool flagged = map['synthetic'] == true || map['not_device_evidence'] == true;
    expect(flagged, isTrue, reason: 'fixture 必须声明为合成数据，不得当作设备证据');
  });

  test('ARCH_BLOCKED 记录：pubspec 无 integration_test 依赖，本文件只能走 flutter_test 通道', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('flutter_test:'), isTrue);
    // 真机 integration_test 绑定需要新增依赖（pubspec 禁改），故此处不可能绑定；
    // 真实旋转/Node 存活/媒体源复用的设备证据属于 ARCH_BLOCKED / DEVICE_BLOCKED。
    expect(pubspec.contains('integration_test:'), isFalse);
  });
}

/// 只替换 modal 位，其余字段保持，便于逐条验证白名单。
OrientationViewState _withModal(OrientationViewState state, ModalState modal) =>
    OrientationViewState(
      currentLane: state.currentLane,
      laneRowMemory: state.laneRowMemory,
      directoryStack: state.directoryStack,
      listAnchor: state.listAnchor,
      trackAnchor: state.trackAnchor,
      bodyAnchor: state.bodyAnchor,
      queueAnchor: state.queueAnchor,
      selected: state.selected,
      musicCollection: state.musicCollection,
      settingsScroll: state.settingsScroll,
      settingsContentBottom: state.settingsContentBottom,
      input: state.input,
      settingEdit: state.settingEdit,
      modal: modal,
      curve: state.curve,
    );
