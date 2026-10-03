# Edge-aware Highlights and Shadows: design (TON-05)

Today Highlights and Shadows are a curve on each pixel's own brightness (`Develop.metal`, the tone controls in log space around middle grey): every pixel at a given brightness moves by the same amount wherever it is. Lifting the shadows therefore lifts the dark threads of a sweater and the dark gaps in foliage as much as the shadow they sit in, which flattens their texture; pulling the highlights greys out the bright parts of clouds as well as the bright sky. Lightroom's controls are local: they move a region by its brightness and keep the detail inside it.

## The idea

Split each pixel's log luminance into a base (the region's brightness, smooth, with its edges kept) and the detail on top: `ev = base + detail`. Highlights and Shadows choose their weight from the base, not the pixel, and add the same shift to the whole region; the detail rides along unchanged. Contrast stays a global curve on `ev`.

- **The base is an edge-preserving smoothing of log luminance: a self-guided filter** (K. He, J. Sun and X. Tang, "Guided image filtering", 2010). In log space the filter doesn't depend on exposure: multiplying the photo by k adds a constant to log luminance, and the filter's output moves by the same constant. So its edge threshold, `epsilon`, is in stops squared and means the same in the shadows as in the highlights, which is what darktable's exposure-independent guided filter is for (DT §4). Our own formulation, from the paper.
- **Computed once per photo, small, upsampled sharp** (the fast guided filter, K. He and J. Sun, 2015): the filter's two coefficients per texel, `a` and `b`, at 512 px on the long side, from the pyramid's camera RGB, as Dehaze's map is (`Haze.swift`). The develop kernel samples them bilinearly and evaluates `detail = (1 - a) * evCamera - b` with the pixel's own full-resolution camera log luminance, so edges stay as sharp as the photo's.
- **In the kernel:** `base = ev - detail`, where `ev` already includes exposure, white balance and any mask's exposure, so the base follows them. The highlight and shadow weights read `base` instead of `ev`. A mask's own Highlights and Shadows use the same weights, so they become edge-aware too.
- **Whites and Blacks stay as the white and black points** in this step (global endpoints, as Lightroom's mostly behave). Whether they should be edge-aware is measured in step 3, not assumed (they stay endpoints: see the results).

## Choices to make while building

- **Filter radius and `epsilon`:** start at 3% of the long side and (0.5 EV)², then tune on the validation photos: too small a radius and the base follows texture (no gain); too large an `epsilon` and edges blur (halos at the sky line).
- **Process version 7:** edits made before keep today's per-pixel tone (process 6 and earlier render exactly as now); new edits get the edge-aware one. Existing edits move only through an explicit update (EDT-03).

## Validation

On photos with deep shadows and bright skies (the portrait set, the raw fixtures, the landscape bake-off's set), at Shadows +100 and Highlights −100, per-pixel against edge-aware:

- **Texture kept:** the detail's spread (standard deviation of `detail`) inside the lifted shadows and pulled highlights, as a share of the original's. Per-pixel flattens it; edge-aware should keep close to all of it.
- **Halos:** overshoot across strong edges (a dark rim under a bright sky line), measured along the edges the filter keeps.
- **Cost:** the map's build time per photo and the kernel's added time at 1:1.
- **Lightroom, if you can:** three of your photos exported from Lightroom at Shadows +100 and Highlights −100 would let us compare against the real thing rather than only per-pixel.

## Steps

1. The map (`ToneBase`: a and b at 512 px) built with the session, with unit tests on synthetic edges.
2. The kernel's edge-aware weights behind process version 7, with render tests (texture kept, an edge without a halo, process 6 unchanged).
3. Validation on real photos, tuning radius and `epsilon`; the Whites and Blacks question.
4. Docs: tracker, README, this design's results.

## Results

Ten photos (the raw fixtures, the portrait set, the edge cases), rendered at 1600 px with process 6 and 7. Texture kept is the spread of high-passed log luminance (σ 3 px) in the darkest quarter for Shadows +100 and the brightest quarter for Highlights −100, as a share of the untouched render's. Bleed is the extra shift on the far side of the moved region, within 12 px of it, against the same tones 40 px or more away.

| | Texture kept, process 6 | Process 7 | Shift, process 6 | Process 7 |
|---|---|---|---|---|
| Shadows +100 | 0.65 | 0.70 | +2.02 EV | +1.95 EV |
| Highlights −100 | 0.88 | 0.95 | −0.23 EV | −0.20 EV |

- **Smaller than the synthetic gain** (1.30 to 1.64 of 1.78 on the render test's texture): Shadows' weight spans 4.5 stops, so per-pixel flattens fine texture less than the extreme case, and much of a real photo's shadow detail is larger than the window and stays in the base.
- **Radius and `epsilon` kept at 3% and 0.25** (the design's start). A sweep of radius 1.5–10% by `epsilon` 0.1–1.0 trades texture against bleed along a smooth line with no free win: `epsilon` 1.0 keeps 0.78 of the shadows' texture but adds 0.13 EV of bleed over per-pixel, against 0.05 EV at 0.25. Highlights gain at every setting (0.91–1.00) with less bleed than per-pixel.
- **No visible halos.** The map of process 7's lift against process 6's follows the texture (brighter bits inside a shadow lifted more, darker less); along strong edges (a building against the street, a watch bezel) it's a thin line, not a band. The worst measured bleed, a portrait's beard against a dark background, is the bright hairs lifted with the shadow they sit in: the texture being kept.
- **One photo keeps less shadow texture** (DSC02005, 0.73 to 0.64): its darkest quarter is a near-black, noisy background, where the spread measured is mostly noise.
- **Cost:** the map takes 10 ms per photo from a 1024 px analysis image (17 ms at 2048), unoptimised; the kernel's sample and log add nothing measurable to a 60 MP export (about 1.5 s either way).
- **Whites and Blacks stay endpoints.** They're a white-point scale and a black-point offset after Highlights and Shadows, not weighted lifts: Whites −100 keeps all of the highlights' texture (1.18, the tone curve adds some), and Blacks +100's 0.55 is the black point lifting, the fade the control is for. Making it edge-aware would turn it into a fifth regional lift; revisit only if a Lightroom comparison shows Lightroom's Blacks keeps the texture.
- **Still open:** a comparison with Lightroom's own exports, and edge-aware Clarity on the same base (TON-06). `REDLAMP_TONE_RADIUS` and `REDLAMP_TONE_EPSILON` override the two settings, to tune.

## What it touches

`SessionBuilder` and `ImageSession` (the new map), `Develop.metal`, `KernelParams` and `DevelopParameters` (a texture and a flag), and `EditRecipe.currentProcessVersion` (7). The other session is working in several of these files (Heal and Clone); this lands after their change, or in coordination with it.

## Gates

Shipping waits on DEC-05 (the patent search includes the guided filter), as MSK-07's refinement does.
