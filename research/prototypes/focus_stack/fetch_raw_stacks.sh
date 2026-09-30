#!/usr/bin/env bash
#
# Downloads the public raw focus stacks used to develop focus stacking into build/proto-data/stacks/
# (gitignored) and verifies them against the publishers' checksums.
#
#   sood-cr3: Johannes Sood, "Focus Stack Sample", Canon EOS R5 Mark II + RF 100 mm macro, CC BY 4.0
#             (https://huggingface.co/datasets/jjjsood/focus-stack-sample). 999 frames in focus order;
#             every 40th is taken, 25 frames spanning the whole depth (about 214 MB).
#
# usage: research/prototypes/focus_stack/fetch_raw_stacks.sh [step]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STEP="${1:-40}"
REVISION=0f8256edf2d2e3f1f1ea162f78a8bca36eb6915c
BASE="https://huggingface.co/datasets/jjjsood/focus-stack-sample/resolve/$REVISION"
OUT="$ROOT/build/proto-data/stacks/sood-cr3"

mkdir -p "$OUT"
cd "$OUT"
curl -sfL -o SHA256SUMS "$BASE/SHA256SUMS"
curl -sfL -o LICENSE "$BASE/LICENSE"
for i in $(seq 0 "$STEP" 998); do
    name=$(printf "frame_%03d.CR3" "$i")
    [[ -f "$name" ]] || curl -sfL -o "$name" "$BASE/raw/$name"
    expected=$(grep " raw/$name$" SHA256SUMS | cut -d' ' -f1)
    actual=$(shasum -a 256 "$name" | cut -d' ' -f1)
    if [[ "$expected" != "$actual" ]]; then
        echo "checksum mismatch: $name" >&2
        exit 1
    fi
done
echo "sood-cr3: $(ls frame_*.CR3 | wc -l | tr -d ' ') frames verified in $OUT"
