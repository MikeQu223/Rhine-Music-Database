// test/bridge/engine_transport_test.dart
// T21-C19-W1 单元测试（writer: T21-C19-W1 / atom T21-C19-A1）
//
// 计划卡：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:524-531（T21）
// 被测对象：lib/bridge/engine_transport.dart
// 唯一权威源：Qt/src/BridgeProcessAndroid.cpp:171-281 + Qt/src/BridgeProcess.h:13-46
// 冻结契约：reports/T21-C14-CONTRACT.json frozenApi.engine_transport
//
// 覆盖（逐条对应契约 rules 与卡面要求）：
//   会话过滤先于 base64 解码 / 非法 data（非 String、非法 base64）与非法 detail/exitCode 拒绝 /
//   30s 定时器仅在 starting 且同 session 时 kill / kill 幂等 / closeWriteChannel 空操作 /
//   waitForFinished 非阻塞 / system-trust（会话匹配与不匹配）都不得回包、输出、状态变化 /
//   error 与 finished → crashed / runtime-error → failedToStart / start 帧五键 + env 四键 / UUID 无花括号。
//
// RED/GREEN 未执行：本卡全程禁止 flutter test / dart test / analyze / 设备执行；
// 本文件从未运行过，只做源码编写 + 独立逻辑审查。
// 本文件不启动真实 Node runtime、不开 socket、不申请任何设备权限；
// EngineRuntimeLink 用纯 Dart 假实现（记录出站帧、可注入入站帧）。
//
// 30s 定时器的确定性：pubspec 没有 fake_async 依赖（且 pubspec 不在本模块写域），
// flutter_test 也不 re-export package:fake_async，因此用 testWidgets + tester.pump(Duration)
// （flutter_test 自带的假时钟）推进 BridgeProcessAndroid.cpp:213-217 的 30000ms 单次定时器。
// 注意：testWidgets 在用例体结束时会对悬挂 Timer 判失败，故每个 testWidgets 用例都在体内
// 让定时器要么自然触发、要么被 kill() 取消。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/bridge/engine_transport.dart';

/// 纯 Dart 假传输连接：记录出站帧，可注入入站帧；不发字节、不开 socket。
class _FakeEngineRuntimeLink implements EngineRuntimeLink {
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  // sync broadcast：让「emit 后立刻断言」与 Qt 的同步信号语义一致。
  final StreamController<Map<String, Object?>> _inbound =
      StreamController<Map<String, Object?>>.broadcast(sync: true);

  bool live = true;

  @override
  bool get isLive => live;

  @override
  Stream<Map<String, Object?>> get messages => _inbound.stream;

  @override
  void send(Map<String, Object?> message) {
    sent.add(message);
  }

  void emit(Map<String, Object?> frame) {
    _inbound.add(frame);
  }

  Future<void> dispose() => _inbound.close();

  int get stopCount =>
      sent.where((Map<String, Object?> f) => f['type'] == 'stop').length;
}

class _Harness {
  _Harness() {
    transport = EngineTransport(link: link, log: logs.add);
    transport.started.listen((void _) => startedEvents.add(null));
    transport.output.listen(outputEvents.add);
    transport.errorOccurred.listen(errorEvents.add);
    transport.finished.listen((void _) => finishedEvents.add(null));
  }

  final _FakeEngineRuntimeLink link = _FakeEngineRuntimeLink();
  late final EngineTransport transport;

  final List<String> logs = <String>[];
  final List<void> startedEvents = <void>[];
  final List<Uint8List> outputEvents = <Uint8List>[];
  final List<EngineProcessError> errorEvents = <EngineProcessError>[];
  final List<void> finishedEvents = <void>[];

  int get sentCount => link.sent.length;
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

String _b64(String text) => base64Encode(utf8.encode(text));

Map<String, Object?> _frame(String type, String session,
        [Map<String, Object?> extra = const <String, Object?>{}]) =>
    <String, Object?>{
      EngineWire.type: type,
      EngineWire.session: session,
      ...extra,
    };

/// worker.cjs:433-452 的命令帧：恰好 id / route / body 三键，经 stdin 逐行输入。
Map<String, Object?> _workerCommand(
  String id,
  String route,
  Map<String, Object?> body,
) =>
    <String, Object?>{
      'id': id,
      'route': route,
      'body': body,
    };

/// ios-runtime.cjs:84-86 把 input.data 原样写进 worker.stdin；断行符 0x0a。
Uint8List _commandBytes(List<Map<String, Object?>> commands) =>
    Uint8List.fromList(utf8.encode(
      commands.map((Map<String, Object?> command) => jsonEncode(command) + '\n').join(),
    ));

/// 按 worker.cjs:430-464 的 readline 语义切行；每行必须是一个独立 JSON 对象。
List<Map<String, Object?>> _decodeCommandLines(Uint8List bytes) {
  final String text = utf8.decode(bytes);
  final List<String> lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines
      .where((String line) => line.isNotEmpty)
      .map((String line) => (jsonDecode(line) as Map<Object?, Object?>)
          .cast<String, Object?>())
      .toList();
}

void main() {
  const String root = '/data/user/0/rhine.music.database/files';
  const String temporary = '/data/user/0/rhine.music.database/cache';
  const String edition = 'kugou-lite';

  group('T21-C19-W1 EngineTransport（Qt BridgeProcessAndroid.cpp:171-281 1:1）', () {
    late _Harness h;

    setUp(() {
      h = _Harness();
    });

    tearDown(() async {
      h.transport.kill();
      await h.link.dispose();
    });

    test('wire 常量与 Qt 线路字面量一致（含 iOS 词汇表与 delimiter）', () {
      expect(EngineWire.type, 'type');
      expect(EngineWire.session, 'session');
      expect(EngineWire.data, 'data');
      expect(EngineWire.detail, 'detail');
      expect(EngineWire.exitCode, 'exitCode');
      expect(EngineWire.script, 'script');
      expect(EngineWire.env, 'env');
      expect(EngineWire.stderrLog, 'stderrLog');
      expect(EngineWire.start, 'start');
      expect(EngineWire.input, 'input');
      expect(EngineWire.stop, 'stop');
      expect(EngineWire.started, 'started');
      expect(EngineWire.output, 'output');
      expect(EngineWire.stderr, 'stderr');
      expect(EngineWire.error, 'error');
      expect(EngineWire.finished, 'finished');
      // Android 只把它们当线路词汇表：BridgeProcessAndroid.cpp 无 system-trust 分支。
      expect(EngineWire.systemTrust, 'system-trust');
      expect(EngineWire.systemTrustResult, 'system-trust-result');
      expect(EngineWire.runtimeError, 'runtime-error');
      expect(EngineWire.delimiter, 0x0a);

      expect(EngineProcessState.values.length, 3);
      expect(EngineProcessError.values.length, 3);
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.transport.session, isNull);
      // Qt/src/BridgeProcess.h:43：m_error 初值 UnknownError；frozenApi 亦为非空 getter。
      expect(h.transport.error, EngineProcessError.unknownError);
      expect(h.transport.startTimeout, const Duration(seconds: 30));
      expect(h.sentCount, 0);
    });

    test('start 帧五键 + env 四键的键集对齐 BridgeProcessAndroid.cpp:202-211（值见 D1）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);

      expect(h.sentCount, 1);
      final Map<String, Object?> frame = h.link.sent.single;
      expect(
        frame.keys.toSet(),
        <String>{'type', 'session', 'script', 'stderrLog', 'env'},
        reason: 'start 帧恰好五键，不得夹带',
      );
      expect(frame['type'], 'start');
      expect(frame['session'], h.transport.session);
      expect(frame['script'], '$root/MusicBridge/worker.cjs');
      expect(frame['stderrLog'], true);

      // 键名/键数与 Qt 一致；路径值不是 Qt 真值：D1 已登记 TMPDIR/device-state 的近似
      // （Qt:194-205 用 CacheLocation 与 AppStorage::dataDirectory()，且 Qt:182 忽略 temporary）。
      final Map<String, Object?> env = frame['env']! as Map<String, Object?>;
      expect(env.length, 4, reason: 'env 恰好四键，不得夹带');
      expect(env['TMPDIR'], temporary);
      expect(env['RHINE_QQ_DEVICE_STATE_PATH'], '$root/qq-device.json');
      expect(env['RHINE_KUGOU_DEVICE_STATE_PATH'], '$root/kugou-device.json');
      expect(env['RHINE_KUGOU_EDITION'], edition);

      expect(h.transport.state, EngineProcessState.starting);
      expect(h.transport.error, EngineProcessError.unknownError);
    });

    test('extraEnv 只能追加，绝不覆盖 Qt 的四个权威环境变量（rules 10）', () {
      h.transport.start(
        root: root,
        temporary: temporary,
        edition: edition,
        extraEnv: const <String, String>{
          'TMPDIR': '/tmp/evil',
          'RHINE_KUGOU_EDITION': 'ios-lite',
          'RHINE_TEST_FLAG': 'on',
        },
      );
      final Map<String, Object?> env =
          h.link.sent.single['env']! as Map<String, Object?>;
      expect(env['TMPDIR'], temporary);
      expect(env['RHINE_KUGOU_EDITION'], edition);
      expect(env['RHINE_QQ_DEVICE_STATE_PATH'], '$root/qq-device.json');
      expect(env['RHINE_KUGOU_DEVICE_STATE_PATH'], '$root/kugou-device.json');
      expect(env['RHINE_TEST_FLAG'], 'on');
      expect(env.length, 5);
    });

    test('session 每次 start 唯一、无花括号、符合 UUIDv4 版式（:184）', () {
      final RegExp v4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );

      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String first = h.transport.session!;
      expect(v4.hasMatch(first), isTrue, reason: first);
      expect(first.contains('{'), isFalse);
      expect(first.contains('}'), isFalse);
      expect(first.length, 36);

      // 每次 start 都是新会话（Qt:184），kill 之后也一样；循环里 kill 顺带收掉 30s 定时器，
      // 避免用例结束时留下大量悬挂 Timer。
      final Set<String> seen = <String>{first};
      for (int i = 0; i < 201; i++) {
        h.transport.kill();
        h.transport.start(root: root, temporary: temporary, edition: edition);
        final String next = h.transport.session!;
        expect(v4.hasMatch(next), isTrue, reason: next);
        seen.add(next);
      }
      expect(seen.length, 202, reason: '每次 start 必须新建会话，不得复用');
    });

    testWidgets('30s 定时器：starting 且同 session 时 kill（:213-217）',
        (WidgetTester tester) async {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;

      await tester.pump(const Duration(seconds: 29));
      expect(h.transport.state, EngineProcessState.starting);
      expect(h.transport.session, session);
      expect(h.sentCount, 1, reason: '未到 30s 不得发 stop');
      expect(h.finishedEvents, isEmpty);

      await tester.pump(const Duration(seconds: 1));
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.transport.session, isNull);
      expect(h.finishedEvents.length, 1);
      expect(h.link.stopCount, 1);
      expect(h.link.sent.last['type'], 'stop');
      expect(h.link.sent.last['session'], session);
    });

    testWidgets('30s 定时器：state==running 时同 session 也不 kill',
        (WidgetTester tester) async {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));
      expect(h.transport.state, EngineProcessState.running);

      await tester.pump(const Duration(seconds: 61));
      expect(h.transport.state, EngineProcessState.running,
          reason: '守卫的前半句：m_state == Starting 才 kill');
      expect(h.sentCount, 1, reason: 'running 后定时器不得 kill');
      expect(h.finishedEvents, isEmpty);
      h.transport.kill();
    });

    testWidgets('30s 守卫按 session 绑定：旧会话定时器不得误杀新会话',
        (WidgetTester tester) async {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String first = h.transport.session!;
      await tester.pump(const Duration(seconds: 20));

      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String second = h.transport.session!;
      expect(second, isNot(first));

      // 推进到第一个会话的 30s 之后：守卫的 session 半句必须拦住 kill。
      await tester.pump(const Duration(seconds: 15));
      expect(h.transport.session, second);
      expect(h.transport.state, EngineProcessState.starting);
      expect(h.link.stopCount, 0, reason: '旧会话的定时器不得对新会话发 stop');
      expect(h.finishedEvents, isEmpty);
      h.transport.kill();
    });

    testWidgets('kill 之后的 30s 定时器不再触发（守卫 state 半句 + 定时器收殓）',
        (WidgetTester tester) async {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      await tester.pump(const Duration(seconds: 5));
      h.transport.kill();
      final int framesAfterKill = h.sentCount;

      await tester.pump(const Duration(seconds: 40));
      expect(h.sentCount, framesAfterKill, reason: '已经 kill 的会话不得再发帧');
      expect(h.link.stopCount, 1);
      expect(h.finishedEvents.length, 1, reason: '不得重复 emit finished');
      expect(h.transport.state, EngineProcessState.notRunning);
    });

    test('kill：发 stop + notRunning + 清 session/output + 单个 finished；幂等（:226-235）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));
      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: base64Encode(_bytes(<int>[7, 8, 9])),
      }));
      expect(h.outputEvents.length, 1);

      h.transport.kill();
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.transport.session, isNull);
      expect(h.link.sent.last['type'], 'stop');
      expect(h.link.sent.last['session'], session);
      expect(h.finishedEvents.length, 1, reason: 'finished 必须同步送达，无需 await');
      expect(
        h.transport.readAllStandardOutput(),
        isEmpty,
        reason: 'kill 清空 output（:233 m_output.clear()）',
      );

      final int framesAfterKill = h.sentCount;
      h.transport.kill();
      expect(h.sentCount, framesAfterKill, reason: '幂等：notRunning 时不再发帧');
      expect(h.finishedEvents.length, 1);
    });

    test('terminate 等价 kill（:236-238）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.transport.terminate();
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.transport.session, isNull);
      expect(h.link.sent.last['type'], 'stop');
      expect(h.link.sent.last['session'], session);
      expect(h.finishedEvents.length, 1);
    });

    test('write 发 {type:input, session, data:base64}，无状态守卫（:219-222）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;

      h.transport.write(_bytes(<int>[1, 2, 3]));
      final Map<String, Object?> frame = h.link.sent.last;
      expect(frame.keys.toSet(), <String>{'type', 'session', 'data'});
      expect(frame['type'], 'input');
      expect(frame['session'], session);
      expect(frame['data'], base64Encode(_bytes(<int>[1, 2, 3])));

      // Qt 无状态守卫：session 已清空时序列化为空字符串。
      h.transport.kill();
      h.transport.write(_bytes(<int>[4]));
      expect(h.link.sent.last['type'], 'input');
      expect(h.link.sent.last['session'], '');
      expect(h.link.sent.last['data'], base64Encode(_bytes(<int>[4])));
    });

    test('worker.cjs 命令帧：id/route/body 三键、0x0a 分行、输入顺序保持', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      final Map<String, Object?> first = _workerCommand(
        'cmd-1',
        '/native/netease/search',
        <String, Object?>{'keywords': 'rhine', 'limit': 30},
      );
      final Map<String, Object?> second = _workerCommand(
        'cmd-2',
        '/native/netease/song/url',
        <String, Object?>{'id': '42', 'quality': 320},
      );

      h.transport.write(_commandBytes(<Map<String, Object?>>[first, second]));

      expect(h.sentCount, 2, reason: 'start + 一个 input 帧；一次 write 不拆帧');
      final Map<String, Object?> frame = h.link.sent.last;
      expect(frame.keys.toSet(), <String>{'type', 'session', 'data'});
      expect(frame['type'], EngineWire.input);
      expect(frame['session'], session);
      final Uint8List input = base64Decode(frame['data']! as String);
      expect(utf8.decode(input).endsWith('\n'), isTrue,
          reason: 'worker.cjs:430-437 readline 需要 0x0a 行尾');
      final List<Map<String, Object?>> commands = _decodeCommandLines(input);
      expect(commands, hasLength(2), reason: '两行必须各自保留，不得合并');
      expect(commands[0].keys.toSet(), <String>{'id', 'route', 'body'});
      expect(commands[1].keys.toSet(), <String>{'id', 'route', 'body'});
      expect(commands[0]['id'], 'cmd-1');
      expect(commands[0]['route'], '/native/netease/search');
      expect(commands[0]['body'], first['body']);
      expect(commands[1]['id'], 'cmd-2');
      expect(commands[1]['route'], '/native/netease/song/url');
      expect(commands[1]['body'], second['body']);
      expect(<Object?>[commands[0]['id'], commands[1]['id']],
          <Object?>['cmd-1', 'cmd-2'],
          reason: 'worker.cjs:92-99 逐行串行，线路顺序就是执行顺序');
    });

    test('worker.cjs 不合并相同命令：重复行与重复 write 都逐条保留', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final Map<String, Object?> command = _workerCommand(
        'same-id',
        '/native/netease/playlist',
        <String, Object?>{'id': 'playlist-7'},
      );

      h.transport.write(_commandBytes(<Map<String, Object?>>[command, command]));
      final List<Map<String, Object?>> firstBatch = _decodeCommandLines(
        base64Decode(h.link.sent.last['data']! as String),
      );
      expect(firstBatch, hasLength(2), reason: '同一 write 内的重复命令不得去重');
      expect(firstBatch[0]['id'], 'same-id');
      expect(firstBatch[1]['id'], 'same-id');
      expect(firstBatch[0], firstBatch[1]);

      h.transport.write(_commandBytes(<Map<String, Object?>>[command]));
      final List<Map<String, Object?>> secondBatch = _decodeCommandLines(
        base64Decode(h.link.sent.last['data']! as String),
      );
      expect(secondBatch, hasLength(1));
      expect(secondBatch.single['id'], 'same-id');
      expect(h.link.sent.where((Map<String, Object?> frame) =>
          frame['type'] == EngineWire.input), hasLength(2),
          reason: '两次 write 产生两个 input 帧，传输层不得合并');
    });

    test('worker.cjs 响应帧原样透传：id/body/cookies 与 503 回退都不改写', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      final Map<String, Object?> ok = _frame(EngineWire.output, session, <String, Object?>{
        'data': _b64(jsonEncode(<String, Object?>{
          'id': 'cmd-1',
          'body': <String, Object?>{'code': 200, 'data': <String, Object?>{'ok': true}},
          'cookies': <Object?>['a=1'],
        }) + '\n'),
      });
      final Map<String, Object?> failure = _frame(EngineWire.output, session, <String, Object?>{
        'data': _b64(jsonEncode(<String, Object?>{
          'id': 'cmd-2',
          'body': <String, Object?>{
            'code': 503,
            'message': '音乐请求失败，请重试',
          },
          'cookies': <Object?>[],
        }) + '\n'),
      });
      h.link.emit(ok);
      h.link.emit(failure);

      expect(h.outputEvents, hasLength(2));
      final List<Map<String, Object?>> responses = <Map<String, Object?>>[];
      for (final Uint8List event in h.outputEvents) {
        final List<Map<String, Object?>> lines = _decodeCommandLines(event);
        expect(lines, hasLength(1));
        responses.add(lines.single);
      }
      expect(responses[0].keys.toSet(), <String>{'id', 'body', 'cookies'});
      expect(responses[1].keys.toSet(), <String>{'id', 'body', 'cookies'});
      expect(responses[0]['id'], 'cmd-1');
      expect(responses[1]['id'], 'cmd-2');
      expect((responses[1]['body']! as Map<String, Object?>)['code'], 503);
      expect((responses[1]['body']! as Map<String, Object?>)['message'],
          '音乐请求失败，请重试');
      expect(responses[1]['cookies'], <Object?>[]);
      expect(h.transport.state, EngineProcessState.starting,
          reason: 'output 只是数据，不改变会话状态');
    });

    test('closeWriteChannel 空操作、绝不关闭共享连接（:239-241）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final int before = h.sentCount;
      h.transport.closeWriteChannel();
      expect(h.sentCount, before, reason: '不得发出任何帧');
      expect(h.link.isLive, isTrue, reason: '共享传输连接必须存活');
      expect(h.transport.state, EngineProcessState.starting);
      expect(h.transport.session, isNotNull);
      expect(h.finishedEvents, isEmpty);
    });

    test('waitForFinished 非阻塞返回 state==notRunning（:242-245）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      expect(h.transport.waitForFinished(1), isFalse);
      expect(h.transport.waitForFinished(60000), isFalse, reason: '参数被忽略');

      h.link.emit(_frame(EngineWire.started, session));
      expect(h.transport.waitForFinished(1), isFalse);

      h.transport.terminate();
      expect(h.transport.waitForFinished(1), isTrue);
    });

    test('started → running 且 emit started（:264-266）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      expect(h.transport.state, EngineProcessState.starting);
      expect(h.startedEvents, isEmpty);

      h.link.emit(_frame(EngineWire.started, session));
      expect(h.transport.state, EngineProcessState.running);
      expect(h.startedEvents.length, 1, reason: 'started 事件同步送达');
    });

    test('output → base64 解码、累加、emit output；readAllStandardOutput 取走即清空（:223-225,267-269）',
        () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));

      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: _b64('hello'),
      }));
      expect(h.outputEvents.length, 1);
      expect(utf8.decode(h.outputEvents.single), 'hello');
      expect(utf8.decode(h.transport.readAllStandardOutput()), 'hello');
      expect(
        h.transport.readAllStandardOutput(),
        isEmpty,
        reason: 'std::exchange(m_output, {}) 语义：取走即清空',
      );

      // 多帧累加。
      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: _b64('a'),
      }));
      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: _b64('b'),
      }));
      expect(utf8.decode(h.transport.readAllStandardOutput()), 'ab');
      expect(h.outputEvents.length, 3);
      expect(h.transport.state, EngineProcessState.running);
    });

    test('会话匹配但 data 非法（非 String / 非法 base64）被拒绝，不抛异常', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));

      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: 123,
      }));
      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: '!!!not-base64!!!',
      }));
      h.link.emit(_frame(EngineWire.output, session));

      expect(h.transport.readAllStandardOutput(), isEmpty);
      expect(h.outputEvents, isEmpty);
      expect(h.transport.state, EngineProcessState.running);
    });

    test('陈旧 session 的 output 帧在 base64 解码之前被丢弃（:261）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));

      // 非空但非法 base64：若在过滤前解码就会抛异常。
      h.link.emit(_frame(EngineWire.output, 'someone-elses-session',
          <String, Object?>{EngineWire.data: '!!!not-base64!!!'}));
      // 非 String 的 session 也永不匹配（QJsonValue::toString() 语义）。
      h.link.emit(_frame(EngineWire.output, session, <String, Object?>{
        EngineWire.data: '!!!not-base64!!!',
      }));
      h.link.emit(<String, Object?>{
        EngineWire.type: EngineWire.output,
        EngineWire.session: 42,
        EngineWire.data: '!!!not-base64!!!',
      });

      expect(h.transport.readAllStandardOutput(), isEmpty);
      expect(h.outputEvents, isEmpty);
      expect(h.transport.state, EngineProcessState.running);
    });

    test('stderr 先于会话过滤：陈旧 session 也记日志且不污染 output（:248-253）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));

      h.link.emit(_frame(EngineWire.stderr, 'stale', <String, Object?>{
        EngineWire.data: _b64('boom\n'),
      }));
      expect(h.logs, isNotEmpty);
      expect(h.logs.last, 'boom', reason: 'QByteArray::trimmed() 语义');
      expect(h.transport.readAllStandardOutput(), isEmpty);
      expect(h.transport.state, EngineProcessState.running);

      // 未启动（notRunning）时 stderr 依然先于会话判断被消费。
      h.transport.kill();
      h.link.emit(_frame(EngineWire.stderr, 'whatever', <String, Object?>{
        EngineWire.data: _b64('after-kill'),
      }));
      expect(h.logs.last, 'after-kill');
      expect(h.transport.state, EngineProcessState.notRunning);

      // 非法 base64 不得抛出：回退原文（见实现 D6）。
      h.link.emit(_frame(EngineWire.stderr, 'whatever', <String, Object?>{
        EngineWire.data: '!!!not-base64!!!',
      }));
      expect(h.logs.last, '!!!not-base64!!!');
    });

    test('runtime-error 先于会话过滤：陈旧 session 也映射 failedToStart（:254-260）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));
      expect(h.transport.state, EngineProcessState.running);

      h.link.emit(_frame(EngineWire.runtimeError, 'stale-session-id'));
      expect(h.transport.error, EngineProcessError.failedToStart);
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.errorEvents.single, EngineProcessError.failedToStart);
      expect(h.finishedEvents.length, 1);
      expect(h.transport.readAllStandardOutput(), isEmpty);
      // Qt:254-260 不清 m_session。
      expect(h.transport.session, session);
    });

    test('runtime-error 在 notRunning（从未 start）时同样被处理', () {
      expect(h.transport.state, EngineProcessState.notRunning);
      h.link.emit(<String, Object?>{EngineWire.type: EngineWire.runtimeError});
      expect(h.transport.error, EngineProcessError.failedToStart);
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.errorEvents.single, EngineProcessError.failedToStart);
      expect(h.finishedEvents.length, 1);
    });

    test('error → crashed 且记 detail；finished → crashed 且记 exitCode（:270-280）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String first = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, first));

      h.link.emit(_frame(EngineWire.error, first, <String, Object?>{
        EngineWire.detail: 'RangeError: boom',
      }));
      expect(h.logs.last, 'RangeError: boom');
      expect(h.transport.error, EngineProcessError.crashed);
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.finishedEvents.length, 1);
      expect(h.errorEvents, isEmpty, reason: 'Qt:270-280 只 emit finished，不 emit errorOccurred');
      // Qt 的 error/finished 分支不清 m_session。
      expect(h.transport.session, first);

      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String second = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, second));
      h.link.emit(_frame(EngineWire.finished, second, <String, Object?>{
        EngineWire.exitCode: 17,
      }));
      expect(h.logs.last, '17');
      expect(h.transport.error, EngineProcessError.crashed);
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.finishedEvents.length, 2);
    });

    test('非法 detail / 非法 exitCode 被拒绝：不记日志但崩溃迁移照旧（rules 1）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));

      h.link.emit(_frame(EngineWire.error, session, <String, Object?>{
        EngineWire.detail: 42,
      }));
      expect(h.logs, isEmpty, reason: '非 String 的 detail 不得被 toString() 塞进日志');
      expect(h.transport.error, EngineProcessError.crashed);
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.finishedEvents.length, 1);

      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String second = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, second));
      h.link.emit(_frame(EngineWire.finished, second, <String, Object?>{
        EngineWire.exitCode: 'seventeen',
      }));
      expect(h.logs, isEmpty, reason: '非 int 的 exitCode 不得被 toString() 塞进日志');
      expect(h.transport.error, EngineProcessError.crashed);
      expect(h.finishedEvents.length, 2);
    });

    test('detail 优先于 exitCode 且 containsKey 语义（Qt:272-276）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));

      // 两字段同时存在：Qt 的 if/else-if 只记 detail。
      h.link.emit(_frame(EngineWire.error, session, <String, Object?>{
        EngineWire.detail: 'primary',
        EngineWire.exitCode: 9,
      }));
      expect(h.logs.single, 'primary');
      expect(h.transport.error, EngineProcessError.crashed);
    });

    test('error 与 Qt m_error 一样跨 kill/start 保留（:226-235 不重置）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));
      h.link.emit(_frame(EngineWire.runtimeError, session));
      expect(h.transport.error, EngineProcessError.failedToStart);

      h.transport.start(root: root, temporary: temporary, edition: edition);
      expect(h.transport.error, EngineProcessError.failedToStart);
      h.transport.kill();
      expect(h.transport.error, EngineProcessError.failedToStart);
    });

    test('system-trust / system-trust-result 在 Android 上静默丢弃（v1.1，iOS 分支不移植）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));
      final int framesBefore = h.sentCount;

      // 会话匹配：不得回 system-trust-result（BridgeProcessIOS.cpp:70-78 的 iOS 通道）。
      h.link.emit(_frame(EngineWire.systemTrust, session, <String, Object?>{
        'id': 'ios-only',
      }));
      // 会话不匹配：同样丢弃。
      h.link.emit(_frame(EngineWire.systemTrust, 'stale', <String, Object?>{
        'id': 'ios-only',
      }));
      // 反向的 system-trust-result 也只是词汇表。
      h.link.emit(_frame(EngineWire.systemTrustResult, session, <String, Object?>{
        'id': 'ios-only',
        'trusted': true,
      }));

      // 三条帧之后：既无回包，也无任何状态/输出/事件变化。
      expect(h.sentCount, framesBefore, reason: '不得回 system-trust-result');
      expect(h.transport.state, EngineProcessState.running);
      expect(h.transport.error, EngineProcessError.unknownError);
      expect(h.transport.readAllStandardOutput(), isEmpty);
      expect(h.startedEvents.length, 1);
      expect(h.finishedEvents, isEmpty);
      expect(h.errorEvents, isEmpty);

      // 未启动时也不会被豁免（会话匹配照样丢弃）。
      h.transport.kill();
      final int afterKill = h.sentCount;
      h.link.emit(_frame(EngineWire.systemTrust, session, <String, Object?>{
        'id': 'ios-only',
      }));
      expect(h.sentCount, afterKill);
      expect(h.finishedEvents.length, 1, reason: '只有 kill 的那一次');
      expect(h.errorEvents, isEmpty);
      expect(h.transport.error, EngineProcessError.unknownError);
    });

    test('未知 type 先经会话过滤后静默忽略（防跨会话透传）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String session = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, session));
      final int framesBefore = h.sentCount;

      h.link.emit(_frame('some-future-frame', session));
      h.link.emit(_frame('some-future-frame', 'stale'));

      expect(h.sentCount, framesBefore);
      expect(h.transport.state, EngineProcessState.running);
      expect(h.transport.error, EngineProcessError.unknownError);
      expect(h.finishedEvents, isEmpty);
      expect(h.startedEvents.length, 1);
    });

    test('notRunning 时任何入站帧都被丢弃（:261 前半句）', () {
      expect(h.transport.state, EngineProcessState.notRunning);
      h.link.emit(_frame(EngineWire.started, 'anything'));
      h.link.emit(_frame(EngineWire.output, 'anything', <String, Object?>{
        EngineWire.data: _b64('ignored'),
      }));
      h.link.emit(_frame(EngineWire.finished, 'anything', <String, Object?>{
        EngineWire.exitCode: 0,
      }));
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.startedEvents, isEmpty);
      expect(h.outputEvents, isEmpty);
      expect(h.finishedEvents, isEmpty);
      expect(h.transport.readAllStandardOutput(), isEmpty);
    });

    test('running 中再次 start：不发 stop、直接换会话（Qt:179-183 无守卫）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String first = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, first));
      expect(h.transport.state, EngineProcessState.running);

      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String second = h.transport.session!;
      expect(second, isNot(first));
      expect(h.transport.state, EngineProcessState.starting);
      expect(h.link.stopCount, 0, reason: 'Qt:179-218 不会为旧会话补发 stop');
      expect(h.finishedEvents, isEmpty);
      // 旧会话的后续帧已不匹配新会话。
      h.link.emit(_frame(EngineWire.started, first));
      expect(h.transport.state, EngineProcessState.starting);
      h.link.emit(_frame(EngineWire.started, second));
      expect(h.transport.state, EngineProcessState.running);
      expect(h.startedEvents.length, 1);
    });

    test('完整生命周期：start → started → output → kill → 新会话（集成契约同构）', () {
      h.transport.start(root: root, temporary: temporary, edition: edition);
      final String first = h.transport.session!;
      h.link.emit(_frame(EngineWire.started, first));
      h.link.emit(_frame(EngineWire.output, first, <String, Object?>{
        EngineWire.data: _b64('payload'),
      }));
      expect(h.transport.state, EngineProcessState.running);
      expect(utf8.decode(h.transport.readAllStandardOutput()), 'payload');
      expect(h.transport.readAllStandardOutput(), isEmpty);

      h.transport.kill();
      expect(h.transport.state, EngineProcessState.notRunning);
      expect(h.transport.session, isNull);
      expect(h.finishedEvents.length, 1);
      expect(h.link.sent.last['session'], first);

      h.transport.start(root: root, temporary: temporary, edition: edition);
      expect(h.transport.session, isNot(first));
      expect(h.transport.state, EngineProcessState.starting);
      expect(h.link.sent.last['type'], 'start');
      expect(h.link.sent.last['session'], h.transport.session);
    });
  });
}
