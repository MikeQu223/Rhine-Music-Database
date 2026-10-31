#!/bin/bash
set -u
delay=$1
here=$(cd "$(dirname "$0")" && pwd)
dir=${OUT_DIR:-$here/out}
mkdir -p "$dir"
repo=$(cd "$here/../.." && pwd)
tag=delay$delay${2:+-$2}
log=$dir/$tag.log
tl=$dir/$tag.timeline
sess=${RHINE_SESSION:-${XDG_DATA_HOME:-$HOME/.local/share}/RhineMusicDatabase/rhine.music.database/session.json}
baseline=${RHINE_SESSION_BASELINE:-$repo/tools/perf/scroll/session.baseline.json}

pkill -f "qt-build/RhineMusicDataba[s]" 2>/dev/null
sleep 2
[ -f "$dir/session.orig.json" ] || cp "$sess" "$dir/session.orig.json" 2>/dev/null
cp "$baseline" "$sess"
: > "$tl"
: > "$log"

cd "$repo" || exit 1
env QT_ASSUME_STDERR_HAS_CONSOLE=1 \
  RHINE_GRAPHICS=vulkan RHINE_FG=off RHINE_FG_DIAG=1 \
  RHINE_TEXTURE_PROBE=1 RHINE_STEP_PROBE=1 RHINE_PACE_DIAG=1 \
  RHINE_TEXTURE_ADMISSION_MS="$delay" \
  RHINE_RESOURCES="$repo/output/resources" ${EXTRA_ENV:-} \
  ./output/qt-build/RhineMusicDatabase 2>&1 | python3 -u "$here/stamp.py" > "$log" 2>/dev/null &
pipepid=$!
mark(){ echo "$(date +%s%3N) $1" >> "$tl"; }

for _ in $(seq 1 200); do grep -q "拍成本" "$log" 2>/dev/null && break; sleep 0.5; done
if ! grep -q "拍成本" "$log" 2>/dev/null; then echo "FATAL $tag: 未打印拍成本"; pkill -f "qt-build/RhineMusicDataba[s]"; exit 1; fi
sleep "${WARMUP:-5}"

apid=$(pgrep -f "qt-build/RhineMusicDataba[s]" | head -1)
wid=$(niri msg windows 2>/dev/null | awk -v p="$apid" '/^Window ID /{id=$3;sub(":","",id)} /PID: /{if($2==p){print id;exit}}')
if [ -n "${wid:-}" ]; then niri msg action focus-window --id "$wid" >/dev/null 2>&1; fi
sleep 1
python3 "$repo/tools/perf/press.py" 1 106 87 >/dev/null 2>&1
sleep 4

mark idleA_start
sleep 2
mark idleA_end
mark seg1_start
python3 "$here/holdkey2.py" 6 108 >/dev/null 2>&1
mark seg1_end
sleep 1
mark seg2_start
python3 "$here/holdkey2.py" 6 103 >/dev/null 2>&1
mark seg2_end
mark seg3_start
sleep 8
mark seg3_end
sleep 1
grim -o DP-1 "$dir/$tag.png" >/dev/null 2>&1
pkill -f "qt-build/RhineMusicDataba[s]"
sleep 1
echo "DONE $tag lines=$(wc -l < "$log")"
