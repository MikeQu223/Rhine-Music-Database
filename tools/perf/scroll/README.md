# tools/perf/scroll — 滚动路径的 A/B 脚手架

固定同一段滚动动作（首次快速滚 → 原路返回 → 停下等待），用来对比纹理准入延迟、节拍策略、
实例格式等改动的效果。产物是「日志 + 时间线标记 + 截图」，靠 `analyze_admission.py` 按段聚合。

## 依赖

与 `tools/perf` 相同：**niri**（取窗口、聚焦）、**grim**（截图留证）、**`/dev/uinput` 可写**（按键注入），
python3 与 bash。仓库需先构建出 `output/qt-build/RhineMusicDatabase`。

## 准备会话基线（每次测量前都要）

程序退出会回写 `session.json`，所以脚本每轮都注入固定起始状态、结束时还原用户原状态：

```bash
sess=~/.local/share/RhineMusicDatabase/rhine.music.database/session.json
cp "$sess" /tmp/session.orig.json                       # 备份用户状态
cp tools/perf/scroll/session.baseline.json "$sess"      # 注入固定起点（自己准备一份）
```

`session.baseline.json` 不入库（体积大且含本机库路径）：用 `python3 tools/perf/make_baseline.py`
或直接把一份干净的会话另存一份。

## 用法

```bash
# 单轮：<准入延迟 ms> [标签]
bash tools/perf/scroll/ab.sh 0 d0
bash tools/perf/scroll/ab.sh 100 d100

# 两轮对照（0 与 100 各跑一遍）
bash tools/perf/scroll/both.sh

# 按段聚合（同组多轮取均值；tags 用正则匹配）
python3 tools/perf/scroll/analyze_admission.py 'd0' 'd100'
```

脚本会：杀旧进程 → 注入 baseline → 启动（`RHINE_TEXTURE_PROBE` / `RHINE_STEP_PROBE` / `RHINE_PACE_DIAG`
/ `RHINE_TEXTURE_ADMISSION_MS=<delay>`）→ 等首条探针行 → 热身 → 聚焦窗口 → `ESC` `→` `F11` 进列表 →
下滚 6 s → 停 1 s → 上滚 6 s → 静止 8 s → 截图 → 杀进程。时间线标记写入 `<tag>.timeline`，
段名为 `idleA / seg1 / seg2 / seg3`。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `OUT_DIR` | 日志/截图/时间线的输出目录，默认 `tools/perf/scroll/out` |
| `WARMUP` | 热身秒数，默认 5 |
| `EXTRA_ENV` | 追加给被测程序的环境变量，例如 `EXTRA_ENV="QSG_RENDER_TIMING=1"` |
| `RHINE_AB_DIR` | 分析脚本读日志的目录（默认同上 `out`） |

## 文件

| 文件 | 作用 |
| --- | --- |
| `ab.sh` | 单轮三段滚动 |
| `both.sh` | 0 与 100 两轮对照，结束还原会话 |
| `stamp.py` | 给程序 stdout 每行打 epoch 毫秒前缀（`analyze` 依赖这个前缀） |
| `holdkey2.py` | 按住某键若干秒（`holdkey2.py 6 108` = 按住 ↓ 6 s） |
| `analyze_admission.py` | 按段汇总节拍/拍成本/3D 内部/纹理探针/GPU 行 |
| `analyze_qsg.py` | 汇总 `QSG_RENDER_TIMING` 的 sync / render / swap 与 `blockedForSync` |

## 已知坑

1. **pkill 自杀**：把 `qt-build/RhineMusicDataba[s]` 这类模式与裸路径写在同一条 `bash -c`（含 heredoc）里，
   会把自己的 shell 一起杀掉。脚本文件内调用是安全的。
2. **必须从仓库根启动**：程序按相对路径找播放服务。
3. **`fg=off` 时 `RHINE_GPU_PROBE` 无效**：它只在 `PresentationShell::renderFrame()` 里采样。
   GPU 时间要看 `节拍诊断` 的 `gpu=` 字段（来自 `cb->lastCompletedGpuTime()`，是"最近已完成帧"）。
4. **窗口均值只适合定方向**：判定 GPU 时间要用时间戳采样，别拿 CPU 录制时间当 GPU 时间。
