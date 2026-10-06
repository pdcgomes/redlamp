#!/usr/bin/env bash
#
# Makes the draw-counting build for RESP-11: a Release build with REDLAMP_PROFILING, copied as
# "Redlamp Draw Counter.app" under its own bundle ID (so it has its own preferences and never
# takes the app's launch arguments) and signed again for that ID, beside a launcher that opens
# it on copies of two fixtures with --count-graph-draws (DebugDrawCounter.swift). Double-click
# the launcher, or run it in Terminal; the log goes to /tmp/redlamp-draw-counter/.
#
# usage: scripts/draw-counter.sh [output directory (build/draw-counter)]
#
# SKIP_BUILD=1 reuses the last build; DERIVED_DATA picks the build directory (build/DerivedData).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/draw-counter}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
BUILT="$DERIVED_DATA/Build/Products/Release/Redlamp.app"
BUNDLE_ID=app.redlamp.mac.drawcounter
APP="$OUT/Redlamp Draw Counter.app"
FIXTURES="$ROOT/tests/fixtures/raw"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme Redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REDLAMP_PROFILING' -quiet
fi

mkdir -p "$OUT"
rm -rf "$APP"
ditto "$BUILT" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName Redlamp Draw Counter" \
    "$APP/Contents/Info.plist"
IDENTITY="${REDLAMP_SIGN_IDENTITY:-$(codesign -dvv "$BUILT" 2>&1 | sed -n 's/^Authority=//p' | head -1)}"
# Not the build's requirements: they name app.redlamp.mac, so the copy wouldn't meet its own and
# macOS would ask again on every launch for the file access it was given.
codesign --force --sign "${IDENTITY:--}" --preserve-metadata=entitlements,flags --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

LAUNCHER="$OUT/Launch Draw Counter.command"
cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Opens Redlamp Draw Counter on copies of two photos, counting the graphs' draws.
set -euo pipefail
PHOTOS=/tmp/redlamp-draw-counter/photos
mkdir -p "\$PHOTOS"
cp -n "$FIXTURES/_DSC0009.ARW" "$FIXTURES/DSC_0750.NEF" "\$PHOTOS/" 2>/dev/null || true
defaults write $BUNDLE_ID welcome.shown -int 99
echo "\$PHOTOS --script select=0 --count-graph-draws" >/tmp/$BUNDLE_ID-launch-args
open -n "$APP"
sleep 3
echo "Redlamp Draw Counter is open. Its log: \$(ls -t /tmp/redlamp-draw-counter/draws-*.log 2>/dev/null | head -1)"
EOF
chmod +x "$LAUNCHER"
echo "made $APP"
echo "launch it with: $LAUNCHER"
