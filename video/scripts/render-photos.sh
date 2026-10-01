#!/usr/bin/env bash
# Renders the photos the explainer develops on screen, with Redlamp itself: one CC0
# landscape from the look-development set, as Redlamp renders it and through five film
# stocks. Needs the CLI (`SCHEME=redlamp mise run build`) and `mise run lookdev`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cli="${REDLAMP_CLI:-$repo/build/DerivedData/Build/Products/Debug/redlamp}"
raw="$repo/build/look-dev/Sony_ILCE-6700.ARW"
out="$repo/video/public/photos"

[ -x "$cli" ] || { echo "Build the CLI first: SCHEME=redlamp mise run build" >&2; exit 1; }
[ -f "$raw" ] || { echo "Download the look-development set first: mise run lookdev" >&2; exit 1; }
mkdir -p "$out"

compress() {
    sips -s format jpeg -s formatOptions 76 "$1" --out "$1" >/dev/null
}

"$cli" render "$raw" -o "$out/original.jpg" --size 1440
compress "$out/original.jpg"

for stock in portra-400 velvia-50 cinestill-800t vision3-500t-2383 tri-x-400; do
    "$cli" recipe render "$raw" --recipe "redlamp/stock/$stock" -o "$out/$stock.jpg" --size 1440
    compress "$out/$stock.jpg"
done
