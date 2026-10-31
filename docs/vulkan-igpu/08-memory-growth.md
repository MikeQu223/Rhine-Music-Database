# 08 常驻内存随翻动上涨：定位与修复

结论先说：**泄漏不在应用侧容器，而在每帧 `updateDynamicBuffer` 的字节被 Vulkan RHI 的暂存逐帧留住**。
非池化路径每帧上传 165 KB，glibc 在用堆就同步长 165 KB/帧；把实例上传改成池化后逐帧增长消失。
修复提交 `426c01f`（默认开池化），观测提交 `61dd993`（内存探针）。

## 症状

翻动列表（↓/↑ 反复）时 `RhineMusicDatabase` 的 RSS 单调上涨，8 轮翻动从 327 MiB 涨到 1.15 GiB 且不收敛；
空闲不动时不动。

## 观测手段

`RHINE_MEMORY_PROBE=1`（每 20 帧一行）：

```text
内存 rss=382.3 MiB 堆=119.3 MiB | 标签 16 封面 16 封面池 12 纹理 63.7 MiB |
材质 20 静态实例 16 批次实例 8 | SRB 23 | 存活 95/13/0 | 曲目 1(封面 4.0 MiB)
```

- `rss` 读 `/proc/self/statm`；`堆` 取 glibc `mallinfo2().uordblks`（真实在用字节，不含碎片与未触达的 mmap）
- 中段是各容器规模：标签/封面纹理数、封面池、纹理总字节、材质表、静态与批次实例 buffer、SRB、
  `resources/sized/transient` 三组存活数；末段是 Engine 侧的曲目缓存条数与封面字节

判定要点：**RSS 会因 glibc 不归还 arena 而虚高，看「堆」才是真实占用**；两者同时单调才算真泄漏。

## 实测（2560×1440、Vulkan、Intel Iris Xe、插帧关）

| 场景 | 结果 |
| --- | --- |
| 基线 8 轮翻动 | RSS 327 MiB → 1.15 GiB，堆 80 → 373 MiB，不收敛 |
| 每次只按一次 ↓（窗口内标签/封面/材质/SRB 全不变） | 堆仍 +3.3 MiB / 20 帧 ≈ **165 KB/帧** |
| 纯空闲（不出帧） | RSS 恒定 |
| OpenGL 后端 | 堆 74.6 → 75.6 MiB，只在新增标签/封面时阶梯 → **Vulkan 特有** |
| 资源账本 `RHINE_VK_RESOURCE_PROBE=1` | 稳态「新建 buffer 0 / SRB 0 / 存量 45 / pipeline 7」，但「更新 3236 次 / 19.86 MB / 120 帧」 |
| `RHINE_VK_INSTANCE_ARENA=1` | 逐帧增长消失，只剩按曲目阶梯 |
| `RHINE_VK_COMPACT_INSTANCES=1` | 仍涨，斜率约基线 1/3（与上传字节成比例） |

关键那条：**19.86 MB ÷ 120 帧 = 165 KB/帧，与每帧堆增长 1:1**。

## 归因

排除了应用侧所有容器（数据见上表：稳态全平）；`dynamicBuffer()` 已经走
`updates->updateDynamicBuffer()` 且做首尾差分与 4 字节对齐，批次在 `cb->resourceUpdate()` 后归零，
own/retire 与 `transient.clear()` 也正常。唯一随帧增长的量就是上传字节，且上传多少堆就长多少 →
问题在 RHI 的 Vulkan 暂存侧（每帧动态 buffer 更新的暂存内存未回收）。OpenGL 没有这条 staging 路径，所以稳定。

## 修复

`426c01f`：实例池化在 Vulkan 后端默认开启（`RHINE_VK_INSTANCE_ARENA=0` 可关；非 Vulkan 后端在
`ensureInstancePool()` 入口自动回退并记 `poolFallback = "非 Vulkan 后端"`）。池化把每帧实例上传从
165 KB 压到接近 0，逐帧增长随之消失——这是回避 staging 问题，不是修了 RHI。

修复后（默认配置、10 轮翻动）：RSS 382.3 MiB 稳定、堆 ~119 MiB 平台，`标签 16 / 封面 16` 封顶、
纹理 63.7 MiB、`材质 20 / 存活 95/13/0` 回稳态。滚动时材质短时冲到 356、存活冲到 767，停稳即回落
（每帧淘汰的瞬时峰值，不是泄漏）。

## 复现与回归判定

```bash
# 1. 备份并注入固定起始会话
cp ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json /tmp/session.orig.json
cp /tmp/session.orig.json tools/perf/scroll/session.baseline.json   # 或用 make_baseline.py 生成的

# 2. 10 轮翻动，观察内存行
CYCLES=10 IDLE=6 bash tools/perf/memory/mem.sh mem_baseline
grep "内存 rss=" tools/perf/memory/out/mem_baseline.log | sed 's/.*内存 //' | tail -12

# 3. 还原
cp /tmp/session.orig.json ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json
```

判定标准：空闲窗口（无输入）堆增长 < 0.5 MiB / 20 帧；10 轮翻动后 RSS 落平台且 `标签/封面` 计数封顶。
若某次改动重新引入大量 `updateDynamicBuffer`（例如关掉池化、或新增每帧重传的 buffer），这条曲线会立刻回来。

## 剩余风险

- **根因仍在 RHI 侧**：任何高频、大批量的 `updateDynamicBuffer` 都可能再次触发同样的逐帧累积，
  例如关闭池化、或把材质 arena 关掉后每帧上传材质。
- 上报 Qt 时可直接用本页数据做最小复现：每帧 `updateDynamicBuffer` + 观察 `uordblks` 线性增长。
- `RHINE_VK_COMPACT_INSTANCES`、`RHINE_VK_DIRECT_WRITE` 等仍是实验开关，只做过编译与离线用例验证，
  没有真机渲染正确性验证。
