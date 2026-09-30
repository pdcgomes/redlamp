#!/usr/bin/env bash
#
# Measures UI smoothness while dragging a slider: launches the app, drags a slider at
# 120 Hz for a few seconds (the --sweep harness in DebugPerformance.swift) and prints how
# busy the main thread was. Only stops the instances it launched.
#
# usage: scripts/perf-sweep.sh [Debug|Release] [parameter] [script]
#   e.g. scripts/perf-sweep.sh Release exposure "select=3,panel=all"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
PARAMETER="${2:-exposure}"
SCRIPT="${3:-select=3}"
FIXTURES="$ROOT/tests/fixtures/raw"
BUNDLE="$ROOT/build/DerivedData/Build/Products/$CONFIGURATION/Redlamp.app"
EXECUTABLE="$BUNDLE/Contents/MacOS/Redlamp"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme Redlamp -configuration "$CONFIGURATION" \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/DerivedData" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REDLAMP_PROFILING' -quiet
fi

caffeinate -u -d -w $$ &
rm -f /tmp/redlamp-perf.txt
find "$FIXTURES" -name '*.redlamp' -delete

# Launched through LaunchServices (in the background, without taking focus): a process
# started straight from a non-GUI shell may never get a window.
BEFORE="$(pgrep -f "$EXECUTABLE" || true)"
PROFILE_FLAG=""
[[ "${PROFILE:-0}" == "1" ]] && PROFILE_FLAG="--sweep-profile" && rm -f /tmp/redlamp-profile.txt
# PROFILE_FOCUS=<mangled symbol substring> also lists what that function spends time in.
[[ -n "$PROFILE_FLAG" && -n "${PROFILE_FOCUS:-}" ]] && PROFILE_FLAG="$PROFILE_FLAG --sweep-profile-focus $PROFILE_FOCUS"
# PANELS=swiftui measures the SwiftUI Develop panels instead of the AppKit ones.
PANELS_FLAG=""
[[ "${PANELS:-appkit}" == "swiftui" ]] && PANELS_FLAG="--swiftui-panels"
echo "$FIXTURES --script $SCRIPT --sweep $PARAMETER --sweep-seconds 3 --sweep-quit $PROFILE_FLAG $PANELS_FLAG" >/tmp/redlamp-launch-args
open -n -g "$BUNDLE"
PID=""
for _ in $(seq 1 80); do
    sleep 0.5
    [[ -z "$PID" ]] && PID="$(pgrep -f "$EXECUTABLE" | grep -vxF "${BEFORE:-none}" | head -1 || true)"
    [[ -f /tmp/redlamp-perf.txt ]] && break
done
sleep 0.5
[[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
find "$FIXTURES" -name '*.redlamp' -delete

echo "== $CONFIGURATION · $PARAMETER · $SCRIPT · ${PANELS:-appkit} panels"
cat /tmp/redlamp-perf.txt 2>/dev/null || echo "(no report: the app did not finish the sweep)"
if [[ -n "$PROFILE_FLAG" && -f /tmp/redlamp-profile.txt ]]; then
    xcrun swift-demangle --simplified </tmp/redlamp-profile.txt >/tmp/redlamp-profile-demangled.txt
    echo "main-thread profile: /tmp/redlamp-profile-demangled.txt"
fi
