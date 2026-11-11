#!/usr/bin/env python3
"""生成 benchmark 用的固定起始会话状态。

为什么需要：程序退出（含 SIGTERM/pkill）会把当前状态回写 session.json，
不固定起始状态的话，每轮的页面、滚动位、选中项都会漂移，帧率就不可比。

做法：以用户原始 session.json 为底，只改三处——
  · view.modal = "settings"  （保证启动后按一次 ESC 就能回到主界面；也保证每次都走同一条路径）
  · 各 offset / settingsScroll 归零（消除滚动位置带来的差异）
  · library.directories = []  （本地音乐目录清空，"我的音乐"页保持空态）

用法:
    make_baseline.py [原始 session.json 路径] [输出路径]
默认读 ~/.local/share/RhineMusicDatabase/rhine.music.database/session.json，
默认写 $BENCH_OUT/session.baseline.json（BENCH_OUT 默认 /tmp/mb）。

**先备份原始文件**，测完要还原（这个脚本不改原文件，但基准测试期间程序会覆盖它）。
"""

import json
import os
import sys

DEFAULT_SESSION = os.path.expanduser(
    "~/.local/share/RhineMusicDatabase/rhine.music.database/session.json"
)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SESSION
    out_dir = os.environ.get("BENCH_OUT", "/tmp/mb")
    dst = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(out_dir, "session.baseline.json")
    )

    with open(src, encoding="utf-8") as handle:
        data = json.load(handle)

    view = data.setdefault("view", {})
    view["modal"] = "settings"
    view["settingsScroll"] = 0.0
    for key in ("listOffset", "trackOffset", "bodyOffset", "queueOffset"):
        if key in view:
            view[key] = 0

    library = data.setdefault("library", {})
    library["directories"] = []
    library["directoryInfo"] = False

    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
    print(f"baseline 写入 {dst}")


if __name__ == "__main__":
    main()
