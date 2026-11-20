#!/bin/bash
#
# Install Soramimi for the current user only. No sudo, no /Library
# changes, no launch daemon. The app is copied to ~/Applications.
#
# Usage:
#   scripts/install-user.sh           # install and open
#   scripts/install-user.sh --no-open # install only
#
set -euo pipefail

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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/build/Soramimi.app"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/Soramimi.app"
OPEN=1

for argument in "$@"; do
    case "$argument" in
        --no-open) OPEN=0 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Build first: scripts/build.sh" >&2
    exit 1
fi

# Quit a running copy cleanly before replacing the bundle.
if pgrep -f "^$DEST_APP/Contents/MacOS/Soramimi( |$)" >/dev/null 2>&1; then
    echo "==> Stopping the currently installed copy"
    stop_binary "$DEST_APP/Contents/MacOS/Soramimi"
    sleep 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
cp -R "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "==> Installed to $DEST_APP"
echo
echo "First start (Gatekeeper): ad-hoc signed builds may show a one-time warning."
echo "Right-click the app in Finder and choose Open, or run:"
echo "  xattr -dr com.apple.quarantine \"$DEST_APP\""
echo "Then start it with:"
echo "  open \"$DEST_APP\""
echo
if [[ "$OPEN" -eq 1 ]]; then
    echo "==> Starting Soramimi"
    open "$DEST_APP"
fi
