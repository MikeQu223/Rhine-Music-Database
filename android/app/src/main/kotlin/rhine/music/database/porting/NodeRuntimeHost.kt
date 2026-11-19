package rhine.music.database.porting

/**
 * 引擎传输 · Android 分支 Node 运行时宿主候选（条件性平台 port：只实现、不注册）。
 *
 * 这里不裁决「JNI 内嵌 libnode」还是「Qt 宿主」，因此只提供候选实现面。
 * [NodeRuntimeHostCandidate.prepare] 一律返回 prepared=false + ARCH_BLOCKED，
 * 不假装已接线。真正的栈设置、libnode.so 加载、`node::Start` 调用与 argv 构造/释放
 * 全部属于 native/JNI 层；[NodeRuntimeNativeStarter] 只声明这个接缝，本树没有实现，
 * 也没有任何注册。
 *
 * 关键契约（与 Qt/src/BridgeProcessAndroid.cpp 对齐）：
 *  - argv 是同一个可写缓冲区 "node\\0" + script + "\\0" + port + "\\0" + token + "\\0"，
 *    共 4 项，必须活过 node::Start 全程；
 *  - Android 原生 pthread 默认栈（约 1 MB）不够，必须设 8 MiB；
 *  - launch 幂等：已启动时只回报状态，绝不第二次 node::Start；
 *  - RUNTIME_EXITED 的 reason 字符串必须与 Dart 侧逐字节相同，否则 Dart 的
 *    `status.reason == 'runtime_exited'` 分支永远不成立；
 *  - NodeRuntime 方法全在 GUI 线程，唯一跨线程值是 std::atomic exited；
 *  - 宿主发现的运行时终态只能靠下一次 prepare 报告（端口没有事件流）。
 *
 * 路线裁决后接线方需补：JNI 实现（加载 libnode.so、解析 node::Start、构造连续可写
 * argv 缓冲、8 MiB 线程栈）、cpp/CMakeLists + externalNativeBuild、MethodChannel 与
 * MainActivity 注册、logcat 诊断。本文件不引 android.util.Log，保持纯 Kotlin 标准库。
 */
object NodeRuntimeHostLimits {
    /** argv 项数：Qt:113 的缓冲区里正好 4 段 NUL 分隔串；Qt:152 `node::Start(4, values)`。 */
    const val ARGV_LENGTH: Int = 4

    /** argv[0]：Qt:113 的字面量 "node"。 */
    const val PROGRAM: String = "node"

    /** argv[1] 后缀：Qt:102/:107 `root + "/MusicBridge/ios-runtime.cjs"`（Dart 的 NodeRuntime.launch 同）。 */
    const val SCRIPT_SUFFIX: String = "/MusicBridge/ios-runtime.cjs"

    /** argv[2] 端口下界：Qt:108 `QByteArray::number(server.serverPort())`，十进制、无符号。 */
    const val MIN_PORT: Int = 1

    /** argv[2] 端口上界：QTcpServer 的端口范围（Qt:103 listen 后由系统分配，Dart 侧 bind 端口 0）。 */
    const val MAX_PORT: Int = 65535

    /** 线程栈：Qt:118 `pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024)`；Dart 的 NodeWire.runtimeStackBytes 同值。 */
    const val STACK_BYTES: Int = 8 * 1024 * 1024

    /** NUL：Qt:113 用 '\\0' 分段，Qt:146-148 用 std::strlen 逐段走 → 参数里出现它就是缓冲撕裂。 */
    const val NUL: Char = '\u0000'
}

/**
 * 宿主端口的 reason 词表（对应 Dart [NodeRuntimeHostStatus.reason]）。
 *
 * 只有 [RUNTIME_EXITED] 是**冻结**值：它必须与 lib/bridge/node_runtime.dart 的
 * `_hostReasonRuntimeExited` 逐字节相同。其余都是本 port 的自检码，Qt 侧没有对应字符串。
 */
object NodeRuntimeHostReason {
    /**
     * node::Start 已经返回（Qt:152-153 `runtime->exited = true`）。
     *
     * 冻结：lib/bridge/node_runtime.dart 的 _hostReasonRuntimeExited（'runtime_exited'）。
     */
    const val RUNTIME_EXITED: String = "runtime_exited"

    /**
     * 这里未接线：没有 native 接缝（路线未裁决）。
     * 这是本树里 prepare() 唯一会返回的失败原因。
     */
    const val ARCH_BLOCKED: String = "arch_blocked"

    /**
     * 原生启动失败：Qt:122-125 `pthread_create != 0` → `delete start; return false`，
     * 再由 Qt:186-188 上报 runtime-error。对应 Dart 的 NodeRuntimeHostStatus(prepared=false)。
     */
    const val NATIVE_START_FAILED: String = "native_start_failed"

    /** 未 prepare 就 startRuntime：本 port 自检（Qt 的 launch 只有 launched 一个闸门，:99）。 */
    const val NOT_PREPARED: String = "not_prepared"

    /** 已经启动过：Qt:99-100 只回报状态、绝不第二次 `node::Start`。 */
    const val ALREADY_STARTED: String = "already_started"

    /** argv 布局不合 Qt:113/:152 的契约（长度/argv[0]/NUL/script 后缀/端口/令牌）。 */
    const val ARGV_INVALID: String = "argv_invalid"

    /** stackBytes 非正：Qt:118 的常量是 8 MiB，0 或负值没有任何 pthread 语义。 */
    const val STACK_BYTES_INVALID: String = "stack_bytes_invalid"

    /** 端口已 dispose：Dart 的 dispose 文档「释放宿主侧资源（不重启运行时）」，Qt 没有重启路径。 */
    const val DISPOSED: String = "disposed"
}

/**
 * 宿主对 Node 运行时的准备状态 = lib/bridge/node_runtime.dart 的 NodeRuntimeHostStatus 的 Kotlin 对应面。
 *
 * 字段语义逐字对齐 Dart：prepared（宿主是否已把运行时就绪）、root（宿主侧运行时根目录，
 * 仅供宿主与诊断使用，Dart 侧 root 字段 明确不使用它）、reason（未就绪原因，或运行时终态）。
 */
class NodeRuntimeHostStatus(
    /** 宿主是否已把 Node 运行时准备好（可执行 so / 脚本 root / argv 缓冲区）。 */
    val prepared: Boolean,
    /** 宿主侧的运行时根目录；Dart 只打印不使用（同 NodeRuntimeHostStatus.root）。 */
    val root: String? = null,
    /** 未就绪原因，或宿主报告的运行时终态（终态时用 [NodeRuntimeHostReason.RUNTIME_EXITED]）。 */
    val reason: String? = null,
) {
    override fun toString(): String =
        "NodeRuntimeHostStatus(prepared: " + prepared +
            ", root: " + (root ?: "null") +
            ", reason: " + (reason ?: "null") + ")"
}

/**
 * 宿主侧 Node 启动请求 = lib/bridge/node_runtime.dart 的 NodeRuntimeStartSpec 的 Kotlin 对应面。
 *
 * 与 Dart 一致，这里**只做数据载体、不做校验**：校验在
 * [NodeRuntimeHostCandidate.startRuntime]，这样"拒绝"能落到 reason/diagnostic 而不是抛异常。
 *
 * @property argv node::Start 的参数：["node", "<root>/MusicBridge/ios-runtime.cjs",
 *   "<port>", "<token>"]（Qt:107-113；ios-runtime.cjs:7 读 argv[2]=port、:16 读 argv[3]=token）。
 *   宿主必须把这份**快照**保存到运行时结束（Qt:110-113 的 NodeThreadStart 挂在堆上）。
 * @property stackBytes 线程栈字节数；8 MiB（Qt:118）由 native 侧
 *   `pthread_attr_setstacksize` 施加 —— Kotlin/Java 层无法设置 pthread 栈。
 */
class NodeRuntimeStartSpec(
    val argv: List<String>,
    val stackBytes: Int,
) {
    override fun toString(): String =
        "NodeRuntimeStartSpec(argv: <" + argv.size + " 项>, stackBytes: " + stackBytes + ")"
}

/**
 * 端口生命周期状态（Qt 侧由 launched/exited 两个旗标 + BridgeProcess 的 state 共同表达）。
 *
 * 状态迁移（[NodeRuntimeHostCandidate]）：
 * ```
 * idle --prepare()--> prepared --startRuntime()--> running --notifyRuntimeExited()--> exited
 *   |                            |
 *   +--prepare()失败----> failed <----startRuntime()失败
 * ```
 * dispose 不改这些状态（Qt 没有 shutdown 路径，Qt:164-168 的实例永不释放），只置
 * [NodeRuntimeHostCandidate.isDisposed]。
 */
enum class NodeRuntimeLifecycleState {
    /** 还没 prepare 过（Qt 的 NodeRuntime 尚未 launch）。 */
    idle,

    /** [NodeRuntimeHostCandidate.prepare] 成功，可以 startRuntime。 */
    prepared,

    /** 已把 argv 交给 native 启动（Qt:48 `launched` 且未 exited）。 */
    running,

    /** `node::Start` 已返回（Qt:50/:153 `exited`）；本进程内不再启动。 */
    exited,

    /** 启动/校验失败（对应 Dart 的 `_unavailable`，粘性、不再重试）。 */
    failed,
}

/**
 * 原生启动接缝（**仅声明；这里不实现、不注册、不加载 so**）。
 *
 * 对应 Qt:98-128 的 launch 与 Qt:142-162 的线程入口。实现方（后续接线）必须做到：
 *  1. 加载 libnode.so 并解析 `node::Start(int, char**)`（Qt:22-24 只导出这一个符号）；
 *  2. 把 [NodeRuntimeStartSpec.argv] 拷贝成**单个连续可写缓冲区**，段间用 NUL 分隔、末尾补
 *     nullptr（Qt:113 的 "node\\0script\\0port\\0token\\0" + Qt:144-149 的 values[5]）；
 *  3. 用 `pthread_attr_setstacksize(spec.stackBytes)` 起线程执行 `node::Start(4, argv)`
 *     （Qt:116-121、:152）；
 *  4. `node::Start` 返回后回调 [NodeRuntimeHostCandidate.notifyRuntimeExited]（Qt:153/:157），
 *     并且**只在返回后**释放 argv 缓冲区（Qt:160）。
 *
 * 返回 false 等价 Qt:122-125：`pthread_create` 失败（不抛异常，绝不外抛）。
 */
interface NodeRuntimeNativeStarter {
    /** 启动原生 Node 运行时；true = 线程已创建（Qt:127 `return true`）。 */
    fun start(spec: NodeRuntimeStartSpec): Boolean
}

/**
 * Node 运行时宿主端口 = lib/bridge/node_runtime.dart 的 `NodeRuntimeHost` 的 Kotlin 对应面。
 *
 * 三个方法与 Dart 一一对应；差别只在 async 表达：Dart 的 `Future` 来自平台通道往返
 * （旧实现 lib/bootstrap/node_host_bridge_channel.dart），进程内 Kotlin 直调没有跨通道握手，
 * 所以同步返回。若后续改由 MethodChannel 承载，由接线层负责包成 Future（这里不写接线）。
 */
interface NodeRuntimeHost {
    /**
     * 幂等准备；失败以 [NodeRuntimeHostStatus.prepared] == false 表达，**绝不抛异常**
     * （Dart 的 prepare 幂等）。重复调用不产生第二次 native 启动。
     */
    fun prepare(): NodeRuntimeHostStatus

    /**
     * 让宿主启动 Node 运行时；参数校验失败不抛异常，而是落到 reason/diagnostic
     * （Qt:186-188 把 launch 失败折成 runtime-error，而不是异常）。
     */
    fun startRuntime(argv: List<String>, stackBytes: Int)

    /** 释放宿主侧资源，不重启运行时（Dart 的 dispose 文档；Qt 无 shutdown 路径）。 */
    fun dispose()
}

/**
 * Android 分支的条件性宿主端口候选实现：**只实现、不注册**。
 *
 * 这里唯一会走到的运行路径是：`prepare` → prepared=false + reason=arch_blocked
 * （因为构造时没有 native 接缝）。其余分支是为路线裁决后准备的完整契约面，
 * 只有注入 [NodeRuntimeNativeStarter] 才会被执行。
 *
 * @param rootHint 宿主侧运行时根目录，仅回填到 [NodeRuntimeHostStatus.root]；
 *   Dart 不使用它（node_runtime.dart 的 root 字段）。
 * @param nativeStarter 原生启动接缝；本树里**没有任何实现**（ARCH_BLOCKED）。
 */
class NodeRuntimeHostCandidate(
    private val rootHint: String? = null,
    private val nativeStarter: NodeRuntimeNativeStarter? = null,
) : NodeRuntimeHost {

    /**
     * 生命周期状态。`@Volatile`：getter 不加锁（对齐 Qt:50 的 `std::atomic<bool> exited`：
     * 状态在 GUI 线程写、可能被运行时线程读）。
     */
    @Volatile
    var state: NodeRuntimeLifecycleState = NodeRuntimeLifecycleState.idle
        private set

    /** 是否已 dispose（Dart 的 dispose 文档 的「释放宿主侧资源」）。 */
    @Volatile
    var isDisposed: Boolean = false
        private set

    /**
     * 被保留的启动参数：Qt:110-113 要求 argv 缓冲活过 `node::Start` 全程，
     * 这里用强引用镜像该义务；Qt:160 只在 Start 返回后才 `delete start`。
     */
    @Volatile
    var retainedStartSpec: NodeRuntimeStartSpec? = null
        private set

    /**
     * 最近一次拒绝/终态的人读诊断。对应 Qt 的 qWarning（:154、:250-251、:273-275）：
     * 设备上没有控制台，接线方必须把它写进 logcat（本文件不引 android.util.Log）。
     */
    @Volatile
    var lastDiagnostic: String? = null
        private set

    /** `node::Start` 的返回码（Qt:152-154）；从未返回过为 null。 */
    @Volatile
    var lastExitCode: Int? = null
        private set

    /** [state] == failed 时粘住的 reason（对应 Dart 的 `_unavailable`）。 */
    @Volatile
    private var failureReason: String? = null

    /** 端口内部状态锁：只有 [notifyRuntimeExited] 可能来自运行时线程（Qt:153 的 atomic 写 + :155 的回投）。 */
    private val lock = Any()

    /** Qt:48 `launched` / Dart 的 launched：已交给宿主启动过（含已经 exited）。 */
    val launched: Boolean
        get() = state == NodeRuntimeLifecycleState.running || state == NodeRuntimeLifecycleState.exited

    /** Qt:50 `exited` / Dart 的 exited：`node::Start` 已返回，本进程内不再启动。 */
    val exited: Boolean
        get() = state == NodeRuntimeLifecycleState.exited

    override fun prepare(): NodeRuntimeHostStatus = synchronized(lock) {
        when {
            // 终态优先：Dart 的 _exited 分支 靠这个 reason 把 _exited 置真。
            state == NodeRuntimeLifecycleState.exited -> status(
                prepared = false,
                reason = NodeRuntimeHostReason.RUNTIME_EXITED,
            )

            isDisposed -> status(
                prepared = false,
                reason = NodeRuntimeHostReason.DISPOSED,
            )

            // 幂等：已就绪或已启动时重复 prepare() 只回报，不产生任何副作用（Dart 的 prepare 幂等）。
            state == NodeRuntimeLifecycleState.prepared || state == NodeRuntimeLifecycleState.running ->
                status(prepared = true)

            state == NodeRuntimeLifecycleState.failed -> status(
                prepared = false,
                reason = failureReason ?: NodeRuntimeHostReason.ARCH_BLOCKED,
            )

            // 这里唯一会走到的分支：没有 native 接缝 → ARCH_BLOCKED，绝不假装已接线。
            nativeStarter == null -> {
                state = NodeRuntimeLifecycleState.failed
                failureReason = NodeRuntimeHostReason.ARCH_BLOCKED
                lastDiagnostic = "node runtime host: no native starter wired " +
                    "(route undecided, plan:526-527); node::Start() cannot be called from Kotlin"
                status(prepared = false, reason = NodeRuntimeHostReason.ARCH_BLOCKED)
            }

            else -> {
                state = NodeRuntimeLifecycleState.prepared
                status(prepared = true)
            }
        }
    }

    override fun startRuntime(argv: List<String>, stackBytes: Int) {
        // 与 Dart 传入 NodeRuntimeStartSpec 一样是一次快照：Qt:112-113 把 argv 拷进 NodeThreadStart，
        // 之后调用方再改自己的 list 不得影响宿主手里这份。
        val spec = NodeRuntimeStartSpec(argv.toList(), stackBytes)
        val starter: NodeRuntimeNativeStarter? = synchronized(lock) {
            val rejection: StartRejection? = gateLocked(spec)
            if (rejection != null) {
                rejectLocked(rejection)
                return
            }
            // 先挂引用再调 native：`node::Start` 可能立刻返回（脚本不存在/立即抛错），
            // 那时 notifyRuntimeExited 会先于 starter.start() 的返回到达。
            retainedStartSpec = spec
            nativeStarter
        }
        if (starter == null) {
            // 防御面：闸门只在注入 native 接缝后才放行（否则 prepare() 已停在 failed/arch_blocked），
            // 但契约面绝不因缺实现而假装启动成功。
            synchronized(lock) {
                retainedStartSpec = null
                rejectLocked(
                    StartRejection(
                        NodeRuntimeHostReason.ARCH_BLOCKED,
                        "node runtime host: startRuntime reached the native seam with no starter " +
                            "(route undecided, plan:526-527)",
                    ),
                )
            }
            return
        }
        var thrownByNative: String? = null
        val started: Boolean = try {
            // 锁外调用：native 启动可能阻塞（pthread_create + libnode 加载），
            // 而 notifyRuntimeExited 需要在同一把锁内推进终态。
            starter.start(spec)
        } catch (t: Throwable) {
            // 与 Dart 的宿主边界兜底 的 `on Object` 同策略：宿主边界绝不外抛（含 UnsatisfiedLinkError）。
            thrownByNative = t.toString()
            false
        }
        synchronized(lock) {
            if (state == NodeRuntimeLifecycleState.exited) {
                // node::Start 已在 starter.start() 内返回（Qt:152-153）：终态优先，不回退到 running。
                return
            }
            if (started) {
                state = NodeRuntimeLifecycleState.running
            } else {
                // Qt:122-125 `delete start; return false` → Qt:186-188 上报 runtime-error。
                retainedStartSpec = null
                val detail: String = thrownByNative?.let { " (threw " + it + ")" } ?: ""
                rejectLocked(
                    StartRejection(
                        NodeRuntimeHostReason.NATIVE_START_FAILED,
                        "node runtime host: native start failed" + detail +
                            " (pthread_create or libnode load failure, Qt:122-125)",
                    ),
                )
            }
        }
    }

    override fun dispose() {
        synchronized(lock) {
            if (isDisposed) {
                return // 幂等
            }
            isDisposed = true
            if (state == NodeRuntimeLifecycleState.running) {
                // Qt 没有 shutdown 路径：node::Start 返回前 argv 缓冲绝不能释放
                // （Qt:110-113 的存活要求 + Qt:160 的释放时机），故推迟到 notifyRuntimeExited。
                lastDiagnostic = "node runtime host: dispose deferred, node::Start still running; " +
                    "argv kept until it returns (Qt:110-113/:160)"
                return
            }
            // 未运行时的释放：与 Qt:160 一致（此时没有读者）。注意不重置 state：
            // Qt:164-168 的实例永不释放，Dart 的 NodeRuntime.shutdown() 也不重置 _launched/_exited。
            retainedStartSpec = null
        }
    }

    /**
     * `node::Start` 返回后的唯一回调面（Qt:152-159）：由 native/宿主线程调用一次。
     *
     * 这里**没有调用方**、也没有 JNI 注册；它存在的意义是把 Qt:153 的
     * `runtime->exited = true` 与 Qt:157 的 `accept({type: runtime-error})` 落成可审查的契约：
     * 置 [state] = exited、记录退出码与脚本路径（Qt:154 的 logcat 文案），并让**下一次**
     * [prepare] 报 [NodeRuntimeHostReason.RUNTIME_EXITED] —— Dart 的 _exited 分支 据此把 `_exited` 置真。
     *
     * 幂等：重复调用只保留第一次（Qt 的 accept(runtime-error) 也只投一次）。
     *
     * @param exitCode `node::Start(4, values)` 的返回值（Qt:152）。
     */
    fun notifyRuntimeExited(exitCode: Int) {
        synchronized(lock) {
            if (state == NodeRuntimeLifecycleState.exited) {
                return
            }
            if (state != NodeRuntimeLifecycleState.running && state != NodeRuntimeLifecycleState.prepared) {
                // 从未启动过（或已 failed/disposed 之前的状态）：没有运行时可退出，
                // 不伪造终态（Qt 只在 nodeThreadMain 里置 exited，:153）。
                return
            }
            val script: String = retainedStartSpec?.argv?.getOrNull(1) ?: "<unknown>"
            state = NodeRuntimeLifecycleState.exited
            lastExitCode = exitCode
            // Qt:160：node::Start 返回后才允许释放 argv 缓冲。
            retainedStartSpec = null
            // Qt:153-154 原文：node runtime exited, code <code> script <script>
            lastDiagnostic = "node runtime exited, code " + exitCode + ", script " + script
        }
    }

    /**
     * startRuntime 的闸门：返回 null = 通过。
     *
     * 顺序即权威顺序：先状态（Qt:99-100 幂等），再 argv 布局（Qt:113/:152），
     * 再端口（Qt:108）、令牌（Qt:109）、脚本（Qt:102/:107），最后栈（Qt:118）。
     */
    private fun gateLocked(spec: NodeRuntimeStartSpec): StartRejection? {
        if (isDisposed) {
            return StartRejection(
                NodeRuntimeHostReason.DISPOSED,
                "node runtime host: startRuntime after dispose (Dart 的 dispose 文档, no restart path)",
            )
        }
        if (state == NodeRuntimeLifecycleState.running || state == NodeRuntimeLifecycleState.exited) {
            // Qt:99-100：launched 后只回报状态，绝不第二次 node::Start。
            return StartRejection(
                NodeRuntimeHostReason.ALREADY_STARTED,
                "node runtime host: startRuntime ignored, runtime already started (Qt:99-100)",
            )
        }
        if (state == NodeRuntimeLifecycleState.failed) {
            // 宿主已粘在 failed（Dart 的 _unavailable）：把粘住的 reason 原样回传，
            // 绝不重试（Qt:186-188 只投一次 runtime-error）。
            return StartRejection(
                failureReason ?: NodeRuntimeHostReason.NATIVE_START_FAILED,
                "node runtime host: startRuntime after a failed prepare/launch (state=failed)",
            )
        }
        if (state != NodeRuntimeLifecycleState.prepared) {
            return StartRejection(
                NodeRuntimeHostReason.NOT_PREPARED,
                "node runtime host: startRuntime requires a successful prepare() first " +
                    "(state=" + state.name + ")",
            )
        }
        val argv: List<String> = spec.argv
        if (argv.size != NodeRuntimeHostLimits.ARGV_LENGTH) {
            return StartRejection(
                NodeRuntimeHostReason.ARGV_INVALID,
                "node runtime host: argv must hold exactly " + NodeRuntimeHostLimits.ARGV_LENGTH +
                    " items, got " + argv.size + " (Qt:113/:152)",
            )
        }
        if (argv[0] != NodeRuntimeHostLimits.PROGRAM) {
            return StartRejection(
                NodeRuntimeHostReason.ARGV_INVALID,
                "node runtime host: argv[0] must be '" + NodeRuntimeHostLimits.PROGRAM +
                    "', got '" + argv[0] + "' (Qt:113)",
            )
        }
        for (index in argv.indices) {
            if (argv[index].indexOf(NodeRuntimeHostLimits.NUL) >= 0) {
                return StartRejection(
                    NodeRuntimeHostReason.ARGV_INVALID,
                    "node runtime host: argv[" + index + "] must not contain U+0000 " +
                        "(Qt:113 splits on '\\0', Qt:146-148 walks with std::strlen)",
                )
            }
        }
        if (!argv[1].endsWith(NodeRuntimeHostLimits.SCRIPT_SUFFIX)) {
            return StartRejection(
                NodeRuntimeHostReason.ARGV_INVALID,
                "node runtime host: argv[1] must end with '" + NodeRuntimeHostLimits.SCRIPT_SUFFIX +
                    "', got '" + argv[1] + "' (Qt:102/:107)",
            )
        }
        val port: Int? = argv[2].toIntOrNull()
        if (port == null || port < NodeRuntimeHostLimits.MIN_PORT || port > NodeRuntimeHostLimits.MAX_PORT) {
            return StartRejection(
                NodeRuntimeHostReason.ARGV_INVALID,
                "node runtime host: argv[2] must be a decimal port in " +
                    NodeRuntimeHostLimits.MIN_PORT + ".." + NodeRuntimeHostLimits.MAX_PORT +
                    ", got '" + argv[2] + "' (Qt:108)",
            )
        }
        if (argv[3].isEmpty()) {
            // Qt:109 secret = token.toUtf8()；空令牌等于首帧认证形同虚设（Qt:81-86）。
            return StartRejection(
                NodeRuntimeHostReason.ARGV_INVALID,
                "node runtime host: argv[3] must be a non-empty token (Qt:109, first frame is {token})",
            )
        }
        if (spec.stackBytes <= 0) {
            return StartRejection(
                NodeRuntimeHostReason.STACK_BYTES_INVALID,
                "node runtime host: stackBytes must be positive, got " + spec.stackBytes +
                    " (Qt:118 uses 8 MiB)",
            )
        }
        return null
    }

    private fun rejectLocked(rejection: StartRejection) {
        lastDiagnostic = rejection.diagnostic
        when (rejection.reason) {
            // 只有"宿主起不来"的原因才把状态粘成 failed（Dart 的 _unavailable）；
            // 调用顺序问题（not_prepared/already_started/disposed）只记诊断、不改状态。
            NodeRuntimeHostReason.ARGV_INVALID,
            NodeRuntimeHostReason.STACK_BYTES_INVALID,
            NodeRuntimeHostReason.NATIVE_START_FAILED,
            NodeRuntimeHostReason.ARCH_BLOCKED -> {
                state = NodeRuntimeLifecycleState.failed
                failureReason = rejection.reason
            }

            else -> Unit
        }
    }

    private fun status(prepared: Boolean, reason: String? = null): NodeRuntimeHostStatus =
        NodeRuntimeHostStatus(prepared = prepared, root = rootHint, reason = reason)

    companion object {
        /**
         * 进程级单例线索（Qt:164-168 `static auto instance = new NodeRuntime;`）：
         * 同一进程（同一 classloader）只应存在一个宿主端口实例，且**永不释放** ——
         * [dispose] 不会清掉这里，正如 Qt 不在 Host 析构时释放仍被 Node 使用的内存（Qt:165）。
         *
         * 注：Qt 的单例是 NodeRuntime 本体（token/回环连接/argv 线程），本文件不复刻那些
         * 内容（它们在 lib/bridge/node_runtime.dart），只复刻"进程级、只建一次、不释放"这一线索。
         */
        val process: NodeRuntimeHostCandidate by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
            NodeRuntimeHostCandidate()
        }
    }
}

/** [NodeRuntimeHostCandidate.startRuntime] 内部的拒绝原因 + 人读诊断（不对外）。 */
private class StartRejection(
    val reason: String,
    val diagnostic: String,
)
