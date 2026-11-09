// SceneTextureHost.cpp —— 场景纹理准入／宿主的实现（Qt → Flutter 1:1 迁移，原子 F）
//
// 与 Kotlin 版本对应：
//   android/app/src/main/kotlin/rhine/music/database/porting/SceneTextureHost.kt
// 权威源：Qt/src/render/MusicTextureAdmission.h（255 行）。逐条对齐 88-206 行的判定与 184-196 行
// 的淘汰顺序；差异只在类型（std::string／std::uint64_t）与时间注入（构造注入 Clock）。
//
// 只依赖 C++17 标准库，且刻意不引入 <algorithm>：本文件允许的头只有
// <cstdint> <cstdlib> <string> <vector> <functional> <optional>，所以去重查找/删除都在下面的
// 匿名命名空间里手写（最多 32 个元素，线性扫描足够，也避免给跨端移植引入额外依赖）。
//
// 线程假设：单 GUI 线程 owner，无锁（与 Qt 版一致）。
//
// STATUS: written, deliberately NOT executed —— 无 CMake / Gradle / 单测执行（验证协议禁止）。
#include "SceneTextureHost.h"

#include <cstdlib>

namespace RhinePorting {
namespace {

int indexOf(const std::vector<std::string>& items, const std::string& value)
{
    for (int i = 0; i < static_cast<int>(items.size()); ++i) {
        if (items[i] == value) {
            return i;
        }
    }
    return -1;
}

bool containsValue(const std::vector<std::string>& items, const std::string& value)
{
    return indexOf(items, value) >= 0;
}

// Qt: m_order.removeAll(key) —— 移除所有同名项（本实现里 order 不会有重复项）。
void eraseAll(std::vector<std::string>& items, const std::string& value)
{
    for (int i = 0; i < static_cast<int>(items.size());) {
        if (items[i] == value) {
            items.erase(items.begin() + i);
        } else {
            ++i;
        }
    }
}

bool isSpace(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

} // namespace

std::optional<int> parseAdmissionDelayMs(const char* raw)
{
    if (raw == nullptr) {
        return std::nullopt;
    }
    const char* p = raw;
    while (isSpace(*p)) {
        ++p;
    }
    bool negative = false;
    if (*p == '+' || *p == '-') {
        negative = (*p == '-');
        ++p;
    }
    if (*p < '0' || *p > '9') {
        return std::nullopt; // 空串、纯空白、"abc" 都算解析失败
    }
    long long value = 0;
    bool outOfRange = false;
    while (*p >= '0' && *p <= '9') {
        if (!outOfRange) {
            value = value * 10 + (*p - '0');
            if (value > kMaxAdmissionMs) {
                outOfRange = true; // 已经超过合法上界，继续吃掉数字直到结尾再拒绝
            }
        }
        ++p;
    }
    while (isSpace(*p)) {
        ++p;
    }
    if (*p != '\0') {
        return std::nullopt; // 尾随垃圾（"100ms"／"100 "）不是数字，回平台默认
    }
    if (outOfRange) {
        return std::nullopt;
    }
    const long long signedValue = negative ? -value : value;
    if (signedValue < 0 || signedValue > kMaxAdmissionMs) {
        return std::nullopt;
    }
    return static_cast<int>(signedValue);
}

int admissionDelayMsFromEnvironment()
{
    return parseAdmissionDelayMs(std::getenv(kAdmissionMsEnvVar)).value_or(kPlatformAdmissionMs);
}

// ---------------------------------------------------------------- SceneTextureAdmission

SceneTextureAdmission::SceneTextureAdmission(int delayMs, Clock clock)
    : m_delayMs(delayMs)
    , m_clock(clock)
{
}

SceneTextureAdmission SceneTextureAdmission::fromEnvironment(Clock clock)
{
    return SceneTextureAdmission(admissionDelayMsFromEnvironment(), clock);
}

int SceneTextureAdmission::delayMs() const
{
    return m_delayMs;
}

bool SceneTextureAdmission::enabled() const
{
    return m_delayMs > 0;
}

bool SceneTextureAdmission::visible() const
{
    return m_visible;
}

std::uint64_t SceneTextureAdmission::generation() const
{
    return m_generation;
}

std::string SceneTextureAdmission::pendingKey() const
{
    return m_pending ? m_key : std::string();
}

std::int64_t SceneTextureAdmission::pendingSinceMs() const
{
    return m_sinceMs;
}

std::string SceneTextureAdmission::focusKey() const
{
    return m_key;
}

void SceneTextureAdmission::setVisible(bool value)
{
    if (m_visible == value) {
        return;
    }
    m_visible = value;
    if (!value) {
        // 隐藏期间不创建资源：把"已等到一半"作废，但不忘记已准入的 key。
        m_pending = false;
        ++m_generation;
        return;
    }
    if (!m_key.empty() && !isAdmitted(m_key)) {
        m_sinceMs = m_clock();
        m_pending = true;
        ++m_generation;
    }
}

SceneTextureAdmission::Status SceneTextureAdmission::focus(const std::string& key)
{
    const std::int64_t nowMs = m_clock();
    if (key.empty()) {
        m_key.clear();
        m_pending = false;
        ++m_generation;
        return Status{false, false, m_generation};
    }
    if (key != m_key) {
        m_key = key;
        ++m_generation;
        if (isAdmitted(key)) {
            // 热缓存：切回来立即命中，只把计时锚点挪到当前时刻。
            m_pending = false;
            m_sinceMs = nowMs;
            return Status{true, false, m_generation};
        }
        m_sinceMs = nowMs;
        // 隐藏期间不创建资源，也就不该挂定时器：setVisible(true) 会从恢复时刻重新计时。
        m_pending = m_visible;
        return Status{false, m_pending, m_generation};
    }
    // 同 key：不重计时。封面晚到、标题 revision 变化都只是"采用最新内容"。
    if (!m_pending) {
        return Status{isAdmitted(key), false, m_generation};
    }
    if (!m_visible) {
        // 隐藏期间不计时：恢复时 setVisible(true) 会重置起点。
        return Status{false, false, m_generation};
    }
    if (m_delayMs <= 0) {
        admit(key);
        return Status{true, false, m_generation};
    }
    if (nowMs - m_sinceMs >= m_delayMs) {
        admit(key);
        return Status{true, false, m_generation};
    }
    return Status{false, true, m_generation};
}

bool SceneTextureAdmission::expire(const std::string& key, std::uint64_t generation)
{
    const std::int64_t nowMs = m_clock();
    if (!m_pending || !m_visible || key != m_key || generation != m_generation) {
        return false;
    }
    if (m_delayMs > 0 && nowMs - m_sinceMs < m_delayMs) {
        return false;
    }
    admit(key);
    return true;
}

bool SceneTextureAdmission::isAdmitted(const std::string& key) const
{
    return containsValue(m_admitted, key);
}

std::vector<std::string> SceneTextureAdmission::admittedKeys() const
{
    return m_admitted;
}

std::vector<std::string> SceneTextureAdmission::admissionOrder() const
{
    return m_order;
}

int SceneTextureAdmission::admittedCount() const
{
    return static_cast<int>(m_admitted.size());
}

void SceneTextureAdmission::reset()
{
    // Qt 174-181 行逐字对应：**不清 m_order**。残留 key 只会在后续 admit 时被当作"空转淘汰"
    // 消耗掉，既不影响 32 条上限，也不改变真实 key 的淘汰顺序，所以照抄以免引入行为差异。
    m_admitted.clear();
    m_key.clear();
    m_pending = false;
    m_sinceMs = 0;
    ++m_generation;
}

void SceneTextureAdmission::admit(const std::string& key)
{
    m_pending = false;
    if (isAdmitted(key)) {
        return;
    }
    m_admitted.push_back(key);
    eraseAll(m_order, key);
    m_order.push_back(key);
    while (static_cast<int>(m_order.size()) > kMaxAdmitted) {
        const std::string oldest = m_order.front();
        m_order.erase(m_order.begin());
        eraseAll(m_admitted, oldest);
    }
}

// ---------------------------------------------------------------- SceneTextureHost

SceneTextureHost::SceneTextureHost(SceneTextureAdmission admission, Allocator allocator)
    : m_admission(admission)
    , m_allocator(allocator)
{
}

const SceneTextureAdmission& SceneTextureHost::admission() const
{
    return m_admission;
}

SceneTextureAdmission& SceneTextureHost::admission()
{
    return m_admission;
}

std::uint32_t SceneTextureHost::handle() const
{
    return m_handle;
}

int SceneTextureHost::width() const
{
    return m_width;
}

int SceneTextureHost::height() const
{
    return m_height;
}

std::uint64_t SceneTextureHost::generation() const
{
    return m_generation;
}

bool SceneTextureHost::pendingHandoff() const
{
    return m_pendingHandoff;
}

bool SceneTextureHost::canCommit() const
{
    return m_handle != 0 && m_width > 0 && m_height > 0;
}

SceneTextureAdmission::Status SceneTextureHost::focus(const std::string& key, int width, int height)
{
    const SceneTextureAdmission::Status status = m_admission.focus(key);
    if (status.admitted) {
        ensureTexture(width, height);
    }
    return status;
}

bool SceneTextureHost::expire(const std::string& key, std::uint64_t generation, int width, int height)
{
    const bool admitted = m_admission.expire(key, generation);
    if (admitted) {
        ensureTexture(width, height);
    }
    return admitted;
}

bool SceneTextureHost::acquire(std::uint32_t handle, int width, int height)
{
    if (handle == 0 || width <= 0 || height <= 0) {
        return false; // 不留"半张纹理"：拒绝且不改状态
    }
    if (m_handle == handle && m_width == width && m_height == height) {
        return true; // 同句柄同尺寸：幂等空操作，不 ++generation
    }
    m_handle = handle;
    m_width = width;
    m_height = height;
    ++m_generation;
    // 新纹理作废旧代号的待提交：旧的 handoff 即使已经交出去也不该再被确认。
    m_pendingHandoff = false;
    return true;
}

std::uint64_t SceneTextureHost::release()
{
    if (m_handle == 0 && !m_pendingHandoff) {
        return m_generation; // 已空且无待提交：空操作，不把代号推乱
    }
    m_handle = 0;
    m_width = 0;
    m_height = 0;
    m_pendingHandoff = false;
    ++m_generation;
    return m_generation;
}

bool SceneTextureHost::releaseIfCurrent(std::uint64_t generation)
{
    if (generation != m_generation) {
        return false;
    }
    release();
    return true;
}

std::optional<std::uint64_t> SceneTextureHost::handoff()
{
    if (!canCommit() || m_pendingHandoff) {
        return std::nullopt;
    }
    m_pendingHandoff = true;
    return m_generation;
}

bool SceneTextureHost::acknowledge(std::uint64_t generation)
{
    if (generation != m_generation || !m_pendingHandoff) {
        return false;
    }
    m_pendingHandoff = false;
    return true;
}

SceneTextureHost::Snapshot SceneTextureHost::snapshot() const
{
    Snapshot snapshot;
    snapshot.handle = m_handle;
    snapshot.width = m_width;
    snapshot.height = m_height;
    snapshot.generation = m_generation;
    snapshot.canCommit = canCommit();
    snapshot.pendingHandoff = m_pendingHandoff;
    return snapshot;
}

void SceneTextureHost::reset()
{
    m_admission.reset();
    release();
}

void SceneTextureHost::ensureTexture(int width, int height)
{
    if (canCommit()) {
        return;
    }
    if (width <= 0 || height <= 0) {
        return;
    }
    acquire(m_allocator(width, height), width, height);
}

} // namespace RhinePorting
