#!/usr/bin/env bash
#
# Records one performance run into docs/performance/history.jsonl: builds the redlamp CLI in
# Release and runs `redlamp bench` on the CC0 fixtures, then the slider sweep (perf-sweep.sh) and,
# when the 50,000-photo fixture exists, the folders run (folders-perf.sh), and prints what changed
# since the previous comparable run. Commit the new line with the change it measures.
#
# Measure on a quiet Mac: a run whose load average exceeds 8 is recorded as noisy and never
# compared. The page at redlamp.app/performance draws the history.
#
# usage: scripts/perf-record.sh
#
# RUNS sets the repetitions per measurement (7); DERIVED_DATA the build directory
# (build/DerivedData); SKIP_BUILD=1 reuses the last builds; SKIP_SWEEP=1 and SKIP_FOLDERS=1 leave
# those runs out; FOLDERS is the photo tree for the folders run (/tmp/rl-fixture-50k.noindex, made
# by scripts/make-folder-fixture.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
FOLDERS="${FOLDERS:-/tmp/rl-fixture-50k.noindex}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

load() { sysctl -n vm.loadavg | awk '{print $2}'; }
LOAD_BEFORE="$(load)"
echo "== load average before: $LOAD_BEFORE"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "== building the redlamp CLI (Release)"
    xcodebuild build -workspace Redlamp.xcworkspace -scheme redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" -quiet
fi

echo "== redlamp bench"
"$DERIVED_DATA/Build/Products/Release/redlamp" bench --runs "${RUNS:-7}" >"$WORK/bench.json"

ARGS=(--bench "$WORK/bench.json")
if [[ "${SKIP_SWEEP:-0}" != "1" ]]; then
    echo "== slider sweep"
    if scripts/perf-sweep.sh Release exposure "select=3,panel=all" && [[ -f /tmp/redlamp-perf.json ]]; then
        cp /tmp/redlamp-perf.json "$WORK/sweep.json"
        ARGS+=(--sweep "$WORK/sweep.json")
    else
        echo "   (the sweep didn't finish; left out)"
    fi
fi
if [[ "${SKIP_FOLDERS:-0}" != "1" && -d "$FOLDERS" ]]; then
    echo "== folders run"
    if SKIP_BUILD="${SKIP_BUILD:-0}" scripts/folders-perf.sh "$FOLDERS" && [[ -f /tmp/redlamp-perf.json ]]; then
        cp /tmp/redlamp-perf.json "$WORK/folders.json"
        ARGS+=(--folders "$WORK/folders.json")
    else
        echo "   (the folders run didn't finish or missed a budget; left out)"
    fi
elif [[ "${SKIP_FOLDERS:-0}" != "1" ]]; then
    echo "== folders run skipped: no photos at $FOLDERS (scripts/make-folder-fixture.sh $FOLDERS)"
fi

LOAD_AFTER="$(load)"
echo "== load average after: $LOAD_AFTER"
scripts/perf-history.py append "${ARGS[@]}" --load-before "$LOAD_BEFORE" --load-after "$LOAD_AFTER"
