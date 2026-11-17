// T21-C19-W2（atom T21-C19-A2）｜桥接生命周期集成测试（接管 T21-C14 草稿）
//
// 计划卡：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:524-531（T21）
// 唯一权威源：Qt/src/BridgeProcessAndroid.cpp（281 行）+ Qt/src/BridgeProcess.h
// 协议对端：MusicBridge/ios-runtime.cjs（:7 argv[2]=port、:16 首帧 {token}、:24-90 帧分派）
// 复用源（只读，最小修复后内联，不整份搬运）：sourceSha=2cb83d1ac48c09286e911b691f6a31c39c0a1a4a
//   lib/bootstrap/bridge_frame_decoder.dart（0x0a 分帧、会话过滤先于 base64 解码）
//
// RED/GREEN 未执行：T21 全程禁止 flutter test / dart test / analyze / 设备执行，本文件只写了断言。
// 本文件按计划卡以 integration_test 形态编写（T21 pass 判据之一：
//   flutter test integration_test/bridge_lifecycle_test.dart，见 plan:530-531）。
// 依赖（NR-10 纠正）：integration_test 是**真实依赖**，不是要删的东西——主集成 root 的
// pubspec.yaml 已在提交 7f3439e2→9aec047 加入 `integration_test: sdk: flutter`，现在仍然存在。
// 因此本文件保留 package:integration_test 的真实导入与 IntegrationTestWidgetsFlutterBinding。
// 【隔离树状态】本 T21 树的基线 8ed3067b 早于 9aec047，隔离树的 pubspec.yaml 里暂时看不到该
// 声明；这属于共享配置（pubspec 不在本卡写域），不改 pubspec、不跑 pub get，仅登记
// DEPENDENCY_ON_SHARED_CONFIG，由唯一集成 owner 应用已审配置（详见报告 NR-10 条目）。
// 仿真器部分只用内存内的确定性对端；跨模块部分用真实回环 socket 驱动真实 NodeRuntime，
// 但宿主仍是本地假宿主（plan:527 不自嵌 Node），绝不启动真实 Node、不申请设备权限。
//
// 覆盖：Qt 宿主 ↔ ios-runtime.cjs 的完整会话生命周期，跨 engine_transport.dart 与
// node_runtime.dart 两个模块的冻结契约（wire keys / 握手排队 / 会话过滤 / 崩溃回传 / 旋转不重启）：
//   A 线路级仿真（_EmulatedNodeRuntime）＋ B 真实回环（真 NodeRuntime + 真 socket + 真 link）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// 用户 m10088：lib/app/lifecycle.dart（68b4d60）已整体撤回，本文件不再依赖它。
// import 'package:rhine_music_database/app/lifecycle.dart';
import 'package:rhine_music_database/bridge/engine_transport.dart';
import 'package:rhine_music_database/bridge/node_runtime.dart';

/// 原生侧单条回环控制连接的确定性仿真器。
///
/// 严格照 Qt/src/BridgeProcessAndroid.cpp:40-169 的宿主语义建模：
///   * 进程级一次性 token（:47），非每会话；
///   * 认证前 send() 落入排队缓冲（:134-137），认证通过后一次性 flush（:90）；
///   * 出站帧一律 compact JSON + 0x0a 定界（:130-133 的 QJsonDocument::Compact + '\n'）；
///   * 缓冲区超过 48 MiB 直接毁链（:73）；
///   * 认证只接受第一帧，且必须是 {token: <实例 token>}。
class _EmulatedNodeRuntime implements EngineRuntimeLink {
  _EmulatedNodeRuntime({required this.token});

  /// 进程级 token，等价 QUuid::createUuid().toString(QUuid::WithoutBraces)。
  final String token;

  /// 认证后真正写出的帧（顺序即线路顺序）。
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  /// 每个出站帧的原始字节（含 0x0a 定界），用于校验 Qt 线路格式。
  final List<Uint8List> wireBytes = <Uint8List>[];

  /// 认证前排队缓冲（Qt: QByteArray queued）。
  final List<Map<String, Object?>> queued = <Map<String, Object?>>[];

  final StreamController<Map<String, Object?>> _inbound =
      StreamController<Map<String, Object?>>.broadcast();

  bool isAuthenticated = false;
  bool isClosed = false;

  /// node::Start 只允许成功一次（BridgeProcessAndroid.cpp:98-100 的 launched 幂等）；
  /// 该计数用于证明「旋转/重建 UI 不重启 runtime」。
  int runtimeStartCount = 0;

  int _inputBytes = 0;

  @override
  Stream<Map<String, Object?>> get messages => _inbound.stream;

  @override
  bool get isLive => !isClosed;

  @override
  void send(Map<String, Object?> message) {
    if (isClosed) {
      throw StateError('send after close');
    }
    // 测试侧守卫：累计出站字节超过 48 MiB 就让仿真对端失效。注意这不是 Qt 的规则——
    // BridgeProcessAndroid.cpp:73 的 48 MiB 量的是**宿主读 Node 的读缓冲**（在
    // node_runtime.dart 的 _ByteQueue 上）；出站方向 Qt 没有任何上限。
    final Uint8List encoded = _encode(message);
    _inputBytes += encoded.length;
    if (_inputBytes > NodeWire.maxFrameBytes) {
      isClosed = true;
      throw StateError('frame budget exceeded');
    }
    if (!isAuthenticated) {
      queued.add(message);
      return;
    }
    _write(message);
  }

  /// 对端（ios-runtime.cjs:16）连上后发出的第一帧：{token}。
  /// 返回被 flush 的排队帧，顺序必须与排队顺序一致。
  List<Map<String, Object?>> authenticate(String presentedToken) {
    if (presentedToken != token) {
      // Qt: 首个消息 token 不匹配 → socket->abort()。
      isClosed = true;
      throw StateError('bad token');
    }
    if (!isAuthenticated) {
      isAuthenticated = true;
      runtimeStartCount += 1;
      final List<Map<String, Object?>> flushed =
          List<Map<String, Object?>>.of(queued);
      queued.clear();
      for (final Map<String, Object?> frame in flushed) {
        _write(frame);
      }
      return flushed;
    }
    return const <Map<String, Object?>>[];
  }

  /// 模拟宿主侧入站帧（来自 worker/runtime 的 0x0a 定界 JSON）。
  void emit(Map<String, Object?> frame) {
    _inbound.add(frame);
  }

  void _write(Map<String, Object?> message) {
    sent.add(message);
    wireBytes.add(_encode(message));
  }

  Uint8List _encode(Map<String, Object?> message) {
    final List<int> payload = utf8.encode(jsonEncode(message));
    return Uint8List.fromList(<int>[...payload, NodeWire.delimiter]);
  }

  Future<void> dispose() async {
    isClosed = true;
    await _inbound.close();
  }
}

/// 让 EngineTransport 以 model 身份在测试里跑起来的最小 harness。
class _Harness {
  _Harness(this.runtime);

  final _EmulatedNodeRuntime runtime;
  late final EngineTransport transport = EngineTransport(
    link: runtime,
    log: (String message) => logs.add(message),
  );

  final List<String> logs = <String>[];
  final List<void> startedEvents = <void>[];
  final List<Uint8List> outputEvents = <Uint8List>[];
  final List<EngineProcessError> errorEvents = <EngineProcessError>[];
  final List<void> finishedEvents = <void>[];

  void bindStreams() {
    transport.started.listen((void _) => startedEvents.add(null));
    transport.output.listen(outputEvents.add);
    transport.errorOccurred.listen(errorEvents.add);
    transport.finished.listen((void _) => finishedEvents.add(null));
  }
}

String _b64(String text) => base64Encode(utf8.encode(text));

/// 本地假宿主：只记录 startRuntime 的入参，绝不启动 Node（plan:527）。
///
/// 同时验证 NR-3 的 argv 生命周期要求：spec.argv 被保留在这里，等价 Qt:110-113
/// 把 argv 缓冲挂在堆上的 NodeThreadStart 里（必须活过 node::Start 全程）。
final class _RecordingHost implements NodeRuntimeHost {
  final List<NodeRuntimeStartSpec> starts = <NodeRuntimeStartSpec>[];
  int prepareCount = 0;
  int disposeCount = 0;

  @override
  Future<NodeRuntimeHostStatus> prepare() async {
    prepareCount += 1;
    return const NodeRuntimeHostStatus(prepared: true);
  }

  @override
  void startRuntime(NodeRuntimeStartSpec spec) {
    starts.add(spec);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }
}

// 用户 m10088：以下 LifecyclePorts 假端口依赖已撤回的 lib/app/lifecycle.dart，整块停用。
// 保留原文，不删；NodeRuntime 相关断言不受影响。
// /// T21-S08 的 foreground 端口：只记录 AppLifecycle 的 host 调用，不碰 Node。
// ///
// /// MainActivity.kt:68-74 目前只重放沉浸式窗口，尚未把 Activity.onResume/onPause
// /// 接到 AppLifecycle；这里直接驱动已落地的 real lifecycle port
// /// (lib/app/lifecycle.dart:402 hostActivityChanged)，不新建 EngineTransport。
// final class _LifecyclePortsFake implements LifecyclePorts {
//   int attachCount = 0;
//   int saveCount = 0;
//   final List<bool> visibility = <bool>[];
//
//   @override
//   bool get offline => false;
//
//   @override
//   bool get playbackConnection => false;
//
//   @override
//   String preference(String key) => '';
//
//   @override
//   void setPreference(String key, String value) {}
//
//   @override
//   EngineAttachment attachEngine() {
//     attachCount += 1;
//     return const EngineAttachment(
//       nodeRuntimeId: 'node-process-singleton',
//       loginSessionId: 'login-session',
//       playerId: 'player',
//     );
//   }
//
//   @override
//   void applyPresentationPreferences() {}
//
//   @override
//   StoredSession? loadSession() => null;
//
//   @override
//   bool restoreSession(StoredSession session, {required bool restorePlayer}) =>
//       true;
//
//   @override
//   void restoreAccount() {}
//
//   @override
//   void restoreIdentityName() {}
//
//   @override
//   void setVolume(double volume) {}
//
//   @override
//   void setSceneModeArchive() {}
//
//   @override
//   void replayStartupAnimation() {}
//
//   @override
//   void saveSession() {
//     saveCount += 1;
//   }
//
//   @override
//   void applyWindowShape() {}
//
//   @override
//   void showFullScreen() {}
//
//   @override
//   void setEngineVisible(bool visible) {
//     visibility.add(visible);
//   }
//
//   @override
//   void trimMemory() {}
// }

/// 轮询等待条件成立：真实回环 socket 是内核异步投递的，pumpEventQueue 不保证已到达。
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时（${timeout.inSeconds}s）：${reason ?? '条件未成立'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 把累计出站字节按 0x0a 切成 JSON 帧（只用于断言「宿主发往运行时」的方向）。
List<Map<String, Object?>> _decodeFrames(List<int> buffer) {
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  int start = 0;
  for (int index = 0; index < buffer.length; index += 1) {
    if (buffer[index] != NodeWire.delimiter) {
      continue;
    }
    final String raw = utf8.decode(buffer.sublist(start, index));
    start = index + 1;
    if (raw.isEmpty) {
      continue;
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map) {
      final Map<String, Object?> frame = <String, Object?>{};
      decoded.forEach((Object? key, Object? value) => frame[key.toString()] = value);
      frames.add(frame);
    }
  }
  return frames;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String root = '/data/user/0/rhine.music.database/files';
  const String temporary = '/data/user/0/rhine.music.database/cache';
  const String edition = 'kugou-lite';
  const String processToken = '0f8fad5b-d9cb-469f-a165-70867728950e';

  group('T21-C14 桥接生命周期（Qt BridgeProcessAndroid.cpp 1:1）', () {
    late _EmulatedNodeRuntime runtime;
    late _Harness harness;

    setUp(() {
      runtime = _EmulatedNodeRuntime(token: processToken);
      harness = _Harness(runtime)..bindStreams();
    });

    tearDown(() async {
      harness.transport.kill();
      await runtime.dispose();
    });

    test('wire 常量与 Qt 同值：0x0a / 48MiB / 8MiB 栈', () {
      // BridgeProcessAndroid.cpp:130-133 定界符；:118 pthread 栈（8 MiB）。
      expect(NodeWire.delimiter, 0x0a);
      expect(NodeWire.maxFrameBytes, 48 * 1024 * 1024);
      expect(NodeWire.runtimeStackBytes, 8 * 1024 * 1024);
      expect(EngineWire.delimiter, 0x0a);
      expect(EngineWire.start, 'start');
      expect(EngineWire.input, 'input');
      expect(EngineWire.stop, 'stop');
      expect(EngineWire.started, 'started');
      expect(EngineWire.output, 'output');
      expect(EngineWire.stderr, 'stderr');
      expect(EngineWire.error, 'error');
      expect(EngineWire.finished, 'finished');
      // Android 只把它们当线路词汇表：BridgeProcessAndroid.cpp 无 system-trust 分支
      // （对照 BridgeProcessIOS.cpp:70-78 的 iOS 专属通道）。
      expect(EngineWire.systemTrust, 'system-trust');
      expect(EngineWire.systemTrustResult, 'system-trust-result');
      expect(EngineWire.runtimeError, 'runtime-error');
    });

    test('握手前 start/input 排队，认证后按序一次性 flush', () async {
      // 先发帧，再让对端认证：模拟 Qt :134-137 queued 与 :90 flush。
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      harness.transport.write(Uint8List.fromList(<int>[1, 2, 3]));

      expect(runtime.sent, isEmpty, reason: '认证前不得直接写出');
      expect(runtime.queued.length, 2);

      final List<Map<String, Object?>> flushed =
          runtime.authenticate(processToken);

      expect(flushed.length, 2);
      expect(runtime.queued, isEmpty);
      // 顺序必须与排队一致：start 在 input 之前（BridgeProcessAndroid.cpp:90）。
      expect(runtime.sent.first[EngineWire.type], EngineWire.start);
      expect(runtime.sent[1][EngineWire.type], EngineWire.input);
      // 线路格式：compact JSON + 0x0a（:130-133）。
      for (final Uint8List bytes in runtime.wireBytes) {
        expect(bytes.last, 0x0a);
      }
      // node::Start 幂等：只启动一次。
      expect(runtime.runtimeStartCount, 1);
    });

    test('start 帧键集对齐 Qt:207-211：五键 + env 四键（路径值见 D1）', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);

      final Map<String, Object?> frame = runtime.sent.single;
      expect(frame[EngineWire.type], 'start');
      expect(frame[EngineWire.session], harness.transport.session);
      expect(frame['script'], root + '/MusicBridge/worker.cjs');
      expect(frame['stderrLog'], true);

      // 键名/键数逐字对齐 Qt；TMPDIR 与两个 device-state 是 D1 近似值：Qt:194-200 的 TMPDIR
      // 是 CacheLocation，Qt:204-205 的 device-state 取 AppStorage::dataDirectory()，且 Qt:182
      // 明确忽略 temporary 实参。断言这里只锁定本实现的 D1 语义，不冒充 Qt 路径。
      final Map<String, Object?> env = frame['env']! as Map<String, Object?>;
      expect(env['TMPDIR'], temporary);
      expect(env['RHINE_QQ_DEVICE_STATE_PATH'],
          root + '/qq-device.json');
      expect(env['RHINE_KUGOU_DEVICE_STATE_PATH'],
          root + '/kugou-device.json');
      expect(env['RHINE_KUGOU_EDITION'], edition);
      expect(env.length, 4, reason: 'env 恰好四键，不得夹带');
    });

    test('完整生命周期：started → output → kill → finished', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String session = harness.transport.session!;

      expect(harness.transport.state, EngineProcessState.starting);

      // ios-runtime.cjs: 'online' → {type:'started', session}（:69）。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: session,
      });
      await pumpEventQueue();
      expect(harness.transport.state, EngineProcessState.running);
      expect(harness.startedEvents.length, 1);

      // ios-runtime.cjs: stdout 'data' → {type:'output', session, data: base64}。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.output,
        EngineWire.session: session,
        EngineWire.data: _b64('hello'),
      });
      await pumpEventQueue();

      final Uint8List drained = harness.transport.readAllStandardOutput();
      expect(utf8.decode(drained), 'hello');
      // std::exchange(m_output,{}) 语义：取走即清空（:223-225）。
      expect(harness.transport.readAllStandardOutput(), isEmpty);
      expect(harness.outputEvents.length, 1);

      // kill() 发 stop 帧（:226-235）。
      harness.transport.kill();
      expect(harness.transport.state, EngineProcessState.notRunning);
      expect(harness.transport.session, isNull);
      final Map<String, Object?> stop = runtime.sent.last;
      expect(stop[EngineWire.type], EngineWire.stop);
      expect(stop[EngineWire.session], session);
      expect(harness.finishedEvents.length, 1);

      // kill 幂等：NotRunning 时直接返回，不再发帧。
      final int before = runtime.sent.length;
      harness.transport.kill();
      expect(runtime.sent.length, before);
    });

    test('旋转/重建 UI 不重启 runtime：新 session，process 仍只启动一次', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String firstSession = harness.transport.session!;
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: firstSession,
      });
      await pumpEventQueue();

      // 旋转等价于 UI 重建：新建 transport，复用同一进程级 runtime 连接。
      final _Harness rotated = _Harness(runtime)..bindStreams();
      rotated.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      await pumpEventQueue();

      expect(rotated.transport.session, isNotNull);
      expect(rotated.transport.session, isNot(firstSession),
          reason: '会话必须每次 start 新建（QUuid WithoutBraces）');
      expect(runtime.runtimeStartCount, 1, reason: '禁止重复 node::Start');
    });

    test('runtime-error 先于会话过滤：宿主崩溃必须回传', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String session = harness.transport.session!;
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: session,
      });
      await pumpEventQueue();

      // BridgeProcessAndroid.cpp:254-260：runtime-error 不参与会话过滤。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.runtimeError,
        EngineWire.session: 'stale-session-id',
      });
      await pumpEventQueue();

      expect(harness.transport.error, EngineProcessError.failedToStart);
      expect(harness.transport.state, EngineProcessState.notRunning);
      expect(harness.errorEvents.single, EngineProcessError.failedToStart);
    });

    test('过期会话帧在 base64 解码之前被丢弃', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String session = harness.transport.session!;
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: session,
      });
      await pumpEventQueue();

      // 非空但非法的 base64：若在过滤前解码就会抛异常（BridgeProcessAndroid.cpp:261）。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.output,
        EngineWire.session: 'someone-elses-session',
        EngineWire.data: '!!!not-base64!!!',
      });
      await pumpEventQueue();

      expect(harness.transport.readAllStandardOutput(), isEmpty);
      expect(harness.outputEvents, isEmpty);
      expect(harness.transport.state, EngineProcessState.running);
    });

    test('stderr 也在会话过滤之前被消费，且不污染 output', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String session = harness.transport.session!;

      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: session,
      });
      // BridgeProcessAndroid.cpp:248-253：stderr 先于 session 判断。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.stderr,
        EngineWire.session: 'stale',
        EngineWire.data: _b64('boom'),
      });
      await pumpEventQueue();

      expect(harness.logs, isNotEmpty);
      expect(harness.transport.readAllStandardOutput(), isEmpty);
    });

    test('system-trust 在 Android 上必须被会话过滤后静默丢弃（iOS 分支不适用）', () async {
      // BridgeProcessAndroid.cpp:92-93 read() 没有 system-trust 分支，帧进 accept()；
      // accept() :246-281 也无该分支 → :261 会话过滤后无匹配分支，静默丢弃。
      // BridgeProcessIOS.cpp:70-78 的 iOS 分支（evaluateIOSServerTrust / system-trust-result
      // 回包）在 Android 上不存在，禁止移植。
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String session = harness.transport.session!;
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: session,
      });
      await pumpEventQueue();
      final int framesBefore = runtime.sent.length;

      // 会话匹配也不得产生任何回包、输出或状态变化。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.systemTrust,
        EngineWire.session: session,
        'id': 'ios-only',
      });
      // 会话不匹配同样丢弃。
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.systemTrust,
        EngineWire.session: 'stale',
        'id': 'ios-only',
      });
      await pumpEventQueue();

      expect(runtime.sent.length, framesBefore, reason: '不得回 system-trust-result');
      expect(harness.transport.state, EngineProcessState.running);
      expect(harness.transport.error, EngineProcessError.unknownError);
      expect(harness.transport.readAllStandardOutput(), isEmpty);
    });

    test('error/finished 映射 crashed 并停止会话', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final String session = harness.transport.session!;
      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: session,
      });
      await pumpEventQueue();

      runtime.emit(<String, Object?>{
        EngineWire.type: EngineWire.finished,
        EngineWire.session: session,
        EngineWire.exitCode: 17,
      });
      await pumpEventQueue();

      expect(harness.transport.state, EngineProcessState.notRunning);
      expect(harness.finishedEvents.length, 1);
    });

    test('closeWriteChannel 空操作、waitForFinished 非阻塞', () async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      final int before = runtime.sent.length;

      // BridgeProcessAndroid.cpp:239-241：绝不关闭共享传输连接。
      harness.transport.closeWriteChannel();
      expect(runtime.sent.length, before);
      expect(runtime.isLive, isTrue);

      // :242-245：不阻塞，仅返回当前状态。
      expect(harness.transport.waitForFinished(1), isFalse);
      harness.transport.terminate();
      expect(harness.transport.waitForFinished(1), isTrue);
    });

    testWidgets('30 s 超时：started 未到达时只发一次 stop 且 finished 一次', (WidgetTester tester) async {
      harness.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
      );
      runtime.authenticate(processToken);
      expect(harness.transport.state, EngineProcessState.starting);
      expect(
        runtime.sent.where((Map<String, Object?> f) => f['type'] == EngineWire.stop),
        isEmpty,
      );

      // BridgeProcessAndroid.cpp:213-217：30000 ms 单次定时器。
      await tester.pump(const Duration(seconds: 29));
      expect(harness.transport.state, EngineProcessState.starting);
      expect(
        runtime.sent.where((Map<String, Object?> f) => f['type'] == EngineWire.stop),
        isEmpty,
      );

      await tester.pump(const Duration(seconds: 1));
      expect(harness.transport.state, EngineProcessState.notRunning);
      expect(harness.transport.session, isNull);
      expect(
        runtime.sent.where((Map<String, Object?> f) => f['type'] == EngineWire.stop),
        hasLength(1),
        reason: '超时只 kill 一次',
      );
      expect(harness.finishedEvents, hasLength(1));
    });
  });

  // ————————————————————————————————————————————————————————————————
  // B. 跨模块真实回环：真 NodeRuntime（隔离实例）+ 真回环 socket + 真 EngineTransport。
  // 覆盖 Qt:103 的单次 bind、:81-91 的握手与握手前排队 flush、:63-67 的断链回传、
  // :99-100 / plan:528 的旋转幂等。宿主是本地假宿主，绝不启动 Node（plan:527）。
  // ————————————————————————————————————————————————————————————————
  group('跨模块真实回环：NodeRuntime ↔ 回环 socket ↔ EngineTransport', () {
    late Directory tempRoot;
    late NodeRuntime runtime;
    late _RecordingHost host;
    late EngineTransport transport;
    late List<EngineProcessError> errors;
    late List<void> finishedEvents;
    late List<Uint8List> outputs;
    Socket? peer;
    final List<int> received = <int>[];

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('t21_bridge_lifecycle_');
      Directory('${tempRoot.path}/MusicBridge').createSync(recursive: true);
      File('${tempRoot.path}/MusicBridge/ios-runtime.cjs').writeAsStringSync(
        '// 假脚本：本测试绝不启动 Node（plan:527）。\n',
      );
      received.clear();
      runtime = NodeRuntime.createIsolatedForTest();
      host = _RecordingHost();
      transport = EngineTransport(link: NodeRuntimeEngineLink(runtime: runtime));
      errors = <EngineProcessError>[];
      finishedEvents = <void>[];
      outputs = <Uint8List>[];
      transport.errorOccurred.listen(errors.add);
      transport.finished.listen((void _) => finishedEvents.add(null));
      transport.output.listen(outputs.add);
    });

    tearDown(() async {
      transport.kill();
      peer?.destroy();
      peer = null;
      await runtime.shutdown();
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    Future<Socket> openControlConnection() async {
      final Socket socket =
          await Socket.connect(InternetAddress.loopbackIPv4, runtime.port);
      socket.listen(received.addAll);
      return socket;
    }

    test('回环握手：认证前 start 排队，首帧 {token} 通过后一次性 flush（Qt:81-91）',
        () async {
      expect(await runtime.launch(tempRoot.path, host), isTrue);
      expect(host.starts, hasLength(1), reason: 'Qt:106-120 只启动一次 Node');
      expect(
        host.starts.single.argv,
        <String>[
          'node',
          '${tempRoot.path}/MusicBridge/ios-runtime.cjs',
          runtime.port.toString(),
          runtime.token,
        ],
        reason: 'Qt:110-113：node + 脚本 + 端口 + 令牌，恰好 4 项（node::Start(4, values)）',
      );
      expect(host.starts.single.stackBytes, NodeWire.runtimeStackBytes,
          reason: 'Qt:118 pthread_attr_setstacksize(8 MiB)');
      expect(runtime.port, greaterThan(0), reason: 'Qt:103 端口 0 由系统分配');

      // 认证之前 send 只能入队（Qt:134-137）。
      transport.start(
        root: tempRoot.path,
        temporary: '${tempRoot.path}/tmp',
        edition: edition,
      );
      expect(runtime.authenticated, isFalse);
      expect(runtime.pendingBytes, 0);

      peer = await openControlConnection();
      peer!.add(utf8.encode(
        jsonEncode(<String, Object?>{NodeWire.token: runtime.token}) + '\n',
      ));
      await _waitFor(() => runtime.authenticated, reason: '首帧 {token} 握手未完成');
      await _waitFor(
        () => _decodeFrames(received).isNotEmpty,
        reason: 'Qt:90-91 握手后必须把排队字节一次性写出',
      );

      final List<Map<String, Object?>> flushed = _decodeFrames(received);
      expect(flushed, hasLength(1), reason: 'Qt:90 一次 write(queued) 后 clear');
      expect(flushed.single[EngineWire.type], EngineWire.start);
      expect(flushed.single[EngineWire.session], transport.session);
      expect(flushed.single[EngineWire.script],
          '${tempRoot.path}/MusicBridge/worker.cjs');
      expect(flushed.single[EngineWire.stderrLog], isTrue);
      final Map<String, Object?> env =
          (flushed.single[EngineWire.env] as Map).cast<String, Object?>();
      expect(env.keys.toSet(), <String>{
        'TMPDIR',
        'RHINE_QQ_DEVICE_STATE_PATH',
        'RHINE_KUGOU_DEVICE_STATE_PATH',
        'RHINE_KUGOU_EDITION',
      });
      expect(env['TMPDIR'], '${tempRoot.path}/tmp');
      expect(env['RHINE_KUGOU_EDITION'], edition);
      expect(env['RHINE_QQ_DEVICE_STATE_PATH'],
          '${tempRoot.path}/qq-device.json');

      // started → running；output 的 base64 要能穿过两模块还原成字节。
      peer!.add(utf8.encode(jsonEncode(<String, Object?>{
        EngineWire.type: EngineWire.started,
        EngineWire.session: transport.session,
      }) +
          '\n'));
      await _waitFor(
        () => transport.state == EngineProcessState.running,
        reason: 'started 未把会话推进到 running（Qt:264-266）',
      );

      peer!.add(utf8.encode(jsonEncode(<String, Object?>{
        EngineWire.type: EngineWire.output,
        EngineWire.session: transport.session,
        EngineWire.data: base64Encode(utf8.encode('hello')),
      }) +
          '\n'));
      await _waitFor(() => outputs.isNotEmpty, reason: 'output 未到达（Qt:267-269）');
      expect(utf8.decode(transport.readAllStandardOutput()), 'hello');

      // kill 只发 {type, session}（Qt:230），不得带 data。
      transport.kill();
      expect(transport.state, EngineProcessState.notRunning);
      await _waitFor(
        () => _decodeFrames(received).length >= 2,
        reason: 'Qt:230 的 stop 帧没有写出',
      );
      final Map<String, Object?> stop = _decodeFrames(received).last;
      expect(stop[EngineWire.type], EngineWire.stop);
      expect(stop[EngineWire.session], isNotNull);
      expect(stop.containsKey(EngineWire.data), isFalse);
      expect(errors, isEmpty);
    });

    test('崩溃回传：控制连接断开 → runtime-error → transport failedToStart（Qt:63-67）',
        () async {
      expect(await runtime.launch(tempRoot.path, host), isTrue);
      transport.start(
        root: tempRoot.path,
        temporary: '${tempRoot.path}/tmp',
        edition: edition,
      );
      peer = await openControlConnection();
      peer!.add(utf8.encode(
        jsonEncode(<String, Object?>{NodeWire.token: runtime.token}) + '\n',
      ));
      await _waitFor(() => runtime.authenticated);
      expect(runtime.isLive, isTrue);

      // Node 进程死掉 ⇔ 控制连接断开（Qt:63-67 的 disconnected → runtime-error）。
      peer!.destroy();

      await _waitFor(() => errors.isNotEmpty, reason: 'runtime-error 没有回传');
      expect(errors.single, EngineProcessError.failedToStart);
      expect(transport.state, EngineProcessState.notRunning);
      expect(finishedEvents, isNotEmpty, reason: 'Qt:258 emit finished');
      expect(runtime.isLive, isFalse);
      // 断链 ≠ node::Start 返回：exited 只在宿主报告 runtime_exited 时置位（Qt:153）。
      expect(runtime.exited, isFalse);
    });

    test('旋转/重建：新 EngineTransport 复用同一运行时，不二次 bind、不二次 startRuntime',
        () async {
      expect(await runtime.launch(tempRoot.path, host), isTrue);
      final int port = runtime.port;
      transport.start(
        root: tempRoot.path,
        temporary: '${tempRoot.path}/tmp',
        edition: edition,
      );
      peer = await openControlConnection();
      peer!.add(utf8.encode(
        jsonEncode(<String, Object?>{NodeWire.token: runtime.token}) + '\n',
      ));
      await _waitFor(() => runtime.authenticated);
      await _waitFor(() => _decodeFrames(received).isNotEmpty);
      final String firstSession = transport.session!;

      final EngineTransport rotated =
          EngineTransport(link: NodeRuntimeEngineLink(runtime: runtime));
      addTearDown(rotated.kill);
      rotated.start(
        root: tempRoot.path,
        temporary: '${tempRoot.path}/tmp',
        edition: edition,
      );
      await _waitFor(
        () => _decodeFrames(received).length >= 2,
        reason: '旋转后的 start 帧没有走同一条已认证连接',
      );

      final List<Map<String, Object?>> frames = _decodeFrames(received);
      expect(frames[0][EngineWire.session], firstSession);
      expect(frames[1][EngineWire.session], rotated.session);
      expect(frames[1][EngineWire.session], isNot(firstSession),
          reason: '每会话一个新 id（Qt:184），不是每进程');

      expect(await runtime.launch(tempRoot.path, host), isTrue,
          reason: 'Qt:99-100：已 launched 且连接仍活 → true');
      expect(host.starts, hasLength(1),
          reason: 'plan:530 Fail 条件：禁止重复 node::Start');
      expect(host.prepareCount, 1, reason: '不重新 prepare');
      expect(runtime.port, port, reason: 'Qt:103 回环端口只绑定一次');
      expect(runtime.authenticated, isTrue);
      expect(errors, isEmpty);
    });

    // 用户 m10088：该用例驱动已撤回的 AppLifecycle/HostActivity，整块停用（保留原文）。
    // 前后台/旋转不重启 Node 的宿主断言仍由上面的 transport 用例覆盖。
//     test('前后台/旋转：real LifecyclePort 的 inactive→active 不重启 Node', () async {
//       expect(await runtime.launch(tempRoot.path, host), isTrue);
//       final _LifecyclePortsFake ports = _LifecyclePortsFake();
//       final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
//       expect(ports.attachCount, 1, reason: '进程级 EngineAttachment 只构建一次');
//
//       lifecycle.hostActivityChanged(HostActivity.active);
//       lifecycle.hostActivityChanged(HostActivity.inactive);
//       lifecycle.hostActivityChanged(HostActivity.active);
//       lifecycle.rotation();
//       lifecycle.activityReattached();
//
//       expect(lifecycle.snapshot.foregroundCount, 2);
//       expect(lifecycle.snapshot.backgroundCount, 1);
//       expect(ports.saveCount, 1, reason: 'inactive 保存一次会话');
//       expect(ports.visibility, <bool>[true, false, true],
//           reason: 'Qt AndroidWindow.cpp:100：非 active 隐藏引擎，active 恢复');
//       expect(ports.attachCount, 1);
//       expect(host.starts, hasLength(1),
//           reason: '前后台/旋转不得第二次 node::Start');
//       expect(host.prepareCount, 1);
//
//       expect(await runtime.launch(tempRoot.path, host), isTrue);
//       expect(host.starts, hasLength(1),
//           reason: 'Qt:99-100：已 launched 且连接仍活 → true，不重复启动');
//     });

  });
}
