#!/usr/bin/env bash
#
# Fails when the release's disk image doesn't hold the app as it was signed:
#
# - it holds anything but Redlamp.app and a link to /Applications, hidden files aside;
# - anything in the app carries an extended attribute: Finder copies them into /Applications, and
#   Gatekeeper on macOS 26 refuses an app tagged with the com.apple.provenance of the Mac that
#   made it (#333);
# - the app's signature doesn't verify, or the image's, once it's signed;
# - with --notarized, the image isn't signed, or the image or the app carries no stapled ticket.
#
#   scripts/check-release-dmg.sh build/release/Redlamp-<version>.dmg [--notarized]
#
# It mounts the image, which the agent's sandbox refuses.

set -euo pipefail

DMG="${1:?usage: check-release-dmg.sh <dmg> [--notarized]}"
NOTARIZED="${2:-}"
[ -f "$DMG" ] || { echo "error: no disk image at $DMG" >&2; exit 1; }
[ -z "$NOTARIZED" ] || [ "$NOTARIZED" = --notarized ] || { echo "error: unknown option $NOTARIZED" >&2; exit 1; }
IMAGE="$(basename "$DMG")"

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

failed=0
if codesign -d "$DMG" >/dev/null 2>&1; then
    if ! verify="$(codesign --verify --strict "$DMG" 2>&1)"; then
        echo "error: $IMAGE's signature doesn't verify:" >&2
        sed 's/^/  /' <<<"$verify" >&2
        failed=1
    fi
elif [ -n "$NOTARIZED" ]; then
    echo "error: $IMAGE isn't signed" >&2
    failed=1
fi
if [ -n "$NOTARIZED" ] && ! xcrun stapler validate -q "$DMG" >/dev/null 2>&1; then
    echo "error: $IMAGE carries no stapled notarization ticket" >&2
    failed=1
fi

mkdir "$MOUNT"
# hdiutil's -quiet hides its errors too, so only what it prints on success is dropped.
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
MOUNTED=1
entries="$(find "$MOUNT" -mindepth 1 -maxdepth 1 ! -name '.*' -exec basename {} \; | sort | tr '\n' ' ')"
if [ "$entries" != "Applications Redlamp.app " ] || [ "$(readlink "$MOUNT/Applications")" != /Applications ]; then
    echo "error: $IMAGE holds ${entries:-nothing }rather than Redlamp.app and a link to /Applications" >&2
    failed=1
fi
APP="$MOUNT/Redlamp.app"
if [ -d "$APP" ]; then
    attributes="$(xattr -rs "$APP" 2>&1 | sed -E 's/.*: //' | sort | uniq -c || true)"
    if [ -n "$attributes" ]; then
        echo "error: files in $IMAGE's app carry extended attributes, which Finder copies into /Applications:" >&2
        sed 's/^/  /' <<<"$attributes" >&2
        failed=1
    fi
    if ! verify="$(codesign --verify --deep --strict "$APP" 2>&1)"; then
        echo "error: in $IMAGE, Redlamp.app's signature doesn't verify:" >&2
        sed 's/^/  /' <<<"$verify" >&2
        failed=1
    fi
    if [ -n "$NOTARIZED" ] && ! grep -qx 'Notarization Ticket=stapled' <<<"$(codesign -dvvv "$APP" 2>&1 || true)"; then
        echo "error: in $IMAGE, Redlamp.app carries no stapled notarization ticket" >&2
        failed=1
    fi
fi

[ "$failed" = 0 ] || exit 1
echo "==> $IMAGE holds Redlamp.app beside a link to /Applications, with no extended attributes and its signature intact${NOTARIZED:+; the app and the image carry their tickets}."
