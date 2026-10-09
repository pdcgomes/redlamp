#!/usr/bin/env bash
#
# Renders background.html into background.tiff, the picture behind the disk image's window, at 1x
# and 2x in one file, so that Finder shows the sharp one on a Retina screen. It needs Google Chrome,
# Swift and Inter Medium, which it fetches from the Inter 4.1 release into build/fonts.
#
#   scripts/dmg/background.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FONTS="$(git -C "$HERE" rev-parse --show-toplevel)/build/fonts"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "error: no Google Chrome at $CHROME" >&2; exit 1; }
if [ ! -f "$FONTS/Inter-Medium.ttf" ]; then
    mkdir -p "$FONTS"
    curl -fsSL -o "$FONTS/Inter-4.1.zip" https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
    unzip -jo -q "$FONTS/Inter-4.1.zip" extras/ttf/Inter-Medium.ttf -d "$FONTS"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The first four flags let Chrome start in the agent's sandbox; file access lets the page load the font.
for scale in 1 2; do
    "$CHROME" --headless --no-sandbox --disable-gpu-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader \
        --user-data-dir="$WORK/chrome" --allow-file-access-from-files --hide-scrollbars --virtual-time-budget=5000 \
        --window-size=640,420 --force-device-scale-factor="$scale" \
        --screenshot="$WORK/$scale.png" "file://$HERE/background.html" >/dev/null 2>&1
done
# Both pictures cover 640 by 420 points, so the 2x one is 144 dpi; tiffutil -cathidpicheck writes
# both at 72, and AppKit then takes the 2x one for a picture twice the size.
cat >"$WORK/tiff.swift" <<EOF
import AppKit
let reps = ["$WORK/1.png", "$WORK/2.png"].map { path -> NSBitmapImageRep in
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!
    rep.size = NSSize(width: 640, height: 420)
    return rep
}
let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0)!
try! tiff.write(to: URL(fileURLWithPath: "$HERE/background.tiff"))
EOF
swift "$WORK/tiff.swift"
echo "==> Rendered $HERE/background.tiff"
