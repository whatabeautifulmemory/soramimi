#!/bin/bash
#
# Performance measurement for Soramimi.
#
# Measures the DELIVERED release build (build/Soramimi.app, no test hooks).
# Modes are selected through NSUserDefaults' argument domain, e.g.
#   Soramimi -KeepAliveEnabled YES -KeepAliveLevelDB -100
# which the app reads exactly like stored preferences but which is never persisted,
# so the user's real preferences are untouched.
#
# "physical footprint" is what Activity Monitor shows as Memory (vmmap "Physical
# footprint:"); RSS is listed only for completeness.
#
# Usage:
#   scripts/measure.sh                 # 20 s idle + 60 s keep-alive + 20 s blocker
#   DURATION=600 scripts/measure.sh    # longer keep-alive window
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$ROOT/build/Soramimi.app"
BIN="$APPDIR/Contents/MacOS/Soramimi"
DURATION="${DURATION:-60}"
OUT="$ROOT/build/measurements.txt"
mkdir -p "$ROOT/build"

[[ -x "$BIN" ]] || { echo "Build first: scripts/build.sh" >&2; exit 1; }


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

stop_stale_instances() {
    stop_binary "$BIN"
    stop_binary "$ROOT/build/SoramimiTest.app/Contents/MacOS/Soramimi"
    sleep 1
}

footprint_mb() {
    local pid="$1"
    local raw
    raw=$(vmmap "$pid" -summary 2>/dev/null | grep -i "Physical footprint:" | head -1 |
        sed -E 's/.*: *([0-9.]+)([KMG]).*/\1 \2/' || true)
    [[ -z "$raw" ]] && echo "" && return
    local value unit
    value=$(echo "$raw" | awk '{print $1}')
    unit=$(echo "$raw" | awk '{print $2}')
    awk -v v="$value" -v u="$unit" 'BEGIN {
        if (u == "K") printf "%.1f", v / 1024.0;
        else if (u == "G") printf "%.1f", v * 1024.0;
        else printf "%.1f", v;
    }'
}

run_measurement() {
    local name="$1"
    local seconds="$2"
    shift 2
    local log="$ROOT/build/measure-${name}.log"
    local samples="$ROOT/build/measure-${name}.csv"
    : > "$log"
    printf 'elapsed_s,rss_kb,phys_footprint_mb,cpu_percent,threads,network_sockets\n' > "$samples"

    stop_stale_instances
    echo "==> $name: running for ${seconds}s"
    "$BIN" "$@" > "$log" 2>&1 &
    local pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        printf 'FAIL: app exited immediately (%s)\n' "$name" | tee -a "$OUT"
        return 1
    fi
    local start
    start=$(date +%s)
    local sample_count=0
    while kill -0 "$pid" 2>/dev/null; do
        local now elapsed rss cpu threads footprint netsock
        now=$(date +%s)
        elapsed=$((now - start))
        [[ "$elapsed" -gt $((seconds + 30)) ]] && break
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        threads=$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
        footprint=$(footprint_mb "$pid" || true)
        netsock=$(lsof -nP -a -p "$pid" -i 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
        if [[ -n "${rss:-}" && -n "${footprint:-}" ]]; then
            printf '%s,%s,%s,%s,%s,%s\n' "$elapsed" "$rss" "$footprint" "${cpu:-0}" \
                "${threads:-0}" "${netsock:-0}" >> "$samples"
            sample_count=$((sample_count + 1))
        fi
        if [[ "$elapsed" -ge "$seconds" ]]; then
            break
        fi
        sleep 2
    done
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    {
        echo "== $name =="
        echo "duration: ${seconds}s, samples: ${sample_count}"
        if [[ "$sample_count" -gt 0 ]]; then
            # Ignore warm-up samples (first 4 s) for steady-state numbers.
            echo "phys_footprint_mb min/avg/max (steady state): $(tail -n +2 "$samples" | awk -F, '
                $1 < 4 || $3 < 1 { next }
                NR == 1 { min = $3; max = $3 }
                { sum += $3; count += 1; if ($3 < min) min = $3; if ($3 > max) max = $3 }
                END { if (count == 0) { printf "n/a" } else { printf "%.1f / %.1f / %.1f", min, sum / count, max } }')"
            echo "cpu_percent max (steady state): $(tail -n +2 "$samples" | awk -F, '
                $1 < 4 { next }
                BEGIN { max = 0 } { if ($4 > max) max = $4 } END { printf "%.1f", max }')"
            echo "rss_kb last: $(tail -1 "$samples" | cut -d, -f2)"
            echo "threads max: $(tail -n +2 "$samples" | awk -F, '
                BEGIN { max = 0 } { if ($5 > max) max = $5 } END { printf "%d", max }')"
            echo "network sockets (sum over samples): $(tail -n +2 "$samples" | awk -F, '
                { sum += $6 } END { printf "%d", sum }')"
        fi
        echo
    } | tee -a "$OUT"
}

: > "$OUT"
{
    echo "Soramimi measurements"
    echo "date: $(date)"
    echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "hardware: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.memsize) bytes RAM"
    echo "artifact: release build, no test hooks (build/Soramimi.app)"
    echo "metric note: 'physical footprint' is what Activity Monitor shows as Memory; RSS is listed for completeness"
    echo "binary: $(stat -f%z "$BIN") bytes"
    echo "bundle: $(du -sk "$APPDIR" | awk '{print $1}') KB"
    echo "signature: $(codesign -dv "$APPDIR" 2>&1 | grep -E 'Signature|Identifier' | tr '\n' ' ')"
    echo "output device: $("$BIN" --dump-state 2>/dev/null | grep '"outputDevice"' | head -1 | sed -E 's/.*: "(.*)",/\1/')"
    echo
} | tee -a "$OUT"

run_measurement "idle-no-features" 20
run_measurement "keep-alive-100dbfs" "$DURATION" -KeepAliveEnabled YES -KeepAliveLevelDB -100
run_measurement "blocker-active" 20 -MusicBlockerEnabled YES

echo "==> measurements written to $OUT"
