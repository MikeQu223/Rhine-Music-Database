#!/usr/bin/env python3
"""比较冻结的原版与 Qt 图像及命中矩形，不使用网络或用户状态。"""

import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image

source = Path(sys.argv[1] if len(sys.argv) > 1 else "output/visual-reference")
target = Path(sys.argv[2] if len(sys.argv) > 2 else "output/visual-qt")
results = []
for descriptor in sorted(source.glob("*.json")):
    fixture = json.loads(descriptor.read_text(encoding="utf-8"))
    name = fixture["name"]
    folder = target / name
    row = {"name": name}
    for layer in ["metal", "panel"]:
        a = np.asarray(
            Image.open(source / f"{name}-{layer}.png").convert("RGBA")
        ).astype(np.int16)
        b = np.asarray(Image.open(folder / f"qt-{layer}.png").convert("RGBA")).astype(
            np.int16
        )
        difference = np.abs(a - b)
        changed = np.any(difference > 0, axis=2)
        row[layer] = {
            "max_channel_difference": int(difference.max()),
            "mean_channel_difference": float(difference.mean()),
            "changed_pixels": int(changed.sum()),
            "pixel_count": int(changed.size),
        }
        if changed.any():
            heat = np.zeros_like(a, dtype=np.uint8)
            heat[:, :, :3] = np.minimum(255, difference[:, :, :3] * 8).astype(np.uint8)
            heat[:, :, 3] = 255
            Image.fromarray(heat).save(folder / f"{layer}-difference.png")
    keys = ["x", "y", "width", "height", "action"]
    actual = json.loads((folder / "qt-hits.json").read_text(encoding="utf-8"))
    expected = fixture["hits"]
    row["hits_equal"] = [{k: v[k] for k in keys} for v in actual] == expected
    if not row["hits_equal"]:
        row["hit_mismatches"] = [
            {"expected": a, "actual": b}
            for a, b in zip(expected, actual)
            if a != {k: b[k] for k in keys}
        ]
        row["hit_counts"] = [len(expected), len(actual)]
    results.append(row)
Path(
    sys.argv[3] if len(sys.argv) > 3 else "output/qt-visual-comparison.json"
).write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
for row in results:
    print(
        row["name"],
        "metal:",
        row["metal"]["max_channel_difference"],
        row["metal"]["changed_pixels"],
        "panel:",
        row["panel"]["max_channel_difference"],
        row["panel"]["changed_pixels"],
        "hits:",
        row["hits_equal"],
    )
