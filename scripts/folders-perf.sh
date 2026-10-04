#!/usr/bin/env bash
#
# Checks the folders performance contract and memory budgets: launches a Release build on a tree
# of photos (scripts/make-folder-fixture.sh) with --folders-perf (DebugFoldersPerformance.swift),
# prints its report and fails when a budget isn't met. Only stops the instance it launched.
#
# usage: scripts/folders-perf.sh [folder] [extra flags...]
#   e.g. scripts/folders-perf.sh /tmp/rl-fixture-50k.noindex --folders-perf-memory
#
# SKIP_BUILD=1 reuses the last build; DERIVED_DATA picks the build directory (build/DerivedData);
# WARM sets how many thumbnails are warmed (3000); APP_ENV="NAME=value ..." sets environment
# variables in the app (through `open --env`).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLDER="${1:-/tmp/rl-fixture-50k.noindex}"
shift || true
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
BUNDLE="$DERIVED_DATA/Build/Products/Release/Redlamp.app"
EXECUTABLE="$BUNDLE/Contents/MacOS/Redlamp"

if [[ ! -d "$FOLDER" ]]; then
    echo "No photos at $FOLDER: make them with scripts/make-folder-fixture.sh $FOLDER" >&2
    exit 2
fi
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme Redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REDLAMP_PROFILING' -quiet
fi

rm -f /tmp/redlamp-perf.txt /tmp/redlamp-perf.json /tmp/redlamp-memory.txt
ENV_FLAGS=()
for assignment in ${APP_ENV:-}; do
    ENV_FLAGS+=(--env "$assignment")
done

# Launched through LaunchServices (in the background, without taking focus): a process started
# straight from a non-GUI shell may never get a window.
BEFORE="$(pgrep -f "$EXECUTABLE" || true)"
echo "--folders-perf $FOLDER --folders-perf-warm ${WARM:-3000} --folders-perf-quit $*" >/tmp/redlamp-launch-args
echo "== load average before: $(sysctl -n vm.loadavg)"
open -n -g ${ENV_FLAGS[@]+"${ENV_FLAGS[@]}"} "$BUNDLE"
PID=""
for _ in $(seq 1 360); do
    sleep 0.5
    [[ -z "$PID" ]] && PID="$(pgrep -f "$EXECUTABLE" | grep -vxF "${BEFORE:-none}" | head -1 || true)"
    [[ -f /tmp/redlamp-perf.txt ]] && break
done
sleep 1
[[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true

if [[ ! -f /tmp/redlamp-perf.txt ]]; then
    echo "(no report: the app did not finish; see /tmp/redlamp-debug.log)" >&2
    exit 2
fi
cat /tmp/redlamp-perf.txt
if [[ -f /tmp/redlamp-memory.txt ]]; then
    echo
    cat /tmp/redlamp-memory.txt
fi
grep -q "^Budgets: all" /tmp/redlamp-perf.txt
