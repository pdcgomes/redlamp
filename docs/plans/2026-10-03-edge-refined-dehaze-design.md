# Edge-refined Dehaze: design (TON-27)

Dehaze removes haze with the dark channel prior (`Haze.swift`, DEC-16): per 512 px map texel, the darkest channel relative to the airlight, its minimum over a patch 2.5% of the long side, then blurred. The patch minimum spreads a dark object's low value a patch-width out into the sky beside it, so that sky is dehazed less than the rest and keeps a pale glow: around trees against the sky and along a ridge line, at Dehaze +100 on the look-development set's sky photos. It's the halo the method's authors fixed with soft matting and then with the guided filter.

## The idea

- **Refine the coarse map with a guided filter** (K. He, J. Sun and X. Tang, "Guided image filtering", 2010, their dehazing example): the input is the patch-minimum dark channel, the guide the photo's brightness relative to the airlight (the mean of its three channels over the airlight's), so the map takes the photo's edges. Computed once per photo at the map's 512 px, from the same full-resolution blocks as today's map, as two coefficients per texel, as the tone base is (`ToneBase`, TON-05).
- **Evaluated per pixel:** the develop kernel samples the coefficients and applies them to the pixel's own brightness, `dark = a * guide + b`, so the map's edges are as sharp as the photo's (the fast guided filter, K. He and J. Sun, 2015).
- **Process version 8:** edits made before keep today's map; Dehaze in masks uses the same map, so it's refined too.
- **Radius and `epsilon`:** the authors use a window about four times the patch and `epsilon` 10⁻³; tuned on the sky photos (it ships at eight patch radii, with a ceiling: see the results).

## Validation

On the look-development set's sky photos at Dehaze +100: in the sky (the bake-off's OneFormer sky masks), the change in log luminance within 30 px of the skyline against the rest of the sky (the halo), before and after; and the change in the land (the map shouldn't pick up texture there). The cost of building the map.

## Steps

1. The refined map's coefficients, with a unit test on a synthetic edge.
2. The kernel behind process version 8, with a render test (sky beside a dark edge dehazed as much as open sky).
3. Validation and tuning on the sky photos.
4. Docs: tracker, README, this design's results.

## Results

Thirteen of the look-development set's sky photos (the Samsung S21 Ultra's DNG doesn't open in the CLI), rendered at 1600 px at Dehaze 0 and +100. The edge measure is the change in log luminance in the sky within 24 px of the skyline (the bake-off's OneFormer sky masks) minus the change in open sky 60–200 px away; it doesn't reach zero, because the sky near the horizon is naturally hazier than the sky above.

| | Edge measure | Land shift | Land texture |
|---|---|---|---|
| Process 7 (coarse map) | +0.62 EV | −0.27 EV | 1.17 |
| Guided, window 4 patch radii | +0.44 EV | −0.29 EV | 1.16 |
| Guided, window 8 | +0.32 EV | −0.35 EV | 1.18 |
| Guided, window 16 | +0.23 EV | −0.46 EV | 1.19 |
| Guided (8) under the reconstruction ceiling (process 8) | +0.33 EV | −0.31 EV | 1.14 |

- **What ships:** the patch-minimum dark channel from the coarse map's full-resolution blocks (so a Dehaze amount means what it did), guided by the photo's brightness over the airlight with a window eight patch radii wide (the authors' ratio) and `epsilon` 10⁻³, evaluated per pixel; under a ceiling, the patch minimum's opening by reconstruction (L. Vincent, 1993) against the blocks' own darkest channel.
- **No visible glow** beside cypresses, a spruce, a tree crown and a ridge line, where process 7 leaves a wide pale band. At window 4 the band is only partly corrected: the band's sky has the open sky's brightness but the tree's haze, which a filter predicting haze from brightness can only average; a wider window averages in more open sky.
- **Why the ceiling:** the guided filter alone learns, where a window spans sky and tree, that bright means hazy, so sunlit leaves beside the sky took the sky's haze and turned yellow when it was removed, and land was dehazed 0.07 EV more. Capped by the reconstruction, which grows the sky's haze back into the band beside a tree (it's connected to the open sky through sky) but not into the tree (whose own blocks are darker), the leaves keep their own.
- **Tried and dropped:** the opening as the filter's input (it raises the haze in all textured land, Dehaze +100 dehazing it 0.2 EV more); a plain opening as the ceiling (its square window leaves pale squares in the sky beside narrow tips); raising the ceiling to each pixel's own darkest channel (sunlit leaves pass for haze again).
- **Cost:** 18 ms per photo for the refined map in an unoptimised build; the dark-channel pass writes the guide into a second channel, so the GPU does no extra work.
- **Process 7 unchanged:** its renders are byte-identical before and after. Its golden renders had never been recorded (TON-05 changed the process version without them); they're recorded now, from the build before this change, with process 8's.
- **Still open:** holes of sky between branches smaller than the patch keep the coarse map's low haze (the reconstruction can't reach them); `REDLAMP_HAZE_RADIUS` and `REDLAMP_HAZE_EPSILON` override the window and `epsilon`, to tune.

## Gates

Shipping waits on DEC-05 (the patent search includes the guided filter) and DEC-16's counsel check on the dark channel prior.
