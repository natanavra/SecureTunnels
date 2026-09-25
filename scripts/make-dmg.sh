#!/usr/bin/env bash
# Packages build/SecureTunnels.app as build/SecureTunnels-<version>.dmg with the app and an Applications shortcut
# side by side. The Finder layout step needs Automation permission for Finder; it is skipped when unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.3.1}"
APP="build/SecureTunnels.app"
STAGE="build/dmg-stage"
TMP="build/SecureTunnels-tmp.dmg"
DMG="build/SecureTunnels-$VERSION.dmg"
VOLUME="SecureTunnels"

[ -d "$APP" ] || scripts/bundle.sh release

rm -rf "$STAGE" "$TMP" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$TMP" -quiet
MOUNT_OUTPUT="$(hdiutil attach "$TMP" -readwrite -noverify -noautoopen)"
MOUNT="$(echo "$MOUNT_OUTPUT" | grep -oE '/Volumes/.*$' | head -1)"

osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "Finder layout skipped (no Automation permission); the image still works."
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 200, 960, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set text size of theViewOptions to 14
    set position of item "SecureTunnels.app" of container window to {150, 160}
    set position of item "Applications" of container window to {410, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$TMP"
rm -rf "$STAGE"
echo "Built $DMG"
