// 自建 Qt for Android kit 的源码补丁：构建期按**内容锚点**应用，不依赖行号。
//
// 为什么不用 .patch 文件：git diff 的 hunk 头带绝对行号，上游文件一改就飘；
// 这里每个补丁是「精确文本 → 精确文本」的替换，文件里上下挪几十行也不影响。
// 命中次数必须严格等于 expect（默认 1）；已应用（替换结果已存在）则跳过，
// 反复构建幂等；锚点消失直接构建失败并指出补丁名，绝不静默略过。
//
// 目前唯一一项：Qt 6.12 的 Android Vulkan 窗口在系统销毁/更换 Surface 时与
// 渲染线程的 vkQueuePresentKHR 竞态。真机 tombstone 实证：
//   FORTIFY "pthread_mutex_lock called on a destroyed mutex"
//   （Surface::hook_queueBuffer ← vulkan::driver::QueuePresentKHR ← QRhi::endFrame）
// 错开时序时表现为静默 SIGSEGV（exit-info 只有 SIGNALED/11，无 tombstone）。
// 修法：clearSurface() 只标记失效并撤回 expose，真正的销毁推迟到渲染线程的
// vkSurface()（swapchain 重建的帧间安全点）或窗口析构。
const fs = require('node:fs');
const path = require('node:path');

const patches = [
    {
        name: 'android-vulkan-surface-race',
        file: 'qtbase/src/plugins/platforms/android/qandroidplatformvulkanwindow.h',
        edits: [
            {
                find: `private:
    void destroyAndClearSurface();

    ANativeWindow *m_nativeWindow;
    QSurfaceFormat m_format;
    VkSurfaceKHR m_vkSurface;
    PFN_vkCreateAndroidSurfaceKHR m_createVkSurface;
    PFN_vkDestroySurfaceKHR m_destroyVkSurface;
};`,
                replace: `private:
    void destroyAndClearSurface();
    void destroySurfaceResources();

    ANativeWindow *m_nativeWindow;
    QSurfaceFormat m_format;
    VkSurfaceKHR m_vkSurface;
    PFN_vkCreateAndroidSurfaceKHR m_createVkSurface;
    PFN_vkDestroySurfaceKHR m_destroyVkSurface;
    // 系统侧已宣告 Surface 失效、但资源尚未销毁（销毁被推迟到渲染线程的
    // 帧间安全点）。见 qandroidplatformvulkanwindow.cpp 的 clearSurface()。
    bool m_vkSurfaceStale = false;
};`,
            },
        ],
    },
    {
        name: 'android-vulkan-surface-race',
        file: 'qtbase/src/plugins/platforms/android/qandroidplatformvulkanwindow.cpp',
        edits: [
            {
                // clearSurface 改为「只标记 + 撤回 expose」，真实销毁挪进
                // destroySurfaceResources()，由渲染线程的 vkSurface() 或析构调用。
                find: `void QAndroidPlatformVulkanWindow::clearSurface()
{
    if (m_vkSurface && m_destroyVkSurface) {
        m_destroyVkSurface(window()->vulkanInstance()->vkInstance(), m_vkSurface, nullptr);
        m_vkSurface = 0;
    }

    if (m_nativeWindow) {
        ANativeWindow_release(m_nativeWindow);
        m_nativeWindow = nullptr;
    }

    decrementSurfacesCount();
}`,
                replace: `void QAndroidPlatformVulkanWindow::clearSurface()
{
    // 系统侧的 Surface 随时可能失效（前台 BLAST 换面同样会触发
    // onSurfaceChanged(invalid)，不经过任何应用状态切换）。此刻渲染线程可能
    // 正处于 vkQueuePresentKHR 的半程：若在这里销毁 VkSurfaceKHR 并释放
    // ANativeWindow，Surface 对象会被从渲染线程脚下抽走——实测 tombstone：
    // FORTIFY "pthread_mutex_lock called on a destroyed mutex"（Surface::
    // hook_queueBuffer ← vulkan::driver::QueuePresentKHR ← QRhi::endFrame），
    // 错开时序则表现为静默 SIGSEGV。
    //
    // 因此这里只做两件无竞态的事：
    //   1. 标记失效；真正的销毁推迟到渲染线程的下一次 vkSurface()（swapchain
    //      重建发生在帧间，是安全点）或窗口析构（渲染线程已停）。
    //   2. 对 Qt Quick 撤回 expose。不撤回的话渲染循环会继续向这个已失效的
    //      surface 出帧，而 surface 重生后 size 未变、swapchainJustBecame-
    //      Renderable 不翻转，createOrResize 永远不会重查 surface，界面就此
    //      冻结。撤回 expose 后渲染线程停摆，重 expose 时走 createOrResize
    //      → vkSurface() → 消费失效标记并换到新 surface。
    m_vkSurfaceStale = true;
    QWindowSystemInterface::handleExposeEvent(window(), QRegion());
}

void QAndroidPlatformVulkanWindow::destroySurfaceResources()
{
    if (m_vkSurface && m_destroyVkSurface) {
        if (QVulkanInstance *inst = window()->vulkanInstance())
            m_destroyVkSurface(inst->vkInstance(), m_vkSurface, nullptr);
    }
    m_vkSurface = 0;

    if (m_nativeWindow) {
        ANativeWindow_release(m_nativeWindow);
        m_nativeWindow = nullptr;
    }

    decrementSurfacesCount();
}`,
            },
            {
                // 隐藏/析构路径：渲染线程已停摆，直接销毁；不能只标记失效，
                // 析构之后再没有 vkSurface() 调用来消费标记。
                find: `void QAndroidPlatformVulkanWindow::destroyAndClearSurface()
{
    lockSurface();
    destroySurface();
    clearSurface();
    unlockSurface();
}`,
                replace: `void QAndroidPlatformVulkanWindow::destroyAndClearSurface()
{
    lockSurface();
    destroySurface();
    // 应用隐藏/窗口析构路径：渲染线程此时已停摆（expose 撤回或应用状态切换
    // 先行），直接销毁资源是安全的。不能只标记失效——析构之后再没有
    // vkSurface() 调用来消费标记，资源会泄漏到进程退出。
    destroySurfaceResources();
    m_vkSurfaceStale = false;
    unlockSurface();
}`,
            },
            {
                // 渲染线程的帧间安全点：消费失效标记，先销毁旧的 VkSurface /
                // ANativeWindow，再按当前 Android Surface 重建。
                find: `    bool needsExpose = false;
    if (!m_vkSurface) {
        clearSurface();

        QMutexLocker lock(&m_surfaceMutex);`,
                replace: `    bool needsExpose = false;
    // 帧间安全点：消费 clearSurface() 标记的失效 surface。本函数由
    // QRhiSwapChain::createOrResize 在渲染线程上调用，此刻没有 present 在途，
    // 销毁 VkSurfaceKHR 与 ANativeWindow 不会与渲染竞争。
    if (m_vkSurfaceStale) {
        m_vkSurfaceStale = false;
        destroySurfaceResources();
    }
    if (!m_vkSurface) {
        QMutexLocker lock(&m_surfaceMutex);`,
            },
            {
                // 新 surface 建好即作废旧标记：创建/等待期间若又收到失效事件，
                // 其标记针对的是旧对象，不能让它误杀刚建好的 surface。
                find: `        VkResult err = m_createVkSurface(inst->vkInstance(), &surfaceInfo, nullptr, &m_vkSurface);
        if (err != VK_SUCCESS)
            qWarning("Failed to create Android VkSurface: %d", err);`,
                replace: `        VkResult err = m_createVkSurface(inst->vkInstance(), &surfaceInfo, nullptr, &m_vkSurface);
        if (err != VK_SUCCESS) {
            qWarning("Failed to create Android VkSurface: %d", err);
        } else {
            // 新的 VkSurface + ANativeWindow 对已就位：若创建/等待期间又收到过
            // 失效事件，其标记针对的是旧对象，就此作废，防止下一次调用误杀
            // 刚建好的 surface。
            m_vkSurfaceStale = false;
        }`,
            },
        ],
    },
];

/**
 * 按锚点走一遍补丁。write=false 时只校验不写盘（--check 用）。
 * 返回需要改动（或已改动）的文件列表；锚点失配会在任何一个补丁上直接抛错。
 */
function walkQtAndroidPatches(root, write) {
    const touched = [];
    for (const patch of patches) {
        const file = path.join(root, 'third_party/qt', patch.file);
        let text = fs.readFileSync(file, 'utf8');
        let changed = false;
        for (const edit of patch.edits) {
            const expect = edit.expect ?? 1;
            const pending = text.split(edit.find).length - 1;
            const settled = text.split(edit.replace).length - 1;
            if (pending === 0 && settled >= expect) {
                // 已应用：替换结果在位，且原始锚点已不存在。
                continue;
            }
            if (pending !== expect) {
                throw new Error(
                    `qt-android patch "${patch.name}" anchor mismatch in ${patch.file}: ` +
                        `expected ${expect} occurrence(s), found ${pending}. ` +
                        '上游文件结构变了，请更新 scripts/qt-android-patches.cjs 的锚点。',
                );
            }
            text = text.split(edit.find).join(edit.replace);
            changed = true;
        }
        if (changed) {
            if (write) {
                fs.writeFileSync(file, text);
            }
            touched.push(patch.file);
        }
    }
    return touched;
}

/** 把补丁应用到 third_party/qt 工作树，返回实际改动的文件列表（已应用则为空）。 */
function applyQtAndroidPatches(root = path.resolve(__dirname, '..')) {
    return walkQtAndroidPatches(root, true);
}

/** 干跑：只校验锚点是否齐全，返回尚未应用的文件列表。 */
function pendingQtAndroidPatches(root = path.resolve(__dirname, '..')) {
    return walkQtAndroidPatches(root, false);
}

module.exports = { applyQtAndroidPatches, pendingQtAndroidPatches };

if (require.main === module) {
    const applied = applyQtAndroidPatches();
    if (applied.length === 0) {
        console.log('qt-android patches: already applied');
    } else {
        console.log('qt-android patches applied:', applied.join(', '));
    }
}
