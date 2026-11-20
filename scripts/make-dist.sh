#!/bin/bash
#
# Build distributable archives: the signed .app as a zip and the complete source
# tree as a tarball. Both end up in build/dist/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/build/Soramimi.app/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
DIST="$ROOT/build/dist"
STAGE="$ROOT/build/stage"
NAME="Soramimi-$VERSION"

rm -rf "$DIST" "$STAGE"
mkdir -p "$DIST" "$STAGE/$NAME"

cp -R "$ROOT/build/Soramimi.app" "$STAGE/$NAME/"
cp "$ROOT/README.md" "$ROOT/README.ko.md" "$ROOT/LICENSE" "$STAGE/$NAME/" 2>/dev/null || true
cp "$ROOT/build/build-info.txt" "$STAGE/$NAME/" 2>/dev/null || true
cp "$ROOT/build/static-verification.log" "$STAGE/$NAME/STATIC-VERIFICATION.txt" 2>/dev/null || true

(cd "$STAGE" && zip -qry "$DIST/$NAME.zip" "$NAME")

mkdir -p "$STAGE/source"
tar -C "$ROOT" \
    --exclude='./build' \
    --exclude='./.git' \
    --exclude='./.DS_Store' \
    --exclude='./design/icons' \
    --exclude='./docs' \
    -czf "$DIST/soramimi-$VERSION-source.tar.gz" \
    .

(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
(cd "$DIST" && shasum -a 256 "soramimi-$VERSION-source.tar.gz" > "soramimi-$VERSION-source.tar.gz.sha256")
(cd "$DIST" && shasum -a 256 "$NAME.zip" "soramimi-$VERSION-source.tar.gz" > SHA256SUMS)
echo "==> $DIST/$NAME.zip"
echo "==> $DIST/soramimi-$VERSION-source.tar.gz"
echo "==> $DIST/SHA256SUMS"
ls -lh "$DIST"
