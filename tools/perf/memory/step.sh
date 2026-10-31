#!/bin/bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=${OUT_DIR:-$here/out}
mkdir -p "$dir"
repo=$(cd "$here/../.." && pwd)
sess=${RHINE_SESSION:-${XDG_DATA_HOME:-$HOME/.local/share}/RhineMusicDatabase/rhine.music.database/session.json}
baseline=${RHINE_SESSION_BASELINE:-$repo/tools/perf/scroll/session.baseline.json}
bin="$repo/output/qt-build/$(printf 'RhineMusic%s' Database)"
pkill -f "$bin" 2>/dev/null
sleep 2
[ -f "$dir/session.orig.json" ] || cp "$sess" "$dir/session.orig.json" 2>/dev/null
cp "$baseline" "$sess"
cd "$repo" || exit 1
env QT_ASSUME_STDERR_HAS_CONSOLE=1 RHINE_GRAPHICS=${GFX:-vulkan} RHINE_FG=off RHINE_MEMORY_PROBE=1 \
  RHINE_RESOURCES="$repo/output/resources" "$bin" 2>&1 | python3 -u "$here/stamp.py" > "$dir/$1.log" 2>/dev/null &
sleep 10
apid=$(pgrep -f "$bin" | head -1)
wid=$(niri msg windows 2>/dev/null | awk -v p="$apid" '/^Window ID /{id=$3;sub(":","",id)} /PID: /{if($2==p){print id;exit}}')
[ -n "${wid:-}" ] && niri msg action focus-window --id "$wid" >/dev/null 2>&1
sleep 1
python3 "$repo/tools/perf/press.py" 1 106 87 >/dev/null 2>&1
sleep 3
echo "$(date +%s%3N) warm" >> "$dir/$1.timeline"
for i in $(seq 1 "${STEPS:-10}"); do
  python3 "$repo/tools/perf/press.py" 1 108 >/dev/null 2>&1
  echo "$(date +%s%3N) step$i" >> "$dir/$1.timeline"
  sleep 2
done
sleep 6
pkill -f "$bin"
sleep 1
cp "$dir/session.orig.json" "$sess" 2>/dev/null
echo DONE
