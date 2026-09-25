#!/usr/bin/env bash
# Builds the SwiftPM products and assembles build/SecureTunnels.app.
# Usage: scripts/bundle.sh [debug|release]   (default release)
# Env:   CODESIGN_IDENTITY  signing identity, "-" (ad hoc) when unset
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="${VERSION:-1.3.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/SecureTunnels.app"

# Release builds are universal (Apple silicon and Intel); debug builds only target this Mac.
ARCH_FLAGS=()
if [ "$CONFIG" = "release" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SecureTunnels" "$BIN/SecureTunnelsAskPass" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/SecureTunnelsAskPass"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP ($CONFIG, version $VERSION, signed with $IDENTITY)"
