# tools/perf — 帧率 A/B 测量脚手架

给「同等设置下 Vulkan / OpenGL / 插帧开与关」的帧率对比用。原本是临时脚本放在 `/tmp/mb`，
`/tmp` 重启即清空，所以收进仓库。

## 依赖

- **niri**（本机合成器）：`niri msg windows` 取窗口 ID、`niri msg action focus-window` 取焦点
- **grim**：`grim -o DP-1` 截图留证
- **`/dev/uinput` 可写**：按键注入。本机没有 `wtype` / `ydotool`，niri IPC 也不提供按键注入
- python3、bash

## 测量口径（重要）

| 指标             | 来源                                                   | 含义                                           |
| ---------------- | ------------------------------------------------------ | ---------------------------------------------- |
| **内容帧/s**     | `节拍诊断` 的 `render/s`（= `Engine::m_renderFrames`） | **画面内容真正更新的次数，是流畅度的正确口径** |
| 上屏 presented/s | `FG diag` 的 `presented` 累计差分                      | 提交给合成器的次数，含同帧重复上屏             |
| 真实渲染/s       | `FG diag` 的 `rendered` 累计差分                       | 真实渲染次数；插帧开时 ≈ 内容帧                |
| 插值/s           | presented − rendered                                   | 合成出来的补帧                                 |

`fg=off` 时 Vulkan 的 presented ≈ 内容帧 × 1.86（`SceneLayerHost::renderFrame()` 在非 Metal 后端
每帧强制置脏，同一内容被重录重渲多次）。**拿 presented 当帧率会高估 Vulkan。**

## 用法

```bash
cd <repo>

# 1. 备份并生成固定起始会话（只需一次；程序运行会覆盖原 session.json，测完记得还原）
cp ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json /tmp/session.orig.json
python3 tools/perf/make_baseline.py

# 2. 单轮：<后��> <插帧> <标签> [长按秒数]
bash tools/perf/bench2.sh vulkan off  vk_off_1
bash tools/perf/bench2.sh vulkan on   vk_on_1
bash tools/perf/bench2.sh opengl off  gl_1

# 3. 多轮交错（减少频率漂移；n>=3 再看均值）
for r in 1 2 3; do
  for cfg in "vulkan off" "vulkan on" "opengl off"; do
    set -- $cfg; bash tools/perf/bench2.sh "$1" "$2" "m${r}_$1_$2"
  done
done

# 4. 分析
python3 tools/perf/analyze2.py $(ls /tmp/mb/m*_vulkan_*.log /tmp/mb/m*_opengl_*.log)

# 5. 还原
cp /tmp/session.orig.json ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json
```

`bench2.sh` 每次会：杀旧进程 → 注入 baseline → 启动（带 `RHINE_FG_DIAG` / `RHINE_PACE_DIAG` /
`RHINE_KEY_PROBE`）→ 等首条 `节拍诊断` → 热身 5s → 聚焦窗口 → `ESC` 关设置弹窗 → `→` 切到
「收藏专辑」→ `F11` 全屏 → 按住 ↓ 20s → 截图 → 杀进程。

## 环境变量

| 变量        | 作用                                                            |
| ----------- | --------------------------------------------------------------- |
| `BENCH_OUT` | 输出目录，默认 `/tmp/mb`（日志 + 截图 + baseline 都在这里）     |
| `EXTRA_ENV` | 追加给被测程序的环境变量，例如 `EXTRA_ENV="RHINE_DRAW_PROBE=1"` |
| `WARMUP`    | 热身秒数，默认 5                                                |

## 场景选择

- 主界面「收藏歌单」(COLLECTION 03) 在**账号校验失败时是空的**（`library.status` 会写
  「账号验证暂不可用」），此时长按 ↓ 没有可选项，测不出负载。所以脚本切到
  「收藏专辑」(COLLECTION 04，98 条)，同一套列表模板，列表循环不会滚到头。
- 只有 5 个设置键生效（`Qt/src/render/RenderConfiguration.h:61-65`）：
  `aa-mode` / `render-scale` / `supersample` / `fg` / `vsync`。
  `msaa` / `aa-scale` 是残留存储值，`quality=hires` 是音质不是画质。

## 已知坑

1. **pkill 自杀**：`pkill -f "qt-build/RhineMusicDataba[s]"` 的模式若与同一条命令行里的裸路径同名，
   会把自己的 shell 也杀掉。**不要把 pkill 和裸名写在同一条 `bash -c` 里，heredoc 也算**
   （heredoc 的正文属于父 shell 命令行）。脚本文件内调用才安全。
2. **必须从仓库根目录启动**：程序按相对路径找播放服务，从别处 `cd` 过去会起不来。
3. **session.json 会被覆盖**：每次退出都回写，每轮必须重新注入 baseline，测完还原用户原状态。
4. **`settingsScroll` 注入不生效**：设置页滚动位置似乎由 UI 自己维护，页面停在
   `FSR SHARPNESS`，滚不到「帧生成」行；方向键每次滚 50px 且方向与直觉相反（Up 往顶部）。
5. **`RHINE_GPU_PROBE` 在 fg=off 下无效**：它只在 `PresentationShell::renderFrame()` 里采样，
   而 `fg=off` 已改走 Qt 默认路径，那条代码不执行。
6. **构建别用 `./build.sh`**：它每次都附带 AppImage 打包，反复构建会堆满磁盘。日常验证用
   `cmake --build output/qt-build --target RhineMusicDatabase -j8`。

## 子目录

| 目录 | 用途 |
| --- | --- |
| `tools/perf/scroll/` | 滚动路径 A/B（纹理准入延迟、节拍策略）：固定「首次滚 → 原路返回 → 停下」三段动作，按段聚合探针 |
| `tools/perf/memory/` | 常驻内存观测：`RHINE_MEMORY_PROBE=1` 配连续翻动/单步/纯空闲三种输入，判定逐帧增长与缓存阶梯 |

两者的结论与数据分别见 `docs/vulkan-igpu/07-render-optimization.md` 与
`docs/vulkan-igpu/08-memory-growth.md`。

## 相关探针

| 探针                  | 输出                                                                                                       |
| --------------------- | ---------------------------------------------------------------------------------------------------------- |
| `RHINE_PACE_DIAG=1`   | `节拍诊断: tick/s=… sceneUpd/s=… hudUpd/s=… render/s=… 间隔均=…ms step均=…ms`                              |
| `RHINE_FG_DIAG=1`     | `FG diag: presented … rendered … skipped … gapP50 … \| 3D层 X ms (打磨/起帧/同步/录制/提交等待) UI层 Y ms` |
| `RHINE_KEY_PROBE=1`   | `按键到达输入层: 键 <code> 接受 <bool>`                                                                    |
| `RHINE_DRAW_PROBE=1`  | `绘制探针: draw N \| pipeline 绑定 … \| srb 绑定 … \| viewport 设置 …`                                     |
| `RHINE_LAYER_PROBE=1` | 每 60 帧打印图层重渲次数与置脏来源                                                                         |
| `RHINE_STEP_PROBE=1`  | 每拍成本分段（app->step / 其余 / 等待）                                                                    |
| `RHINE_MEMORY_PROBE=1` | 每 20 帧一行：RSS、glibc 在用堆、标签/封面/纹理字节/材质/SRB/存活资源/曲目缓存 |
