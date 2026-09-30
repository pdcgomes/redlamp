#!/usr/bin/env bash
#
# Screenshots a harness scene, for reviews and parity checks. Launches the harness in the
# background (without taking focus), captures its window and quits it. Needs Screen
# Recording permission for the terminal.
#
# usage: scripts/harness-capture.sh <scene-id> <out.png> [parity-mode] [harness arguments...]
#   e.g. scripts/harness-capture.sh parity-basic /tmp/basic.png difference
#        scripts/harness-capture.sh basic-panel /tmp/basic.png side --theme nord --tint 0.5

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENE="$1"
OUT="$2"
MODE="${3:-side}"
shift $(($# < 3 ? $# : 3))
EXTRA="$*"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE="$ROOT/build/DerivedData/Build/Products/$CONFIGURATION/RedlampHarness.app"
EXECUTABLE="$BUNDLE/Contents/MacOS/RedlampHarness"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme RedlampHarness -configuration "$CONFIGURATION" \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/DerivedData" -quiet
fi

caffeinate -u -d -w $$ &
echo "--scene $SCENE --parity-mode $MODE --background ${BACKGROUND:-black} $EXTRA" >/tmp/redlamp-harness-args
BEFORE="$(pgrep -f "$EXECUTABLE" || true)"
open -n -g "$BUNDLE"
PID=""
for _ in $(seq 1 40); do
    sleep 0.25
    PID="$(pgrep -f "$EXECUTABLE" | grep -vxF "${BEFORE:-none}" | head -1 || true)"
    [[ -n "$PID" ]] && break
done
sleep "${WAIT:-4}"
WINDOW="$(swift "$ROOT/scripts/window-id.swift" "$PID")"
screencapture -l "$WINDOW" -o -x "$OUT"
kill "$PID" 2>/dev/null || true
echo "$OUT"
