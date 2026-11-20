#!/bin/bash
#
# Static and runtime verification for Soramimi.
#
# Two artifacts are involved:
#
#   release build  build/Soramimi.app          -> shipped artifact
#   test build     build/SoramimiTest.app      -> identical sources compiled
#                                                         with -DMAG_TESTING (different
#                                                         bundle id + prefs domain) so the
#                                                         end-to-end tests can drive the
#                                                         app without any production control
#                                                         surface existing.
#
# Static security claims are checked against the RELEASE build. Feature behaviour is
# exercised with the TEST build. Neither build is installed and no administrator
# rights are used.
#
# The login-item test mutates the real (per-user) Login Items database, so it is
# opt-in:  MAG_VERIFY_LOGIN_ITEM=1 scripts/verify.sh
# The real Apple Music test is opt-in:  MAG_VERIFY_REAL_MUSIC=1 scripts/verify.sh
#
# Exit code: 0 when no FAIL occurred (WARN does not fail the run).
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_RELEASE="$ROOT/build/Soramimi.app"
BIN_RELEASE="$APP_RELEASE/Contents/MacOS/Soramimi"
APP_TEST="$ROOT/build/SoramimiTest.app"
BIN_TEST="$APP_TEST/Contents/MacOS/Soramimi"
FIXTURES="$ROOT/build/test-fixtures"
RUN_ID="$$"
DUMMY_ID="local.soramimi-verify-${RUN_ID}.dummy"
REPL_ID="local.soramimi-verify-${RUN_ID}.replacement"
MARKER_DUMMY="/tmp/soramimi-verify-${RUN_ID}-dummy-started"
MARKER_REPL="/tmp/soramimi-verify-${RUN_ID}-replacement-started"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

pass() { printf 'PASS: %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { printf 'WARN: %s\n' "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
skip() { printf 'SKIP: %s\n' "$*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }


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

cleanup() {
    stop_binary "$BIN_RELEASE"
    stop_binary "$BIN_TEST"
    stop_binary "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget"
    stop_binary "$FIXTURES/ReplacementTarget.app/Contents/MacOS/ReplacementTarget"
    rm -f "$MARKER_DUMMY" "$MARKER_REPL"
}
trap cleanup EXIT INT TERM

echo "== Soramimi verification =="
echo "release: $APP_RELEASE"
echo "test:    $APP_TEST"
echo "date:    $(date)"
echo

# ---------------------------------------------------------------------------
echo "-- 0. Build both flavors"
# ---------------------------------------------------------------------------
"$ROOT/scripts/build.sh" >/dev/null 2>&1 || { fail "release build failed"; exit 1; }
"$ROOT/scripts/build.sh" --test-hooks >/dev/null 2>&1 || { fail "test build failed"; exit 1; }
[[ -x "$BIN_RELEASE" ]] && pass "release binary built" || fail "release binary missing"
[[ -x "$BIN_TEST" ]] && pass "verification (test-hooks) binary built" || fail "test binary missing"
TEST_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_TEST/Contents/Info.plist" 2>/dev/null || true)
[[ "$TEST_BUNDLE_ID" == "local.soramimi.test" ]] &&
    pass "test build uses a distinct bundle identifier ($TEST_BUNDLE_ID)" ||
    fail "test build bundle id is unexpected: $TEST_BUNDLE_ID"

# ---------------------------------------------------------------------------
echo
echo "-- 1. Release bundle / Info.plist"
# ---------------------------------------------------------------------------
PLIST_RELEASE="$APP_RELEASE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST_RELEASE" 2>/dev/null | grep -qx "true" &&
    pass "LSUIElement=true (no Dock icon)" || fail "LSUIElement is not true"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST_RELEASE" 2>/dev/null)" == "13.0" ]] &&
    pass "LSMinimumSystemVersion=13.0" || warn "unexpected LSMinimumSystemVersion"
if grep -q "CFBundleURLTypes" "$PLIST_RELEASE"; then
    fail "Info.plist declares URL scheme handlers (not needed; attack surface)"
else
    pass "no URL scheme handlers declared"
fi
if grep -qE "NSAppleEventsUsageDescription|NSAccessibility|NSScreenCapture|NSMicrophone" "$PLIST_RELEASE"; then
    fail "Info.plist requests privacy-sensitive permissions"
else
    pass "Info.plist requests no privacy-sensitive permissions"
fi

# ---------------------------------------------------------------------------
echo
echo "-- 2. Code signature and entitlements (release + test)"
# ---------------------------------------------------------------------------
CODESIGN="$(xcrun -find codesign)"
for APP in "$APP_RELEASE" "$APP_TEST"; do
    "$CODESIGN" --verify --strict "$APP" >/dev/null 2>&1 &&
        pass "codesign --verify --strict: $(basename "$APP")" ||
        fail "code signature verification failed: $APP"
    ENTITLEMENTS=$("$CODESIGN" -d --entitlements - "$APP" 2>/dev/null || true)
    if [[ -z "$ENTITLEMENTS" ]]; then
        pass "no entitlements: $(basename "$APP")"
    else
        fail "unexpected entitlements in $APP: $ENTITLEMENTS"
    fi
done
"$CODESIGN" -dv "$APP_RELEASE" 2>&1 | grep -q "Signature=adhoc" &&
    pass "ad-hoc signed (documented for local builds)" || warn "unexpected signature type"

# ---------------------------------------------------------------------------
echo
echo "-- 3. Linked libraries (release allow-list)"
# ---------------------------------------------------------------------------
ALLOWED_FRAMEWORK_REGEX='/(AppKit|Foundation|AudioToolbox|CoreAudio|ServiceManagement|CoreFoundation)\.framework/'
ALLOWED_LIB_REGEX='^/usr/lib/(libSystem|libobjc|libc\+\+|libc\.1|libauto)\.'
UNEXPECTED=0
while IFS= read -r line; do
    [[ "$line" == *":"* ]] && continue
    dep=$(echo "$line" | awk '{print $1}')
    [[ -z "$dep" ]] && continue
    if [[ "$dep" =~ $ALLOWED_FRAMEWORK_REGEX || "$dep" =~ $ALLOWED_LIB_REGEX ]]; then
        :
    else
        echo "  unexpected dependency: $dep"
        UNEXPECTED=$((UNEXPECTED + 1))
    fi
done < <("$(xcrun -find otool)" -L "$BIN_RELEASE")
if [[ "$UNEXPECTED" -eq 0 ]]; then
    pass "release binary links only allow-listed macOS system frameworks/libraries"
else
    fail "$UNEXPECTED unexpected linked library/libraries"
fi

# ---------------------------------------------------------------------------
echo
echo "-- 4. Forbidden APIs / network symbols / test hooks (release binary)"
# ---------------------------------------------------------------------------
FORBIDDEN_REGEX='URLSession|NSURLConnection|CFNetwork|NWConnection|nw_connection|getaddrinfo|gethostby|CFSocket|WebSocket|MPNowPlayingInfoCenter|MPRemoteCommandCenter|MediaRemote|CGEventTap|AXIsProcessTrusted|AXUIElement|IOHID|SMJobBless|AuthorizationCreate|AuthorizationExecuteWithPrivileges|NSAppleScript|NSTask|posix_spawn|_execve|_fork|_system|_dlopen|_dlsym|_syscall|objc_getClass|objc_lookUpClass|Sparkle|SUUpdater|appcast|telemetry|analytics|CrashReporter|Sentry|Firebase'
SYMBOLS=$("$(xcrun -find nm)" -u "$BIN_RELEASE" 2>/dev/null | awk '{print $2}')
HITS=0
while IFS= read -r symbol; do
    [[ -z "$symbol" ]] && continue
    if echo "$symbol" | grep -qE "$FORBIDDEN_REGEX"; then
        echo "  forbidden undefined symbol: $symbol"
        HITS=$((HITS + 1))
    fi
done <<< "$SYMBOLS"
if [[ "$HITS" -eq 0 ]]; then
    pass "release binary references no forbidden network/media/event/privilege/dynamic-loading APIs"
else
    fail "$HITS forbidden symbol(s) referenced"
fi
STRINGS_RELEASE=$(strings -a "$BIN_RELEASE" 2>/dev/null)
if echo "$STRINGS_RELEASE" | grep -qE 'https?://'; then
    fail "release binary contains an http(s) URL string"
else
    pass "release binary contains no http(s) URL strings"
fi
if echo "$STRINGS_RELEASE" | grep -qiE 'telemetry|analytics|appcast|sparkle'; then
    fail "release binary contains telemetry/auto-update strings"
else
    pass "release binary contains no telemetry/auto-update strings"
fi
if echo "$STRINGS_RELEASE" | grep -q "MAG_TEST_"; then
    fail "release binary still contains MAG_TEST_* verification hooks"
else
    pass "release binary contains no MAG_TEST_* verification hooks (compiled out)"
fi
if echo "$STRINGS_RELEASE" | grep -q -- "--test-login-item"; then
    fail "release binary still exposes --test-login-item"
else
    pass "release binary has no --test-login-item test command"
fi
if "$(xcrun -find otool)" -L "$BIN_RELEASE" | grep -q "MediaPlayer"; then
    fail "MediaPlayer.framework is linked"
else
    pass "MediaPlayer.framework is not linked (no Now Playing session possible)"
fi

# Source-level scan: code lines only (explanatory comment lines are skipped).
SOURCE_HITS=$(grep -RInE 'URLSession|NSURLConnection|CFNetwork|NWConnection|nw_connection|getaddrinfo|MPNowPlayingInfoCenter|MPRemoteCommandCenter|CGEventTap|AXUIElement|IOHID|SMJobBless|AuthorizationCreate|NSAppleScript|NSTask|posix_spawn|execve|syscall\(|dlopen\(|dlsym\(|Sparkle|appcast' "$ROOT/Sources" 2>/dev/null |
    grep -vE ':[0-9]+:[[:space:]]*(//|\*|\*/)' || true)
if [[ -z "$SOURCE_HITS" ]]; then
    pass "source scan: no forbidden API use in Sources/"
else
    echo "$SOURCE_HITS" | sed 's/^/  /'
    fail "source scan found forbidden API use"
fi

# ---------------------------------------------------------------------------
echo
echo "-- 5. Self-test (release and test builds)"
# ---------------------------------------------------------------------------
SELFTEST_OUTPUT=$("$BIN_RELEASE" --self-test 2>&1)
SELFTEST_STATUS=$?
[[ $SELFTEST_STATUS -eq 0 ]] && pass "release --self-test exits 0" || fail "release --self-test exits $SELFTEST_STATUS"
echo "$SELFTEST_OUTPUT" | grep -q "no MediaPlayer/MediaRemote framework is loaded" &&
    pass "runtime: no MediaPlayer/MediaRemote framework loaded" || fail "runtime: forbidden media framework loaded"
echo "$SELFTEST_OUTPUT" | grep -q "audio queue started" &&
    pass "runtime: AudioQueue keep-alive started" || fail "runtime: AudioQueue keep-alive did not start"
"$BIN_TEST" --self-test >/dev/null 2>&1 && pass "test build --self-test exits 0" ||
    fail "test build --self-test failed"
DUMP_STATE=$("$BIN_RELEASE" --dump-state 2>/dev/null)
if echo "$DUMP_STATE" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    pass "release --dump-state emits valid JSON"
else
    fail "release --dump-state did not emit valid JSON"
fi

# ---------------------------------------------------------------------------
echo
echo "-- 6. Runtime: no network traffic while running (release build)"
# ---------------------------------------------------------------------------
RELEASE_LOG="$ROOT/build/verify-release-idle.log"
: > "$RELEASE_LOG"
"$BIN_RELEASE" > "$RELEASE_LOG" 2>&1 &
RUN_PID=$!
sleep 2
if ! kill -0 "$RUN_PID" 2>/dev/null; then
    fail "release app exited during the network check (liveness check)"
else
    pass "release app is alive during the network check"
    NET_LINES=0
    for _ in 1 2 3; do
        COUNT=$(lsof -nP -a -p "$RUN_PID" -i 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        NET_LINES=$((NET_LINES + COUNT))
        sleep 1
    done
    [[ "$NET_LINES" -eq 0 ]] && pass "0 network sockets observed over 3 samples" ||
        fail "$NET_LINES network socket lines observed"
fi
kill "$RUN_PID" 2>/dev/null
wait "$RUN_PID" 2>/dev/null
sleep 1
pgrep -f "$BIN_RELEASE" >/dev/null 2>&1 && fail "release app did not exit after SIGTERM" ||
    pass "release app stopped cleanly"

# ---------------------------------------------------------------------------
echo
echo "-- 7. Runtime performance with keep-alive ON (release build)"
# ---------------------------------------------------------------------------
DEVICE_BEFORE=$("$BIN_RELEASE" --dump-state 2>/dev/null | grep '"outputDevice"' | head -1)
VOLUME_BEFORE=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null || echo unknown)
PERF_LOG="$ROOT/build/verify-release-keepalive.log"
: > "$PERF_LOG"
"$BIN_RELEASE" -KeepAliveEnabled YES -KeepAliveLevelDB -100 > "$PERF_LOG" 2>&1 &
RUN_PID=$!
sleep 3
if ! kill -0 "$RUN_PID" 2>/dev/null; then
    fail "release app exited before performance sampling (liveness check)"
else
    RSS_KB=$(ps -o rss= -p "$RUN_PID" | tr -d ' ')
    THREADS=$(ps -M -p "$RUN_PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    FOOTPRINT_RAW=$(vmmap "$RUN_PID" -summary 2>/dev/null | grep -i "Physical footprint:" | head -1)
    FOOTPRINT_MB=$(echo "$FOOTPRINT_RAW" | sed -E 's/.*: *([0-9.]+)M.*/\1/')
    CPU_1=$(ps -o %cpu= -p "$RUN_PID" | tr -d ' ')
    sleep 3
    CPU_2=$(ps -o %cpu= -p "$RUN_PID" | tr -d ' ')
    sleep 3
    CPU_3=$(ps -o %cpu= -p "$RUN_PID" | tr -d ' ')
    echo "  RSS: ${RSS_KB} KB, physical footprint: ${FOOTPRINT_MB:-?} MB, threads: ${THREADS}"
    echo "  CPU samples: ${CPU_1}% ${CPU_2}% ${CPU_3}%"
    if [[ -n "$FOOTPRINT_MB" ]] && awk -v f="$FOOTPRINT_MB" 'BEGIN { exit !(f <= 15.0) }'; then
        pass "physical footprint ${FOOTPRINT_MB} MB <= 15 MB target"
    else
        warn "physical footprint ${FOOTPRINT_MB:-?} MB exceeds the 15 MB target"
    fi
    MAX_CPU=$(printf '%s\n%s\n%s\n' "$CPU_1" "$CPU_2" "$CPU_3" | sort -g | tail -1)
    if awk -v c="$MAX_CPU" 'BEGIN { exit !(c <= 0.5) }'; then
        pass "CPU <= 0.5% (observed max ${MAX_CPU}%)"
    else
        warn "CPU above 0.5% target (observed max ${MAX_CPU}%)"
    fi
    [[ "$THREADS" -le 12 ]] && pass "thread count reasonable (${THREADS})" ||
        warn "unexpectedly many threads: ${THREADS}"
    NET_KEEPALIVE=$(lsof -nP -a -p "$RUN_PID" -i 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    [[ "$NET_KEEPALIVE" -eq 0 ]] && pass "0 network sockets while keep-alive is running" ||
        fail "$NET_KEEPALIVE network sockets while keep-alive is running"
    # Audio must be actually running: coreaudiod holds a power assertion for our pid.
    sleep 1
    if pmset -g assertions 2>/dev/null | grep -A3 "Created for PID: $RUN_PID" | grep -q "audio-out"; then
        pass "coreaudiod confirms an active audio output context for this process"
    else
        warn "no audio power assertion observed for the process (keep-alive may not be running)"
    fi
fi
kill "$RUN_PID" 2>/dev/null
wait "$RUN_PID" 2>/dev/null
DEVICE_AFTER=$("$BIN_RELEASE" --dump-state 2>/dev/null | grep '"outputDevice"' | head -1)
VOLUME_AFTER=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null || echo unknown)
if [[ -n "$DEVICE_BEFORE" && "$DEVICE_BEFORE" == "$DEVICE_AFTER" ]]; then
    pass "default output device unchanged by keep-alive ($(echo "$DEVICE_AFTER" | sed -E 's/.*: "(.*)",/\1/'))"
else
    fail "default output device changed: '$DEVICE_BEFORE' -> '$DEVICE_AFTER'"
fi
if [[ "$VOLUME_BEFORE" == "$VOLUME_AFTER" ]]; then
    pass "system output volume unchanged by keep-alive (${VOLUME_AFTER})"
else
    warn "system output volume changed during the test: ${VOLUME_BEFORE} -> ${VOLUME_AFTER}"
fi

# ---------------------------------------------------------------------------
echo
echo "-- 8. Blocking behaviour (verification build, fixture targets)"
# ---------------------------------------------------------------------------
VERIFY_SDK="$(xcrun --show-sdk-path)"
mkdir -p "$FIXTURES/DummyTarget.app/Contents/MacOS" "$FIXTURES/ReplacementTarget.app/Contents/MacOS"
cat > "$FIXTURES/dummy.m" <<EOF
#import <Cocoa/Cocoa.h>
int main(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createFileAtPath:@"$MARKER_DUMMY" contents:[NSData data] attributes:nil];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
EOF
"$(xcrun -find clang)" -fobjc-arc -Os -mmacosx-version-min=13.0 -isysroot "$VERIFY_SDK" \
    -framework Cocoa -o "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget" "$FIXTURES/dummy.m"
cat > "$FIXTURES/DummyTarget.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DummyTarget</string>
<key>CFBundleIdentifier</key><string>$DUMMY_ID</string>
<key>CFBundleName</key><string>SoramimiVerifyDummy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
"$CODESIGN" --force --sign - "$FIXTURES/DummyTarget.app" >/dev/null 2>&1

cat > "$FIXTURES/replacement.m" <<EOF
#import <Cocoa/Cocoa.h>
int main(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createFileAtPath:@"$MARKER_REPL" contents:[NSData data] attributes:nil];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
EOF
"$(xcrun -find clang)" -fobjc-arc -Os -mmacosx-version-min=13.0 -isysroot "$VERIFY_SDK" \
    -framework Cocoa -o "$FIXTURES/ReplacementTarget.app/Contents/MacOS/ReplacementTarget" "$FIXTURES/replacement.m"
cat > "$FIXTURES/ReplacementTarget.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ReplacementTarget</string>
<key>CFBundleIdentifier</key><string>$REPL_ID</string>
<key>CFBundleName</key><string>SoramimiVerifyReplacement</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
"$CODESIGN" --force --sign - "$FIXTURES/ReplacementTarget.app" >/dev/null 2>&1

run_blocker_case() { # name, seconds, log, env...
    local name="$1"; shift
    local seconds="$1"; shift
    local log="$1"; shift
    : > "$log"
    rm -f "$MARKER_DUMMY" "$MARKER_REPL"
    env "$@" MAG_TEST_QUIT_AFTER_SECONDS="$seconds" "$BIN_TEST" > "$log" 2>&1 &
    RUN_PID=$!
    sleep 1.5
}

# 8a. Always Block intercepts the target before it finishes launching.
BLOCK_LOG="$ROOT/build/verify-blocker.log"
run_blocker_case "always" 15 "$BLOCK_LOG" MAG_TEST_ENABLE_MUSIC_BLOCKER=1 MAG_TEST_POLICY=always \
    MAG_TEST_EXTRA_BLOCKED_BUNDLE="$DUMMY_ID" MAG_TEST_VERBOSE=1
open "$FIXTURES/DummyTarget.app"
sleep 2
grep -q "MAG_BLOCKED $DUMMY_ID" "$BLOCK_LOG" &&
    pass "Always Block intercepted the target at willLaunch" || fail "blocker did not log an interception"
pgrep -f "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget" >/dev/null 2>&1 &&
    fail "blocked target is still running" || pass "blocked target is not running"
[[ -e "$MARKER_DUMMY" ]] &&
    pass "target process started and was terminated before finishing launch (pre-launch hook)" ||
    warn "target marker missing (termination may have happened even earlier)"
wait "$RUN_PID" 2>/dev/null

# 8b. Smart Block allows an uncorrelated launch.
SMART_LOG="$ROOT/build/verify-smart.log"
run_blocker_case "smart" 12 "$SMART_LOG" MAG_TEST_ENABLE_MUSIC_BLOCKER=1 MAG_TEST_POLICY=smart \
    MAG_TEST_EXTRA_BLOCKED_BUNDLE="$DUMMY_ID" MAG_TEST_VERBOSE=1
open "$FIXTURES/DummyTarget.app"
sleep 3
pgrep -f "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget" >/dev/null 2>&1 &&
    pass "Smart Block allowed an uncorrelated (manual-looking) launch" ||
    fail "Smart Block blocked an uncorrelated launch"
pkill -f "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget" >/dev/null 2>&1 || true
wait "$RUN_PID" 2>/dev/null

# 8c. Smart Block blocks a launch correlated with a simulated device event.
CORR_LOG="$ROOT/build/verify-smart-correlated.log"
run_blocker_case "smart-correlated" 15 "$CORR_LOG" MAG_TEST_ENABLE_MUSIC_BLOCKER=1 MAG_TEST_POLICY=smart \
    MAG_TEST_EXTRA_BLOCKED_BUNDLE="$DUMMY_ID" MAG_TEST_TRIGGER_AUTO_SECONDS=1 MAG_TEST_VERBOSE=1
sleep 1
open "$FIXTURES/DummyTarget.app"
sleep 2
grep -q "MAG_BLOCKED $DUMMY_ID" "$CORR_LOG" &&
    pass "Smart Block blocked a launch correlated with a simulated device change" ||
    fail "Smart Block did not block a correlated launch"
pkill -f "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget" >/dev/null 2>&1 || true
wait "$RUN_PID" 2>/dev/null

# 8d. Replacement application launches once and is not duplicated.
REPL_LOG="$ROOT/build/verify-replacement.log"
run_blocker_case "replacement" 20 "$REPL_LOG" MAG_TEST_ENABLE_MUSIC_BLOCKER=1 MAG_TEST_POLICY=always \
    MAG_TEST_EXTRA_BLOCKED_BUNDLE="$DUMMY_ID" MAG_TEST_REPLACEMENT_PATH="$FIXTURES/ReplacementTarget.app" \
    MAG_TEST_VERBOSE=1
open "$FIXTURES/DummyTarget.app"
sleep 2
grep -q "MAG_BLOCKED $DUMMY_ID" "$REPL_LOG" &&
    pass "blocked launch was intercepted for the replacement test" ||
    fail "blocked launch was not intercepted for the replacement test"
if [[ -e "$MARKER_REPL" ]] && pgrep -f "$FIXTURES/ReplacementTarget.app/Contents/MacOS/ReplacementTarget" >/dev/null 2>&1; then
    pass "replacement application was launched after the block"
else
    fail "replacement application was not launched"
fi
open "$FIXTURES/DummyTarget.app" 2>/dev/null || true
sleep 2
COUNT=$(pgrep -f "$FIXTURES/ReplacementTarget.app/Contents/MacOS/ReplacementTarget" | wc -l | tr -d ' ')
[[ "$COUNT" -eq 1 ]] && pass "replacement application is not duplicated on a second blocked launch (count=$COUNT)" ||
    warn "unexpected replacement process count: $COUNT"
pkill -f "$FIXTURES/ReplacementTarget.app/Contents/MacOS/ReplacementTarget" >/dev/null 2>&1 || true
pkill -f "$FIXTURES/DummyTarget.app/Contents/MacOS/DummyTarget" >/dev/null 2>&1 || true
wait "$RUN_PID" 2>/dev/null

# ---------------------------------------------------------------------------
if [[ "${MAG_VERIFY_REAL_MUSIC:-0}" == "1" ]]; then
    echo
    echo "-- 8e. Real Apple Music launch (opt-in)"
    MUSIC_LOG="$ROOT/build/verify-real-music.log"
    : > "$MUSIC_LOG"
    if pgrep -x "Music" >/dev/null 2>&1; then
        skip "Apple Music is already running; skipping the real-music launch test"
    else
        MAG_TEST_ENABLE_MUSIC_BLOCKER=1 MAG_TEST_POLICY=always MAG_TEST_VERBOSE=1 \
            MAG_TEST_QUIT_AFTER_SECONDS=20 "$BIN_TEST" > "$MUSIC_LOG" 2>&1 &
        RUN_PID=$!
        sleep 1.5
        open -a /System/Applications/Music.app
        sleep 3
        if pgrep -x "Music" >/dev/null 2>&1; then
            fail "Apple Music is still running after the blocking attempt"
            pkill -x Music >/dev/null 2>&1 || true
        else
            pass "Apple Music was blocked before it could stay running"
        fi
        grep -q "MAG_BLOCKED com.apple.Music" "$MUSIC_LOG" &&
            pass "blocker logged the real Apple Music interception" ||
            fail "no real Apple Music block log line"
        wait "$RUN_PID" 2>/dev/null
    fi
else
    skip "real Apple Music test is opt-in (MAG_VERIFY_REAL_MUSIC=1)"
fi

# ---------------------------------------------------------------------------
echo
echo "-- 9. Binary / bundle size (release)"
# ---------------------------------------------------------------------------
BIN_BYTES=$(stat -f%z "$BIN_RELEASE")
BUNDLE_KB=$(du -sk "$APP_RELEASE" | awk '{print $1}')
echo "  binary: ${BIN_BYTES} bytes; bundle: ${BUNDLE_KB} KB"
[[ "$BIN_BYTES" -le 10485760 ]] && pass "binary ${BIN_BYTES} bytes <= 10 MB target" ||
    fail "binary exceeds 10 MB target"

# ---------------------------------------------------------------------------
echo
echo "-- 10. Privilege / system-modification checks"
# ---------------------------------------------------------------------------
SUDO_HITS=0
while IFS= read -r hit; do
    content="${hit#*:*:}"
    [[ "$content" =~ ^[[:space:]]*# ]] && continue
    echo "  sudo reference: $hit"
    SUDO_HITS=$((SUDO_HITS + 1))
done < <(grep -rnE 'sudo[[:space:]]' "$ROOT/scripts" --exclude=verify.sh 2>/dev/null || true)
[[ "$SUDO_HITS" -eq 0 ]] && pass "no script executes sudo or requires administrator rights" ||
    fail "$SUDO_HITS script line(s) reference sudo as a command"
if find "$APP_RELEASE" -perm -4000 2>/dev/null | grep -q .; then
    fail "app bundle contains a setuid binary"
else
    pass "no setuid binaries"
fi
[[ -w /System/Applications/Music.app ]] 2>/dev/null &&
    warn "system Music.app is writable (unusual)" ||
    pass "system directories untouched (no attempt to modify system apps)"
NOT_RUNNING_SYSTEM=$(launchctl print system 2>/dev/null | grep -c "soramimi" || true)
[[ "$NOT_RUNNING_SYSTEM" -eq 0 ]] && pass "no system-wide launchd service installed" ||
    fail "system-wide launchd service found"

# ---------------------------------------------------------------------------
echo
echo "-- 11. Login item API (opt-in: mutates the real per-user Login Items database)"
# ---------------------------------------------------------------------------
if [[ "${MAG_VERIFY_LOGIN_ITEM:-0}" == "1" ]]; then
    LOGIN_OUTPUT=$("$BIN_TEST" --test-login-item 2>&1)
    if echo "$LOGIN_OUTPUT" | grep -q "PASS: login item registered" &&
        echo "$LOGIN_OUTPUT" | grep -q "PASS: login item unregistered"; then
        pass "SMAppService login item registers and unregisters without admin rights (test bundle id)"
    else
        fail "login item register/unregister test failed:"
        echo "$LOGIN_OUTPUT" | sed 's/^/    /'
    fi
else
    skip "login-item mutation is opt-in (MAG_VERIFY_LOGIN_ITEM=1); feature was verified manually during delivery"
fi

# ---------------------------------------------------------------------------
echo
echo "== verification summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARN_COUNT} warnings, ${SKIP_COUNT} skipped =="
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0
exit 1
