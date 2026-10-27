# FSR 接入：任务清单与交接状态

> 跨会话交接用。规则：不提交代码、不运行程序（允许构建）、不引入预构建二进制。

## 一、总目标

三平台一起做超分与插帧，全部源码构建：

| 平台 | 超分 | 插帧 |
|---|---|---|
| Windows / DX12 | FSR3.1 | 是 |
| Windows / Vulkan | FSR3.1 | 待定（见「FG 阻塞」） |
| Linux / Vulkan | FSR3.1 | 待定（见「FG 阻塞」） |
| 全平台 GL | FSR1（EASU+RCAS） | 是 |

抗锯齿七种互斥单选：`off / fxaa / ssaa / msaa / taa / fsr1 / fsr3`，默认全关。FSR 与其它 AA 不可同时开。

**D3D11 已彻底移除**（用户决定，不做自动切换）：Windows 只保留 D3D12 / Vulkan / OpenGL。FSR3 只支持 DX12 与 Vulkan；FSR1 是纯片元方案，所有后端可用。

## 二、已完成（构建全绿）

### 着色器链：全部构建期从源码生成，零预编译二进制

- `cmake/Glslang.cmake`：`third_party/glslang` 16.6.0 作为子项目构建出 `glslang-standalone`（`ENABLE_OPT=ON` 必需，`-Os` 依赖 SPIRV-Tools）。首次全量约 40 分钟。
- `cmake/FfxShaderCompiler.cmake`：把 SDK 的 `ffx_shader_compiler` 编成构建期工具 `ffx_sc`。
  - `cmake/ffx_sc_port/` 提供 Windows API shim（`Windows.h`）、替换 `pch.hpp`、HLSL 编译器 stub、可移植 `utils.cpp`、宽字符入口转发 `entry.cpp`。SDK 源文件不改，靠「暂存到构建树 + 同名头文件遮蔽」生效。
  - `glsl_compiler.cpp` 打了一个补丁：`token.pop_back()` 在空 token 上会把长度下溢成 `SIZE_MAX`，libstdc++ 抛 `std::length_error`。并发构建必触发，单跑几乎不触发。
- 生成 **112 个置换头**（FSR3 10 个 pass × 4 变体 + FI 11 × 4 + OF 7 × 4），输出在 `output/qt-build/ffx_shaders/vk/`。
- FG swapchain 的 6 个 UI 合成/调试着色器原本是签入的预编译 SPIR-V（`.h` 里的 `uint32_t` 数组），已改为构建期用同一套 glslang 参数（`--vn`）从 `.glsl` 生成，见 `_rhine_ffx_prepare_swapchain`（仅 Windows 生效）。

### 主机端

- `Qt/src/fsr/Fsr3Backend.h/.cpp`：Vulkan 后端封装。`compiledIn()` / `supported(QRhi*)` / `resize()` / `release()` / `setCamera()` / `setJitter()` / `dispatch()`。资源用 `ffxGetImageResourceDescriptionVK` + `ffxGetResourceVK` 包装 QRhi 纹理，命令缓冲区由调用方传入（`QRhi` 没有 `currentFrameCommandBuffer()`）。
- 自动曝光关闭（不设 `FFX_FSR3UPSCALER_ENABLE_AUTO_EXPOSURE`），仅开 HDR。
- 已链接进 `RhineMusicDatabase`，`RHINE_FSR3_VULKAN` 宏控制可用性。

### SDK 的 Linux 可移植性修复（都不改 SDK 源）

- **上下文尺寸**：`FFX_SDK_DEFAULT_CONTEXT_SIZE` 按 Windows 2 字节 `wchar_t` 校准（512 KiB）。Linux 上 `wchar_t` 4 字节，`FfxResourceBinding` 140→268 字节，FSR3 私有上下文涨到 837848 字节，SDK 自己的 `static_assert` 失败。实测需求：FSR3 209462、FI 192018、OF 122210 个 uint32。用构建树里的 `ffx_types.h` 覆盖副本改成 `(1024 * 256)`，放在 include 路径最前。
- `sprintf_s` / `strcpy_s` / `wcscpy_s`（指针+长度重载）/ `FFX_UNUSED` 补进 `cmake/ffx_linux_compat.h`。
- `std::wstring_convert` 在 libstdc++ 16 已移除，两种模板拼写都要改写（`_rhine_ffx_compat_copy`）。
- `cmake/ffx_windows_shim.h` + `ffx_synchapi_shim.h`：FG swapchain 无条件 `#include <Windows.h>` / `<synchapi.h>`，提供 auto-reset 事件、线程、`CRITICAL_SECTION`、`QueryPerformanceCounter`（纳秒口径）。
- `ffx_shared` 需包含全部四个 `sdk/src/shared/*.cpp`（消息、面包屑、断言、对象管理）。
- `rhine_fidelityfx_sdk` 的 `-include cstddef -include cwchar` 必须写成单个 `SHELL:` 条目，否则 `target_compile_options` 去重会压成 `-include cstddef cwchar`，`cwchar` 变成输入文件。
- `project(... LANGUAGES CXX C)`：glslang/SPIRV-Tools 有 C 源。

## 三、已完成（全部构建通过）

1. **RhiScene 接线**：`finalFragment` 写入 `fsrInput`（渲染分辨率）→ `beginExternal()` 内派发 FSR3 → `copyColor` 把 `fsrOutput` 拷到目标。near/far 从投影矩阵 `m[10]`/`m[14]` 反解；jitter 取反（`upsample.h` 用 `(pos+0.5) - Jitter()` 反解，故传给 FSR3 的必须是投影偏移的相反数）。
2. **FSR1 GLSL 端口**：`Qt/shaders/fsr1_easu.frag` + `fsr1_rcas.frag` + `Qt/src/fsr/Fsr1Constants.h`。EASU 从渲染分辨率升采样到显示分辨率，RCAS 直接写目标。**binding 1 必须是 FSR1 专用的 64 字节常量块**，不能复用 AO kernel。
3. **DX12 路径**：`Fsr3Backend.cpp` 里 DX12 与 Vulkan 并列，context 描述与 dispatch 的 18 个字段两个后端共用一份。顺带修掉三个真实缺陷：Windows 上把 `QRhiD3D12NativeHandles` 当 Vulkan 句柄解引用的 UB、SDK 不认的 CMake 变量名（`FFX_FSR`→`FFX_FSR3UPSCALER`/`FFX_FI`/`FFX_OF`）、两个后端头文件的同名枚举冲突。
4. **设置页**：后端名表删 D3D11；aa-mode 按后端 + 编译期能力过滤（FSR3 只在 Vulkan/D3D12 且构建里真编进了才出现）；FG 独立开关（呈现层常驻接管且插值可用后可点并即时切换、不需要重启；降级/未接管/未编入时置灰写明原因）。
5. **MSAA / TAA**：MSAA 用多重采样 color/depth + resolve，`Target.texture` 指向解析结果使下游零改动；深度不解析——合成通道改用半分辨率 `normalDepth` 算弥散圆。TAA 用 `taaHistory[2]` ping-pong + 3×3 邻域夹紧，重置走"播种"路径。
6. **免重启**：`resize()` 的重建条件包含 `sizedAaMode` 与 `sampleCount`；`RhiScene` 有 16ms 定时器在 `fsr3`/`taa` 下持续重绘；`Engine` 在这两种模式下自动开抖动。
7. **构建产物持久化**：置换头输出到 `generated/ffx_shaders/vk/`（364 个文件，约 25MB，**不被 .gitignore 排除**），可用 `-DRHINE_FFX_SHADER_OUTPUT_DIR=` 覆盖。

## 四、未完成 / 待决策

1. **FG（帧生成）**：`ffx_frameinterpolation` 与 `ffx_opticalflow` 已无条件编译并链接进二进制，FI/OF 的 Vulkan 置换头也已生成；缺的是"由应用自己拥有交换链并 present"。详见 `docs/fg-integration-plan.md`。Qt 6.12 没有任何把交换链交给应用的公开途径（`QRhiVulkanNativeHandles` 连 `VkSurfaceKHR` 字段都没有），可行路线是 `QQuickRenderControl` 双场景离屏 + 自持 `VkSwapchainKHR` + 自研 present 循环，预估 20–33 人日，且需要两个 go/no-go 闸门先验。**2026-10-25 更新：该路线的组件已实现并编入构建（`Qt/src/fg/`：FgHost / FgBackend / VulkanPresenter / FgConfig），只剩 `main.cpp` 接线与两个闸门实测，见 `docs/fsr-fg-handoff.md`。**
2. **Windows 上 DXC 从源码构建**：DX12 的 HLSL→DXIL 仍需 DXC。`third_party/dxc` 源码已在仓库，构建脚本在建。
7. 全量 diff 审查。

## 四、FG 阻塞（需要决策）

FidelityFX SDK 1.1.4 的 Vulkan FG swapchain（`sdk/src/backends/vk/FrameInterpolationSwapchain/`）**是 Windows 专用**，不是可移植代码：

- 无平台隔离地使用 `UINT64`、`LARGE_INTEGER`、`CRITICAL_SECTION`、`VkSurfaceFullScreenExclusiveWin32InfoEXT`。
- 它必须**自己拥有 `VkSwapchainKHR` 并起线程 present**。

而 Rhine 通过 Qt 的 `QQuickRhiItem`/QRhi 渲染，**交换链归 QRhi 所有**。要完整做 FG 等于接管 Qt 的呈现层（每平台重写 present 路径），不是「移植一个文件」。

当前处理：Linux 下 `cmake/ffx_fg_unsupported.cpp` 提供 `ffxSetFrameGenerationConfigToSwapchainVK` 返回 `FFX_ERROR_BACKEND_API_ERROR`，让后端能链接、运行时明确报不可用。

可选方向（待选）：
- A. FG 只做 Windows/DX12（SDK 原生支持，改动小）。
- B. Linux 也做，但要把渲染从 QQuickRhiItem 迁出、自建呈现层（工程量大，且影响现有 UI 合成）。
- C. 暂不做 FG，先把 FSR3 超分 + FSR1 落地。

## 五、已知坑

- 运动矢量目前只做模型矩阵差分，**相机自身运动不进 MV**（静态物体在相机移动时 MV=0）。FSR3 要在可动相机下正确工作，需补上一帧 view/projection。
- 抖动不会强制连续出帧，场景稳定后会休眠；FSR3 启用时要保持渲染循环。
- FSR 作用范围只有 3D（QQuickRhiItem 的纹理），UI 天然在外，符合要求。
- **CMake + Ninja 的 bash 花括号展开**：`-DFOO={0,1}` 经 `/bin/sh`（本机是 bash）会展开成 `-DFOO=0 -DFOO=1`，glslang 报 "Macro redefined"。CMake 的 `VERBATIM` 不转义 `{}`。解法是用 `cmake -P` 脚本包 `execute_process`，不经 shell。
- 构建命令：`cmake -S . -B output/qt-build && cmake --build output/qt-build -j8`。不要删构建目录。
