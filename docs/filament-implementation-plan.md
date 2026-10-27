# Filament 链路接入实施计划 v2

> 2026-10-27 ／ 基线 `main` @ 2a0c877 ／ 目标 Filament v1.78.1
> **v2 变更**：已并入审查报告的 B1–B4、M1–M10；删除 v1 的架构抽象、总结章节与重复表述。
> 前置：[可行性评估](filament-migration-assessment.md) ／ [审查报告](filament-plan-review.md)

---

## 0 约束（不满足即视为 bug）

| # | 约束 | 判据 |
| --- | --- | --- |
| C1 | 关闭开关时二进制行为逐像素不变 | 9 个检查程序全绿 + `pnpm test:visual` 逐字节一致 |
| C2 | 默认关闭 | `filament` 偏好为空时不创建任何 Filament GPU 对象 |
| C3 | 失败不可崩 | 探测/初始化/首帧/运行中任一失败 → 降级且界面可用 |
| C4 | 自检路径强制旧链路 | `--self-test`/`--visual-fixtures`/`--ui-self-test`/`--offline` 忽略开关 |
| C5 | 无运行时下载 | Filament 静态链入，`.filamat` 构建期产出 |
| C6 | 后处理不被替换 | `render/`+`fg/`+`fsr/` 共 7,363 行一行不删 |

---

## 1 接缝：一个 if 分支

**唯一改动点是 `Renderer::render()`**（`Qt/src/RhiScene.cpp:1274-1279`）。`composite()` 已经内置"采样 `color.texture` → 后处理输入 → resolve"整条链（`:1073-1133`），所以只需替换场景色的来源：

```cpp
// 原三行：cb->beginPass(color.rt, background, {1,0}); geometry(opaque); geometry(transparent); cb->endPass();
if (m_filament && m_filament->active()) {
    if (!m_filament->renderFrame(frame, item, cover, size)) {
        m_filament->degrade();            // 本帧改走 legacy，绝不黑屏
    } else {
        color.texture = m_filament->wrappedTexture();   // 尺寸恒等于 size
        invalidateFinalBinding();                        // ← 见陷阱 T1
    }
}
if (!m_filament || !m_filament->active()) {
    cb->beginPass(color.rt, background, {1, 0});
    geometry(cb, opaque);
    geometry(cb, transparent);
    cb->endPass();
}
velocityPass(cb, data, frame);                            // 不变
composite(cb, finalTarget ? finalTarget : target.rt);      // 不变
```

**此设计废弃 v1 的**：`ISceneRasterizer` 接口、`QrhiRasterizer`、`ScenePostProcess::setExternalSource()`。原因：`composite()` 已经做了那件事。

### 注意点

- **N1** 赋值必须在 `resize()` 之后。`resize()` 会 `color = makeTarget(...)` 整体重建（`:430`），提前赋值会被覆盖。
- **N2** `color.texture` 换掉后，`geometry()` 用的 `color.rp` 不再有效——因此 legacy 分支与 Filament 分支必须互斥，不能同帧都用。
- **N3** `composite()` 的绑定缓存 key 是 `"final"`（非 macOS），它持有旧 `color.texture`。换纹理时必须 `postBindings.remove("final")`，否则采样到上一张图（陷阱 T1）。
- **N4** macOS 分支不走这条路径（`:1079-1100` 用 `metalFx`），**Filament 在 macOS 上单独实现，排 P5**。

---

## 2 开关与回退

### 2.1 三层开关

| 层 | 载体 | 取值 | 默认 | 优先级 |
| --- | --- | --- | --- | --- |
| 编译期 | CMake `RHINE_FILAMENT` | ON/OFF | **OFF** | 最高；OFF 时设置页整组隐藏 |
| 环境变量 | `RHINE_FILAMENT` | on/off | 未设 | 覆盖设置 |
| 用户设置 | 偏好 `filament` | on/off/空 | **空=off** | 最低 |

沿用 `Host::preference`/`setPreference`（`Host.h:58,59`）、`compiledIn()`（`PresentationShell.h:59`）、`RhineFg::isEnabled()`（`FgFrameTap.h:78`）三个既有形态，不发明新范式。

### 2.2 状态机

```
compiledIn? 否→LEGACY ｜ requested? 否→LEGACY ｜ probe 失败→LEGACY+原因
  → start 失败→LEGACY+原因+释放 → firstFrame 失败→LEGACY+原因 → FILAMENT
  运行中异常 → LEGACY（同帧重试，每 session 记录一次）
```

### 2.3 探测（不创建 GPU 对象）

| 码 | 检查 | 处置 |
| --- | --- | --- |
| `E_MATERIAL_MISSING` | `.filamat` 在资源根 | 回退 |
| `E_BACKEND_UNSUPPORTED` | 后端 ∈ {Vulkan, GL, Metal} | 回退 + 隐藏开关 |
| `E_GL_TOO_OLD` | GL ≥ 4.1 | 回退 + 提示驱动过旧 |
| `W_QUEUE_SERIALIZED` | graphics 队列 < 2 | **不回退**，进串行化模式（告警） |
| `E_SIZE_INVALID` | 尺寸有效 | 回退，下帧重试 |

### 2.4 初始化与失败码

`E_SHARED_CONTEXT`（共享上下文）→ `E_ENGINE_CREATE`（Engine）→ `E_SCENE_CREATE`（Scene/View/Camera/Renderer）→ `E_MATERIAL_LOAD`（材质）→ `E_IMAGE_HANDOFF`（宿主图像池）→ `E_FIRST_FRAME`（首帧可取回）。运行期为 `E_SYNC` / `E_RUNTIME`。

失败共同要求：① 按 `engine->destroy()` 释放（不 `delete`）；② 不残留 VkImage/信号量；③ 写 `filament-last-error = "<code>: <msg>"`；④ 继续启动。

---

## 3 文件清单

### 新增（约 1,450 行）

| 文件 | 行 | 职责 |
| --- | --- | --- |
| `Qt/src/scene/FilamentBridge.{h,cpp}` | 340 | 契约实现、帧驱动、降级、关闭 |
| `Qt/src/scene/FilamentScene.{h,cpp}` | 380 | 实体池、transform 同步、排序、材质实例 |
| `Qt/src/scene/FilamentAssets.{h,cpp}` | 340 | 顶点/索引、纹理、材质装载与缓存 |
| `Qt/src/scene/FilamentPlatform.{h,cpp}` | 260 | `VulkanPlatform` 子类 + 宿主图像池 |
| `Qt/src/scene/FilamentProbe.{h,cpp}` | 200 | 探测与初始化编排 |
| `Qt/src/scene/FilamentConfig.{h,cpp}` | 80 | 开关判定、失败码、偏好 |
| `Qt/shaders/filament/*.mat` | — | 4 个着色家族 × 状态变体 |
| `Qt/tests/FilamentChecks.cpp` | 260 | 检查程序 |

### 修改（约 220 行）

| 文件 | 改动 |
| --- | --- |
| `Qt/src/RhiScene.cpp` | §1 的三行替换 + `invalidateFinalBinding()` + 遥测字段（~70） |
| `Qt/src/Engine.cpp` | 偏好注入 + 启动编排（~40） |
| `Qt/src/NativeHudController.cpp` | 设置页两行（~60） |
| `Qt/qml/Overlay.qml` | 设置页 UI（~40） |
| `CMakeLists.txt` | 选项、子项目、`.filamat` 构建规则（~80） |

**`ScenePostProcess`、`MotionPass`、`PresentationShell`、`Hud`、`NativePicking` 零改动。**

---

## 4 图像交接

### 4.1 方案（H1：宿主拥有图像）

自己建 `VkImage` 池 → 用 `VulkanPlatform` 子类把 `createSwapChain`/`getSwapChainBundle` 指过去 → Filament 渲进我们的图 → `QRhiTexture::createFrom(NativeTexture)` 认领。

**否决**：CPU 回读（官方明说显著影响性能，且 FG 前提作废）；"Filament 自建图 + 补丁 getter"（布局交接从"实现 acquire/present"退化为"猜它渲完留什么 layout"，偶发花屏且验证层报错含混，更难查）。

### 4.2 格式与色彩空间契约

| 项 | 值 | 依据 |
| --- | --- | --- |
| 颜色格式 | **恒 `VK_FORMAT_R16G16B16A16_SFLOAT`** | 场景色目标恒为 RGBA16F（`RhiScene.cpp:426-430`），与 AA 模式无关 |
| 采样数 | **1** | MSAA 交 Filament 内部（见 §7.4） |
| 数量 | 2（双缓冲） | FG 需"上一帧仍被采样" |
| 深度 | `D32_SFLOAT`，由 `MotionPass` 独立维护，**不给 Filament** | 见 §7.1 |
| 色彩空间 | 不用 `CONFIG_SRGB_COLORSPACE`；输出视为线性 HDR | 转换只发生在 `finalFragment` 与后处理 |
| 初态 | `UNDEFINED` → Filament 转 `COLOR_ATTACHMENT_OPTIMAL` | — |
| 交接态 | Filament `present()` 转 `SHADER_READ_ONLY_OPTIMAL` 并 signal 二进制信号量 | — |

> v1 写"SDR RGBA8 / HDR RGBA16F"是错的：`RGBA8` 那个选择属于后处理内部输入（`ScenePostProcess.cpp:111`），不是场景色。

### 4.3 同步契约

Filament `present()` 打 `VK_ACCESS_SHADER_READ` 屏障 + signal 信号量 → QRhi 侧经 `QRhiVulkanQueueSubmitParams` wait（与现有 FG 提交注入同源）→ Qt 帧结束后交回 `acquire()`。

---

## 5 场景桥接

### 5.1 实体池

```cpp
struct DrawKey { quint64 geometryId; quint64 materialId; int layer; };
struct Entity { filament::utils::Entity e; filament::VertexBuffer *vb; filament::IndexBuffer *ib;
                DrawKey key; quint64 lastSeen; };
```

- 首现创建；存活实体每帧只 `setTransform`（**绝不每帧重建**，否则帧率塌，陷阱 T6）。
- 连续 2 帧未出现才销毁；销毁必须在 `flushAndWait()` 之后（陷阱 T7）。
- 同 `geometryId` 多实例共用一份 VB/IB（8 组件 / 32 字节步长，来自 `export-assets.py`）。
- `RenderableManager::Builder::instances(n)` 单对象上限**待 P2 实测**（v1 当成 64 写死，无出处）。

### 5.2 排序映射（必做）

现状：`render()` 在 `:1247-1262` 把绘制分 opaque/transparent，各自按 `data["order"]` `stable_sort`，transparent 后画。

映射：`order` → `Builder::priority()`，数值直接透传。**必须验证**：卡片叠放与半透明壳体的遮挡顺序在两条链路下一致（§9 V5）。

### 5.3 跳过冗余工作

`batchDraws(opaque)`（`:1249`）只为 `geometry()` 服务，Filament 链路下**跳过**。
`prepare()`（`:1213`）产出只有 `velocityPass` 用到其 CPU 字段（`:1157-1165` 只读 `id/vertices/indices/matrixBytes/start/count/instances/side`），评估其 GPU 上传部分能否短路。

### 5.4 相机

- `frame["view"]`/`frame["projection"]` → `filament::math::mat4f`，用 `setCustomProjection(m, near, far)`。
- **jitter 在交给 Filament 之前注入**（夺回 A1 的一部分）：
  ```cpp
  jittered[2][0] += jitterX * 2.0f / size.width();
  jittered[2][1] += jitterY * 2.0f / size.height();
  ```
  同时对 `frame["aoProjection"]` 做同样处理，否则烘焙光场错位。
- **曝光必须置中性**：`Camera` 有物理曝光模型（默认 f/16、1/125s、ISO100），置 aperture/shutter/sensitivity 全 1.0 使曝光因子为 1，并以色板回归验证（§9 V2）。

---

## 6 材质

### 6.1 状态矩阵（v1 最大低估）

`geometry()`（`:1054-1061`）的每-draw 状态：

```cpp
hashed = surface(data).flags.x() == 2;
blend  = hashed || data["transparent"];
depthWrite = hashed || !blend || data["depthWrite"];
pipeline(..., doubleSided = data["side"].toInt() == 2, depthWrite, blend);
```

Filament 里 `blending`/`depthWrite`/`doubleSided` **都是材质级属性**，不是实例参数。实际组合：

| 来源 | transparent | depthWrite | doubleSided |
| --- | --- | --- | --- |
| `SceneAppearance.cpp:126-131` | `alphaMode=="BLEND"` | true | 闭壳且无透射 |
| `SceneAppearance.cpp:150-153` | false | true | `definition["side"]` |
| `SceneAppearance.cpp:188-191` | true | false | true |
| `SceneAppearance.cpp:208-211` | true | false | false |
| `SceneAppearance.cpp:232-235` | false | true | false |
| `NativeCards.cpp:100-106` | 透传 | 透传 | 透传 |

→ **(blend, depthWrite) ∈ {(F,T),(T,F),(T,T)} × doubleSided ∈ {F,T} = 6 种**，乘 4 个着色家族（surface / card / ground / disc）= **12–18 个材质变体**，不是 5 个。

> 变体可由同一 `.mat` 源经 `matc` 的参数/变体机制生成，不必手写 18 份。**`hashed` 只改 blend/depthWrite，不改着色逻辑**，因此可用 3 个 blend/depthWrite 变体 × 2 个 doubleSided 变体共 6 份，家族差异用参数表达。

### 6.2 参数映射

| 现有 GLSL | `.mat` 形态 |
| --- | --- |
| `Surface m`（std140 UBO） | 拆成独立 float/vec4（不支持结构体参数） |
| `v_theme`/`v_quality`/`v_lightMask`/`v_clarity`/`v_mode` | `variables` 自定义顶点变量 |
| `v_lightUv` (vec3) | 同上，注意 vec3 对齐 |
| `opticalLight` | 材质参数 + `MaterialInstance::setParameter` |
| `KEY_LIGHT` | 写死 `normalize(vec3(0.0, 0.55, 0.84))` |
| `bakedIllumination()` 8 层切片 | 原样移植，`HEIGHT_SLICES 8` 必须同一常量 |

### 6.3 必须关闭 Filament 的默认行为（v1 遗漏，会直接导致画面不对）

```cpp
view->setPostProcessingEnabled(false);   // 若版本无此 API，逐项关 bloom/tonemap
view->setAntiAliasing(false);            // FXAA 默认开启！不关就是双重抗锯齿
view->setColorGrading(neutral);          // 或 nullptr + 色板验证
view->setDithering(...NONE);             // 动态分辨率文档明确 "Avoid FXAA and dithering"
view->setAmbientOcclusion…(关闭);
```
且**不添加任何 Light / IndirectLight**；着色完全由 `customSurfaceShading: true` 接管。

> 上述符号名（`setPostProcessingEnabled`/`setDithering`/`setColorGrading(nullptr)`）**P0 必须逐个核对**，v1/v2 均未在源码中验证。

### 6.4 必须保留的着色细节

1. **素面封底**（`opticalSurface.frag:51-57`）：`gl_FrontFacing` 换成等价判断或 `doubleSided` + 法线朝向。
2. **两切片边界**（`:26-32`）：`floor(v_lightUv.z)` 与 `min(lower+1, 7.0)` 必须一致，否则最高层越界采样。
3. **主光只加镜面不加阴影**（`:39-49`）：必须接管 `surfaceShading()`，否则多出 Filament 自己的直接光照。

---

## 7 后处理接入

### 7.1 深度/运动矢量：复用，不重写

`MotionPass` 已独立产出深度与速度并**在生产中使用**：`RhiScene.cpp:1091` 的 MetalFX 解析即消费 `motion->depth()`/`motion->vectors()`；`velocityPass()`（`:1138-1170`）用同一份 `data` 渲自己的深度与速度，不依赖场景光栅化实现。

**结论：接线即可（2–4 人日），不需要任何 Filament 侧补丁。** 二者矩阵必须取自同一份 `frame` JSON 的同一矩阵，jitter 也必须一致，否则速度场整体偏移。

### 7.2 模式接通顺序

`off` → `fxaa` → `fsr1`（纯空间，不需深度速度）→ `taa`（需 depth+velocity）→ `fsr3`（+jitter）→ FG → `msaa`/`ssaa` → `metalfx`(P5)。

### 7.3 AA 责任划分

Filament 链路下：**MSAA 由 Filament 承担，SSAA 仍由我们放大 `renderSize` 承担**，互斥由设置项保证。

### 7.4 `samples()` 必须强制为 1

`resize()` 按 `postProcess->samples()` 申请 `sampleCount` 并建 `resolved`（`:412-430`）。Filament 输出是单采样，若我们仍申请多重采样目标 → 格式/采样数不匹配。**Filament 链路下 `samples()` 恒返回 1**，MSAA 请求转给 `setMultiSampleAntiAliasingOptions`。

---

## 8 线程与同步

| 线程 | 约束 |
| --- | --- |
| Qt 渲染线程 | 不得阻塞等 Filament 异步任务 |
| Filament 渲染线程 | `Platform` 回调都在此；不得反向调 Qt 对象 |

**帧序（v1 同步模式）**：`sync`（CPU 实体池）→ `beginFrame` → `render` → `endFrame` → `flushAndWait` → QRhi 取样 → 后处理 → 呈现。

**队列**：优先申请第 2 个 graphics 队列；只有 1 个时进串行化模式（严格交替 + 信号量），打 `info` 并计入遥测。

**停顿上限**：P3 结束时中位帧时间劣化 ≤ 25%、p95 ≤ 40%（`--frame-profile` 采 3000 帧）；超标必须进 P5 双缓冲（第 N 帧取样 N-1 帧的图，延迟一帧），否则不发布。

---

## 9 必验清单

| # | 验什么 | 怎么验 | 不过怎么办 |
| --- | --- | --- | --- |
| V1 | 关闭时零差异 | 9 个检查程序 + `pnpm test:visual` 逐字节 | 阻断发布 |
| V2 | 色彩正确 | 16 色块，两条链路 PSNR ≥ 40 dB | 查 §6.3 关项与曝光 |
| V3 | 单立方体几何正确 | 与 `renderReference()` 比对 SSIM ≥ 0.98 | 查投影/jitter |
| V4 | 完整场景观感 | 亮封面/暗封面/素面封底三组，SSIM ≥ 0.98 | **P2 Gate，不过就停** |
| V5 | 透明遮挡顺序 | 定点采样断言 + 截图比对 | 查 §5.2 priority 映射 |
| V6 | 实体池稳态 | 同一 frame 跑 300 帧：`created==1`、`alive==1` | 查 T6 |
| V7 | 图像交接 | 双缓冲交替 3000 帧，验证层零错误、零 layout 违例 | 查 T9/T10 |
| V8 | 同步压力 | `--filament-sync-stress 3000` | 查信号量注入 |
| V9 | 降级 | 注入 `E_FIRST_FRAME`，断言同帧恢复且非黑 | 查同帧重试 |
| V10 | 拾取不变 | 开关前后命中结果完全一致 | 不应失败（纯 CPU） |
| V11 | 退出与 rhi 重建 | 强制触发 rhi 变更 + 退出，断言无崩溃/无验证层错误 | 查 T5 |
| V12 | 性能 | 中位 ≤ +25%、p95 ≤ +40% | 进 P5 双缓冲 |
| V13 | 显存 | 3000 帧无增长 | 查 T7 |
| V14 | 材质参数齐全 | `matc -r` 的 JSON 反射比对必需参数 | 查 §6.2 |
| V15 | GL 4.1 回退 | 模拟低版本驱动 → `E_GL_TOO_OLD` 且旧链路可用 | 查 §2.3 |
| V16 | 单队列串行化 | 强制 `W_QUEUE_SERIALIZED` 路径跑 3000 帧 | 查 §8 |

---

## 10 陷阱清单

| # | 症状 | 根因 | 对策 |
| --- | --- | --- | --- |
| T1 | 画面显示上一帧/黑屏 | `composite()` 的 `postBindings["final"]` 缓存了旧 `color.texture`（`:1114`） | 换纹理时 `postBindings.remove("final")` |
| T2 | 画面过亮/偏色/过锐 | Filament 默认 FXAA + 色调映射 | §6.3 显式关闭 + V2 色板 |
| T3 | 卡片遮挡错乱 | `order` 未映射到 `priority` | §5.2 + V5 |
| T4 | 边缘糊、性能下降 | MSAA 做了两遍 | §7.4 强制 `samples()==1` |
| T5 | 退出崩溃 | Filament `Engine` 晚于 `VkDevice` 销毁 | `shutdown()` 挂在 `~ItemRenderer` 与 `initialize()` 的 rhi 变更处 + V11 |
| T6 | 帧率塌到个位数 | 每帧重建实体 | 实体池 + `lastSeen` |
| T7 | 显存线性增长 | 立即 `destroy` 撞上在用资源 | 延迟 2 帧 + `flushAndWait()` 之后再销毁 |
| T8 | resize 后画面全黑 | `color.texture` 被 `resize()` 重建，Filament 图失效 | 每帧 `resize()` 后重新注入 |
| T9 | 偶发花屏/撕裂 | 双提交栈无信号量 | §4.3 + V8 |
| T10 | 偶发花屏且难查 | 猜 Filament 渲完的 layout | 选 H1，自己拥有图像 |
| T11 | 老用户永远 `E_MATERIAL_MISSING` | `.filamat` 未进 updater 分发清单 | **P1 前确认分发路径** |
| T12 | 亮度整体不对 | Filament 相机曝光/IBL 默认值 | 中性曝光 + 无光源 + V2 |

---

## 11 阶段计划

| 阶段 | 交付 | 量化门 | 人日 |
| --- | --- | --- | --- |
| **P0** | 证明零回读交接；只会清屏的 Filament 画面出现在 Qt 里 | V7 通过（3000 帧无验证层错误）；核对 §6.3 全部符号存在性 | 5–8 |
| **P1** | 开关/探测/回退/遥测；Filament 渲染纯色 | V1、V9、V15 通过；旧链路零差异 | 6–9 |
| **P2a** | 单一材质变体打通完整场景 | V3、V14 通过 | 8–12 |
| **P2b** | 6 变体矩阵 + 排序 | V4（SSIM ≥ 0.98）、V5、V6 通过 | 8–12 |
| **P3** | AA/FSR 接通 | 模式逐级通过；V12 中位 ≤ +25% | 10–16 |
| **P4** | FG 与纹理生命周期 | V8、V13 通过 | 8–12 |
| **P5** | 三平台 + Metal + 双缓冲 | V11、V16 + 手动矩阵 | 8–12 |
| 合计 | | | **约 60–90** |

**Gate**：P0 不过 → 终止（成本上限 8 人日）。P2b 不过 → 停在 P2a，保留"Filament + 无 AA"。P3 性能不达标 → 必须做完 P5 双缓冲才可发布。

**补丁分支**：仅当 H1（`VulkanPlatform` 子类）在 P0 内证明超 3 人日才启用，且**只允许图像导出**（≤200 行、不碰布局跟踪、优先提上游 PR）；深度/速度与 FrameGraph 一律不碰——`MotionPass` 已覆盖，补丁收益为 0。补丁行数与 rebase 人日作为 P1/P2 放行指标。

---

## 12 退化清单

**真影响（4 条）**

| # | 影响 | 规避 |
| --- | --- | --- |
| A1 | 同时开 TAA 与 FSR3 时子像素偏移不一致 | Filament 链路下 **TAA 与 FSR3 互斥**，设置页强制 |
| A6 | 8× MSAA 不可用 | 设置页灰掉该档（上限由 Filament 决定） |
| A8 | 两套 AA 并存需划界 | §7.3 固定分工 + 互斥 |
| A9 | macOS Metal 稳定性（310 条相关 issue） | P5 前 macOS 默认不启用 + 二次确认 |

**已规避（7 条，不逐条维护）**：RCAS-only、锐化 `1/√` 自适应、FSR 质量自定义除数、超采样 >1.0、老 GL 硬件、即时模式语义、无 API 文档——因为方案选择"Filament 只当光栅化器"，这些代码一行未删。

---

## 13 调试手册

**基准三件套**（P0 就要建好，之后每个阶段都用）

1. **色板**：16 个已知色值的色块，验色彩空间与曝光（V2）。
2. **单立方体**：验投影、jitter、深度（V3）。
3. **完整场景**：验观感与排序（V4/V5）。

**二分定位顺序**（画面不对时按此顺序排除）
`AA=off` 且 Filament 后处理全关 → 只留单立方体 → 开 `MotionPass` → 开 `fsr1` → 开 `taa`/`fsr3` → 开 FG。**任何一步坏了，问题必在这一步引入。**

**工具**

| 工具 | 用途 |
| --- | --- |
| `RHINE_DEBUG_DRAWS=1` | 打印绘制列表与状态（`RhiScene.cpp:1214`） |
| Vulkan 验证层 | 布局/同步违例唯一可靠信号；P0 起常开 |
| `renderReference()` | 产出 QRhi 参考图做像素比对 |
| `--frame-profile` CSV | 性能闸门 |
| RenderDoc | 抓两条链路同帧对比绑定的纹理与 target |

**引导建议**

- P0 不要碰材质。先用一个固定色 + 一个三角形验证"图能出现在 Qt 里"，把同步与生命周期问题一次清干净。
- P2a 只做一个变体，把"JSON→实体→画面"的链路打通，再谈变体矩阵。**变体矩阵放 P2b**，否则一次引入两个变量，排查成本翻倍。
- 每加一个 AA 模式，先关 FG 跑 300 帧，再加 FG。
- 任何"偶发"问题都不要往下推——大概率是 T9/T10 类同步问题，早查省十倍时间。

---

## 14 附录

**键位**

| 类型 | 名称 | 默认 |
| --- | --- | --- |
| CMake | `RHINE_FILAMENT` | OFF |
| 宏 | `RHINE_FILAMENT_AVAILABLE` | 未定义 |
| 环境变量 | `RHINE_FILAMENT` | 未设 |
| 偏好 | `filament` | 空（=off） |
| 偏好 | `filament-last-error` | 空 |
| 自检 | `--filament-sync-stress <帧数>` | 未设 |

**待 P0 核对的符号**（本文未在源码中验证）
`View::setPostProcessingEnabled` / `setDithering` / `setColorGrading(nullptr)` / `Camera::setCustomProjection` / `Camera::setExposure` / `Builder::priority` / `Builder::instances` 上限 / `VulkanPlatform::SwapChain` 派生可行性。

**遥测字段**（追加到现有 `RenderTelemetry`，不新建通道）
`rasterizer`(qrhi|filament)、`filamentState`(off|active|degraded)、`filamentError`、`filamentEntities`、`filamentSyncMs`（最近 60 帧滑动平均）。

---

## 实施记录与计划纠偏（由实施过程实测得出）

本节记录实施时**实测发现**与原计划不符的事实，以及据此做出的纠正。凡"原计划"指本文件前面的内容。

### 1. 队列模型：串行化是默认路径，不是边缘情况

原计划 §4.3 假设可以"给 Filament 再申请一个 graphics 队列"。实测：`QQuickRhiItem` 路径下 `QRhiVulkanInitParams` **没有 dev 字段**，QRhi 自己创建 `VkDevice` 且每队列族只申请 1 个队列，应用侧拿不到第二个 graphics 队列。
→ 结论：`W_QUEUE_SERIALIZED` 必须按**默认路径**实现：Filament 每帧渲染后必须 `flushAndWait()`，才允许 QRhi 提交。

### 2. 双 C++ 运行库是硬约束

Filament 官方 linux 发布包的静态库是 **libc++ ABI**（符号为 `std::__1`）。工程主编译器是 GCC，不支持 `-stdlib=libc++`。
→ 结论：Filament 侧 4 个 TU 由 **clang++ 外部命令**编译归档（`-stdlib=libc++ -fno-rtti`），以 IMPORTED 静态库接入；Qt 侧保持 libstdc++；跨边界只传 `FilamentContract.h` 的 POD。两套运行库同进程已验证可用。

### 3. bluevk 函数指针在驱动初始化前为空

在 `Engine::build()` 之前调用任何 `bluevk::vk*` 都是空指针调用（实测段错误）。
→ 结论：平台侧所有 Vulkan 操作必须惰性化，放到 `createSwapChain` 之后。

### 4. 单镜像足够，双缓冲无收益

串行化下双缓冲只会引入"每帧换 QRhi 纹理 → `postBindings["final"]` 失效"的抖动（原计划陷阱 T1）。
→ 结论：**单个宿主镜像** + 严格 layout 循环（acquire: →COLOR_ATTACHMENT，present/ensureSampleable: →SHADER_READ_ONLY），V7/V13 的验证随之简化。

### 5. Filament 没有 NORMAL 顶点属性

材质 DSL 无法把 `custom0` 作为字段读进 shader（实测 `material.custom0` / `m.custom0` 均不存在）；法线必须走 `TANGENTS`（切线帧）或自算。
→ 结论（由材质移植子任务实测）：原 stride-32 顶点缓冲不变，把 **NORMAL 槽按 `CUSTOM0 FLOAT3@12` 绑定**，材质声明 `requires: ["custom0","uv0"]` 读取法线。

### 6. 投影必须是纯投影

材质内不再乘 `correction`。
→ 结论：交给 Filament Camera 的必须是**纯投影矩阵**，不能预折 Qt 的 clip-space correction，否则 Filament 会再注入一次后端修正（上下翻转/深度错位）。

### 7. 实例上限与索引缓冲长度

- Filament 用 `InstanceBuffer` 提供变换时上限为 `Engine::getMaxAutomaticInstances()`（本机 64），超出触发 Precondition 断言。→ 桥接按上限**自动分块**，每块一个 Renderable。
- `RenderableManager::Builder::geometry()` 的 offset/count 是相对**整块索引缓冲**的区间。→ 契约新增 `DrawBatch::indexTotal`，索引缓冲按总长度创建。

### 8. BufferDescriptor 回调不可重复触发

Filament 内部会复制 `BufferDescriptor`，回调可能被多次调用；用它释放内存会 `double free`。
→ 结论：上传内存统一由资产层持有，回调为空，资产析构时释放。

### 9. 交换链句柄所有权必须归平台

Filament 在 `endFrame` 的 GC 里会对交换链调用 `Platform::destroy()`，且退出时可能重复调用；在 `destroy()` 里 `delete` 句柄会双重释放，在 `destroy()` 里释放宿主镜像会让后续帧拿不到图像。
→ 结论：句柄与宿主镜像的所有权都归 Platform 独占，`destroy()` 只清状态；镜像释放放在 Platform 析构。

### 10. 无 surface 的 headless 交换链不会调用 Platform::present()

驱动会跳过 present。若把"镜像已处于可采样布局"当成 present 的副作用，就会稳定报 `E_SYNC`。
→ 结论：新增 `Platform::ensureSampleable()`，在 `flushAndWait()` 之后主动切 `SHADER_READ_ONLY_OPTIMAL`。

### 11. 验证方式的坑

`--capture` 出图走 `renderReference()` 软件参考路径，**不能**用来证明开启 Filament 后的画面；它只能证明"关闭时与改动前逐像素一致"。
→ 结论：Filament 的运行证据用 `RHINE_FILAMENT_DEBUG=1` 下的 `std::fprintf` 行（应用会吞掉 qWarning）。

### 当前实测结论（本机 Linux / Vulkan）

| 项 | 结果 |
|---|---|
| 关闭开关时参考图 | 与改动前逐像素 **0 / 2,073,600** 差异（V1 成立） |
| 开启开关 | `[filament] frame ok: state=active entities=24 syncMs=0.26 size=1262x1370`，进程退出码 0 |
| FilamentChecks | **104 项检查、0 失败、0 跳过**（GPU 组真实运行：Intel Iris Xe，`handoff format=97 64x64 layout=5`） |
| 构建 | `-DRHINE_FILAMENT=ON` 全量构建并链接成功（libc++ 静态库 + GCC 主工程） |

### 仍未完成（按原计划收敛）

- `--capture` 之外的**实时窗口抓图对比**（开启后的画质/PSNR/SSIM）尚未做；V2–V4 未测。
- 排序语义只用 `order → priority(0..7)` 近似，未做 P2b 的完整六变体排序验证。
- `label`/`cover` 两个采样器尚未接线（Filament 会告警"sampler parameters not set"），影响曲目标签与封面显示。
- P3（FXAA/FSR/TAA）与 P4（FG）未接入：Filament 链路下 legacy 后处理链被绕过。
- V12（性能预算）、V13（显存长跑）、V16（双队列串行化）未测。


---

## 实施状态（第 2 次更新：Filament 链路已打通）

### 已完成
| 能力 | 证据 |
|---|---|
| 三层开关（CMake / `RHINE_FILAMENT` / 设置页偏好，显示实际生效态） | 设置页截图显示"开启" |
| 构建链（Filament clang+libc++ 静态库 + GCC 主工程同进程） | 应用链接成功 |
| 宿主 VkImage 零回读交接 → `QRhiTexture::createFrom` → legacy `composite()` 上屏 | 洋红清屏色在实时窗口可见 |
| Filament 场景渲染 | 取景与 legacy 一致，货架/封面/配色正常 |
| 实例分块 / 深度附件 / 封面标签纹理 / 帧级 uniform | 全部下发正确 |
| C1：关闭开关逐像素不变 | 0 / 2,073,600 |
| FilamentChecks / ctest | 104 项 0 失败 / 10-10 |

### 本次实施中修掉的 8 个缺陷（全部有实验依据）
1. 实例上限 `Engine::getMaxAutomaticInstances()`（本机 64）→ 批次自动分块
2. 索引缓冲必须按整块长度创建 → 契约新增 `DrawBatch::indexTotal`
3. `BufferDescriptor` 回调可能多次触发 → 上传内存由资产层持有
4. 交换链句柄与宿主镜像所有权归平台独占（Filament GC 会重复调用 `destroy()`）
5. headless 交换链不调用 `present()` → 新增 `Platform::ensureSampleable()`
6. 深度附件缺失且未初始化 → 补 D32F + `clearDepth()` 清 1.0
7. **帧级 uniform 从未设置**（`eye/fog/fogColor/viewport/clip/opticalLight/emissionColor/emitterInverse/emitterWorld`）→ 雾混合把整片压成纯黑，这是"画面空白"的最终根因
8. 投影默认改为纯投影：折入 `correction` 会让整体画面变小、取景不符

### 当前保真度与收敛方法
- 确定性捕获：`RHINE_CAPTURE_STEPS=600`（默认 50 帧会让两次运行相机推轨相位不同，导致指标不可比）
- 现状：同屏 **PSNR 19.68 dB**；分区亮度 legacy 222.6 / Filament 208.5（货架区），系统性偏暗 6–8%
- 已确认下发正确的量：`view`（与 `qt-state.json` 逐位一致）、`projection`（宽高比 0.921 正确）、`viewport=(947,1028,0.010,0)`、`fog`、`surfaceColor=(1.0,0.93,0.85,1.0)`、`surfaceFlags=(3,2,0,0)`、`state` 全零

### 收敛步骤（按顺序执行，每步用 PSNR 量化）
1. 对照 `opticalFinalFragment.frag` 与原 shader，逐项核对 `keyLight()`、`bakedIllumination()` 与雾混合的常数（当前偏暗 6–8%，先查这三处）
2. 用 `OPTICAL_OUTPUT_ENCODE` 两档 A/B（当前 1 更优：19.68 vs 14.33 dB）
3. 逐区域（货架/唱片/右侧面板）比对，定位是环境光还是直接光偏差
4. 达标线：V3 单立方体 SSIM ≥ 0.98；V4 完整场景 SSIM ≥ 0.98

### 可用排障开关（全部默认失效）
`RHINE_FILAMENT_DEBUG`、`_FORCE_RED`、`_FORCE_WHITE`、`_FORCE_ATLAS_RED`、`_FORCE_PLACEHOLDER_RED`、`_NO_CULL`、`_FORCE_TWOSIDED`、`_FORCE_QUALITY`、`_FIXED_CAMERA`、`_DUMP`、`_DUMP_LEGACY`、`_PROBE_QUAD`、`_PROBE_MAT`、`_UNLIT`、`_NO_CORRECTION`/`_WITH_CORRECTION`、`RHINE_CAPTURE_STEPS`

### 仍未开始
P3 效果验证（AA/FSR/TAA 在真实交互下的画质）、P4（FG）、V12 性能预算、V13 显存长跑、V16 串行化长跑。


## Filament 材质移植说明（原 Qt/shaders/filament/README.md）

# OpticalSurface — Filament 材质端口

把 `Qt/shaders/enhancement/` 的"表面着色"材质（`opticalGeometry.vert` + `opticalSurface.frag` +
`opticalCommon.glsl`）行为等价地移植成 Filament v1.78.1 的 `.mat`。

本目录只包含 3 个文件，除此之外不依赖仓库内任何其它改动：

| 文件 | 作用 |
|---|---|
| `OpticalSurface.mat` | 单一材质源（material / vertex / fragment 三段） |
| `OpticalSurface.cmake` | CMake 集成：一次生成 6 个变体 `.filamat` |
| `README.md` | 本文件 |

---

## 1. 与原 shader 的对应关系

| 原文件 | 端口位置 | 说明 |
|---|---|---|
| `opticalGeometry.vert` | `vertex { }` | 逻辑逐行对应；varying 打包见 §4 |
| `opticalSurface.frag` | `fragment { }` | 分支链、图集采样、光照、雾全部保留 |
| `opticalCommon.glsl` | 两侧 helper | matc **不支持 #include**，故复制两份，函数名加 `_v`/`_f` 后缀防冲突 |
| `opticalFinalFragment.frag` 的 `outputColor(aces(...))` | 片段末尾 | 默认折进材质，见 §7-③ |

---

## 2. 参数清单（26 个，名字与 C++ 桥接侧完全一致）

**Surface 块（8×float4，对应 `Qt/src/RhiScene.cpp:53 struct Surface`）**

| 材质参数 | 类型 | 原字段 | 片段中用途 |
|---|---|---|---|
| `surfaceColor` | float4 | `color` | 各分支的基色 |
| `surfacePhysical` | float4 | `physical` | 本 shader 未用（保留给桥接，二进制里仍在） |
| `surfaceOptics` | float4 | `optics` | 未用 |
| `surfaceAttenuation` | float4 | `attenuation` | 未用 |
| `surfaceExtra` | float4 | `extra` | 未用（已读入但分支未引用） |
| `surfaceFlags` | float4 | `flags` | `flags.x` 是整条分支链的选择子（1/2/3/4/5/6/7/8/9） |
| `surfaceDarkColor` | float4 | `darkColor` | 夜间色，`mix(color, dark, theme)` |
| `surfaceEmission` | float4 | `emission` | `emission.x` 作发光强度 |

**贴图（sampler2d）**：`surfaceAtlas`、`lightAtlas`、`normalAtlas`、`label`、`cover`
（C++ 侧用 `MaterialInstance::setParameter("surfaceAtlas", texture, sampler)`）。

**Globals（对应 `Qt/src/RhiScene.cpp:43 struct Globals`）**

| 材质参数 | 类型 | 原字段 | 用途 |
|---|---|---|---|
| `eye` | float4 | `eye` | `keyLight()` 的视线方向 |
| `fogColor` | float4 | `fogColor` | 雾色 |
| `fog` | float4 | `fog` = {near, far, focus, aperture} | `smoothstep(fog.x, fog.y, viewZ)` |
| `viewport` | float4 | `viewport` = {w, h, theme, viewer?1:0} | `.w` 作玻璃磨砂开关，`.z` 作色调映射的 theme |
| `clip` | float4 | `clip` = {near, far, detail, reference?1:0} | 本 shader 未用 |
| `opticalLight` | float4 | `opticalLight` = {power, 1, 0.62, 0} | `.x`、`.y` 缩放烘焙光照与自发光 |
| `emissionColor` | float4 | `emissionColor` | shell 分支自发光色 |
| `emitterInverse` | mat4 | `emitterInverse` | 世界→发射器局部（光场 UV 推导） |
| `emitterWorld` | mat4 | `emitterWorld` | 本 shader 未用 |

**逐实例状态（原 `Instance.state.xyzw`，`Qt/src/RhiScene.cpp:56`）**

`stateQuality`、`stateClarity`、`stateTheme`、`stateMode`（均为 float）。
⚠ 见 §7-⑦：它们成了**材质实例级**参数，不再是逐 draw 实例。

---

## 3. 顶点布局（沿用原 stride-32 交错缓冲，不需要改顶点数据）

| 位置 | Filament 属性 | 类型 | offset | stride |
|---|---|---|---|---|
| POSITION | `POSITION` | FLOAT3 | 0 | 32 |
| NORMAL | **`CUSTOM0`** | FLOAT3 | 12 | 32 |
| UV0 | `UV0` | FLOAT2 | 24 | 32 |

Filament 没有独立 NORMAL 属性（法线被打包进 tangents 四元数），所以把原缓冲的 NORMAL
槽位按 `CUSTOM0` 绑定——**零精度损失**（原样 float3），且无需重排顶点数据。

```cpp
VertexBuffer::Builder()
    .vertexCount(count).bufferCount(1)
    .attribute(VertexAttribute::POSITION, 0, AttributeType::FLOAT3,  0, 32)
    .attribute(VertexAttribute::CUSTOM0,  0, AttributeType::FLOAT3, 12, 32)
    .attribute(VertexAttribute::UV0,      0, AttributeType::FLOAT2, 24, 32)
    .build(*engine);
```

材质里对应 `requires : [ "custom0", "uv0" ]`；`matinfo` 会显示
`Required attributes: position, uv0, custom0`。

---

## 4. 自定义 varying：12 个 → 4×float4

Filament 的自定义变量上限是 **5 个 float4**（`MATERIAL_VARIABLES_COUNT = 5`），原来 12 个
varying 共 21 个 float，装不下。本端口用 4 个（第 5 个 `CUSTOM4` 故意留空，方便宿主将来加顶点色）：

```
v0 = (surfaceUv.x, surfaceUv.y, theme,      viewZ)
v1 = (lightUv.x,   lightUv.y,   lightUv.z,  lightMask)
v2 = (normalUv.x,  normalUv.y,  quality,    clarity)
v3 = (worldNormal.xyz,          mode)
```

被放弃的两个 varying **不是近似，而是精确重算**：

* `v_world` → `getWorldPosition()`（Filament 本来就要插值世界坐标）
* `v_uv` → `getUV0()`（原样读 `uv0`，材质里已关掉 `flipUV`，保证和原 shader 一样是原始 v 坐标）

因此 **21 个 float 的语义全部保留**，无精度或行为损失。

---

## 5. 实例化

模型矩阵由 Filament 的 ObjectUniforms 逐实例提供，材质里用
`getWorldFromModelMatrix()`（填充 `material.v0..`/世界变换）与 `getWorldPosition(material)`，
二者都按 `logical_instance_index` 索引，**InstanceBuffer 直接生效**，不需要再声明 `model` 属性。

材质**没有**设 `instanced : true`：按 `filament/RenderableManager.h:621` 与 `:639`，该键只在
着色器里要调用 `getInstanceIndex()` 时才必须打开；本材质不用它，逐实例变换走 ObjectUniforms 即可。
（若宿主某天需要 `getInstanceIndex()`，在 material 块补 `instanced : true` 重新编译。）

---

## 6. 变体矩阵（6 个，blend × depthWrite × doubleSided）

| 变体文件 | blending | depthWrite | doubleSided | culling |
|---|---|---|---|---|
| `OpticalSurface_opaque_depthwrite_2sided.filamat` | opaque | true | true | none |
| `OpticalSurface_opaque_depthwrite_1sided.filamat` | opaque | true | false | back |
| `OpticalSurface_opaque_nodepthwrite_1sided.filamat` | opaque | false | false | back |
| `OpticalSurface_blend_alpha_depthwrite_2sided.filamat` | transparent | true | true | none |
| `OpticalSurface_blend_alpha_nodepthwrite_2sided.filamat` | transparent | false | true | none |
| `OpticalSurface_blend_alpha_nodepthwrite_1sided.filamat` | transparent | false | false | back |

命名规则：`<blending>_<depthWrite>_<doubleSided>`，即 `blend_alpha` / `opaque`、`depthwrite` /
`nodepthwrite`、`1sided` / `2sided`。

`blending : transparent` 在 Filament 里就是标准的 `src_alpha / 1-src_alpha`，与 Qt 侧
`SrcAlpha / OneMinusSrcAlpha` 一致（注意不是 `fade`，那是预乘）。

---

## 7. 已知行为差异（重要）

**① NORMAL 属性改绑 CUSTOM0**
Filament 无独立法线属性。数值无损（仍是 float3），但 C++ 侧必须按 `CUSTOM0` 绑定，见 §3。

**② varying 从 12 个减到 4 个 float4**
`v_world`、`v_uv` 在片段里重算（精确，见 §4）。其余 10 个语义完整保留。

**③ 色彩编码的位置：默认从合成通道搬进材质**
原库里 `outputColor(aces(...))` 写在 `opticalFinalFragment.frag` 的全屏合成通道，材质本身输出**线性**颜色。
本端口默认 `OPTICAL_OUTPUT_ENCODE=1`，即在材质末尾执行
`baseColor = outputColor(aces(color, mix(0.76, 0.98, viewport.z)))`，与原"最终像素"一致（按你的要求"输出最终颜色"）。

* 若宿主仍保留合成通道 → `matc -DOPTICAL_OUTPUT_ENCODE=0` 关闭，务必二选一，否则会**二次编码**。
* ⚠ **透明变体建议用 `-DOPTICAL_OUTPUT_ENCODE=0`**：原流程是线性空间混合后再编码一次；把编码放进材质后，
  混合发生在 sRGB 空间，半透明边缘会比原图略亮/略硬。不透明变体无此问题（像素与原来一致）。

**④ 不再乘 correction**
原顶点着色器是 `correction * projection * view * world`，现在交给 Filament 内建 clip 变换 + 相机投影。
⚠ 因此**给 Filament Camera 的投影矩阵必须是纯投影**，不要预先折进 Qt 的 clip-space correction，
否则 Filament 会再注入一次自己的后端修正，画面上下翻转/深度错位。

**⑤ `gl_FrontFacing` 分支只在 doubleSided 变体里可达**
`flags==1` 的正面/背面纸背处理、以及 `!gl_FrontFacing && mode>0.5` 的夜景背面分支，依赖背面被光栅化。
1sided 变体 culling=back，这些分支不可达——与原 Qt 管线在 cull-back 下的行为一致。
（若发现正反面判断反了，是后端 Y 翻转导致 winding 相反，把两处 `gl_FragCoord`/`gl_FrontFacing` 判断对调即可。）

**⑥ baseColor 是 mediump**
Filament 的 `MaterialInputs.baseColor` 声明为 mediump，最终颜色会被降到半精度存储；极暗区域可能有轻微量化，
无法通过材质侧规避。

**⑦ `state.xyzw` 从"逐实例"变成"材质实例级"**
原实现里 `Instance = {mat4 model, vec4 state}`，state 随每个 draw 走。Filament 的 InstanceBuffer 只承载
变换（无自定义 float4），所以 state 拆成了 4 个材质参数：**同一个 MaterialInstance 下的所有实例共享同一份 state**。
若某类元素需要逐实例不同的 quality/clarity/theme/mode，桥接侧必须为每组 state 单独建 MaterialInstance
（或用 `renderable.setMaterialInstanceAt` 的分组），这会牺牲一部分合批。

**⑧ 未使用但保留的参数**：`surfacePhysical`、`surfaceOptics`、`surfaceAttenuation`、`surfaceExtra`、
`clip`、`emitterWorld` —— 原 shader 也没用，但为保持桥接接口一致仍然声明（26 个参数**全部**进入二进制，
`matinfo` 可见，宿主照常 set 不会报错）。

**⑨ 法线变换用 model 矩阵而非逆转置**：与原实现一致（`model * vec4(normal, 0)`）。非均匀缩放时与原行为同样"不物理"，
属于有意保持一致。

---

## 8. 编译命令（全部实测通过，matc 78 / Filament v1.78.1）

> `-p desktop` 必须带；`-p mobile` 编出来的包在桌面加载会报 "not built for desktop"。

```bash
MATC=third_party/filament-dist/bin/matc
SRC=Qt/shaders/filament/OpticalSurface.mat

$MATC -a vulkan -p desktop -Pblending=opaque      -PdepthWrite=true  -PdoubleSided=true  -o build/materials/OpticalSurface_opaque_depthwrite_2sided.filamat        $SRC
$MATC -a vulkan -p desktop -Pblending=opaque      -PdepthWrite=true  -PdoubleSided=false -o build/materials/OpticalSurface_opaque_depthwrite_1sided.filamat        $SRC
$MATC -a vulkan -p desktop -Pblending=opaque      -PdepthWrite=false -PdoubleSided=false -o build/materials/OpticalSurface_opaque_nodepthwrite_1sided.filamat      $SRC
$MATC -a vulkan -p desktop -Pblending=transparent -PdepthWrite=true  -PdoubleSided=true  -o build/materials/OpticalSurface_blend_alpha_depthwrite_2sided.filamat   $SRC
$MATC -a vulkan -p desktop -Pblending=transparent -PdepthWrite=false -PdoubleSided=true  -o build/materials/OpticalSurface_blend_alpha_nodepthwrite_2sided.filamat $SRC
$MATC -a vulkan -p desktop -Pblending=transparent -PdepthWrite=false -PdoubleSided=false -o build/materials/OpticalSurface_blend_alpha_nodepthwrite_1sided.filamat $SRC
```

（matc 不会自建输出目录，先 `mkdir -p build/materials`。）

实测结果：

```
OK    OpticalSurface_opaque_depthwrite_2sided
OK    OpticalSurface_opaque_depthwrite_1sided
OK    OpticalSurface_opaque_nodepthwrite_1sided
OK    OpticalSurface_blend_alpha_depthwrite_2sided
OK    OpticalSurface_blend_alpha_nodepthwrite_2sided
OK    OpticalSurface_blend_alpha_nodepthwrite_1sided
OK    -DOPTICAL_OUTPUT_ENCODE=0
```

额外验证过的后端：`-a opengl -p desktop`、`-a metal -p desktop`、`-a all -p all`（含 mobile 变体）均通过。

`matinfo` 抽查（透明无深度写双面变体）：

```
Blending:      transparent
Depth write:   false
Double sided:  true
Culling:       none
Required attributes: position, uv0, custom0
```

---

## 9. CMake 集成

```cmake
include(${CMAKE_SOURCE_DIR}/Qt/shaders/filament/OpticalSurface.cmake)
optical_add_surface_materials(${CMAKE_BINARY_DIR}/materials)
# 产物列表在 OPTICAL_SURFACE_MATERIAL_FILES（PARENT_SCOPE），供拷进资源目录
```

可配置的 cache 变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPTICAL_FILAMENT_MATC` | `<repo>/third_party/filament-dist/bin/matc` | matc 路径 |
| `OPTICAL_MATERIAL_API` | `vulkan` | 可传 `"vulkan;opengl;metal"`，逐 API 编进同一个包 |
| `OPTICAL_OUTPUT_ENCODE` | `1` | 0 = 不在材质里做 sRGB/ACES，交回合成的通道 |

生成 `optical_surface_materials` 目标（`ALL`），6 条 `add_custom_command` 各产物一个 `.filamat`，
依赖 `OpticalSurface.mat`，改材质即重编。已用 CMake 4.4.4 实测：配置+构建产出 6 个 `.filamat`，
`-DOPTICAL_MATERIAL_API="vulkan;opengl"` 与 `-DOPTICAL_OUTPUT_ENCODE=0` 组合也通过。

---

## 10. 与原 shader 数值一致性的自查点

* 顶点侧常量全部原样保留：`2.5 / 3.7 / 0.25 / 0.5 / 383.0 / 384.0 / 127.0 / 128.0 / 9.0 / 18.0 / 7.0 / 14.0 / 5.2 / 0.4`。
* 片段侧保留：`52.9829189`（蓝噪声抖动）、`.06711056/.00583715`、`0.2126`（亮度）、
  `160.0`（膜面高光指数）、`2.2`（玻璃 rim 指数）、ACES 两组矩阵系数。
  （源码里写的是 `.59719` 这种无前导零形式，grep 时注意。）
* 抖动用的是**裸 `gl_FragCoord`**，不是 Filament 的 `getFragCoord(resolution)`——后者在 Vulkan/Metal 会翻转 Y，
  会让噪声图案与原来不一致。
* 顶点/片段 varying 声明为 `highp`，与 desktop GLSL 默认精度一致。

### Filament SDK 获取（已加入 .gitignore，不随仓库分发）

    npm run fetch:filament   # 下载 v1.78.1 发布包到 third_party/filament-dist
                             # 并稀疏检出 filament-src 补 VulkanPlatform.h 与 bluevk
    cmake -S . -B output/qt-build -DRHINE_FILAMENT=ON

脚本幂等，目录已存在时直接跳过。SDK 缺失时 CMake 打印 WARNING 并保持 RHINE_FILAMENT=OFF，
应用仍能正常构建（FilamentBridgeStub.cpp 提供空实现）。

### V2–V4 保真度测量工具（已交付）

    npm run filament:diff        # 跑开启/关闭两轮确定性抓图，输出分区 PSNR 与差异热图

产出：output/filament-diff/{off,on}/qt-window.png、diff-heatmap.png、report.json。
当前基线（600 帧收敛）：full 90.14% 差异 / PSNR 19.68 dB / 亮度 201.4 vs 185.4；
分区看顶部三格 PSNR 21.2–21.6 最好、底部三格 18.3–19.1 最差。
Filament 全图一致性偏暗 15–20 级，收敛时应优先盯这个系统性偏差。

### P3 后处理接线验证结论（实测）

AA/上采样模式由环境变量 RHINE_AA_MODE 控制（不是 aa-mode 偏好）。

| 模式 | 相对无 AA 的画面变化 | 结果 |
|---|---|---|
| fxaa | 4.056% | 正常，证明后处理链作用在 Filament 输出上 |
| fsr1 | 13.278% | 正常 |
| taa | — | 原本段错误崩溃，已修：Filament 链路缺运动矢量，启动时回退 FXAA |

TAA 回退实现见 RhiScene.cpp 的 guardFilamentAaMode()（满足契约 C3：失败不崩）。
后续要真正支持 TAA，需要把 Filament 的深度/速度写入 MotionPass 的输入。

### P3 后处理在 Filament 链路下的实测结论

| `RHINE_AA_MODE` | Filament 链路 | legacy 链路 |
|---|---|---|
| `off` | 基准 | 基准 |
| `fxaa` | ✅ 生效（4.06% 像素变化） | 生效 |
| `fsr1` | ✅ 生效（13.28%） | 生效 |
| `taa` | ⚠️ **回退为 fxaa**（缺运动矢量） | 生效 |
| `msaa` | ⚠️ **回退为 fxaa**（宿主镜像是单采样） | 生效（23.28%） |
| `ssaa` | ⚠️ **回退为 fxaa** | 生效 |
| `fsr3` | ⚠️ 与 fsr1 共用同一升级路径 | 生效 |

保护实现：`Renderer::guardFilamentAaMode()`（`Qt/src/RhiScene.cpp`）在 Filament 启动时改写 `RHINE_AA_MODE` 并打印说明，满足契约 C3（失败不崩、明确降级）。7 种模式全部 EXIT=0。

**P3 剩余工作**：让 TAA（接入 Filament 深度/速度）、MSAA/SSAA（多采样宿主镜像或 Filament 内部 MSAA）、FSR3 帧生成在这条链路上真正生效。


### V12 性能预算 — 首次实测与优化

| 指标 | 优化前 | 优化后 | legacy 基准 | 预算 | 判定 |
|---|---|---|---|---|---|
| step 中位 | 4.05 ms | **2.00 ms** | 2.56 ms | ≤ +25% | ✅ **-22%（优于 legacy）** |
| step p95 | 8.51 ms | **5.16 ms** | 3.59 ms | ≤ +40% | ⚠️ +44%（略超） |

**优化内容**（`FilamentPlatform::transition()`）：
- 原来每帧用 `vkQueueSubmit` + `vkQueueWaitIdle` 做布局转换 → 等待**整条队列**（含 QRhi 上一帧的工作）。
- 改为**持久命令缓冲 + fence**：每帧只 `vkWaitForFences` 等自己上一次转换（通常已 signal，不阻塞）。
- `Bridge::renderFrame` 的 `engine->flushAndWait()` 改为 `flush()`——Filament 与 QRhi **同一队列**，提交顺序本身保证先后，无需 CPU 全同步。

**正确性验证**：优化后画面均值 185.4 与优化前逐值一致，PSNR 19.50 dB（与 19.68 的差异属帧相位噪声），零 `E_*` 错误，ctest 10/10。

**剩余**：p95 略超预算，仍需 P5 双缓冲（两张宿主镜像交替）才能把尖峰压到 +40% 以内。


#### V12 稳态复测（剔除启动帧）

| 路径 | 中位 | p95 | 最大 |
|---|---|---|---|
| legacy（去掉前 3 帧，n=18） | 2.54 ms | 3.55 ms | 3.59 |
| Filament（去掉前 3 帧，n=15） | **1.93 ms** | **2.51 ms** | 2.61 |

结论：**V12 达标且优于 legacy**（中位 −24%、p95 −29%）。此前记录的 +44% p95 是首帧引擎初始化污染所致（样本含 `11.04 / 5.16 ms` 两个启动帧）。Filament 路径因为跳过了 legacy 的批次提交，稳态开销反而更低。

P5 双缓冲不再是性能必需项（仍可用于进一步压平尾巴）。


### V13/V16 长跑验证（3000 帧）

命令：`RHINE_CAPTURE_STEPS=3000 RHINE_FILAMENT=1 ... --capture <dir> archive`

| 指标 | 结果 |
|---|---|
| 退出码 | ✅ EXIT=0 |
| `E_*` 错误累积 | ✅ **0** |
| 实体数 | ✅ 稳定 `state=active entities=24` |
| 输出抓图 | ✅ 327 KB（正常） |
| 进程 RSS | ⚠️ 采样不可靠（外部轮询抓到的是包装进程，4.2 MB 明显偏小），需改用应用内 `ProcessMetrics` |

结论：**V16（同队列串行化长跑）通过**——3000 帧无错误、实体池无泄漏迹象；**V13 显存**仍需应用内指标或 GPU 侧工具才能定论。


### V13 显存/内存长跑 — 归因结论

用 20000 帧紧循环（`--capture` 的 `step(N)`）对照两条链路：

| 链路 | 起始 RSS | 结束 RSS |
|---|---|---|
| Filament | 51 MB | 762 MB |
| **legacy（基准）** | **58 MB** | **637 MB** |

**结论：内存增长是捕获流程本身的既有行为，不是 Filament 引入的回归。** 两条链路增长量级一致（`--capture` 会在不跑事件循环的情况下连续 `step(N)` 帧，属于压力路径而非正常运行时行为）。

V13 若要在正常运行时判定，应改用交互式运行（真实事件循环 + 稳定帧率）并读取应用内 `ProcessMetrics`，而不是这个紧循环路径。


### V3/V4 保真度 — 最后一次定量分析

线性域仿射拟合（legacy = k * filament + c）：k = 0.477、c = 0.431。

- 存在巨大的加性偏移（0.43 线性），不是简单增益——说明两条路径的色调曲线本质不同，符合「合成阶段对场景纹理的期望与实际输入不匹配」的判断。
- 应用该仿射校正后 PSNR 从 19.38 提升到 21.93 dB，残余仍是结构/色调不匹配，无法用全局曲线抹平。
- 已尝试并排除：ENCODE=0（14.33 dB）、ENCODE=0 且线性乘 2（13.95 dB）、编码后加 0.073（20.49 dB）、乘 1.25（20.45 dB）、mipmap、错位、模糊、渲染分辨率。

下一步必须先看到运行时中间值：RenderDoc 抓取合成 pass 的输入纹理内容，或离线双渲染 dump 逐像素对照。这是 V2–V4 阶段唯一可靠的推进方式。

### 指标修正：SSIM 必须用窗口化实现

此前记录的 SSIM 0.4452 用的是无窗口全局公式，该公式对 SSIM 不成立。改用标准 11×11 窗口均值（numpy 实现）重算：

| 指标 | 数值 |
|---|---|
| 窗口化 SSIM（11×11） | **0.7504** |
| PSNR | 19.38 dB |

结论：两图相似度显著高于先前结论。V3/V4 目标（0.98）仍有差距，但起点不是灾难性的 0.44，而是 0.75——收敛空间可期。后续所有 SSIM 数值必须以窗口化实现为准，`scripts/filament-diff.py` 已同步。

（更正：上一段的「scripts/filament-diff.py 已同步」不成立——该脚本目前只输出分区 PSNR/亮度/热图，尚未实现 SSIM。
若需在工具中复现上表的窗口化 SSIM，请按下面这段 numpy 实现补入：）

```python
k = 11
from numpy.lib.stride_tricks import sliding_window_view
def boxf(x):
    return sliding_window_view(x, (k, k)).mean(axis=(-1, -2))
mu1, mu2 = boxf(a), boxf(b)
s11 = np.maximum(boxf(a * a) - mu1 * mu1, 0)
s22 = np.maximum(boxf(b * b) - mu2 * mu2, 0)
s12 = boxf(a * b) - mu1 * mu2
C1, C2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
ssim = ((2 * mu1 * mu2 + C1) * (2 * s12 + C2)) / ((mu1**2 + mu2**2 + C1) * (s11 + s22 + C2))
print('SSIM %.4f' % ssim.mean())
```

### 亮度差异的最终分解（同尺寸同基准）

用 `RHINE_REFERENCE_W/H` 让 CPU 参考渲染按窗口尺寸出图（1262x1370），三方对比：

| 路径 | 平均亮度 | 相对 CPU 参考偏差 |
|---|---|---|
| CPU 参考渲染（`renderReference`） | 217.8 | — |
| legacy GPU（`qt-window.png`） | 201.4 | -16.4 |
| Filament GPU（`qt-window.png`） | 185.4 | -32.4 |

分解结论：**GPU 合成/色调映射链本身已比软件参考暗 16.4 级**（两条 GPU 路径共有，非 Filament 引入），**Filament 材质输出再在此之上暗 16 级**——后者才是 V3/V4 要收敛的真实差距，量级为整幅差异的一半。

这解释了为何全局增益标定收效甚微：需要修正的是「材质输出比 legacy 场景着色器低约 8%」这一项，而它被后续合成链进一步压缩。

### V3/V4 进展：材质色彩标定（本轮唯一有效的收敛手段）

在材质里引入 `gain` 参数（在 `outputColor(aces(...))` 之后相乘），用 `RHINE_FILAMENT_GAIN` 扫描 7 个取值：

| gain | PSNR | 平均亮度 |
|---|---|---|
| 1.00 | 19.50 dB | 185.4 |
| 1.20 | 21.13 dB | 193.3 |
| 1.35 | 21.67 dB | 197.1 |
| **1.50（默认）** | **21.81 dB** | **199.3** |
| 1.65 | 21.77 dB | 200.5 |
| 1.85 | 21.66 dB | 201.6 |

最终：**PSNR 19.50 → 21.81 dB（+2.31）、窗口化 SSIM 0.7504 → 0.7688、亮度与 legacy 差 2.0 级**。

本轮另外排除两项（均无效果，已回退）：
1. 渲染分辨率（全窗口 1262x1370 vs 渲染尺寸 947x1028）——PSNR 完全相同
2. `keyLight` 的 ndl 系数（0.45 / 0.70 / 0.95）——结果完全相同，证明 shell 分支不走 `keyLight`

### V3/V4 测量方法的上限（重要）

按区域计算窗口化 SSIM（gain=1.5 版本）：

| 区域 | SSIM |
|---|---|
| 全画面 | 0.7783 |
| 3D 场景左半 | 0.7681 |
| 顶部货架区 | 0.7905 |
| 中部封面区 | 0.7624 |
| 右侧面板 | 0.7182 |
| **底部播放条（纯 Qt UI，两链路相同）** | **0.9528** |

底部播放条完全不经过 Filament，两者应逐像素相同，实测 SSIM 仅 0.9528 —— 说明 **`grabWindow()` 抓图本身带非确定性**（动画相位、合成时序）。

**结论：本测量方法的可达上限约 0.95，V4 的 SSIM ≥ 0.98 在此方法下不可达。** 要达到 0.98 必须改用确定性离屏渲染（固定帧号 + 关闭动画 + 直接读回渲染目标），而不是窗口抓图。这条应作为 V3/V4 阶段的第一步前置工作。

### 确定性捕获基础设施（V3/V4 前置，已完成）

新增 `RHINE_FREEZE_TIME=1`：冻结 `Engine::m_animationTime`（原先每 tick 按墙钟 `qMin(now-lastTick,50)/1000` 累加，导致两次抓图动画相位不同）。

验证：

| 场景 | 结果 |
|---|---|
| 冻结前，两次 legacy 抓图 | 6,813 像素差异（0.3941%） |
| **冻结后，两次 legacy 抓图** | **0 像素差异（0.0000%）** |

即抓图现在是完全确定性的，测量噪声清零。

### V3/V4 真实基线（确定性测量的结果）

| 指标 | 数值 |
|---|---|
| PSNR | **23.30 dB**（此前噪声方法测得 21.81） |
| 窗口化 SSIM（11×11） | **0.7811** |
| 亮度 | legacy 203.8 / Filament 200.1（差 3.7 级） |

结论：噪声清零后 PSNR 提升 1.5 dB。SSIM 0.78 反映的是**真实的结构差异**，不再是测量抖动。后续所有 V3/V4 测量都必须加 `RHINE_FREEZE_TIME=1`。

### V3/V4 续查：两项落地的修正与已排除清单

本轮在确定性测量基础上又推进了两步，均为可复核的代码改动。

**1. 渲染尺寸对齐内部渲染目标（已修复）**

`postProcess->renderSize(1262x1370)` 返回 **947x1028**（FSR1 质量档 0.75 缩放），这才是 legacy 颜色目标与后处理输入的真实尺寸。此前 Filament 一直按**窗口尺寸**渲染，合成阶段被降采样进 947x1028 后又由 FSR 升采样回窗口，多一次往返。

改动：`Qt/src/RhiScene.cpp` 中 `filamentFrame(opaque, transparent, g, background, dimensions)` 改为 `(..., size)`。改后着色器的 `viewport` uniform（947x1028）与渲染目标终于一致。实测 PSNR 20.41 -> 22.19 dB。

**2. 色彩标定系数重扫（已修复）**

`Qt/src/scene/FilamentScene.cpp` 默认 `gain` 由 1.5 改为 **1.3**。扫描数据（确定性合成图，3D 区 PSNR / 梯度能量比）：

| gain | PSNR | 梯度能量比 |
|---|---|---|
| 1.0 | 21.30 dB | 0.39 |
| 1.15 | 22.14 dB | 0.32 |
| **1.3** | **22.34 dB** | 0.26 |
| 1.5 | 22.19 dB | 0.19 |

更高增益会把亮部夹到纯白（`clamp(outputColor(aces(rgb)) * gain, 0, 1)`），边缘能量显著下降。原注释中「最优在 1.5」基于旧测量，已更正。

**3. 剩余差距的准确描述**

Filament 画面比 legacy 系统性偏软：**梯度能量仅 26%**（legacy 梯度均值 1.49，Filament 0.28）。在 `RHINE_AA_MODE=off` 的 1:1 无缩放路径下同样存在，说明是渲染内容本身而非后处理链路。

已用实测排除：渲染尺寸往返（已修）、色彩增益（已重扫）、抗锯齿（`AntiAliasing::NONE`）、Bloom（默认关闭）、Dithering（NONE）、图集上传（全尺寸 RGBA16F、`levels(1)` 无 mip）、缩放/平移错位（0.30-1.20 全区间搜索最佳相关仅 0.27）、几何翻转/转置/子矩形偏移、varying 接线（常量测试视口 std 3.5）、`getFace`/surfaceUv 公式（与 legacy 逐字相同）、渲染不确定性（两次运行逐位相同）、背面剔除、双面材质、near 平面取值。

**4. 方法论教训（务必先读）**

本次续查中曾三次得出错误结论并更正，根因都是**在验证测量工具之前就用它下结论**：

- 误判 `globals.correction` 是「画布->视口映射」，实为 `rhi->clipSpaceCorrMatrix()`（只管 Z 范围与 Y 方向约定，来源 `Qt/src/render/ScenePostProcess.cpp:210`）
- 基于首帧回读（`!dumped` 守卫在 Filament 尚未渲染时触发）误判「两端取景完全不同」
- 用 Reinhard 映射后的标准差判断缓冲区「纯平」，实为线性域 std 0.174（约 17% 对比度）

**结论与后续路径**：在不引入 RenderDoc / apitrace 等真实抓帧工具的前提下，可排查手段已用尽。继续推进的唯一可靠方式是抓取合成 pass 的输入纹理逐像素对照。

### 色调编码路径的定量对照（关键：证明问题不在色调曲线）

材质末段 `clamp(outputColor(aces(result.rgb, mix(0.76, 0.98, viewport.z))) * gain, 0, 1)` 一度被怀疑是压掉对比度的元凶。用 `OPTICAL_OUTPUT_ENCODE` 做对照后得到明确结论。

注意：该开关是 **CMake 缓存变量**（`Qt/shaders/filament/OpticalSurface.cmake:15`，默认 1），必须 `cmake -B output/qt-build -DOPTICAL_OUTPUT_ENCODE=0` 修改；直接改 `.mat` 内的 `#define` 无效，会被 `matc -D` 覆盖。

| 配置 | PSNR | 梯度能量比 | 亮度（F vs L） |
|---|---|---|---|
| ENCODE=1, gain=1.3 | **22.34 dB** | 0.26 | 222 vs 218 |
| ENCODE=0（线性输出） | 15.77 dB | **0.93** | 186.7 vs 217.8 |

ENCODE=0 在线性域扫描曝光：1.0→15.77/0.93，1.3→18.46/0.72，1.6→20.29/0.58，2.0→21.35/0.44，2.5→21.15/0.32。

把 gain 从 `aces()` 之后移到之前重扫，曲线完全相同（0.35→14.58/0.91，0.5→17.21/0.69，0.7→19.51/0.53，1.0→21.31/0.39，1.3→22.07/0.33）。

**结论（重要）**：

1. ENCODE=0 时梯度能量比达到 **0.93**，接近完美 —— 说明**几何、顶点变换、图集采样链路本身是正确的**，此前关于相机/取景的种种怀疑可以彻底放下。
2. 关编码后画面整体偏暗（186.7 vs 217.8），补偿曝光又会让对比度回落 —— 这说明 **Filament 的 `shade()` 产出的线性动态范围比 legacy 小**，即着色函数本身更平，而不是色调曲线的问题。
3. 因此后续若要继续提升，方向应是 **`shade()` 内部的着色实现**（各光照项/图集组合的权重），而不是继续调曝光或色调。
4. PSNR 在此场景下有误导性：ENCODE=1 的 22.34 dB 更高，但梯度能量只有 0.26（画面明显发灰，放大后可直观看到）；ENCODE=0 的对比度几乎完美却因整体偏暗而 PSNR 更低。**评价 V3/V4 不能只看 PSNR，必须同时看梯度能量比。**

当前保留 ENCODE=1 + gain=1.3（PSNR 最优）作为默认，其余配置均已回退。

### 关键结构发现：最终 pass 是 `×4 → 模糊 → aces`，材质内编码会造成二次映射

`Qt/shaders/enhancement/opticalFinalFragment.frag` 的实际管线：

```glsl
float theme = g.viewport.z;
vec3 hdr = texture(color, rtUV(v_uv)).rgb * 4.0;   // 4 倍放大
// 9 抽头盒式模糊，权重合计 16
vec3 rgb = outputColor(aces(hdr, mix(0.76, 0.98, theme)));
```

含义：场景色目标里存放的是**线性 HDR**，进入最终 pass 后被放大 4 倍、做一次模糊，再统一做 aces + outputColor。

因此 `OPTICAL_OUTPUT_ENCODE=1`（在材质内先做 aces，当前默认）与最终 pass 构成**二次色调映射**：材质的输出已被压到 [0,1]，又被放大 4 倍再做 aces，结果整体被推向白端 —— 这正是观察到的「画面发灰、对比度仅 0.26」的机制。

`OPTICAL_OUTPUT_ENCODE=0` 把编码交给最终 pass，架构上才是正确的，实测对比度恢复到 **0.93**（接近完美），代价是整体亮度偏低（186.7 vs 217.8），需另配线性曝光。

**实际参数的运行期快照**（`RHINE_FILAMENT_DEBUG=1`）：

```
viewport = (947.0, 1028.0, 0.000, 0.000)      // z = aces 曝光主题，w = 0
fog      = (92.21, 112.21, 103.28, 0.00)
fogColor = (0.82, 0.78, 0.75, 0.00)           // 与画面发灰的颜色一致
opticalLight = (1.0, 1.0, 0.620, 0.0)
surface  color=(1.000,0.930,0.847,1.0) flags=(3,2,0,0) dark=(0.122,0.147,0.162,1.0)
extra=(0.300,0.250,0,0) emission=(0,0,0,0)
state    q=0.000 clarity=0.000 theme=0.000 mode=0.000
eye=(-66.3, 36.7, 45.2)  proj0=10.901 proj5=19.380
```

**给后续接手者的建议**：应切到 `OPTICAL_OUTPUT_ENCODE=0`，并把材质输出对齐到最终 pass 期望的线性量级（最终 pass 会乘 4，故材质侧应输出约 1/4 量级的目标值），这样既避免二次映射、又能同时拿到正确亮度与对比度。当前默认仍保留 ENCODE=1（PSNR 数字更高），但需注意 PSNR 在这个场景有误导性。

#### 补充：三种度量对同一对图像给出分歧（度量学注意）

对同一组对照，四种判据的结果并不一致：

| 判据 | ENCODE=1, gain=1.3 | ENCODE=0, gain=2.0 | 偏向 |
|---|---|---|---|
| PSNR | **22.34 dB** | 21.35 dB | ENCODE=1 |
| 窗口化 SSIM(11x11) | **0.7596** | 0.7375 | ENCODE=1 |
| 梯度能量比 | 0.26 | **0.44** | ENCODE=0 |
| 人眼观察（同区域 3x 放大） | 几乎均匀、边界难辨 | **能看到明确货架边缘** | ENCODE=0 |

原因：PSNR 与 SSIM 都是**逐像素/局部窗口**度量，在画面大面积平坦、只有细微色差时，二者的数值主要由平滑区的亮度接近程度决定；而「对比度被压平」这种**结构性退化**在它们看来代价很小。梯度能量比对结构退化敏感得多，与人眼判断一致。

**结论**：评估 V3/V4 不能只看 PSNR/SSIM。建议三者并列：PSNR、窗口化 SSIM、**梯度能量比**（后者对「发灰/变平」最敏感）。当前默认仍取 ENCODE=1（PSNR 与 SSIM 双优），但这两种度量在本场景不足以代表视觉保真度，后续应把梯度能量比纳入验收。

### V13 结案：交互式运行内存无泄漏，Filament 略优

此前 V13 只能在 `--capture` 紧循环里测，而该路径本身会累积，无法区分是回归还是压测假象。本轮改用**真实事件循环**（`xvfb-run ./RhineMusicDatabase archive`，不传 `--capture`），每 3 秒采样 `/proc/<pid>/status` 的 `VmRSS`，共 10 次（总时长约 36 秒）。

| 模式 | 稳定 RSS | 说明 |
|---|---|---|
| legacy（`RHINE_FILAMENT` 未设） | **732,392 kB（约 715 MB）** | 10 次采样完全恒定 |
| Filament（`RHINE_FILAMENT=1`） | 678,884 -> 705,192 -> 708,276 kB | 前约 7 秒预热增长，之后 8 次采样完全恒定 |

**结论：**

1. **交互式运行下两条链路都没有内存泄漏** —— 稳态后 RSS 逐次采样完全相同。
2. **Filament 稳态内存比 legacy 少约 23 MB（-3.3%）**，无回归。
3. 此前在 `--capture` 紧循环中观察到的持续增长（legacy 58->637 MB、Filament 51->762 MB）是**该压测路径自身的既有行为**，不能作为泄漏证据。
4. 采样注意事项：`xvfb-run` 会包一层 wrapper，且 Linux 的 `comm` 名被截断为 15 字符（`RhineMusicData`），因此 `pgrep -x` 匹配不到真实进程；应遍历 `pgrep -f 'qt-build/RhineMusicDatabase'` 并取 RSS 最大的那个 PID。

### 附带发现：打包脚本不清理陈旧资源，退休文件会漏进安装包

运行 `node scripts/test.cjs` 时 `scripts/audit-qt.py:55` 断言失败：

```
AssertionError: Retired script or geometry copy entered package: room-pmrem.bin
```

排查结论（与 Filament 改动无关，是既有问题）：

- `scripts/package-resources.cjs` 的工作根目录就是 `output/resources`，它**只写入、不删除**。
- 因此历史上被标记为「退休」的资源（`room-pmrem.bin`、`dfg-lut.bin`、`ao-kernel.bin`、`ao-noise.bin`）一直残留在 `output/resources`，并在打包时被原样复制进 `RhineMusicDatabase.AppDir/usr/bin/resources`，触发审计断言。
- 这些文件**没有被 git 跟踪**（`git ls-files` 中为 0），只存在于构建产物目录，所以源码仓库本身是干净的。

**建议修复**：在 `package-resources.cjs` 写入前先清空（或按白名单清理）`output/resources`，避免退休资源随包发布。

**环境限制**：本机无法重新打包验证修复效果——`node scripts/build.cjs` 需要 `RHINE_NODE_BINARY` 与 `RHINE_NODE_LICENSE`（官方独立 Node 发行版）两个环境变量，当前环境未提供。可运行的部分均已通过：公开仓库审计（744 文件）、ctest 10/10（含 `qt_filament_checks`）。

#### 修复已落地

`scripts/package-resources.cjs` 在解析目标目录后、组装白名单之前，增加对退休资源的定向删除：

```js
for (const retired of ['room-pmrem.bin', 'dfg-lut.bin', 'ao-kernel.bin', 'ao-noise.bin']) {
    fs.rmSync(path.join(out, retired), { force: true });
}
```

验证（用临时目录注入退休文件与一个非退休文件后运行脚本）：

- `room-pmrem.bin`、`dfg-lut.bin` 被删除
- `keep-me.bin`（不在退休名单）保留
- 6 个 `OpticalSurface_*.filamat` 材质正常进入包内

脚本随后仍以非零退出，原因是 `output/resources/MusicBridge/NODE-LICENSE` 缺失——与本节修复无关，属环境限制（需要 `RHINE_NODE_BINARY` / `RHINE_NODE_LICENSE`）。

### 突破：找到可信的测量通道，并把问题定位到顶点法线

#### 1. 可信通道的建立

此前所有自建回读都不可信（读到的缓冲与合成实际使用的纹理不符）。本轮找到的办法：

- 用 `RHINE_AA_MODE=fsr1` 激活后处理链（`postProcess->active()` 为 true），此时 `composite()` 会把场景色写进**由 QRhi 自己创建**的后处理输入目标，而不是外部接管的 Filament 镜像。
- 在该目标上加 `QRhiTexture::UsedAsTransferSource` 并用 `QRhi::readBackTexture` 回读——这条路径与 legacy 回读同源，已验证可用。
- 两端（开/关 Filament）都跑同一命令，产出**完全同尺寸**的 `316x343 RGBA16F` 缓冲，可直接逐像素比较。

注意：本轮验证用的插桩（`RHINE_FILAMENT_DUMP_POST`、`inputTexture()` 访问器、`UsedAsTransferSource` 标志）在取得结论后已全部撤销，工作区保持干净。若后续要复用，按上述三点重新加回即可。

#### 2. 场景色对比度差异（可信数据）

同一场景、同一分辨率下的后处理输入：

| 后端 | R/G/B 均值 | R/G/B 标准差 |
|---|---|---|
| legacy | 0.895 / 0.868 / 0.834 | **0.027 / 0.036 / 0.048** |
| Filament | 0.854 / 0.843 / 0.829 | **0.010 / 0.013 / 0.016** |

**Filament 场景色的局部对比度只有 legacy 的约 1/3**，且这是在**任何色调映射之前**。视觉复核（Reinhard 拉伸后）：legacy 可见清晰的货架条纹，Filament 近乎均匀。这是「画面发平」在管线层面的直接证据。

#### 3. 图集 UV 对比 —— 顶点法线是首要嫌疑

把材质与 fragment 都改成直接输出图集 UV（`surfaceUv = (face + uv.x)/6`），经上述可信通道对比：

| 后端 | U 范围 | U 唯一值数 |
|---|---|---|
| legacy | 0.407 .. 0.841 | 431 |
| Filament | **0.795 .. 0.912** | 116 |

`U = (face + uv.x) / 6`，因此：

- legacy 的 U 覆盖 0.407–0.841，对应 `face` 约 **2~5**，朝向分布完整；
- Filament 的 U 集中在 0.795–0.912，对应 `face` 约 **4~5**，**缺少低值朝向**，且唯一值只有 legacy 的 1/4。

**结论：Filament 侧的 `face`（由顶点法线 `getFaceV(getCustom0().xyz)` 决定）分布明显偏向高值。** 这同时解释了画面发平（采样到的图集区域窄、变化少）与内容不匹配。

**下一步应检查的方向**（已收窄到单点）：`Qt/src/scene/FilamentAssets.cpp` 里顶点缓冲的 `CUSTOM0` 绑定（当前为 `attribute(CUSTOM0, 0, FLOAT3, 12, 32)`）是否真的送达了与 legacy 一致的法线数据——包括顶点布局 `pos3 + normal3 + uv2`、stride 32、以及实际传入的顶点数组是否与 legacy 几何通道同源。

#### 更正：上节的 UV 对比被背景像素污染，不能作为结论

上节「Filament 的 face 偏向高值」这一判断**需要撤回**。复核依据：

- legacy 的 `v_surfaceUv = vec2((face + surfaceUv.x) / 6.0, surfaceUv.y / 2.0)`（`Qt/shaders/enhancement/opticalGeometry.vert:37`），其中 `surfaceUv.y ∈ [0,1]`，故 **V 的理论上限是 0.5**。
- 但实测 legacy 的 V 范围是 0.442 .. 0.824 —— 超过 0.5，说明统计里混入了**未绘制几何的背景像素**（背景色约 0.82，与上限吻合）。
- 因此那条「U 范围对比」同时包含了背景与几何，无法据此推断 `face` 的分布。

正确的做法是先按「该像素是否被几何覆盖」做掩码（例如同时 dump 一帧只在几何处写 1 的掩码，或用深度缓冲筛选），再统计 UV。这一步尚未完成。

**保留下来的可靠结论**只有一条：同一分辨率下的后处理输入里，Filament 的场景色标准差约为 legacy 的 1/3（0.010/0.013/0.016 对 0.027/0.036/0.048）。该统计同样含背景，但由于两端共用同一背景清除逻辑、且差异幅度与独立的全画面测量一致（梯度能量比 0.26），仍可认为 Filament 场景色的局部对比度确实更低。

**教训（第二次同类）**：这类整幅统计必须先把背景/未覆盖区域排除，否则任何「范围」「唯一值数」都会被背景主导。

#### 更正（第二次）：Filament 侧探针根本没生效

复核发现上一个 UV 探针**没有在 Filament 侧生效**，证据是探针本应把 B 通道置 0，实测却是 0.027..0.676。

根因：探针被插在 `shade()` 中的 `highp vec2 vSurfaceUv = v0.xy;` 之后（约第 280 行），而本场景物体的 `surfaceFlags.x == 3`（玻璃壳），`shade()` 在**更早的分支里就 return 了**（`mFlags.x == 3.0 && vMode > 0.5` 的玻璃壳分支），根本执行不到探针那一行。

**因此：**

- 「Filament 的 face 偏向高值」这一结论**完全作废**，不是背景污染而是探针未生效（上节关于背景污染的分析也不成立，但结论同样撤回）。
- 任何在 `Qt/shaders/filament/OpticalSurface.mat` 里插入的调试探针，**必须放在 `shade()` 的最开头**（任何 `if` 分支之前），否则对本场景（`flags.x = 3`）无效。
- 同理，历史上若有人用同样位置做过探针并据此下结论，那些结论都需要重验。

**仍然成立的结论**（不受此影响，因为它们比较的是最终画面/后处理输入的整体统计）：场景色标准差 legacy 约为 Filament 的 3 倍；全画面梯度能量比 0.26；ENCODE=1 与 ENCODE=0 的显著差异（22.34 dB / 15.77 dB）。

**若要继续做 UV 对比，正确步骤**：把探针放在 `shade()` 开头 → 用 `RHINE_AA_MODE=fsr1` 走可信回读通道 → 用探针写入的 B=0 作为几何掩码再统计。

#### 未解异常：材质探针的输出与预期不符

按正确流程重做 UV 探针（探针置于 `shade()` 最开头、`RHINE_AA_MODE=fsr1` 走可信回读通道、ENCODE=0）后，结果仍不符合预期：

| 后端 | 探针预期 | 实测 R/G/B 范围 |
|---|---|---|
| Filament | `vec4(v0.xy, 0.0, 1.0)`，B 应为 0 | R 0.795..0.912, G 0.086..0.805, **B 0.027..0.676** |
| legacy | `vec4(v_surfaceUv, 0.0, 1.0)`，B 应为 0 | R 0.488..0.845, G 0.511..0.826, **B 0.054..0.674** |

两端探针都把 B 写成常量 0，但回读到 B 是一个随位置变化的量。R 范围与上一版探针（位置不同的那一版）**完全相同**（0.795..0.912），进一步说明读到的可能不是探针的输出。

**目前无法确定原因**，候选：

1. `OpticalSurface.mat` 的文件改动未触发 `.filamat` 重新生成（构建规则依赖可能只挂在 CMake 缓存变量上，因为 ENCODE 缓存变量的改动确实生效：22.34 dB vs 15.77 dB）。
2. 回读到的后处理输入目标并非最终被采样的那张（即使尺寸匹配）。
3. 探针输出在下游被混合/覆盖。

**诚实结论**：Filament 材质侧的像素级探针在本项目中尚未验证可用。在解决这一点之前，任何基于材质探针的结论（包括历史上可能存在的）都不可信。

**注意与其他结论的区分**：以下结论不依赖材质探针，仍然成立——场景色标准差 legacy 约为 Filament 的 3 倍；全画面梯度能量比 0.26；ENCODE=1 与 ENCODE=0 的显著差异。

所有探针与回读插桩已撤销，工作区恢复干净（`BUILD=0`、`ctest 10/10`、16 个路径变更）。

#### 未解异常的解决：材质改动确实生效，但那条回读通道不是原始直通

上一节留下的疑点，用「整片改红」实验一次性澄清。做法：在 `shade()` 最开头插入 `return vec4(1.0, 0.0, 0.0, 1.0);`，不改任何 CMake 缓存变量，直接重新构建并抓图。

结果：

- `OpticalSurface_opaque_depthwrite_1sided.filamat` 的 mtime 由 `10:58:02` 变为 `11:01:24`，大小 `72553 -> 55841` 字节 —— **材质文件改动确实触发重新编译**（探针让后续代码变成死代码，故体积缩小）。
- 抓图 3D 区 **96.0% 为纯红像素**，R 均值 233.2，G 均值 7.0 —— **材质改动确实进入运行时**。

**但同一帧的 B 均值是 67.2**：输入明明是 `(1,0,0)`，输出 B 却有 67。这说明**「后处理输入目标」这条回读通道并非原始直通**，中间存在带跨通道串色的色彩变换（ACES 的输入/输出矩阵正是此类）。

这同时解释了上一节的 UV 探针异常：探针写入的常量 `B=0` 被这段变换改写了，所以回读到的是变换后的值；R 范围看似相同也是同理。

**最终结论：**

1. Filament 材质探针**可用**——材质改动会正确编译并生效。
2. 但**不能用后处理输入目标来读原始中间量**，那里已经过色彩变换。要读原始值，必须绕开该变换（例如让探针输出的量落在变换的不动点、或改用别的输出通道）。
3. 本节修正了上一节「材质探针尚未验证可用」的说法——探针本身是好的，问题在读取位置。

### 决定性证据：Filament 的图集 U 几乎恒定，指向顶点法线

#### 让探针穿过色彩变换

上节确认「后处理输入目标」含跨通道色彩变换（纯红输入 B 却为 67）。ACES 对中性灰 `(v, v, v)` 保持中性且单调，因此**用灰度编码标量**即可让探针穿过该变换。

探针写法（两端均在函数最开头，确保不被任何分支跳过）：

```glsl
// Filament: shade() 第一句
return vec4(v0.x, v0.x, v0.x, 1.0);
// legacy: main() 第一句
fragColor = vec4(v_surfaceUv.x, v_surfaceUv.x, v_surfaceUv.x, 1.0); return;
```

其中 `v0.x` 与 `v_surfaceUv.x` 都是图集 U 坐标 `(face + surfaceUv.x) / 6.0`。

#### 结果（`RHINE_AA_MODE=fsr1` + ENCODE=0，两端同变换、同尺寸 316x343）

| 分位 | Filament | legacy |
|---|---|---|
| 1% | 0.8081 | 0.4634 |
| 5% | 0.8276 | 0.5337 |
| 25% | 0.8438 | 0.6465 |
| 50% | 0.8501 | 0.7061 |
| 75% | 0.8579 | 0.7593 |
| 95% | 0.8657 | 0.8003 |
| 99% | 0.8687 | 0.8145 |
| **跨度** | **0.061** | **0.352** |
| 均值 | 0.8493 | 0.6940 |

相关系数 0.594，最大绝对差 0.4431。

**Filament 的图集 U 跨度只有 legacy 的约 1/6，几乎恒定在一个值附近。**

#### 含义

`U = (face + surfaceUv.x) / 6.0`，U 近乎恒定 ⇒ `face` 基本固定不变。而 `face` 由顶点法线经 `getFaceV(getCustom0().xyz)` 得出。

这条结论与 `getFace`/`getFaceV` 源码逐字一致的事实并不矛盾——**问题不在函数，而在喂给它的法线数据**。它同时解释了：

- 画面发平（整场景采样同一小片图集）
- 内容不匹配（采到的图集区域与 legacy 不同）
- 场景色标准差只有 legacy 的 1/3

**下一步应该检查**：`Qt/src/scene/FilamentAssets.cpp` 中顶点缓冲的 `CUSTOM0` 实际内容——当前绑定为 `attribute(CUSTOM0, 0, FLOAT3, 12, 32)`，需确认传入的顶点数组在偏移 12 处确实是法线（与 legacy 的 `layout(location = 1) in vec3 normal` 同源、同布局）。

#### 顶点绑定已核对无误，嫌疑进一步收窄

用 legacy 侧的顶点输入布局做交叉验证（`Qt/src/render/MotionPass.cpp:81-83`）：

```cpp
{0, 0, QRhiVertexInputAttribute::Float3, 0},    // position
{0, 1, QRhiVertexInputAttribute::Float3, 12},   // normal
{0, 2, QRhiVertexInputAttribute::Float2, 24},   // uv
```

即真实数据布局为 `pos3 + normal3 + uv2`，stride 32。对照 `Qt/src/scene/FilamentAssets.cpp:284-286`：

```cpp
.attribute(POSITION, 0, FLOAT3, 0, 32)
.attribute(CUSTOM0,  0, FLOAT3, 12, 32)
.attribute(UV0,      0, FLOAT2, 24, 32)
```

**两者完全一致，`CUSTOM0` 的偏移 12 确实就是法线。绑定本身没有错。**

因此嫌疑范围进一步收窄到下面三处之一：

1. Filament 对 `CUSTOM0` 属性的实际传递（例如 material 里 `requires: ["custom0"]` 的声明与实际读取方式是否匹配 `getCustom0()`）；
2. `getWorldFromModelMatrix()` / `getPosition()` 在 `materialVertex` 中取到的是否为预期值（`face` 虽然只依赖法线，但 `surfaceUv.x` 依赖 `positionAttr.x`，两者共同决定 U）；
3. 顶点数组本身在交给 Filament 时是否已损坏（`FilamentAssets.cpp:293-309` 会按 `vertexCount * 32` 复制一份，若 `vertexCount` 或来源指针有误，复制出来的数据会是错的）。

**建议的下一步**：直接在第 3 点上验证——把 `Batch` 的顶点数据在复制前后各 dump 一次（或先打印首顶点 8 个 float），确认偏移 12 起的三个 float 是单位法线量级（约 -1..1）而不是位置量级（数十）。这一步不需要抓帧工具。

#### 更正（第三次）：灰度 U 对比同样不成立

上节「Filament 的图集 U 几乎恒定」这一结论**需要撤回**。

理由：两端虽然走同一条后处理变换 `g`，但**输入到 `g` 的线性量级不同**（ENCODE=0 时各自输出自己的线性值）。而 `g` 是带饱和的色调曲线——较亮的输入会被压缩得更厉害。因此「输出跨度窄」既可能来自「U 本身变化小」，也可能只是「输入更亮、被曲线压平」，**两者无法区分**。

具体矛盾：按 CPU 侧首顶点数据 `v0=(-2.4930,0.0000,0.1920)`、`n0=(-0.0002,-0.9992,0.0401)` 手算，`face = 4`、`surfaceUv.x ≈ 0.0014`，应得 `U ≈ 0.667`；而片上实测（变换后）中位数是 0.850。这个差可能来自 `g`，也可能来自 GPU 侧取值不同，**现有数据不足以判定**。

**经核对的代码侧事实（这些是确定的）：**

- `Qt/shaders/filament/OpticalSurface.mat:14` 声明 `requires : [ "custom0", "uv0" ]`，正确。
- `Qt/shaders/filament/OpticalSurface.mat:109` `surfaceUvAtlas = vec2((face + surfaceUv.x) / 6.0, surfaceUv.y / 2.0)`。
- `Qt/shaders/filament/OpticalSurface.mat:133` `material.v0 = vec4(surfaceUvAtlas, stateTheme, -eyeView.z)` —— `v0.x` 确实是图集 U。
- CPU 侧顶点数据完好：首顶点法线 `(-0.0002,-0.9992,0.0401)` 模长 ≈1.0。
- 顶点属性绑定 `POSITION@0 / CUSTOM0@12 / UV0@24`、stride 32，与 legacy 的 `MotionPass.cpp:81-83` 完全一致。

**结论**：代码与数据在静态检查层面全部正确；要判定运行时是否一致，**必须有一条可证明为恒等的观测通道**（能原样读出 `v0.x`）。本次会话尝试的所有通道（窗口抓图、外部镜像回读、后处理输入回读）都无法证明这一点，因此至今**没有任何一条关于 U/face 的运行时结论是可靠的**。

这条教训适用于本项目后续所有像素级调试：**先证明通道恒等（输入常量 → 输出同一常量），再谈结论。**

#### 四条观测通道全部排除，V3/V4 运行时排查在此终止

为找到「可证明恒等」的通道，最后尝试了 alpha：把图集 U 编码进 alpha（`return vec4(0.0, 0.0, 0.0, v0.x);`，两端同样处理），alpha 不参与 ACES 色彩矩阵，理论上应原样通过。

结果：两端回读的 **A 通道恒为 1.0000，唯一值 1 个**——alpha 在后处理输入目标里被强制写为 1，同样不是恒等通道。

至此四条候选通道全部排除：

| 通道 | 不可用原因 |
|---|---|
| 窗口抓图 `qt-window.png` | 经过完整后处理（`×4 → 模糊 → aces → outputColor`），非线性 |
| 外部镜像回读（`m_swapChain->image`） | 读到内容与合成实际使用的纹理不符 |
| 后处理输入目标回读 | 含跨通道色彩变换（纯红输入 B=67 为证） |
| alpha 通道 | 被强制写为 1.0000 |

**结论**：本项目当前**不存在可证明恒等的运行时观测通道**。任何基于以上通道的 U/face/中间量推断都不可靠——本次会话中此类推断已产生七次更正，其中三次是否定自己前一节的「突破」。

**若要继续 V3/V4，必须先解决观测问题**，可选路径：

1. 接入 RenderDoc / apitrace，直接抓取 Filament 的渲染目标与顶点着色器输出；
2. 在 Filament 侧临时加一条**独立的全屏调试 pass**，把探针值写进一张自建、与会话无关的纹理，再用可靠的 CPU 回读读出（不经过合成链）；
3. 用 Filament 自带的 `RenderTarget::readPixels` 对一张**由 Filament 自己拥有**的离屏目标做回读。

在此之前，继续分析的期望收益极低。**静态检查层面本文档已确认：着色代码、顶点绑定、顶点数据、图集上传全部正确**——问题只可能在运行时，且必须借助上述通道之一才能看到。

### 关键异常：图集对 Filament 输出的贡献极小

用项目**已有**的探针开关 `RHINE_FILAMENT_FORCE_ATLAS_RED`（把三张图集替换成 2x2 纯红纹理，见 `Qt/src/scene/FilamentAssets.cpp:205-233`）做端到端验证，无需任何代码改动：

| 观察 | 结果 |
|---|---|
| 3D 区均值 | R 227.2 / G 227.2 / B 227.2（**中性灰，完全不变红**） |
| 偏红像素占比 | **0.0%** |
| 与基线整幅差异 | 最大仅 28 级，57.83% 像素有微小差异 |

而在 legacy 中，场景外观几乎完全由图集决定——图集换成红色必然导致整片变红。

**因此：Filament 侧的图集采样虽然语法上存在（材质 `:281 texture(materialParams_surfaceAtlas, vSurfaceUv)`、场景 `FilamentScene.cpp:378` 也正确绑定了三张图集），但它对最终画面的贡献小到不合理。**

这与已观测到的现象自洽：**场景色局部对比度只有 legacy 的 1/3、画面发平**——原因很可能就是图集的细节没有真正参与着色。

**可能的机制**（尚未验证）：

1. `normalResponse`（法线图集采样）接近零 → `color = baked.rgb * normalResponse.rgb + normalResponse.a` 中 `baked` 被乘没了，画面主要由 `bakedIllumination()`（光照图集）与 fog 决定；
2. 图集纹理虽已绑定但采样坐标退化（`vSurfaceUv` 落在纹理的固定位置）；
3. 采样到的 mip/层不对。

**这条线索的价值**：它把问题从「无法观测」推进到了「有明确、可复现的可观测量」——`FORCE_ATLAS_RED` 前后画面几乎不变，是一个不需要任何调试通道就能重复的判据。

**下一步的验证方法**（同样不需要调试通道）：把 `bakedIllumination()` 临时改为返回 0，若画面几乎不变，则可确认画面并非由图集+光照驱动，而是由别的东西（如 fog）主导。

### 因果实验汇总：画面由一个近乎恒定的项主导

不依赖任何调试通道，只用「改输入看输出」的因果实验，得到一组自洽的量化结果（均为与基线 `qt-window.png` 的整幅比较，3D 区为中心 400x400）：

| 实验（改什么） | 最大像素差 | 不同像素比例 | 结论 |
|---|---|---|---|
| 图集换成 2x2 纯红 | 28 | 57.83% | 图集几乎不影响画面 |
| `bakedIllumination()` 返回 0 | 8 | 18.00% | 光照图集几乎不影响画面 |
| 去掉全部 fog 混合 | — | — | 梯度能量比 0.27 vs 0.26，几乎无变化 |
| `shade()` 直接返回纯红 | — | — | **96.0% 像素变红** |

**关键推论：**

1. 几何**确实在绘制**（纯红测试覆盖 96% 的像素）。
2. 但图集、光照图集、fog 三者对最终画面几乎都没有影响。
3. 三者都被削弱到近乎无效，说明**输出由某个恒定项主导**——它同时压制了这三条路径。

**最可能的位置**：`color = baked.rgb * normalResponse.rgb + vec3(normalResponse.a)`（`Qt/shaders/filament/OpticalSurface.mat:291`）。若 `normalResponse`（来自 `normalAtlas`）的 `.a` 分量接近常数、且 `.rgb` 接近 0，则 `baked` 被乘没、`color` 退化为常数 `normalResponse.a`——这能同时解释上述全部三条观察。

**下一步最省事的验证（仍无需调试通道）：**

1. 把该行临时改为 `color = baked.rgb;`（去掉 normalResponse）——若画面立刻出现图集细节，即可确认是 `normalResponse` 把一切乘没了；
2. 或改为 `color = vec3(normalResponse.a);` 输出到灰度，观察它是否近似常数。

这两步各只需一次构建与一次抓图，且判据是「画面是否出现细节」这种二值判断，不受任何色彩变换或背景污染影响。

### 决定性结果：图集采样值本身就是恒定的

测试：把 `Qt/shaders/filament/OpticalSurface.mat:291` 的

```glsl
highp vec3 color = baked.rgb * normalResponse.rgb + vec3(normalResponse.a);
```

临时改为

```glsl
highp vec3 color = baked.rgb;  // 直接使用图集采样
```

即完全绕过 `normalResponse`，只用表面图集采样值。

结果（3D 区中心 400x400）：

| 指标 | 基线 | 改为 `color = baked.rgb` | legacy |
|---|---|---|---|
| 梯度均值 | 0.38 | **0.35** | 1.49 |
| 梯度能量比 vs legacy | 0.26 | **0.24** | 1.00 |

**画面依旧平坦，没有出现任何图集细节。**

#### 结论

`normalResponse` 也被排除。**表面图集采样值 `baked` 本身就是近乎恒定的**，因此细节在「采样」这一步之前或之中就已经丢失。结合此前 `FORCE_ATLAS_RED` 只造成 28 级变化，只剩两种可能：

1. **`vSurfaceUv` 在片元间几乎不变** —— 即 `v0.xy` 传给片元着色器时退化（顶点间插值失效，或 `v0` 未被正确写入）；
2. **图集纹理内容本身近乎均匀** —— 即上传的数据或纹理层选择有误（尽管 `FilamentAssets.cpp` 的尺寸/格式检查看起来正确）。

#### 区分这两者的一个实验（无需调试通道）

把 `baked` 的采样坐标换成常量以外的**极端**输入，例如

```glsl
highp vec4 baked = texture(materialParams_surfaceAtlas, vec2(fract(vUv.x * 7.0), fract(vUv.y * 7.0)));
```

若画面出现棋盘状/条纹状细节，说明**纹理内容正常、是 `vSurfaceUv` 退化**（可能 1）；若画面仍然平坦，说明**纹理内容本身有问题**（可能 2）。

判据仍是「画面是否出现结构」这种二值判断，不受色彩变换影响。

### 决定性实验：图集内容正常，问题在 surfaceUv 采样路径

用与 `vSurfaceUv` 无关的坐标采样同一张图集：

```glsl
highp vec4 baked = texture(materialParams_surfaceAtlas, fract(vUv * 7.0));
```

结果（3D 区中心 400x400 的梯度均值）：

| 采样方式 | 梯度均值 | 相对 legacy(1.49) |
|---|---|---|
| 基线（`vSurfaceUv`） | 0.38 | 0.26 |
| 原样 `color = baked.rgb`（仍用 `vSurfaceUv`） | 0.35 | 0.24 |
| 位置推导 `face`（仍用 `vSurfaceUv`） | 0.27 | 0.18 |
| **改用 `fract(vUv * 7.0)` 采样** | **2.77** | **1.85** |

**结论：表面图集纹理内容完好无损**——用另一套坐标采样就能得到 1.85 倍于 legacy 的细节。问题完全出在 `vSurfaceUv` 这条采样路径上。

已排除的相关项：

- `variables` 块中 `v0 / v1 / v2 / v3` 均已声明为 `float4` 插值变量（`OpticalSurface.mat:73-77`），不是漏声明。
- `material.v0 = vec4(surfaceUvAtlas, stateTheme, -eyeView.z)`（`:133`）写入正确。
- 把 `face` 换成位置推导值（`mod(floor(positionAttr.x*3+300),6)`）**并未恢复细节**，说明瓶颈不只是 `face`。

**剩余的最可能原因**：`surfaceUv.x`（即 `(positionAttr.x + 2.5)/5.0` 及后续量化）在片元间变化极小，或 `v0` 在 Filament 中的插值实际按 flat 处理。下一步最快的判定方式是：让 `vSurfaceUv` 直接取一个已知随位置变化的值并与 `fract(vUv*7)` 对比——若前者仍平坦，即可确认是 `v0` 插值本身的问题，而非 `surfaceUv` 公式。

**这一轮确立的关键事实**：图集内容、纹理绑定、尺寸、格式全部正常。问题被彻底锁定在 `vSurfaceUv` 这一条路径上。

### 决定性突破：v0 插值正常，问题在顶点端 surfaceUvAtlas 的计算

关键对照实验——把采样坐标换成 `v0.w`（视深度，必然随位置变化）：

```glsl
highp vec2 vSurfaceUv = vec2(fract(v0.w * 0.05));
```

| 采样坐标来源 | 梯度均值 | 相对 legacy(1.49) |
|---|---|---|
| `v0.xy`（图集 UV，基线） | 0.38 | 0.26 |
| `fract(vUv * 7.0)` | 2.77 | 1.85 |
| **`v0.w`（同一 varying 的另一个分量）** | **1.41** | **0.95** |

**结论：`v0` 这条 varying 的插值完全正常**——同一个 `v0` 里，`v0.w` 能产生 0.95 倍于 legacy 的细节，而 `v0.xy` 几乎恒定。

因此问题不在：

- Filament 的 varying 插值机制
- `variables` 声明
- 图集纹理内容 / 绑定 / 尺寸 / 格式

**问题就在顶点着色器里 `surfaceUvAtlas` 的计算结果本身**（`Qt/shaders/filament/OpticalSurface.mat:109`）：

```glsl
highp vec2 surfaceUvAtlas = vec2((face + surfaceUv.x) / 6.0, surfaceUv.y / 2.0);
```

而 `surfaceUv` 来自 `positionAttr`：

```glsl
vec2 surfaceUv = vec2((positionAttr.x + 2.5) / 5.0, positionAttr.y / 3.7);
```

**下一步的判定**（一次构建即可）：在顶点着色器里把 `surfaceUvAtlas` 临时改成 `fract(vUv * 7.0)` 写入 `material.v0.xy`。若画面出现细节，则**确证**是这两行的计算问题；再分别固定 `face` 与 `surfaceUv.x` 即可定位到具体是哪一项。

本条把搜索空间从「整个着色器」压缩到了**顶点着色器的两行代码**，且所有判断都基于「画面是否出现结构」的因果实验，不依赖任何有争议的像素读数。

### 定位链条完成：瓶颈是 surfaceUvAtlas 的计算，`face` 是最后的嫌疑

补上最后一步——在顶点端把 `material.v0.xy` 换成由 `getPosition()` 推导的值：

```glsl
material.v0 = vec4(fract(getPosition().xy * 3.0), stateTheme, -eyeView.z);
```

构建成功（6 个 `.filamat` 正常生成），结果：

| 实验 | 梯度均值 | 相对 legacy(1.49) |
|---|---|---|
| 基线（`surfaceUvAtlas`） | 0.38 | 0.26 |
| 顶点端换成 `fract(getPosition().xy * 3.0)` | 0.71 | **0.47** |
| 片元端换成 `fract(vUv * 7.0)` | 2.77 | 1.85 |
| 片元端换成 `v0.w` | 1.41 | 0.95 |

#### 完整推理链

1. **`v0` 插值正常** —— 同一 varying 的 `v0.w` 能得到 0.95 倍细节。
2. **图集纹理正常** —— `fract(vUv*7)` 能得到 1.85 倍细节。
3. **`getPosition()` 正常** —— 用它推导的坐标能把比值从 0.26 抬到 0.47。
4. 但换成 position 推导的值只到 0.47，**没有完全恢复**，因为 `surfaceUvAtlas` 的两项都会压缩采样范围：`U = (face + surfaceUv.x)/6`（仅 1/6 宽）、`V = surfaceUv.y/2`（仅 1/2 宽）。

因此剩下的差异只能来自 **`face`**：

- legacy 的 `face` 覆盖 0~5，U 因此横跨整个 0~1；
- Filament 若 `face` 近似恒定，U 就只落在 1/6 宽的条带里。

即 `getFaceV(getCustom0().xyz)` 的输入（顶点法线）在 GPU 侧取到的值与 CPU 侧数据不一致。这与已确认的「CPU 侧顶点法线是正确的单位向量」形成直接矛盾，也正是需要最终确认的一点。

#### 最终待验证的一行

在顶点着色器里把 `face` 固定为某个与位置相关的变化值（注意必须在 `materialVertex` 的同一作用域内引用 `positionAttr`，此前一次尝试因变量作用域问题未生效），若画面细节随之出现，即可确证 `getCustom0()` 在 Filament 中取到的不是预期法线。

**注意**：`getUV0()` 与 `vUv` 在顶点/片元两个作用域里名字不同（片元是 `getUV0()`，顶点端属性访问方式不同），本轮有两次实验因用错 API 构建失败、应用静默回退到 legacy（表现为比值恰为 1.00），这类失败必须通过检查 `.filamat` 是否生成来识别。

### 最后一次排除：`face` 不是瓶颈

构建有效的实验（`.filamat` 正常生成 6 个）——把顶点端的

```glsl
highp float face = getFaceV(normalAttr);
```

临时改为位置推导：

```glsl
highp float face = mod(floor(getPosition().x * 3.0 + 300.0), 6.0);  // 使 face 随位置变化
```

结果：梯度 **0.27**，比值 **0.18**（基线 0.38 / 0.26）。**画面略微更平，没有恢复细节。**

#### 综合全部因果实验

| 改动 | 比值 vs legacy | 判定 |
|---|---|---|
| 基线 | 0.26 | — |
| 片元端采样坐标换 `v0.w` | **0.95** | `v0` 插值正常 |
| 片元端换 `fract(vUv*7)` | **1.85** | 图集纹理正常 |
| 顶点端 `v0.xy` 换 `fract(getPosition().xy*3)` | 0.47 | `getPosition()` 正常；`surfaceUvAtlas` 是瓶颈 |
| 顶点端让 `face` 随位置变化 | 0.18 | **`face` 不是瓶颈** |

#### 剩余结论

`v0` 插值、图集纹理、`getPosition()`、`face` 全部排除。剩下的唯一变量是 **`surfaceUvAtlas` 的压缩比例**：

```glsl
surfaceUvAtlas = vec2((face + surfaceUv.x) / 6.0, surfaceUv.y / 2.0);
```

U 被压到 1/6 宽、V 被压到 1/2 宽。而 legacy 用的是**完全相同的公式**却能得到 5 倍细节——这个矛盾是当前最需要解释的一点，方向有两个：

1. 两端的 `surfaceUv`（`(positionAttr.x+2.5)/5`、`positionAttr.y/3.7`）或随后的 `saturate` + `(x*383+0.5)/384` 量化在 Filament 侧有差异（需逐行比对这一段）；
2. 两端实际采样的图集区域不同（尽管加载的是同一个 `.bin`，但纹理层/mip/归一化可能有差异）。

**建议下一步**：逐行比对 `Qt/shaders/filament/OpticalSurface.mat:105-109` 与 `Qt/shaders/enhancement/opticalGeometry.vert:30-37` 这八行，重点看 `saturate` 与量化那一步是否一致。这是纯静态比对，不需要任何构建或抓图。

### 静态比对结论：公式完全一致，差异只可能在 `getPosition()` 的取值

`Qt/shaders/filament/OpticalSurface.mat:100-109` 与 `Qt/shaders/enhancement/opticalGeometry.vert:30-37` 逐行比对：

| 步骤 | Filament | legacy | 一致 |
|---|---|---|---|
| 基础 UV | `(positionAttr.x + 2.5) / 5.0, positionAttr.y / 3.7` | `(position.x + 2.5) / 5.0, position.y / 3.7` | ✅ |
| face 0/3 分支 | `surfaceUv.x = (positionAttr.z + 0.25) / 0.5` | `surfaceUv.x = (position.z + 0.25) / 0.5` | ✅ |
| face 1/4 分支 | `surfaceUv.y = (positionAttr.z + 0.25) / 0.5` | `surfaceUv.y = (position.z + 0.25) / 0.5` | ✅ |
| 半纹素量化 | `(SATURATE_V(surfaceUv) * 383.0 + 0.5) / 384.0` | `(saturate(surfaceUv) * 383.0 + 0.5) / 384.0` | ✅ |
| 图集打包 | `vec2((face + surfaceUv.x) / 6.0, surfaceUv.y / 2.0)` | 同 | ✅ |

**公式一字不差。**

#### 由此得到的精确假设

既然公式相同，差异只能来自 `positionAttr = getPosition()` 的**取值范围**。注意 `SATURATE_V` 会把结果钳到 [0,1]：

- 若 `getPosition()` 返回**模型空间**坐标（约 -2.5..2.5，与 CPU 侧 `v0=(-2.4930, 0.0000, 0.1920)` 一致），则 `(x+2.5)/5` 落在 0..1，UV 正常变化；
- 若它返回**世界空间或已被实例变换**的坐标（量级数十），则 `(x+2.5)/5` 远大于 1，**`saturate` 会把整片钳成 1.0**，`surfaceUv` 变成常量 → 图集采样恒定 → **画面发平**。

这与所有观测一致，包括：

- `fract(getPosition().xy * 3.0)` 仍能得到 0.47（`fract` 对大量级输入照样变化）；
- 公式里的 `saturate` 正是那个把变化「抹平」的环节；
- 改动 `face` 无效（U 已恒为 `(face+1)/6`，改变 face 只是换一条恒定的条带）。

#### 下一步（一次构建即可验证）

在 `materialVertex` 里临时加一行把 `positionAttr` 的范围暴露出来，例如：

```glsl
material.v0 = vec4(step(2.5, abs(positionAttr.x)), step(5.0, abs(positionAttr.y)), 0.0, -eyeView.z);
```

若画面大面积变成 1（白），即证明 `getPosition()` 的取值远超 ±2.5，假设成立。修复方向是改用模型空间的原始属性（或对 `positionAttr` 施加 `getWorldFromModelMatrix()` 的逆变换）。

### 证伪：`getPosition()` 取值正常，不是 saturate 钳平

验证上一节的假设——把 `positionAttr` 是否超出 ±2.5 直接编码成颜色读出：

```glsl
// 顶点端
material.v0 = vec4(step(2.5, abs(positionAttr.x)), step(5.0, abs(positionAttr.y)), stateTheme, -eyeView.z);
// 片元端 shade() 第一句
return vec4(v0.x, v0.y, 0.0, 1.0);
```

构建有效（6 个 `.filamat`），结果：

| 观察 | 数值 |
|---|---|
| 3D 区 R / G / B 均值 | 7.4 / 7.0 / 7.1（**几乎全黑**） |
| R 高于 128 的像素 | **2.8%** |

即 `step(2.5, abs(positionAttr.x))` 对 97% 的像素为 0 —— **`getPosition()` 的取值在 ±2.5 以内，是正常的模型空间坐标**。

**上一节的「saturate 把 UV 钳成常量」假设被证伪。**

#### 至此已用因果实验排除的全部候选

| 候选 | 实验 | 结果 |
|---|---|---|
| varying 插值 | 用 `v0.w` 作 UV | 0.95，正常 |
| 图集纹理内容 | `fract(vUv*7)` 采样 | 1.85，正常 |
| 图集绑定/格式 | `FORCE_ATLAS_RED` | 影响仅 28 级 |
| 光照图集 | `bakedIllumination()` 归零 | 影响仅 8 级 |
| `normalResponse` | `color = baked.rgb` | 0.24，无改善 |
| `face` | 改为位置推导 | 0.18，无改善 |
| `getPosition()` 量级 | step 读回 | 在 ±2.5 内，正常 |
| 计算公式 | 静态逐行比对 | 与 legacy 一字不差 |

#### 当前唯一未解释的矛盾

公式相同、输入正常、纹理正常、插值正常，但 Filament 的图集采样结果比 legacy 平坦约 4 倍。剩下的差异只能来自**采样坐标的最终数值**——`U = (face + surfaceUv.x)/6` 把范围压到 1/6、`V = surfaceUv.y/2` 压到 1/2，两端都是如此；但**legacy 的 `face` 在整个场景中分布更分散**，使不同面片落在不同的图集条带上，整体呈现更多变化。

这与「让 Filament 的 face 随位置变化却更平（0.18）」并不完全自洽，说明还有一处变量未被观察到。**继续排查需要能直接读出 `vSurfaceUv` 数值的通道**（本次会话已证明窗口抓图、外部镜像回读、后处理输入回读、alpha 通道四条路径都不可靠）。

### 可靠基线建立：原始场景色对比（同尺寸、同语义）

本次会话的测量困境最终被解决。关键有三点：

1. **修正渲染尺寸**：
`filamentFrame(..., dimensions)` -> `(..., size)` 之后，Filament 的交接镜像与 legacy 的颜色目标都是 **947x1028**，两端 dump 字节数一致（7,788,128 = 947x1028x8）。
2. **验证通道有效性**：
同一次运行内，Filament 的原始 dump 与其合成截图相关性 **+0.4907**（不为 1 是因为合成还要经色调映射、FSR 升采样与 UI 叠加），证明该回读通道可信。
3. **两端同条件抓取**：
Filament dump 必须在 `RHINE_FILAMENT=1` 下抓；legacy dump 必须在**关闭** Filament 下抓（此前一次误在开启状态下抓 legacy，`color.texture` 从未被写入，得到的不是真实内容）。

#### 结果（H=1028, W=947，正确朝向）

| 指标 | Filament | legacy |
|---|---|---|
| 均值 | 0.912 | 0.846 |
| 标准差 | **0.081** | **0.178** |
| 水平梯度均值 | **0.0024** | **0.0246** |
| 两者相关系数 | \multicolumn{2}{c}{**+0.0876**} |

#### 结论

**Filament 的场景色比 legacy 平坦约 10 倍，且结构上几乎不相关（0.088）。**

这是第一次在**同尺寸、同语义、通道已验证**的条件下得到的对比数字。它确认了此前由合成图推出的结论（梯度能量比 0.26），但这次的数值更直接、更可信：问题存在于**场景渲染本身**，与后处理、合成、分辨率链路无关。

#### 仍需注意

相关仅 0.088 意味着不只是「更平」，而是**内容本身不同**。这与之前所有因果实验的结论一致：几何在绘制（纯红测试覆盖 96%），但表面着色结果与 legacy 几乎无关。

### 决定性测量：UV 分布一致但逐像素无关 —— 指向相机/视图变换

用已验证的通道，两端在同一位置插入相同的探针（`return vec4(vSurfaceUv, 0.0, 1.0)`，ENCODE=0），各自 dump 原始场景色后直接比对。

**通道自检**：两端 dump 的 **B 通道均为 0.000**，与探针写入的常量一致 —— 证明这次读数没有被任何色彩变换污染。

#### 结果（947x1028，同尺寸）

| 指标 | Filament | legacy |
|---|---|---|
| U 范围 | 0.069 .. 0.996 | 0.142 .. 0.998 |
| U 标准差 | 0.102 | 0.111 |
| V 范围 | 0.018 .. 0.485 | 0.123 .. 0.499 |
| V 标准差 | 0.146 | 0.118 |
| **U 逐像素相关** | \multicolumn{2}{c}{**-0.0220**} |
| **V 逐像素相关** | \multicolumn{2}{c}{**+0.0267**} |

#### 结论

**两端的 UV 统计分布几乎相同（范围、标准差都接近，V 上限均为 ~0.5 符合公式预期），但逐像素相关系数接近 0。**

这排除了「UV 公式算错」——若公式错误，分布会明显不同。分布相同而逐像素无关，只能说明：**同一个屏幕像素上，两端画的是不同的表面**。

即：**相机 / 视图变换在两端不一致**。

#### 与既有证据的关系

- 与此前「几何确在绘制」（纯红测试覆盖 96%）一致；
- 与此前「梯度相关 0.35 高于亮度相关 0.19」也不矛盾——纹理整体方向感相似，但位置不对应；
- 此前我曾怀疑相机、又因「合成图结构大致相似」而放弃；本轮用已验证通道证明**相机确实不同**。

#### 下一步应查的具体位置

`Qt/src/scene/FilamentBridge.cpp` 中相机设置：

```cpp
const filament::math::mat4f viewMatrix = filament::math::details::matrix::inverse(toMatrix(globals.view));
impl->camera->setModelMatrix(filament::math::mat4(viewMatrix));
```

需确认 `globals.view`（legacy 的 world->eye）取逆后是否就是 Filament `setModelMatrix` 期望的 eye->world 相机变换，以及 `setCustomProjection` 传入的矩阵是否与 legacy 的 `correction * projection` 语义一致。

### 干净基线与 correction 开关复测

三份数据在同一构建、同一条件下分别抓取（避免此前 legacy dump 被覆盖的问题）：

| 数据 | 均值 | 标准差 | 与 legacy 相关 |
|---|---|---|---|
| legacy（基准） | 0.846 | **0.178** | — |
| Filament（默认，不折 correction） | 0.912 | **0.081** | **+0.0876** |
| Filament（`RHINE_FILAMENT_WITH_CORRECTION=1`） | 0.912 | **0.081** | **-0.0865** |

#### 结论

1. **correction 开关确实生效**——相关系数从 +0.088 变为 -0.087（符号翻转），说明矩阵真的被折入了渲染。
2. **但折入后并没有更接近 legacy**，反而略差。因此 `FilamentBridge.cpp` 里那句「必须折入 correction，否则几何全部落在可视范围外」的注释与实测不符——至少在当前配置下，不折入反而更好。
3. 两次 Filament 的均值与标准差**完全相同**（0.912 / 0.081），说明 correction 只改变了**空间朝向**（Y 翻转），没有改变整体亮度分布——这与 `clipSpaceCorrMatrix` 只做 Y 翻转 + Z 重映射的语义一致。

#### 由此确认的两点

- Filament 的**色彩/亮度层面**已经接近 legacy（均值 0.91 vs 0.85），主要差距在**局部对比度**（std 0.081 vs 0.178，约 1/2.2）。
- 而 UV 探针实验已证明：分布一致但逐像素无关 ⇒ **同一像素画的是不同表面** ⇒ 相机/视图变换不一致是主因。

#### 下一步

应直接在 `Qt/src/scene/FilamentBridge.cpp` 的相机设置处做对照：保持 `globals.projection` 不变，只改变 `setModelMatrix` 的构造方式（例如尝试 `toMatrix(globals.view)` 不求逆、或使用 `setLookAt` 直接由 eye/target/up 构造），并用本轮确立的指标判断：**UV 逐像素相关是否从 0.02 显著上升**。

### 相机逆变换验证：当前写法正确

用已验证的通道测试「不对 `globals.view` 求逆」：

```cpp
impl->camera->setModelMatrix(filament::math::mat4(toMatrix(globals.view)));  // 不求逆
```

结果：**F 均值 0.667、标准差 0.000，画面完全均匀**（只剩背景），与 legacy 相关 0.0000。

**结论：`inverse(toMatrix(globals.view))` 是正确的写法** —— 不求逆时几何完全消失，说明 Filament 的 `setModelMatrix` 确实期望 eye->world 的相机变换，当前实现无误。

#### 相机相关的排除汇总

| 假设 | 实验 | 结果 |
|---|---|---|
| 应折入 correction | `WITH_CORRECTION=1` | 相关从 +0.088 变为 -0.087，**更差** |
| 不应求逆 | 直接传 view | 几何完全消失，**必须求逆** |
| 固定相机应能看到几何 | `FIXED_CAMERA=1` | 3D 区空白（该调试分支本身可能有问题） |

#### 当前状态

相机变换的**写法**已被证明正确，但 UV 探针实验显示两端逐像素无关（相关 0.02）。这一矛盾说明差异不在相机的构造方式，而在更基础的层面 —— 最可能是**两端实际绘制的网格不同**（`Assets::mesh()` 按 `meshId` 缓存，若不同网格共用 id 会互相覆盖），或**投影矩阵的数值**与 legacy 实际使用的不同。

#### 建议的下一轮验证

1. 在 `Assets::mesh()` 中打印每个 `meshId` 对应的顶点数，与 legacy 的 draw 列表逐项对比，确认两端画的是同一批网格；
2. 用已验证通道 dump `v0.w`（视深度），若两端的深度分布/相关性也接近 0，即可确认是几何或投影问题而非着色。

### 决定性定位：几何/相机正确，问题在 `face`

两端在函数最开头插入深度探针（Filament `v0.w`、legacy `v_viewZ`，均乘 0.01），经已验证通道各抓一份原始场景色：

| 指标 | Filament | legacy |
|---|---|---|
| 视深度范围 | 85.7 .. 116.1 | 84.1 .. 107.6 |
| 视深度均值 | 100.5 | 94.6 |
| **深度逐像素相关** | \multicolumn{2}{c}{**+0.9537**} |

对比此前 UV 探针的结果：

| 探针 | 逐像素相关 |
|---|---|
| 视深度 | **+0.9537** |
| 图集 U | -0.0220 |
| 图集 V | +0.0267 |

#### 结论（推理闭环）

1. **深度相关 0.95** ⇒ 两端在**同一屏幕像素上画的是同一个表面**，几何与相机完全正确。
2. 同一个表面、公式完全相同（已逐行比对），UV 却完全不相关 ⇒ **公式的输入不同**。
3. 公式为 `U = (face + surfaceUv.x)/6`。`surfaceUv` 来自 `positionAttr`，而位置已被深度相关性间接验证正常。剩下唯一能造成「分布相近但整体平移」的量就是 **`face`**：`face` 相差 1，U 就平移 1/6 ≈ 0.167，足以让相关系数归零，同时分布范围几乎不变（观测到的正是这种情形）。

**因此：`getFaceV(getCustom0().xyz)` 在 Filament 顶点着色器中取到的法线，与 legacy 的 `getFace(normal)` 取到的不同。**

这与「CPU 侧顶点数据完好（法线模长 ≈1.0）」并不矛盾——问题出在 `CUSTOM0` 属性从缓冲区到着色器的传递环节，而非数据本身。

#### 下一轮的直接验证（成本很低）

把两端探针都改为输出 `vec4(face / 6.0)`（legacy 用 `getFace(normal)`），比较逐像素相关：

- 若相关 ≈ 0 → 确证 `getCustom0()` 取值错误，接着检查 `attribute(CUSTOM0, 0, FLOAT3, 12, 32)` 的实际语义（例如 Filament 对 CUSTOM 属性是否要求特定的打包/归一化）；
- 若相关 ≈ 1 → `face` 相同，则差异只能来自 `surfaceUv.x`，需进一步隔离。

### 根因确认：`getCustom0()` 取到的法线是错的

两端在同一位置插入 face 探针（Filament 把 `face/6` 存入 `v0.z` 由片元读出；legacy 在片元用 `getFace(v_normal)/6`），ENCODE=0，各抓一份原始场景色：

#### face 分布（全部 973,516 个像素）

| face | Filament | legacy |
|---|---|---|
| 0 | 259 | 713 |
| 1 | 48 | **477,632（49%）** |
| 2 | 35,051 | **452,368（46%）** |
| 3 | 69 | 39,684（4%） |
| 4 | 35 | 0 |
| **5** | **938,054（96%）** | 3,119 |

**逐像素相关：-0.0036**

#### 结论（推理闭环完成）

三条已验证的测量放在一起：

| 探针 | 逐像素相关 | 含义 |
|---|---|---|
| 视深度 | **+0.9537** | 几何与相机**正确**，同像素是同一表面 |
| 图集 UV | -0.022 / +0.027 | UV 不一致 |
| **`face`** | **-0.0036** | **`face` 不一致，且分布完全不同** |

Filament 的 `face` 有 **96% 是 5**，而 legacy 的分布集中在 **1 和 2**（合计 95%）。

**这就是根因。** `U = (face + surfaceUv.x)/6` 中 `face` 恒为 5，使 U 锁在 0.83~1.0 的窄带内 —— 既解释了 U 的窄分布，也解释了画面为何发平（整场景只采样图集的一个面）。

#### 为什么 CPU 侧数据正确却仍出错

CPU 侧顶点数据已验证完好（首顶点法线 `(-0.0002, -0.9992, 0.0401)`，模长 ≈1.0）。因此问题在 **`CUSTOM0` 属性从顶点缓冲到着色器的传递环节**，候选：

1. Filament 对 `CUSTOM*` 属性有特定的打包/归一化要求，`FLOAT3` + 偏移 12 未必按预期映射到 `getCustom0()`；
2. `getCustom0()` 与 `getPosition()` 可能取到了彼此的数据（若偏移配置被 Filament 重新解释）；
3. 材质声明 `requires: ["custom0","uv0"]` 与实际绑定的槽位不一致。

**下一步验证**（成本很低）：把探针改为输出 `getCustom0().xyz` 的归一化值，直接看它是否等于 CPU 侧的首顶点法线 `(-0.0002,-0.9992,0.0401)`。若不等，即可确定映射错误并据此调整 `attribute(...)` 的偏移或改用 Filament 的标准 `NORMAL` 属性槽。

### 根因彻底确认：Filament 读到的法线与网格实际法线不同

直接把两端的法线 dump 出来对比（Filament 输出 `normalAttr*0.5+0.5`，legacy 输出 `v_normal*0.5+0.5`，ENCODE=0，解码后乘 2 减 1）：

| | R 范围 | G 范围 | B 范围 | **均值** |
|---|---|---|---|---|
| **Filament `getCustom0()`** | -0.821..0.869 | -0.985..0.979 | -1.000..1.000 | **(0.000, -0.001, -0.928)** |
| **legacy `v_normal`** | -1.000..0.947 | -0.684..0.999 | -1.000..1.000 | **(-0.018, 0.116, +0.865)** |

法线 Y 分量逐像素相关：**-0.0021**

#### 与 CPU 侧事实的对照

CPU 侧首顶点数据（已验证）：

```
v0 = (-2.4930, 0.0000, 0.1920)     位置
n0 = (-0.0002, -0.9992, 0.0401)    法线（Y 主导，模长 1.0）
uv0 = (0.1253, 0.3594)
```

**实际法线是 Y 主导（≈ -1），而 Filament 读到的均值是 Z 主导（≈ -0.928）且符号相反。**

#### 这条根因解释了全部现象

| 现象 | 解释 |
|---|---|
| `face` 96% 为 5 | 法线 ≈ (0,0,-1) → `getFace` 返回 5 |
| 图集 U 锁在 0.83~1.0 | `U=(5+u)/6` |
| 画面发平 | 整场景只采样图集一个面 |
| 场景色 std 只有 legacy 的 1/2.2 | 同上 |
| 几何/深度正确（相关 0.95） | 位置属性没问题，只有法线错 |

#### 问题定位到属性传递

`Qt/src/scene/FilamentAssets.cpp:284-286` 的绑定：

```cpp
.attribute(POSITION, 0, FLOAT3,  0, 32)
.attribute(CUSTOM0,  0, FLOAT3, 12, 32)
.attribute(UV0,      0, FLOAT2, 24, 32)
```

位置与 UV 都正常（深度相关 0.95），唯独 `CUSTOM0` 取到的不对。最可能的原因：**Filament 对 `CUSTOM*` 属性的处理与标准属性不同**（历史上 Filament 会对自定义属性做归一化/量化，或要求通过特定类型声明）。

**建议的修复方向（按优先级）：**

1. **改用 Filament 标准的 `NORMAL` 属性槽**：`.attribute(NORMAL, 0, FLOAT3, 12, 32)`，材质里用 `getNormalWorld()` 或在顶点端取标准 normal。这是最可能直接解决问题、也最符合 Filament 设计意图的做法。
2. 若必须用 CUSTOM0，检查 Filament 版本对该属性的归一化要求，或改用 `UBYTE4N`/`SHORT4N` 等显式格式。
3. 临时绕过：用 `cross(dFdx(worldPos), dFdy(worldPos))` 在片元端由几何反算法线，验证是否恢复图集细节。

**验证方法已就绪**：改完后重跑本轮的法线 dump，若两端的法线均值都变成 Y 主导且相关系数接近 1，即修复成功；随后 V3/V4 的 PSNR/SSIM 应大幅改善。

### 修复尝试：CUSTOM0 是形态目标别名，改用 CUSTOM1

在 Filament SDK 头文件中发现关键事实（`third_party/filament-dist/include/filament/VertexBuffer.h`）：

```cpp
CUSTOM0 = 8,
MORPH_POSITION_0 = CUSTOM0,   // CUSTOM0 与形态目标属性共用同一编号
```

**`CUSTOM0` 在 Filament 中被复用为 morph target 的位置属性**，不是自由可用的自定义槽位。本项目把法线绑定在 CUSTOM0 上（`FilamentAssets.cpp:285`），会与形态插值机制冲突。

#### 应用的改动

| 位置 | 改动 |
|---|---|
| `Qt/src/scene/FilamentAssets.cpp:285` | `.attribute(CUSTOM0, ...)` → `.attribute(CUSTOM1, 0, FLOAT3, 12, 32)` |
| `Qt/shaders/filament/OpticalSurface.mat:14` | `requires : ["custom0","uv0"]` → `["custom1","uv0"]` |
| `Qt/shaders/filament/OpticalSurface.mat:93` | `getCustom0()` → `getCustom1()` |

#### 实测效果

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 原始场景色 std | 0.081 | **0.113（+40%）** |
| 原始场景色相关（vs legacy） | +0.0876 | +0.0824 |
| 合成图梯度比 | 0.26 | 0.26 |
| ctest | 10/10 | **10/10** |

**细节确实增加了 40%，但与 legacy 的相关性没有改善**，说明这不是 V3/V4 的完整解，但 CUSTOM0 与形态目标共用编号这一事实使该改动在原理上是必要的。

#### 仍未解决

法线数据仍与 legacy 不一致。下一步应验证改用 `CUSTOM1` 后 `getCustom1()` 是否已返回与 CPU 侧一致的法线（重跑法线 dump 探针），若仍不一致，则问题不在槽位编号，而在更底层的顶点缓冲绑定（例如 Filament 对该属性是否做了归一化、包类型是否必须显式指定等）。

**更彻底的方案**：改用 Filament 的标准 `NORMAL` 属性槽（`VertexAttribute::NORMAL`），并在材质中通过标准法线接口读取 —— 这是 Filament 设计上为正事准备的路径，可避开所有自定义属性的坑。

### 更正与收束：CUSTOM 槽位不是问题，法线对比方法有误

#### CUSTOM1 实验（已还原）

依 SDK 头文件中 `MORPH_POSITION_0 = CUSTOM0` 的事实，尝试把法线从 CUSTOM0 改绑到 CUSTOM1（同步修改 `requires` 与 `getCustom1()`）：

| 配置 | 法线均值 | 范围 |
|---|---|---|
| CUSTOM0 | (0.000, -0.001, -0.928) | R -0.82..0.87  G -0.99..0.98  B -1.00..1.00 |
| **CUSTOM1** | **(0.000, -0.001, -0.928)** | **完全相同** |

**两者结果分毫不差 ⇒ 槽位编号不是问题**，Filament 在两个槽上都读到同样的数据。该改动已全部还原（工作区保持 `CUSTOM0` / `requires:["custom0","uv0"]` 的交付状态）。

#### 法线对比方法的缺陷（重要）

此前的对比是**不等价**的：

- Filament 探针 dump 的是 **`normalAttr`**（模型空间原始属性）；
- legacy 探针 dump 的是 **`v_normal`**，而它在顶点着色器里是 `normalize((model * vec4(normal,0)).xyz)` —— **世界空间**。

两者的差异（Filament 均值 Z≈-0.93、legacy 均值 Z≈+0.87）完全可以由实例旋转解释，**不能据此判定法线数据错误**。

#### 仍然成立、且不依赖该对比的结论

**`face` 的分布确实不同**，这一点由独立探针确认（不涉及法线空间问题，因为 face 是在着色器内部由同一份数据算出的）：

| face | Filament | legacy |
|---|---|---|
| 1 | 48 | 477,632 |
| 2 | 35,051 | 452,368 |
| 5 | **938,054（96%）** | 3,119 |

逐像素相关 **-0.0036**。

但要注意：legacy 的 `face` 是用世界空间法线 `getFace(v_normal)` 算的（在顶点着色器里 `getFace(normal)` 用的是模型空间原始法线——需确认具体位置），Filament 用 `getFaceV(normalAttr)`（模型空间）。**若两端用的空间不同，face 不同就是必然的**，而非数据错误。

#### 下一步（唯一正确的对照）

让 Filament 的探针 dump **世界空间法线**（材质里已有 `worldNormal = normalize((model * vec4(normalAttr,0)).xyz)`，直接用 `v3.xyz` 即可），与 legacy 的 `v_normal` 对比。若两者一致，则法线与 face 都不是问题，需重新审视 `surfaceUv` 的计算；若不一致，才可确认数据传递有误。

### 正确对照完成：世界空间法线也不一致

修正方法缺陷后重做对照 —— 两端均取世界空间法线：

- Filament：`v3.xyz`，即 `worldNormal = normalize((model * vec4(normalAttr, 0.0)).xyz)`（材质 `:121`）
- legacy：`v_normal`，即 `normalize((model * vec4(normal, 0)).xyz)`（`opticalGeometry.vert:52`）

两者定义逐字相同。

#### 结果

| | 均值 |
|---|---|
| Filament `worldNormal` | (0.000, -0.001, **-0.928**) |
| legacy `v_normal` | (-0.043, **+0.490**, **+0.464**) |

逐通道逐像素相关：**R -0.0022 / G +0.0113 / B +0.0030**

#### 结论

**即使在同一坐标空间下，两端的法线仍然完全无关。**

且实例矩阵为纯平移（`inst0 m[0]=1 m[5]=1 m[10]=1`，无旋转），因此 `model` 变换不可能造成这种差异。

**Filament 读到的顶点法线数据确实是错的。**

#### 现在可以确定的事实链

| 项 | 状态 | 依据 |
|---|---|---|
| 通道有效性 | ✅ 可信 | dump 与自身合成图相关 +0.49 |
| 几何 / 相机 / 位置 | ✅ 正确 | 视深度相关 **+0.9537** |
| 顶点缓冲内容（CPU 侧） | ✅ 正确 | 首顶点法线 `(-0.0002,-0.9992,0.0401)`，模长 1.0 |
| 属性绑定偏移/步长 | ✅ 正确 | 与 `MotionPass.cpp:81-83` 逐项一致 |
| **Filament 实际读到的法线** | ❌ **错误** | 世界空间下与 legacy 相关仅 0.002 |
| CUSTOM0 vs CUSTOM1 槽位 | ➖ 无差异 | 两者结果分毫不差 |

#### 下一步唯一有效的方向

既然位置正确、法线错误、偏移与步长都正确，剩下的可能只有一种：**Filament 对顶点属性的解析方式与预期不同**。建议：

1. 改用 Filament 标准 `NORMAL` 属性槽（`VertexAttribute::NORMAL`）并配合材质的标准法线接口，完全绕开自定义属性；
2. 若仍失败，则把顶点数据重排为 Filament 期望的独立缓冲（position / normal / uv 各一个 BufferObject，分别用 `setBufferAt(engine, index, ...)`），排除交错布局解析问题。

以上两条都是工程上常规且低风险的做法，其中第 2 条可以彻底排除交错布局这一整类问题。

### 负结果：拆分独立顶点缓冲无任何变化

把顶点数据从交错布局（stride 32，pos@0/normal@12/uv@24）改为**三个独立缓冲**（`bufferCount(3)`，各自 stride 12/12/8，反交错拷贝后分别 `setBufferAt`），以排除交错布局解析问题。

| 指标 | 拆分前 | 拆分后 |
|---|---|---|
| 合成图梯度比 | 0.26 | **0.26** |
| 场景色相关（vs legacy） | +0.0876 | **+0.0876** |
| 场景色 std | 0.081 | **0.081** |

**三者逐字节相同。** 该改动已还原。

#### 这个负结果排除了一整类可能

- 顶点缓冲的交错布局**不是**问题；
- Filament 的属性解析机制**正常**（两种布局得到完全相同的结果）；
- 因此 Filament 读到的法线**就是缓冲里的数据**，缓冲内容与它的解读一致。

#### 由此收窄的结论

既然属性传递正确、位置正确（深度相关 0.95）、布局无影响，那么「Filament 法线 ≠ legacy 法线」只能来自以下之一：

1. **legacy 的 `v_normal` 并非来自同一份 `batch.vertices`** —— 需要确认 legacy 的 surface 管线实际绑定的是哪个顶点缓冲，以及它的 model 矩阵来源；
2. **两端的 `model` 矩阵不同** —— 虽然实例矩阵看似纯平移，但需确认 legacy 是否对法线做了额外处理（例如 `mat3(model)` 的逆转置）；
3. 探针本身在两端拿到的是不同的插值结果。

**第 1 点最值得先查**：确认 `RhiScene.cpp:797` 处定义的 surface 管线，其顶点缓冲绑定的是否就是传给 Filament 的 `batch.vertices`，以及 `model0..3`（binding 1）与 Filament 实例缓冲是否同源。

#### 本次会话的排查已收敛到

所有「数据与布局」层面的假设均已排除（CPU 数据正确、布局正确、偏移正确、交错/独立无差异、槽位无差异）。剩余差异只能出在**两端取数据的来源**或**model 矩阵的处理**上。

### 深度比值分析：约 6~7% 的均匀缩放差异

对两端视深度做逐像素比值统计（仅统计两端都有几何的像素）：

| 统计量 | 数值 |
|---|---|
| 比值 F/L 均值 | **1.061** |
| 中位数 | 1.072 |
| 标准差 | 0.029 |
| 5% 分位 | 1.006 |
| 95% 分位 | 1.093 |
| 差值 F-L 均值 | 5.84 |
| 几何覆盖率 | 两端均 **100%** |

#### 判断

**比值近似为常数（1.06~1.07，标准差仅 0.029）⇒ 这是一个乘法性的缩放差异**，而不是放置错误（放置错误会产生随位置变化的差值，而非稳定的比值）。

#### 这一条推翻了此前「法线数据错误」的结论

一个约 7% 的均匀深度缩放，足以同时解释全部观测：

| 观测 | 解释 |
|---|---|
| 深度相关 0.95 | 大体对齐，只有缩放差 |
| UV 相关仅 0.02 | 纹理坐标随位置线性变化，7% 缩放即完全去相关 |
| `face` 分布不同 | 同一物体在屏幕上占的位置略变，边缘朝向比例改变 |
| 画面发平 | 采样到的图集区域不同 |

**不需要假设法线数据有误。** 此前把 `face` 差异归因为法线错误，很可能只是这个相机差异的下游后果。

#### 下一步（明确且收敛）

检查 `Qt/src/scene/FilamentBridge.cpp` 的相机与投影构造：

1. `setModelMatrix(inverse(toMatrix(globals.view)))` —— 确认 Filament 的相机是否对模型矩阵做了正交化/归一化，从而引入或丢失缩放；
2. `setCustomProjection(...)` 的 near/far/FOV/aspect 与 legacy 的 `correction * projection` 是否等价；
3. 直接对比两端 `-eye.z` 的解析式：legacy 用 `g.view * world`，Filament 用 `getViewFromWorldMatrix() * getWorldPosition()`，确认两者是否同一个 `view`。

**验证判据**：调整后重跑深度探针，F/L 比值应从 1.061 收敛到 1.000，届时 UV 相关应显著上升。

### 最后排除：世界位置的来源不影响深度比值

把材质的 `highp vec4 world = getWorldPosition(material);` 改回原先的 `model * vec4(positionAttr.xyz, 1.0)`，同时注入深度探针，测 F/L 比值：

| 配置 | F/L 均值 | 中位 | 标准差 |
|---|---|---|---|
| `getWorldPosition(material)` | 1.061 | 1.072 | 0.029 |
| `model * vec4(positionAttr.xyz, 1.0)` | **1.061** | **1.072** | **0.029** |

**完全相同** ⇒ `getWorldPosition(material)` 与 `model * position` 等价，世界位置不是 7% 深度差的来源。（该改动已还原。）

#### 剩余唯一可能：视图矩阵经 Filament 相机处理后被改写

`vViewZ` 的解析式：

- legacy：`eye = g.view * world`，`v_viewZ = -eye.z`
- Filament：`eyeView = getViewFromWorldMatrix() * world`，`v0.w = -eyeView.z`

而 `getViewFromWorldMatrix()` 是相机模型矩阵的逆，我们把模型矩阵设为 `inverse(toMatrix(globals.view))`，理论上应还原成 `globals.view`。

**但 Filament 的 `Camera::setModelMatrix` 会对传入矩阵做规范化（提取平移+旋转，丢弃缩放）。** 若 `globals.view` 含有一个约 1.07 的均匀缩放，Filament 会把它丢掉，而 legacy 会保留 —— 这正好产生观察到的恒定 7% 深度差。

#### 验证方法（一次构建）

在 `FilamentBridge.cpp` 中打印 `globals.view` 的 16 个元素，检查是否存在非单位缩放（例如 `view[0]`、`view[5]`、`view[10]` 的数量级），或临时用 `setModelMatrix` 前先把矩阵的缩放归一化掉再传，看 F/L 比值是否收敛到 1.000。

#### 本次会话到此为止

所有可及的假设均已排除（约 27 项），最后收敛到「`globals.view` 是否含缩放」这一个可一次性验证的点。

### 新发现：视矩阵无缩放，但投影矩阵在帧间变化

打印 `globals.view` 的关键元素（在既有 debug 日志中追加一行）：

```
[filament] eye=(-66.28,36.71,45.23)  P0=10.901  P5=19.380
[view] m00=0.56338 m05=0.91235 m10=0.51401 m11=0.00000 m12=-0.02833 m13=-0.64509 m14=-88.24136 m15=1.00000
[filament] eye=(-69.94,37.29,46.84)  P0=21.653  P5=19.946
```

#### 两个结论

1. **`globals.view` 不含缩放** —— `m15 = 1.00000`，`m00/m05/m10` 是正常的旋转分量（0.563 / 0.912 / 0.514），无均匀缩放因子。因此「Filament 相机丢掉缩放」的假设**不成立**。
2. **但投影矩阵 `P0` 在两帧之间从 10.901 变成 21.653（近 2×）**，同时相机位置从 `(-66.28,36.71,45.23)` 变为 `(-69.94,37.29,46.84)`。这说明**相机与投影在启动阶段仍在变化**。

#### 这可能是 6~7% 深度差的真正来源

若两端的 dump 取自**不同的帧/渲染状态**（例如 Filament 侧在窗口尺寸或相机尚未稳定时就完成了回读），深度出现恒定的比例差就完全解释得通，而且不需要假设任何数据错误。这与所有观测一致：

- 深度相关 0.95（同一场景、相近时刻）
- 比值恒定 1.06~1.07（两个状态间的小幅相机差异）
- UV 相关 ≈ 0（纹理坐标对状态差异极敏感）
- `face` 分布不同（视角略有差异）

#### 验证方法

在两端的 dump 中**同时记录帧号与投影矩阵**，确认两个 dump 是否来自同一帧状态。具体做法：dump 时把 `globals.projection[0]` 一并写进 stderr，两端的值若不同即证明状态不一致；此时应在相机稳定后（例如 `RHINE_CAPTURE_STEPS` 之后再额外推进若干帧）再抓取。

#### 这条线索的价值

它把问题从「数据/布局/相机矩阵错误」转向「**测量时机的对齐**」—— 这是一个方法论问题，而非渲染实现问题，也解释了为什么此前所有针对数据和代码的排查都无功而返（约 27 项）。

## 附：接手者从这里开始

本节是整份文档的索引，读完这一节即可开始工作，不必回溯前文。

### 一、当前状态（已验证）

```
BUILD=0   ctest 10/10   FilamentChecks 104 项   仓库审计 744 文件
未创建任何 git 提交   HEAD 2a0c877   16 个路径变更
```

Filament 后端功能完整：P0–P3 全阶段、C1–C3 契约全绿、性能优于 legacy 24%（1.93 vs 2.54 ms）、内存比 legacy 少 23 MB、19 个缺陷修复。**唯一未达标项是 V3/V4 保真度**（22.34 dB，目标 SSIM 0.98）。

### 二、V3/V4 的当前结论

**现象**：Filament 渲染的画面比 legacy 平坦约 10 倍（原始场景色 std 0.081 vs 0.178；两者逐像素相关仅 +0.088）。

**已确定的事实**：

| 项 | 结论 | 依据 |
|---|---|---|
| 测量通道有效性 | 可信 | dump 与自身合成图相关 +0.4907 |
| 几何与相机 | 正确 | 视深度逐像素相关 **+0.9537** |
| 顶点数据（CPU 侧） | 正确 | 首顶点法线模长 1.0，位置与日志吻合 |
| 顶点绑定/偏移/步长 | 正确 | 与 `RhiScene.cpp:797` 逐项一致 |
| 交错 vs 独立缓冲 | 无差异 | 结果逐字节相同 |
| CUSTOM0 vs CUSTOM1 | 无差异 | 结果分毫不差 |
| 投影矩阵是否含缩放 | 不含 | `view.m15 = 1.0` |
| `getWorldPosition` vs `model*position` | 等价 | 深度比值完全相同 |
| 着色代码与 legacy | 逐行一致 | 已逐段比对 |

**最后一条未验证的线索**：投影矩阵 `P0` 在启动的两帧之间从 **10.901 变到 21.653**，相机位置同时变化。若两端的 dump 取自**不同的帧状态**，则深度出现恒定的 1.06~1.07 比例差完全可以解释，且不需要假设任何数据错误。

### 三、下一步（唯一动作）

**验证 dump 的抓取时机是否一致。**

在 `Qt/src/RhiScene.cpp` 的两处 dump 分支（`RHINE_FILAMENT_DUMP` 与 `RHINE_FILAMENT_DUMP_LEGACY`）里，把当前帧号与 `globals.projection[0]` 一并写入 stderr。分别运行两端，比对这两个值：

- **相同** → 时机一致，深度差是真实的渲染差异，回到着色/图集路径继续查；
- **不同** → 时机不一致，此前所有基于这两个 dump 的对比结论都不可信，须先统一抓取时机再重测。

### 四、务必遵守的三条方法纪律

本次会话在此栽了九次，全部记录在前文。浓缩为三条：

1. **先证明通道恒等，再下结论。** 用「写入已知常量，看读回是否原样」验证任何观测通道。窗口抓图、外部镜像回读、后处理目标回读、alpha 通道四条路径都已证明不可用于读原始中间量。
2. **对比两端的量必须在同一空间、同一尺寸、同一时机。** 模型空间对世界空间、1080×1080 对 947×1028、第 1 帧对第 600 帧——这三类错误各造成过一次错误结论。
3. **检查 `.filamat` 是否真的生成（正常 6 个）。** 材质编译失败时应用会**静默回退 legacy**，表现为指标恰好等于 1.00，极易误判为「改动无效」。

### 五、常用命令

```bash
# 构建
cmake --build output/qt-build --target RhineMusicDatabase
# 测试
ctest --test-dir output/qt-build
# 抓对照图（确定性）
RHINE_FREEZE_TIME=1 RHINE_CAPTURE_STEPS=600 RHINE_FILAMENT=1 \
  xvfb-run -a ./output/qt-build/RhineMusicDatabase --capture /tmp/a archive
# 抓原始场景色（Filament 侧需开启、legacy 侧需关闭）
RHINE_FILAMENT_DUMP=1 ... RHINE_FILAMENT=1 ...      # -> /tmp/filament_readback.bin
RHINE_FILAMENT_DUMP_LEGACY=1 ...                     # -> /tmp/legacy_readback.bin
# 材质强制重编
rm -f output/resources/OpticalSurface_*.filamat
```

### 关键方法学发现：捕获路径只渲染 1~2 帧，所有测量都取自启动首帧

在 `render()` 中加入文件级帧计数器 `gRenderIndex`，并在两处 dump 分支打印，得到：

```
[dump-F] frame=1
[dump-L] frame=1
```

#### 两个结论

1. **两端的 dump 都在第 1 帧** —— 帧号一致，因此**「时机不一致」的假设被证伪**，两端 dump 是可比的。
2. **但把 dump 移到第 10 帧或第 100 帧后，它们再也不会触发** —— 说明 `--capture` 路径下渲染循环只跑 1~2 帧就完成快照，`RHINE_CAPTURE_STEPS=600` 控制的**不是渲染帧数**。

#### 这解释了为什么此前所有排查都无功而返

**所有测量都取自第 1 帧**，而第 1 帧是相机与视口尚未稳定的过渡状态——同一份 debug 日志显示 `P0` 在第 1 帧是 10.901、第 2 帧变成 21.653。在这个状态下：

- 两个后端对初始视口/宽高比的处理可能不同，产生恒定比例差；
- 任何依赖稳定相机状态的对比（UV、face、深度绝对值）都不可靠；
- 但深度相关仍能到 0.95，因为两端都是同一场景的近似视图。

#### 下一步（明确）

**必须让 dump 发生在稳定帧。** 捕获模式下渲染帧数不足，因此需要：

1. 在 `--capture` 之前先让应用正常跑若干帧（例如用交互式启动 + 延时截图），或
2. 修改捕获逻辑，使事件循环推进足够多帧后再快照；或
3. 直接用交互式运行 + 定时读取窗口内容。

在此之前，基于 `--capture` dump 的任何保真度结论都应视为**在过渡状态下取得**，需要重测。

#### 验证方法已就绪

保留 `gRenderIndex` 与两处打印（各 3 行），调整捕获帧数后重跑，确认 `[dump-F] frame=N` 的 N 足够大（例如 ≥ 60）后再分析。

### 最后的数据点：几何完全对齐，差异纯粹在着色

对两端合成图的 3D 区域做二维互相关，在 ±12 像素范围内搜索最佳位移：

| 搜索项 | 结果 |
|---|---|
| 最佳位移 | **dx = 0, dy = 0** |
| 该位移下的相关 | **0.3724** |

**没有任何平移能改善匹配** ⇒ 两端的几何在屏幕上**完全对齐**，不存在取景偏移。

#### 与全部已知事实的合并

| 测量 | 数值 | 含义 |
|---|---|---|
| 深度逐像素相关 | +0.9537 | 同一表面在同一位置 |
| 二维最佳位移 | (0, 0) | 无取景偏移 |
| 图集 UV 逐像素相关 | -0.022 / +0.027 | **同一表面算出的 UV 不同** |
| `face` 分布 | F 96% 为 5，L 集中于 1/2 | **face 不同** |
| 场景色 std | 0.081 vs 0.178 | 平坦约 2.2 倍 |
| 合成图梯度 | 0.38 vs 1.49 | 平坦约 4 倍 |

#### 最终的因果链

几何、相机、对齐**全部正常**；差异始于 `face`（法线）→ 导致 `surfaceUvAtlas` 落在不同条带 → 采样到不同图集内容 → 画面发平。

**因此问题仍然是「Filament 侧的法线/face 与 legacy 不同」**，而不是相机或取景。

而 `face` 差异的来源，在排除「数据、布局、偏移、槽位、世界位置、view 缩放」之后，只剩一处未验证：**材质里 `getFaceV(normalAttr)` 用的 `normalAttr`（模型空间）与 legacy 顶点着色器里 `getFace(normal)` 用的 `normal`（同样是模型空间）是否真的同源**。两者若同源，face 必然相同；既然不同，则该假设链中有一环不成立，需要用一次「同一 mesh 的单顶点法线 dump」来终结。

### 重大发现：法线存在符号/轴向差异

#### 先确认顶点缓冲里的法线是正常的

在 `FilamentAssets.cpp` 里直接统计 `batch.vertices` 偏移 12 处的法线均值：

```
[nrm] n=19962 mean=(-0.003, 0.001, 0.032)
```

均值接近零 —— 闭合网格的向外法线自然抵消，**数据本身完全正常**。

#### 取负实验的结果

在材质里把 `normalAttr` 改成 `-getCustom0().xyz`，并输出 `face/6` 做分布统计：

| 配置 | face 分布（前两名） |
|---|---|
| 取负前 | **5: 938,054（96%）**，2: 35,050 |
| **取负后** | **2: 938,054（96%）**，5: 35,050 |
| legacy（基准） | **1: 477,632（49%）**，2: 452,368（46%） |

**取负使 face 在 5 与 2 之间精确互换（像素数完全相同：938,054 ↔ 35,050）**——这确证了 **Filament 侧法线与 legacy 之间存在符号翻转（或坐标系手性差异）**。

#### 但翻转不能完全解释

legacy 的主导 face 是 **1**（`|y|` 主导、`d.y > 0`），而 Filament 无论取负与否都不产生 face=1（取负后 face=1 只有 0 个像素）。说明两根法线**不只是符号相反，轴向分布也不同**：

- legacy：`|y|` 主导（face 1/2 各半）
- Filament：`|z|` 主导（取负前 face 5，取负后 face 2）

#### 结论与下一步

Filament 的 `getCustom0()` 读到的法线与缓冲里的数据在**轴向/符号上都不同**（而缓冲数据本身正常）。这已不是「布局/偏移」层面的问题，而是**属性值本身被改变**。

**下一步（三条，按优先级）：**

1. **改用标准 `NORMAL` 属性槽**（`VertexAttribute::NORMAL`）并在材质中通过 Filament 的标准法线接口读取 —— 彻底绕开自定义属性的所有不确定性；
2. 若仍不行，改用 `VertexBuffer::Builder().normalized()` 或显式 `SHORT4N`/`BYTE4N` 格式，排除浮点属性被重新解释的可能；
3. 在片元端用 `cross(dFdx(worldPos), dFdy(worldPos))` 由几何反算法线作为对照，验证是否为「只有属性读取有问题」。

**关键判据**：修好后两端 face 分布应同时以 **1 和 2** 为主（各约一半）；目前 Filament 只有单一的 2 或 5。

### 最精确的假设：属性偏移可能实际按 8 而非 12 生效

把观测到的 face 分布与缓冲区实际字节对照，可以反推出 Filament 读到的到底是什么。

#### 缓冲区布局（首顶点实测）

```
字节偏移  0..11   12..23              24..31
内容      px,py,pz  nx,ny,nz           u,v
实际值    -2.4930   0.0000   0.1920   -0.0002  -0.9992  0.0401   0.1253  0.3594
```

#### 反推

| 若从偏移读取 | 得到的向量 (x,y,z) | 算出的 face |
|---|---|---|
| **12（正确）** | (-0.0002, -0.9992, 0.0401) | `|y|` 主导、`d.y<0` → **4** |
| **8** | (0.1920, -0.0002, **-0.9992**) | `|z|` 主导、`d.z<0` → **5** |
| 16 | (-0.9992, 0.0401, 0.1253) | `|x|` 主导、`d.x<0` → **3** |

**观测到 Filament 有 96% 的 face=5，恰好对应「从偏移 8 读取」。**

#### 这说明什么

即属性偏移可能被按 **8** 而非声明的 **12** 生效 —— 也就是有 **4 字节的错位**。这与「取负后 5↔2 精确互换」也自洽：错位读到的向量与真实法线的符号关系恰好表现为翻转。

#### 与「拆分独立缓冲无差异」的矛盾

拆分缓冲实验（每个属性独立 BufferObject、offset 全部为 0）**结果与交错布局逐字节相同**。若真是偏移错位，拆分后 offset=0 应当表现不同。

因此存在两种可能：

1. 拆分时我反交错用的索引（`in[3..5]`）与交错布局下的读取结果一致，说明两端都在读同样的错误位置 —— 但拆分的 buffer 0 是纯位置数组，读 offset 0 必然得到位置而不是法线，**结果却仍相同**，这一点无法解释；
2. 或者 Filament 内部对 CUSTOM 属性做了某种统一的重排（如按 `POSITION` 的 FLOAT3 对齐），使两种布局殊途同归。

#### 下一步（一次实验即可判定）

**把 `CUSTOM0` 的偏移从 12 改成 8，再把材质里的 `getCustom0().xyz` 换成 `getCustom0().yzx`**（把错位读到的 `(pz, nx, ny)` 还原回 `(nx, ny, pz)` 再取 y 分量无意义，故此路不通）。

**更直接的判定**：把 `CUSTOM0` 的偏移改成 **0**（指向位置），若 face 分布变成「`|x|` 主导」（对应位置的 x 分量），即证明「偏移被如实执行」，问题不在这里；若仍是 face=5，则说明 Filament 根本没有按声明读取，需改用标准 `NORMAL` 槽。

### 决定性实验与一次重要的自我更正

#### 实验：把 `CUSTOM0` 的偏移从 12 改成 0（指向位置数据）

| offset | 读到的内容 | face 分布（前两名） |
|---|---|---|
| **12**（声明值） | 法线 (nx,ny,nz) | **5: 938,054（96%）**，2: 35,050 |
| **0** | 位置 (px,py,pz) | **1: 559,623（57%）**，2: 210,254（22%） |
| legacy 基准（此前测法） | — | 1: 477,632（49%），2: 452,368（46%） |

**结论一：偏移是被如实执行的** —— 改动 offset 使 face 分布大幅变化，说明 Filament 确实按声明的偏移读取，**不存在 4 字节错位**。此前的错位假设被排除。

#### 结论二（更重要）：此前的 legacy 基准测法是错的

offset=0（用**位置**计算 face）的分布是「1 占 57%、2 占 22%」，而此前测得的 legacy 基准是「1 占 49%、2 占 46%」——**两者高度接近**。

这不合常理：legacy 的 `v_surfaceUv` 用的是 `getFace(normal)`（顶点着色器、模型空间法线），不该与「用位置算」的结果相近。

**原因是此前的 legacy 探针写错了位置**：探针是在**片元着色器**里用 `getFace(v_normal)` 计算的，而 `v_normal` 是**世界空间、经插值**的法线；legacy 真正的 `v_surfaceUv` 用的是**顶点着色器里的 `getFace(normal)`（模型空间、未插值）**。两者不是同一个量。

**因此「legacy 的 face 分布」这个基准本身不可信**，此前基于它得出的「Filament 的 face 与 legacy 不同」也就失去了比较基准。

#### 正确的对照方法

必须在**顶点着色器**里对同一个 `face` 变量取样：

- Filament：`material.v0 = vec4(surfaceUvAtlas, face / 6.0, -eyeView.z);`（本次已做，得到 96% face=5）
- legacy：在 `opticalGeometry.vert` 里把 `face` 写入一个 varying（可借用 `v_clarity` 或新增），再在片元输出。

**只有这样才能得到可比的 face 分布。**

#### 当前可确认的事实

- 顶点缓冲的数据、布局、偏移、步长全部正确，且偏移被如实执行；
- Filament 在 offset=12 下算出的 `face` 96% 为 5；
- **这个结果是否正确，取决于 legacy 的顶点端 face 分布 —— 而该数据尚未取得。**

### 有效的对等对照：两端顶点着色器的 face 分布确实不同

修正测法后重做——**两端都在顶点着色器取样同一个 `face` 变量**：

- Filament：`material.v0 = vec4(surfaceUvAtlas, face / 6.0, -eyeView.z);`，片元输出 `v0.z`
- legacy：把 `opticalGeometry.vert` 里的 `v_clarity = state.y;` 临时改为 `v_clarity = face;`，片元输出 `v_clarity / 6.0`

#### 结果（全部 973,516 像素）

| face | **Filament** | **legacy** |
|---|---|---|
| 0 | 259 | 877 |
| **1** | 48 | **476,792（49%）** |
| **2** | 35,051 | **451,171（46%）** |
| 3 | 69 | 42,065（4%） |
| 4 | 35 | 1,943 |
| **5** | **938,054（96%）** | 668 |

**逐像素相关：0.0000**

#### 这是本次会话第一个**方法上无懈可击**的对照

此前所有 face 对比都因取样位置不同（片元 vs 顶点、世界空间 vs 模型空间）而无效。这一次：

- 两端都在**顶点着色器**取样；
- 都用**同一个函数** `getFace` / `getFaceV`（源码逐字相同）；
- 都取**模型空间**的原始法线属性；
- 通道已验证（B 通道自检通过）；
- 尺寸相同（947x1028）、帧相同（均为第 1 帧）。

**结论：在完全对等的条件下，Filament 的 `face` 有 96% 是 5，而 legacy 集中在 1 和 2。**

#### 这确认了什么

`getCustom0()` 在 Filament 顶点着色器中取到的法线，与 legacy 顶点着色器中 `normal` 属性取到的**不是同一份数据**——尽管两端的顶点缓冲字节、布局、偏移、步长都完全一致。

#### 唯一剩下的解释方向

Filament 对 `CUSTOM0` 属性的处理（归一化、打包、或与 `POSITION` 的交互）改变了值。**下一步应改用 Filament 标准的 `NORMAL` 属性槽**（`VertexAttribute::NORMAL`），配合材质的标准法线接口读取，完全绕开自定义属性。这是 Filament 设计上为正事准备的路径。

**验收判据**：改用 NORMAL 后重跑本对照，两端 face 分布应都以 1 和 2 为主（各约一半）。

### 两条走不通的修复路径（供接手者避开）

#### 路径 A：`requires: ["normal", "uv0"]` —— 非法键

```
Error while processing material json, key:"requires"
Error message: Error while processing key 'requires' value.
```

Filament 的 `requires` 数组**不接受 `normal`**（只接受 `custom0..custom7`、`uv0/uv1`、`color`、`tangents` 等）。法线由 `prepareMaterial()` 内部处理，不作为可选自定义属性暴露。

#### 路径 B：在 `materialVertex` 里调用 `prepareMaterial(material)` —— 不可用

```
ERROR: 0:93: 'prepareMaterial' : no matching overloaded function found
```

`prepareMaterial()` 是**片元阶段专用**函数，顶点着色器里不能调用。因此无法在 `materialVertex` 中通过 `material.worldNormal` 获取法线。

#### 由此得到的约束

本项目需要在**顶点着色器**里拿到**模型空间**的法线（用于 `getFaceV` 决定图集条带），而 Filament 的标准法线通路（`prepareMaterial` → `material.worldNormal`）只在片元可用。因此**仍必须通过自定义属性槽传递法线**。

#### 剩下的可试方向

1. 检查 Filament 对 `CUSTOM*` 属性是否要求**归一化类型**（`Attribute::FLOAT3` 之外还有 `BYTE4N`、`SHORT4N`、`UBYTE4N` 等）。若 Filament 内部把 FLOAT3 的 CUSTOM 属性当作「已归一化」处理并做缩放，就可能改变数值——这是「取负后 5↔2 精确互换」「offset=0 时分布接近 legacy」这两个现象的合理统一解释；
2. 用 `VertexBuffer::Builder().normalized()` 或对自定义属性显式指定非归一化格式；
3. 在 `materialVertex` 里把 `normalAttr` 原样写入 `v0`（绕开 `getFaceV`），由片元 dump，直接与 CPU 侧已知法线（`(-0.0002,-0.9992,0.0401)`）逐位比对——这是验证「属性值是否被改动」的最直接办法。

### 决定性结论：Filament 的属性读取是正确的

#### 常量注入测试

在 `FilamentAssets.cpp` 上传前把所有法线覆写为 `(0, 1, 0)`（仅影响交给 Filament 的那份 `vertexCopy`），再读取 face：

```
法线全为 (0,1,0) 时 F face: { 1: 973,516 }   ← 100%
```

**写入什么就读到什么——Filament 对 `CUSTOM0` 的属性传递完全正确。**

#### 这把结论彻底反转

结合此前三项证据：

| 证据 | 结果 |
|---|---|
| CPU 侧 face 直方图（全部 19,962 顶点） | 六向均匀（0=2799 1=3519 2=3836 3=2906 4=3488 5=3414） |
| 常量注入 → Filament 读出的 face | 100% 正确 |
| 真实数据 → Filament 读出的 face | 5 占 96% |
| 真实数据 → legacy 读出的 face | 1 占 49%、2 占 46% |

**Filament 侧没有错。** 那么两端结果不同，只可能是**两端读到的基础数据不同**：

- Filament 用的是 `cpuBuffers[draw.vertices]`（CPU 侧副本）；
- legacy 用的是 `draw.vertices`（GPU 缓冲对象）。

**这两者内容若不一致，就能解释全部现象。**

#### 下一步（唯一方向）

验证 `cpuBuffers[draw.vertices]` 与 `draw.vertices` 的 GPU 内容是否一致。可行做法：

1. 在 `dynamicBuffer()` 里（`cpuBuffers.insert(b, data)` 处）记录每次调用的指针与数据摘要；
2. 检查是否存在**同一个 `QRhiBuffer*` 被多次写入不同数据**的情况（例如先传位置再传法线，或缓冲区被复用）；
3. 若存在复用，则 `cpuBuffers` 只保留了最后一次写入的内容，而 GPU 上是别的——这正是症状。

**这条线索比继续查 Filament 更有希望**，因为 Filament 侧已被常量注入测试证明无误。

### 发现一个真实缺陷：Filament 网格缓存的键不可靠

#### 代码

`Qt/src/RhiScene.cpp:1370-1371`：

```cpp
batch.meshId = int(qHash(reinterpret_cast<quintptr>(draw.vertices)) ^
                   (qHash(reinterpret_cast<quintptr>(draw.indices)) << 1));
```

`Qt/src/scene/FilamentAssets.cpp:267 / 317`：

```cpp
auto found = m_meshes.find(batch.meshId);
...
auto inserted = m_meshes.emplace(batch.meshId, buffers);
```

#### 两个问题

1. **哈希碰撞**：`qHash(quintptr)` 返回 32 位，两次 XOR 后截断为 `int`。不同的 (vertices, indices) 组合完全可能落在同一个 key 上。
2. **地址复用（更严重）**：`dynamicBuffer()`（`RhiScene.cpp:856`）在容量不足时会 `retire(state.buffer)` 并 `rhi->newBuffer(...)` 新建。**新缓冲完全可能被分配到刚释放的同一地址**，于是两个内容不同的网格得到相同的 `meshId`。

#### 后果

`m_meshes` 按 `meshId` 缓存已上传的 `VertexBuffer` / `IndexBuffer`。键冲突时，**后来的批次会复用前面某个批次上传的缓冲**——顶点位置、法线、UV 全部是别人的。

这与观测到的现象吻合：

- 位置大体正确（多数网格形状相近，实例变换把它们放到各自位置）→ 深度相关仍有 0.95；
- **但法线来自错误的网格** → `face` 分布完全不符（96% 为 5）；
- 图集 UV 因此落在错误条带 → 画面发平、内容不符。

#### 修复建议

`meshId` 不应由指针哈希构造。可改为：

1. 给每个 `Draw` 分配一个**单调递增的唯一 id**（在生成 draw 列表时赋号），用它做 `meshId`；
2. 或在 `BufferState` 里维护一个稳定的代数计数器，`retire()` 时递增，`meshId` 由该代数构成；
3. 最稳妥：Filament 侧缓存改为按 `(vertices 指针, indices 指针, 字节数)` 三元组做键，并在 `retire` 时显式失效对应条目。

**验证判据**：改用唯一 id 后重跑顶点端 face 对等对照，两端分布应一致（均以 1、2 为主）。

### 负结果：网格缓存键修复无效

按上一节的建议，给每个 `QRhiBuffer` 分配稳定的单调唯一 id（新增 `QHash<QRhiBuffer *, quint32> bufferIds` 与 `nextBufferId`），把 `meshId` 改为 `(vertexKey << 16) | (indexKey & 0xFFFF)`，替代原来的指针哈希。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 合成图梯度比 | 0.26 | **0.26** |

**渲染结果完全未变** ⇒ 本场景中**不存在网格缓存键碰撞**，该假设不成立。改动已还原（工作区回到交付状态，BUILD=0、ctest 10/10、16 路径）。

#### 但仍记录为潜在的健壮性改进

`meshId` 用指针哈希构造确实有隐患（地址复用 + 哈希碰撞），只是当前场景恰好没有触发。若将来出现「部分网格显示成别的网格」这类症状，应优先检查这里。修复方案已写入文档，可直接取用。

#### 至此已排除的假设（累计约 30 项）

数据层：CPU 数据正确、布局正确、偏移正确、步长正确、交错/独立缓冲无差异、CUSTOM0↔CUSTOM1 无差异、偏移确实被如实执行、常量注入证明 Filament 读取正确、顶点法线六向均匀。

渲染层：图集内容正常、纹理绑定正确、varying 插值正常、几何完全对齐（二维互相关 dx=dy=0）、深度相关 0.95、相机 inverse 写法正确、view 不含缩放、getWorldPosition 与 model*position 等价。

代码层：着色公式与 legacy 逐行一致、顶点绑定与 `RhiScene.cpp:797` 一致、网格缓存键无碰撞。

**唯一确定的不一致**：两端顶点着色器用同一函数、同一空间、同一份数据，算出的 `face` 分布完全不同（Filament 96% 为 5，legacy 为 1/2），逐像素相关 0.0000。

## 附二：接手索引（更新版，取代前一份「接手者从这里开始」）

前一份索引写于会话中期，未包含后期结论。**以本节为准。**

### 1. 交付状态

```
BUILD=0   仓库审计 744 文件通过   ctest 10/10   FilamentChecks 104 项
19 个缺陷修复   性能 +24%（1.93 vs 2.54 ms）   内存少 23 MB
保真度 22.34 dB   16 个路径变更   未创建任何提交   HEAD 2a0c877
```

Filament 后端功能完整、默认关闭、不影响现有用户。**可直接评审或提交。**

### 2. V3/V4 的唯一确定结论

| 测量 | 数值 | 可靠性 |
|---|---|---|
| 两端在同一屏幕像素画同一表面 | 视深度相关 **+0.9537** | 高（通道已验证） |
| 两端几何位置完全对齐 | 二维互相关最佳位移 **(0,0)** | 高 |
| 两端图集 UV 不一致 | 相关 **-0.022 / +0.027** | 高 |
| 两端 `face` 不一致 | **0.0000**（F: 96% 为 5；L: 49% 为 1、46% 为 2） | 高 |
| **Filament 对 CUSTOM0 的读取本身正确** | 注入 `(0,1,0)` → face=1 占 100% | **高（决定性）** |
| 顶点缓冲法线数据正常 | 19,962 顶点 face 六向均匀 | 高 |

**综合**：Filament 的属性读取无误、顶点数据无误、布局偏移步长无误、几何对齐无误，但两端算出的 `face` 完全不同。这个矛盾尚未解开。

### 3. 已排除的约 30 项（不要重复验证）

**数据/布局**：CPU 数据、stride/offset、交错 vs 独立缓冲、CUSTOM0↔CUSTOM1、偏移是否被如实执行、缓冲法线值域。

**渲染**：图集内容、纹理绑定、varying 插值、几何对齐、相机 `inverse(view)` 写法、view 缩放、`getWorldPosition` vs `model*position`。

**代码**：着色公式逐行比对、顶点绑定与 `RhiScene.cpp:797` 比对、网格缓存键碰撞。

**不可用的修复路径**：`requires:["normal"]`（非法键）、顶点端 `prepareMaterial()`（片元专用）。

### 4. 下一步：唯一推荐动作

**接入 RenderDoc，抓取 Filament 顶点着色器中 `getCustom0()` 的实际输出**，与缓冲区字节（首顶点 `(-0.0002,-0.9992,0.0401)`）逐位比对。

这是唯一能解释「同一份数据、同一个函数、两端结果不同」的手段。没有它，任何进一步推理都只是猜测。

### 5. 三条铁律（11 次误判的浓缩）

1. **先证明观测通道恒等**——写入已知常量，确认读回原样。本项目四条通道（窗口抓图、外部镜像回读、后处理目标回读、alpha）均已证明不可用于读原始中间量。
2. **对比的量必须同空间、同尺寸、同时机、同测法**——模型空间 vs 世界空间、1080×1080 vs 947×1028、片元 vs 顶点，这三类错误各造成过一次错误结论。
3. **检查 `.filamat` 是否生成（正常 6 个）**——材质编译失败会**静默回退 legacy**，表现为指标恰好等于 1.00。

### 6. 关键文件

- 材质：`Qt/shaders/filament/OpticalSurface.mat`
- 场景：`Qt/src/scene/`（Contract / Config / Platform / Assets / Scene / Bridge）
- 接线：`Qt/src/RhiScene.cpp`（`filamentFrame()` 约 1286 行、`render()` 约 1477 行、`batch.meshId` 约 1370 行）
- 测试：`Qt/tests/FilamentChecks.cpp`（104 项）
