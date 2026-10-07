#!/usr/bin/env bash
#
# Fails when a release zip doesn't unpack to the app as it was signed:
#
# - it holds AppleDouble entries (`._*`, `__MACOSX/`), the extended attributes of the build's
#   files: Finder puts them back when it unpacks a download, and Gatekeeper on macOS 26 then
#   refuses to open the app as one it can't verify, while unzip and bsdtar write them into the
#   bundle as files, which breaks its seal;
# - unpacked by plain unzip, the app's signature doesn't verify;
# - with --notarized, the unpacked app carries no stapled ticket.
#
#   scripts/check-release-zip.sh build/release/Redlamp-<version>.zip [--notarized]

set -euo pipefail

ZIP="${1:?usage: check-release-zip.sh <zip> [--notarized]}"
NOTARIZED="${2:-}"
[ -f "$ZIP" ] || { echo "error: no zip at $ZIP" >&2; exit 1; }
[ -z "$NOTARIZED" ] || [ "$NOTARIZED" = --notarized ] || { echo "error: unknown option $NOTARIZED" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failed=0
entries="$(unzip -Z1 "$ZIP")"
doubles="$(grep -cE '(^|/)(\._|__MACOSX/)' <<<"$entries" || true)"
if [ "$doubles" != 0 ]; then
    echo "error: $doubles of the zip's $(wc -l <<<"$entries" | tr -d ' ') entries are AppleDouble files, the build's extended" >&2
    echo "       attributes; zip the app with ditto -c -k --norsrc --noextattr --noacl." >&2
    failed=1
fi

unzip -qq "$ZIP" -d "$WORK"
APP="$(find "$WORK" -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$APP" ] || { echo "error: the zip holds no app at its top level" >&2; exit 1; }
if ! verify="$(codesign --verify --deep --strict "$APP" 2>&1)"; then
    echo "error: unpacked by unzip, $(basename "$APP")'s signature doesn't verify:" >&2
    sed 's/^/  /' <<<"$verify" >&2
    failed=1
fi
if [ -n "$NOTARIZED" ]; then
    details="$(codesign -dvvv "$APP" 2>&1 || true)"
    if ! grep -qx 'Notarization Ticket=stapled' <<<"$details"; then
        echo "error: unpacked, $(basename "$APP") carries no stapled notarization ticket" >&2
        failed=1
    fi
fi

[ "$failed" = 0 ] || exit 1
echo "==> $(basename "$ZIP") holds no extended attributes and unzip unpacks it to an app whose signature verifies${NOTARIZED:+, its ticket stapled}."
