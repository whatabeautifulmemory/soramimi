#!/bin/bash
#
# Build Soramimi.
#
# Two build flavors are produced from the same sources:
#
#   scripts/build.sh                -> build/Soramimi.app
#                                      the shipped, hardened release build.
#                                      Test-only hooks are compiled OUT.
#
#   scripts/build.sh --test-hooks   -> build/SoramimiTest.app
#                                      identical code plus -DMAG_TESTING hooks
#                                      (different bundle identifier and prefs
#                                      domain) used only by the verification,
#                                      measurement and soak scripts.
#
# Both are ad-hoc signed. No Xcode project, no third-party frameworks, no package
# manager, no network access during the build.
#
# Usage:
#   scripts/build.sh [--unsigned] [--test-hooks]
#   VERSION=1.0.1 scripts/build.sh
#   BUILD_DATE=2026-01-01T00:00:00Z scripts/build.sh   # deterministic builds
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DATE="${BUILD_DATE:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
BUILD_DIR="$ROOT/build"
BASE_APP_NAME="Soramimi"
BASE_BUNDLE_ID="local.soramimi"
SDK="$(xcrun --show-sdk-path)"
CLANG="$(xcrun -find clang)"
STRIP="$(xcrun -find strip)"
CODESIGN="$(xcrun -find codesign)"
PLUTIL="$(xcrun -find plutil)"
TOOLCHAIN="$("$CLANG" --version | head -1)"
SIGN=1
TEST_HOOKS=0

for argument in "$@"; do
    case "$argument" in
        --unsigned) SIGN=0 ;;
        --test-hooks) TEST_HOOKS=1 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done

if [[ "$TEST_HOOKS" -eq 1 ]]; then
    APP_NAME="$BASE_APP_NAME"
    APP="$BUILD_DIR/${BASE_APP_NAME}Test.app"
    BUNDLE_ID="$BASE_BUNDLE_ID.test"
    DISPLAY_NAME="Soramimi (Test)"
    BUILD_INFO="$BUILD_DIR/build-info-test.txt"
    EXTRA_DEFINE="-DMAG_TESTING"
else
    APP_NAME="$BASE_APP_NAME"
    APP="$BUILD_DIR/${BASE_APP_NAME}.app"
    BUNDLE_ID="$BASE_BUNDLE_ID"
    DISPLAY_NAME="Soramimi"
    BUILD_INFO="$BUILD_DIR/build-info.txt"
    EXTRA_DEFINE=""
fi

echo "==> Building $DISPLAY_NAME $VERSION ($BUILD_DATE)"
echo "    app: $APP"
echo "    bundle id: $BUNDLE_ID  test hooks: $([[ "$TEST_HOOKS" -eq 1 ]] && echo on || echo off)"
echo "    SDK: $SDK"
echo "    Toolchain: $TOOLCHAIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

CFLAGS=(
    -fobjc-arc
    -Os
    -g0
    -mmacosx-version-min=13.0
    -fvisibility=hidden
    -Wall
    -Wextra
    -Wno-unused-parameter
    -Wno-deprecated-declarations
    -isysroot "$SDK"
    ${EXTRA_DEFINE:-}
)
LDFLAGS=(
    -framework AppKit
    -framework Foundation
    -framework AudioToolbox
    -framework CoreAudio
    -framework ServiceManagement
    -Wl,-dead_strip
    -Wl,-x
    -Wl,-S
)

# shellcheck disable=SC2086
"$CLANG" "${CFLAGS[@]}" -o "$APP/Contents/MacOS/$APP_NAME" "$ROOT"/Sources/*.m "${LDFLAGS[@]}"
"$STRIP" -x "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Info.plist from template, then flavor-specific identity.
sed \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@BUILD_NUMBER@|$BUILD_NUMBER|g" \
    -e "s|@BUILD_DATE@|$BUILD_DATE|g" \
    -e "s|@BUILD_TOOLCHAIN@|$TOOLCHAIN|g" \
    "$ROOT/Resources/Info.plist.in" > "$APP/Contents/Info.plist"
if [[ "$TEST_HOOKS" -eq 1 ]]; then
    "$PLUTIL" -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
    "$PLUTIL" -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP/Contents/Info.plist"
    "$PLUTIL" -replace CFBundleName -string "$DISPLAY_NAME" "$APP/Contents/Info.plist"
fi
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null

# App icon (pixel-art illustration selected by the user; source asset lives in Resources/).
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "Missing Resources/AppIcon.icns" >&2
    exit 1
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SIGN" -eq 1 ]]; then
    # Ad-hoc signature: enough for macOS to run the bundle and to use
    # SMAppService login items. There is no Developer ID / notarization here,
    # which is why the project explicitly documents Gatekeeper steps.
    "$CODESIGN" --force --sign - --timestamp=none "$APP"
else
    echo "    (signature skipped)"
fi

BINARY_BYTES=$(stat -f%z "$APP/Contents/MacOS/$APP_NAME")
BUNDLE_BYTES=$(du -sk "$APP" | awk '{print $1 * 1024}')
BINARY_SHA256=$(shasum -a 256 "$APP/Contents/MacOS/$APP_NAME" | awk '{print $1}')
ICON_SHA256=$(shasum -a 256 "$APP/Contents/Resources/AppIcon.icns" | awk '{print $1}')

# Hash of the build inputs, so a build can be tied to an auditable source snapshot.
SOURCE_TREE_SHA256=$(
    {
        cd "$ROOT"
        find Sources Resources tests Makefile -type f -print | sort
        find scripts -maxdepth 1 -type f -name "*.sh" -print | sort
        echo README.md
        echo README.ko.md
        echo LICENSE
    } 2>/dev/null | while IFS= read -r file; do
        [[ -f "$file" ]] && shasum -a 256 "$file"
    done | shasum -a 256 | awk '{print $1}'
)
GIT_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
[[ -z "$GIT_COMMIT" ]] && GIT_COMMIT="uncommitted"

{
    echo "name=$DISPLAY_NAME"
    echo "version=$VERSION"
    echo "build_number=$BUILD_NUMBER"
    echo "build_date=$BUILD_DATE"
    echo "bundle_identifier=$BUNDLE_ID"
    echo "test_hooks=$TEST_HOOKS"
    echo "sdk_path=$SDK"
    echo "sdk_version=$(xcrun --show-sdk-version)"
    echo "toolchain=$TOOLCHAIN"
    echo "signature=$([[ "$SIGN" -eq 1 ]] && echo ad-hoc || echo none)"
    echo "binary_bytes=$BINARY_BYTES"
    echo "bundle_bytes=$BUNDLE_BYTES"
    echo "binary_sha256=$BINARY_SHA256"
    echo "app_icon_sha256=$ICON_SHA256"
    echo "source_tree_sha256=$SOURCE_TREE_SHA256"
    echo "git_commit=$GIT_COMMIT"
} > "$BUILD_INFO"

cat "$BUILD_INFO"
echo "==> Built $APP"
