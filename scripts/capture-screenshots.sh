#!/usr/bin/env bash
#
# Regenerates the README screenshots in docs/images from the Debug app, using the CC0
# fixtures in tests/fixtures/raw (fetch them with `mise run fixtures`).
#
# Each shot launches the app with a `--script` of scripted edits, waits for the render,
# and captures the real window with screencapture. The terminal running this needs the
# Screen Recording permission.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/Redlamp.app/Contents/MacOS/Redlamp"
FIXTURES="$ROOT/tests/fixtures/raw"
OUT="$ROOT/docs/images"
WAIT="${WAIT:-9}"

[[ -x "$APP" ]] || { echo "error: build the app first (mise run build)" >&2; exit 1; }

# A sleeping display has no windows to capture; keep it awake for the whole run.
caffeinate -u -d -w $$ &
[[ -d "$FIXTURES" ]] || { echo "error: fetch fixtures first (mise run fixtures)" >&2; exit 1; }
mkdir -p "$OUT"

clean_sidecars() { find "$FIXTURES" -name '*.redlamp' -delete; }

capture() {
    local name="$1" script="$2"
    pkill -x Redlamp 2>/dev/null || true
    sleep 1
    clean_sidecars
    "$APP" "$FIXTURES" --script "$script" >/dev/null 2>&1 &
    local pid=$!
    sleep "$WAIT"
    local id
    id="$(swift "$ROOT/scripts/window-id.swift" "$pid")"
    screencapture -x -o -l "$id" "$OUT/$name.png"
    sips -Z 1800 "$OUT/$name.png" >/dev/null
    kill "$pid" 2>/dev/null || true
    echo "==> $OUT/$name.png"
}

# Fixture order in the filmstrip: 0 Sony ARW, 1 Fujifilm RAF, 2 Canon CR3, 3 Nikon NEF, 4 iPhone DNG.
capture editor "select=3,panel=basic+toneCurve,exposure=0.45,highlights=-40,shadows=35,vibrance=20,gradeShadowsHue=210,gradeShadowsSaturation=30,gradeHighlightsHue=45,gradeHighlightsSaturation=22,vignetteAmount=-25"
capture color-grading "select=2,panel=colorGrading,exposure=0.2,contrast=15,gradeShadowsHue=200,gradeShadowsSaturation=40,gradeMidtonesHue=30,gradeMidtonesSaturation=12,gradeHighlightsHue=50,gradeHighlightsSaturation=30"
capture black-and-white "select=0,panel=basic,preset=bw.selenium,vignetteAmount=-30,grainAmount=25"
capture zoom-xtrans "select=1,panel=colorMixer,zoom=1:1,vibrance=15"
capture proraw "select=4,panel=basic+colorMixer,exposure=0.15,highlights=-50,shadows=25,vibrance=30,saturationBlue=15,luminanceBlue=-20"
capture masking "select=0,tool=masking,linear=0.5:0.02:0.5:0.42,localExposure=-1.3,localTemperature=-30,localSaturation=25,radial=0.72:0.62:0.3:0.22:70,localExposure=0.9,localTemperature=30"

pkill -x Redlamp 2>/dev/null || true
clean_sidecars
