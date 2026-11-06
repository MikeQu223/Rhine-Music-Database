#!/usr/bin/env python3
"""解析 bench2.sh 产出的日志：按住 ↓ 区间内的平均帧率。

Vulkan：FG diag 的 presented/rendered 累计计数 → 帧率（上屏 / 真实渲染 / 插值）
OpenGL：没有呈现层，用 节拍诊断 的 render/s 逐秒累加 → 帧率

口径提醒：`render/s`（= Engine::m_renderFrames）是**内容帧**，即画面内容真正更新的次数，
才是用户感知的流畅度；presented 在上屏侧，fg=off 时含约 1.86 倍的同帧重复上屏，
拿它当帧率会高估 Vulkan。

用法: analyze2.py <log...>   （不带参数则扫 $BENCH_OUT 或 /tmp/mb 下的 m*_*.log）
"""

import glob
import os
import re
import statistics
import sys

KP = re.compile(r"按键到达输入层: 键 (\d+) 接受")
FG = re.compile(
    r"FG diag: presented (\d+) rendered (\d+) skipped (\d+).*?gapP50 ([\d.]+)"
    r".*?\| 3D层 ([\d.]+) ms"
)
PACE = re.compile(
    r"节拍诊断: tick/s=(\d+) sceneUpd/s=(\d+) hudUpd/s=(\d+) render/s=(\d+).*?"
    r"间隔均=([\d.]+)ms 最大=([\d.]+)ms"
)

DOWN = 16777237  # Qt::Key_Down


def rows(path):
    out = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        if "\t" not in raw:
            continue
        ts, txt = raw.split("\t", 1)
        try:
            out.append((float(ts), txt.rstrip()))
        except ValueError:
            pass
    return out


def analyze(path):
    r = rows(path)
    if not r:
        return None
    probes = [(t, int(m.group(1))) for t, x in r for m in [KP.search(x)] if m]
    down = [t for t, c in probes if c == DOWN]
    if len(down) < 5:
        return {"path": path, "error": f"↓ 键事件太少 ({len(down)})"}
    k0, k1 = down[0], down[-1]

    fg = [
        (t, *[float(g) for g in m.groups()])
        for t, x in r
        for m in [FG.search(x)]
        if m and k0 <= t <= k1
    ]
    pace = [
        (t, *(float(g) for g in m.groups()))
        for t, x in r
        for m in [PACE.search(x)]
        if m and k0 <= t <= k1
    ]

    res = {
        "path": path,
        "window": k1 - k0,
        "keys": len(down),
        "key_rate": len(down) / (k1 - k0),
        "backend": "vulkan" if fg else "opengl",
    }

    if len(fg) >= 3:
        span = fg[-1][0] - fg[0][0]
        res["presented"] = (fg[-1][1] - fg[0][1]) / span
        res["rendered"] = (fg[-1][2] - fg[0][2]) / span
        res["interp"] = res["presented"] - res["rendered"]
        res["gap_p50"] = statistics.median([x[4] for x in fg])
        res["layer3d"] = statistics.median([x[5] for x in fg])
        res["samples"] = len(fg)
    if len(pace) >= 3:
        span = pace[-1][0] - pace[0][0]
        res["engine_render"] = sum(p[4] for p in pace[1:]) / span
        res["gap_mean"] = statistics.median([x[5] for x in pace])
        res["tick"] = sum(p[1] for p in pace[1:]) / span
        if "presented" not in res:
            res["presented"] = res["engine_render"]
            res["rendered"] = res["engine_render"]
            res["interp"] = 0.0
            res["samples"] = len(pace) - 1
    return res


def main(paths):
    rs = [x for x in (analyze(p) for p in paths) if x]
    print(
        f"{'tag':<18}{'backend':<9}{'presented/s':>12}{'rendered/s':>12}"
        f"{'interp/s':>10}{'tick/s':>8}{'gapP50':>8}{'键/s':>7}{'窗口s':>8}"
    )
    print("-" * 92)
    for x in rs:
        tag = os.path.basename(x["path"]).replace(".log", "")
        if "error" in x:
            print(f"{tag:<18}ERROR {x['error']}")
            continue
        print(
            f"{tag:<18}{x['backend']:<9}{x.get('presented', 0):>12.1f}"
            f"{x.get('rendered', 0):>12.1f}{x.get('interp', 0):>10.1f}"
            f"{x.get('tick', 0):>8.1f}{x.get('gap_p50', 0):>8.1f}"
            f"{x['key_rate']:>7.1f}{x['window']:>8.2f}"
        )

    groups = {}
    for x in rs:
        if "error" in x or "presented" not in x:
            continue
        fgflag = "on" if x.get("interp", 0) > 1 else "off"
        key = (x["backend"], fgflag if x["backend"] == "vulkan" else "n/a")
        groups.setdefault(key, []).append(x)

    print("\n聚合（按住区间平均帧率）:")
    for (backend, fgflag), xs in sorted(groups.items()):
        p = [x["presented"] for x in xs]
        rd = [x["rendered"] for x in xs]
        sd = statistics.stdev(p) if len(p) > 1 else 0.0
        rds = statistics.stdev(rd) if len(rd) > 1 else 0.0
        print(
            f"  {backend:<8} FG={fgflag:<4} n={len(p)}  "
            f"presented {statistics.mean(p):6.1f} ± {sd:4.1f}   "
            f"rendered {statistics.mean(rd):6.1f} ± {rds:4.1f}   "
            f"[{', '.join(f'{v:.1f}' for v in p)}]"
        )


if __name__ == "__main__":
    default_out = os.environ.get("BENCH_OUT", "/tmp/mb")
    main(
        sys.argv[1:]
        or sorted(
            glob.glob(os.path.join(default_out, "m*_vulkan_*.log"))
            + glob.glob(os.path.join(default_out, "m*_opengl_*.log"))
        )
    )
