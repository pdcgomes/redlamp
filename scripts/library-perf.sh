#!/usr/bin/env bash
#
# Checks the library's budgets (LIB-04): builds the redlamp CLI in Release, makes a synthetic
# library with `redlamp library fixture` if there isn't one, then runs `redlamp library bench` on
# it once for each volume profile, printing each report, and fails when a budget isn't met
# (docs/plans/2026-10-05-library-design.md, The stress harness).
#
# usage: scripts/library-perf.sh
#
# FIXTURE is the library (/Volumes/SSD/redlamp-tmp/library-fixtures/lib-100k) and PHOTOS its size
# when it's made (100000); PROFILES the volume profiles to run, of ssd, spinning, nas, wifi and
# vpn ("ssd"); SKIP_BUILD=1 reuses the last build; DERIVED_DATA picks the build directory
# (build/DerivedData-library-perf); JSON_DIR keeps each profile's report there as JSON.
# COLD=1 keeps the library on a sparse APFS disk image beside FIXTURE (FIXTURE.sparseimage,
# mounted at FIXTURE.mount), detached and attached again before each run so that none of it is in
# the file cache. A fixture on its own volume holds copies of the raws it clones (_sources).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${FIXTURE:-/Volumes/SSD/redlamp-tmp/library-fixtures/lib-100k}"
FIXTURE="${FIXTURE%/}"
PHOTOS="${PHOTOS:-100000}"
PROFILES="${PROFILES:-ssd}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData-library-perf}"
REDLAMP="$DERIVED_DATA/Build/Products/Release/redlamp"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" -quiet
fi

LIBRARY="$FIXTURE"
if [[ "${COLD:-0}" == "1" ]]; then
    IMAGE="$FIXTURE.sparseimage"
    MOUNT="$FIXTURE.mount"
    LIBRARY="$MOUNT/$(basename "$FIXTURE")"
    attach() {
        hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "$MOUNT" "$IMAGE" >/dev/null
    }
    detach() {
        if mount | grep -qF " on $MOUNT ("; then
            hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
        fi
    }
    trap detach EXIT
    if [[ ! -f "$IMAGE" ]]; then
        mkdir -p "$(dirname "$IMAGE")"
        hdiutil create -size 200g -type SPARSE -fs APFS -volname "Redlamp library fixture" "$IMAGE" >/dev/null
    fi
    mkdir -p "$MOUNT"
    detach
    attach
fi

if [[ ! -f "$LIBRARY/manifest.json" ]]; then
    echo "== making $PHOTOS photos in $LIBRARY"
    "$REDLAMP" library fixture "$LIBRARY" --photos "$PHOTOS" --raw-sources "$ROOT/tests/fixtures/raw"
fi

echo "== load average before: $(sysctl -n vm.loadavg)"
FAILED=0
for PROFILE in $PROFILES; do
    if [[ "${COLD:-0}" == "1" ]]; then
        detach
        attach
    fi
    echo "== $PROFILE"
    ARGS=(library bench "$LIBRARY" --profile "$PROFILE")
    if [[ -n "${JSON_DIR:-}" ]]; then
        mkdir -p "$JSON_DIR"
        ARGS+=(--json "$JSON_DIR/library-$PROFILE.json")
    fi
    "$REDLAMP" "${ARGS[@]}" || FAILED=1
done
exit "$FAILED"
