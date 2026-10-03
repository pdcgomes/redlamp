#!/usr/bin/env bash
# The redlamp CLI never writes over a photo: not its own input, not a raw file, not a JPEG it
# didn't write. It does replace its own earlier output.
#
#   scripts/check-cli-protection.sh [path/to/redlamp]
#
# Defaults to the Debug build (SCHEME=redlamp mise run build) and tests/fixtures/raw/_DSC0009.ARW.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
redlamp="${1:-build/DerivedData/Build/Products/Debug/redlamp}"
fixture="tests/fixtures/raw/_DSC0009.ARW"
[ -x "$redlamp" ] || { echo "no redlamp binary at $redlamp" >&2; exit 2; }
[ -f "$fixture" ] || { echo "no fixture at $fixture (mise run fixtures)" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$fixture" "$work/x.ARW"
sips -s format jpeg "$fixture" --out "$work/camera.jpg" >/dev/null

failures=0
hash() { shasum -a 256 "$1" | cut -d' ' -f1; }

refuses() {
    local target="$1"
    shift
    local before
    before="$(hash "$target")"
    if "$redlamp" "$@" >/dev/null 2>&1; then
        echo "FAIL: redlamp $* exited 0"
        failures=$((failures + 1))
    elif [ "$(hash "$target")" != "$before" ]; then
        echo "FAIL: redlamp $* changed $(basename "$target")"
        failures=$((failures + 1))
    else
        echo "ok: redlamp $* refused"
    fi
}

writes() {
    if "$redlamp" "$@" >/dev/null 2>&1; then
        echo "ok: redlamp $* wrote"
    else
        echo "FAIL: redlamp $* failed"
        failures=$((failures + 1))
    fi
}

refuses "$work/x.ARW" render "$work/x.ARW" --size 256 -o "$work/x.ARW"
refuses "$work/x.ARW" render "$work/x.ARW" --size 256 -o "$work/X.arw"
refuses "$work/camera.jpg" render "$work/x.ARW" --size 256 -o "$work/camera.jpg"
writes render "$work/x.ARW" --size 256 -o "$work/out.jpg"
writes render "$work/x.ARW" --size 256 -o "$work/out.jpg"
refuses "$work/out.jpg" recipe render "$work/out.jpg" --recipe essentials/punchy -o "$work/out.jpg"
refuses "$work/camera.jpg" recipe render "$work/camera.jpg" --recipe essentials/punchy -o "$work/camera.jpg"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "check-cli-protection: OK"
