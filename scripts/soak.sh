#!/bin/bash
#
# Long-running stability check on the DELIVERED release build.
#
# The SRS asks for a 24 hour soak test; this script makes that a one-liner:
#   SOAK_SECONDS=86400 INTERVAL=60 scripts/soak.sh
#
# Keep-alive is enabled through NSUserDefaults' argument domain (never persisted),
# so the user's real preferences are untouched. While the keep-alive is running
# macOS holds an audio power assertion for the process (same as any audio player),
# so the machine will not idle-sleep during the soak. That is expected and
# documented in docs/SECURITY.md.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/Soramimi.app/Contents/MacOS/Soramimi"
SOAK_SECONDS="${SOAK_SECONDS:-1800}"
INTERVAL="${INTERVAL:-60}"
LEVEL="${LEVEL:--100}"
OUT="$ROOT/build/soak.csv"
LOG="$ROOT/build/soak.log"
mkdir -p "$ROOT/build"

[[ -x "$BIN" ]] || { echo "Build first: scripts/build.sh" >&2; exit 1; }

echo "==> soak: ${SOAK_SECONDS}s on the release build, sampling every ${INTERVAL}s, level ${LEVEL} dBFS"
: > "$OUT"
: > "$LOG"
printf 'elapsed_s,rss_kb,phys_footprint_mb,cpu_percent,threads,network_sockets\n' > "$OUT"


# Kill only processes whose command line starts with the given executable path.
# (A blanket `pkill -f <path>` can match unrelated shells whose command line merely
# contains the path, which is how a reviewer's test shell got killed once.)
stop_binary() {
    local exe="$1"
    local pids
    pids=$(pgrep -f "^${exe}( |$)" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done <<< "$pids"
    fi
}

# Stop stale instances from previous runs (release and verification builds).
stop_binary "$BIN"
stop_binary "$ROOT/build/SoramimiTest.app/Contents/MacOS/Soramimi"
sleep 1

"$BIN" -KeepAliveEnabled YES -KeepAliveLevelDB "$LEVEL" >> "$LOG" 2>&1 &
PID=$!
sleep 2
if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: app exited at soak start" >&2
    exit 1
fi
START=$(date +%s)
echo "pid=$PID log=$LOG"

while kill -0 "$PID" 2>/dev/null; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    [[ "$ELAPSED" -gt "$SOAK_SECONDS" ]] && break
    RSS=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || true)
    CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' || true)
    THREADS=$(ps -M -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
    FOOTPRINT_RAW=$(vmmap "$PID" -summary 2>/dev/null | grep -i "Physical footprint:" | head -1 | sed -E 's/.*: *([0-9.]+)([KMG]).*/\1 \2/' || true)
    FOOTPRINT=""
    if [[ -n "$FOOTPRINT_RAW" ]]; then
        FV=$(echo "$FOOTPRINT_RAW" | awk '{print $1}')
        FU=$(echo "$FOOTPRINT_RAW" | awk '{print $2}')
        FOOTPRINT=$(awk -v v="$FV" -v u="$FU" 'BEGIN { if (u=="K") printf "%.1f", v/1024.0; else if (u=="G") printf "%.1f", v*1024.0; else printf "%.1f", v }')
    fi
    NETSOCK=$(lsof -nP -a -p "$PID" -i 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
    if [[ -n "${RSS:-}" && -n "${FOOTPRINT:-}" ]]; then
        printf '%s,%s,%s,%s,%s,%s\n' "$ELAPSED" "$RSS" "$FOOTPRINT" "${CPU:-0}" "${THREADS:-0}" "${NETSOCK:-0}" >> "$OUT"
    fi
    sleep "$INTERVAL"
done
kill -TERM "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
sleep 1
stop_binary "$BIN"

echo "==> soak finished; summary:"
head -1 "$OUT"
tail -n 5 "$OUT"
echo "full samples: $OUT"
