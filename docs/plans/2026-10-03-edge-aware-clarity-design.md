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

## Results

Thirteen of the look-development set's sky photos, at 1600 px, Clarity 0 and +100. The bands are the change in log luminance within 24 px of the skyline (the bake-off's OneFormer sky masks) less the change 60–200 px away, on each side; the texture's boost is the spread of a band-pass (σ 2 to 10 px) in the land where the photo has no strong edge, against Clarity 0.

| | Sky band | Land band | Texture boost | Land's tone |
|---|---|---|---|---|
| Process 8 (per level) | +0.025 EV | −0.125 EV | 1.36 | −0.08 EV |
| Edge-aware, `epsilon` 0.25, gain 0.7 | +0.017 EV | −0.031 EV | 1.20 | |
| Edge-aware, `epsilon` 0.5, gain 1.0 | +0.033 EV | −0.068 EV | 1.36 | |
| Edge-aware, `epsilon` 1.0, gain 0.85 | +0.037 EV | −0.078 EV | 1.36 | |
| Edge-aware, `epsilon` 0.25, gain 1.25 (process 9) | +0.029 EV | −0.056 EV | 1.36 | +0.02 EV |

- **What ships:** a self-guided filter on log luminance (`ToneBase`'s weights) from the analysis image, with a 32 px window in full-resolution pixels and `epsilon` 0.25 stops², applied to the band's fine level; Clarity's gain is 1.25 on it, against 0.7 per level.
- **Why the higher gain:** the filter keeps part of strong texture in its base (its slope is variance over variance plus `epsilon`), so at the same gain the band is smaller and Clarity +100 boosted texture 1.20 times instead of 1.36. At 1.25 it matches; with a larger `epsilon` the gain needed is smaller but the bands come back.
- **The bands halve, and the broad darkening goes:** per-level Clarity darkens each tree and the land beside a bright sky as a whole (a band 64 px wide and the land's tone −0.08 EV on average); edge-aware Clarity's change follows the texture and leaves the land's tone where it was. On a synthetic edge with stripes the bands for each stop of the stripes' boost are 3.4 (bright side) and 6 (dark side) times smaller. The sky side was small already, held back by the soft limit.
- **Cost:** 38 ms per photo for the map in an unoptimised build; the detail stage reads one more texture.
- **Gates:** the preview against a downscaled export passes for Clarity; process 9's golden renders are recorded.
- **Still open:** a thin line remains along the strongest edges (the filter's window straddles them); `REDLAMP_CLARITY_RADIUS`, `REDLAMP_CLARITY_EPSILON` and `REDLAMP_CLARITY_GAIN` override the three settings, to tune.

## Gates

Shipping waits on DEC-05 (the guided filter).
