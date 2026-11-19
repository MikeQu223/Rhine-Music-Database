/// 引擎传输 · Node 运行时宿主端口
/// （Android 分支 1:1）。
///
/// 计划卡：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:524-531（
/// 「引擎传输与 Node 生命周期」）。
/// 唯一权威源：Qt/src/BridgeProcessAndroid.cpp（281 行；Android 的 libnode.so 只导出
/// node::Start(int, char**)，没有 iOS 的 C 包装 node_start —— 见该文件 :19-24）。
/// 同协议对照：Qt/src/BridgeProcess.h:13-46（ProcessState/ProcessError 与四个信号）、
/// Qt/src/BridgeProcessIOS.cpp:20-130（iOS 多一条 system-trust 通道；本文件不得把
/// Security.framework 分支带进 Android 路径）。
/// 协议对端：MusicBridge/ios-runtime.cjs（:7 argv[2]=port、:16 首帧 {token}、
/// :21 setInterval(60000) 保活）。
///
/// 复用源（只读；最小修复后内联，未整份搬运，只搬 0x0a 分帧 / 48 MiB / 握手排队 /
/// 候选销毁 / 常量时间比较这几处机制）：
/// sourceSha = 2cb83d1ac48c09286e911b691f6a31c39c0a1a4a
/// lib/bootstrap/node_host_bridge_channel.dart（回环绑定 :400-403、候选销毁 :476-498、
/// 握手排队与 flush :559-591/:938-953、常量时间令牌比较 :1198-1207）。
/// 差异（逐条，便于独立审查）：
///   1. 宿主端口由 MethodChannel（node_host_platform.dart / NodeHost.kt，未随本树携带）
///      改为冻结契约的 NodeRuntimeHost：这里不裁决「JNI 内嵌 Node」还是「Qt 宿主」，
///      所以本文件只描述 argv/栈/端口，绝不自己起 native 线程、绝不写 JNI/CMake/gradle/
///      MainActivity。
///   2. token 在实例构造时生成一次（BridgeProcessAndroid.cpp:47 是成员初值 QUuid::createUuid()，
///      进程级而不是每会话；每会话 id 在 BridgeProcessAndroid.cpp:184）。
///   3. 只允许一个控制连接：第二个候选直接销毁（Qt:55-60）；复用源是有界多候选。
///   4. 越界判据回到 Qt:73 的「整个读缓冲」而不是复用源的「单帧」（engine_transport.dart
///      侧仍按单帧，两者刻意不同）。
///   5. 会话过滤、base64 还原、start/input/stop 组装不在本文件（属 engine_transport.dart）；
///      本文件只做「字节 → 帧」与「帧 → 字节」以及握手。
///   6. 读缓冲用 Uint8List 线性队列而不是 List<int>：48 MiB 的越界帧会在 List<int> 里
///      膨胀成数亿字节的对象图，而 Qt 的 QByteArray 是连续字节。
///
/// 已知限制（冻结接口决定）：NodeRuntimeHost 没有事件流，所以
/// 「成功启动之后」宿主才发现的运行时退出，只能经控制连接断开（Qt:63-67 的等价路径）
/// 或下一次 launch 的 prepare() 反馈被感知。
///
/// 契约文本 / 行为细节的其余差异（接上面 1-6 编号；供独立审查逐条核对，冲突处以 Qt 源为准）：
///   7. import 基线之外多一个 dart:math：令牌是回环端口上唯一的认证凭据（Qt:47
///      QUuid::createUuid 走 QRandomGenerator::system()，是 CSPRNG），所以这里必须用
///      Random.secure() 而不是时钟/序号派生。契约的 imports 是基线集合，此处为唯一例外，
///      已在  报告 deviations[0] 登记。
///   8. 读缓冲与出站队列用「起始游标 + 结束游标」的 _ByteQueue，而不是原地 setRange
///      位移：Qt 的 QByteArray::remove(0, n) 是 memmove 语义，Dart 的
///      Uint8List.setRange 在源/目标同缓冲时未在语言规范里承诺重叠安全，48 MiB 级别的
///      位移一旦实现成前向拷贝就会静默破坏数据。游标版 consume 是 O(1) 且无重叠假设。
///   9. runtime-error 的去重只在**单次会话内**生效（会话 = 一次真实 launch 尝试，或一次被
///      接受的控制连接，见 _failureSession/_failureEmittedSession）。Qt 没有一次性标志：
///      BridgeProcessAndroid.cpp:63-67 每次 disconnected 都 accept(runtime-error)，:186-189
///      每次 start() 失败都再合成一次。本实现只合并「同一个失败被通知两次」这种 Dart 侧特有形
///      情形（_abortConnection 先显式走一遍失败路径，随后 socket 的 onDone 又回调一次），
///      跨会话绝不抑制：启动失败之后重新 launch 成功的断链、以及每次独立的启动尝试，都各自
///      上报。仍然保留的差异只有一条——launch 在 launched 之后只回报状态、不重复上报
///      （等价 「旋转不重复启动」，避免 UI 收到重复崩溃通知）。
///   10. send/flush 对已 abort 的 socket 做 try/catch：Qt 的 socket->write() 在已断开的
///      QTcpSocket 上静默返回 -1，而 Dart 的 Socket.add 在销毁后会抛 StateError；
///      为保持「认证后写失败不崩溃调用方」这一 Qt 行为，这里吞掉该异常。
///   11. launch 失败收监听器只发生在「尚未置 launched」的路径上。Qt:102-105 的两种失败
///      本来就没有监听，而 Qt:120-125 的 pthread_create 失败在 Qt:106 launched = true
///      之后，Qt 并未 server.close()，QTcpServer 仍在监听；这里对齐后者。
///
/// 本文件的 Qt 证据行：:47 token、:52-69 构造/单连接/断链回传、:71-96 读取与握手、
/// :98-128 launch 幂等 + 8 MiB 栈 + argv 生命周期、:130-138 出站与握手排队、
/// :152-159 node::Start 返回 → exited → runtime-error。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'engine_transport.dart';

/// 正常 shutdown 时等待套接字优雅关闭的上限（复用源的 shutdownTimeout 默认 5s）。
const Duration _shutdownSocketTimeout = Duration(seconds: 5);

/// 宿主报告运行时终态时使用的 reason 取值（沿用旧平台宿主 NodeHost.kt 的终态码命名，
/// 语义等于 Qt:153 的 runtime->exited = true：node::Start 已经返回）。
const String _hostReasonRuntimeExited = 'runtime_exited';

/// 宿主侧 Node 启动请求。
///
/// [argv] 必须由宿主保存到运行时结束（Qt:110-113 把 argv 缓冲挂在堆上的
/// NodeThreadStart 里，就是为了让它活过 node::Start 全程，不能是 launch 的局部变量）。
final class NodeRuntimeStartSpec {
  const NodeRuntimeStartSpec({required this.argv, required this.stackBytes});

  /// node::Start 的参数：["node", "<root>/MusicBridge/ios-runtime.cjs", "<port>", "<token>"]
  /// （Qt:107-113；ios-runtime.cjs:7/:16 读 argv[2]=port、argv[3]=token）。
  final List<String> argv;

  /// 线程栈字节数；8 MiB（Qt:118 pthread_attr_setstacksize）由宿主施加。
  final int stackBytes;

  @override
  String toString() => 'NodeRuntimeStartSpec(argv: <${argv.length} 项>, stackBytes: $stackBytes)';
}

/// 宿主对 Node 运行时的准备状态（[NodeRuntimeHost.prepare] 的返回）。
final class NodeRuntimeHostStatus {
  const NodeRuntimeHostStatus({required this.prepared, this.root, this.reason});

  /// 宿主是否已把 Node 运行时准备好（可执行 so / 脚本 root / argv 缓冲区）。
  final bool prepared;

  /// 宿主侧的运行时根目录；仅供宿主与诊断使用，本文件只使用调用者传入的 root
  /// （Qt:102 的路径拼接是调用者的 root + "/MusicBridge/ios-runtime.cjs"）。
  final String? root;

  /// 未就绪原因，或宿主报告的运行时终态（终态时用 _hostReasonRuntimeExited）。
  final String? reason;
}

/// 宿主端口：Node 运行时的准备、启动与释放。
///
/// 这里不裁决宿主形态，因此这里只定义 port；不出现任何 JNI/CMake/
/// Gradle/MainActivity 相关内容。
abstract interface class NodeRuntimeHost {
  /// 幂等准备；失败以 [NodeRuntimeHostStatus.prepared] == false 表达，不抛异常。
  Future<NodeRuntimeHostStatus> prepare();

  /// 让宿主启动 Node 运行时；必须让 [NodeRuntimeStartSpec.argv] 活过运行时全程。
  void startRuntime(NodeRuntimeStartSpec spec);

  /// 释放宿主侧资源（不重启运行时）。
  Future<void> dispose();
}

/// 宿主 ↔ Node 运行时之间的线格式常量。
///
/// 出站与入站共用一套字段名（改一处就静默断链）：出站 token/type/session/data/
/// script/env/stderrLog（BridgeProcessAndroid.cpp:184-243 与 ios-runtime.cjs:57-76），
/// 入站 type/session/data/detail/exitCode（iOS 侧同名，见 BridgeProcessIOS.cpp:70-77）。
abstract final class NodeWire {
  // —— 出站字段（Qt/js → runtime）
  static const String token = 'token';
  static const String type = 'type';
  static const String session = 'session';
  static const String data = 'data';
  static const String script = 'script';
  static const String env = 'env';
  static const String stderrLog = 'stderrLog';

  // —— 入站字段（runtime → Qt/js）
  static const String detail = 'detail';
  static const String exitCode = 'exitCode';

  // —— 消息类型
  static const String start = 'start';
  static const String input = 'input';
  static const String stop = 'stop';
  static const String systemTrustResult = 'system-trust-result';

  static const String started = 'started';
  static const String output = 'output';
  static const String stderr = 'stderr';
  static const String error = 'error';
  static const String finished = 'finished';
  static const String systemTrust = 'system-trust';

  /// 宿主合成的失败通知（不是 ios-runtime.cjs 发出的；Qt 用
  /// accept({{"type","runtime-error"}}) 在断链/硬崩溃/未启动时上报，
  /// 见 BridgeProcessAndroid.cpp:66、:157、:186-189）。
  static const String runtimeError = 'runtime-error';

  /// 帧分隔符：换行（Qt:78 input.indexOf('\n')；ios-runtime.cjs:12-14 JSON + 换行）。
  static const int delimiter = 0x0a;

  /// 未结束读缓冲的上限：48 * 1024 * 1024（Qt:73 整个 input 越界即 abort）。
  static const int maxFrameBytes = 48 * 1024 * 1024;

  /// Node 线程栈：8 * 1024 * 1024（Qt:118 pthread_attr_setstacksize）。
  static const int runtimeStackBytes = 8 * 1024 * 1024;
}

/// 进程级 Node 运行时控制器（等价 Qt:164-168 的
/// static auto instance = new NodeRuntime; return *instance;）。
///
/// 生命周期：宿主先 [NodeRuntimeHost.prepare]，本类再绑回环端口、把 argv 交给
/// [NodeRuntimeHost.startRuntime]，然后等运行时用首帧 {token} 完成认证。认证前
/// [send] 只排队，认证后一次性 flush（Qt:81-91）。任何读缓冲越界、令牌不匹配、
/// 套接字断开或宿主报告运行时不在了，都发一次 runtime-error（Qt:63-67/:75/:84/:157）；
/// 去重只在单次会话内（见文件头差异 9），跨会话一律重新上报。
final class NodeRuntime {
  NodeRuntime._({int maxFrameBytes = NodeWire.maxFrameBytes})
      : assert(maxFrameBytes > 0 && maxFrameBytes <= NodeWire.maxFrameBytes),
        _maxFrameBytes = maxFrameBytes,
        _token = _generateToken();

  /// 进程级单例：一个进程只初始化一次 Node（Qt:35-39 注释）。
  static final NodeRuntime instance = NodeRuntime._();

  /// 隔离实例，仅供单元测试使用（生产链路只有 [instance]，接线见
  /// [NodeRuntimeEngineLink]）。
  ///
  /// 冻结契约之外的唯一附加面：单例一旦 launched/authenticated 就无法复位，而一个
  /// 测试进程里要覆盖多个用例（幂等、拒连、越界、握手排队……），必须能拿到干净实例。
  /// [maxFrameBytes] 只允许调小（便于在测试里用小上限复现越界），上限本身仍是
  /// [NodeWire.maxFrameBytes]。
  static NodeRuntime createIsolatedForTest({int maxFrameBytes = NodeWire.maxFrameBytes}) =>
      NodeRuntime._(maxFrameBytes: maxFrameBytes);

  final int _maxFrameBytes;
  final String _token;

  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<void> _runtimeFailed = StreamController<void>.broadcast();

  /// Qt:45 的 input（收到但还没切出完整帧的字节）。
  final _ByteQueue _input = _ByteQueue();

  /// Qt:46 的 queued（认证前攒下的出站字节）。
  final _ByteQueue _queued = _ByteQueue();

  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSubscription;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSubscription;
  NodeRuntimeHost? _host;
  Future<bool>? _launchFuture;

  int _port = 0;
  bool _launched = false;
  bool _authenticated = false;
  bool _exited = false;
  bool _unavailable = false;
  bool _shutdown = false;
  bool _socketLive = false;

  /// runtime-error 去重的会话号（文件头差异 9）：断链、读缓冲越界、令牌不匹配、
  /// 读监听错误、launch 失败都汇流到 [_reportRuntimeFailure]，同一会话内只上报一次。
  ///
  /// 会话推进点与 Qt 的真实状态点一一对应：真正开始一次 launch 尝试（Qt:186-189 每次
  /// start() 失败都单独合成一次 runtime-error），以及接受一个控制连接（Qt:63-67 每次
  /// disconnected 都单独 accept）。用会话号比较而不是进程级 bool，是为了让「启动失败 →
  /// 重新 launch 成功 → 断链」这条路径上的后续失败不会被前一次吞掉。
  int _failureSession = 0;

  /// 最近一次真正上报过 runtime-error 的会话号；null 表示本实例尚未上报。
  int? _failureEmittedSession;

  /// 进程级随机令牌（Qt:47 QUuid::createUuid().toString(WithoutBraces)）。
  /// 小写 UUIDv4、带连字符、无花括号；不含逗号/空格/引号，因为要作为 argv 的一项
  /// 穿过宿主（Qt:113）并在首帧里回传（ios-runtime.cjs:16）。
  String get token => _token;

  /// 回环控制端口；尚未监听时为 0（Qt:108 server.serverPort() 的对应值）。
  int get port => _port;

  /// 是否已经交给宿主启动过（Qt:48 launched）。旋转/重建不重置它。
  bool get launched => _launched;

  /// 首帧令牌是否已通过（Qt:49 authenticated）。
  bool get authenticated => _authenticated;

  /// 运行时是否已终止（Qt:50 std::atomic<bool> exited：node::Start 返回，或宿主
  /// 报告 runtime_exited）。为 true 时本进程内不再启动（ 旋转不重复启动）。
  bool get exited => _exited;

  /// 读缓冲里还没切出完整帧的字节数（Qt:45 input.size() 的对应值）。
  int get pendingBytes => _input.length;

  /// Qt:99-100 的幂等判据：未退出、未关闭，且「还没有控制连接或连接仍然活着」。
  bool get isLive =>
      _launched && !_exited && !_shutdown && (_socket == null || _socketLive);

  /// 运行时 → 宿主的帧流（已认证之后；含宿主合成的 runtime-error）。
  Stream<Map<String, Object?>> get messages => _messages.stream;

  /// 运行时失败通知流（等价 Qt 的 accept({{"type","runtime-error"}})；
  /// 每个失败会话投递一次，同一会话内不重复，见文件头差异 9）。
  Stream<void> get runtimeFailed => _runtimeFailed.stream;

  /// 首次招标 + 幂等启动。
  ///
  /// 已 launched 时只回报「未退出且连接仍活」，绝不第二次启动 Node（Qt:99-100，
  /// 对应 「旋转不重复启动」与  的 Fail 条件「重复 node::Start」）。
  /// 并发调用共享同一次尝试，避免出现两条 Node 启动路径。
  Future<bool> launch(String root, NodeRuntimeHost host) {
    final Future<bool>? pending = _launchFuture;
    if (pending != null) {
      return pending;
    }
    final Future<bool> attempt = _launchOnce(root, host);
    _launchFuture = attempt;
    return attempt.whenComplete(() {
      if (identical(_launchFuture, attempt)) {
        _launchFuture = null;
      }
    });
  }

  Future<bool> _launchOnce(String root, NodeRuntimeHost host) async {
    if (_launched) {
      // Qt:99-100：不重新 prepare、不重新 bind、不重新 startRuntime。
      return isLive;
    }
    if (_exited || _unavailable || _shutdown) {
      // Qt 没有重启路径：运行时一旦终止（或宿主报告它不可用），本进程内不再启动。
      return false;
    }
    // 每次真实尝试都是新的失败会话：Qt:186-189 对每次失败的 start() 都重新合成一次
    // runtime-error，重试（补齐脚本、端口冲突后重来）因此不会被上一次失败吞掉。
    _beginFailureSession();
    try {
      final NodeRuntimeHostStatus status = await host.prepare();
      if (!status.prepared) {
        // 宿主报告运行时不可用/已退出（NodeRuntimeHost 没有事件流，这是唯一能拿到
        // 宿主侧终态的位置；成功启动之后的退出只能靠控制连接断开感知）。
        _unavailable = true;
        if (status.reason == _hostReasonRuntimeExited) {
          _exited = true;   // 等价 Qt:153 runtime->exited = true
        }
        _failLaunch();
        return false;
      }
      final String scriptPath = '$root/MusicBridge/ios-runtime.cjs'; // Qt:102
      if (!File(scriptPath).existsSync()) {
        _failLaunch();
        return false;
      }
      final ServerSocket server;
      try {
        // Qt:103：QHostAddress::LocalHost + 端口 0（系统分配）；Unix 上 LocalHost
        // 会同时绑 127.0.0.1 与 ::1，这里显式夹到 loopback IPv4。
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      } on Object {
        _failLaunch();
        return false;
      }
      if (_shutdown) {
        await server.close();
        return false;
      }
      _host = host;
      _server = server;
      _port = server.port;
      _serverSubscription = server.listen(_onCandidate, onError: _onServerError);
      // Qt:106：listen 成功后才置 launched（失败路径允许以后重试）。
      _launched = true;
      host.startRuntime(NodeRuntimeStartSpec(
        argv: List<String>.unmodifiable(<String>[
          'node',
          scriptPath,
          server.port.toString(),
          _token,
        ]),
        stackBytes: NodeWire.runtimeStackBytes,
      ));
      return true;
    } on Object {
      // launch 是宿主/引擎的边界：任何异常都退化成「启动失败」，绝不外抛。
      _failLaunch();
      return false;
    }
  }

  /// 组织一帧出站消息（Qt:130-131 QJsonDocument::Compact + 换行）。
  void send(Map<String, Object?> message) {
    if (_shutdown) {
      return;
    }
    final Uint8List payload = utf8.encode(jsonEncode(message));
    final Uint8List frame = Uint8List(payload.length + 1);
    frame.setRange(0, payload.length, payload);
    frame[payload.length] = NodeWire.delimiter;
    if (_authenticated) {
      _write(frame);
    } else {
      // Qt:134-137：认证前只攒字节，认证成功后一次性写出。
      _queued.append(frame);
    }
  }

  /// 正常关闭：停监听、断连接、释放宿主；不重启、不伪造 runtime-error。
  Future<void> shutdown() async {
    if (_shutdown) {
      return;
    }
    _shutdown = true;
    await _closeListener();
    final Socket? socket = _socket;
    _socket = null;
    final StreamSubscription<Uint8List>? subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    _socketLive = false;
    _queued.clear();
    if (socket != null) {
      try {
        await socket.close().timeout(_shutdownSocketTimeout);
      } on Object {
        socket.destroy();
      }
    }
    final NodeRuntimeHost? host = _host;
    _host = null;
    await host?.dispose();
    // 不重置 _launched/_exited：Qt 没有 shutdown，运行时在本进程内不重启。
    // 也不关闭两个 StreamController：Qt 的运行时是永不释放的进程级对象（Qt:164-168）。
  }

  // —— Qt:52-69 构造期回调 ——

  void _onCandidate(Socket candidate) {
    if (_shutdown || _socket != null) {
      // Qt:55-60：只允许一个控制连接。回环端口对本机其它进程可见，所以不猜谁是
      // 本进程的运行时，多余的候选直接 abort。注意与 Qt 一致：一旦给 _socket 赋过
      // 值，即使该连接后来被 abort，后续候选也一律销毁（不重新接管）。
      candidate.destroy();
      return;
    }
    _socket = candidate;
    _socketLive = true;
    // 新控制连接 = 新失败会话：Qt:63-67 对每次 disconnected 都 accept(runtime-error)，
    // 不看此前是否上报过（例如 launch 已置位后宿主 startRuntime 才抛错的那次失败，
    // 之后该连接的断开仍必须上报）。见文件头差异 9。
    _beginFailureSession();
    _socketSubscription = candidate.listen(
      _onSocketData,
      onError: (Object error, StackTrace stackTrace) => _onConnectionLost(),
      onDone: _onConnectionLost,
      cancelOnError: false,
    );
  }

  void _onServerError(Object error, StackTrace stackTrace) {
    // Qt 的 QTcpServer 在这个文件里没有错误处理（连接不上就等 BridgeProcess 30s 超时）；
    // Dart 侧把监听错误折进同一条失败路径：控制通道不可用 = runtime-error。
    if (_shutdown) {
      return;
    }
    _abortConnection();
  }

  // —— Qt:71-96 读取与握手 ——

  void _onSocketData(Uint8List chunk) {
    if (_shutdown || _socket == null) {
      return;
    }
    _input.append(chunk);
    // Qt:73-76：整个读缓冲（而不是单帧）超过 48 MiB 就 abort。
    if (_input.length > _maxFrameBytes) {
      _abortConnection();
      return;
    }
    int offset = 0;
    while (true) {
      final int newline = _input.indexOf(NodeWire.delimiter, offset);
      if (newline < 0) {
        break;
      }
      final Uint8List line = _input.view(offset, newline);
      offset = newline + 1;
      if (!_handleLine(line)) {
        break;
      }
    }
    if (offset > 0) {
      _input.consume(offset);
    }
  }

  /// 处理一条完整帧；返回 false 表示连接已被销毁，必须停止本轮解析。
  bool _handleLine(Uint8List line) {
    final Map<String, Object?>? message = _decodeMessage(line);
    if (!_authenticated) {
      // Qt:81-84：第一条消息必须带回本进程令牌，否则 abort（不做握手前的类型判断）。
      final Object? presented = message == null ? null : message[NodeWire.token];
      if (presented is! String || !_constantTimeEquals(presented, _token)) {
        _abortConnection();
        return false;
      }
      _authenticated = true;
      // Qt:88 server.close()：认证后不再接受任何新连接。
      unawaited(_closeListener());
      _flushQueued();
      return true;
    }
    if (message != null) {
      // Qt:92-93：node_runtime 只负责把帧交出去；类型分派与
      // 「session 不匹配就在解码前丢弃」都在 engine_transport.dart。
      if (!_messages.isClosed) {
        _messages.add(message);
      }
    }
    return true;
  }

  Map<String, Object?>? _decodeMessage(Uint8List bytes) {
    if (bytes.isEmpty) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      // Qt:79 用 QJsonDocument::fromJson 得到空对象：握手期必然 abort，认证后也会被
      // 会话过滤丢掉，结果与「丢弃」等价，因此这里直接判别为不可用消息。
      return null;
    }
    if (decoded is! Map) {
      return null;
    }
    final Map<String, Object?> message = <String, Object?>{};
    decoded.forEach((Object? key, Object? value) {
      message[key.toString()] = value;
    });
    return message;
  }

  // —— Qt:130-138 / :63-67 / :152-159 连接生命周期 ——

  void _flushQueued() {
    if (_queued.length > 0) {
      // Qt:90-91：认证成功后把排队字节一次性写出再清空（顺序即入队顺序）。
      _write(_queued.toBytes());
    }
    _queued.clear();
  }

  /// 对已断开的 socket 写字节：Qt 的 socket->write() 在 abort 之后静默返回 -1
  /// （文件头差异 D），Dart 的 Socket.add 会抛 StateError，这里对齐 Qt 的静默语义，
  /// 但只吞「写失败」——真正的断链仍由 onDone/onError 走 _onConnectionLost。
  void _write(Uint8List bytes) {
    final Socket? socket = _socket;
    if (socket == null) {
      return;
    }
    try {
      socket.add(bytes);
    } on Object {
      // 已 abort/销毁：等价 Qt 的 write() 返回 -1，不再向上抛。
    }
  }

  void _abortConnection() {
    // Qt:84/:75/:58 的 socket->abort()。Qt 里 abort 必然触发 disconnected 信号，
    // 所以这里先显式走一遍失败路径（保证单元测试不必等事件循环），随后 socket 的
    // onDone 还会回调同一次失败——由 _reportRuntimeFailure 在**同一会话内**合并成一次
    // （见文件头差异 9）。
    _onConnectionLost();
    _socket?.destroy();
  }

  void _onConnectionLost() {
    if (_shutdown) {
      // 主动 shutdown 是正常关闭，不得伪造崩溃（ios-runtime.cjs:18-20 也是
      // 「连接没了就静默」的策略）。
      return;
    }
    _socketLive = false;
    _reportRuntimeFailure();
  }

  void _failLaunch() {
    // 正常关闭之后不再发 runtimeFailed：shutdown 与一次在途的 prepare/bind 竞争时，迟到
    // 的失败描述的是「已经被关掉的运行时」，UI 不该看到伪崩溃（与 _onConnectionLost 的
    // _shutdown 守卫一致；Qt 没有 shutdown 路径，这是 Dart 侧的等价收口）。
    if (_shutdown) {
      return;
    }
    // Qt BridgeProcess::start:186-188：launch 返回 false 时立刻上报 runtime-error。
    // 监听器只在「还没置 launched」的失败路径上收掉：Qt:102-105 的失败根本没在监听，
    // 而 Qt:120-125 的 pthread_create 失败发生在 Qt:106 launched = true 之后，Qt 并没有
    // server.close()，QTcpServer 继续监听（文件头差异 11）。
    if (!_launched) {
      unawaited(_closeListener());
    }
    _reportRuntimeFailure();
  }

  /// 推进失败会话：一次真实的 launch 尝试，或一个被接受的控制连接。
  void _beginFailureSession() {
    _failureSession += 1;
  }

  /// 上报本会话的 runtime-error；同一会话的后续通知（abort 之后 onDone 再回调一次）
  /// 被丢弃。跨会话一定会重新上报，因此「启动失败 → 重新 launch 成功 → 断链」不会再被
  /// 前一次失败吞掉（Qt:63-67 每次断链都 accept，:186-189 每次 start() 失败都再合成）。
  void _reportRuntimeFailure() {
    if (_failureEmittedSession == _failureSession) {
      return;
    }
    _failureEmittedSession = _failureSession;
    _emitRuntimeFailed();
  }

  void _emitRuntimeFailed() {
    // 等价 accept({{"type", "runtime-error"}})（Qt:66、:157）；宿主合成的帧没有
    // session 字段，因此它会先于任何会话过滤被 engine_transport.dart 处理。
    if (!_messages.isClosed) {
      _messages.add(<String, Object?>{NodeWire.type: NodeWire.runtimeError});
    }
    if (!_runtimeFailed.isClosed) {
      _runtimeFailed.add(null);
    }
  }

  Future<void> _closeListener() async {
    final StreamSubscription<Socket>? subscription = _serverSubscription;
    _serverSubscription = null;
    final ServerSocket? server = _server;
    _server = null;
    await subscription?.cancel();
    await server?.close();
  }

  /// QUuid WithoutBraces 等价物：小写 UUIDv4（8-4-4-4-12），无花括号。
  ///
  /// 冻结契约的 import 列表里没有 dart:math；这里显式引入并用 Random.secure() 生成
  /// 128 位随机量（否则只能用时间戳，回环端口上的可猜令牌等于没有认证）。该偏差在实现说明中登记。
  /// 该偏差在实现说明中登记。
  static String _generateToken() {
    final Random random = Random.secure();
    final Uint8List bytes = Uint8List(16);
    for (int index = 0; index < bytes.length; index += 1) {
      bytes[index] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final StringBuffer buffer = StringBuffer();
    for (int index = 0; index < bytes.length; index += 1) {
      if (index == 4 || index == 6 || index == 8 || index == 10) {
        buffer.write('-');
      }
      buffer.write(bytes[index].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// 与复用源 :1198-1207 同策略：先比长度，再逐字符 XOR 或，不提前返回。
  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) {
      return false;
    }
    int accumulator = 0;
    for (int index = 0; index < left.length; index += 1) {
      accumulator |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return accumulator == 0;
  }
}

/// 线性字节队列：等价 Qt 的 QByteArray（input / queued）。
///
/// 用 Uint8List + 「起始游标 / 结束游标」而不是 List<int>：48 MiB 的读缓冲在 List<int>
/// 里会变成数亿字节的对象图，而 QByteArray 是连续字节。
///
/// 为什么是双游标而不是每次 consume 都原地位移（文件头差异 B）：Qt 的
/// QByteArray::remove(0, n) 是 memmove 语义，而 Dart 语言规范没有承诺
/// Uint8List.setRange 在源与目标是同一缓冲的重叠区间上按 memmove 拷贝——一旦实现成
/// 前向逐字节拷贝，48 MiB 级别的位移就会静默把数据写坏（且只在生产大数据下出现）。
/// 双游标让 consume 变成 O(1) 且完全不依赖重叠假设；只有真正需要容量时才整段搬到新
/// 缓冲（新旧对象不重叠）。副作用是消费后容量仍被持有，与 QByteArray 保留 capacity 一致。
final class _ByteQueue {
  Uint8List _bytes = Uint8List(0);

  /// 队首在 [_bytes] 中的偏移（已被 consume 掉的字节数为 _start）。
  int _start = 0;

  /// 队尾在 [_bytes] 中的偏移（不含）。
  int _end = 0;

  int get length => _end - _start;

  void append(List<int> chunk) {
    if (chunk.isEmpty) {
      return;
    }
    final int live = _end - _start;
    final int required = live + chunk.length;
    if (_end + chunk.length > _bytes.length) {
      int capacity = _bytes.isEmpty ? 256 : _bytes.length;
      while (capacity < required) {
        capacity *= 2;
      }
      final Uint8List grown = Uint8List(capacity);
      // 新缓冲与旧缓冲是不同对象，区间不重叠，setRange 语义无歧义。
      grown.setRange(0, live, _bytes, _start);
      _bytes = grown;
      _start = 0;
      _end = live;
    }
    _bytes.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// 从队首偏移 [from] 起查找 [value]，找不到返回 -1；返回的下标相对队首。
  int indexOf(int value, [int from = 0]) {
    int index = _start + from;
    if (index < _start) {
      index = _start; // from 为负时夹回队首（Qt 的 indexOf 不接受负起点）。
    }
    for (; index < _end; index += 1) {
      if (_bytes[index] == value) {
        return index - _start;
      }
    }
    return -1;
  }

  /// 队首 [start, end) 的视图；只允许在同一轮解析里立即消费，不能跨 append 持有
  /// （append 可能整体换缓冲，旧视图会指向被丢弃的 Uint8List）。
  Uint8List view(int start, int end) =>
      Uint8List.sublistView(_bytes, _start + start, _start + end);

  /// 丢弃队首 [count] 字节（O(1)：只挪游标）。
  void consume(int count) {
    if (count <= 0) {
      return;
    }
    if (count >= _end - _start) {
      _start = 0;
      _end = 0;
      return;
    }
    _start += count;
  }

  /// 队首内容的独立副本（写出后不再与本队列共享内存）。
  Uint8List toBytes() => Uint8List.fromList(
        Uint8List.sublistView(_bytes, _start, _end),
      );

  void clear() {
    _start = 0;
    _end = 0;
  }
}

/// 唯一接线适配器：把进程级 [NodeRuntime] 接给 engine_transport.dart 的
/// [EngineRuntimeLink]（避免为一行转发再开第三个文件）。
final class NodeRuntimeEngineLink implements EngineRuntimeLink {
  NodeRuntimeEngineLink({NodeRuntime? runtime}) : _runtime = runtime ?? NodeRuntime.instance;

  final NodeRuntime _runtime;

  @override
  void send(Map<String, Object?> message) {
    _runtime.send(message);
  }

  @override
  Stream<Map<String, Object?>> get messages => _runtime.messages;

  @override
  bool get isLive => _runtime.isLive;
}
