#!/usr/bin/env python3
"""按段汇总探针日志；同组多轮取均值。用法: analyze2.py 'delay0|delay0-r2' 'delay100|delay100-r2'"""
import os, re, sys, statistics as st

LOG_DIR = os.environ.get("RHINE_AB_DIR",
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
SEGS = ["idleA", "seg1", "seg2", "seg3"]
pat_pace = re.compile(r"tick/s=(\d+) sceneUpd/s=(\d+) hudUpd/s=(\d+) render/s=(\d+).*?sleeping=(\d).*?间隔均=([\d.]+)ms 最大=([\d.]+)ms step均=([\d.]+)ms 最大=([\d.]+)ms")
pat_step = re.compile(r"拍成本: 合计 ([\d.]+) ms = app->step ([\d.]+) \+ 其余 ([\d.]+)\s*\|\s*线程CPU ([\d.]+) ms\s*\|\s*等待 ([\d.]+) ms")
pat_3d   = re.compile(r"3D内部: 后处理 ([\d.]+)\s+纹理 ([\d.]+)\s+draw列表 ([\d.]+)\s+构建 ([\d.]+)\s+录制 ([\d.]+)")
pat_tex  = re.compile(r"纹理探针:.*?准入 (\d+)/(\d+)（未准入跳过 (\d+)）\s*\|\s*取消 (\d+)\s*\|\s*在途峰值 (\d+)\s*\|\s*纹理 (\d+) / ([\d.]+) MiB\s*\|\s*标签 (\d+) \(([\d.]+) ms\)\s*\|\s*换绑 ([\d.]+) 帧/最大 (\d+) 样本 (\d+)")
pat_gpu  = re.compile(r"GPU探针: 进入前积压 ([\d.]+) ms\s*\|\s*本帧 GPU ([\d.]+) ms\s*\|\s*3D层 ([\d.]+) ms\s*\|\s*UI层 ([\d.]+) ms")

def load(tag):
    marks, rows = {}, []
    for line in open(os.path.join(LOG_DIR, f"{tag}.timeline")):
        ts, name = line.split(); marks[name] = int(ts)
    for line in open(os.path.join(LOG_DIR, f"{tag}.log"), errors="replace"):
        ts, _, text = line.partition("\t")
        rows.append((int(ts), text.rstrip()))
    return marks, rows

def seg_of(ts, marks):
    for s in SEGS:
        a, b = marks.get(s + "_start"), marks.get(s + "_end")
        if a and b and a <= ts <= b: return s
    return None

def collect(tag):
    marks, rows = load(tag)
    acc = {s: {"pace": [], "step": [], "d3": [], "tex": [], "gpu": []} for s in SEGS}
    for ts, text in rows:
        s = seg_of(ts, marks)
        if not s: continue
        if (m := pat_pace.search(text)): acc[s]["pace"].append(m.groups())
        elif (m := pat_step.search(text)): acc[s]["step"].append(m.groups())
        elif (m := pat_3d.search(text)): acc[s]["d3"].append(m.groups())
        elif (m := pat_tex.search(text)): acc[s]["tex"].append(m.groups())
        elif (m := pat_gpu.search(text)): acc[s]["gpu"].append(m.groups())
    return acc

def mean(v): return sum(v) / len(v) if v else float("nan")

def avg(xs):
    xs = [x for x in xs if x == x]
    return mean(xs) if xs else float("nan")

METRICS = [
    ("内容帧 render/s（唤醒窗口）", lambda a: mean([float(x[3]) for x in a["pace"] if x[4] == "0" and float(x[5]) < 100])),
    ("间隔均 ms（唤醒窗口）", lambda a: mean([float(x[5]) for x in a["pace"] if x[4] == "0" and float(x[5]) < 100])),
    ("间隔最大 ms", lambda a: max([float(x[6]) for x in a["pace"]], default=float("nan"))),
    ("step均 ms", lambda a: mean([float(x[7]) for x in a["pace"]])),
    ("step最大 ms", lambda a: max([float(x[8]) for x in a["pace"]], default=float("nan"))),
    ("拍成本合计 ms", lambda a: mean([float(x[0]) for x in a["step"]])),
    ("app->step ms", lambda a: mean([float(x[1]) for x in a["step"]])),
    ("线程CPU ms", lambda a: mean([float(x[3]) for x in a["step"]])),
    ("等待 ms", lambda a: mean([float(x[4]) for x in a["step"]])),
    ("3D 纹理 ms", lambda a: mean([float(x[1]) for x in a["d3"]])),
    ("3D draw列表 ms", lambda a: mean([float(x[2]) for x in a["d3"]])),
    ("3D 构建 ms", lambda a: mean([float(x[3]) for x in a["d3"]])),
    ("3D 录制 ms", lambda a: mean([float(x[4]) for x in a["d3"]])),
    ("标签生成", lambda a: sum(int(x[7]) for x in a["tex"])),
    ("标签 CPU ms", lambda a: sum(float(x[8]) for x in a["tex"])),
    ("准入成功", lambda a: sum(int(x[0]) for x in a["tex"])),
    ("准入尝试", lambda a: sum(int(x[1]) for x in a["tex"])),
    ("未准入跳过", lambda a: sum(int(x[2]) for x in a["tex"])),
    ("取消", lambda a: sum(int(x[3]) for x in a["tex"])),
    ("在途峰值", lambda a: max([int(x[4]) for x in a["tex"]], default=0)),
    ("纹理创建", lambda a: sum(int(x[5]) for x in a["tex"])),
    ("上传 MiB", lambda a: sum(float(x[6]) for x in a["tex"])),
    ("换绑样本", lambda a: sum(int(x[11]) for x in a["tex"])),
    ("GPU 本帧 ms（均值）", lambda a: mean([float(x[1]) for x in a["gpu"]])),
    ("GPU 本帧 ms（最大）", lambda a: max([float(x[1]) for x in a["gpu"]], default=float("nan"))),
    ("GPU 进入前积压 ms", lambda a: mean([float(x[0]) for x in a["gpu"]])),
    ("GPU 3D层 ms", lambda a: mean([float(x[2]) for x in a["gpu"]])),
    ("GPU UI层 ms", lambda a: mean([float(x[3]) for x in a["gpu"]])),
]

def fmt(v):
    if v != v: return "—"
    return f"{v:.2f}"

def main(groups):
    tags = [g.split("|") for g in groups]
    data = [[collect(t) for t in g] for g in tags]
    for s in SEGS:
        print(f"\n#### {s}")
        print("| 指标 | " + " | ".join(g for g in groups) + " |")
        print("|---|" + "---|" * len(groups))
        for name, fn in METRICS:
            cells = []
            for runs in data:
                vals = [fn(r[s]) for r in runs]
                cells.append(fmt(avg(vals)))
            print(f"| {name} | " + " | ".join(cells) + " |")

if __name__ == "__main__":
    main(sys.argv[1:])
