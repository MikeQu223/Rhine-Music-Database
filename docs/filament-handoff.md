# Filament 适配交接文档

> 状态：**Filament 后端代码已落地**，C1–C3 契约全部达标；但 V1–V16 中**仅 V1 / V12 / V13 已验证通过**，
> V3 / V4 明确未通过，其余 11 项未验证；P3 真实 AA/FSR 与 P4/P5 未实现。逐项状态见第一节。
> 当前工作区：RHINE_FILAMENT=ON 与 OFF 两种配置均完整构建通过、测试全绿，**未创建任何 git 提交**。
> 更新日期：2026-10-27。

---

## 一、交付状态

**重要：本表为逐项实际状态，与计划第 9 节的 V1–V16 清单一一对应。**

| V 编号 | 验收项 | 计划门槛 | **实际状态** |
|---|---|---|---|
| V1 | 关闭时零差异 | 逐字节 | ✅ **已验证** 0 / 2,073,600 |
| V2 | 色彩正确 | 16 色块 PSNR ≥ 40 dB | ❌ **未验证** |
| V3 | 单立方体几何正确 | SSIM ≥ 0.98 | ❌ **未通过** 22.34 dB |
| V4 | 完整场景观感 | SSIM ≥ 0.98 | ❌ **未通过**（画面平坦 2.2 倍） |
| V5 | 透明遮挡顺序 | 定点断言 + 截图 | ❌ **未验证** |
| V6 | 实体池稳态 | created==1 / alive==1 | ❌ **未验证** |
| V7 | 图像交接 | 3000 帧零验证层错误 | ❌ **未验证** |
| V8 | 同步压力 | 3000 帧 | ❌ **未验证** |
| V9 | 降级 | 注入 E_FIRST_FRAME 同帧恢复 | ❌ **未验证** |
| V10 | 拾取不变 | 开关前后命中一致 | ❌ **未验证** |
| V11 | 退出与 rhi 重建 | 无崩溃 / 无验证层错误 | ❌ **未验证** |
| V12 | 性能 | 中位 ≤ +25% | ✅ **已验证** 快 24% |
| V13 | 显存 | 3000 帧无增长 | ✅ **已验证** |
| V14 | 材质参数齐全 | matc -r 反射比对 | ❌ **未验证** |
| V15 | GL 4.1 回退 | E_GL_TOO_OLD 且旧链路可用 | ❌ **未验证**（GL 后端未实现） |
| V16 | 单队列串行化 | 3000 帧 | ❌ **未验证** |

### 阶段状态（按计划第 11 节的量化门）

| 阶段 | 计划交付 | 实际状态 |
|---|---|---|
| P0 | 零回读交接 | 已实现；**V7 未验证** |
| P1 | 开关 / 探测 / 回退 | 已实现；V1 通过，**V9 / V15 未验证** |
| P2a | 单材质变体打通完整场景 | **V3 未通过**；V14 未验证 |
| P2b | 6 变体矩阵 + 排序 | **V4 未通过**；V5 / V6 未验证 |
| P3 | AA / FSR 接通 | **仅实现安全兜底**：MSAA / SSAA / TAA / FSR3 一律重映射为 fxaa / fsr1，真实效果未实现 |
| P4 | FG 与纹理生命周期 | **未实现**（需呈现层架构改动） |
| P5 | 三平台 + Metal + 双缓冲 | **未实现** |

### 其他已知未解决项

1. **3D 模型渲染错误（V3/V4）** —— 画面比 legacy 平坦 2.2 倍，`face` 分布错误（96% 为 5，应为 1/2）。详见第三节。
2. **真实抗锯齿 / FSR3 未接通（P3）** —— 当前只是把不支持的 AA 模式降级为 fxaa / fsr1 保证不出错，用户选择 MSAA/TAA/FSR3 时拿不到真实效果。
3. **帧生成（P4）未实现** —— 需要呈现层架构改动，计划中标注为需授权。
4. **两个调试开关损坏** —— `RHINE_FILAMENT_UNLIT` 触发 abort（exit 134），`RHINE_FILAMENT_PROBE_QUAD` 触发 SIGSEGV。均不影响正常渲染。
5. **GL 4.1 回退未实现（V15）** —— 仅有 Vulkan 路径。
6. **界面问题** —— 设置开关缺失（本次已修复）；其余界面问题需用户指出具体现象。

---|---|
| P0 零回读图像交接 · P1 三层开关 · P2 场景渲染 · P3 后处理 | 完成 |
| C1 关闭时逐像素一致 | 通过（0 / 2,073,600） |
| C2 默认关闭 | 通过 |
| C3 失败降级不崩溃 | 通过 |
| 双配置构建 + 测试 | ON 10/10 · OFF 9/9 |
| 单测 | FilamentChecks 104 项 |
| 性能（V12） | 中位 1.93 vs 2.54 ms（**快 24%**） |
| 内存（V13） | 无泄漏，比 legacy 少 23 MB |
| 缺陷修复 | 19 个（含 1 个既有打包缺陷） |
| 仓库审计 | 744 文件通过 |
| **V3/V4 保真度** | **22.34 dB，未达标** |

改动规模：28 个已跟踪文件（+885 / −333 行），新增约 3,650 行（后端 2,693 + 测试/脚本 957）。

---

## 二、构建与验证

开启 Filament（默认 OFF）：

    cmake -B output/qt-build -DRHINE_FILAMENT=ON
    cmake --build output/qt-build
    ctest --test-dir output/qt-build          # 期望 10/10

默认配置（不带 Filament）：

    cmake -B output/qt-build -DRHINE_FILAMENT=OFF
    cmake --build output/qt-build
    ctest --test-dir output/qt-build          # 期望 9/9（qt_filament_checks 不注册）

首次需拉取 SDK（幂等）：

    npm run fetch:filament

抓对照图（确定性）：

    RHINE_FREEZE_TIME=1 RHINE_CAPTURE_STEPS=600 RHINE_FILAMENT=1 \
      xvfb-run -a ./output/qt-build/RhineMusicDatabase --capture /tmp/a archive

产物 /tmp/a/qt-window.png 是真实 GPU 帧；qt-composite.png 与 qt-metal.png 来自 CPU 参考管线，**不可作为基准**。

抓原始场景色（**两端条件不同，务必注意**）：

    # Filament 侧：必须开启 Filament
    RHINE_FILAMENT_DUMP=1 RHINE_FILAMENT=1 ...   # -> /tmp/filament_readback.bin
    # legacy 侧：必须关闭 Filament，否则 color.texture 从未写入
    RHINE_FILAMENT_DUMP_LEGACY=1 ...             # -> /tmp/legacy_readback.bin

材质强制重编：

    rm -f output/resources/OpticalSurface_*.filamat

---

## 三、V3/V4 未解问题（核心）

### 3.1 现象

Filament 渲染的画面比 legacy **平坦约 2.2 倍**（原始场景色 std 0.081 vs 0.178），两者逐像素相关仅 **+0.088**。

### 3.2 已经确认的事实

| 项 | 结论 | 依据 |
|---|---|---|
| 测量通道有效性 | 可信 | dump 与同次运行合成图相关 **+0.4907** |
| 几何与相机 | **正确** | 视深度逐像素相关 **+0.9537** |
| 几何对齐 | **完全对齐** | 二维互相关最佳位移 **(0,0)**，相关 0.3724 |
| 顶点数据（CPU 侧） | 正确 | 首顶点法线模长 1.0；19,962 顶点 face 直方图六向均匀 |
| 顶点绑定 / 偏移 / 步长 | 正确 | 与 RhiScene.cpp:797 逐项一致，且偏移改动会如实反映 |
| 交错 vs 独立缓冲 | 无差异 | 结果逐字节相同 |
| CUSTOM0 vs CUSTOM1 | 无差异 | 结果分毫不差 |
| globals.view 是否含缩放 | 不含 | m15=1.0，m00/m05/m10 为正常旋转分量 |
| getWorldPosition vs model*position | 等价 | 深度比值完全相同 |
| 着色代码与 legacy | 逐行一致 | 含 face 分支、UV 公式、saturate 量化、图集打包 |
| **Filament 属性读取** | **正确** | **常量注入 (0,1,0) 后 face 100% 为 1** |

### 3.3 唯一确定的矛盾

两端**顶点着色器**用**同一函数**（getFace / getFaceV，源码逐字相同）、**同一空间**（模型空间）、**同一份缓冲数据**，算出的 face 分布却完全不同：

| face | Filament | legacy |
|---|---|---|
| 1 | 48 | 476,792（49%） |
| 2 | 35,051 | 451,171（46%） |
| 3 | 69 | 42,065（4%） |
| **5** | **938,054（96%）** | 668 |

逐像素相关 **0.0000**。

取负法线后 face 在 5 与 2 之间**精确互换**（像素数完全相同 938,054 与 35,050），说明存在符号 / 手性差异；但 legacy 主导面是 1（|y| 主导），Filament 无论取负与否都不产生 face=1，说明**轴向分布也不同**。

### 3.4 已排除的修复路径

- requires: ["normal", "uv0"] —— **非法键**，Filament 的 requires 不接受 normal
- 顶点端调用 prepareMaterial(material) —— **片元专用**，顶点着色器不可用
- 改用标准 NORMAL 属性槽 —— 受上面两条限制，无法在顶点端取得模型空间法线
- meshId 改用稳定唯一 id —— 渲染完全未变，本场景无缓存碰撞

### 3.5 推荐下一步

1. **接入 RenderDoc / apitrace**，直接抓取 Filament 顶点着色器中 getCustom0() 的实际输出，与缓冲区字节逐位比对。这是唯一能解开「同数据不同结果」这一矛盾的观测手段。
2. 若不可行，做**单 mesh 单顶点法线 dump**：材质里把 normalAttr 原样写入 v0，片元直接输出，与 CPU 侧已知值 (-0.0002, -0.9992, 0.0401) 比对。
3. 排查 Filament 是否对 CUSTOM* 属性做归一化（尝试 BYTE4N / SHORT4N 等显式非归一化格式）。

---

## 四、本次会话修复的缺陷

### 4.1 设置界面缺少 Filament 开关（用户反馈）

**症状**：设置里看不到「Filament 渲染」这一行。

**根因**：该行被 #ifdef RHINE_FILAMENT_AVAILABLE 包着，而该宏只在 -DRHINE_FILAMENT=ON 时定义。

**修复**（3 处）：

- FilamentConfig.cpp 第 5–6 行已无条件定义该宏（缺省 0），compiledIn() 返回 RHINE_FILAMENT_AVAILABLE != 0 —— 两个配置函数**任何配置下都可用**
- Qt/src/NativeHudModal.cpp：移除设置行的 #ifdef，并把 #include "scene/FilamentConfig.h" 解除守卫
- Qt/src/NativeHudController.cpp：移除切换逻辑的 #ifdef

**效果**：设置界面**始终显示**「FILAMENT / Filament 渲染 · 重启生效」；编入时显示开启 / 关闭可切换，未编入时显示「未编入」。

### 4.2 RhineCore 有引用无实现（真实链接缺陷）

**根因**：CMakeLists.txt 的源过滤正则 "...|/scene/Filament" 把 FilamentConfig.cpp 一并排除出 RhineCore，但 RhineCore 编译的 NativeHudModal.cpp 在 RHINE_FILAMENT_AVAILABLE 下引用 RhineFilament::resolveConfig / compiledIn —— **有引用无实现**，导致 RhineLocalMusicRegression、RhineNativeHudRegression、RhineUpdaterRegression **链接失败**。

**为何长期被掩盖**：平时只构建主目标（--target RhineMusicDatabase），ctest 跑的是旧测试二进制；只有完整构建才暴露。

**修复**：过滤正则改为

    "/tests/|/fsr/|/fg/|/render/|/scene/Filament(Bridge|Assets|Scene|Platform)\\."

即只排除需要 Filament SDK 的四个文件，保留 FilamentConfig.cpp 进入 RhineCore。

**验证**：ON 为 10/10；OFF 为 9/9；两者均无链接错误。

---

## 五、方法纪律（本次会话踩过的坑，务必先读）

1. **先证明观测通道恒等，再下结论。** 用「写入已知常量 → 检查读回是否原样」验证任何通道。四条候选路径已证明**不可用**：窗口抓图（经完整后处理）、外部镜像回读（内容不符）、后处理输入目标回读（含跨通道色彩变换，纯红输入 B=67 为证）、alpha 通道（被强制写为 1.0）。
2. **对比两端的量必须同空间、同尺寸、同一时机。** 模型空间对世界空间、1080x1080 对 947x1028、片元对顶点——这三类错误各造成过一次错误结论。尤其注意 legacy 的 v_normal 是**世界空间**（顶点着色器里乘了 model），而材质里的 normalAttr 是**模型空间**。
3. **检查 .filamat 是否真的生成（正常 6 个）。** 材质编译失败时应用会**静默回退 legacy**，表现为指标恰好等于 1.00，极易误判为「改动无效」。
4. **--capture 路径只渲染 1~2 帧。** RHINE_CAPTURE_STEPS=600 控制的是动画步进，不是渲染帧数；两处 dump 实测都发生在**第 1 帧**。
5. **getUV0() 与 vUv 在顶点 / 片元作用域名字不同**；用错会构建失败并静默回退 legacy。
6. **CUSTOM0 在 Filament 中是 MORPH_POSITION_0 的别名**（见 VertexBuffer.h），语义上不是自由槽位。

---

## 六、文件索引

### 新增模块

| 文件 | 职责 |
|---|---|
| Qt/src/scene/FilamentContract.h | 全 POD 跨运行时契约（DrawBatch / FrameGlobals / FrameStats） |
| Qt/src/scene/FilamentConfig.{h,cpp} | 三层开关解析、13 个 E_* 错误码 |
| Qt/src/scene/FilamentPlatform.{h,cpp} | VulkanPlatform 子类，零回读交接 |
| Qt/src/scene/FilamentAssets.{h,cpp} | 6 个材质变体、3 张图集、网格缓存 |
| Qt/src/scene/FilamentScene.{h,cpp} | 批次同步、64 实例分块、帧级 uniform |
| Qt/src/scene/FilamentBridge.{h,cpp} + Stub.cpp | 生命周期；未启用时为空实现 |
| Qt/shaders/filament/OpticalSurface.mat | 与 legacy 逐行对应的移植材质 |
| Qt/tests/FilamentChecks.cpp | 104 项单测 |
| scripts/fetch-filament.cjs | 幂等拉取 SDK（npm run fetch:filament） |
| scripts/filament-diff.py | 分区 PSNR / 差异热图（npm run filament:diff） |

### 主要修改

Qt/src/RhiScene.cpp（合成接管点、纹理缓存、确定性捕获）、CMakeLists.txt、Qt/src/main.cpp、Qt/src/Engine.{h,cpp}、Qt/src/Host.cpp、Qt/src/NativeHud*.cpp、scripts/package-resources.cjs、.gitignore

### 相关文档

- docs/filament-implementation-plan.md —— 2675 行，完整过程记录与逐项证据
- docs/filament-migration-assessment.md —— 迁移可行性评估
- docs/filament-plan-review.md —— 计划评审
