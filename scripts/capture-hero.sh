#!/usr/bin/env bash
#
# Captures the README's and redlamp.app's hero shots into docs/images from a folder of your own
# photos, through scripts/capture-promo.sh, whose header describes the folder's promo.txt:
#
#   scripts/capture-hero.sh ~/Pictures/redlamp-promo
#   ONLY="hero-palette hero-slider" scripts/capture-hero.sh ~/Pictures/redlamp-promo
#
# Each shot is the editor at 1600 × 1000 points in the app's default theme (Neutral), scaled to
# 2400 pixels wide. The Folders panel shows the folder's name. web/content/features.ts lists the
# shots in `heroShots`, and the README shows hero.png and the detail shots.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/images"

[[ $# -eq 1 && -d "$1" ]] || { echo "usage: scripts/capture-hero.sh <photo folder>" >&2; exit 1; }

# Each image in docs/images, and the capture-promo.sh shot it's made from.
SHOTS="hero:hero hero-palette:palette-search hero-slider:palette-slider hero-shortcuts:shortcuts hero-masks:masks-overlay
    hero-film:film-after hero-compare:before-after"

wanted=""
for pair in $SHOTS; do
    [[ -n "${ONLY:-}" && " $ONLY " != *" ${pair%%:*} "* ]] && continue
    wanted+=" ${pair#*:}"
done
[[ -n "$wanted" ]] || { echo "error: ONLY names none of the hero shots" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROMO_OUT="$WORK" ONLY="$wanted" "$ROOT/scripts/capture-promo.sh" "$1"

for pair in $SHOTS; do
    shot="$WORK/${pair#*:}.png"
    [[ -f "$shot" ]] || continue
    sips -Z 2400 "$shot" --out "$OUT/${pair%%:*}.png" >/dev/null
    echo "==> $OUT/${pair%%:*}.png"
done
