#!/usr/bin/env bash
#
# Screenshots harness scenes under every theme, appearance and tint, for judging how
# the themes map onto Redlamp's panels. Builds once, then captures with
# scripts/harness-capture.sh. Needs Screen Recording permission for the terminal.
#
# usage: scripts/theme-sweep.sh [out-dir]
#   THEMES="neutral redlamp nord"  limit the themes (default: all)
#   SCENES="basic-panel"           limit the scenes (default: basic-panel slider-rows panel-chrome)
#   TINTS="0 1"                    limit the tints (default: 0 0.5 1)
#   APPEARANCES="dark"             limit the appearances (default: dark light)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/theme-sweep}"
CATALOG="$ROOT/packages/RedlampDesign/Sources/Themes/ThemeCatalog.swift"
ALL_THEMES="$(sed -nE 's/.*(ThemeFamily\(id: |family\()"([a-z0-9-]+)".*/\2/p' "$CATALOG" | tr '\n' ' ')"
THEMES="${THEMES:-$ALL_THEMES}"
SCENES="${SCENES:-basic-panel slider-rows panel-chrome}"
TINTS="${TINTS:-0 0.5 1}"
APPEARANCES="${APPEARANCES:-dark light}"

mkdir -p "$OUT"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    xcodebuild build \
        -workspace "$ROOT/Redlamp.xcworkspace" -scheme RedlampHarness -configuration "${CONFIGURATION:-Debug}" \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/DerivedData" -quiet
fi

for scene in $SCENES; do
    for theme in $THEMES; do
        for appearance in $APPEARANCES; do
            for tint in $TINTS; do
                file="$OUT/$scene--$theme--$appearance--tint$tint.png"
                SKIP_BUILD=1 BACKGROUND=panel "$ROOT/scripts/harness-capture.sh" "$scene" "$file" side \
                    --theme "$theme" --appearance "$appearance" --tint "$tint" >/dev/null
                echo "$file"
            done
        done
    done
done
