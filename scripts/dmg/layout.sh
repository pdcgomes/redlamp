#!/usr/bin/env bash
#
# Has Finder lay out the disk image's window and keeps what it writes in DS_Store, which
# scripts/release-dmg.sh puts in every image as its .DS_Store: icon view without the toolbar,
# 640 by 400 points, background.tiff behind the icons, and Redlamp.app and the Applications link
# where background.html draws their places. Run it again when the window's size or the icons'
# places change, and commit DS_Store; a new picture needs only background.sh.
#
# Finder finds the picture by the volume's name and the picture's path, so every image is called
# Redlamp and holds .background/background.tiff. This mounts an image where Finder sees it and
# scripts Finder, so it runs in Terminal, which macOS asks once to let control Finder.
#
#   scripts/dmg/layout.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT=/Volumes/Redlamp
[ -f "$HERE/background.tiff" ] || { echo "error: no $HERE/background.tiff (scripts/dmg/background.sh)" >&2; exit 1; }
[ ! -e "$MOUNT" ] || { echo "error: $MOUNT is in use; eject it and run this again" >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = 1 ]; then
        hdiutil detach -force "$MOUNT" >/dev/null || return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

hdiutil create -size 16m -fs HFS+ -volname Redlamp "$WORK/layout.dmg" >/dev/null
hdiutil attach -noautoopen "$WORK/layout.dmg" >/dev/null
MOUNTED=1
[ -d "$MOUNT" ] || { echo "error: the image didn't mount at $MOUNT" >&2; exit 1; }
# The picture goes in first, as scripts/release-dmg.sh puts it. Finder keeps the icons' places by
# name, so an empty Redlamp.app stands in for the app.
mkdir "$MOUNT/.background"
cp "$HERE/background.tiff" "$MOUNT/.background/"
mkdir -p "$MOUNT/Redlamp.app/Contents"
ln -s /Applications "$MOUNT/Applications"

for _ in $(seq 20); do
    [ "$(osascript -e 'tell application "Finder" to exists disk "Redlamp"')" = true ] && break
    sleep 0.5
done
# The bounds include the title bar, leaving 640 by 400 points inside.
osascript <<'EOF'
tell application "Finder"
    tell disk "Redlamp"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Redlamp.app" of container window to {160, 180}
        set position of item "Applications" of container window to {480, 180}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Finder writes .DS_Store a moment after the window closes.
for _ in $(seq 20); do
    [ -s "$MOUNT/.DS_Store" ] && break
    sleep 0.5
done
sleep 1
if ! grep -aq background.tiff "$MOUNT/.DS_Store" 2>/dev/null || ! grep -aq Iloc "$MOUNT/.DS_Store"; then
    echo "error: Finder's .DS_Store doesn't hold the picture and the icons' places" >&2
    exit 1
fi
cp "$MOUNT/.DS_Store" "$HERE/DS_Store"
xattr -c "$HERE/DS_Store"
echo "==> Saved the window's layout in $HERE/DS_Store"
