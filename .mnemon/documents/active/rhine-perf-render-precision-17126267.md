---
id: "17126267-5190-4f5d-bc18-d4be28fefdfa"
title: "Rhine 渲染性能诊断与改动记录（perf/render-precision）"
description: "Rhine 渲染性能的完整诊断：三层瓶颈归因（呈现层压 GUI 线程、每帧强制重渲、插帧的二次几何遍历）、已实施改动与实测收益、失败实验清单、未解决项与构建环境铁律。"
status: "active"
created_at: "2026-10-28T16:00:34.049Z"
updated_at: "2026-10-28T16:00:34.049Z"
content_hash: "b3beaa0c975b5f96723da12d0d780d6b4c9078a24c3e1ba80f585826abda0959"
source_paths:
  []
session_ids:
  - "session-f293f616-6715-40d7-a765-8caf9100e12e"
memory_body_ids:
  []
---

# Rhine 渲染性能：诊断结论与改动记录（2026-10-28）

分支 `perf/render-precision`。所有数据为全屏 2560x1440、主界面「收藏专辑」(98 条) 列表、
uinput 按住 ↓ 20 s 的区间平均，取 `节拍诊断` 的 `render/s`（= `Engine::m_renderFrames`，即**内容帧**）。

## 一、测量环境与生效设置

| 项 | 值 |
|---|---|
| 合成器 | niri 26.04 Wayland，输出 DP-1 2560x1440@99.965Hz |
| GPU | Intel Iris Xe（`gpu-index=1`，i915）。RTX 3050 Mobile 为 `gpu-index=0` |
| 生效设置 | `aa-mode=fsr`、`fsr-quality=super`（场景内部分辨率 = 显示/3）、`render-scale=100`、`supersample=1`、`vsync=off`(MAILBOX)、`gpu-index=1` |

渲染器只消费 `RenderConfiguration::initialize` 的 5 个键（`Qt/src/render/RenderConfiguration.h:61-65`）：
`aa-mode` / `render-scale` / `supersample` / `fg` / `vsync`。
`msaa=8`、`aa-scale=125` 等是残留存储值，不生效；`quality=hires` 是音质不是画质。

## 二、三组基线（改动前）

| 配置 | 内容帧/s | 上屏 presented/s | 间隔均 | step均 |
|---|---|---|---|---|
| Vulkan 插帧关 | **20.3** | 36.8 | 51.3 ms | 10.8 ms |
| Vulkan 插帧开 | **12.9** | 24.8（真实 12.4 + 插值 12.4） | 62.0 ms | 13.8 ms |
| OpenGL | **30.7** | 29.6 | 32.9 ms | 9.7 ms |

两个反直觉现象：
1. **Vulkan 插帧关的上屏数（36.8/s）几乎是内容帧（20.3/s）的 1.8 倍**——`SceneLayerHost::renderFrame()`
   在非 Metal 后端每帧强制置脏，同一内容被重录重渲多次。
2. **插帧开时内容帧腰斩**（20.4→12.1），但"不同画面数"反而更高（上屏含插值帧）。

## 三、根因：呈现层把渲染压在 GUI 线程

- `SceneLayerHost` 全部基于 `QQuickRenderControl`，`render()` 在**调用线程**执行；
  `PresentationShell` 自管 QRhi 绕过 Qt Quick 渲染线程 → Vulkan 路径下，两层离屏录制 + 合成 + present
  全落在 GUI 线程上。
- OpenGL 根本没有 `PresentationShell`（`supportsBackend()` 只认 metal/vulkan），走 Qt 标准
  `QQuickWindow` 的独立渲染线程。
- 实测：Vulkan 每拍 GUI 线程 33.39 ms（step 8.09 + 呈现 25.3），OpenGL 23.45 ms（step 9.47）。
  **Vulkan 的 step 反而更低，差距全在拍与拍之间。**
- 引擎节拍不是固定值：`Engine::tick()` 末尾 `timer.setInterval(1)`，注释明写"帧率上限完全交给呈现侧……
  渲染期间 GUI 线程被占，定时器本来就投递不进来"。所以内容帧率 = 渲染工作之外的空隙。

分层成本（FG diag，插帧关）：3D 层 8.2 ms（其中录制 7.5）+ UI 层 6.0 ms ≈ **14.2 ms/次上屏**，
而上屏 36.8 次/s → 约 545 ms/s（55% GUI 线程）。其中约 16.4 次/s 是内容没变的重渲，
折合 233 ms/s 的纯浪费。

## 四、已实施的改动

### 1. 呈现层按插帧开关门控（核心，+43%）

`Qt/src/main.cpp`：

```cpp
const bool fgForced = qEnvironmentVariable("RHINE_FG_LAYER").compare("on", Qt::CaseInsensitive) == 0;
const bool interpolationWanted = fgForced || RhineFg::parseBool(qgetenv("RHINE_FG"), false);
const bool fgCandidate = !test && !args.contains("--capture") && !fgLayerDisabled &&
                         hasNativeWindowSystem && interpolationWanted &&
                         PresentationShell::supportsBackend(RhineGraphics::activeBackend());
```

`fg=off` 时不再创建呈现层，直接走 Qt 默认路径。**代价：切换插帧需要重启**。

效果：Vulkan 插帧关 20.3 → **27.2 ± 1.1**（+34%），间隔均 51.3 → 33.2 ms，
与 OpenGL 差距从 −36% 收窄到 −18%。`RHINE_FG_LAYER=on` 保留强制接管的对照口子。

### 2. 设置页文案标明重启

`Qt/src/NativeHudModal.cpp`：`FRAME GENERATION / 帧生成 · 重启生效`（与 V-SYNC/GPU/后端三处写法一致）。
同步修正 `Qt/src/fg/FgConfig.h`、`Qt/src/NativeHudController.cpp` 里"免重启生效"的旧注释。

### 3. 修复设置项死锁（回归）

`Qt/src/fg/FgCapability.h` 的 `frameGenerationUi()`：门控改造后 `fg=off` 时
`presentLayerActive` 恒 false，原逻辑对它返回 `{false,"呈现层未接管"}` 并置灰 → **开关永远打不开**。

```cpp
if (!presentLayerActive) {
    if (!preferenceOn) return {true, QStringLiteral("关闭")};
    return {true, QStringLiteral("已开启 · 重启生效")};
}
```

真正失败（`reason` 非空）仍在前面提前返回并置灰。回归用例见
`Qt/tests/FgCapabilityChecks.cpp` 的 `settingsRowStates()` 第 5/5b 条
（`RhineFgCapabilityRegression`，编译通过、退出码 0）。

### 4. 绘制状态开销（viewport + 排序）

`Qt/src/RhiScene.cpp` 的 `geometry()`：
- 原来每个 draw 都调一次 `setViewport`（尺寸恒定）；改为仅在 pipeline 变化后设置一次
- draw 按 `QRhiGraphicsPipeline*` 稳定排序，**不透明段在前、透明段保持原顺序**（`std::stable_sort`，
  比较器对透明项返回 false 以保序）

实测状态重绑（`RHINE_DRAW_PROBE=1`，每 120 帧）：

```
draw 111 | pipeline 绑定 45 | srb 绑定 111 | viewport 设置 45
```

pipeline 绑定与 viewport 从 111 降到 45（−60%）。画面与改动前一致（专辑墙/封面/玻璃层/HUD 全部就位）。

## 五、失败与回退的实验（重要，别再重复）

| 实验 | 结论 |
|---|---|
| 实例 buffer 合并成 arena | **回退**。批次 buffer 72→0，但 `srb 绑定` 纹丝不动（116 次），实例 buffer 反涨到 289；内容帧 28.4 vs 28.5，间隔还差 1.9 ms |
| 跳过 HUD 文字栅格化 | **无效**。HUD 绘制 7.35 ms 里 text 占 92%，但整体跳过后 tick 反降（30.5→28.1）|
| `PRESENT_ALWAYS=0` 省上屏 | **无效**。presented 52.7→33.7 |
| 内容代次精细化上屏 | tick +7.6% 但 presented 掉到 33.4，上屏不是瓶颈 |
| 光流降档 | **不可行**。`ffxOpticalflowContextDispatch` 返回 -2147483638，SDK 要求按 displaySize |
| `RHINE_TICK_MS=40` 压帧 | 节拍反降到 13/s，采样不随 dt 回落 → 否定"dt 变大导致更贵" |
| FSR 开关对比 | 场景分辨率砍到 1/9 帧率几乎不变（46.8→45.1）→ **瓶颈在 CPU 提交，不是填充率** |

## 六、未解决

1. **Vulkan 插帧开仍比关低 56%**（12.9 vs 29.0）。单帧渲染 14.2→47.6 ms：起帧(beginFrame) 0→9~11 ms、
   录制 7.5→23 ms（`RhiScene::velocityPass` 跑 `MotionPass` 把同一份几何再渲一遍产深度+运动矢量）、
   UI 层 6.0→14.4 ms。插值本身（光流 1.11 + 插值 0.66 + 合成 0.11 ms）不到总成本 5%。
   MRT 合并已做过一部分（+4.3%）。
2. **`srb 绑定 111~116 次/帧`** 是下一个真靶子：每个 draw 的 `QRhiShaderResourceBindings`
   绑定不同封面/标签纹理，合并需要纹理数组 + 索引切换，属架构级改动。
3. 设置页「帧生成」行在最大滚动位仍不可见（停在 FSR SHARPNESS），原因未查。

## 七、环境铁律

- 构建：`RHINE_NODE_BINARY=$PWD/vendor/node-linux-x64/node RHINE_NODE_LICENSE=$PWD/vendor/node-linux-x64/LICENSE ./build.sh`
  —— 但**日常验证别用它**，它总附带 AppImage 打包，反复跑会把磁盘塞满；
  用 `cmake --build output/qt-build --target RhineMusicDatabase -j8`。
- 配置只改 `gpu-index` 一行（`sed -i`），绝不整份覆盖（曾冲掉用户的 FSR 改动）。
- 收尾还原会话：`cp session.orig.json ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json`；
  脚本与基线见「Rhine 帧率测量脚手架」文档。
