#!/usr/bin/env bash
#
# Makes the disk image redlamp.app's download button offers: Redlamp.app beside a link to
# /Applications, so that dragging it there is the obvious step. Sparkle won't update a copy that
# runs from the image, or from Downloads, where a zip unpacks. Its window takes its picture and
# Finder's layout from scripts/dmg (background.tiff and DS_Store; scripts/dmg/layout.sh).
#
# Whatever runs the release can tag each file it writes with com.apple.provenance. A disk image
# keeps the tags, Finder copies them into /Applications, and Gatekeeper on macOS 26 then refuses
# the app (#333). So the app is copied into a read-write image and cleared of extended attributes
# there, and the compressed image is converted from it block for block, so nothing in it is
# written again.
#
#   scripts/release-dmg.sh build/release/Redlamp.app build/release/Redlamp-<version>.dmg
#
# It mounts the image, which the agent's sandbox refuses.

set -euo pipefail

APP="${1:?usage: release-dmg.sh <Redlamp.app> <dmg>}"
DMG="${2:?usage: release-dmg.sh <Redlamp.app> <dmg>}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
NAME="$(basename "$APP")"
LAYOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dmg"
for file in background.tiff DS_Store; do
    [ -f "$LAYOUT/$file" ] || { echo "error: no $LAYOUT/$file (scripts/dmg/layout.sh)" >&2; exit 1; }
done

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = 1 ]; then
        hdiutil detach -force "$MOUNT" >/dev/null || return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# hdiutil's -quiet hides its errors too, so only what it prints on success is dropped.
# The app, a fifth more and 20 MB for the file system's own structures.
KB="$(du -sk "$APP" | cut -f1)"
hdiutil create -size "$((KB * 6 / 5 + 20480))k" -fs HFS+ -volname Redlamp "$WORK/image.dmg" >/dev/null
mkdir "$MOUNT"
hdiutil attach -nobrowse -noautoopen -noverify -mountpoint "$MOUNT" "$WORK/image.dmg" >/dev/null
MOUNTED=1
# The picture goes in first, as scripts/dmg/layout.sh puts it, and the window's layout last.
mkdir "$MOUNT/.background"
cp "$LAYOUT/background.tiff" "$MOUNT/.background/"
ditto --norsrc --noextattr --noacl "$APP" "$MOUNT/$NAME"
ln -s /Applications "$MOUNT/Applications"
cp "$LAYOUT/DS_Store" "$MOUNT/.DS_Store"
xattr -crs "$MOUNT/$NAME" "$MOUNT/Applications" "$MOUNT/.background" "$MOUNT/.DS_Store"
# Spotlight and fseventsd can hold a volume they've just found for a moment.
for _ in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT" >/dev/null 2>&1; then
        MOUNTED=0
        break
    fi
    sleep 2
done
if [ "$MOUNTED" = 1 ]; then
    hdiutil detach -force "$MOUNT" >/dev/null
    MOUNTED=0
fi
hdiutil convert "$WORK/image.dmg" -format ULMO -ov -o "$DMG" >/dev/null
echo "==> Made $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
