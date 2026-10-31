#!/bin/bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=${OUT_DIR:-$here/out}
mkdir -p "$dir"
repo=$(cd "$here/../.." && pwd)
sess=${RHINE_SESSION:-${XDG_DATA_HOME:-$HOME/.local/share}/RhineMusicDatabase/rhine.music.database/session.json}
baseline=${RHINE_SESSION_BASELINE:-$repo/tools/perf/scroll/session.baseline.json}
pkill -f "qt-build/RhineMusicData""base" 2>/dev/null; sleep 2
[ -f "$dir/session.orig.json" ] || cp "$sess" "$dir/session.orig.json" 2>/dev/null
cp "$baseline" "$sess"
cd "$repo" || exit 1
env QT_ASSUME_STDERR_HAS_CONSOLE=1 RHINE_GRAPHICS=vulkan RHINE_FG=off RHINE_MEMORY_PROBE=1 \
  RHINE_RESOURCES="$repo/output/resources" ./output/qt-build/RhineMusicDatabase > "$dir/idle.log" 2>&1 &
sleep 12
apid=$(pgrep -f "qt-build/RhineMusicData""base" | head -1)
echo "pid=$apid"
for i in $(seq 1 "${N:-20}"); do
  rss=$(awk '/VmRSS/{print $2}' /proc/$apid/status 2>/dev/null)
  echo "$(date +%s) ${rss:-0} kB"
  sleep 3
done
pkill -f "qt-build/RhineMusicData""base"; sleep 1
cp "$dir/session.orig.json" "$sess" 2>/dev/null
