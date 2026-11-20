#!/bin/bash
#
# Remove Soramimi for the current user. No sudo required.
#
# Steps:
#   1. Stop the running app (SIGTERM; the app removes its audio engine state).
#   2. Run the app's own --reset path (unregisters the SMAppService login item and
#      removes the preferences domain) before deleting the bundle.
#   3. Delete ~/Applications/Soramimi.app.
#
# Usage:
#   scripts/uninstall.sh              # uninstall from ~/Applications
#   APP_PATH=... scripts/uninstall.sh # uninstall from a custom location
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

TARGET_APP="${APP_PATH:-$HOME/Applications/Soramimi.app}"

if pgrep -f "^$TARGET_APP/Contents/MacOS/Soramimi( |$)" >/dev/null 2>&1; then
    echo "==> Stopping Soramimi"
    stop_binary "$TARGET_APP/Contents/MacOS/Soramimi"
    sleep 1
fi

if [[ -x "$TARGET_APP/Contents/MacOS/Soramimi" ]]; then
    echo "==> Unregistering login item and removing preferences"
    "$TARGET_APP/Contents/MacOS/Soramimi" --reset
fi

if [[ -d "$TARGET_APP" ]]; then
    rm -rf "$TARGET_APP"
    echo "==> Removed $TARGET_APP"
else
    echo "==> $TARGET_APP was not present"
fi

echo "==> Uninstall complete."
echo "If 'Launch at Login' is still listed in System Settings, open"
echo "System Settings → General → Login Items and remove Soramimi manually."
echo "Note: deleting an app does not always delete its System Settings login-item entry,"
echo "which is why --reset unregisters it before removal."
