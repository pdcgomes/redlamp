#!/bin/bash
#
# Measures Redlamp on this Mac for its performance history, as scripts/perf-record.sh does in the
# repository: redlamp bench on the sample raws, the slider sweep and the folders run on 50,000
# photos, and the decode service's figures for DATA-17. Needs only Terminal: no Xcode, no Python,
# no repository. The results are one zip in results/, to send back.
#
# usage: bash run.sh
#
# RUNS sets the repetitions per bench measurement (7). It waits up to SETTLE_MINUTES (15) for the
# one-minute load average to fall to SETTLE_LOAD (3). FOLDERS is the photo tree for the folders
# runs (/tmp/rl-fixture-50k.noindex, made on the first run from FOLDER_COUNT (500) folders of
# PER_FOLDER (100) clones of one sample); WARM is how many thumbnails are warmed (3000).
# SKIP_SWEEP=1, SKIP_FOLDERS=1 and SKIP_DECODER=1 leave those runs out.
#
# The kit's app has its own bundle ID, so its preferences and saved state are its own, and runs in
# a home of its own (CFFIXED_USER_HOME), since Application Support/Redlamp and Caches/app.redlamp
# don't follow the bundle ID: an installed Redlamp's files are never read or written.

set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Redlamp Perf Kit.app"
WORK="${WORK:-/tmp/redlamp-perf-kit}"
FOLDERS="${FOLDERS:-/tmp/rl-fixture-50k.noindex}"
RUNS="${RUNS:-7}"
WARM="${WARM:-3000}"
STAMP="$(date +%Y%m%d-%H%M%S)"

rm -rf "$WORK"
mkdir -p "$WORK/home" "$WORK/reports" "$KIT/results"
LOG="$WORK/reports/run.log"
exec > >(tee -a "$LOG") 2>&1

load() { sysctl -n vm.loadavg | awk '{print $2}'; }
note_load() { echo "$(date +%H:%M:%S) $1: $(sysctl -n vm.loadavg)" | tee -a "$WORK/reports/loads.txt" >/dev/null; }
above() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

echo "== Redlamp performance kit, $(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$KIT/kit.json")"
# AirDrop and the Finder's unzipping mark every file; macOS would refuse to run the app's code.
xattr -dr com.apple.quarantine "$KIT" 2>/dev/null || true

# Run from copies on this Mac's own disk (clones, where it can), outside Downloads and its
# privacy prompts.
ditto "$KIT/$APP_NAME" "$WORK/$APP_NAME"
mkdir -p "$WORK/fixtures"
for raw in "$KIT/fixtures/"*; do
    cp -c "$raw" "$WORK/fixtures/" 2>/dev/null || cp "$raw" "$WORK/fixtures/"
done
APP="$WORK/$APP_NAME"
EXE="$APP/Contents/MacOS/Redlamp"
CLI="$APP/Contents/Helpers/redlamp"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
# The clean-up at the end deletes under ~/Library by this ID, so only the kit's own will do.
[[ "$BUNDLE_ID" == app.redlamp.mac.perfkit ]] || {
    echo "run.sh: the app's bundle ID is '$BUNDLE_ID', not the kit's app.redlamp.mac.perfkit" >&2
    exit 1
}
COMMIT="$(plutil -extract RedlampCommit raw "$APP/Contents/Info.plist")"

# What an installed Redlamp keeps, to check afterwards that nothing in it changed.
INSTALLED=(
    "$HOME/Library/Preferences/app.redlamp.mac.plist"
    "$HOME/Library/Application Support/Redlamp"
    "$HOME/Library/Caches/app.redlamp"
    "$HOME/Library/Caches/app.redlamp.mac"
    "$HOME/Library/Saved Application State/app.redlamp.mac.savedState"
)
touch "$WORK/started"

LOAD_LIMIT="${SETTLE_LOAD:-3}"
WAITED=0
note_load "start"
echo "== load average: $(sysctl -n vm.loadavg)"
while above "$(load)" "$LOAD_LIMIT" && ((WAITED < ${SETTLE_MINUTES:-15} * 60)); do
    echo "   waiting for the one-minute load average ($(load)) to fall to $LOAD_LIMIT; quit other apps meanwhile"
    sleep 15
    WAITED=$((WAITED + 15))
done
above "$(load)" "$LOAD_LIMIT" && echo "   still $(load) after $((WAITED / 60)) min: measuring anyway (the record will say how busy it was)"
caffeinate -i -d -w $$ &
LOAD_BEFORE="$(load)"
note_load "measuring"

# Runs the kit's app with `arguments` and its own report directory, until it writes perf.txt or
# `seconds` pass. Only stops the process it started.
launch() {
    local report=$1 seconds=$2 pid waited=0
    shift 2
    mkdir -p "$report"
    CFFIXED_USER_HOME="$WORK/home" "$EXE" "$@" --perf-report "$report" >"$report/app.log" 2>&1 &
    pid=$!
    while [[ ! -f "$report/perf.txt" ]] && kill -0 "$pid" 2>/dev/null && ((waited < seconds * 2)); do
        sleep 0.5
        waited=$((waited + 1))
    done
    sleep 1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [[ -f "$report/perf.txt" ]]; then
        cat "$report/perf.txt"
    else
        echo "   (no report: see $report/debug.log and app.log)"
    fi
}

echo "== redlamp bench ($RUNS runs)"
note_load "bench"
CFFIXED_USER_HOME="$WORK/home" "$CLI" bench --runs "$RUNS" "$WORK/fixtures/"* \
    >"$WORK/reports/bench.json" 2>"$WORK/reports/bench.log" || echo "   (bench failed: see bench.log)"

if [[ "${SKIP_SWEEP:-0}" != "1" ]]; then
    echo "== slider sweep"
    note_load "sweep"
    launch "$WORK/reports/sweep" 60 "$WORK/fixtures" --script "select=3,panel=all" --sweep exposure \
        --sweep-seconds 3 --sweep-quit
    find "$WORK/fixtures" -name '*.redlamp' -prune -exec rm -rf {} +
fi

if [[ "${SKIP_FOLDERS:-0}" != "1" || "${SKIP_DECODER:-0}" != "1" ]] && [[ ! -d "$FOLDERS" ]]; then
    echo "== making the photo tree at $FOLDERS (APFS clones: no extra disk space)"
    bash "$KIT/tools/make-folder-fixture.sh" "$FOLDERS" "${FOLDER_COUNT:-500}" "${PER_FOLDER:-100}" \
        "$WORK/fixtures/_DSC0009.ARW"
fi
if [[ "${SKIP_FOLDERS:-0}" != "1" ]]; then
    echo "== folders run (the decode service not started)"
    note_load "folders"
    launch "$WORK/reports/folders" 240 --folders-perf "$FOLDERS" --folders-perf-warm "$WARM" --folders-perf-quit
fi
if [[ "${SKIP_DECODER:-0}" != "1" ]]; then
    echo "== folders run with the decode service started at launch, then a minute idle"
    note_load "decoder"
    launch "$WORK/reports/decoder" 360 --folders-perf "$FOLDERS" --folders-perf-warm "$WARM" \
        --folders-perf-decoder --folders-perf-decoder-idle 60 --folders-perf-quit
    grep "^Decode service" "$WORK/reports/decoder/perf.txt" 2>/dev/null || true
fi

LOAD_AFTER="$(load)"
note_load "done"
echo "== load average after: $(sysctl -n vm.loadavg)"

CHANGED="$(find "${INSTALLED[@]}" -newer "$WORK/started" 2>/dev/null || true)"
OTHERS="$(pgrep -fl "/Contents/MacOS/Redlamp" | grep -vF "$APP_NAME" || true)"
{
    if [[ -z "$CHANGED" ]]; then
        echo "An installed Redlamp's preferences, Application Support and caches: unchanged."
    else
        echo "Changed during the run, $(wc -l <<<"$CHANGED" | tr -d ' ') files (the kit writes only in $WORK/home):"
        echo "$CHANGED"
    fi
    [[ -z "$OTHERS" ]] || printf 'Other Redlamps running at the end:\n%s\n' "$OTHERS"
} >"$WORK/reports/isolation.txt"
head -3 "$WORK/reports/isolation.txt"
# Preferences go to the real home whatever CFFIXED_USER_HOME says; they're under the kit's own ID.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
    "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID"

CHIP="$(sysctl -n machdep.cpu.brand_string)"
MODEL="$(sysctl -n hw.model)"
OFFSET="$(date +%z)"
cat >"$WORK/reports/facts.json" <<EOF
{"date": "$(date +%Y-%m-%dT%H:%M:%S)${OFFSET:0:3}:${OFFSET:3:2}", "commit": "$COMMIT", "chip": "$CHIP",
 "model": "$MODEL", "memoryGB": $(($(sysctl -n hw.memsize) / 1073741824)), "macOS": "$(sw_vers -productVersion)",
 "loadBefore": $LOAD_BEFORE, "loadAfter": $LOAD_AFTER, "waitedSeconds": $WAITED}
EOF
cp "$KIT/kit.json" "$WORK/reports/kit.json"
echo "== record: $(osascript -l JavaScript "$KIT/tools/record.js" "$WORK/reports/record.json" "$KIT/kit.json" \
    "$WORK/reports/facts.json" "$WORK/reports/bench.json" "$WORK/reports/sweep/perf.json" \
    "$WORK/reports/folders/perf.json" "$WORK/reports/decoder/perf.json" 2>&1)"

NAME="redlamp-perf-$MODEL-$(tr -cs 'A-Za-z0-9' '-' <<<"${CHIP#Apple }" | sed 's/-$//')-$STAMP"
echo "== results: $KIT/results/$NAME.zip"
mv "$WORK/reports" "$WORK/$NAME"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$WORK/$NAME" "$KIT/results/$NAME.zip"
echo "Done. Send back results/$NAME.zip (AirDrop it to the Mac it came from)."
