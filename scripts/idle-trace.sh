#!/usr/bin/env bash
#
# How often the canvas render threads wake while the app sits idle on a photo (RESP-12).
#
# Launches a test copy of the app (bundle ID app.redlamp.mac.idle, a home of its own, as
# scripts/e2e.py does) on one photo, leaves it untouched for SETTLE seconds, then records
# TRACE_SECONDS of Time Profiler and counts the samples on each thread. Time Profiler samples
# only threads that are running, so a thread asleep in its run loop has none: the count on the
# "Redlamp canvas" threads (the editor's canvas and the Navigator's, one each) is how much they
# woke. A canvas whose display link stays on the run loop while paused wakes about 5 to 6
# times a second and shows a hundred or more samples in 20 s; one whose link leaves the run
# loop when idle shows almost none. RESP-12's guard: under 10 samples on the canvas threads in
# 20 s.
#
#   scripts/idle-trace.sh                         # builds Release into build/DerivedData-idle
#   scripts/idle-trace.sh path/to/Redlamp.app     # a build made elsewhere
#   SETTLE=15 TRACE_SECONDS=20 PHOTO=tests/fixtures/raw/DSC_0750.NEF scripts/idle-trace.sh
#
# Prints one line per thread with samples (canvas threads first), the canvas total and the
# load average, and keeps the trace in build/idle-trace/<time>/. Exits 1 if the app doesn't
# start or the trace can't be recorded. Needs the screen unlocked, so the window shows and its
# canvas renders; run it under the app lock (audit.py exclusive app) beside other sessions.
# Inside a sandboxed agent shell xctrace fails with "Could not set the recording priority":
# run it from a Terminal of your own.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTLE="${SETTLE:-15}"
TRACE_SECONDS="${TRACE_SECONDS:-20}"
PHOTO="${PHOTO:-$ROOT/tests/fixtures/raw/DSC_0750.NEF}"
BUNDLE_ID=app.redlamp.mac.idle
NAME="Redlamp Idle"
RUN="$ROOT/build/idle-trace/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"

if [[ $# -ge 1 ]]; then
    BUILT="$1"
else
    DERIVED="${DERIVED:-$ROOT/build/DerivedData-idle}"
    echo "==> Building Release into $DERIVED"
    xcodebuild build -workspace "$ROOT/Redlamp.xcworkspace" -scheme Redlamp -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -quiet
    BUILT="$DERIVED/Build/Products/Release/Redlamp.app"
fi
[[ -d "$BUILT" ]] || { echo "no app at $BUILT" >&2; exit 1; }
[[ -f "$PHOTO" ]] || { echo "no photo at $PHOTO" >&2; exit 1; }

# The copy under its own bundle ID has defaults of its own; signed again as the build was, so
# its frameworks still load.
APP="$RUN/$NAME.app"
ditto "$BUILT" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName $NAME" "$APP/Contents/Info.plist"
IDENTITY="${REDLAMP_SIGN_IDENTITY:-$(codesign -dvv "$BUILT" 2>&1 | sed -n 's/^Authority=//p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" --preserve-metadata=entitlements,flags --timestamp=none "$APP" 2>/dev/null

defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" welcome.shown -int 99
mkdir -p "$RUN/home" "$RUN/photos"
cp -c "$PHOTO" "$RUN/photos/"

echo "==> Opening $(basename "$PHOTO"); load average $(sysctl -n vm.loadavg)"
CFFIXED_USER_HOME="$RUN/home" "$APP/Contents/MacOS/Redlamp" "$RUN/photos/$(basename "$PHOTO")" \
    > "$RUN/app.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || { echo "the app quit; see $RUN/app.log" >&2; exit 1; }

echo "==> Recording $TRACE_SECONDS s of Time Profiler (pid $PID)"
xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit "${TRACE_SECONDS}s" \
    --output "$RUN/idle.trace" --no-prompt > "$RUN/xctrace.log" 2>&1 \
    || { echo "xctrace couldn't record; see $RUN/xctrace.log" >&2; exit 1; }
! grep -q "Recording failed" "$RUN/xctrace.log" \
    || { echo "xctrace couldn't record; see $RUN/xctrace.log" >&2; exit 1; }
xcrun xctrace export --input "$RUN/idle.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$RUN/samples.xml"

LOAD="$(sysctl -n vm.loadavg)"
python3 - "$RUN/samples.xml" "$TRACE_SECONDS" "$LOAD" <<'PY'
import collections
import re
import sys
import xml.etree.ElementTree as ElementTree

path, seconds, load = sys.argv[1], sys.argv[2], sys.argv[3]
# Later rows refer back to a thread written out in full earlier, by its id.
names, counts = {}, collections.Counter()
for row in ElementTree.parse(path).getroot().iter("row"):
    thread = row.find("thread")
    if thread is None:
        continue
    if "ref" in thread.attrib:
        name = names.get(thread.attrib["ref"], "?")
    else:
        name = re.sub(r"\s+0x[0-9a-f]+.*$", "", thread.attrib.get("fmt", "?")).strip() or "?"
        names[thread.attrib.get("id")] = name
    counts[name] += 1
canvas = sum(count for name, count in counts.items() if "Redlamp canvas" in name)
for name, count in sorted(counts.items(), key=lambda item: ("Redlamp canvas" not in item[0], -item[1])):
    print(f"{count:6d}  {name}")
print(f"canvas threads: {canvas} samples in {seconds} s (guard: under 10); total {sum(counts.values())}; "
      f"load average {load}")
PY
echo "==> Trace kept in $RUN"
