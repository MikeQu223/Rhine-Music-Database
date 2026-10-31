#!/bin/bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=${OUT_DIR:-$here/out}
mkdir -p "$dir"
for d in 0 100; do
  node "$DSH_PROGRESS_CLI" emit --task scrollab --pct 10 --msg "运行 delay=$d（三段滚动）" >/dev/null 2>&1 || true
  bash "$dir/run.sh" "$d" || echo "RUN_FAIL $d"
  node "$DSH_PROGRESS_CLI" emit --task scrollab --pct 55 --msg "delay=$d 完成" >/dev/null 2>&1 || true
done
cp "$dir/session.orig.json" "$sess" 2>/dev/null
node "$DSH_PROGRESS_CLI" emit --task scrollab --pct 95 --msg "会话已还原，准备分析" >/dev/null 2>&1 || true
echo ALLDONE
