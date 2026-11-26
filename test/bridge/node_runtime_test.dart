// lib/bridge/node_runtime.dart 的宿主侧确定性单测。
//
// 全部在宿主侧复现，不启动真实 Node、不需要设备：只用回环 TCP 与系统临时目录。
// 附加面：createIsolatedForTest（单例无法复位）与 isLive（EngineRuntimeLink 的唯一判据）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/bridge/node_runtime.dart';

/// 假宿主：只记录 prepare/startRuntime/dispose 的调用次数与参数。
final class _FakeNodeRuntimeHost implements NodeRuntimeHost {
  _FakeNodeRuntimeHost({this.prepared = true, this.reason});

  final bool prepared;
  final String? reason;

  final List<NodeRuntimeStartSpec> starts = <NodeRuntimeStartSpec>[];
  int prepareCount = 0;
  int disposeCount = 0;

  /// 宿主必须保住 argv（Qt:110-113 把 argv 缓冲挂在 NodeThreadStart 上），这里用副本
  /// 模拟「宿主持有它」，也顺便证明 argv 在 launch 返回之后仍然完整可读。
  final List<List<String>> retainedArgv = <List<String>>[];

  @override
  Future<NodeRuntimeHostStatus> prepare() async {
    prepareCount += 1;
    return NodeRuntimeHostStatus(prepared: prepared, root: null, reason: reason);
  }

  @override
  void startRuntime(NodeRuntimeStartSpec spec) {
    starts.add(spec);
    retainedArgv.add(List<String>.unmodifiable(spec.argv));
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }
}

/// 启动即抛错的宿主：复现 Qt:120-125 一类「launched 已在 Qt:106 置位之后宿主侧才失败」
/// 的路径——此时监听仍开着（node_runtime.dart 文件头差异 11），失败会话与随后的控制连接
/// 会话必须是两个独立的去重作用域（DEDUP-24）。
final class _ThrowingStartHost implements NodeRuntimeHost {
  int prepareCount = 0;

  @override
  Future<NodeRuntimeHostStatus> prepare() async {
    prepareCount += 1;
    return const NodeRuntimeHostStatus(prepared: true, root: null, reason: null);
  }

  @override
  void startRuntime(NodeRuntimeStartSpec spec) {
    throw StateError('host refused to start the runtime');
  }

  @override
  Future<void> dispose() async {}
}

/// prepare 可被外部闸门卡住的宿主：让 shutdown 与一次在途的 launch 稳定地竞争
/// （reviewer finding #1：迟到失败不得在关机之后伪造 runtime-error）。
final class _BlockingPrepareHost implements NodeRuntimeHost {
  final Completer<void> gate = Completer<void>();
  int disposeCount = 0;

  @override
  Future<NodeRuntimeHostStatus> prepare() async {
    await gate.future;
    return const NodeRuntimeHostStatus(prepared: false, root: null, reason: 'not_ready');
  }

  @override
  void startRuntime(NodeRuntimeStartSpec spec) {
    fail('关机后绝不启动 Node');
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }
}

/// 回环测试客户端：原文累积 + 按 0x0a 切帧。
final class _LoopbackClient {
  _LoopbackClient._(this.socket) {
    _subscription = socket.listen(
      (Uint8List chunk) {
        received.addAll(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        closed = true;
      },
      onDone: () {
        closed = true;
      },
      cancelOnError: false,
    );
  }

  static Future<_LoopbackClient> connect(int port) async =>
      _LoopbackClient._(await Socket.connect(InternetAddress.loopbackIPv4, port));

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> received = <int>[];
  bool closed = false;

  static final String _newline = String.fromCharCode(NodeWire.delimiter);

  void sendToken(String token) {
    socket.add(utf8.encode(jsonEncode(<String, Object?>{NodeWire.token: token}) + _newline));
  }

  void sendFrame(Map<String, Object?> message) {
    socket.add(utf8.encode(jsonEncode(message) + _newline));
  }

  void sendRaw(List<int> bytes) {
    socket.add(bytes);
  }

  List<Map<String, Object?>> frames() {
    final List<Map<String, Object?>> result = <Map<String, Object?>>[];
    int start = 0;
    for (int index = 0; index < received.length; index += 1) {
      if (received[index] != NodeWire.delimiter) {
        continue;
      }
      final String raw = utf8.decode(received.sublist(start, index));
      start = index + 1;
      if (raw.isEmpty) {
        continue;
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        final Map<String, Object?> message = <String, Object?>{};
        decoded.forEach((Object? key, Object? value) {
          message[key.toString()] = value;
        });
        result.add(message);
      }
    }
    return result;
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    socket.destroy();
  }
}

late Directory _root;

String get _rootPath => _root.path;

/// 轮询等待（不用固定 sleep 做正断言；负断言才用显式延迟）。
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = '条件未在超时内成立',
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时：$reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('t21c14_node_runtime_');
    Directory('$_rootPath/MusicBridge').createSync();
    File('$_rootPath/MusicBridge/ios-runtime.cjs').writeAsStringSync('// fake script: this test never starts Node');
  });

  tearDown(() {
    if (_root.existsSync()) {
      _root.deleteSync(recursive: true);
    }
  });

  group('T21-C14 node_runtime.dart（Qt BridgeProcessAndroid.cpp 1:1）', () {
    test('NodeWire 常量：0x0a 分帧 / 48 MiB 读缓冲上限 / 8 MiB 栈', () {
      expect(NodeWire.delimiter, 0x0a);
      expect(NodeWire.maxFrameBytes, 48 * 1024 * 1024);
      expect(NodeWire.runtimeStackBytes, 8 * 1024 * 1024);
      // 字段名与 Qt/js 端必须一致（改一处就静默断链）。
      expect(NodeWire.token, 'token');
      expect(NodeWire.type, 'type');
      expect(NodeWire.session, 'session');
      expect(NodeWire.data, 'data');
      expect(NodeWire.script, 'script');
      expect(NodeWire.env, 'env');
      expect(NodeWire.stderrLog, 'stderrLog');
      expect(NodeWire.detail, 'detail');
      expect(NodeWire.exitCode, 'exitCode');
      expect(NodeWire.start, 'start');
      expect(NodeWire.input, 'input');
      expect(NodeWire.stop, 'stop');
      expect(NodeWire.systemTrustResult, 'system-trust-result');
      expect(NodeWire.started, 'started');
      expect(NodeWire.output, 'output');
      expect(NodeWire.stderr, 'stderr');
      expect(NodeWire.error, 'error');
      expect(NodeWire.finished, 'finished');
      expect(NodeWire.systemTrust, 'system-trust');
      expect(NodeWire.runtimeError, 'runtime-error');
    });

    test('token：构造时生成一次、小写 UUIDv4 无花括号、不含逗号/空格/引号', () {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final String first = runtime.token;
      expect(
        first,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
      expect(first.contains('{'), isFalse);
      expect(first.contains('}'), isFalse);
      expect(first.contains(','), isFalse);
      expect(first.contains(' '), isFalse);
      expect(first.contains('"'), isFalse);
      // 同一实例反复读取是同一个令牌（Qt:47 成员初值，不是每会话）。
      expect(runtime.token, first);
      // 不同实例不同令牌（Random.secure，128 位）。
      final NodeRuntime other = NodeRuntime.createIsolatedForTest();
      expect(other.token, isNot(first));
      // 进程级单例稳定。
      expect(NodeRuntime.instance, same(NodeRuntime.instance));
      expect(NodeRuntime.instance.token, NodeRuntime.instance.token);
    });

    test('launch 幂等：startRuntime 只被调用一次，argv/栈按 Qt:107-118', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      expect(runtime.port, 0);
      expect(runtime.launched, isFalse);

      expect(await runtime.launch(_rootPath, host), isTrue);
      expect(runtime.launched, isTrue);
      expect(runtime.port, greaterThan(0));
      expect(host.prepareCount, 1);
      expect(host.starts, hasLength(1));
      expect(host.starts.single.stackBytes, NodeWire.runtimeStackBytes);
      expect(
        host.starts.single.argv,
        <String>[
          'node',
          '$_rootPath/MusicBridge/ios-runtime.cjs',
          runtime.port.toString(),
          runtime.token,
        ],
      );
      // 宿主持有 argv 的副本仍然完整（生命期要求，Qt:110-113）。
      expect(host.retainedArgv.single, host.starts.single.argv);

      // 第二次 launch：已 launched 且还没连接 → 视为「仍在连接中」，直接回报状态。
      expect(await runtime.launch(_rootPath, host), isTrue);
      // 第三次也一样（旋转/重建 UI 的等价动作）。
      expect(await runtime.launch(_rootPath, host), isTrue);
      expect(host.starts, hasLength(1), reason: '绝不第二次 node::Start（plan:530 Fail 条件）');
      expect(host.prepareCount, 1, reason: '幂等分支连宿主都不再询问');
      expect(runtime.isLive, isTrue);

      await runtime.shutdown();
    });

    test('只允许一个控制连接：第二个候选在认证前就被销毁，且不产生 runtime-error', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient first = await _LoopbackClient.connect(runtime.port);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final _LoopbackClient second = await _LoopbackClient.connect(runtime.port);
      await _waitFor(() => second.closed, reason: '第二个候选必须被 destroy（Qt:55-60）');
      expect(second.received, isEmpty);
      expect(first.closed, isFalse, reason: '已选中的控制连接不受影响');
      expect(failures, isEmpty, reason: '被丢弃的候选不算运行时崩溃（Qt 只对已选中的 socket 连 disconnected）');
      expect(runtime.authenticated, isFalse);

      // 第一个连接仍然可以完成握手。
      first.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);
      expect(runtime.authenticated, isTrue);
      expect(failures, isEmpty);

      // 认证后监听已关闭：新连接不能接管控制通道（Qt:88 server.close()）。
      _LoopbackClient? probe;
      Object? connectError;
      try {
        probe = await _LoopbackClient.connect(runtime.port);
      } on Object catch (error) {
        connectError = error;
      }
      final _LoopbackClient? ready = probe;
      if (ready != null) {
        await _waitFor(() => ready.closed, reason: '认证后不能再有控制连接');
        expect(ready.received, isEmpty);
        await ready.dispose();
      } else {
        expect(connectError, isA<SocketException>());
      }
      expect(runtime.authenticated, isTrue);

      await first.dispose();
      await second.dispose();
      await runtime.shutdown();
    });

    test('首帧 token 错误：连接被销毁并回传 runtime-error（Qt:81-86）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
      runtime.runtimeFailed.listen(failures.add);
      runtime.messages.listen(frames.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken('00000000-0000-4000-8000-000000000000');
      await _waitFor(() => client.closed, reason: '令牌不匹配必须 abort 连接');
      expect(runtime.authenticated, isFalse);
      expect(client.received, isEmpty, reason: '认证失败绝不写回任何字节');
      await _waitFor(() => failures.isNotEmpty);
      expect(failures, hasLength(1));
      await _waitFor(() => frames.isNotEmpty);
      expect(frames.last[NodeWire.type], NodeWire.runtimeError);
      expect(frames.last.containsKey(NodeWire.session), isFalse,
          reason: '宿主合成的 runtime-error 没有 session，先于会话过滤处理');
      // 越界前已消费过的帧不会留在读缓冲里（Qt:80-86：先 remove 再判令牌）。
      expect(runtime.pendingBytes, 0);

      await client.dispose();
      await runtime.shutdown();
    });

    test('坏首帧（非法 JSON / 缺 token）同样断开（Qt:79-84）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendRaw(utf8.encode('not-json${String.fromCharCode(NodeWire.delimiter)}'));
      await _waitFor(() => client.closed, reason: '非法首帧必须 abort');
      expect(runtime.authenticated, isFalse);

      await client.dispose();
      await runtime.shutdown();
    });

    test('缺少 MusicBridge/ios-runtime.cjs：launch false 且上报 runtime-error（Qt:102）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
      runtime.messages.listen(frames.add);
      File('$_rootPath/MusicBridge/ios-runtime.cjs').deleteSync();

      expect(await runtime.launch(_rootPath, host), isFalse);
      expect(runtime.launched, isFalse);
      expect(runtime.port, 0, reason: '监听都不该建立');
      expect(host.starts, isEmpty, reason: '绝不偷偷嵌入新 Node');
      await _waitFor(() => frames.isNotEmpty);
      expect(frames.last[NodeWire.type], NodeWire.runtimeError);
    });

    test('读缓冲上限：越界即销毁连接（Qt:73 整个 buffer 口径）', () async {
      // 全局常量是 48 MiB；用小上限在同一条代码路径上复现越界。
      expect(NodeWire.maxFrameBytes, 48 * 1024 * 1024);
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest(maxFrameBytes: 1024);
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendRaw(List<int>.filled(1024, 0x41));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.closed, isFalse, reason: '恰好等于上限不算越界');
      expect(runtime.pendingBytes, 1024);
      expect(failures, isEmpty);

      client.sendRaw(<int>[0x42]);
      await _waitFor(() => client.closed, reason: '超过上限必须 abort 连接');
      await _waitFor(() => failures.isNotEmpty);
      expect(failures, hasLength(1));
      expect(runtime.pendingBytes, greaterThan(1024), reason: '越界时 Qt 也不清缓冲，直接 abort');

      await client.dispose();
      await runtime.shutdown();
    });

    test('握手前排队：认证前不写出，认证后按入队顺序一次性 flush（Qt:130-137/:90-91）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      runtime.send(<String, Object?>{NodeWire.type: NodeWire.start, NodeWire.session: 's1'});
      runtime.send(<String, Object?>{
        NodeWire.type: NodeWire.input,
        NodeWire.session: 's1',
        NodeWire.data: 'AA==',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.received, isEmpty, reason: '认证前一个字节都不许写出');
      expect(runtime.authenticated, isFalse);

      client.sendToken(runtime.token);
      await _waitFor(() => client.frames().length >= 2);
      final List<Map<String, Object?>> frames = client.frames();
      expect(frames, hasLength(2));
      expect(frames[0][NodeWire.type], NodeWire.start);
      expect(frames[0][NodeWire.session], 's1');
      expect(frames[1][NodeWire.type], NodeWire.input);
      expect(frames[1][NodeWire.data], 'AA==');
      expect(client.received.last, NodeWire.delimiter, reason: '每帧以 0x0a 结尾');

      // compact JSON + 换行：Qt:130-131 的 QJsonDocument::Compact。
      final int firstDelimiter = client.received.indexOf(NodeWire.delimiter);
      final String raw = utf8.decode(client.received.sublist(0, firstDelimiter));
      expect(raw, '{"type":"start","session":"s1"}');
      expect(raw.contains(' '), isFalse);

      // 认证后 send 直接走套接字（不再排队）。
      runtime.send(<String, Object?>{NodeWire.type: NodeWire.stop, NodeWire.session: 's1'});
      await _waitFor(() => client.frames().length >= 3);
      expect(client.frames()[2][NodeWire.type], NodeWire.stop);

      await client.dispose();
      await runtime.shutdown();
    });

    test('宿主报告 runtime_exited：launch false + runtime-error，且本进程内不再启动', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host =
          _FakeNodeRuntimeHost(prepared: false, reason: 'runtime_exited');
      final List<void> failures = <void>[];
      final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
      runtime.runtimeFailed.listen(failures.add);
      runtime.messages.listen(frames.add);

      expect(await runtime.launch(_rootPath, host), isFalse);
      expect(runtime.launched, isFalse);
      expect(runtime.exited, isTrue, reason: '宿主确认 node::Start 已返回（Qt:153）');
      expect(host.starts, isEmpty);
      await _waitFor(() => frames.isNotEmpty);
      expect(frames.last[NodeWire.type], NodeWire.runtimeError);
      expect(failures, hasLength(1));

      // 旋转/重建再 launch：仍 false，且不再询问宿主。
      expect(await runtime.launch(_rootPath, host), isFalse);
      expect(host.prepareCount, 1);
      expect(host.starts, isEmpty);
      expect(runtime.launched, isFalse);
    });

    test('运行时崩溃回传：控制连接断开 → runtimeFailed 恰好一次（Qt:63-67）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);
      expect(runtime.isLive, isTrue);

      // 运行时进程死掉 = 套接字断开（NodeHost 没有退出事件流，这是可观测的等价路径）。
      await client.dispose();
      await _waitFor(() => failures.isNotEmpty, reason: '断开必须回传 runtime-error');
      expect(failures, hasLength(1));
      expect(runtime.isLive, isFalse);

      await runtime.shutdown();
    });

    test('旋转/重建 UI：已认证连接下 launch 仍幂等且连接继续可用（plan:528）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);

      expect(await runtime.launch(_rootPath, host), isTrue);
      expect(await runtime.launch(_rootPath, host), isTrue);
      expect(host.starts, hasLength(1), reason: '旋转绝不能第二次 node::Start');
      expect(runtime.authenticated, isTrue);
      expect(runtime.isLive, isTrue);
      expect(failures, isEmpty);

      // 连接仍然可用：新会话（旋转后 BridgeProcess 的每会话 id）照样能发出去。
      runtime.send(<String, Object?>{
        NodeWire.type: NodeWire.input,
        NodeWire.session: 's2',
        NodeWire.data: 'AA==',
      });
      await _waitFor(() => client.frames().isNotEmpty);
      expect(client.frames().single[NodeWire.session], 's2');

      await client.dispose();
      await runtime.shutdown();
    });

    test('shutdown：停监听/断连接/释放宿主一次，不伪造崩溃，之后不再启动', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);

      final int port = runtime.port;
      await runtime.shutdown();
      await _waitFor(() => client.closed, reason: 'shutdown 必须断掉控制连接');
      expect(host.disposeCount, 1);
      expect(failures, isEmpty, reason: '正常关闭不是崩溃，不得伪造 runtime-error');
      expect(runtime.isLive, isFalse);
      expect(runtime.launched, isTrue, reason: 'shutdown 不重置 launched（Qt 没有重启路径）');

      // 端口不再接受控制连接。
      Object? connectError;
      try {
        final _LoopbackClient probe = await _LoopbackClient.connect(port);
        await probe.dispose();
      } on Object catch (error) {
        connectError = error;
      }
      expect(connectError, isA<SocketException>());

      // 再 launch 直接 false，且不再询问/启动宿主。
      expect(await runtime.launch(_rootPath, host), isFalse);
      expect(host.prepareCount, 1);
      expect(host.starts, hasLength(1));
      // shutdown 幂等。
      await runtime.shutdown();
      expect(host.disposeCount, 1);

      await client.dispose();
    });

    test('读缓冲：一次读入两整帧 + 半帧，半帧留到下一次（QByteArray 语义）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
      runtime.messages.listen(frames.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);

      // 等价 Qt:77-95：一次 readAll() 里连续切帧，尾部没有换行的部分留在 input。
      final String partial = '{"type":"fin';
      client.sendRaw(utf8.encode(
        '{"type":"started","session":"s1"}\n'
        '{"type":"output","session":"s1","data":"AA=="}\n'
        '$partial',
      ));
      await _waitFor(() => frames.length >= 2);
      expect(frames[0][NodeWire.type], NodeWire.started);
      expect(frames[1][NodeWire.type], NodeWire.output);
      expect(runtime.pendingBytes, utf8.encode(partial).length,
          reason: '半帧必须原样留在读缓冲，等下一个 0x0a');

      client.sendRaw(utf8.encode('ished","session":"s1"}\n'));
      await _waitFor(() => frames.length >= 3);
      expect(frames[2][NodeWire.type], NodeWire.finished);
      expect(runtime.pendingBytes, 0);

      await client.dispose();
      await runtime.shutdown();
    });

    test('认证后断链：send 不抛（Qt socket->write 静默返回 -1）且 runtime-error 只发一次', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);

      await client.dispose();
      await _waitFor(() => failures.isNotEmpty);

      // Qt 在 disconnected 之后也不复位 authenticated（:87 只在握手时置 true）。
      expect(runtime.authenticated, isTrue);
      expect(runtime.isLive, isFalse);
      expect(
        () => runtime.send(<String, Object?>{
          NodeWire.type: NodeWire.input,
          NodeWire.session: 's1',
          NodeWire.data: 'AA==',
        }),
        returnsNormally,
        reason: 'Qt 的 socket->write() 在已断开的 socket 上静默返回 -1，绝不外抛',
      );
      expect(failures, hasLength(1), reason: '同一会话内至多一次（差异 9：abort + onDone 合并）');

      await runtime.shutdown();
    });

    // —— DEDUP-24：runtime-error 去重的作用域必须是「单次会话」而不是进程 ——
    test('DEDUP-24：启动失败 → 重新 launch 成功 → 断链仍回传 runtime-error（Qt:63-67）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
      runtime.runtimeFailed.listen(failures.add);
      runtime.messages.listen(frames.add);

      // 会话 1：脚本不在 → launch false + runtime-error（Qt:102-105，经 :186-189 合成）。
      File('$_rootPath/MusicBridge/ios-runtime.cjs').deleteSync();
      expect(await runtime.launch(_rootPath, host), isFalse);
      expect(runtime.launched, isFalse);
      await _waitFor(() => failures.isNotEmpty);
      await _waitFor(() => frames.isNotEmpty, reason: 'runtime-error 帧自身也必须出现在 messages');
      expect(failures, hasLength(1));
      expect(frames.single[NodeWire.type], NodeWire.runtimeError);

      // 会话 2：补齐脚本后重试成功——Qt 的 launched 直到 :106 才置位，失败不是终态。
      File('$_rootPath/MusicBridge/ios-runtime.cjs')
          .writeAsStringSync('// fake script: this test never starts Node');
      expect(await runtime.launch(_rootPath, host), isTrue);
      expect(runtime.launched, isTrue);
      expect(host.starts, hasLength(1), reason: '成功那次才真正交给宿主启动');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(failures, hasLength(1), reason: '成功启动本身不是失败，不得补发');

      // 会话 3：成功启动之后的断链必须再上报一次（Qt:63-67 无条件 accept，不看历史）。
      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);
      expect(runtime.isLive, isTrue);

      await client.dispose();
      await _waitFor(
        () => failures.length >= 2,
        reason: 'DEDUP-24：进程级 latch 会吞掉这里的第二次 runtimeFailed',
      );
      expect(failures, hasLength(2), reason: '每个失败会话恰好一次，跨会话绝不抑制');
      await _waitFor(
        () => frames.where((Map<String, Object?> m) => m[NodeWire.type] == NodeWire.runtimeError).length >= 2,
        reason: '两条 runtime-error 帧都要进 messages（UI 的崩溃提示源）',
      );
      expect(
        frames.where((Map<String, Object?> m) => m[NodeWire.type] == NodeWire.runtimeError),
        hasLength(2),
      );

      await runtime.shutdown();
    });

    test('DEDUP-24：两次独立的启动失败各自上报（每次 launch 尝试是一个会话）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      File('$_rootPath/MusicBridge/ios-runtime.cjs').deleteSync();

      expect(await runtime.launch(_rootPath, host), isFalse);
      await _waitFor(() => failures.isNotEmpty);
      expect(failures, hasLength(1));

      // Qt:186-189：每次失败的 start() 都会再合成一次 runtime-error，两次失败就是两条。
      expect(await runtime.launch(_rootPath, host), isFalse);
      await _waitFor(
        () => failures.length >= 2,
        reason: '第二次失败被上一次的 latch 吞掉了（DEDUP-24）',
      );
      expect(failures, hasLength(2));
      expect(host.prepareCount, 2, reason: '失败路径允许重试：launched 从未置位');
      expect(host.starts, isEmpty);
      expect(runtime.port, 0);

      await runtime.shutdown();
    });

    test('DEDUP-24：同一会话内的重复断链回调只上报一次（abort + onDone 合并）', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);
      expect(await runtime.launch(_rootPath, host), isTrue);

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      // 首帧令牌不匹配：_abortConnection 先显式走一遍失败路径，socket 的 onDone 随后还会
      // 回调同一个失败——两次通知属于同一会话，必须合并成一次。
      client.sendToken('00000000-0000-4000-8000-000000000000');
      await _waitFor(() => failures.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(failures, hasLength(1), reason: '同一失败不重复刷屏（差异 9 保留的部分）');
      expect(runtime.authenticated, isFalse);

      await client.dispose();
      await runtime.shutdown();
    });

    test('DEDUP-24：launch 置位后宿主启动抛错，随后控制连接的断链仍独立上报', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _ThrowingStartHost host = _ThrowingStartHost();
      final List<void> failures = <void>[];
      runtime.runtimeFailed.listen(failures.add);

      // 会话 1：_launched 已在 Qt:106 置位之后宿主才失败（Qt:120-125 一类路径）。
      expect(await runtime.launch(_rootPath, host), isFalse);
      expect(runtime.launched, isTrue, reason: 'Qt:106 之后不再回收监听（差异 11）');
      expect(host.prepareCount, 1);
      await _waitFor(() => failures.isNotEmpty);
      expect(failures, hasLength(1));

      // 会话 2：监听仍在，控制连接可以建立；它的断开是独立的失败会话，必须再上报。
      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => runtime.authenticated);
      await client.dispose();
      await _waitFor(
        () => failures.length >= 2,
        reason: '连接会话的断链被上一次失败吞掉了（DEDUP-24）',
      );
      expect(failures, hasLength(2));

      await runtime.shutdown();
    });

    test('DEDUP-24 finding#1：shutdown 与在途 prepare 竞争，迟到失败不伪造 runtime-error', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final _BlockingPrepareHost host = _BlockingPrepareHost();
      final List<void> failures = <void>[];
      final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
      runtime.runtimeFailed.listen(failures.add);
      runtime.messages.listen(frames.add);

      final Future<bool> attempt = runtime.launch(_rootPath, host);
      await runtime.shutdown();
      expect(runtime.launched, isFalse);

      // prepare 之后才返回「未就绪」：此时已经 shutdown，不得再发 runtime-error。
      host.gate.complete();
      expect(await attempt, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(failures, isEmpty, reason: '正常关闭后的迟到失败不是崩溃');
      expect(frames, isEmpty);
    });

    test('NodeRuntimeEngineLink：转发 send / messages / isLive 给进程级运行时', () async {
      final NodeRuntime runtime = NodeRuntime.createIsolatedForTest();
      final NodeRuntimeEngineLink link = NodeRuntimeEngineLink(runtime: runtime);
      final _FakeNodeRuntimeHost host = _FakeNodeRuntimeHost();
      expect(link.isLive, isFalse);

      final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
      link.messages.listen(seen.add);

      expect(await runtime.launch(_rootPath, host), isTrue);
      expect(link.isLive, isTrue);

      link.send(<String, Object?>{NodeWire.type: NodeWire.start, NodeWire.session: 's1'});
      expect(runtime.pendingBytes, 0, reason: '未认证时进 queued，不进读缓冲');

      final _LoopbackClient client = await _LoopbackClient.connect(runtime.port);
      client.sendToken(runtime.token);
      await _waitFor(() => client.frames().isNotEmpty);
      expect(client.frames().single[NodeWire.type], NodeWire.start);

      client.sendFrame(<String, Object?>{
        NodeWire.type: NodeWire.started,
        NodeWire.session: 's1',
      });
      await _waitFor(() => seen.isNotEmpty);
      expect(seen.single[NodeWire.type], NodeWire.started);

      await client.dispose();
      await runtime.shutdown();
    });
  });
}
