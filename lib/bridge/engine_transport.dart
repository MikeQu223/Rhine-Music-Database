// T21-C19-W1 · lib/bridge/engine_transport.dart
//
// 计划卡：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:524-531（T21 引擎传输与 Node 生命周期）
// 唯一行为权威：Qt/src/BridgeProcessAndroid.cpp:171-281（会话状态机）+ Qt/src/BridgeProcess.h:13-46（状态/错误/信号）
// 协议对端：MusicBridge/ios-runtime.cjs（output/stderr/started/error/finished 的真实发出者）
// 协议对照（只对照、绝不移植）：Qt/src/BridgeProcessIOS.cpp:70-78（iOS 的 system-trust 通道）
// 冻结契约：reports/T21-C14-CONTRACT.json frozenApi["engine_transport.dart"]（签名逐条对齐）
//
// 接管说明（T21-C19-W1）：复用 T21-C14-W2 草稿，逐条对照冻结契约与 Qt 源后做最小修正，未重写模块结构。
//
// 复用源（只读，最小修复后内联，未整份搬运文件本体）：
//   sourceSha = 2cb83d1ac48c09286e911b691f6a31c39c0a1a4a
//   lib/bootstrap/bridge_frame_decoder.dart
//   保留：会话过滤先于 base64 解码 / base64 数据帧解码 / 类型分派 / 非法 data（非 String、
//        非法 base64）与非法 detail/exitCode 的拒绝语义。
//   删除（属 lib/bridge/node_runtime.dart 职责）：0x0a 字节分帧、48MiB 单帧上限、首帧 {token}
//        握手与认证、terminal/abort/排队缓冲、BridgeFrame* 帧类型体系；本层不按行切分 NDJSON。
//
// 本层边界（契约 rules 2）：不开 socket、不生成 token、不做 0x0a 分帧、不管 48MiB 上限与握手排队；
// 这些由 node_runtime.dart 通过 EngineRuntimeLink（send / messages / isLive）承担。
// 本文件定义 EngineRuntimeLink，node_runtime.dart 反向 import 本文件；本文件绝不 import node_runtime.dart（避免环）。
//
// error 初值：Qt/src/BridgeProcess.h:43 把 m_error 初始化为 UnknownError，frozenApi 也写作
//   「EngineProcessError get error;」（非空）。本实现逐字对齐：未出错时是 unknownError，不是 null。
//
// 与 Qt 源的可观测差异（全部有据，逐条列在下方与 reports/T21-C19-W1.json）：
//   D1 环境路径是近似值，不是 Qt 真值：Qt:194-200 的 TMPDIR 取 QStandardPaths::CacheLocation
//      （空则 AppStorage::temporaryDirectory()），Qt:204-205 的两个 device-state 取
//      AppStorage::dataDirectory()/qq-device.json|kugou-device.json；Qt:182 明确 Q_UNUSED(temporary)。
//      Flutter 侧没有 AppStorage 单例，冻结签名（root/temporary/edition）也没有 data/cache 注入缝，
//      故本层只能用 temporary 近似 TMPDIR、用 root 近似 dataDirectory。完整 gap 见报告 exactGap。
//   D2 extraEnv 只能追加、不得覆盖 Qt 的四键：Qt:202-206 的四个环境变量是权威值（临时目录/设备态/版本），
//      契约 rules 10 要求 env 恰为这四键；extraEnv 是契约签名给出的扩展缝，故采用「Qt 键优先」。
//   D3 kill() 与 start() 会取消上一次的 30s 定时器：Qt:213-217 只依赖 m_session/m_state 自守卫、从不取消。
//      取消不可观测——被取消的定时器在 Qt 语义下必然守卫失败（对应会话已被换掉或已 notRunning）；
//      而 Dart 侧留下悬挂 Timer 会让 flutter_test 判 pending timer 失败。守卫条件仍逐字保留作第二道防线。
//   D4 start() 不检查 link.isLive：Qt:186-189 只有在 runtime().launch(root) 失败时才合成 runtime-error，
//      而 isLive 等价「未退出且已连接」，launch 成功但未连接时 Qt 照样往下走（start 帧进握手队列由
//      node_runtime 承担）。故本层不因 isLive 提前失败，launch 失败以入站 runtime-error 帧体现。
//   D5 stderr 日志只记正文：Qt:248-253 写 logcat 时带 "node worker:" 前缀（呈现层），本层把正文交给 log 回调。
//   D6 stderr 的 base64 解码用严格 base64Decode，失败时回退原文：Qt 的 QByteArray::fromBase64 是宽容解码
//      （忽略非法字符）。两者都绝不抛异常到调用方，且 stderr 只用于日志、不影响状态机。
//
// RED/GREEN 未执行：本卡禁止 flutter test / dart test / analyze / 设备执行（见 CONTRACT.notExecuted）。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 原生侧（Android NodeRuntimeHost / 桌面宿主）单条回环控制连接的 Dart 侧抽象。
///
/// 由 lib/bridge/node_runtime.dart 的 NodeRuntimeEngineLink 实现；本层只通过它与线路交互：
///   * 发送 send：发出一个线路帧（实现负责 compact JSON + 0x0a 定界、握手排队、48MiB 上限）；
///   * 订阅 messages：入站帧流；
///   * 读取 isLive：共享传输连接是否仍可用（等价 Qt NodeRuntime 的「未退出且已连接」）。
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

  /// 宿主侧合成的崩溃回传（非 ios-runtime.cjs 发出；Qt:186-189 的 launch 失败路径）。
  static const String runtimeError = 'runtime-error';

  /// Qt 线路定界符；本层不做字节分帧，常量仅为契约一致性与 node_runtime 复用。
  static const int delimiter = 0x0a;
}

/// Qt BridgeProcess 会话半部分的 1:1 移植（Qt/src/BridgeProcessAndroid.cpp:171-281）。
///
/// 一个实例对应 Qt 侧一个 BridgeProcess 对象：kill 后可再次 start，共享同一进程级 runtime 连接。
final class EngineTransport {
  /// [log] 对应 Qt 的 logcat 输出（stderr 正文与 error.detail / finished.exitCode）。
  EngineTransport({
    required EngineRuntimeLink link,
    void Function(String)? log,
  })  : _link = link,
        _log = log {
    // 订阅在构造期建立且刻意永不取消：Qt 的 BridgeProcess 跨会话复用同一 runtime 连接
    // （Qt/src/Host.cpp:346-356），冻结 API 也没有 dispose()。
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

  /// 当前会话标识；notRunning 后为 null（等价 m_session.clear()）。
  String? get session => _session;

  EngineProcessState get state => _state;

  /// Qt/src/BridgeProcess.h:43 的 m_error 初值 UnknownError；frozenApi 为非空 getter。
  EngineProcessError get error => _error;

  Stream<void> get started => _startedController.stream;

  Stream<Uint8List> get output => _outputController.stream;

  Stream<EngineProcessError> get errorOccurred => _errorController.stream;

  Stream<void> get finished => _finishedController.stream;

  /// Qt/src/BridgeProcessAndroid.cpp:179-218 的会话启动半部分。
  ///
  /// 与 Qt 的差异：link 负责 launch（见文件头 D4），本层只发 start 帧并管理状态机。
  void start({
    required String root,
    required String temporary,
    required String edition,
    Map<String, String> extraEnv = const <String, String>{},
  }) {
    _startTimer?.cancel();
    _startTimer = null;

    // Qt:183-184：先置 Starting、再分配新会话（不清理旧的 output/error，与 Qt 一致）。
    final String session = _newSessionId();
    _session = session;
    _state = EngineProcessState.starting;

    // Qt:202-206：env 四键。TMPDIR 与两个 device-state 是 D1 近似值（Qt 真值分别是
    // CacheLocation 与 AppStorage::dataDirectory()），键名与键数才与 Qt 逐字一致。
    // Qt 键先写入，extraEnv 只允许追加新键，绝不覆盖（文件头 D2 / 契约 rules 10）。
    final Map<String, Object?> environment = <String, Object?>{
      'TMPDIR': temporary,
      'RHINE_QQ_DEVICE_STATE_PATH': '$root/qq-device.json',
      'RHINE_KUGOU_DEVICE_STATE_PATH': '$root/kugou-device.json',
      'RHINE_KUGOU_EDITION': edition,
    };
    for (final MapEntry<String, String> entry in extraEnv.entries) {
      environment.putIfAbsent(entry.key, () => entry.value);
    }

    // Qt:207-211：{type, session, script, stderrLog, env} 五键，逐字一致。
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

  /// 等价 QByteArray::fromBase64(...).trimmed()：非法 base64 不回抛给调用方。
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
