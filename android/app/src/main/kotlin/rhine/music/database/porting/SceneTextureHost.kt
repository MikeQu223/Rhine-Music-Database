// SceneTextureHost.kt —— 场景纹理准入／宿主（Qt → Flutter 1:1 迁移，原子 F）
//
// 权威源：Qt/src/render/MusicTextureAdmission.h（255 行；RhineRender::MusicTextureAdmission +
// RhineRender::AdmissionScheduler）。本文件是它的 Kotlin 孪生，另加一层场景纹理宿主骨架：
//   * SceneTextureAdmission —— 准入状态机，逐条对齐 Qt 的判定语义（含三条"写错也不会崩"的规则）；
//   * SceneTextureHost      —— 场景纹理（句柄／宽高／代号）的宿主状态机，只做状态机与 ABI 契约。
//
// 约束（spec-F）：
//   * 纯 Kotlin 标准库，**不 import android.* 也不 import androidx.***：同一份实现既能编进
//     Android source set，也能在 JVM 单测里原样跑（Qt 版同样是"渲染器与用例共用一份实现"）。
//   * 时间不自己读：全部由构造注入的 clock 提供（毫秒、单调）。Android 侧传
//     { System.nanoTime() / 1_000_000L }；内部只用到差值（now - since），绝对起点无所谓。
//
// 平台默认：Android 500ms、其余 100ms（Qt 31-35）。计划文本
// （docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md 的 T41 段）写「纹理准入 100 ms」，
// 那是历史通用值；源码对 Android 明确取 500ms 并写清了理由（一次 fling 能跨十几条，100ms 之后
// 焦点早已换过两轮，等于边滑边给已经离开视野的条目建纹理）。冲突时以源码为准：
// Android 500ms、其它平台 100ms。
//
// 线程假设：单 GUI 线程 owner，无锁（与 Qt 版一致）。
//
// STATUS: written, deliberately NOT executed —— 没有执行 Gradle / CMake / 单测（验证协议禁止）。
package rhine.music.database.porting

/**
 * 快速滚动的冷纹理准入（Qt B01 的 1:1 移植）：焦点 key 在单调时钟上稳定 delayMs 之后才允许
 * 创建标签／封面纹理。只做纯判断——不读时钟、不碰定时器、不碰 GL——因此用例可以用精确边界
 * 断言（0／99／100），不需要 sleep。
 *
 * 三条容易写错、写错又不会崩的语义（Qt 头注释 5-8 行）：
 *   1. 同 key 重复帧、封面晚到、revision 变化都不重计时——否则滚动越久越等不到；
 *   2. 切走再回来要重计时，但已经准入过的 key 直接命中（热缓存立即复用）；
 *   3. 隐藏期间不作数：恢复后从恢复时刻重新计时。
 *
 * @param clock 单调毫秒时钟（唯一时间来源）。
 * @param admissionMsOverride 显式延迟覆盖；null = 取 [platformDefaultMs]。
 *        与 Qt 的构造函数一样**不做钳制**：0 或负值等于"关闭延迟"（delayMs <= 0 立即准入），
 *        只有环境变量那条路径才钳制到 0..60000。
 * @param isAndroid 平台判定（对应 Qt 的 Q_OS_ANDROID 分支）。默认 true：本文件只编进
 *        Android source set；JVM 单测想拿 100ms 默认时必须显式传 false。
 */
class SceneTextureAdmission(
    private val clock: () -> Long,
    admissionMsOverride: Int? = null,
    isAndroid: Boolean = true,
) {
    /** 准入延迟毫秒。0（或负值）= 关闭延迟，全部立即准入。 */
    val delayMs: Int = admissionMsOverride ?: platformDefaultMs(isAndroid)

    /** 延迟是否生效（Qt: enabled()）。 */
    val enabled: Boolean get() = delayMs > 0

    /**
     * 是否可见；隐藏期间不创建资源（Qt: visible()）。
     *
     * 用"私有字段 + 只读属性"而不是 `var visible ... private set`：后者会在 JVM 上生成
     * private setVisible(Z)V，与下面的 setVisible(Boolean) 签名冲突，Kotlin 会报
     * "platform declaration clash"。这里的形状也更贴近 Qt（visible() + setVisible()）。
     */
    private var visibleState: Boolean = true

    val visible: Boolean get() = visibleState

    /** 焦点代号：每次焦点／可见性／重置变化都自增，旧定时器回调靠它失效（Qt: generation()）。 */
    var generation: Long = 0L
        private set

    /** 当前焦点 key，空串表示没有焦点（Qt: focusKey()）。 */
    var focusKey: String = ""
        private set

    /** 正在等待的 key；没在等待时是空串（Qt: pendingKey()）。 */
    val pendingKey: String get() = if (pending) focusKey else ""

    /**
     * 等待起点（Qt: pendingSinceMs()）。与 Qt 一样，这个字段在"不在等待"时也不清零——
     * 它是最近一次计时的锚点，不是 pending 的附属品。
     */
    var pendingSinceMs: Long = 0L
        private set

    /** 是否在等延迟到期（返回 true 时调用方负责挂一次性定时器）。 */
    var pending: Boolean = false
        private set

    /** 已准入 key（Qt 用 QSet；这里用 LinkedHashSet，插入序即首次准入序，便于诊断输出）。 */
    private val admitted = LinkedHashSet<String>()

    /** 准入顺序，尾部最新；超限时丢最旧（Qt: m_order，QStringList）。 */
    private val order = ArrayList<String>()

    /** 当前 key 现在能不能建资源。 */
    fun isAdmitted(key: String): Boolean = admitted.contains(key)

    /** 已准入条数。 */
    val admittedCount: Int get() = admitted.size

    /** 已准入 key 的快照（集合语义；顺序不作契约）。 */
    fun admittedKeys(): Set<String> = LinkedHashSet(admitted)

    /** 准入顺序快照（尾部最新），用于诊断与跨端对拍；Qt 只暴露无序 QSet，这里是额外的只读视图。 */
    fun admissionOrder(): List<String> = ArrayList(order)

    /**
     * 可见性：隐藏时挂起等待，恢复时若还没准入就从恢复时刻重新计时。
     * 隐藏不清已准入记忆——恢复后热缓存仍然立即复用。
     */
    fun setVisible(value: Boolean) {
        if (visibleState == value) {
            return
        }
        visibleState = value
        if (!value) {
            // 隐藏期间不创建资源：把"已等到一半"作废，但不忘记已准入的 key。
            pending = false
            ++generation
            return
        }
        if (focusKey.isNotEmpty() && !isAdmitted(focusKey)) {
            pendingSinceMs = clock()
            pending = true
            ++generation
        }
    }

    /**
     * 报告当前焦点（每帧可调用）。key 为空表示没有焦点，撤销等待。
     * 返回 pending 时调用方负责 arm 一次性定时器；返回 admitted 时定时器可以停掉。
     */
    fun focus(key: String): Status {
        val nowMs = clock()
        if (key.isEmpty()) {
            focusKey = ""
            pending = false
            ++generation
            return Status(admitted = false, pending = false, generation = generation)
        }
        if (key != focusKey) {
            focusKey = key
            ++generation
            if (isAdmitted(key)) {
                // 热缓存：切回来立即命中，只把计时锚点挪到当前时刻。
                pending = false
                pendingSinceMs = nowMs
                return Status(admitted = true, pending = false, generation = generation)
            }
            pendingSinceMs = nowMs
            // 隐藏期间不创建资源，也就不该挂定时器：setVisible(true) 会从恢复时刻重新计时。
            pending = visibleState
            return Status(admitted = false, pending = pending, generation = generation)
        }
        // 同 key：不重计时。封面晚到、标题 revision 变化都只是"采用最新内容"。
        if (!pending) {
            return Status(admitted = isAdmitted(key), pending = false, generation = generation)
        }
        if (!visibleState) {
            // 隐藏期间不计时：恢复时 setVisible(true) 会重置起点。
            return Status(admitted = false, pending = false, generation = generation)
        }
        if (delayMs <= 0) {
            admit(key)
            return Status(admitted = true, pending = false, generation = generation)
        }
        if (nowMs - pendingSinceMs >= delayMs) {
            admit(key)
            return Status(admitted = true, pending = false, generation = generation)
        }
        return Status(admitted = false, pending = true, generation = generation)
    }

    /**
     * 定时器到期：核对 key／代号／可见性／剩余时长。任何一项不符都返回 false，调用方不要自己猜——
     * 旧回调就是这么被挡掉的。
     */
    fun expire(key: String, generation: Long): Boolean {
        val nowMs = clock()
        if (!pending || !visibleState || key != focusKey || generation != this.generation) {
            return false
        }
        if (delayMs > 0 && nowMs - pendingSinceMs < delayMs) {
            return false
        }
        admit(key)
        return true
    }

    /**
     * 设备恢复后不清空：准入是"用户已经看过它"的事实，纹理重建要沿着这份记忆走。
     * 只有显式 reset（切换数据源／退出）才清。
     *
     * 与 Qt 174-181 行逐字对应：**不清 order**。残留 key 只会在后续 admit 时被当作"空转淘汰"
     * 消耗掉，既不影响 32 条上限，也不改变真实 key 的淘汰顺序，所以照抄以免引入行为差异。
     */
    fun reset() {
        admitted.clear()
        focusKey = ""
        pending = false
        pendingSinceMs = 0L
        ++generation
    }

    private fun admit(key: String) {
        pending = false
        if (isAdmitted(key)) {
            return
        }
        admitted.add(key)
        order.remove(key) // Qt: m_order.removeAll(key)；order 里不会有重复项，remove 等价
        order.add(key)
        while (order.size > kMaxAdmitted) {
            admitted.remove(order.removeAt(0))
        }
    }

    /** 一次 focus/expire 的判定结果（字段名与 Qt Status 一一对应）。 */
    data class Status(
        /** 当前 key 现在就可以创建资源。 */
        val admitted: Boolean = false,
        /** 在等延迟到期（要挂一次性定时器）。 */
        val pending: Boolean = false,
        /** 焦点代号；旧定时器回调靠它失效。 */
        val generation: Long = 0L,
    )

    companion object {
        /** 已准入 key 的记忆条数（Qt: MusicTextureAdmission::MaxAdmitted，65 行）。 */
        const val kMaxAdmitted: Int = 32

        /** RHINE_TEXTURE_ADMISSION_MS 的合法上界（Qt 49 行硬编码 60000）。 */
        const val kMaxAdmissionMs: Int = 60_000

        /** 环境变量名（Qt 45 行）。 */
        const val kAdmissionMsEnvVar: String = "RHINE_TEXTURE_ADMISSION_MS"

        /** 平台默认准入延迟（Qt 31-35：Android 500ms，其它 100ms）。 */
        fun platformDefaultMs(isAndroid: Boolean): Int = if (isAndroid) 500 else 100

        /**
         * 读 RHINE_TEXTURE_ADMISSION_MS（Qt 42-53 的 1:1 移植）：未设置／解析失败／越界
         * （<0 或 >60000）一律回平台默认。一个笔误把延迟设成 0 是功能回退，设成几十秒则是
         * "界面永远不出图"，两种都不该由环境变量静默决定。
         *
         * @param env 环境变量读取器；Android 侧可传 { System.getenv(it) }，单测传假 Map。
         */
        fun fromEnvironment(
            env: (String) -> String?,
            clock: () -> Long,
            isAndroid: Boolean = true,
        ): SceneTextureAdmission = SceneTextureAdmission(
            clock = clock,
            admissionMsOverride = parseDelayMs(env(kAdmissionMsEnvVar)),
            isAndroid = isAndroid,
        )

        /**
         * 解析延迟毫秒；非法返回 null（调用方回平台默认）。
         * 语义对齐 Qt 的 qEnvironmentVariableIntValue：两端空白允许，中间/尾部垃圾拒绝
         * （"100ms" 不是数字），溢出拒绝；范围 [0, 60000] 之外也当非法。
         */
        fun parseDelayMs(raw: String?): Int? {
            val text = raw?.trim() ?: return null
            if (text.isEmpty()) {
                return null
            }
            val value = text.toIntOrNull() ?: return null
            if (value < 0 || value > kMaxAdmissionMs) {
                return null
            }
            return value
        }
    }
}

/**
 * 场景纹理宿主骨架（GUI 线程，无锁）。持有"整张场景纹理"这一个槽位：
 * 句柄、宽高、代号，以及一次尚未被消费方确认的 handoff。
 *
 * 平台契约（不实现真实 GL，只钉状态机与 ABI）：
 *   * Android 侧由 ImageReader／SurfaceTexture 产出 GL 纹理名（GLuint，32 位）或 Flutter 外部
 *     纹理 id；Kotlin 用 Long 承载，0 表示"没有句柄"（GL 纹理名 0 本来也非法）。
 *     Dart 的 int 是 64 位，JNI 走 jlong，跨端不会截断；C++ 侧对应 std::uint32_t。
 *   * Flutter 侧通过 Texture(textureId) 把这张纹理当外部纹理消费：宿主只负责"哪一代可以提交"，
 *     真正的 GL/EGL 上下文归平台实现。
 *   * 释放（surface 丢失／Activity 停止）必须让未确认的 handoff 失效，否则消费方会拿到已经
 *     不存在的纹理号——这正是代号（generation）存在的理由。
 *
 * @param admission 准入状态机（同一实例由宿主转发 focus/expire）。
 * @param allocator 向平台要一张纹理：返回句柄，0 表示平台此刻给不出（如 surface 未就绪）。
 *        宿主下一帧会重试；实现方要保证重复调用不泄漏 GL 资源。
 */
class SceneTextureHost(
    val admission: SceneTextureAdmission,
    private val allocator: (width: Int, height: Int) -> Long,
) {
    /** 纹理句柄；0 = 无。 */
    var handle: Long = 0L
        private set

    /** 纹理宽（像素）；0 = 无。 */
    var width: Int = 0
        private set

    /** 纹理高（像素）；0 = 无。 */
    var height: Int = 0
        private set

    /** 纹理代号：每次句柄建立／失效都自增，消费方据此丢弃过期帧。 */
    var generation: Long = 0L
        private set

    /** 是否已 handoff 但消费方还没确认（acknowledge 前不允许重复 handoff）。 */
    var pendingHandoff: Boolean = false
        private set

    /** 当前是否可提交给 Flutter（有句柄且尺寸有效）。 */
    val canCommit: Boolean get() = handle != 0L && width > 0 && height > 0

    /**
     * 每帧：向准入报告焦点 key；准入通过且当前没有可提交纹理时，向平台要一张。
     * 返回值原样是准入结果——pending 时调用方负责 arm 一次性定时器。
     */
    fun focus(key: String, width: Int, height: Int): SceneTextureAdmission.Status {
        val status = admission.focus(key)
        if (status.admitted) {
            ensureTexture(width, height)
        }
        return status
    }

    /**
     * 一次性定时器到点：交给准入核对 key／代号／可见性／剩余时长；通过则补建纹理。
     * 返回 false 表示这是一次过期回调（调用方不要自己猜，也不要重试）。
     */
    fun expire(key: String, generation: Long, width: Int, height: Int): Boolean {
        val admitted = admission.expire(key, generation)
        if (admitted) {
            ensureTexture(width, height)
        }
        return admitted
    }

    /**
     * 平台交出句柄（SurfaceTexture 已创建）。同句柄同尺寸是幂等空操作（不 ++generation）；
     * 句柄为 0 或尺寸非法时拒绝且不改状态——不留"半张纹理"。
     */
    fun acquire(handle: Long, width: Int, height: Int): Boolean {
        if (handle == 0L || width <= 0 || height <= 0) {
            return false
        }
        if (this.handle == handle && this.width == width && this.height == height) {
            return true
        }
        this.handle = handle
        this.width = width
        this.height = height
        ++generation
        // 新纹理作废旧代号的待提交：旧的 handoff 即使已经交出去也不该再被确认。
        pendingHandoff = false
        return true
    }

    /**
     * 释放纹理（surface 丢失／Activity 停止）。使未确认的 handoff 失效并 ++generation，
     * 返回新代号。已经空且没有待提交时是空操作（不 ++generation），重复释放不会把代号推乱。
     */
    fun release(): Long {
        if (handle == 0L && !pendingHandoff) {
            return generation
        }
        handle = 0L
        width = 0
        height = 0
        pendingHandoff = false
        ++generation
        return generation
    }

    /**
     * 带代号的释放：只有代号仍是当前代才生效（Android 的 surface 回调可能晚到，
     * 过期回调不能拆掉新纹理）。返回是否生效。
     */
    fun releaseIfCurrent(generation: Long): Boolean {
        if (generation != this.generation) {
            return false
        }
        release()
        return true
    }

    /**
     * 交给 Flutter 消费：返回要提交的代号，或 null（不可提交／同一代已经交接过）。
     * 交出后必须由消费方 acknowledge(generation) 收尾，否则同一代不会重复提交。
     */
    fun handoff(): Long? {
        if (!canCommit || pendingHandoff) {
            return null
        }
        pendingHandoff = true
        return generation
    }

    /** 消费方确认已接收该代纹理；代号不匹配或没有待提交时返回 false。 */
    fun acknowledge(generation: Long): Boolean {
        if (generation != this.generation || !pendingHandoff) {
            return false
        }
        pendingHandoff = false
        return true
    }

    /** 供跨端对拍／日志的只读快照。 */
    fun snapshot(): Snapshot = Snapshot(
        handle = handle,
        width = width,
        height = height,
        generation = generation,
        canCommit = canCommit,
        pendingHandoff = pendingHandoff,
    )

    /** 切换数据源／退出：清准入记忆并释放纹理。 */
    fun reset() {
        admission.reset()
        release()
    }

    private fun ensureTexture(width: Int, height: Int) {
        if (canCommit) {
            return
        }
        if (width <= 0 || height <= 0) {
            return
        }
        acquire(allocator(width, height), width, height)
    }

    /** 宿主状态快照（字段名与 C++ 版 Snapshot 一一对应）。 */
    data class Snapshot(
        val handle: Long = 0L,
        val width: Int = 0,
        val height: Int = 0,
        val generation: Long = 0L,
        val canCommit: Boolean = false,
        val pendingHandoff: Boolean = false,
    )
}
