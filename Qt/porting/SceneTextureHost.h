// SceneTextureHost.h —— 场景纹理准入／宿主（Qt → Flutter 1:1 迁移，原子 F）
//
// 与 Kotlin 版本对应：
//   android/app/src/main/kotlin/rhine/music/database/porting/SceneTextureHost.kt
// （同一份语义的两端实现：常量名、Status 字段名、边界行为逐项对齐）
//
// 权威源：Qt/src/render/MusicTextureAdmission.h（255 行；RhineRender::MusicTextureAdmission +
// RhineRender::AdmissionScheduler，Qt 类型 QString／QSet／quint64／QTimer）。
//
// 与 Qt 版的差别只在类型与时间注入方式：
//   * QString → std::string，QSet → std::vector（含去重查找），quint64 → std::uint64_t；
//   * Qt 把 nowMs 作为形参传进每次调用（调用方自己读时钟）；这里把 nowMs 收进构造注入的
//     Clock，方法不再收时间参数。语义不变——两种形状都"不读时钟"，都能用假时钟精确断言；
//   * Qt 的 AdmissionScheduler（QTimer）没有移植：一次性定时器属于 Qt 事件循环，
//     Flutter 侧由 Kotlin/Dart 侧的调度器承担，本文件只保留"arm 幂等"所需的 key+generation 契约。
//
// 本头文件不依赖任何 Qt 类型，只用 C++17 标准库（<cstdint> <cstdlib> <string> <vector>
// <functional> <optional>），因此可以被不含 Qt 的单测直接编译；也不包含 Qt/porting/CMakeLists.txt
// 的构建配置（T12 owner）。
//
// 线程假设：单 GUI 线程 owner，无锁（与 Qt 版一致）。
//
// STATUS: written, deliberately NOT executed —— 无 CMake / Gradle / 单测执行（验证协议禁止）。
#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace RhinePorting {

/**
 * 平台默认准入延迟（Qt 31-35 的 1:1）。Android 500ms、其余 100ms。
 *
 * 计划文本（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md 的 T41 段）写
 * 「纹理准入 100 ms」，那是历史通用值；源码对 Android 明确取 500ms，理由是手机上一次 fling
 * 能跨过十几条，100ms 之后焦点早已换过两轮，等于"边滑边给已经离开视野的条目建纹理"。
 * 冲突时以源码为准。
 */
#if defined(__ANDROID__)
inline constexpr int kPlatformAdmissionMs = 500;
#else
inline constexpr int kPlatformAdmissionMs = 100;
#endif

/// RHINE_TEXTURE_ADMISSION_MS 的合法上界（Qt 49 行硬编码 60000）。
inline constexpr int kMaxAdmissionMs = 60000;

/// 环境变量名（Qt 45 行）。
inline constexpr char kAdmissionMsEnvVar[] = "RHINE_TEXTURE_ADMISSION_MS";

/**
 * 解析延迟毫秒；非法返回 std::nullopt（调用方回平台默认）。
 * 语义对齐 Qt 的 qEnvironmentVariableIntValue：两端空白允许，中间/尾部垃圾拒绝
 * （"100ms" 不是数字），越界（<0 或 >60000）也当非法。
 */
std::optional<int> parseAdmissionDelayMs(const char* raw);

/**
 * 读 RHINE_TEXTURE_ADMISSION_MS（Qt 42-53 的 1:1）：未设置／解析失败／越界一律回平台默认。
 * 一个笔误把延迟设成 0 是功能回退，设成几十秒则是"界面永远不出图"，两种都不该由环境变量
 * 静默决定——所以这里不钳制，只回退。
 */
int admissionDelayMsFromEnvironment();

/**
 * 冷纹理准入状态机（GUI 线程）。只做纯判断：不读时钟、不碰定时器、不碰 GL，
 * 所以用例能用精确边界断言（0／99／100），不需要 sleep。
 *
 * 三条容易写错、写错又不会崩的语义（Qt 头注释 5-8 行）：
 *   1. 同 key 重复帧、封面晚到、revision 变化都不重计时——否则滚动越久越等不到；
 *   2. 切走再回来要重计时，但已经准入过的 key 直接命中（热缓存立即复用）；
 *   3. 隐藏期间不作数：恢复后从恢复时刻重新计时。
 */
class SceneTextureAdmission
{
public:
    /// 单调毫秒时钟（唯一时间来源；Android 侧可用 clock_gettime(CLOCK_MONOTONIC)）。
    using Clock = std::function<std::int64_t()>;

    /// 已准入 key 的记忆条数（Qt: MaxAdmitted，65 行）。超限时丢最旧的那条。
    static constexpr int kMaxAdmitted = 32;

    /// Qt: DefaultDelayMs（62 行）。
    static constexpr int kDefaultDelayMs = kPlatformAdmissionMs;

    /// 一次 focus/expire 的判定结果（字段名与 Kotlin Status 一一对应）。
    struct Status
    {
        bool admitted = false;          ///< 当前 key 现在就可以创建资源
        bool pending = false;           ///< 在等延迟到期（要挂一次性定时器）
        std::uint64_t generation = 0;   ///< 焦点代号；旧定时器回调靠它失效
    };

    /// 与 Qt 的构造函数一样不做钳制：delayMs <= 0 等于"关闭延迟"。
    SceneTextureAdmission(int delayMs, Clock clock);
    static SceneTextureAdmission fromEnvironment(Clock clock);

    int delayMs() const;
    bool enabled() const;
    bool visible() const;
    std::uint64_t generation() const;
    /// 正在等待的 key；没在等待时为空串（Qt: pendingKey()）。
    std::string pendingKey() const;
    /// 等待起点。与 Qt 一样，不在等待时也不清零——它是最近一次计时的锚点。
    std::int64_t pendingSinceMs() const;
    std::string focusKey() const;

    /// 可见性：隐藏时挂起等待，恢复时若还没准入就从恢复时刻重新计时。
    void setVisible(bool value);

    /// 报告当前焦点（每帧可调用）。key 为空表示没有焦点，撤销等待。
    Status focus(const std::string& key);

    /// 定时器到期：核对 key／代号／可见性／剩余时长；任何一项不符都返回 false。
    bool expire(const std::string& key, std::uint64_t generation);

    bool isAdmitted(const std::string& key) const;
    /// 已准入 key 的快照（集合语义，顺序不作契约；Qt 返回无序 QSet）。
    std::vector<std::string> admittedKeys() const;
    /// 准入顺序快照（尾部最新），用于诊断与跨端对拍；Qt 只暴露无序 QSet，这里是额外只读视图。
    std::vector<std::string> admissionOrder() const;
    int admittedCount() const;

    /// 设备恢复后不清空：准入是"用户已经看过它"的事实。只有显式 reset 才清。
    void reset();

private:
    void admit(const std::string& key);

    int m_delayMs = kDefaultDelayMs;
    Clock m_clock;
    bool m_visible = true;
    bool m_pending = false;
    std::string m_key;
    std::vector<std::string> m_order;     ///< 准入顺序（尾部最新），超限时丢最旧的
    std::vector<std::string> m_admitted;  ///< Qt: QSet<QString>，这里用去重 vector
    std::uint64_t m_generation = 0;
    std::int64_t m_sinceMs = 0;
};

/**
 * 场景纹理宿主骨架（GUI 线程，无锁）。持有"整张场景纹理"这一个槽位：句柄、宽高、代号，
 * 以及一次尚未被消费方确认的 handoff。
 *
 * 平台契约（不实现真实 GL，只钉状态机与 ABI）：
 *   * Android 侧由 ImageReader／SurfaceTexture 产出 GL 纹理名（GLuint，32 位），
 *     这里用 std::uint32_t 承载，0 表示"没有句柄"（GL 纹理名 0 本来也非法）；
 *     Kotlin 侧用 Long 承载同一个值，JNI 走 jlong，跨端不截断。
 *   * Flutter 侧通过 Texture(textureId) 把这张纹理当外部纹理消费：宿主只负责
 *     "哪一代可以提交"，真正的 GL/EGL 上下文归平台实现。
 *   * 释放（surface 丢失／Activity 停止）必须让未确认的 handoff 失效，否则消费方会拿到
 *     已经不存在的纹理号——这正是代号（generation）存在的理由。
 */
class SceneTextureHost
{
public:
    /// 向平台要一张纹理：返回句柄，0 表示平台此刻给不出（如 surface 未就绪），宿主下一帧重试。
    using Allocator = std::function<std::uint32_t(int width, int height)>;

    /// 宿主状态快照（字段名与 Kotlin Snapshot 一一对应）。
    struct Snapshot
    {
        std::uint32_t handle = 0;
        int width = 0;
        int height = 0;
        std::uint64_t generation = 0;
        bool canCommit = false;
        bool pendingHandoff = false;
    };

    SceneTextureHost(SceneTextureAdmission admission, Allocator allocator);

    const SceneTextureAdmission& admission() const;
    SceneTextureAdmission& admission();

    std::uint32_t handle() const;
    int width() const;
    int height() const;
    std::uint64_t generation() const;
    bool pendingHandoff() const;
    /// 当前是否可提交给 Flutter（有句柄且尺寸有效）。
    bool canCommit() const;

    /// 每帧：向准入报告焦点 key；准入通过且没有可提交纹理时向平台要一张。
    SceneTextureAdmission::Status focus(const std::string& key, int width, int height);

    /// 一次性定时器到点：交给准入核对；通过则补建纹理。false = 过期回调，不要重试。
    bool expire(const std::string& key, std::uint64_t generation, int width, int height);

    /// 平台交出句柄。同句柄同尺寸是幂等空操作；句柄 0 或尺寸非法时拒绝且不改状态。
    bool acquire(std::uint32_t handle, int width, int height);

    /// 释放纹理并 ++generation（使未确认的 handoff 失效），返回新代号；已空且无待提交时空操作。
    std::uint64_t release();

    /// 带代号的释放：只有代号仍是当前代才生效（晚到的 surface 回调不能拆掉新纹理）。
    bool releaseIfCurrent(std::uint64_t generation);

    /// 交给 Flutter 消费：返回要提交的代号，或 std::nullopt（不可提交／同一代已交接过）。
    std::optional<std::uint64_t> handoff();

    /// 消费方确认已接收该代纹理；代号不匹配或没有待提交时返回 false。
    bool acknowledge(std::uint64_t generation);

    Snapshot snapshot() const;

    /// 切换数据源／退出：清准入记忆并释放纹理。
    void reset();

private:
    void ensureTexture(int width, int height);

    SceneTextureAdmission m_admission;
    Allocator m_allocator;
    std::uint32_t m_handle = 0;
    int m_width = 0;
    int m_height = 0;
    std::uint64_t m_generation = 0;
    bool m_pendingHandoff = false;
};

} // namespace RhinePorting
