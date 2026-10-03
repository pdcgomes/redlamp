# Edge-aware Clarity: design (TON-06)

Clarity is a gain on a band of log-luminance detail: the pyramid's level 3 (about 8 px) less its level 6 (about 64 px), soft-limited at 0.5 stops (`LocalContrast.metal`). Level 6 is a blur, so at a strong edge the band jumps: the bright side brightens and the dark side darkens for about 64 px. At Clarity +100 on the look-development set's sky photos that's a pale band in the sky around trees and along a ridge, and each tree darkened as a whole. The limit caps the halo but doesn't remove it.

## The idea

- **Keep the band, replace its coarse end with an edge-preserving base:** a self-guided filter on log luminance (as the tone base, `ToneBase`, TON-05) at Clarity's scale, a window of about 32 full-resolution pixels. Inside a region it's the region's local mean, as level 6 is, so texture gets the same boost; across an edge stronger than `epsilon` it keeps the edge, so the band, and the halo, go to zero there.
- **Computed once per photo** from the analysis image (1024 px), as the filter's two coefficients per texel; the detail stage applies them to the band's fine level, `base = a * fine + b`, so the base's edges are as sharp as the photo's. From the whole image, so tiles and the preview agree.
- **Masks' Clarity** uses the same band, so it becomes edge-aware too.
- **Process version 9:** edits made before keep today's band.

## Validation

At Clarity +100, process 8 against 9: on a synthetic step with texture, the overshoot beside the edge and the texture's gain away from it; on the sky photos, the sky's change beside the skyline against open sky (the halo) and the texture's gain in the land; and the map's cost.

## Steps

1. The map, with a unit test.
2. The detail stage behind process version 9, with a render test (the texture's boost kept, the edge's overshoot gone).
3. Validation and tuning (window, `epsilon`).
4. Docs: tracker, README, this design's results.

## Gates

Shipping waits on DEC-05 (the guided filter).
