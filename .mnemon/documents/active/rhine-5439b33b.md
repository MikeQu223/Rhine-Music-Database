---
id: "5439b33b-ea81-40a9-83ef-d4ada4b0a250"
title: "Rhine 帧率测量脚手架（重启后可从本文档恢复）"
description: "Vulkan/OpenGL 帧率 A/B 测量的完整脚本集：全屏启动、uinput 按键注入、时间戳日志、区间帧率解析。原本在 /tmp/mb/，/tmp 会被重启清空，故在此存档；恢复命令见文末。"
status: "active"
created_at: "2026-10-28T15:59:27.152Z"
updated_at: "2026-10-28T15:59:27.152Z"
content_hash: "79763aee79d6a01821d3b7b3219ee760298458cb3215a49c3d066ceb82a7c543"
source_paths:
  []
session_ids:
  - "session-f293f616-6715-40d7-a765-8caf9100e12e"
memory_body_ids:
  []
---

# Rhine 帧率测量脚手架

原本位于 `/tmp/mb/`。`/tmp` 重启即清空，故存档于此。恢复：

```bash
mkdir -p /tmp/mb && cd /tmp/mb
# 从本文档复制下文各段到对应文件名，然后：
chmod +x bench2.sh press.py holdkey.py ts.py analyze2.py
```

依赖：`niri`（Wayland 合成器，`niri msg`）、`grim`（截图）、`/dev/uinput` 可写、python3。
被测二进制：`<repo>/output/qt-build/RhineMusicDatabase`，资源 `RHINE_RESOURCES=<repo>/output/resources`。

## 关键前提

- 程序按**相对路径**找播放服务，必须 `cd <repo>` 后用 `./output/qt-build/RhineMusicDatabase` 启动，不能从别处起。
- `pkill -f "qt-build/RhineMusicDataba[s]"` 的模式里若与同一命令行中的裸路径同名，会把自己也杀掉；脚本文件内调用才安全（**不要把 pkill 和裸名写在同一条 bash -c 里，heredoc 也算**）。
- 用户设置只改 `gpu-index` 一行（0=RTX 3050 Mobile，1=Intel Iris Xe，原值 1），绝不整份覆盖配置文件。
- 收尾必须还原会话：`cp session.orig.json ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json`（原 sha256 `d2803b41…`）。

## ts.py

```python
#!/usr/bin/env python3
"""给每一行日志打上精确时间戳（秒，相对启动），供测速解析。"""
import sys
import time

start = time.monotonic()
out = sys.stdout
for line in sys.stdin:
    out.write("%.3f\t%s" % (time.monotonic() - start, line))
    out.flush()
```

## holdkey.py

```python
#!/usr/bin/env python3
"""按住某个键 hold 秒（uinput 虚拟键盘，走真实输入路径）。
KEY_DOWN=108。按下后保持 hold 秒再松开；内核自动重复会让合成器产生连续按键。
"""
import ctypes
import fcntl
import os
import struct
import sys
import time

UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565

EV_SYN, EV_KEY = 0, 1
SYN_REPORT = 0


class E(ctypes.Structure):
    _fields_ = [("s", ctypes.c_long), ("u", ctypes.c_long),
                ("t", ctypes.c_uint16), ("c", ctypes.c_uint16), ("v", ctypes.c_int32)]


def write_event(fd, etype, code, value):
    os.write(fd, bytes(E(0, 0, etype, code, value)))


def create_keyboard(name=b"mb-kbd"):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_KEYBIT, 108)  # KEY_DOWN
    buf = name + b"\0" * (80 - len(name))
    buf += struct.pack("HHHH", 3, 0x1234, 0x5678, 1) + struct.pack("I", 0)
    for arr in ([0] * 64, [0] * 64, [0] * 64, [0] * 64):
        buf += struct.pack("64i", *arr)
    os.write(fd, buf)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.7)
    return fd


def main():
    hold = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    keycode = int(sys.argv[2]) if len(sys.argv) > 2 else 108
    fd = create_keyboard()
    try:
        print(f"press keycode={keycode}", flush=True)
        write_event(fd, EV_KEY, keycode, 1)
        write_event(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(hold)
        write_event(fd, EV_KEY, keycode, 0)
        write_event(fd, EV_SYN, SYN_REPORT, 0)
        print(f"release after {hold}s", flush=True)
        time.sleep(0.5)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == "__main__":
    main()
```

## press.py

```python
#!/usr/bin/env python3
"""依次单击若干按键（uinput 虚拟键盘）。用法: press.py <keycode> [keycode ...]
KEY_ESC=1  KEY_F11=87  KEY_DOWN=108
"""
import ctypes
import fcntl
import os
import struct
import sys
import time

UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
EV_SYN, EV_KEY = 0, 1
SYN_REPORT = 0
MAXKEY = 256


class Event(ctypes.Structure):
    _fields_ = [("s", ctypes.c_long), ("u", ctypes.c_long),
                ("t", ctypes.c_uint16), ("c", ctypes.c_uint16), ("v", ctypes.c_int32)]


def emit(fd, etype, code, value):
    os.write(fd, bytes(Event(0, 0, etype, code, value)))


def create(name=b"mb-kbd2"):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for code in range(1, MAXKEY):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    buf = name + b"\0" * (80 - len(name))
    buf += struct.pack("HHHH", 3, 0x1234, 0x5679, 1) + struct.pack("I", 0)
    for _ in range(4):
        buf += struct.pack("64i", *([0] * 64))
    os.write(fd, buf)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.7)
    return fd


def main():
    codes = [int(c) for c in sys.argv[1:]] or [1]
    fd = create()
    try:
        for code in codes:
            emit(fd, EV_KEY, code, 1)
            emit(fd, EV_SYN, SYN_REPORT, 0)
            time.sleep(0.08)
            emit(fd, EV_KEY, code, 0)
            emit(fd, EV_SYN, SYN_REPORT, 0)
            print(f"tap {code}", flush=True)
            time.sleep(0.9)
        time.sleep(0.4)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == "__main__":
    main()
```

## bench2.sh

```bash
#!/bin/bash
# bench2.sh <backend> <fg> <tag> [hold_seconds]
# 全屏 2560x1440 主界面列表页（收藏专辑），长按 ↓ 取平均帧数
# EXTRA_ENV="X=1 Y=2" 可追加环境变量（探针用）
set -u
backend=$1; fg=$2; tag=$3; hold=${4:-20}
repo=/home/aibeto/code/Rhine-Music-Database
sess=~/.local/share/RhineMusicDatabase/rhine.music.database/session.json
out=/tmp/mb
log=$out/$tag.log

pkill -f "output/qt-build/RhineMusicDataba[s]" 2>/dev/null
sleep 2
cp $out/session.baseline.json "$sess"

cd "$repo" || exit 1
env QT_ASSUME_STDERR_HAS_CONSOLE=1 \
    RHINE_GRAPHICS="$backend" \
    RHINE_FG="$fg" \
    RHINE_FG_DIAG=1 \
    RHINE_PACE_DIAG=1 \
    RHINE_KEY_PROBE=1 \
    RHINE_RESOURCES="$repo/output/resources" ${EXTRA_ENV:-} \
    ./output/qt-build/RhineMusicDatabase 2>&1 | python3 -u $out/ts.py >"$log" 2>/dev/null &
pipepid=$!

for _ in $(seq 1 160); do grep -q "节拍诊断" "$log" 2>/dev/null && break; sleep 0.5; done
sleep 5

apid=$(pgrep -f "output/qt-build/RhineMusicDataba[s]" | head -1)
[ -z "${apid:-}" ] && { echo "FATAL $tag: 进程未起来"; exit 1; }
wid=$(niri msg windows 2>/dev/null | awk -v p="$apid" '/^Window ID /{id=$3;sub(":","",id)} /PID: /{if($2==p){print id;exit}}')
[ -z "${wid:-}" ] && { echo "FATAL $tag: 无窗口"; pkill -f "output/qt-build/RhineMusicDataba[s]"; exit 1; }

niri msg action focus-window --id "$wid" >/dev/null 2>&1
sleep 1

# ESC 关掉启动时的设置弹窗回主界面 → 右方向键切到「收藏专辑」→ F11 全屏
python3 $out/press.py 1 106 87 >/dev/null 2>&1
sleep 2

start_ms=$(date +%s%3N)
python3 $out/holdkey.py "$hold" 108 >/dev/null 2>&1
end_ms=$(date +%s%3N)
sleep 1
grim -o DP-1 "$out/$tag.png" 2>/dev/null
kp=$(grep -c "按键到达输入层" "$log" 2>/dev/null || echo 0)
pkill -f "output/qt-build/RhineMusicDataba[s]" 2>/dev/null
sleep 1
kill $pipepid 2>/dev/null

dur=$(python3 -c "print(f'{($end_ms-$start_ms)/1000:.1f}')")
printf '%s\tbackend=%s\tfg=%s\thold=%ss\tkeys=%s\n' "$tag" "$backend" "$fg" "$dur" "$kp"
```

多轮矩阵（交错执行，减少漂移）：

```bash
for r in 1 2 3; do
  for cfg in "vulkan off" "vulkan on" "opengl off"; do
    set -- $cfg
    /tmp/mb/bench2.sh "$1" "$2" "m${r}_$1_$2" 20
  done
done
```

## analyze2.py

```python
#!/usr/bin/env python3
"""解析全屏运行的日志：按住 ↓ 区间内的平均帧率。
Vulkan：FG diag 的 presented/rendered 累计计数 → 帧率
OpenGL：无呈现层，用 节拍诊断 的 render/s 逐秒累加 → 帧率
"""
import glob
import re
import statistics
import sys

KP = re.compile(r"按键到达输入层: 键 (\d+) 接受")
FG = re.compile(r"FG diag: presented (\d+) rendered (\d+) skipped (\d+).*?gapP50 ([\d.]+)"
                r".*?\| 3D层 ([\d.]+) ms")
PACE = re.compile(r"节拍诊断: tick/s=(\d+) sceneUpd/s=(\d+) hudUpd/s=(\d+) render/s=(\d+).*?"
                  r"间隔均=([\d.]+)ms 最大=([\d.]+)ms")

DOWN = 16777237


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

    fg = [(t, *[float(g) for g in m.groups()])
          for t, x in r for m in [FG.search(x)] if m and k0 <= t <= k1]
    pace = [(t, *(float(g) for g in m.groups()))
            for t, x in r for m in [PACE.search(x)] if m and k0 <= t <= k1]

    res = {"path": path, "window": k1 - k0, "keys": len(down),
           "key_rate": len(down) / (k1 - k0), "backend": "vulkan" if fg else "opengl"}

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
    print(f"{'tag':<18}{'backend':<9}{'presented/s':>12}{'rendered/s':>12}"
          f"{'interp/s':>10}{'tick/s':>8}{'gapP50':>8}{'键/s':>7}{'窗口s':>8}")
    print("-" * 92)
    for x in rs:
        tag = x["path"].split("/")[-1].replace(".log", "")
        if "error" in x:
            print(f"{tag:<18}ERROR {x['error']}")
            continue
        print(f"{tag:<18}{x['backend']:<9}{x.get('presented', 0):>12.1f}"
              f"{x.get('rendered', 0):>12.1f}{x.get('interp', 0):>10.1f}"
              f"{x.get('tick', 0):>8.1f}{x.get('gap_p50', 0):>8.1f}"
              f"{x['key_rate']:>7.1f}{x['window']:>8.2f}")

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
        print(f"  {backend:<8} FG={fgflag:<4} n={len(p)}  "
              f"presented {statistics.mean(p):6.1f} ± {sd:4.1f}   "
              f"rendered {statistics.mean(rd):6.1f} ± {rds:4.1f}   "
              f"[{', '.join(f'{v:.1f}' for v in p)}]")


if __name__ == "__main__":
    main(sys.argv[1:] or sorted(glob.glob("/tmp/mb/m*_vulkan_*.log") + glob.glob("/tmp/mb/m*_opengl_*.log")))
```

## 会话基线（固定起始状态）

`session.baseline.json` 由 `~/.local/share/RhineMusicDatabase/rhine.music.database/session.json`
的原始备份加工：`view.modal='settings'`（保证按 ESC 能回到主界面）、各 offset 归零、
`library.directories=[]`。每轮注入以消除状态漂移。

**注意**：程序退出（SIGTERM）会回写 session.json，所以每轮必须重新注入。

## 踩过的坑

- `settingsScroll` 注入后设置页滚动位失效（页面停在 FSR SHARPNESS，滚不到「帧生成」行），
  方向键滚动是每次 50px 且方向与直觉相反（Up 往顶部）。
- `RHINE_GPU_PROBE` 只在 `PresentationShell::renderFrame()` 里采样；fg=off 改走 Qt 默认路径后
  该探针完全不生效。
- 构建不要用 `./build.sh`（它总附带 AppImage 打包，反复构建会把磁盘塞满）；
  日常验证用 `cmake --build output/qt-build --target RhineMusicDatabase -j8`。
