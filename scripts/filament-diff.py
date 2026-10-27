#!/usr/bin/env python3
"""Filament 渲染保真度测量：跑开启/关闭两轮确定性抓图并输出分区指标。

用法：python3 scripts/filament-diff.py [输出目录]
依赖：output/qt-build/RhineMusicDatabase 已构建；xvfb-run 可用。
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "output", "qt-build", "RhineMusicDatabase")
STEPS = "600"


def capture(target, filament):
    os.makedirs(target, exist_ok=True)
    env = dict(os.environ)
    env["RHINE_CAPTURE_STEPS"] = STEPS
    if filament:
        env["RHINE_FILAMENT"] = "1"
    else:
        env.pop("RHINE_FILAMENT", None)
    command = ["xvfb-run", "-a", APP, "--capture", target, "archive"]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise SystemExit(f"抓图失败（filament={filament}）：{result.returncode}")
    return os.path.join(target, "qt-window.png")


def metrics(a, b, label):
    diff = ImageChops.difference(a, b)
    hist = diff.convert("L").histogram()
    total = a.size[0] * a.size[1]
    changed = sum(hist[1:])
    A = np.array(a.convert("RGB")).astype(np.float64)
    B = np.array(b.convert("RGB")).astype(np.float64)
    mse = ((A - B) ** 2).mean()
    psnr = 10 * np.log10(255.0**2 / mse) if mse > 0 else float("inf")
    return {
        "region": label,
        "changedPixels": changed,
        "changedPercent": round(100.0 * changed / total, 3),
        "psnr": round(psnr, 2),
        "meanLegacy": round(float(A.mean()), 1),
        "meanFilament": round(float(B.mean()), 1),
    }


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "output", "filament-diff")
    off = capture(os.path.join(out, "off"), False)
    on = capture(os.path.join(out, "on"), True)
    legacy = Image.open(off)
    filament = Image.open(on)
    rows = [metrics(legacy, filament, "full")]
    width, height = legacy.size
    # 3x3 分区，便于定位差异集中区域。
    for row in range(3):
        for column in range(3):
            box = (
                width * column // 3,
                height * row // 3,
                width * (column + 1) // 3,
                height * (row + 1) // 3,
            )
            rows.append(
                metrics(
                    legacy.crop(box), filament.crop(box), f"cell_r{row}c{column}"
                )
            )
    heat = ImageChops.difference(legacy.convert("RGB"), filament.convert("RGB"))
    heat.save(os.path.join(out, "diff-heatmap.png"))
    report = {"steps": STEPS, "rows": rows}
    with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
    for item in rows:
        print(
            "%-14s 差异 %6.3f%%  PSNR %6.2f dB  亮度 %.1f vs %.1f"
            % (
                item["region"],
                item["changedPercent"],
                item["psnr"],
                item["meanLegacy"],
                item["meanFilament"],
            )
        )
    print(f"报告：{os.path.join(out, 'report.json')}")


if __name__ == "__main__":
    main()
