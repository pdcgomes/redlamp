#!/usr/bin/env bash
#
# Regenerates the README and website screenshots in docs/images from the Debug app and the harness
# (`ONLY="editor film-catalog"` regenerates just those),
# using the CC0 fixtures in tests/fixtures/raw (fetch them with `mise run fixtures`) and,
# for the Recipe Lab, the look-development set (`mise run lookdev`).
#
# Each app shot launches the app on a temporary copy of the fixtures with a `--script` of
# scripted edits, waits for the render, and captures the real window with screencapture, so
# sidecars in tests/fixtures are never touched. The terminal running this needs the Screen
# Recording permission.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$ROOT/build/DerivedData/Build/Products/Debug/Redlamp.app"
APP="$BUNDLE/Contents/MacOS/Redlamp"
OUT="$ROOT/docs/images"
WAIT="${WAIT:-9}"

[[ -x "$APP" ]] || { echo "error: build the app first (mise run build)" >&2; exit 1; }
[[ -d "$ROOT/tests/fixtures/raw" ]] || { echo "error: fetch fixtures first (mise run fixtures)" >&2; exit 1; }

# A sleeping display has no windows to capture; keep it awake for the whole run.
caffeinate -u -d -w $$ &
mkdir -p "$OUT"
FIXTURES="$(mktemp -d)/raw"
mkdir -p "$FIXTURES"
# Filmstrip order: 0 Sony ARW, 1 Fujifilm RAF, 2 Canon CR3, 3 Nikon NEF, 4 iPhone DNG.
for file in _DSC0009.ARW AFXT2720.RAF Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3 DSC_0750.NEF IMG_1361.DNG; do
    cp "$ROOT/tests/fixtures/raw/$file" "$FIXTURES/"
done
# The app's preferences are saved now and put back on exit, as capture-promo.sh does.
DOMAIN=app.redlamp.mac
PREFS="$(dirname "$FIXTURES")/preferences.plist"
defaults export "$DOMAIN" "$PREFS" 2>/dev/null || PREFS=""
restore() {
    pkill -f "$APP" 2>/dev/null || true
    sleep 1
    # Import merges, so clear the domain first: keys the run added, such as the last folder, go too.
    defaults delete "$DOMAIN" 2>/dev/null || true
    if [[ -n "$PREFS" ]]; then
        defaults import "$DOMAIN" "$PREFS"
    fi
    rm -rf "$(dirname "$FIXTURES")"
}
trap restore EXIT
# What would show in a shot goes too: the theme, the remembered folders (the Folders panel lists
# only the fixtures), the library's views (the filmstrip is in the order below) and the window's size.
for key in themeFamily themeAppearance themeTint themeTintsNativeControls panelTransparency \
    folders.roots folders.open folders.expanded folders.lastPhotos folders.subfolders lastFolder \
    library.views library.filters "NSWindow Frame editor"; do
    defaults delete "$DOMAIN" "$key" 2>/dev/null || true
done

capture() {
    local name="$1" script="$2" title="${3:-}"
    [[ -n "${ONLY:-}" && " $ONLY " != *" $name "* ]] && return 0
    pkill -f "$APP" 2>/dev/null || true
    sleep 1
    find "$FIXTURES" -name '*.redlamp' -delete
    # Launched through `open` (a process started from a non-GUI shell may never get a
    # window), with the arguments in the file beside the bundle that the app reads once on
    # launch, which no other checkout's launch can take.
    echo "$FIXTURES --window-size 1600x1000 --script $script" >"$(dirname "$BUNDLE")/redlamp-launch-args"
    open -n -g "$BUNDLE"
    local pid=""
    for _ in $(seq 1 40); do
        sleep 0.25
        pid="$(pgrep -f "$APP" | head -1 || true)"
        [[ -n "$pid" ]] && break
    done
    sleep "$WAIT"
    local id
    id="$(swift "$ROOT/scripts/window-id.swift" "$pid" ${title:+"$title"})"
    screencapture -x -o -l "$id" "$OUT/$name.png"
    sips -Z 1800 "$OUT/$name.png" >/dev/null
    kill "$pid" 2>/dev/null || true
    echo "==> $OUT/$name.png"
}

capture editor "select=3,panel=basic+toneCurve,exposure=0.45,highlights=-40,shadows=35,vibrance=20,gradeShadowsHue=210,gradeShadowsSaturation=30,gradeHighlightsHue=45,gradeHighlightsSaturation=22,vignetteAmount=-25"
capture color-grading "select=2,panel=colorGrading,exposure=0.2,contrast=15,gradeShadowsHue=200,gradeShadowsSaturation=40,gradeMidtonesHue=30,gradeMidtonesSaturation=12,gradeHighlightsHue=50,gradeHighlightsSaturation=30"
capture black-and-white "select=0,panel=basic,recipe=bw/selenium,vignetteAmount=-30,grainAmount=25"
capture zoom-xtrans "select=1,panel=colorMixer,zoom=1:1,vibrance=15"
capture proraw "select=4,panel=basic+colorMixer,exposure=0.15,highlights=-50,shadows=25,vibrance=30,saturationBlue=15,luminanceBlue=-20"
capture masking "select=0,tool=masking,linear=0.5:0.02:0.5:0.42,localExposure=-1.3,localTemperature=-30,localSaturation=25,radial=0.72:0.62:0.3:0.22:70,localExposure=0.9,localTemperature=30"
capture recipes "select=1,panel=basic+effects,recipe=camera/chrome-street"
capture detail "select=2,panel=detail,zoom=1:1,sharpenAmount=70,sharpenDetail=40,noiseLuminance=30,noiseColor=30,texture=15"
capture before-after "select=3,compare=sideBySide,before=1,exposure=0.35,highlights=-45,shadows=40,dehaze=15,vibrance=25,clarity=10,vignetteAmount=-20"
capture film-catalog "select=3,recipe=stock/portra-400,window=film-looks" "Film Looks"
capture film-editor "select=0,panel=basic+effects,recipe=stock/cinestill-800t"

pkill -f "$APP" 2>/dev/null || true

# The harness: the Recipe Lab on the look-development set, and the design foundations.
harness() {
    local name="$1" scene="$2"
    [[ -n "${ONLY:-}" && " $ONLY " != *" $name "* ]] && return 0
    shift 2
    SKIP_BUILD=1 WAIT="${HARNESS_WAIT:-18}" "$ROOT/scripts/harness-capture.sh" "$scene" "$OUT/$name.png" side "$@" >/dev/null
    sips -Z 1800 "$OUT/$name.png" >/dev/null
    echo "==> $OUT/$name.png"
}

xcodebuild build -workspace "$ROOT/Redlamp.xcworkspace" -scheme RedlampHarness -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/DerivedData" -quiet
harness lab-gallery recipe-lab --lab-select redlamp/camera/chrome-street --lab-mode split --lab-image X-H2S
harness lab-across-set recipe-lab --lab-select redlamp/street/gritty --lab-mode acrossSet --lab-hide-gallery
harness lab-side-by-side recipe-lab --lab-select redlamp/camera/chrome-street --lab-compare redlamp/camera/bright-slide \
    --lab-mode sideBySide --lab-image X-S20 --lab-hide-gallery
harness lab-inspect recipe-lab --lab-tab inspect --lab-select redlamp/camera/chrome-street
harness lab-runs recipe-lab --lab-tab runs --lab-run night-city --lab-hide-gallery
harness harness-parity parity-basic
harness harness-tokens tokens

# The command palette, scripted in the harness's Live scene, for the website: the stage alone,
# at 2x on a Retina screen when there is one, cropped to 800 x 500 pt around the palette.
# Launched directly rather than through `open`, because its steps can contain spaces.
HARNESS="$ROOT/build/DerivedData/Build/Products/Debug/RedlampHarness.app/Contents/MacOS/RedlampHarness"
palette() {
    local name="$1" steps="$2"
    [[ -n "${ONLY:-}" && " $ONLY " != *" $name "* ]] && return 0
    "$HARNESS" --scene command-palette --stage-only --window 1280x860 --background black \
        --palette-steps "$steps" >/dev/null 2>&1 &
    local pid=$!
    sleep "${HARNESS_WAIT:-18}"
    local window
    window="$(swift "$ROOT/scripts/window-id.swift" "$pid" || true)"
    rm -f "$OUT/$name.png"
    [[ -n "$window" ]] && screencapture -x -o -l "$window" "$OUT/$name.png" || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [[ -f "$OUT/$name.png" ]] || { echo "error: no harness window to capture for $name" >&2; return 1; }
    local scale=$(($(sips -g pixelWidth "$OUT/$name.png" | awk '/pixelWidth/ { print $2 }') / 1280))
    sips -c $((500 * scale)) $((800 * scale)) --cropOffset $((52 * scale)) $((240 * scale)) "$OUT/$name.png" >/dev/null
    echo "==> $OUT/$name.png"
}

palette palette-search "open;type:white"
palette palette-slider "open;type:exposure;enter;shift-right;shift"
palette palette-picker "open;type:base look;enter;down;down;down;down;down"
palette palette-value "open;type:temp 5600k"
