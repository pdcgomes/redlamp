#!/usr/bin/env bash
# Builds libraw_thumbs.cpp against the vendored LibRaw (`mise run vendor`) and runs it:
#
#   research/prototypes/thumbnails/run.sh                     # per file, on tests/fixtures/raw
#   research/prototypes/thumbnails/run.sh <folder> [threads]  # throughput, on the raws beneath <folder>
#
# For throughput, a tree from scripts/make-folder-fixture.sh works (4,000 files are used: 2,000 per
# path). Run it twice to see decoding alone: the second run's files are already opened and cached.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
libraw="$root/vendor/build/LibRaw.xcframework/macos-arm64"
binary="$root/build/proto-out/libraw_thumbs"
mkdir -p "$(dirname "$binary")"
clang++ -O2 -std=c++17 -I"$libraw/Headers" "$(dirname "$0")/libraw_thumbs.cpp" "$libraw/libraw.a" -lz \
    -framework ImageIO -framework CoreGraphics -framework CoreFoundation -o "$binary"

if [[ $# -eq 0 ]]; then
    find "$root/tests/fixtures/raw" -type f ! -name '*.redlamp' -print0 | xargs -0 "$binary" 1
else
    find "$1" -type f \( -iname '*.arw' -o -iname '*.cr3' -o -iname '*.nef' -o -iname '*.raf' -o -iname '*.dng' \) \
        | sort | head -4000 | tr '\n' '\0' | xargs -0 "$binary" "${2:-16}"
fi
