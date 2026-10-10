#!/bin/zsh
# Renders a raw with each candidate (main, a, b, c, d, ef, e8) at the defaults, Highlights -80, Exposure -1.5,
# Exposure -3 and Auto's values as the engine computes them for that candidate.
# Usage: candidates.sh <raw> <name> [stops]
# With stops, the raw is first overexposed by that many stops (REDLAMP_PROTO_OVEREXPOSE), and every
# render gets Exposure -stops more, so it lines up with the original.
# The CLI is the prototype branch's (fix/clipped-highlights-prototype), built in Release; REDLAMP_CLI
# names it, and HIGHLIGHTS_OUT where renders go (an absolute path).
set -e
cli=${REDLAMP_CLI:?build the prototype branch's redlamp CLI and set REDLAMP_CLI}
out=${HIGHLIGHTS_OUT:?set HIGHLIGHTS_OUT}
raw=$1; name=$2; stops=${3:-0}
export HOME=$out/home
mkdir -p $HOME $out/renders/$name
cd $out/renders/$name
offset() { printf '%.2f' $(( $1 - stops )) }
for candidate in ${=CANDIDATES:-main a b c d ef e8}; do
  # A trailing 8 (e8) also asks rim blocks to have a colour within 80% of its clip level; a trailing
  # f (ef, the design's E) fades only photosites at 0.8 of their clip level or above, fully from 0.9.
  proto=${candidate%f}; fade=0; [ "$proto" != "$candidate" ] && fade=0.9
  base=$proto; proto=${base%8}; near=0; [ "$proto" != "$base" ] && near=0.8
  export REDLAMP_PROTO_HIGHLIGHTS=$proto REDLAMP_PROTO_RIM_NEAR=$near REDLAMP_PROTO_FADE_NEAR=$fade REDLAMP_PROTO_OVEREXPOSE=$stops
  $cli render "$raw" -o $candidate-defaults.tif --size 2048 --16bit --set basic.exposure=$(offset 0) 2>&1 | sed "s/^/  $candidate /"
  $cli render "$raw" -o $candidate-highlights-80.tif --size 2048 --16bit --set basic.exposure=$(offset 0) --set basic.highlights=-80 2>&1 | sed "s/^/  $candidate /"
  $cli render "$raw" -o $candidate-exposure-1.5.tif --size 2048 --16bit --set basic.exposure=$(offset -1.5) 2>&1 | sed "s/^/  $candidate /"
  $cli render "$raw" -o $candidate-exposure-3.tif --size 2048 --16bit --set basic.exposure=$(offset -3) 2>&1 | sed "s/^/  $candidate /"
  if [ "$stops" = 0 ]; then
    $cli render "$raw" -o $candidate-auto.tif --size 2048 --16bit --proto-auto 2>&1 | sed "s/^/  $candidate /"
  fi
done
