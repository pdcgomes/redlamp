#!/usr/bin/env bash
#
# Measures UI smoothness while dragging a slider: launches the app, drags a slider at
# 120 Hz for a few seconds (the --sweep harness in DebugPerformance.swift) and prints how
# busy the main thread was, and how long each frame took from its request to the editor.
# Only stops the instances it launched.
#
# usage: scripts/perf-sweep.sh [Debug|Release] [parameter] [script]
#   e.g. scripts/perf-sweep.sh Release exposure "select=3,panel=all"
#
# The script defaults to select=3,panel=all: every Develop panel open, as people edit.
# DERIVED_DATA picks the build directory (build/DerivedData). REPORT_DIR names the directory
# the run's reports go to (perf.txt, perf.json for scripts/perf-record.sh, profile.txt); without
# it each run makes its own under /tmp and removes it afterwards, so runs from other checkouts
# at the same time never take or delete each other's report. It can't contain whitespace.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
PARAMETER="${2:-exposure}"
SCRIPT="${3:-select=3,panel=all}"
FIXTURES="$ROOT/tests/fixtures/raw"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/Redlamp.app"
EXECUTABLE="$BUNDLE/Contents/MacOS/Redlamp"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme Redlamp -configuration "$CONFIGURATION" \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REDLAMP_PROFILING' -quiet
fi

if [[ -n "${REPORT_DIR:-}" ]]; then
    REPORT="$REPORT_DIR"
    mkdir -p "$REPORT"
    rm -f "$REPORT/perf.txt" "$REPORT/perf.json" "$REPORT/profile.txt"
else
    REPORT="$(mktemp -d /tmp/redlamp-perf.XXXXXX)"
    # Kept when there's a profile to read, or no report (its debug.log says why).
    [[ "${PROFILE:-0}" == "1" ]] || trap '[[ -f "$REPORT/perf.txt" ]] && rm -rf "$REPORT"' EXIT
fi

# Sidecars are packages (directories), so -delete alone would leave them and their edits.
remove_sidecars() { find "$FIXTURES" -name '*.redlamp' -prune -exec rm -rf {} +; }

caffeinate -u -d -w $$ &
remove_sidecars

# Launched through LaunchServices (in the background, without taking focus): a process
# started straight from a non-GUI shell may never get a window.
BEFORE="$(pgrep -f "$EXECUTABLE" || true)"
PROFILE_FLAG=""
[[ "${PROFILE:-0}" == "1" ]] && PROFILE_FLAG="--sweep-profile"
# PROFILE_FOCUS=<mangled symbol substring> also lists what that function spends time in.
[[ -n "$PROFILE_FLAG" && -n "${PROFILE_FOCUS:-}" ]] && PROFILE_FLAG="$PROFILE_FLAG --sweep-profile-focus $PROFILE_FOCUS"
# PANELS=swiftui measures the SwiftUI Develop panels instead of the AppKit ones.
PANELS_FLAG=""
[[ "${PANELS:-appkit}" == "swiftui" ]] && PANELS_FLAG="--swiftui-panels"
echo "$FIXTURES --perf-report $REPORT --script $SCRIPT --sweep $PARAMETER --sweep-seconds 3 --sweep-quit $PROFILE_FLAG $PANELS_FLAG" >/tmp/redlamp-launch-args
open -n -g "$BUNDLE"
PID=""
for _ in $(seq 1 80); do
    sleep 0.5
    [[ -z "$PID" ]] && PID="$(pgrep -f "$EXECUTABLE" | grep -vxF "${BEFORE:-none}" | head -1 || true)"
    [[ -f "$REPORT/perf.txt" ]] && break
done
sleep 0.5
[[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
remove_sidecars

echo "== $CONFIGURATION · $PARAMETER · $SCRIPT · ${PANELS:-appkit} panels"
cat "$REPORT/perf.txt" 2>/dev/null || echo "(no report: the app did not finish the sweep; see $REPORT/debug.log)"
if [[ -n "$PROFILE_FLAG" && -f "$REPORT/profile.txt" ]]; then
    xcrun swift-demangle --simplified <"$REPORT/profile.txt" >"$REPORT/profile-demangled.txt"
    echo "main-thread profile: $REPORT/profile-demangled.txt"
fi
[[ -f "$REPORT/perf.txt" ]]
