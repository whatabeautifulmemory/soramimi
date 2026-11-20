#!/bin/bash
#
# Build and run the test suite:
#   1. pure-logic unit tests (23 checks: signal generator, blocking policy, prefs)
#   2. ThreadSanitizer regression test for the UI<->AudioQueue level-change hand-off
#      (the race that an independent review found before MAGSignalControl was added)
#
# No AppKit, no audio device, no user preferences are modified other than the
# clamping check in MAGTestPreferenceBounds (which restores the value).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
SDK="$(xcrun --show-sdk-path)"
CLANG="$(xcrun -find clang)"
mkdir -p "$BUILD_DIR"

echo "==> Building logic tests"
"$CLANG" \
    -fobjc-arc -Os -g0 -mmacosx-version-min=13.0 -isysroot "$SDK" -I "$ROOT/Sources" \
    -framework Foundation \
    -o "$BUILD_DIR/MAGTests" \
    "$ROOT/tests/MAGTests.m" \
    "$ROOT/Sources/MAGSignalGenerator.m" \
    "$ROOT/Sources/MAGSignalControl.m" \
    "$ROOT/Sources/MAGBlockPolicy.m" \
    "$ROOT/Sources/MAGPreferences.m"

echo "==> Running logic tests"
"$BUILD_DIR/MAGTests"

echo
echo "==> Building ThreadSanitizer race test"
"$CLANG" \
    -fobjc-arc -O1 -g -mmacosx-version-min=13.0 -isysroot "$SDK" -I "$ROOT/Sources" \
    -fsanitize=thread \
    -framework Foundation \
    -o "$BUILD_DIR/MAGRaceTests" \
    "$ROOT/tests/MAGRaceTests.m" \
    "$ROOT/Sources/MAGSignalGenerator.m" \
    "$ROOT/Sources/MAGSignalControl.m"

echo "==> Running ThreadSanitizer race test"
TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$BUILD_DIR/MAGRaceTests"
