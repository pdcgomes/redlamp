#!/usr/bin/env bash
#
# A measurement kit for another Mac, and the import of what it measured into
# docs/performance/history.jsonl, as that Mac's own series.
#
#   scripts/perf-kit.sh [output directory (build/perf-kit)]
#     Builds a kit from the current commit: the Release app with REDLAMP_PROFILING as
#     "Redlamp Perf Kit.app" under its own bundle ID (signed again for that ID), the Release
#     redlamp CLI inside it, the CC0 sample raws perf-record.sh measures, make-folder-fixture.sh
#     and run.sh (scripts/perf-kit/run.sh), zipped to send by AirDrop. On the other Mac,
#     `bash run.sh` in Terminal measures and leaves one zip in the kit's results/.
#   scripts/perf-kit.sh import <results zip> [--apply]
#     Checks that the zip's record names the kit's commit and prints how it compares with the
#     previous record from the same chip; --apply appends it.
#
# SKIP_BUILD=1 reuses the last builds; DERIVED_DATA picks the build directory (build/DerivedData).
# The working tree must be clean (ALLOW_DIRTY=1 builds it anyway), since the record names a commit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "import" ]]; then
    ZIP="${2:?usage: scripts/perf-kit.sh import <results zip> [--apply]}"
    UNPACKED="$(mktemp -d)"
    trap 'rm -rf "$UNPACKED"' EXIT
    ditto -x -k "$ZIP" "$UNPACKED"
    RECORD="$(find "$UNPACKED" -name record.json | head -1)"
    KIT_JSON="$(find "$UNPACKED" -name kit.json | head -1)"
    [[ -n "$RECORD" && -n "$KIT_JSON" ]] || { echo "no record.json and kit.json in $ZIP" >&2; exit 2; }
    COMMIT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["commit"])' "$KIT_JSON")"
    exec scripts/perf-history.py import "$RECORD" --commit "$COMMIT" ${3:+"$3"}
fi

OUT="${1:-$ROOT/build/perf-kit}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
PRODUCTS="$DERIVED_DATA/Build/Products/Release"
BUNDLE_ID=app.redlamp.mac.perfkit
COMMIT="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" && "${ALLOW_DIRTY:-0}" != "1" ]]; then
    echo "uncommitted changes: the kit's record would name $COMMIT without them (ALLOW_DIRTY=1 to build anyway)" >&2
    exit 2
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build -workspace Redlamp.xcworkspace -scheme Redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REDLAMP_PROFILING' REDLAMP_COMMIT="$COMMIT" -quiet
    xcodebuild build -workspace Redlamp.xcworkspace -scheme redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" -quiet
fi
[[ "$(plutil -extract RedlampCommit raw "$PRODUCTS/Redlamp.app/Contents/Info.plist")" == "$COMMIT" ]] \
    || { echo "the app in $PRODUCTS wasn't built from $COMMIT: build it again (without SKIP_BUILD)" >&2; exit 2; }

NAME="redlamp-perf-kit-$COMMIT"
KIT="$OUT/$NAME"
APP="$KIT/Redlamp Perf Kit.app"
rm -rf "$KIT" "$KIT.zip"
mkdir -p "$KIT/fixtures" "$KIT/tools" "$KIT/results"
ditto "$PRODUCTS/Redlamp.app" "$APP"
# The CLI shares the app's frameworks (its rpath includes @executable_path/../Frameworks), as in a release.
mkdir -p "$APP/Contents/Helpers"
ditto "$PRODUCTS/redlamp" "$APP/Contents/Helpers/redlamp"
# No update feed: the kit never updates itself.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName Redlamp Perf Kit" \
    -c "Set :SUFeedURL ''" "$APP/Contents/Info.plist"
IDENTITY="${REDLAMP_SIGN_IDENTITY:-$(codesign -dvv "$PRODUCTS/Redlamp.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" --preserve-metadata=entitlements,flags --timestamp=none \
    "$APP/Contents/Helpers/redlamp"
# Not the build's requirements: they name app.redlamp.mac, so the copy wouldn't meet its own.
codesign --force --sign "${IDENTITY:--}" --preserve-metadata=entitlements,flags --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
grep -q 'usage: redlamp' <<<"$("$APP/Contents/Helpers/redlamp" 2>&1 || true)" \
    || { echo "the kit's CLI doesn't run (missing frameworks?)" >&2; exit 1; }

for raw in tests/fixtures/raw/*; do
    case "${raw##*.}" in
        ARW | arw | CR2 | cr2 | CR3 | cr3 | NEF | nef | RAF | raf | DNG | dng | ORF | orf | RW2 | rw2 | PEF | pef)
            cp -c "$raw" "$KIT/fixtures/"
            ;;
    esac
done
cp scripts/make-folder-fixture.sh scripts/perf-kit/record.js "$KIT/tools/"
cp scripts/perf-kit/run.sh "$KIT/run.sh"
chmod +x "$KIT/run.sh" "$KIT/tools/make-folder-fixture.sh"
python3 - "$KIT/kit.json" "$COMMIT" "$BUNDLE_ID" <<'PY'
import datetime, json, subprocess, sys
path, commit, bundle = sys.argv[1:]
subject = subprocess.run(["git", "log", "-1", "--format=%s", commit], capture_output=True, text=True).stdout.strip()
json.dump({"commit": commit, "subject": subject, "bundleID": bundle,
           "built": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}, open(path, "w"), indent=2)
PY
cat >"$KIT/README.txt" <<EOF
Redlamp performance kit, built from $COMMIT.

In Terminal:
    cd ~/Downloads/$NAME
    bash run.sh

It waits for the Mac to be quiet, measures for about 10 minutes (the first run also makes a
folder of 50,000 photos in /tmp, as clones that take no space), and leaves one zip in results/.
AirDrop that zip back. The kit leaves an installed Redlamp's settings, files and caches alone.
EOF

ditto -c -k --keepParent "$KIT" "$KIT.zip"
echo "made $KIT ($(du -sh "$KIT" | cut -f1)), zipped as $KIT.zip ($(du -sh "$KIT.zip" | cut -f1))"
