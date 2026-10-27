# 把 3D 图形部分重构为 Godot：可行性评估

> 评估日期 2026-10-26。Godot 基准版本 **4.7.2 stable**（2026-08-18 发布），4.8 当时处于 beta 1（2026-10-15，功能冻结）。
> 代码事实取自本仓库当前工作树（`main` @ 2a0c877）；人日估算为量级参考，非承诺。

---

## 一、结论先说

**不建议迁移。** 两个范围分别给结论：

| 范围 | 结论 | 一句话理由 |
| --- | --- | --- |
| **A. 只把 3D 场景交给 Godot，Qt 继续管 UI** | **不成立**（Windows / Linux 无路，仅 macOS 可行） | Godot 只能在 Apple 平台把窗口渲染进宿主提供的 surface；Win/Linux 依赖一个从未合入的 Godot 4.2 时代补丁。且即便打通，被替换的 5,028 行里最值钱的是"画模型"，而模型本身很轻。 |
| **B. 整个呈现层改为 Godot，Qt 退成壳或移除** | **否决**（除非接受产品降级） | 会丢掉 FSR3.1 超分与 FSR 插帧这两项当前画质卖点，要重写 18.4k 行呈现层 + 5,001 行 HUD 布局 + 全部视觉回归测试，还得自己补 Linux 托盘、MPRIS、Wayland、高 DPI、AppImage。 |

Godot 能替代的是"**画一个 3D 场景**"；替代不了的是这套自研栈里真正难的那部分——**FSR3.1 超分、FSR 插帧 + 自持交换链、七种互斥 AA、自绘文字**。而恰恰是后面这几项，才是目前维护成本的来源。

---

## 二、先纠正一个范围认知：这里的"3D 图形部分"不是一块 3D 视口

本项目的 3D 与 UI 边界已经存在，且是为插帧专门拆开的（`Qt/qml/Scene3D.qml:4-12` 的注释写明了原因：插值会把文字和按钮算出鬼影）：

- `RhiScene`（`Qt/src/RhiScene.h:12`，继承 `QQuickRhiItem`）——唯一 3D 渲染入口
- `Hud`（`Qt/src/Hud.h:7`，继承 `QQuickPaintedItem`）——叠加层，用 QPainter 画命令列表，**不在 3D 里**

### 实测代码量（`wc -l`，当前工作树）

| 部分 | 行数 | 说明 |
| --- | --- | --- |
| 3D 场景核心 | **5,028** | `RhiScene.cpp` 1,506 + `NativeScene*` 1,455 + `NativeViewer` 404 + `NativeCards` 161 + `NativePicking` 268 + `Scene*`/`DiscGeometry` 1,234 |
| 超分 / 呈现 / 插帧 | **7,363** | `render/` 3,702 + `fg/` 2,876 + `fsr/` 785 |
| 呈现层着色器 | **510** | `Qt/shaders/`（另有 `enhancement/` 子目录） |
| HUD 叠加层（**非 3D**） | **5,001** | `NativeHud*` + `Hud` + `Glyphs` + `UiMotion` + `Icon` |
| 业务逻辑（不受影响） | 8,518 | `Music*` / `AudioPlayer` / `LyricsController` / `LocalMusicLibrary` 等 |
| 平台 / OS 集成 | 1,650 | `Platform*` / `DesktopTray` / `WindowsTaskbar` / `NativeApplication` |
| **Qt/src 合计** | **30,754** | 呈现层约占 60% |

### 3D 内容本身很轻

- 一个光盘壳 + 盘面（`DiscGeometry.h:7-13`：半径 1.57、192 段、中心 1.85）
- 两个 GLB：`Assets/models/archive-cassette.glb`（3.5 MB）、`archive-assembly.glb`（3.3 MB），构建期被 `scripts/export-assets.py` + `scripts/bake-archive-lighting.py` 烘焙成自研 json/bin（384×384 面片图集、8 段高度切片）
- UI 卡片（`NativeCards`：静态部件模板 + 每实例矩阵）
- 一块地面

**工作量不在"画模型"，在周边管线。** 这是评估的关键前提。

---

## 三、Godot 4.7.2 的能力边界（已核实）

### 能力对照

| 能力 | 本项目现状 | Godot 4.7.2 | 判定 |
| --- | --- | --- | --- |
| FSR **3.1** 超分 | Vulkan / DX12 可用 | **无**。`Viewport.Scaling3DMode` 枚举只有 `FSR`(1.0) / `FSR2`(2.2) / `METALFX_*` | **回归** |
| FSR 插帧 + 光流 | Vulkan 自持 `VkSwapchainKHR`，即时开关 | **无**。提案 godot-proposals#14768 已于 2026-05-02 关闭（archived，从未合并） | **回归** |
| 自持交换链呈现 | `Qt/src/fg/VulkanPresenter.cpp`（976 行） | **结构上无路**：引擎自持交换链，`CompositorEffect` 所有阶段都在最终输出之前 | **回归** |
| MetalFX（macOS） | Spatial + Temporal | Spatial + Temporal 可用（仅 Metal 驱动） | 持平 |
| Metal 后端 | 原生 Metal | 4.4 起原生 Metal 取代 MoltenVK | 持平 |
| Vulkan | 主路径 | 生产可用 | 持平 |
| D3D12 | **已停用**（commit 50d1d60） | 生产可用，4.6 起已是 Windows 新项目默认 | Godot 更好 |
| OpenGL + FSR1 | 有（GL 路径 EASU+RCAS） | FSR1 **仅 Forward+**，Compatibility(OpenGL) 渲染器**不可用** | **回归** |
| FXAA / SSAA / MSAA / TAA | 四类、七种模式、全后端 | MSAA 2/4/8× 全后端；FXAA 仅 Forward+/Mobile；TAA **仅 Forward+** | 收窄 |
| 自定义全屏 pass | 完全自主 | `CompositorEffect`（类参考标注 **Experimental**）+ `RenderSceneBuffersRD`/`RD_*` | 受限 |
| 自定义 jitter | 自主（给 FSR3 传投影偏移的反数） | **无公开 API**：TAA 内部抖动顶点、不暴露序列 | **回归** |
| 文字渲染 | 自绘 `Glyphs`（QRawFont → QPainterPath → 图集），376 行 | TextServer 动态字体；MSDF 默认关闭（`multichannel_signed_distance_field = false`） | **未验证** |

### 桌面工具适配（`docs.godotengine.org/en/stable/tutorials/ui/creating_applications.html`）

官方在这一页自己写明："**Godot is a game engine first and foremost** … creating applications with Godot is a byproduct of its feature set, and not its primary focus of development." 逐项缺口：

| 能力 | Godot 4.7 现状 | 对本项目的影响 |
| --- | --- | --- |
| 系统托盘 `StatusIndicator` | **仅 Windows / macOS**（"only supported on Windows and macOS"） | `Qt/src/DesktopTray.cpp` 的 Linux 托盘**没有替代品** |
| 多窗口 | 支持，但 **X11/XWayland only，不支持原生 Wayland**；关闭主窗口即退出进程 | 项目正在做 Wayland 适配（commit `849a098`），方向相反 |
| 高 DPI | 只在 macOS / Android / Wayland 读系统缩放；"**On Linux (X11) and Windows, you will need to provide a manual scaling option**" | 手动缩放 = 让用户自己设，**直接退化**最近做完的高 DPI 适配 |
| 客户端装饰 / 自定义标题栏 | **仅 macOS**（`extend_to_title`、`window_get_safe_title_margins()`） | `WindowChrome.qml` 需完全重写为 borderless |
| 全局菜单 | **仅 macOS**（`NativeMenu`） | — |
| 原生文件对话框 | 支持，但 `use_native_dialog` **逐节点开关，无全局设置** | `LocalMusicDialogs.qml` 需逐个改造 |
| 桌面通知 | "Godot currently does not have native support for sending desktop notifications" | 需 `OS.execute` 调 `notify-send`，Windows 侧无对应 |
| MPRIS / D-Bus | 文档索引里 `dbus`、`mpris` **零条目**；只有 `KEY_MEDIAPLAY` 等常量，且仅**窗口聚焦时**收到 | 项目已有 macOS 媒体键；Linux 系统级 MPRIS 与全局热键都要原生代码 |
| 任务栏进度 / 窗口位置持久化 / 自动更新 | 均无内建（进度仅 Win/mac） | 需自写 |

**净效果**：Linux 托盘 + MPRIS + 自动更新 + 签名公证胶水**反正都要写原生代码**——"用 Godot 就能摆脱原生代码"这条理由在本项目上直接失效。

### 发行体积与签名（实测数字）

- Godot **4.7-stable** 官方资产实测：`export_templates.tpz` **1.19 GB**（全平台）；单平台模板 `linux.x86_64` **72.2 MB**、`win64.exe.zip` **79.9 MB**、`macos.universal` **158 MB**；.NET 变体 101–187 MB。**1.19 GB 是导出模板的开发环境成本，不是成品体积。**
- 同类真实工具对照：**Pixelorama v1.1.5** 出包 Linux 27 MB / Windows 34 MB / `setup.exe` 67.1 MB / `.dmg` 65.2 MB —— 成品体积不是问题。
- **macOS 公证是一等公民**：导出预设内置 `Codesign`（Xcode `codesign`，或 Linux/Windows 上的 **`rcodesign`**）+ `Notarization`（`notarytool`），支持 App Store Connect 密钥与 ticket stapling。**但**：用 GDExtension 时硬化运行时需要 **"Disable Library Validation"** 权限——等于削弱刚做完的公证加固。
- **Windows**：导出时可 SignTool / osslsigncode 签名，支持 Embed PCK 出单文件 exe。
- **Linux**：产物是 二进制 + `data.pck`；官方导出文档里 **AppImage 零次出现**，推荐路线是 Flatpak。本项目目前发 AppImage → 需自建流程。
- 安装包："Godot does not have built-in support for creating installers" → Inno Setup / NSIS / create-dmg 自己写。

### 许可（这一栏别选错）

- **Godot 是 MIT**：对闭源商业应用的唯一义务是"在某处附上许可文本"（关于页 / 许可页 / 日志 / 附带文件 / 链到 godotengine.org/license，任一即可）。无 copyleft，不要求开源。仍需随包附第三方（含字体 OFL）声明。
- **真正的许可陷阱不是 Godot，是 Qt Quick 3D**：它只有**商业授权或 GPLv3**，**没有 LGPL 选项**——"Qt Quick 3D is available under the commercial license from The Qt Company. In addition, it is available under the GNU General Public License, version 3."。本项目是 MIT，若有人提议"那不如改用 Qt Quick 3D"，**那是把 MIT 项目拖进 GPL**，比换 Godot 严重得多。（Qt Quick 3D 内部还打包了 MIT 的 Godot 代码：`Godot Engine: Fog`、`Godot Engine: ProceduralSky`。）
- 本项目现在用的是 Qt 基础模块 LGPLv3 动态链接，与 Qt Quick 3D 的处境**不同**，不要混为一谈。

### 渲染模型差异（容易被忽略）

- 本项目是**按需绘制**（README:272「静止时低帧率和较长帧间隔属于正常休眠」）。
- Godot 的 `OS.low_processor_usage_mode` **默认 false**，即持续 vsync 重绘。一个常驻桌面音乐面板的待机功耗与风扇表现会直接变化——需要额外配置（`Engine.max_fps` / 低耗模式）才能接近现状。

---

## 四、两种范围分别怎么算

### 范围 A：仅 3D 场景交给 Godot

**可行性**：代码边界已经存在（`Scene3D.qml` / `Overlay.qml`），场景本体也只依赖"模型 + 材质 + 相机 + 拾取"——**从代码角度看这是个干净的切口**。问题不在切口，在切口两侧怎么把一帧递过去。

**拦路虎（按严重度）**：

1. **合成路径（唯一的硬拦路虎）**。`LibGodot` 确实存在：PR #110863 "LibGodot: Core — Build Godot Engine as a Library"（kisg / Migeran）已于 **2025-10-08 合并**，随 **Godot 4.6**（2026-01-26 发布）落地，官方 FAQ 标注 **experimental**，支持 Win/mac/Linux。API 是 `GodotInstance`：`libgodot_create_godot_instance` 创建，`start()` / `iteration()` / `pause()` / `resume()` / `focus_in()` / `focus_out()`。**限制：一个进程只能创建一个实例**（引擎内部大量全局单例）。
   但"引擎能嵌进进程"和"能渲染进 Qt 的窗口"是两件事：
   - **Apple 平台**：可以。`DisplayServerEmbedded` + `RenderingNativeSurface` + `Window::set_native_surface(...)`，把 `CAMetalLayer` 交给宿主即可，Metal / MoltenVK 直接往上画。
   - **Windows / Linux**：**不可以**。README 原文："a separate Vulkan instance and the use of external textures is required"；存在一个**基于 Godot 4.2** 的 Vulkan External Texture 原型，但只说"we intend to upgrade and refactor this patch"——**从未合入，也没有跟踪 issue**。官方 C++ 示例里 Godot 显示的是"**自己的窗口**"，不是你的 widget。
   - 目前唯一的公开 Qt 集成尝试 `the-argus/qt-libgodot`（2026-02-09 建，**6 次提交、0 star、无 README、无 release**）的唯一平台文件是 `src/metal_layer_widget.mm`，编译条件 **`if (APPLE)`**，submodule 还钉在 migeran 的 fork 上。**这就是"Qt + Godot"的现状。**
   - 唯一文档化的跨应用取图路线是 `Viewport.get_texture().get_image()` = **GPU→CPU 回读**。每帧一次回读再上传，等于把插帧与低功耗的前提全部推翻。
   - 另有 API 稳定性风险，维护者在 #110441 明说："Everything we can get in during Godot 4.6's development can change the original `libgodot_create_godot_instance`"。
2. **插帧前提被破坏**。当前 FG 只让 3D 参与插值、UI 原生叠加；一旦 3D 帧要跨进程/跨上下文搬到 Qt，帧时序与运动矢量都不再可控。
3. **收益端很薄**。能省掉的主要是 `RhiScene.cpp` 里的材质烘焙与光照图集（Godot 用 PBR + LightmapGI/ReflectionProbe 覆盖），以及 `export-assets.py` + `bake-archive-lighting.py` 两套自研烘焙。

**结论**：这个范围在 **Windows / Linux 上今天不成立**——不是"难"，是缺一条已经存在的 API。macOS 技术上可行，但那等于为三条平台中的一条单独写一套渲染路径（且要维护一个极不成熟的上游 experimental 接口 + 一个 6 次提交的社区原型）。即便打通合成，picking、输入、动画状态机仍要在 C++/GDScript 两边对齐，**净收益接近零**。

**不建议**，除非目标本身是"让 3D 场景可以用编辑器维护"，且愿意只支持 macOS。

### 范围 B：整个呈现层改 Godot

需要重做的清单：

- 3D 场景 5,028 行 → Godot 场景树（**这部分反而是收益**：`SceneMotion` + `Assets/animation/boot-tracks.json` 的自研时间轴可换成 `AnimationPlayer`）
- HUD 5,001 行 → Control 树 + TextServer 文字（**风险最高**：`NativeHud::Layout` 是手工像素级排版，`Glyphs` 自带 `width/wrap/inset/artWidth`；换成 Godot 的布局与文字度量后，整套视觉需要重新对齐）
- 超分 / 呈现 7,363 行 + 着色器 510 行 → 大部分**直接消失（功能也消失）**：FSR3.1、FG、自持交换链都没有对应物
- 9 个场景/呈现相关检查程序（`RhiSceneChecks` / `NativeSceneChecks` / `PresentationChecks` / `FgCapabilityChecks` / `FgGateProbe` / `ScenePostProcessChecks` / `SceneMotionChecks` / `UiChecks` / `UiMotionRegression`）+ `scripts/test-visual.cjs` 的金标准帧对照（`.qz` 基线）→ 全部作废重建
- 托盘（Linux 缺口）、媒体键/MPRIS、窗口 chrome、自动更新、三平台打包签名 → 都要重新实现或退回原生代码

**结论**：只有在"愿意放弃 FSR3/FG、接受按需绘制变成持续重绘、并接受项目重新定位为 Godot 应用"的前提下成立。否则**否决**。

---

## 五、成本量级（人日，区间）

**锚点**：本项目自己给 FG 自持交换链的估算就是 **20–33 人日**（`docs/fsr-integration-status.md` 第四节）。Godot 侧要把同等能力补回来，成本只会更高（要 fork 引擎）。

| 项 | 范围 A | 范围 B |
| --- | --- | --- |
| 前置 go/no-go 原型（LibGodot 嵌入 + 与 FSR3 共存） | 5–8 | 5–8 |
| 场景重建 | 8–12 | 15–20 |
| HUD / 文字 / 列表 / 对话框 | — | 40–60 |
| 输入与拾取桥接 | 4–6 | 6–8 |
| 合成 / 缩放 / 呈现 | 3–5 | 10–15（且功能仍缺 FSR3/FG） |
| 音频 / OS 集成重新接线 | — | 15–25 |
| 测试与视觉基线重建 | 3–5 | 10–15 |
| 三平台打包 / 签名 / 公证 / CI | 3–5 | 8–12 |
| **合计** | **~25–40** | **~110–180** |

两个范围都**先花 5–8 人日做 go/no-go 原型**，否则后面的数字没有意义。

---

## 六、如果真正的痛点其实是这些，有便宜一个数量级的解法

把"想上 Godot"背后可能的动机逐条拆开：

1. **自研渲染栈维护成本高** —— 成本集中在 FSR3/FG/MetalFX 与自绘文字，**不在 3D 场景本身**。可先做的：AA 矩阵从"七种互斥"收窄（这是自找的复杂度）；`fg/` + `fsr/` 已经是可裁剪模块（README:179 写明缺 FidelityFX-SDK 时构建仍成功，只是不编入 FSR3）。**换引擎不能降低这部分成本，只会让它变成"要么没有、要么 fork"。**
2. **HUD 手工排版累** —— `Hud` 已经是 `QQuickPaintedItem`，可以直接换成 Qt Quick 原生 `Text`/`Label`，用 Qt 自己的文字栈，比迁 Godot 便宜一个数量级，且不动 3D 与 FG。
   **但别顺手换成 Qt Quick 3D**：该模块只有商业授权或 GPLv3，没有 LGPL，"把 3D 也一起搬过去"会把 MIT 项目拖进 GPL。Qt Quick（2D 的 `Text`/`Label`）不受此限。
3. **想要编辑器 / 动画时间轴** —— 可以用 Blender 出动画、离线烘焙进 `boot-tracks.json`，把可视化编辑留在外部工具，而不换运行时引擎。
4. **想要更强 3D 表现力** —— 现栈已经能画 GLB 烘焙网格 + PBR 参数 + 光照图集；缺的实时阴影、后处理可以在现栈补，不必换引擎。
5. **跨平台驱动兼容性** —— 这一点 Godot 确实更好（D3D12 生产可用、自动回退链）。但当前 Vulkan/GL/Metal 三路已经跑通，收益是"更省心"，不是"能跑"。

---

### 必须承认的反方理由（steelman）

上面的结论若不写这一段就不诚实——当前呈现栈确实脆弱，而且脆弱在很痛的地方：

- 工具链重：`glslang` 全量首次构建约 **40 分钟**；DX12 的 DXC 要从 LLVM 级源码构建（CI 需缓存）。
- 可移植性补丁多：FidelityFX 在 Linux 上 `wchar_t` 是 4 字节导致 SDK 的 `static_assert` 失败，只能改 `FFX_SDK_DEFAULT_CONTEXT_SIZE`（实际需求 FSR3 209,462 / FI 192,018 / OF 122,210 个 uint32）；`sprintf_s` 系列、`std::wstring_convert` 已从 libstdc++ 16 移除、FG swapchain 无条件 `#include <Windows.h>`——清单见 `docs/fsr-integration-status.md` 第二节。
- 认知负担持续：**127 次提交里 23 次（18%）触碰图形代码**。
- Godot 能一次性消掉：自研渲染器、两套资产烘焙脚本、着色器工具链、以及"每种 AA × 每种后端"的测试矩阵。

**但**：若团队的真实目标是"少维护图形、多做音乐功能"，那么砍掉 FSR3/插帧是一个可以讨论的**产品取舍**，不是技术评估能替你下的结论。本报告只回答"技术上能不能、代价多大"——答案是能，代价是失去那两项能力并投入约 110–180 人日。

---

## 七、如果仍要推进：可验证的最小下一步

1. **5–8 人日 spike**：LibGodot 编译成共享库 → 从 Qt 侧启动 → 把 Godot 一帧交给 QRhi 纹理 → 记录 CPU/GPU 开销与延迟。**务必在 Windows / Linux 上做**，因为这是唯一还没有现成答案的平台（macOS 已有 `DisplayServerEmbedded` 通路，跑通了也不证明另外两个平台可行）。
2. **判定闸门**：若合成只能走 `get_image()` CPU 回读，或必须自行移植那个 4.2 时代的 Vulkan external-texture 补丁——**立即否决**（插帧与低功耗前提被破坏，且等于自己长期维护一份引擎补丁）。
3. **文字原型**：用 Godot Control 复刻一个 200 行歌词列表 + 分页歌单列表，实测 CJK 排版质量与每帧更新开销（无官方数据可依）。
4. **若要保留 FSR3.1 + 插帧**：Godot 侧必须 fork 引擎（自持交换链 + 公开 jitter）。这会切断上游升级路径——单独估这一项，通常就等于"不迁移"。

---

## 八、仍未验证 / 需实测的项

已由第二轮资料核实、从原清单移出：导出体积与签名公证流程（见 §三"发行体积"）、`LibGodot` 在 Win/Linux 的宿主合成能力（已确认**未实现**，仅有 4.2 时代原型）、AppImage（官方文档零提及，社区路线是 Flatpak）。

仍开着的：

- **密集 CJK 列表每帧更新的文字开销**：官方没有任何基准数据。这是范围 B 的最大单点风险，只能靠原型实测（见 §七 第 3 条）。
- **Godot 4.7 中 Metal 是否仍限 Apple Silicon**（4.4 时明确限制在 ARM 设备）。
- **插帧提案 #14768 的关闭理由原文**（GitHub issue 正文需 JS 渲染，未能读到；只能确认状态为 closed/archived，且未进 4.8 路线图）。
- **Win/Linux external-texture 的路线图时间**：README 只说"intend to"，无 PR、无 issue 跟踪。
- **`LibGodot` API 在 4.8 的稳定度**：维护者已预告可能变更。
- **先例缺位**：Pixelorama（Godot 4.7.1）、Material Maker（4.7）、GodSVG（4.8）证明 Godot 能出成熟跨平台工具，但它们**全部是整包重写、没有一个在嵌入宿主**；也没有任何"把 Godot 嵌进 Qt"的规模化事后复盘可参考。**缺少证据不等于不存在**，只意味着这条路没有前人替你踩过坑。

---

## 九、一句话回答

**"能不能"**：范围 A（只把 3D 交给 Godot）在 **Windows / Linux 上今天没有可行路径**——Godot 只能在 Apple 平台把窗口渲染进宿主提供的 surface，唯一的 Qt 集成尝试是个 6 次提交的 macOS 原型。范围 B（整个壳改 Godot）能，但要重写 18.4k 行、丢掉 FSR3.1 超分与 FSR 插帧两项当前最值钱的能力，还得自己补 Linux 托盘、MPRIS、Wayland、高 DPI 与 AppImage。

**"该不该"**：不该。真正该减的是 AA 矩阵宽度、FG/FSR 的可裁剪性、HUD 的手工排版——这三件事换个引擎一件都解决不了，换个引擎只会让它们变成"要么没有、要么 fork 引擎"。
