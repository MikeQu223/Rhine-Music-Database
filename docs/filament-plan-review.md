# 《Filament 链路接入规划书》审查报告

> 审查日期 2026-10-27 ／ 被审对象 [filament-implementation-plan.md](filament-implementation-plan.md) v1.0
> 审查方式：对每条承重论断回源码取证，标注 `文件:行`。凡未取证的，标为"未验证"而非默认为真。
> 结论：**有条件放行**——架构接缝（B1）必须先改写再开工，其余在阶段内消化。

---

## 零、审查结论

| 维度 | 评价 |
| --- | --- |
| 目标与约束 | 清晰、可执行。"完全共存 / 默认关闭 / 失败回退"三条都能落到具体机制上 |
| 核心成本论断（`MotionPass` 可复用） | **成立**（已取证，见 §4.1） |
| 架构接缝设计 | **错误且过度设计**（B1）。规划书要改的两个高风险点，实际上是多余的 |
| 材质方案 | **数量假设错 3 倍**（B3）；且完全漏掉 Filament 默认后处理污染（M1） |
| 图像交接 | 方向对（H1），但**目标格式写错**（B2） |
| 成本与排期 | 偏低约 30–40%（M8） |
| 验收标准 | 偏含糊，缺性能闸门（M9/M10） |

**必须开工前改的：B1。** 其余 3 条阻断项（B2/B3/B4）在 P0–P2 内必须落到文档，否则会在 P2 中期返工。

---

## 一、阻断性问题（开工前必须改）

### B1. 接缝选错：整个 `ISceneRasterizer` 抽象是多余的

**规划书主张**（§3.1/§3.2/§3.3）：引入 `ISceneRasterizer` 接口 + `QrhiRasterizer` 包装现有 `Renderer` + 给 `ScenePostProcess` 加 `setExternalSource()`，在 `ItemRenderer::render()` 处分叉。

**源码事实**：

`Renderer::render()`（`Qt/src/RhiScene.cpp:1195-1280`）的收尾三步是：

```cpp
cb->beginPass(color.rt, background, {1, 0});
geometry(cb, opaque);
geometry(cb, transparent);
cb->endPass();
velocityPass(cb, data, frame);                      // MotionPass，独立
composite(cb, finalTarget ? finalTarget : target.rt);
```

而 `composite()`（`:1073-1133`）内部已经完成了规划书想新增的那条链：

```cpp
auto finalDestination = destination;
if (postProcess->active()) {
    destination = postProcess->inputTarget();       // ① 把场景色转进后处理输入
}
...
binding = bindings({ ... sampledTexture(2, FragmentStage, color.texture, linear) });  // ② 采样场景色
cb->beginPass(destination, ...); cb->setGraphicsPipeline(pipeline("finalFragment", ...)); 
cb->draw(3); cb->endPass();
if (postProcess->active()) {
    postProcess->resolve(cb, finalDestination, motionInputs);   // ③ AA/FSR
}
```

**即：`composite()` 本身就是一个采样 `color.texture` 的全屏 blit + 后处理入口。** 只要让 `color.texture` 变成 Filament 的产出，整条下游链路**一行都不用改**。

**因此正确的接缝是**：

```cpp
// Renderer::render() 内，替换原来的 beginPass/geometry/endPass 三行
if (m_filament && m_filament->active()) {
    if (!m_filament->renderFrame(frame, item, cover, size))
        m_filament->degrade();                    // 失败即降级，同帧继续走下面
}
if (!m_filament || !m_filament->active()) {
    cb->beginPass(color.rt, background, {1, 0});
    geometry(cb, opaque);
    geometry(cb, transparent);
    cb->endPass();
} else {
    color.texture = m_filament->wrappedTexture(); // 已由外层按 size 建好的 QRhiTexture
}
velocityPass(cb, data, frame);                    // 不变
composite(cb, finalTarget ? finalTarget : target.rt);   // 不变
```

**连带删除的规划书内容**：

| 规划书条目 | 处置 |
| --- | --- |
| §3.1 `ISceneRasterizer.h` + `QrhiRasterizer.{h,cpp}`（~180 行） | **删除**。旧链路根本不需要被包装 |
| §3.2 "rasterizer 二选一 + 同帧重试" | **保留思路**（降级重试），但落在 `FilamentBridge` 内部 |
| §3.3 `ScenePostProcess::setExternalSource()`（~50 行改动） | **删除**。`composite()` 已经做了这件事 |
| §6.1 里两个文件、§6.2 里 `ScenePostProcess` 那行 | 全部删除 |

**收益**：新增代码从 ~2,100 行降到约 1,500 行；同时消除两个高风险面——(a) 不再需要动 `ScenePostProcess` 的取样绑定（零差异验收的最难点），(b) 不再需要同时存在两个各自持有 QRhi 资源的 `Renderer`（生命周期与显存翻倍问题）。

**代价**：`Renderer` 会同时承担两条链路的状态，需要在类注释里写明"Filament 激活时 `color.texture` 由外部注入，`color.rt`/`color.rp` 不再使用"。这是可接受的内聚性损失。

---

### B2. 场景色目标格式写错

**规划书主张**（§9.2）：宿主图像"颜色格式 SDR `VK_FORMAT_R8G8B8A8_UNORM` / HDR `R16G16B16A16_SFLOAT`，与 `ScenePostProcess.cpp:111` 的 RGBA8/RGBA16F 选择对齐"。

**源码事实**（`Qt/src/RhiScene.cpp:426-430`）：

```cpp
auto rtFlags = QRhiTexture::RenderTarget;
depth = create(own(rhi->newTexture(QRhiTexture::D32F, size, sampleCount, rtFlags), true));
auto attachment = create(own(rhi->newTexture(QRhiTexture::RGBA16F, size, sampleCount, rtFlags), true));
auto resolved = sampleCount > 1 ? texture(size, QRhiTexture::RGBA16F, rtFlags, true) : nullptr;
color = makeTarget(attachment, depth, resolved);
```

场景色**恒为 `RGBA16F`**，与 AA 模式无关。`ScenePostProcess` 里的 RGBA8/RGBA16F 选择针对的是**后处理内部的输入目标**（`ScenePostProcess.cpp:111`），不是场景色。

**修正**：宿主图像**恒为 `VK_FORMAT_R16G16B16A16_SFLOAT`**，单采样（MSAA 由 Filament 内部处理，见 M4）。

**影响**：按原方案实现会在 SDR 模式下写出 RGBA8 图像，而 `finalFragment` 管线按 RGBA16F 采样 → 至少是色深损失，最坏是管线/格式不匹配直接验证层报错。

---

### B3. 材质数量假设错约 3 倍

**规划书主张**（§8.1）：5 个 `.mat`（surface / card / ground / disc / final）。

**源码事实**（`Qt/src/RhiScene.cpp:1054-1061`）：

```cpp
const bool hashed = surface(data).flags.x() == 2;
const bool blend  = hashed || data["transparent"].toBool();
const bool depthWrite = hashed || !blend || data["depthWrite"].toBool();
cb->setGraphicsPipeline(pipeline("surface", draw.bindings, color.rp, false,
                                 data["side"].toInt() == 2, depthWrite, blend));
```

即每条 draw 的运行状态由 **(blend, depthWrite, doubleSided)** 三元组决定，而这三者在 Filament 里**全是材质级属性**（`blending` / `depthWrite` / `doubleSided`），**不是 MaterialInstance 可改的实例参数**。

实际出现的组合（取证自 `SceneAppearance.cpp:126-240`、`NativeCards.cpp:100-106`）：

| 来源 | transparent | depthWrite | side(=2 即 doubleSided) |
| --- | --- | --- | --- |
| `SceneAppearance.cpp:126-131` | `alphaMode=="BLEND"` | `true` | 闭壳且无透射 → 1，否则 2 |
| `SceneAppearance.cpp:150-153` | `false` | `true` | `definition["side"]` |
| `SceneAppearance.cpp:188-191` | `true` | `false` | `2` |
| `SceneAppearance.cpp:208-211` | `true` | `false` | `0` |
| `SceneAppearance.cpp:232-235` | `false` | `true` | `0` |
| `NativeCards.cpp:100-106` | 透传 | 透传 | 透传 |

叠加 `hashed`（`surface(...).flags.x()==2` 强制 blend+depthWrite）后，实际组合为 **(blend,depthWrite) ∈ {(F,T), (T,F), (T,T)} × doubleSided ∈ {F,T} = 6 种**，再乘着色家族（surface / card / ground / disc）→ **约 12–18 个材质变体**，而不是 5 个。

**修正**：§8 必须补一张"绘制状态 → 材质变体"矩阵表，并说明变体如何由构建期生成（一个 `.mat` 源 + `matc` 不同 `-D` 定义，或 6 个手写变体）。**这会显著推高 P2 的工作量**（见 M8）。

> 附带一个可优化点：`hashed` 在本项目里只影响 blend/depthWrite，不改变着色逻辑，因此变体可由同一 `.mat` 用 `matc` 的变体机制或参数化生成，不必手写 6 份。

---

### B4. `optical_final.mat` 是多余材质

**规划书主张**（§8.1 第 5 行）：需要 `optical_final.mat` "最终合成到宿主图像"。

**源码事实**：`composite()` 里的 `finalFragment` 管线（`RhiScene.cpp:1102-1119`）就是最终合成通道；且在 H1 方案下 Filament 直接渲进宿主图像，本就不存在"二次合成"。

**修正**：删除该材质。材质清单从 5 个（含 final）改为 4 个着色家族 × 状态变体。

---

## 二、重大问题（影响正确性）

### M1. Filament 的默认后处理会污染画面 —— 规划书完全没提

Filament 的默认行为（评估书 §五已取证）包括：**FXAA 默认开启**、`View` 默认带 tonemapping / color grading / bloom 链路。

若不显式关闭，后果是：
1. 画面先过它的 FXAA，再进我们的 FXAA/FSR → **双重抗锯齿**，锐度与细线表现直接变差；
2. 它的 ACES 色调映射会改变线性值 → 我们烘焙图集的观感**整体偏移**，而规划书 §8.3 的核心风险正是"观感复刻"。

**必须补进 §8**：Filament 侧显式关闭
```cpp
view->setPostProcessingEnabled(false);
view->setAntiAliasing(false);
view->setColorGrading(nullptr);          // 或中性 ColorGrading
view->setAmbientOcclusionOptions({});     // 关闭
view->setBloomOptions({});                // 关闭
view->setDithering(false);                // 见 M1b
```
且**不添加任何 `LightManager` 光源与 `IndirectLight`**（着色完全由 `customSurfaceShading` 接管）。

### M1b. `View::setDithering` 必须关闭
Filament 的动态分辨率文档明确"**Avoid FXAA and dithering**"，而抖动会在我们自己的 FSR 之前引入噪声。规划书未提。

### M2. 输出色彩空间未定义

宿主图像格式（见 B2）之外，还必须约定：Filament 侧**不得**使用 `SwapChain::CONFIG_SRGB_COLORSPACE`，输出视为线性 HDR；色彩空间转换只发生在 `finalFragment` 与后处理里（现状行为）。

**验收补充**：增加一个"色板回归"用例——16 个已知色值的色块，两条链路逐像素比对，容差 ≤ 1/255。这比"golden frame 结构一致"可执行得多（见 M9）。

### M3. 透明排序语义会变，规划书没有映射规则

**源码事实**（`RhiScene.cpp:1247-1262`）：绘制被分成 opaque / transparent 两组，各自按 `data["order"]` 做 `stable_sort`，transparent 组后画。

Filament 用它自己的排序（`RenderableManager::Builder::priority` + 混合模式规则）。规划书 §7.2 的 `DrawKey` 里虽然有 `layer`，但**没有说明如何映射，也没有验收**。

**修正**：补一条——`order` → `priority`（数值直接透传），并增加用例：卡片叠放与半透明壳体在两条链路下的遮挡顺序一致（截图比对 + 像素采样点断言）。

### M4. MSAA 与 `resize()` 的多重采样目标冲突

`resize()` 按 `postProcess->samples()` 申请 `sampleCount` 并建 `resolved` 纹理（`:412-430`）。若 MSAA 交给 Filament，我们侧必须 `sampleCount == 1`，否则 Filament 的单采样输出与我们的多重采样目标不匹配。

**修正**：Filament 链路下强制 `postProcess->samples()` 返回 1，MSAA 请求转成 Filament 的 `MultiSampleAntiAliasingOptions`。规划书 §10.3 第 7 行的方向对，但没写这条强制。

### M5. 退出与 rhi 切换时的销毁顺序未定义（会崩）

Filament 的 `Engine` 必须在 `VkDevice` 销毁前销毁。`ItemRenderer::initialize()`（`RhiScene.cpp:1312-1316`）已经在 rhi 变更时 `renderer.reset()`，这条路径会触发 Filament 对象在**仍活着的旧 rhi** 上销毁，或在**新 rhi** 上错误复用。

**修正**：`FilamentBridge` 必须在以下两处执行 `flushAndWait()` → `engine->destroy(...)`：
1. `~ItemRenderer()`；
2. `initialize()` 检测到 `rhi` 变更时（与现有 `renderer.reset()` 同处）。

并新增用例 **F9**：强制触发 rhi 重建 + 退出，断言无崩溃、无验证层报错、无泄漏。规划书 §14.2 缺这一条。

### M6. `.filamat` 的运行时分发未定义

资源加载靠目录扫描（`Engine.cpp:848`、`Host.cpp:914` 都按 `*.json` 枚举），工程里没有找到资源清单机制。新增二进制资源 `.filamat` 是否进入安装包与自动更新（`backend.host.updater.check()`，`main.cpp:428`）的分发范围**未确认**。

**后果**：若 updater 只同步白名单内文件，老用户升级后永远拿不到材质包 → 开关打开即 `E_MATERIAL_MISSING` 永久失败。

**修正**：P1 前必须确认并在文档中写明 `.filamat` 的落盘位置与分发路径。这是"看起来是技术问题、实际是发布问题"的典型。

---

## 三、中等

### M7. Filament 链路下 `prepare()`/`batchDraws()` 是冗余开销
`render()` 在 `:1213` 调 `prepare()`（为每个材质建 uniform buffer、为每批建 instance buffer），`:1249` 调 `batchDraws(opaque)`（只服务 `geometry()`）。Filament 链路下这两块产出**只有 `velocityPass` 用到**，而 `velocityPass` 只用 `data` 的 CPU 字段（`:1157-1165` 读取 `id/vertices/indices/matrixBytes/start/count/instances/side`），并不需要那些 GPU buffer。
→ 应跳过 `batchDraws`，并评估 `prepare()` 的 GPU 上传部分能否短路。可省 CPU 与显存，规划书未提。

### M8. 成本估算偏低 30–40%
B3 的变体矩阵一补，`FilamentAssets`/材质两块至少 +200 行；P2 的 15–22 人日没有为"变体矩阵 + 排序验证 + 后处理关闭调参"留时间。
→ 建议：总估上调到 **约 60–90 人日**；P2 拆为 **P2a 单变体打通（+4 天）** 与 **P2b 变体矩阵与排序（+5 天）**，让 Gate 更早判生死。

### M9. 验收标准不可执行
§16 P2 写"首帧与 golden frame 结构一致"——"结构一致"无法判定。
→ 改为量化：以 `renderReference()`（`RhiScene.cpp:1396+`）产出的参考图为基线，**SSIM ≥ 0.98 且逐像素 PSNR ≥ 40 dB**；并说明浮点光栅化差异下阈值如何校准（先在 P0 用纯色 + 单个立方体标定）。

### M10. 缺少性能闸门
§11 承认 v1 有 `flushAndWait()` 停顿，但没有可接受上限与测量方法。
→ 补：P3 结束时中位帧时间劣化 ≤ 25%、p95 ≤ 40%（用 `--frame-profile` CSV 采 3000 帧对比）；超标则必须进 Phase 5 双缓冲，否则不发布。

---

## 四、轻微

| # | 问题 | 处置 |
| --- | --- | --- |
| m1 | §7.2 把 `instances(count)` 上限 64 写成既定事实，无来源 | 标为"待 P2 实测"，或补出处 |
| m2 | §4.2"编译期未编入整组隐藏"与 §5.2 P2"不显示开关"重复 | 合并为一处 |
| m3 | `E_QUEUE_INSUFFICIENT` 语义是"降级不失败"，却放在失败码表里 | 改名 `W_QUEUE_SERIALIZED`，单列为告警 |
| m4 | §7.3 只处理了投影矩阵，未提相机曝光 | Filament `Camera` 有物理曝光模型（默认 f/16 1/125s ISO100）；虽无光源时影响小，仍需显式置中性并验证 |
| m5 | §12 遥测字段名 `filamentSyncMs` 与现有 `RenderTelemetry` 的 camelCase 一致，OK；但未说明滑动平均窗口 | 补"最近 60 帧" |

---

## 五、修正后的架构（供直接替换规划书 §三）

```
Renderer（保持不变）
├── musicDraws / prepare / batchDraws      ← Filament 链路下 batchDraws 跳过
├── [分支] 场景色来源
│     ├── legacy:    beginPass(color.rt) → geometry(opaque) → geometry(transparent) → endPass
│     └── filament:  m_filament->renderFrame(...) → color.texture = m_filament->wrappedTexture()
├── velocityPass                            ← 两条链路完全相同（复用 MotionPass）
└── composite                               ← 两条链路完全相同（采样 color.texture → 后处理 → resolve）

FilamentBridge（新增，Renderer 的成员）
├── probe()      六道探测（P1–P6）
├── start()      共享上下文 → Engine → Scene/View/Camera/Renderer → 材质 → 图像池
├── renderFrame() 实体池同步 → beginFrame/render/endFrame → flushAndWait
├── wrappedTexture()  宿主 VkImage → QRhiTexture（createFrom）
├── degrade()    标记失败 + 写偏好 + 单次日志
└── shutdown()   flushAndWait → engine->destroy(...)
```

**关键不变式**：`velocityPass` 与 `composite` 之后的所有代码，两条链路**共享同一份实现**——这是"完全共存"的最强保证，也是本方案可维护性的来源。

---

## 六、复审清单（改完规划书后逐条勾）

- [ ] B1：删除 `ISceneRasterizer`/`QrhiRasterizer`/`setExternalSource`，改为 `FilamentBridge` 成员 + `color.texture` 注入
- [ ] B2：宿主图像格式改为恒 `R16G16B16A16_SFLOAT`，单采样
- [ ] B3：补"绘制状态 → 材质变体"矩阵表（6 组合 × 4 家族）
- [ ] B4：删除 `optical_final.mat`
- [ ] M1/M1b：补 Filament 侧关闭后处理/FXAA/色调映射/抖动、不加光源的具体调用
- [ ] M2：补色彩空间契约 + 色板回归用例
- [ ] M3：补 `order` → `priority` 映射与遮挡顺序验收
- [ ] M4：补 `samples()` 强制为 1 的规则
- [ ] M5：补 `shutdown()` 的两处调用点 + F9 用例
- [ ] M6：确认 `.filamat` 分发路径
- [ ] M7：补跳过 `batchDraws` 的说明
- [ ] M8：成本上调至 60–90 人日；P2 拆 P2a/P2b
- [ ] M9/M10：补量化验收（SSIM/PSNR）与性能闸门（中位 25% / p95 40%）

---

## 七、审查者的一句话

**方案的方向是对的**——"Filament 只当光栅化器、后处理全部留在自己手里"这个判断经受住了取证：`composite()` 已经内置了那条链，`MotionPass` 确实独立，两条链路可以共享 `velocityPass` 之后的全部代码。

**但规划书把简单的事写复杂了**：`ISceneRasterizer` 抽象与服务端改造都是多余的，正确的改动是 `Renderer::render()` 里一个 if 分支加一次 `color.texture` 赋值。**真正被低估的不是架构，是材质状态矩阵**——那 6 种运行状态组合在 Filament 里必须编译成 6 份材质，这是 P2 的真实成本所在，而规划书只列了 5 个材质、没提这件事。


---

## 八、补充审查：一次被驳回的"重大利好"

### 8.1 被驳回的主张

有一路补充调研主张：Filament 的 `CompositorEffect` 是公开 API，其 `RenderData` 提供 `get_velocity_texture()` 与 `get_render_scene_buffers().get_texture("render_buffers","depth")`，并带 `needs_motion_vectors` / `access_resolved_depth` 标志，因此在回调里做一次 GPU 拷贝即可拿到深度与运动矢量，把 §10.1 的成本从 8–15 人日降到 2–4。

**该主张不成立，且是跨引擎串台。**

### 8.2 驳回依据

1. **`CompositorEffect` 是 Godot 4 的类，Filament 没有这个类。** 本次会话早前的 Godot 调研原文即为："CompositorEffect is marked *Experimental*… `_render_callback(effect_callback_type: int, render_data: RenderData)`… flags `access_resolved_color`, `access_resolved_depth`, `needs_motion_vectors`, `needs_normal_roughness`, `needs_separate_specular`… buffers via `render_data.get_render_scene_buffers().get_texture("render_buffers","color"|"depth")`; `get_velocity_texture()` for MOTION VECTORS." 主张里的 API 名字、标志名、调用形式与该段**逐字一致**。
2. **"RID" 是 Godot 的概念**（RenderingServer 的资源句柄）。Filament 没有 RID。主张自己写的待验前提"回调内取得的 RID 能否在回调外使用"已经暴露了串台。
3. **`RenderSceneBuffersRD` 同样是 Godot 4 的类**，Filament 的对应物是`RenderTarget`/`Texture`，没有 `render_buffers` 这一层抽象。
4. Filament 侧的独立取证（40 个公开头文件全扫）结论是：**深度与运动矢量存在于引擎内部，但无任何公开访问器**。Filament 的 `FrameGraph` 是内部框架且不是扩展点（公开头文件中不含 `FrameGraph.h`）。

**结论**：§10.1 与 §十三 B3 的结论保持不变——**深度/速度不是"一次拷贝"，仍是"自己渲一遍"**。若相信了这条，P3 会建立在一个不存在的 API 上。

### 8.3 但该报告里有三条值得采纳的判断

驳回错误主张不等于整份作废。以下三点经审后成立，已并入本报告：

**（一）H1 的价值是"布局确定性"，不只是"少写一套交换链"。**
若改用"Filament 自己的图 + 补丁 getter"，布局交接问题不会消失，只是从"实现 acquire/present"变成"猜它渲染完把图留在什么 layout"——后者表现为偶发花屏、跨栈时验证层报错含混，**更难查**。这为 §九 选 H1 提供了第二条独立理由（第一条是零拷贝），值得写进决策依据。**维持 H1 为首选。**

**（二）补丁的两条红线**（若 P0 判定必须打补丁）：
1. 单个补丁 ≤ **200 行**，且**不得触碰布局跟踪与资源所有权**——超过就说明在改它的架构而不是拆一个阻塞点；
2. **优先上游 PR**。Filament 仓库有 `AGENTS.md`/`skills/` 且接受外部贡献；合并则维护成本归零。自持则按 40 release/年 估约 1–2 人日/年的 rebase，但补丁一旦涨到数百行，这个数字非线性上升。

**（三）补丁买不到任何一项退化。**
A6（8× MSAA）、A8（两套 AA 划界）、A9（Metal 后端质量）、FSR3.1、插帧、光照烘焙——**没有一项因改底层而改善**。其中 A9 反而恶化：fork 之后无法随手跟进上游对 Metal 的修复，而 Metal 恰是上游修得最勤的后端（310 条相关 issue）。这条应写进 §十七 风险登记册。

### 8.4 对 §九 决策门的修订

原文：H2（极小补丁）作为 H1 超期后的兜底。

修订为：**H2 作为 P0 的正式并行分支，但带进入条件与量化红线**——

| 项 | 规定 |
| --- | --- |
| 进入条件 | 仅当 H1（`VulkanPlatform` 子类）在 P0 内被证明超 3 人日 |
| 补丁规模上限 | ≤ 200 行，且不触碰布局跟踪/资源所有权 |
| 必须尝试上游 | 提交 PR；合并则视为最优结局，维护成本归零 |
| 阶段门量化指标 | 记录**补丁行数**与**rebase 所需人日**，作为 P1/P2 的放行依据，防止补丁无声膨胀 |
| 许可义务 | Apache-2.0：保留 NOTICE/LICENSE 归属，在改动文件内声明已修改；不要求开源应用 |

**不变的结论**：H3（CPU 回读）永不采用；补丁不改变任何 A 类退化的存在与否。

### 8.5 对成本的影响

补充报告给出的对比（零补丁 52–79／补丁-lite 34–56）方向可信，但**未计入本报告 B3 的材质状态矩阵**（6 组合 × 4 家族）。叠加后：

| 方案 | 修正后区间 |
| --- | --- |
| 零补丁（H1） | **60–90 人日** |
| 补丁-lite（H2，≤200 行） | **约 45–70 人日**，另加每年 1–2 人日 rebase |

即：补丁能省约 15–20 人日，但省下的部分集中在"交换链"；**材质矩阵与排序验证这两块省不掉**，它们才是 P2 的真实成本。


---

## 九、若允许改 Filament 底层：收益核算

> 直接回答"改了会不会更好"：**会省事一点，但不是"更好"，而且最诱人的那一项收益为零。**

### 9.1 逐项核算

| # | 可打的补丁 | 真实规模 | 买到什么 | 判定 |
| --- | --- | --- | --- | --- |
| P-1 | 导出 `Texture` 的 `VkImage` | **50–150 行**（含一个 transition 助手，不是 20 行 getter） | 省掉 `VulkanPlatform` 子类（估 10–18 人日） | **仅作兜底**，见 §9.2 |
| P-2 | **导出深度 + 运动矢量** | 100–300 行，且必须改 `FrameGraph` / TAA pass（速度缓冲只在 TAA 启用时才生成） | **零**——见 §9.3 | **拒绝** |
| P-3 | 暴露 `FrameGraph` 让宿主插 pass | 100+ 人日 | 把 7,363 行后处理搬进 Filament 重写 | **否决** |
| P-4 | 8× MSAA | 可打 | A6 恢复 | 无意义（4× 在桌面已足够，且它受硬件限制） |

**净收益上限：约 10–18 人日，且全部集中在 P-1 一条。**

### 9.2 为什么 P-1 只能兜底，不能预设

补丁要"安全"地交出一张 `VkImage`，必须同时交出它的 layout 与最后一次写入的 stage——否则我们只能猜。而"猜 layout"正是补充报告自己指出的风险："偶发花屏、跨栈时验证层报错含混，更难查"。

于是出现一个**内部矛盾**：

> 红线一要求"不得触碰布局跟踪与资源所有权"，红线二却要求"安全导出图像"。**安全导出必然要碰 layout/barrier 状态**——两者不可兼得。

一旦补丁为了安全而碰了 layout，它就不再是 200 行以内的小补丁，维护成本随之非线性上升。**因此 P-1 的价值不在于"更省事"，而在于"用确定性换工作量"，而 H1 的确定性更高。**

### 9.3 P-2 收益为零的证据

补充报告主张"用 `CompositorEffect` 一次拷贝拿到深度与速度，把成本从 8–15 人日降到 2–4"。这条不成立，理由有三层：

1. **那是 Godot 的 API，不是 Filament 的。** `CompositorEffect`、`RenderData`、`RenderSceneBuffersRD`、`RID`、"get_render_scene_buffers().get_texture(...)"、"needs_motion_vectors / access_resolved_depth"——这一整套名字与本次会话早前的 Godot 调研逐字一致。Filament 的 40 个公开头文件里没有这些类；它的 `FrameGraph` 是内部框架且不是扩展点。
2. **即便有，我们也不需要。** `MotionPass` 已经独立产出深度与速度，并且**正在生产中使用**：`Qt/src/RhiScene.cpp:1091` 的 MetalFX 时域解析就是拿 `motion->depth()` 与 `motion->vectors()` 当输入。它不依赖场景光栅化实现（`:1142-1168` 用同一份 `data` 列表渲染自己的深度/速度）。
3. **成本数字对不上。** 规划书 §10.1 已经写明"不重写，只接线"，真实成本是 2–4 人日的接线工作。所谓"从 8–15 降到 2–4"，是拿评估书里被推翻的旧估数在比。

**结论：P-2 会用一个 fork 依赖，换掉一个已经跑通、正在被 MetalFX 使用的子系统。这不是"更好"，是纯亏。**

### 9.4 补丁买不到的东西（不必再讨论）

A6（8× MSAA）、A8（两套 AA 划界）、A9（Metal 后端质量）、FSR3.1、插帧、光照烘焙——**没有一项因改底层而改善**。

其中 **A9 反而恶化**：fork 之后无法随手跟进上游对 Metal 的修复，而 Metal 恰是上游修得最勤的后端（310 条相关 issue）。macOS 本来就是本方案最弱的一环，锁版本等于主动放弃它的修复。

### 9.5 若仍要打补丁：执行规约

| 项 | 规定 |
| --- | --- |
| 允许范围 | **仅 P-1（图像导出）**；P-2/P-3 一律不做 |
| 规模上限 | ≤ 200 行；超限即放弃补丁、回 H1 |
| 进入条件 | 仅当 H1（`VulkanPlatform` 子类）在 P0 内被证明超 3 人日 |
| 上游优先 | 提交 PR；合并则维护成本归零。Filament 仓库有 `AGENTS.md`/`skills/`，接受外部贡献 |
| 量化门 | 记录**补丁行数**与**rebase 人日**，作为 P1/P2 放行依据，防止无声膨胀 |
| 许可 | Apache-2.0：保留 NOTICE/LICENSE，在改动文件内声明已修改；不要求开源应用 |

### 9.6 一句话

**允许改底层，最省的那一刀是"少写一套交换链"，值 10–18 人日；最诱的那一刀（深度/速度）基于一个不属于 Filament 的 API，且会被我们的 `MotionPass` 重复实现。所以：维持零补丁为主路径，把补丁降级为有时间盒的兜底，并且只准用于图像导出。**
