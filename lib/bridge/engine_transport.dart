// 会话传输层：与原生侧的单条回环控制连接，对齐 Qt/src/BridgeProcessAndroid.cpp:171-281
// 与 BridgeProcess.h:13-46 的状态机；协议对端是 MusicBridge/ios-runtime.cjs。
//
// 本层边界：不开 socket、不生成 token、不做 0x0a 分帧、不管 48MiB 上限与握手排队，
// 这些由 node_runtime.dart 通过 EngineRuntimeLink（send / messages / isLive）承担。
// 本文件定义 EngineRuntimeLink，node_runtime.dart 反向 import 本文件；本文件绝不
// import node_runtime.dart（避免环）。
//
// error 初值是 unknownError 而不是 null：与 Qt 的 m_error（BridgeProcess.h:43）一致。
//
// 与 Qt 的可观测差异：
//   D1 环境路径只能近似：Flutter 侧没有 AppStorage 单例，冻结签名也没有 data/cache
//      注入缝，故用 temporary 近似 TMPDIR、用 root 近似 dataDirectory；Qt:201 的
//      QDir.mkpath 也不执行（本层无 dart:io，目录创建留给宿主）。
//   D2 extraEnv 只追加、不覆盖 Qt 的四键（临时目录/设备态/版本），Qt 键优先。
//   D3 kill/start 会取消上一次的 30s 定时器；Qt 靠 m_session/m_state 自守卫且不取消。
//      守卫条件仍逐字保留作第二道防线，取消只为避免 flutter_test 的 pending timer。
//   D4 launch 不在本层，且 isLive 不能代替它：launch 失败需由 NodeRuntime 合成
//      runtime-error；装配顺序必须是先 launch 成功再 start，否则 start 帧会留在
//      认证前队列直到 30s 超时。
//   D5 stderr 日志只记正文，前缀由呈现层加。
//   D6 stderr 的 base64 用严格解码，失败回退原文；两者都不向调用方抛异常。
//   D7 入站帧没有 owner 语义：link.messages 是广播流，靠 session 过滤；stderr 与
//      runtime-error 走旁路，多实例并存时会各处理一份（单实例下不可观测）。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 原生侧（Android NodeRuntimeHost / 桌面宿主）单条回环控制连接的 Dart 侧抽象。
///
/// 由 lib/bridge/node_runtime.dart 的 NodeRuntimeEngineLink 实现；本层只通过它与线路交互：
///   * send：写出一帧。实现负责 compact JSON + 0x0a 定界与认证前排队
///     （node_runtime.dart:348-361，对应 Qt:130-137）；本层不碰字节层。
///   * messages：入站帧流，含 NodeRuntime 合成的 runtime-error（node_runtime.dart:560-565）；
///     是广播流，没有 owner 语义（见文件头 D7）。
///   * isLive：与 Qt:99-100 的 !exited && (!socket || 已连接) 近似——Qt 只在 launch 已成功时求值
///     该式（Qt:99 的守卫），本层把「已 launch、未退出、未 shutdown」外置为 getter 的前置门，即
///     _launched && !_exited && !_shutdown && (_socket == null || _socketLive)
///     （node_runtime.dart:256-258）。Qt 把「尚未连接」也算存活，故它不表示「已就绪」，
///     也不能用来判断 launch 是否成功（见文件头 D4）。
///
/// 协议上限（48 MiB 读缓冲、首帧 token 握手）在实现的入站读取路径上（Qt:71-96），不在 send 上。
abstract interface class EngineRuntimeLink {
  void send(Map<String, Object?> message);

  Stream<Map<String, Object?>> get messages;

  bool get isLive;
}

/// Qt/src/BridgeProcess.h:16 的 enum ProcessState { NotRunning, Starting, Running } 的 1:1 映射。
enum EngineProcessState { notRunning, starting, running }

/// Qt/src/BridgeProcess.h:17 的 enum ProcessError { FailedToStart, Crashed, UnknownError } 的 1:1 映射。
enum EngineProcessError { failedToStart, crashed, unknownError }

/// 与 Qt 线路逐字一致的键名与类型字面量（契约 wireKeys）。
///
/// 只作线路词汇表；会话状态机状态归 [EngineTransport] 自己持有，不在两层重复维护。
abstract final class EngineWire {
  static const String type = 'type';
  static const String session = 'session';
  static const String data = 'data';
  static const String detail = 'detail';
  static const String exitCode = 'exitCode';

  /// start 帧专用键（Qt/src/BridgeProcessAndroid.cpp:207-211）。
  static const String script = 'script';
  static const String env = 'env';
  static const String stderrLog = 'stderrLog';

  static const String start = 'start';
  static const String input = 'input';
  static const String stop = 'stop';
  static const String started = 'started';
  static const String output = 'output';
  static const String stderr = 'stderr';
  static const String error = 'error';
  static const String finished = 'finished';

  /// iOS 专属通道词汇（Qt/src/BridgeProcessIOS.cpp:70-78）。Android 上只作线路词汇表：
  /// Qt/src/BridgeProcessAndroid.cpp:92-93 的 read() 无 system-trust 分支，帧落到 accept()（:246-281），
  /// 先被 :261 会话过滤、再因无匹配分支被静默丢弃——绝不回 system-trust-result。
  static const String systemTrust = 'system-trust';
  static const String systemTrustResult = 'system-trust-result';

  /// 宿主侧合成的运行时失败回传（非 ios-runtime.cjs 发出）。Qt 有三处合成：:63-67 控制连接
  /// 断开、:152-159 node::Start 返回、:186-189 launch 失败；本层的对端是 NodeRuntime 的同类
  /// 上报（node_runtime.dart:545-565）。
  static const String runtimeError = 'runtime-error';

  /// Qt 线路定界符；本层不做字节分帧，常量仅为契约一致性与 node_runtime 复用。
  static const int delimiter = 0x0a;
}

/// Qt BridgeProcess 会话半部分的逐条移植（Qt/src/BridgeProcessAndroid.cpp:171-281），
/// 与 Qt 的可观测差异见文件头 D1-D7。
///
/// 一个实例对应 Qt 侧一个 BridgeProcess 对象：kill 后可再次 start，共享同一进程级 runtime 连接
/// （Qt:164-168 的单例）。start() 的前置条件见该方法文档。
final class EngineTransport {
  /// [log] 对应 Qt 的 logcat 输出（stderr 正文与 error.detail / finished.exitCode）。
  EngineTransport({
    required EngineRuntimeLink link,
    void Function(String)? log,
  })  : _link = link,
        _log = log {
    // 订阅在构造期建立且刻意永不取消：Qt 的 NodeRuntime 是进程级单例（Qt:164-168），连接跨会话
    // 复用，且 Qt:185 每次 start 把 owner 换成最新 BridgeProcess；本层没有 owner 通道（D7），
    // 冻结 API 也没有 dispose()，故订阅永久保留、靠 session 过滤隔离。
    _link.messages.listen(_handleMessage);
  }

  final EngineRuntimeLink _link;
  final void Function(String)? _log;

  /// 等价 Qt 的 m_output（std::exchange(m_output, {}) 语义见 [readAllStandardOutput]）。
  final BytesBuilder _output = BytesBuilder(copy: false);

  // Qt 信号是同步的；协调者集成测试在 kill() 之后不 await 就断言 finished 事件数，
  // 本层自己的测试也要求确定性，故全部使用 sync broadcast。
  final StreamController<void> _startedController =
      StreamController<void>.broadcast(sync: true);
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<EngineProcessError> _errorController =
      StreamController<EngineProcessError>.broadcast(sync: true);
  final StreamController<void> _finishedController =
      StreamController<void>.broadcast(sync: true);

  static int _sessionSequence = 0;

  String? _session;
  EngineProcessState _state = EngineProcessState.notRunning;
  EngineProcessError _error = EngineProcessError.unknownError;
  Timer? _startTimer;

  /// Qt/src/BridgeProcessAndroid.cpp:213-217 的 30000ms 单次定时器。
  Duration startTimeout = const Duration(seconds: 30);

  /// 当前会话标识。kill() 之后为 null（等价 Qt:232 m_session.clear()）；runtime-error 与
  /// error/finished 只把 state 置 notRunning，不清会话（Qt:254-260 与 :270-280 只改 m_error/m_state；
  /// 其间的 output 分支 :267-269 只追加 m_output）。
  String? get session => _session;

  EngineProcessState get state => _state;

  /// Qt/src/BridgeProcess.h:43 的 m_error 初值 UnknownError；契约规定为非空 getter。
  EngineProcessError get error => _error;

  Stream<void> get started => _startedController.stream;

  Stream<Uint8List> get output => _outputController.stream;

  Stream<EngineProcessError> get errorOccurred => _errorController.stream;

  Stream<void> get finished => _finishedController.stream;

  /// Qt/src/BridgeProcessAndroid.cpp:179-218 的会话启动半部分。
  ///
  /// 前置条件（由调用方保证，接口无法表达）：先 NodeRuntime.launch(root, host)，返回 true 之后
  /// 再调用本方法；launch 失败不得 start。本层只发 start 帧并管理状态机，不做 launch（文件头
  /// D4），也不做 Qt:185 的 owner 接管与 Qt:201 的 mkpath（D7/D1）。
  void start({
    required String root,
    required String temporary,
    required String edition,
    Map<String, String> extraEnv = const <String, String>{},
  }) {
    _startTimer?.cancel();
    _startTimer = null;

    // Qt:183-184：先置 Starting、再分配新会话（不清理旧的 output/error，与 Qt 一致）。
    _state = EngineProcessState.starting;
    final String session = _newSessionId();
    _session = session;

    // Qt:202-206：env 四键。TMPDIR 与两个 device-state 是 D1 近似值（Qt 真值分别是
    // CacheLocation 与 AppStorage::dataDirectory()），键名与键数才与 Qt 逐字一致。
    // Qt 键先写入，extraEnv 只允许追加新键，绝不覆盖（文件头 D2；契约 engine_transport.rules
    // 只有 9 条且无 env 规则，扩展缝来自契约签名本身）。
    final Map<String, Object?> environment = <String, Object?>{
      'TMPDIR': temporary,
      'RHINE_QQ_DEVICE_STATE_PATH': '$root/qq-device.json',
      'RHINE_KUGOU_DEVICE_STATE_PATH': '$root/kugou-device.json',
      'RHINE_KUGOU_EDITION': edition,
    };
    for (final MapEntry<String, String> entry in extraEnv.entries) {
      environment.putIfAbsent(entry.key, () => entry.value);
    }

    // Qt:207-211：{type, session, script, stderrLog, env} 五键键集逐字一致（env 的值见 D1）。
    _link.send(<String, Object?>{
      EngineWire.type: EngineWire.start,
      EngineWire.session: session,
      EngineWire.script: '$root/MusicBridge/worker.cjs',
      EngineWire.stderrLog: true,
      EngineWire.env: environment,
    });

    // Qt:213-217：singleShot(30000)，只在「会话未变且仍在 Starting」时 kill（守卫逐字保留）。
    _startTimer = Timer(startTimeout, () {
      if (_session == session && _state == EngineProcessState.starting) {
        kill();
      }
    });
  }

  /// Qt/src/BridgeProcessAndroid.cpp:219-222：无状态守卫；session 已清空时 Qt 序列化为空字符串。
  void write(Uint8List bytes) {
    _link.send(<String, Object?>{
      EngineWire.type: EngineWire.input,
      EngineWire.session: _session ?? '',
      EngineWire.data: base64Encode(bytes),
    });
  }

  /// Qt/src/BridgeProcessAndroid.cpp:223-225：return std::exchange(m_output, {}); 取走即清空。
  Uint8List readAllStandardOutput() => _output.takeBytes();

  /// Qt/src/BridgeProcessAndroid.cpp:226-235：幂等；发 stop → notRunning → 清 session/output → emit finished。
  /// error 与 Qt 的 m_error 一样不在此重置（Qt:226-235 只清 m_session/m_output）。
  void kill() {
    _startTimer?.cancel();
    _startTimer = null;
    if (_state == EngineProcessState.notRunning) {
      return;
    }
    _link.send(<String, Object?>{
      EngineWire.type: EngineWire.stop,
      EngineWire.session: _session ?? '',
    });
    _state = EngineProcessState.notRunning;
    _session = null;
    _output.clear();
    _finishedController.add(null);
  }

  /// Qt/src/BridgeProcessAndroid.cpp:236-238：terminate() { kill(); }。
  void terminate() => kill();

  /// Qt/src/BridgeProcessAndroid.cpp:239-241：空实现。worker 退出统一走 stop 帧，
  /// 绝不关闭共享运行时传输连接（该连接跨会话复用）。
  void closeWriteChannel() {}

  /// Qt/src/BridgeProcessAndroid.cpp:242-245：忽略参数，非阻塞返回 m_state == NotRunning。
  bool waitForFinished(int ms) {
    // Qt 里该参数被完全忽略（仅作签名兼容），此处保持同样的非阻塞语义。
    return _state == EngineProcessState.notRunning;
  }

  /// Qt/src/BridgeProcessAndroid.cpp:246-281 的 accept()，分派顺序逐条对应。
  void _handleMessage(Map<String, Object?> message) {
    final Object? type = message[EngineWire.type];

    // Qt:248-253 stderr 先于会话过滤（不改 output、不看 state）。
    if (type == EngineWire.stderr) {
      final Object? raw = message[EngineWire.data];
      // Qt 对 data 调 toString() 再宽容解码（数字会变成 "123"）；本层按契约 rules 1 做类型拒绝：
      // 非 String 的 data 属于非法帧，直接丢弃、不产生日志噪声。
      if (raw is! String) {
        return;
      }
      _log?.call(_decodeStderr(raw));
      return;
    }

    // Qt:254-260 runtime-error 同样先于会话过滤（launch 失败路径），映射 FailedToStart；
    // 不清 m_session/m_output（Qt:254-260 只改 m_error/m_state）。
    if (type == EngineWire.runtimeError) {
      _error = EngineProcessError.failedToStart;
      _state = EngineProcessState.notRunning;
      _errorController.add(EngineProcessError.failedToStart);
      _finishedController.add(null);
      return;
    }

    // Qt:261 if (m_state == NotRunning || message["session"].toString() != m_session) return;
    // 丢弃发生在任何 base64 解码之前；非 String 的 session 永不等于当前会话字符串。
    if (_state == EngineProcessState.notRunning ||
        message[EngineWire.session] != _session) {
      return;
    }

    // Qt:264-266 started → Running + emit started()。
    if (type == EngineWire.started) {
      _state = EngineProcessState.running;
      _startedController.add(null);
      return;
    }

    // Qt:267-269 output → m_output += fromBase64(data) + emit readyReadStandardOutput。
    if (type == EngineWire.output) {
      final Object? raw = message[EngineWire.data];
      if (raw is! String) {
        return; // 非法 data（非 String）：拒绝（契约 rules 1），不改变状态。
      }
      final Uint8List decoded;
      try {
        decoded = base64Decode(raw);
      } on FormatException {
        return; // 非法 base64：拒绝，不抛异常到调用方。
      }
      _output.add(decoded);
      _outputController.add(decoded);
      return;
    }

    // Qt:270-280 error / finished → Crashed + NotRunning + emit finished()（不 emit errorOccurred）。
    // Qt 的记录顺序是 if (contains("detail")) ... else if (contains("exitCode")) ...，
    // 且两个字段都用 toString()：此处按契约 rules 1 做字段级拒绝——detail 必须是 String、
    // exitCode 必须是 int 才记日志；字段类型非法时静默不记，但崩溃迁移照旧无条件发生（Qt:277-279）。
    if (type == EngineWire.error || type == EngineWire.finished) {
      if (message.containsKey(EngineWire.detail)) {
        final Object? detail = message[EngineWire.detail];
        if (detail is String) {
          _log?.call(detail);
        }
      } else if (message.containsKey(EngineWire.exitCode)) {
        final Object? exitCode = message[EngineWire.exitCode];
        if (exitCode is int) {
          _log?.call(exitCode.toString());
        }
      }
      _error = EngineProcessError.crashed;
      _state = EngineProcessState.notRunning;
      _finishedController.add(null);
      return;
    }

    // v1.1（Android 权威修正）：system-trust 不享受任何会话豁免。
    // Qt/src/BridgeProcessAndroid.cpp:92-93 的 read() 没有 system-trust 分支，帧进入 accept()，
    // 会话匹配后也无匹配分支（:264-280 只认 started/output/error/finished）→ 静默丢弃、绝不回包。
    // Qt/src/BridgeProcessIOS.cpp:70-78 的 evaluateIOSServerTrust + system-trust-result 在 Android 上不存在。
    if (type == EngineWire.systemTrust ||
        type == EngineWire.systemTrustResult) {
      return;
    }

    // 其余未知 type：会话通过后同样无匹配分支 → 静默丢弃。
  }

  /// 近似 QByteArray::fromBase64(...).trimmed()：Qt 宽容解码，本层严格解码并在失败时回退
  /// 原文（D6）；两条路径都不回抛给调用方。
  static String _decodeStderr(String raw) {
    try {
      return utf8.decode(base64Decode(raw), allowMalformed: true).trim();
    } on FormatException {
      return raw.trim();
    }
  }

  /// Qt/src/BridgeProcessAndroid.cpp:184 的 QUuid::createUuid().toString(QUuid::WithoutBraces)。
  ///
  /// 冻结 imports 只有 dart:async / dart:convert / dart:typed_data（无 dart:math），
  /// 因此不能用 Random；这里用「微秒时钟 + 进程内单调序号 + 实例身份哈希」经 4 个 32 位
  /// 混淆通路扩散成 128 位，再按 UUIDv4 布局（版本位 0100、变体位 10）输出小写 8-4-4-4-12，无花括号。
  /// 诚实声明：它是进程内唯一且不可预测性有限，不是密码学 CSPRNG；会话 id 只在已认证的
  /// 回环控制连接上出现（token 握手由 node_runtime.dart 负责），因此满足需求。
  String _newSessionId() {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    final int sequence = ++_sessionSequence;
    final int identity = identityHashCode(this);
    final int lane0 = _spread(micros);
    int lane1 = _spread((micros >>> 32) ^ (sequence * 0x9E3779B1) ^ identity);
    int lane2 = _spread(identity ^ (sequence * 0x85EBCA6B) ^ micros);
    final int lane3 = _spread(micros ^ (sequence << 17) ^ (identity << 3));
    // UUIDv4 的版本位必须落在第 3 组的首位（= h1[4]，即位 15..12），
    // 因为输出分组是 h1[0:4] | h1[4:8]，段 3 = h1.substring(4)。
    lane1 = (lane1 & 0xFFFF0FFF) | 0x00004000;
    lane2 = (lane2 & 0x3FFFFFFF) | 0x80000000;
    final String h0 = _hex32(lane0);
    final String h1 = _hex32(lane1);
    final String h2 = _hex32(lane2);
    final String h3 = _hex32(lane3);
    return '$h0-${h1.substring(0, 4)}-${h1.substring(4)}-'
        '${h2.substring(0, 4)}-${h2.substring(4)}$h3';
  }

  /// 32 位雪崩混淆（全部中间值 < 2^32，避免 64 位溢出与平台差异）。
  static int _spread(int value) {
    int x = value & 0xFFFFFFFF;
    x = (x ^ (x >>> 15)) & 0xFFFFFFFF;
    x = (x * 0x2545F491) & 0xFFFFFFFF;
    x = (x ^ (x >>> 13)) & 0xFFFFFFFF;
    x = (x * 0x45D9F3B) & 0xFFFFFFFF;
    x = (x ^ (x >>> 16)) & 0xFFFFFFFF;
    return x;
  }

  static String _hex32(int value) =>
      (value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
