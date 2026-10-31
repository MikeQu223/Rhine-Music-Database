#!/bin/bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=${OUT_DIR:-$here/out}
mkdir -p "$dir"
repo=$(cd "$here/../.." && pwd)
tag=${1:-mem}
log=$dir/$tag.log
sess=${RHINE_SESSION:-${XDG_DATA_HOME:-$HOME/.local/share}/RhineMusicDatabase/rhine.music.database/session.json}
baseline=${RHINE_SESSION_BASELINE:-$repo/tools/perf/scroll/session.baseline.json}

pkill -f "qt-build/RhineMusicDataba[s]" 2>/dev/null
sleep 2
[ -f "$dir/session.orig.json" ] || cp "$sess" "$dir/session.orig.json" 2>/dev/null
cp "$baseline" "$sess"
: > "$log"

cd "$repo" || exit 1
env QT_ASSUME_STDERR_HAS_CONSOLE=1 \
  RHINE_GRAPHICS=vulkan RHINE_FG=off RHINE_FG_DIAG=1 \
  RHINE_MEMORY_PROBE=1 RHINE_TEXTURE_PROBE=1 \
  RHINE_RESOURCES="$repo/output/resources" ${EXTRA_ENV:-} \
  ./output/qt-build/RhineMusicDatabase 2>&1 | python3 -u "$here/stamp.py" > "$log" 2>/dev/null &
for _ in $(seq 1 200); do grep -q "内存 rss=" "$log" 2>/dev/null && break; sleep 0.5; done
if ! grep -q "内存 rss=" "$log" 2>/dev/null; then echo "FATAL $tag"; pkill -f "qt-build/RhineMusicDataba[s]"; exit 1; fi
sleep "${WARMUP:-5}"
apid=$(pgrep -f "qt-build/RhineMusicDataba[s]" | head -1)
wid=$(niri msg windows 2>/dev/null | awk -v p="$apid" '/^Window ID /{id=$3;sub(":","",id)} /PID: /{if($2==p){print id;exit}}')
[ -n "${wid:-}" ] && niri msg action focus-window --id "$wid" >/dev/null 2>&1
sleep 1
python3 "$repo/tools/perf/press.py" 1 106 87 >/dev/null 2>&1
sleep 3
echo "$(date +%s%3N) warm_done" >> "$dir/$tag.timeline"
for i in $(seq 1 "${CYCLES:-10}"); do
  python3 "$here/holdkey2.py" 2 108 >/dev/null 2>&1
  python3 "$here/holdkey2.py" 2 103 >/dev/null 2>&1
  echo "$(date +%s%3N) cycle$i" >> "$dir/$tag.timeline"
done
sleep "${IDLE:-10}"
pkill -f "qt-build/RhineMusicDataba[s]"
sleep 1
cp "$dir/session.orig.json" "$sess" 2>/dev/null
echo "DONE $tag lines=$(wc -l < "$log")"
