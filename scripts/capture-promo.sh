#!/usr/bin/env bash
#
# Captures the editor for the Reddit stills (video/src/stills) from a folder of your own photos:
#
#   scripts/capture-promo.sh ~/Pictures/redlamp-promo
#   ONLY="masks-sky film-looks" scripts/capture-promo.sh ~/Pictures/redlamp-promo
#
# The folder needs a promo.txt naming the photo for each role, one `role = file name` per line:
#
#   hero = DSC04439.ARW        the editor in images 1 and 8, and the panels and shortcuts in 2
#   portrait = DSC01207.ARW    People masks (image 3): a clear face
#   landscape = DSC00310.ARW   the Sky mask (image 3): a big sky
#   night = DSC02088.ARW       CineStill 800T and the Film Looks window (image 4): bright lights
#   fujifilm = DSCF4410.RAF    the Chrome Street recipe (image 5)
#   stack = stack              a subfolder of 10 to 30 focus-bracketed frames (image 6)
#
# A role left out skips its shots. Each shot launches the Debug app (`mise run build`; the stack
# needs the CLI too, `SCHEME=redlamp mise run build`) on a temporary copy of the folder, with the
# editor at 1600 × 1000 points on a Retina screen. It applies a --script of edits on top of the
# edits already in your sidecars, and keeps the 3200 × 2000 window capture in
# video/public/promo/<shot>.png (PROMO_OUT overrides it), where the stills pick it up. Nothing in
# the folder itself is changed. The terminal running this needs the Screen Recording permission.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="$ROOT/build/DerivedData/Build/Products/Debug"
BUNDLE="$PRODUCTS/Redlamp.app"
APP="$BUNDLE/Contents/MacOS/Redlamp"
CLI="$PRODUCTS/redlamp"
OUT="${PROMO_OUT:-$ROOT/video/public/promo}"
WAIT="${WAIT:-10}"

[[ $# -eq 1 && -d "$1" ]] || { echo "usage: scripts/capture-promo.sh <photo folder>" >&2; exit 1; }
SOURCE="$(cd "$1" && pwd)"
[[ -x "$APP" ]] || { echo "error: build the app first (mise run build)" >&2; exit 1; }
[[ -f "$SOURCE/promo.txt" ]] || { echo "error: $SOURCE/promo.txt is missing; see the top of this script" >&2; exit 1; }

role() {
    local name
    name="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$SOURCE/promo.txt" | head -1 | sed 's/[[:space:]]*$//')"
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
HERO="$(role hero)"
PORTRAIT="$(role portrait)"
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
# The app remembers the last folder it opened; put the user's back afterwards.
LAST_FOLDER="$(defaults read app.redlamp.mac lastFolder 2>/dev/null || true)"
restore() {
    pkill -f "$APP" 2>/dev/null || true
    rm -rf "$WORK"
    if [[ -n "$LAST_FOLDER" ]]; then
        defaults write app.redlamp.mac lastFolder "$LAST_FOLDER"
    else
        defaults delete app.redlamp.mac lastFolder 2>/dev/null || true
    fi
}
trap restore EXIT

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
    capture hero "$PHOTOS" "select=$HERO,panel=basic+toneCurve"
    capture panels "$PHOTOS" "select=$HERO,panel=basic"
    capture shortcuts "$PHOTOS" "select=$HERO,action=showShortcuts"
    # Image 7 waits for a release with the command palette; builds without it capture the editor.
    capture palette "$PHOTOS" "select=$HERO,action=commandPalette"
fi
# The overlay is never red in the stills: the glow is each image's one red light.
if [[ -n "$PORTRAIT" ]]; then
    capture masks-people "$PHOTOS" "select=$PORTRAIT,mask=people,action=maskOverlayColor" "" 18
    capture masks-face "$PHOTOS" "select=$PORTRAIT,mask=people:faceSkin,action=maskOverlayColor" "" 18
fi
if [[ -n "$LANDSCAPE" ]]; then
    capture masks-sky "$PHOTOS" "select=$LANDSCAPE,mask=sky,action=maskOverlayColor" "" 18
fi
if [[ -n "$NIGHT" ]]; then
    capture film-before "$PHOTOS" "select=$NIGHT"
    capture film-after "$PHOTOS" "select=$NIGHT,recipe=stock/cinestill-800t,panel=effects"
    capture film-looks "$PHOTOS" "select=$NIGHT,recipe=stock/cinestill-800t,window=film-looks" "Film Looks" 14
fi
if [[ -n "$FUJIFILM" ]]; then
    capture fujifilm "$PHOTOS" "select=$FUJIFILM,panel=effects,recipe=camera/chrome-street"
    # Tall enough for the Effects panel's camera-recipe controls, which sit below its effects.
    capture fujifilm-effects "$PHOTOS" "select=$FUJIFILM,panel=effects,recipe=camera/chrome-street" "" "$WAIT" 1600x1440
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
