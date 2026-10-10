# Clipped highlights pulled below white: design (CAM-31)

On the Nikon Z 8 sample (`tests/fixtures/cameras/Nikon_Z-8.NEF`, a pond under a bright sky, ISO 64, f/8), the sky around the sun clipped in the camera. At the defaults it renders white. Pulled below white, by Highlights −80 or Exposure −1.5 alone, it renders lilac-pink with a cyan band between it and the unclipped sky, identically in 0.2.6, 0.2.7 and 0.2.8. Since 0.2.7, Auto pulls such skies down itself (Exposure +0.31 and Highlights −80 on this sample), so Auto now shows the fault where 0.2.6's Auto (+1.30, −70) pushed the sky back past white.

The owner decided on 10 October 2026 that it is fixed properly, in rendering, under a new process version, for 0.2.9, rather than worked around in Auto. This document is the investigation and the design, for the owner to decide on. Nothing has landed on main.

Proposed tracker row: CAM-31 (below). Related rows: CAM-08 (Done, 6789502, the reconstruction this corrects) and CAM-09 (segmentation-based reconstruction of fully blown highlights, not started).

**Status (2026-10-10):** proposed. The candidates are prototyped in the engine on the local branch `fix/clipped-highlights-prototype` (a77757f9, f893ba93), behind environment variables that don't belong on main; the measurements' scripts are in `research/prototypes/highlights/`.

## What the sky is

The sky isn't clipped in all three colours. Green and blue clipped; red didn't.

| Raw (Z 8, black 1008, white 16383) | Red | Green | Blue |
| --- | --- | --- | --- |
| Photosites at 16383 | 162 | 852,769 | 663,002 |
| 99.9th percentile | 11,531 | 16,383 | 16,383 |
| As-shot multiplier, over the smallest | 1.908 | 1 | 1.537 |
| Clip level after white balance (0.99 × multiplier) | 1.889 | 0.99 | 1.522 |

Of the frame's 2 × 2 blocks, 7.08% have green and blue clipped (the sky round the sun), 1.87% only green (a band between it and the unclipped sky), and 143 blocks, 0.001%, all three (the sun's disc).

## The cause

Redlamp normalises the mosaic and multiplies each colour by its as-shot multiplier over the smallest (`rl_cfa_normalize`, `Demosaic.metal` line 24; `SessionBuilder.balance`, `SessionBuilder.swift` lines 211–213). Photosites that clipped at the same raw level therefore clip at different white-balanced levels: on the Z 8, red at 1.889, green at 0.99, blue at 1.522. In that proportion the clip levels themselves are magenta. CAM-08 then rebuilds clipped photosites (`HighlightModel.swift`, `rl_cfa_reconstruct_highlights` in `Demosaic.metal`), and three things in it combine on this sky. Line numbers are origin/main at 5171eebd.

1. **The colour model is fitted on the wrong pixels.** `HighlightModel.fit` learns how far each colour sits from the others, in cube-root space, on the unclipped rim of clipped areas. It accepts a rim block only when every colour reaches half of *its own* clip level (`HighlightModel.swift` lines 34 and 37). Red's multiplier of 1.91 puts that bar at 0.944 for red, while the sky's red is about 0.9 where green starts to clip. So the sky's own rim is rejected: 210 of 58,723 rim blocks pass, warm ones from another surface (mean R 1.051, G 0.864, B 0.925). The fit says green and blue sit below red.
2. **A prediction below the clip level becomes the clip colour.** Where green and blue clipped, both are predicted from red alone with those offsets, and land below their own clip levels. The kernel clamps a prediction to between the clip level and four times it (`Demosaic.metal` line 245), so green and blue stay at 0.99 and 1.522 while red is 1.145: white-balanced R 1.145, G 1.011, B 1.511 on average, lilac. Where every colour clipped the kernel writes the lowest neutral consistent with all three clip levels (line 238); that case is neutral, but here it is only the sun's disc.
3. **Red neighbours fail the same test.** The kernel only uses an unclipped neighbour that reaches half of *its own colour's* clip level (`Demosaic.metal` line 229). In the band where only green clipped, red sits just under 0.944, so green is predicted from blue alone and comes out about as high as blue: cyan.

At the defaults these colours are far enough above white that the tone curve's shoulder renders them white, which is why only pulling them down shows them. The white level isn't at fault: `WhiteLevel.measured` finds the clip spike at 16383 as it should.

A NumPy model of these stages (`research/prototypes/highlights/cam08.py`) reproduces the colours, and 0.2.8's own renders confirm them: at Highlights −80 the sky averages sRGB (227, 216, 248) and the band (217, 232, 244).

## Which samples show it

The camera coverage set, the development samples and the shoot scenes were surveyed for clipping. Neither X-Trans sample clipped at all (the X-T5's brightest green is 11,852 of 16,383), so unclipped raws were also overexposed: pushed 2 stops and clipped at their white level, which gives the truth to score against.

| Sample | Clipped blocks | On main, pulled down |
| --- | --- | --- |
| Nikon Z 8 | 8.95% (G 1.87%, G+B 7.08%) | Lilac sky, cyan band |
| Google Pixel 4a | 2.60% (G 0.76%, G+B 1.44%, all 0.38%) | Lilac sky between trees: sRGB (234, 210, 249) at Exposure −3 |
| Panasonic S5 II | 0.87% (G 0.81%, G+B 0.05%) | Pink where green and blue clipped: (174, 155, 169) at −3 |
| Sony A7 III (`_DSC0009.ARW`) | 0.86% (G 0.74%, G+B 0.11%) | A cyan band: hue −121° in OKLab against −87° beside it |
| Panasonic G9 | 1.46% (G) | No fault: one colour clipped |
| OM System OM-1 II | 1.01% (G 0.89%) | No fault |
| Sony A7 IV | 0.45% (G 0.24%, G+B 0.19%) | No fault: near neutral |
| Fujifilm X-T3 (`AFXT2720.RAF`), +2 stops | 30.6% (G 14.1%, R+G 3.1%, G+B 2.9%, all 10.5%) | Lilac where green and blue clipped: (148, 128, 155) at −1.5, truth (147, 148, 153) |
| Fujifilm X-T5, +2 stops | 24.0% (G 12.3%, G+B 10.7%, all 1.05%) | A cyan band: (110, 132, 138), truth (111, 122, 141) |
| Canon EOS R6, +2 stops | 3.9% (G 3.3%, G+B 0.55%) | No fault: its clipped objects were near neutral |

The fault needs two colours clipped where the third is well below its own white-balanced clip level, which is what a daylight-balanced sky near the sun gives. It is in the reconstruction, so Bayer and X-Trans have it alike.

## How others handle it

Read for understanding only. darktable's code and manual are GPL-3.0, RawTherapee's code GPL-3.0 and its RawPedia CC BY-SA 3.0; nothing here copies them, and the candidates below are written from the papers and from Redlamp's own CAM-08.

- **Adobe Lightroom and Camera Raw** document that Camera Raw "can reconstruct some details from areas in which one or two color channels are clipped to white" (Recovery, PV2010 and PV2003), and that dragging Highlights to the left (PV2012) darkens highlights and recovers "blown out" detail ([Camera Raw help](https://helpx.adobe.com/camera-raw/desktop/using/make-color-tonal-adjustments-camera.html)). Adobe doesn't document what fully clipped areas become; that they render neutral is how they look, not a documented rule.
- **darktable** ([manual 5.6](https://docs.darktable.org/usermanual/5.6/en/module-reference/processing-modules/highlight-reconstruction/)) runs highlight reconstruction on the raw data after white balance and before demosaicing, and explains the pink as above: with green clipped, white balance lifts red and blue past green's clip. Its methods: *clip highlights* clamps every colour to the white level (neutral, data lost); *reconstruct in LCh* rebuilds each sensor block in LCh (monochrome highlights); *inpaint opposed*, the default, restores clipped pixels from an average of the other colours with a correction sampled next to clipped areas, and "may fail where the clipped areas are adjacent to areas of a different color"; *segmentation based* colours each clipped area from its own surroundings, rejecting dark and edge pixels, and rebuilds areas where every colour clipped from the surrounding gradients; *guided laplacians* (Bayer only) propagates gradients and colour from valid channels by multi-scale diffusion. Its filmic module adds a later reconstruction that can desaturate to white. The repository's darktable study ([findings §3](../research/darktable-findings.md#3-cameras-and-raw-data), [notes §2.6](../research/darktable/notes/A-cameras-and-raw.md)) recorded the same; CAM-08 took its idea from inpaint opposed.
- **RawTherapee** ([RawPedia, Exposure](https://web.archive.org/web/2025/https://rawpedia.rawtherapee.com/Exposure); the live site is down) offers *Luminance Recovery* ("recovered details will be neutral gray"), *CIELab*, *Blend* (the closest unclipped highlight nearby), *Color Propagation* (bleeds the surrounding colour into the clipped area; best on small areas, can bleed wrong colours) and *Inpaint opposed*, "sensitive to white balance settings".
- **Papers.** Zhang and Brainard (2004) estimate saturated values from the correlation between colours, of which CAM-08 is the constant-chromaticity case. Masood, Zhu and Tappen (2009) correct saturated regions from cross-channel correlation with a smoothness prior over the region. Guo, Cheng, Zhuo and Sim (2010) recover lightness, then propagate colour from neighbouring unclipped pixels. Xu, Doutre and Nasiopoulos (2011) correct clipped pixels from the unclipped channels' correlation. Rouf, Lau and Heidrich (2012) restore clipped highlights in the gradient domain from the unclipped channels. Each assumes a clipped area continues its unclipped surroundings' colour; none keeps a clip level as the answer.

Three families come out of these: neutral (clip, LCh, Luminance Recovery), one colour fitted next to all clipped areas (inpaint opposed, CAM-08), and each area's own surroundings' colour (segmentation, Color Propagation, the papers). Where all three colours clipped there is nothing to rebuild from, and everyone ends at neutral or at a guess from around the area.

## Candidates

All were built into the engine (`HighlightModel.swift`, `rl_cfa_reconstruct_highlights`, and a new `rl_cfa_neutralize_highlights`) and chosen by `REDLAMP_PROTO_HIGHLIGHTS`. `REDLAMP_PROTO_OVEREXPOSE` overexposes a mosaic for the synthetic tests, and the CLI's `--proto-auto` applies Auto's values as the engine computes them. Before any change, the worktree's CLI rendered the Z 8 identically to the released 0.2.8 (largest difference 0 of 65535).

- **A: CAM-08 corrected.** Brightness is judged against the lowest clip level (green's, in daylight) rather than each colour's own: a rim block is a reference when every colour reaches half the lowest clip level, and an unclipped neighbour counts when it reaches half of it. One line in `HighlightModel.fit` and one in the kernel. (A first form took rim blocks with any colour within 80% of its clip; it let bright foliage tint the G9's sky gaps, and was dropped.)
- **B: A, then two- and three-colour clipping faded to neutral.** A second pass moves photosites towards the brightest colour's local mean, the lowest neutral none falls below, by a weight of a half where two colours clipped and one where three did, blurred over about 16 photosites. Lightroom-like neutral for deep clipping.
- **C: each clipped area's own border colour.** The rim's colour offsets are filled into the clipped areas by pull-push over a coarse grid (8 or 12 photosites a cell), so each area takes its surroundings' colour, and fully clipped areas fade to neutral with distance. The segmentation family, without segments.
- **D: A, with only areas clipped in every colour faded to neutral.** B's pass with weight zero where two colours clipped.
- **E: D, with a second clipped colour estimated first, and the fade only near the clip.** Where one other colour clipped too, it is first predicted from the one observed (and kept at least at its clip level), and the clipped colour is then predicted from both, so a colour no longer switches from two observed colours to one where a second colour starts to clip, the faint edge A and D leave. The neutral fade reaches only photosites at 0.8 of their clip level or more (fully from 0.9), so unclipped detail beside a blown area keeps its colour. Its first form faded every photosite in reach and moved, on the Pixel 4a, 0.016% of the pixels away from clipped areas by more than 0.5 (OKLab × 100, largest 8.4); limited, 0.0004% (largest 3.1).
- **E8: E, with rim blocks also near clipping** (their brightest colour at least 80% of its own clip level). Measured as a variant.

### Measurements

Engine renders, 2048 pixels on the long side. Colours are averages over each class of clipped colours, a few pixels in from its edges. *Hue* is the OKLab hue angle (−90° blue, −60° violet-lilac, −120° cyan). *Edge* is the 99th percentile of the OKLab a, b gradient (× 100 per 10 pixels) on bright flat ground within 12 pixels of a change of class: where a band shows. *Elsewhere* is the largest OKLab difference (× 100) from main more than 6 pixels from any clipped block. The Mac's load average was 70 to 90 throughout, so no timing below means anything.

**The Z 8** (the sky where green and blue clipped, and the band where only green did):

| Setting | main (process 14) | A | B | C | D | E |
| --- | --- | --- | --- | --- | --- | --- |
| Highlights −80: sky sRGB, hue | 227 216 248, −59° | 230 234 247, −87° | 239 240 246, −87° | 230 230 246, −74° | as A | 230 235 247, −91° |
| Exposure −1.5: sky | 209 193 237, −59° | 209 216 236, −88° | 222 225 234, −87° | 210 210 235, −74° | as A | 209 217 236, −92° |
| Exposure −1.5: band | 194 214 229, −118° | 194 206 231, −94° | as A | 194 206 231, −95° | as A | as A |
| Exposure −1.5: edge | 5.68 | 1.13 | 1.27 | 2.46 | 1.13 | 0.48 |
| Exposure −3: edge | 6.14 | 1.64 | 1.71 | 3.74 | 1.64 | 0.61 |
| Auto: Exposure | +0.31 | +0.28 | +0.27 | +0.32 | +0.28 | +0.28 |
| Elsewhere, fixed settings | — | 0.58 | 0.97 | 0.58 | 0.58 | 0.58 |

Auto sets Highlights −80, Contrast 8, Shadows +15 and Vibrance 10 for every candidate; only its Exposure moves. Unclipped sky measures 0.25 on the edge measure, so E's edges are 2 to 2.5 times the sky's own gradient, where main's are 23 to 25 times it. E8 measured as E but for its edges, 0.63 and 1.01.

**The other real samples**, at Exposure −3:

| Sample, area | main | A | B | E |
| --- | --- | --- | --- | --- |
| Pixel 4a, green and blue clipped: sRGB, chroma | 234 210 249, 0.061 | 236 239 248, 0.014 | 242 242 248, 0.007 | 236 240 248, 0.013 |
| S5 II, green and blue clipped | 174 155 169, 0.030 | 171 168 169, 0.004 | 171 169 170, 0.003 | 171 169 169, 0.003 |
| A7 III, hue where only green clipped, and beside it | −121°, −87° | −86°, −78° | −86°, −78° | −86°, −80° |
| A7 III, edge | 8.34 | 2.74 | 2.30 | 2.34 |
| G9, green clipped (sky through leaves) | 147 153 157 | 145 158 155 | as A | as A |
| OM-1 II, green clipped | 150 153 147 | 150 150 148 | — | 150 150 148 |

**Overexposed 2 stops, against the truth** (the unclipped original rendered at the same final exposure): mean OKLab difference × 100 over clipped pixels, at Exposure −1.5 and −3.

| Sample | main | A | B | C | D | E | E8 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| X-T3 (X-Trans) | 5.17, 3.92 | 3.74, 2.80 | 3.27, 2.42 | 3.40, 2.68 | 3.58, 2.67 | 2.99, 2.25 | 3.00, 2.28 |
| X-T5 (X-Trans) | 3.43, 2.85 | 1.16, 1.11 | 1.58, 1.42 | 2.20, 1.93 | 1.16, 1.11 | 1.05, 1.02 | 1.01, 0.99 |
| R6 (Bayer) | 0.53, 0.37 | 0.52, 0.36 | 0.53, 0.37 | 0.57, 0.40 | 0.52, 0.36 | 0.52, 0.36 | 0.51, 0.36 |

At Exposure −1.5, where green and blue clipped, the X-T3's truth is (147, 148, 153): main (148, 128, 155), E (148, 146, 151). The X-T5's is (143, 157, 177), a blue sky: main (148, 148, 162), B (158, 161, 170), E (146, 155, 172). Where only green clipped on the X-T5, the truth is (111, 122, 141): main (110, 132, 138), E (111, 121, 141).

### What the measurements say

- **The lilac and the band come from A's two tests.** Judging brightness against the lowest clip level fits the sky's own rim and uses its red, so the sky and the band take one hue: −88° and −94° on the Z 8, where main gave −59° and −118°. Every real sample's lilac, pink or cyan becomes the colour around it, and on the overexposed X-Trans samples A cuts main's error by 28% (X-T3) and by two thirds (X-T5).
- **E removes the last edge and is closest to the truth.** Predicting from both colours where a second one clipped brings the Z 8's edge measure from 1.13 to 0.48 at Exposure −1.5 and from 1.64 to 0.61 at −3, and E has the lowest error on the X-T3 and, within 0.04 of E8, on the X-T5.
- **B's neutral is a look, and the truth disagrees with it.** Fading two-colour clipping to neutral turns the area round the Z 8's sun white-grey (chroma 0.013 at −1.5), with a soft visible boundary where blue starts to clip. On the X-T5, whose clipped sky really was blue, B's error is 36% above A's.
- **C needs more than a prototype.** Filling each area with its border's colour falls back on the clip floor deep inside a large area whose border is far away (hue −74° on the Z 8), and its error on the X-T5 is nearly twice A's. It is CAM-09's direction, not this fix's.
- **E8 doesn't pay for itself.** Requiring rim blocks near clipping scores within 0.04 of E against the truth, either way, but leaves stronger edges on the Z 8 (1.01 against 0.61 at −3).
- **The rest of the photo doesn't move.** Changes stop within about 60 photosites of clipped areas, as far as the demosaic and colour noise reduction's coarsest scales carry a corrected colour: on the A7 III, beyond 20 render pixels (58 photosites) nothing moves more than 0.26, and beyond 48 nothing at all. On the Z 8 nothing more than 6 pixels from a clipped block moves more than 0.58. Unclipped highlights don't change: the reconstruction only writes photosites at or above their clip level, and E's fade only those near it.

The limits: one colour offset per photo, fitted on the rims of all its clipped areas, so two differently coloured clipped surfaces share it, as with darktable's inpaint opposed. On the G9's sky seen through leaves, A to E render the gaps slightly greener than main (sRGB 145, 158, 155 against 147, 153, 157); without a truth it can't be said which is right, and a rim that is mostly sky mixed with leaves is the likely cause. Fully clipped areas are the lowest consistent neutral, not a continuation of their surroundings' brightness. Both are CAM-09's work.

Pictures, under `/tmp/clipped-highlights/pictures/`:

- `z8-sky-main-vs-proposed.jpg`: main against E on the Z 8's sky at the defaults, Highlights −80, Exposure −1.5 and Auto.
- `pixel4a-main-vs-proposed.jpg` (Exposure −1.5 and −3), and `xt3-over2-truth-main-proposed.jpg` and `xt5-over2-truth-main-proposed.jpg` (the truth, main and E at −1.5).
- `<sample>-<setting>.jpg`: a strip of every candidate, for `z8`, `pixel4a`, `s5`, `dsc0009`, `g9`, `om1`, `a7iv`, `xt3-over2`, `xt5-over2` and `r6-over2`, at `defaults`, `highlights-80`, `exposure-1.5`, `exposure-3` and `auto` (not for the overexposed ones).

The owner's own strips are in the release room (`0.2.8-auto-pink-sky.jpg`).

## Recommendation: E

E rebuilds a clipped colour from the colours that didn't clip, in the colour of the clipped area's surroundings, and only falls back on neutral where every colour clipped: what Adobe documents for one or two clipped colours, and what every published method assumes. On every sample it removes the lilac, the pink and the cyan band, leaves no visible edge, is closest to the truth where there is one, and changes nothing beyond about 60 photosites of a clipped area. It is CAM-08 corrected rather than a new algorithm: two brightness tests, one joint prediction, and one pass over areas clipped in every colour.

## Under a new process version

### What renders differently

Only edits at the new process version (15, unless another change takes it first), only raws with clipped photosites (where `HighlightModel.fit` finds any; linear DNGs and bitmaps have no reconstruction), and only in clipped areas and within about 60 photosites of them. What is worked out from the pyramid moves with it on those photos: Auto's values (the Z 8's Exposure +0.31 becomes +0.28), and Highlights' tone base, Dehaze's haze map and the glow sources near clipped areas. Edits at process 14 and before render exactly as now.

### Raw stages by process version

The raw stages have never been gated by process version. A session's pyramid is built when a photo opens, from the decoded file alone, before any edit is known, and CAM-05 to CAM-08 changed every edit (CAM-07 by the owner's decision, DEC-40). This is the first raw-stage change under a process version, so it needs the mechanism:

- **A raw revision per process version.** `RawRevision(processVersion:)`: revision 1 for processes 1 to 14, revision 2 from 15. `SessionBuilder.build(_:revision:)` and `HighlightModel.fit(_:balance:revision:)` take it.
- **The open photo's session holds the current revision**, built as now, and records whether its raw stages depend on the revision at all: a photo with nothing clipped builds the same pyramid at every revision and serves every edit.
- **An older edit of a photo that clipped renders from a variant session,** built from the session's decoded image at the edit's revision, with its own pyramid and maps, and kept beside the photo's retouched copies. `RetouchStage.session(for:base:...)` is the pattern: it already picks a per-edit session at render time by the edit's process version (`recipe.processVersion >= 12`). The retouch stage then works on the variant, so an older edit's spots render over the older reconstruction.
- **Everything that reads pixels for an edit uses its revision's session:** renders and stills, Auto (`autoTone(for:)` has the recipe), the readout, point colour, and masks computed for the edit. AI masks already stored in an edit stay as they are.
- **Cost:** a second build (about the time of opening the photo, 1.2 s for the Z 8 on this Mac) and a second pyramid (about 480 MB for 45 megapixels), only while an older edit of a photo that clipped is shown. Updating that edit's process version drops the variant.

Two cheaper routes were considered. A correction in `rl_develop` for process 15, from a map of clipped colours, would gate per render without a second session, but it would work on demosaiced, noise-reduced and mipmapped values CAM-08 already got wrong, and Auto, the masks and Highlights' tone base would keep seeing the old pyramid. Letting the change reach every edit, as CAM-07 did, is one line, but it changes existing edits of clipped photos, which the owner has decided against.

## Implementation

1. `HighlightModel.fit`: the rim test against half the lowest clip level; the revision; the neutral-fade weight where all three colours clipped (a coarse grid, 4 blocks a cell, blurred over 2 cells), made on the GPU or in the single pass of the clipped-block scan it already makes.
2. `rl_cfa_reconstruct_highlights`: the neighbour test against half the lowest clip level, and the joint prediction where one other colour clipped. Revision 1 keeps today's code path untouched.
3. `rl_cfa_neutralize_highlights`: the fade towards the local brightest-colour mean, only for photosites near their clip level.
4. The raw revision in `SessionBuilder`, `ImageSession` and `SessionCache`, and a variant stage beside `RetouchStage`, with the readers above taking the edit's session.
5. `EditRecipe.currentProcessVersion` to 15, the sidecar schema's maximum and the table in `docs/recipes/sidecar-format.md`: "Highlights the camera clipped in one or two colours are rebuilt with the colour of what's around them, and areas clipped in every colour fade smoothly to neutral, so a sky clipped in green and blue no longer turns lilac, with a cyan band, when Highlights or Exposure pull it below white."

Size: M (1 to 3 engineer-weeks), most of it the raw revision; the reconstruction is small.

## Tests and references

- **Reconstruction** (synthetic mosaics built in the test, `RedlampServices` and `RedlampEngine`): a daylight-balanced sky gradient clipped in green and blue fits its offsets from its own rim and renders within a few degrees of its unclipped part's hue; no step where a second colour starts to clip (the edge measure against the unclipped gradient); an area clipped in every colour renders neutral and the fade leaves unclipped photosites beside it unchanged; saturated foliage beside a clipped area isn't taken for its rim; the same on an X-Trans pattern.
- **Against the truth:** the X-T3 and R6 development samples overexposed 2 stops come closer to their unclipped originals than process 14 does, by a margin the test states; they skip without the fixtures, as the camera goldens do.
- **Process stability:** `ProcessStabilityTests` passes unchanged for processes 1 to 14. Two of its four raw fixtures clipped (the A7 III's 0.86%, the Pixel 4a's 2.6%), so an ungated change fails it. Process 15's references are recorded with `TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1`, which writes only the missing ones.
- **The variant session:** one open photo renders a process 14 edit as before and a process 15 edit with the new reconstruction; switching between them doesn't rebuild the current revision; the variant is released with the photo (`EngineMemoryTests`).
- **Camera goldens** (`CameraGoldenTests`) render the default edit at the current version, so a patch on a clipped area may move; such a patch is re-recorded in the same change, which names it.
- **Sidecar schema** (`SidecarSchemaTests`): the maximum and the table row.
- **Performance:** opening a 45-megapixel photo that clipped is recorded on a quiet Mac after merge (`.cursor/rules/performance.mdc`).

## Changes to docs/raw-pipeline.md

- The header's date and process version (it says 12; main is at 14).
- §7, step 3: the brightness tests against the lowest clip level, the joint prediction, the neutral fade of areas clipped in every colour, and that processes 1 to 14 keep the reconstruction as it was.
- §11: replace "Raw-stage changes reach every edit, since the raw stages aren't gated by version" with the raw revision, the variant session and how a raw-stage change adds a revision; `currentProcessVersion` is 15.
- §13, Known gaps: one colour offset per photo, and fully clipped areas at the lowest consistent neutral (CAM-09).
- §14, Changing a raw stage: add a raw revision and map the new process version to it.
- §15, Constraints: a prediction held at its clip level is the white-balanced clip colour, magenta in daylight, so brightness tests use the lowest clip level; anything that reads an edit's pixels uses its revision's session.

## Proposed tracker row

Section 3, Cameras and raw data:

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CAM-31 | Clipped highlights keep a plausible colour once Highlights or Exposure pull them below white: CAM-08's brightness tests judged against the lowest white-balanced clip level instead of each colour's own (red's multiplier put a daylight sky's own rim and its red neighbours out of reach, so skies clipped in green and blue turned lilac with a cyan band, on the Nikon Z 8, Pixel 4a, Panasonic S5 II and X-Trans alike), a second clipped colour estimated before predicting from both, and areas clipped in every colour faded smoothly to neutral; under a new process version, with the raw stages built per process version for older edits (a variant session per raw revision, as RetouchStage keeps retouched copies) | Do better | P2 | M | CAM-08 | Accepted (2026-10-10): the owner asked for it | Not started | The owner (2026-10-10), from 0.2.8's Auto on the Z 8 sample; [design](../plans/2026-10-10-clipped-highlights-design.md) |

It isn't CAM-09's work: CAM-09 rebuilds fully blown areas from their surroundings by segmentation; this corrects CAM-08 where one or two colours clipped and leaves fully blown areas neutral.

## Questions for the owner

1. **Two-colour clipping: the surroundings' colour or neutral?** E keeps the Z 8's sky blue to the sun's disc; B turns the area round the sun white-grey, with a soft visible edge. Lean: E's colour. Adobe documents rebuilding from one or two clipped colours, the X-T5's truth was blue where B made it grey, and neutral can still be had with Highlights and Saturation, while B's grey can't be undone. A Lightroom export would settle it (question 3).
2. **The process-version route:** a variant session per raw revision (M; exact; reusable for CAM-09 and any later raw-stage change), a correction at render time (S; approximate; Auto, the masks and Highlights' tone base keep the old pixels), or letting it reach every edit as CAM-07 did (S; changes existing edits). Lean: the variant session.
3. **Lightroom on the Z 8 sample:** a Redlamp Bench task, Highlights −80 and Exposure −1.5 exported from Lightroom, to see whether it keeps the sky blue or turns it neutral round the sun. Not blocking. Lean: yes, before the implementation starts.
4. **0.2.9's scope.** The fix is M, most of it the raw revision, and without the revision it can only land by changing existing edits. Lean: hold 0.2.9 for it if its date allows; otherwise ship it in the release after.

## References

- X. Zhang, D. H. Brainard, "Estimation of saturated pixel values in digital color imaging", *JOSA A* 21(12), 2301–2310, 2004, doi:10.1364/josaa.21.002301.
- S. Z. Masood, J. Zhu, M. F. Tappen, "Automatic correction of saturated regions in photographs using cross-channel correlation", *Computer Graphics Forum* 28(7), 1861–1869, 2009, doi:10.1111/j.1467-8659.2009.01564.x.
- D. Guo, Y. Cheng, S. Zhuo, T. Sim, "Correcting over-exposure in photographs", *CVPR* 2010, 515–521, doi:10.1109/cvpr.2010.5540170.
- D. Xu, C. Doutre, P. Nasiopoulos, "Correction of clipped pixels in color images", *IEEE TVCG* 17(3), 333–344, 2011, doi:10.1109/tvcg.2010.63.
- M. Rouf, C. Lau, W. Heidrich, "Gradient domain color restoration of clipped highlights", *CVPR Workshops* 2012, 7–14, doi:10.1109/cvprw.2012.6239193.
- S. J. Gortler, R. Grzeszczuk, R. Szeliski, M. F. Cohen, "The Lumigraph", *SIGGRAPH* 1996 (pull-push, candidate C).
- Adobe, [Make color and tonal adjustments in Camera Raw](https://helpx.adobe.com/camera-raw/desktop/using/make-color-tonal-adjustments-camera.html), read 10 October 2026.
- darktable 5.6 user manual, [highlight reconstruction](https://docs.darktable.org/usermanual/5.6/en/module-reference/processing-modules/highlight-reconstruction/), GPL-3.0, read 10 October 2026.
- RawPedia, [Exposure](https://web.archive.org/web/2025/https://rawpedia.rawtherapee.com/Exposure), CC BY-SA 3.0, the Wayback Machine's copy of 1 February 2025.
- Redlamp: [raw pipeline](../raw-pipeline.md), [sidecar format](../recipes/sidecar-format.md#process-versions), [darktable findings §3](../research/darktable-findings.md#3-cameras-and-raw-data).
