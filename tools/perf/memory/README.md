# tools/perf/memory — 常驻内存/泄漏观测脚手架

配合 `RHINE_MEMORY_PROBE=1` 使用：程序每 20 帧打印一行内存与容器规模，脚本负责固定输入动作，
把「翻动导致内存上涨」拆成**逐帧增长**与**按曲目阶梯**两类。结论与数据见
[`docs/vulkan-igpu/08-memory-growth.md`](../../../docs/vulkan-igpu/08-memory-growth.md)。

## 用法

```bash
# 会话基线（同 scroll/README）
sess=~/.local/share/RhineMusicDatabase/rhine.music.database/session.json
cp "$sess" /tmp/session.orig.json
cp tools/perf/scroll/session.baseline.json "$sess"

# 1) 连续翻动 N 轮：CYCLES=10 IDLE=6（结束后自动还原会话）
CYCLES=10 IDLE=6 bash tools/perf/memory/mem.sh mem_baseline

# 2) 每次只按一次 ↓，用来排除"滚动本身"的干扰
STEPS=12 bash tools/perf/memory/step.sh step_baseline

# 3) 完全不动（对照组：应该完全不涨）
N=20 bash tools/perf/memory/idle.sh

# 4) 看图：只看「堆」列，RSS 会被 glibc arena 抬高
grep "内存 rss=" tools/perf/memory/out/mem_baseline.log | sed 's/.*内存 //' | tail -12
```

`step.sh` 支持 `GFX=opengl` 换后端做对照（Vulkan 特有 vs 通用）。`EXTRA_ENV` 可追加任意探针/开关，
例如 `EXTRA_ENV="RHINE_VK_INSTANCE_ARENA=0"` 复现修复前的曲线。

## 判定标准

- **泄漏**：窗口内所有容器计数不变、却在「堆」上单调增长（例如 +3.3 MiB / 20 帧）。
- **缓存阶梯**：只在新增曲目/封面时上台阶，随后平台 → 属正常缓存，看是否封顶。
- **RSS 假象**：glibc 不归还 arena，RSS 会在停止增长后仍保持高位；真泄漏看 `uordblks`。

当前基线（修复后，默认配置）：10 轮翻动 RSS 稳定 ~382 MiB、堆 ~119 MiB 平台，
`标签 16 / 封面 16` 封顶、纹理 63.7 MiB，`材质 20 / 存活 95/13/0` 回稳态。

## 文件

| 文件 | 作用 |
| --- | --- |
| `mem.sh <tag>` | 连续 ↓↑ 循环 `CYCLES` 轮，末尾静止 `IDLE` 秒 |
| `step.sh <tag>` | 每次只按一次 ↓，间隔 2 s，`STEPS` 次 |
| `idle.sh` | 不注入任何输入，外部每 3 s 采一次 `VmRSS`，`N` 次 |

日志与时间线写入 `tools/perf/memory/out/`（`OUT_DIR` 可覆盖）。
