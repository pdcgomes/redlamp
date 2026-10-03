# Edge-refined Dehaze: design (TON-27)

Dehaze removes haze with the dark channel prior (`Haze.swift`, DEC-16): per 512 px map texel, the darkest channel relative to the airlight, its minimum over a patch 2.5% of the long side, then blurred. The patch minimum spreads a dark object's low value a patch-width out into the sky beside it, so that sky is dehazed less than the rest and keeps a pale glow: around trees against the sky and along a ridge line, at Dehaze +100 on the look-development set's sky photos. It's the halo the method's authors fixed with soft matting and then with the guided filter.

## The idea

- **Refine the coarse map with a guided filter** (K. He, J. Sun and X. Tang, "Guided image filtering", 2010, their dehazing example): the input is the patch-minimum dark channel, the guide the photo's brightness relative to the airlight (the mean of its three channels over the airlight's), so the map takes the photo's edges. Computed once per photo at the map's 512 px from the analysis image, as the tone base is (`ToneBase`, TON-05), as two coefficients per texel.
- **Evaluated per pixel:** the develop kernel samples the coefficients and applies them to the pixel's own brightness, `dark = a * guide + b`, so the map's edges are as sharp as the photo's (the fast guided filter, K. He and J. Sun, 2015).
- **Process version 8:** edits made before keep today's map; Dehaze in masks uses the same map, so it's refined too.
- **Radius and `epsilon`:** the authors use a window about four times the patch and `epsilon` 10⁻³; tuned on the sky photos.

## Validation

On the look-development set's sky photos at Dehaze +100: in the sky (the bake-off's OneFormer sky masks), the change in log luminance within 30 px of the skyline against the rest of the sky (the halo), before and after; and the change in the land (the map shouldn't pick up texture there). The cost of building the map.

## Steps

1. The refined map's coefficients, with a unit test on a synthetic edge.
2. The kernel behind process version 8, with a render test (sky beside a dark edge dehazed as much as open sky).
3. Validation and tuning on the sky photos.
4. Docs: tracker, README, this design's results.

## Gates

Shipping waits on DEC-05 (the patent search includes the guided filter) and DEC-16's counsel check on the dark channel prior.
