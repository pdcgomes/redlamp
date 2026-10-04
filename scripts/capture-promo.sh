#!/usr/bin/env bash
#
# Captures the editor for the Reddit stills (video/src/stills) and the Introducing film
# (video/src/introducing) from a folder of your own photos:
#
#   scripts/capture-promo.sh ~/Pictures/redlamp-promo
#   ONLY="masks-people film-looks" scripts/capture-promo.sh ~/Pictures/redlamp-promo
#   PROMO_OUT=video/public/film/captures scripts/capture-promo.sh ~/Pictures/redlamp-promo   # the film's
#
# The folder needs a promo.txt naming the photo for each role, one `role = file name` per line:
#
#   hero = DSC04439.ARW        the editor in images 1 and 8, the panels, shortcuts and palette,
#                              and the website's hero shots (the palette's search, its slider bar,
#                              and before and after)
#   portrait = DSC02005.jpg    People masks (image 3): a clear face
#   subject = DSC02035.jpg     the Subject mask (image 3)
#   landscape = DSC00310.ARW   the Sky mask (image 3): a big sky
#   night = DSC01968.jpg       CineStill 800T and the Film Looks window (image 4): bright lights
#   fujifilm = DSC01545.jpg    the Chrome Street recipe (image 5)
#   stack = stack              a subfolder of 10 to 30 focus-bracketed frames (image 6)
#
# A role left out skips its shots. `<role>.edit = <script>` adds edits to every shot of a role, such
# as `hero.edit = recipe=local/<id>,exposure=0.75` for a raw that has no sidecar here.
#
# Each shot launches the Debug app (`mise run build`; the stack needs the CLI too,
# `SCHEME=redlamp mise run build`) on a temporary copy of the folder, with the editor at
# 1600 × 1000 points on a Retina screen. It applies a --script of edits on top of the edits already
# in your sidecars, and keeps the 3200 × 2000 window capture in video/public/promo/<shot>.png
# (PROMO_OUT overrides it), where the stills pick it up. Shots use the app's default theme and only
# the models testers get, and the Folders panel shows only the folder being captured, under the
# name of yours; your preferences are put back afterwards, and nothing in the folder itself
# changes. The terminal running this needs the Screen Recording permission.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="$ROOT/build/DerivedData/Build/Products/Debug"
BUNDLE="$PRODUCTS/Redlamp.app"
APP="$BUNDLE/Contents/MacOS/Redlamp"
CLI="$PRODUCTS/redlamp"
DOMAIN="app.redlamp.mac"
OUT="${PROMO_OUT:-$ROOT/video/public/promo}"
WAIT="${WAIT:-10}"

[[ $# -eq 1 && -d "$1" ]] || { echo "usage: scripts/capture-promo.sh <photo folder>" >&2; exit 1; }
SOURCE="$(cd "$1" && pwd)"
[[ -x "$APP" ]] || { echo "error: build the app first (mise run build)" >&2; exit 1; }
[[ -f "$SOURCE/promo.txt" ]] || { echo "error: $SOURCE/promo.txt is missing; see the top of this script" >&2; exit 1; }

setting() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$SOURCE/promo.txt" | head -1 | sed 's/[[:space:]]*$//'
}
role() {
    local name
    name="$(setting "$1")"
    # The launch arguments are split on whitespace and scripts on commas.
    if [[ "$name" =~ [[:space:],=] ]]; then
        echo "error: rename \"$name\" ($1) without spaces, commas or =" >&2
        exit 1
    fi
    if [[ -n "$name" && ! -e "$SOURCE/$name" ]]; then
        echo "error: $1 = $name, which isn't in $SOURCE" >&2
        exit 1
    fi
    echo "$name"
}
# `select=<file>` plus the role's own edits, to start each shot's script with.
open_role() {
    local edit
    edit="$(setting "$2\\.edit")"
    echo "select=$1${edit:+,$edit}"
}
HERO="$(role hero)"
PORTRAIT="$(role portrait)"
SUBJECT="$(role subject)"
LANDSCAPE="$(role landscape)"
NIGHT="$(role night)"
FUJIFILM="$(role fujifilm)"
STACK="$(role stack)"
if [[ -n "$STACK" && ! -x "$CLI" ]]; then
    echo "error: the stack shots need the CLI (SCHEME=redlamp mise run build)" >&2
    exit 1
fi

# A sleeping display has no windows to capture; keep it awake for the whole run.
caffeinate -u -d -w $$ &
mkdir -p "$OUT"
WORK="$(mktemp -d)"
PHOTOS="$WORK/$(basename "$SOURCE" | tr -c '[:alnum:]._\n-' '-')"
# Every shot starts from the folder as it is, so one shot's edits never reach the next. Stack
# documents made here survive the refresh.
refresh() {
    mkdir -p "$PHOTOS"
    rsync -a --delete --exclude promo.txt --exclude '*.redlampstack' "$SOURCE/" "$PHOTOS/"
}

# The app's preferences, including the last folder it opened, are saved now and put back on exit.
PREFS="$WORK/preferences.plist"
defaults export "$DOMAIN" "$PREFS" 2>/dev/null || PREFS=""
restore() {
    pkill -f "$APP" 2>/dev/null || true
    sleep 1
    # Import merges, so clear the domain first: keys the run added, such as the last folder, go too.
    defaults delete "$DOMAIN" 2>/dev/null || true
    if [[ -n "$PREFS" ]]; then
        defaults import "$DOMAIN" "$PREFS"
    fi
    rm -rf "$WORK"
}
trap restore EXIT
# The remembered folders go too, so the Folders panel lists only the shot's own folder.
for key in themeFamily themeAppearance themeTint themeTintsNativeControls panelTransparency \
    commandPaletteThemeFamily commandPaletteThemeAppearance commandPaletteThemeTint app.redlamp.evaluationModels \
    folders.roots folders.open folders.expanded folders.lastPhotos folders.subfolders lastFolder; do
    defaults delete "$DOMAIN" "$key" 2>/dev/null || true
done

# capture <shot> <folder> <script> [window title] [seconds to wait] [window size]
capture() {
    local name="$1" folder="$2" script="$3" title="${4:-}" wait="${5:-$WAIT}" size="${6:-1600x1000}"
    [[ -n "${ONLY:-}" && " $ONLY " != *" $name "* ]] && return 0
    pkill -f "$APP" 2>/dev/null || true
    sleep 1
    refresh
    # Launched through `open` (a process started from a non-GUI shell may never get a
    # window), with the arguments in the file the app reads once on launch.
    echo "$folder --window-size $size --script $script" >/tmp/redlamp-launch-args
    open -n -g "$BUNDLE"
    local pid=""
    for _ in $(seq 1 40); do
        sleep 0.25
        pid="$(pgrep -f "$APP" | head -1 || true)"
        [[ -n "$pid" ]] && break
    done
    [[ -n "$pid" ]] || { echo "error: Redlamp didn't start" >&2; exit 1; }
    sleep "$wait"
    local id
    id="$(swift "$ROOT/scripts/window-id.swift" "$pid" ${title:+"$title"})"
    screencapture -x -o -l "$id" "$OUT/$name.png"
    kill "$pid" 2>/dev/null || true
    echo "==> $OUT/$name.png ($(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/ { printf "%s ", $2 }'))"
}

if [[ -n "$HERO" ]]; then
    hero="$(open_role "$HERO" hero)"
    capture hero "$PHOTOS" "$hero,panel=basic+toneCurve"
    # The edit the app saved for it, which the film's History sheets are rendered from
    # (video/scripts/film-assets.mjs).
    if [[ -e "$PHOTOS/$HERO.redlamp" ]]; then
        rm -rf "$OUT/hero.redlamp"
        cp -R "$PHOTOS/$HERO.redlamp" "$OUT/hero.redlamp"
    fi
    capture panels "$PHOTOS" "$hero,panel=basic"
    capture shortcuts "$PHOTOS" "$hero,action=showShortcuts"
    # Image 7 waits for a release with the command palette; builds without it capture the editor.
    capture palette "$PHOTOS" "$hero,action=commandPalette"
    # For scripts/capture-hero.sh: a search, the slider bar a slider opens, and before and after.
    capture palette-search "$PHOTOS" "$hero,palette=open;type:white"
    capture palette-slider "$PHOTOS" "$hero,palette=open;type:exposure;enter;right;right"
    capture before-after "$PHOTOS" "$hero,compare=sideBySide,before=1"
fi
# Masks show as Image on Black, or in green: never the default red, since the glow is each
# image's one red light.
if [[ -n "$PORTRAIT" ]]; then
    portrait="$(open_role "$PORTRAIT" portrait)"
    capture masks-people "$PHOTOS" "$portrait,mask=people,overlay=imageOnBlack,action=maskPins" "" 18
    capture masks-face "$PHOTOS" "$portrait,mask=people:faceSkin,action=maskOverlayColor,action=maskPins" "" 18
fi
if [[ -n "$SUBJECT" ]]; then
    capture masks-subject "$PHOTOS" "$(open_role "$SUBJECT" subject),mask=subject,overlay=imageOnBlack,action=maskPins" "" 18
fi
if [[ -n "$LANDSCAPE" ]]; then
    capture masks-sky "$PHOTOS" "$(open_role "$LANDSCAPE" landscape),mask=sky,action=maskOverlayColor,action=maskPins" "" 18
fi
if [[ -n "$NIGHT" ]]; then
    night="$(open_role "$NIGHT" night)"
    capture film-before "$PHOTOS" "$night"
    capture film-after "$PHOTOS" "$night,recipe=stock/cinestill-800t,panel=effects"
    capture film-looks "$PHOTOS" "$night,recipe=stock/cinestill-800t,window=film-looks" "Film Looks" 14
fi
if [[ -n "$FUJIFILM" ]]; then
    fujifilm="$(open_role "$FUJIFILM" fujifilm)"
    capture fujifilm "$PHOTOS" "$fujifilm,panel=effects,recipe=camera/chrome-street"
    # Tall enough for the Effects panel's camera-recipe controls, which sit below its effects.
    capture fujifilm-effects "$PHOTOS" "$fujifilm,panel=effects,recipe=camera/chrome-street" "" "$WAIT" 1600x1440
fi
if [[ -n "$STACK" ]]; then
    # The banner only shows while the frames have no stack document.
    capture stack-banner "$PHOTOS/$STACK" "select=0"
    if [[ -z "${ONLY:-}" || " $ONLY " == *" stack-depth "* || " $ONLY " == *" stack-merged "* ]]; then
        "$CLI" stack "$PHOTOS/$STACK" --save "$PHOTOS/$STACK/stack.redlampstack" >/dev/null
    fi
    capture stack-depth "$PHOTOS/$STACK" "select=stack.redlampstack,stack=depth" "" 24
    capture stack-merged "$PHOTOS/$STACK" "select=stack.redlampstack,stack=open" "" 24
fi
