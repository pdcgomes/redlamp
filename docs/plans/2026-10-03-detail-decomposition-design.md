# One decomposition for detail: design (TON-06, #26)

The detail stage (`DetailStage.swift`, `DetailStage+Sharpen.swift`, `Denoise.metal`, `Sharpen.metal`, `LocalContrast.metal`, `DetailLocal.metal`) runs noise reduction, then capture sharpening, then Texture and Clarity, each with its own filters: sharpening's Gaussian of the Radius, Texture's ratio of the pyramid's levels 1 and 3, Clarity's level 3 against an edge-preserving base. TON-06's last item asks for Texture, Clarity and Sharpening on one multiscale decomposition. This document measures today's stage and proposes that decomposition, to ship as process version 10 once the owner approves it (wave 4, W4-DESIGN; the build is W4-BUILD).

## Summary

- **The decomposition:** a ladder of four B3-spline à-trous scales of the noise-reduced image's linear Rec. 2020 luminance, per work area, after noise reduction. Texture and Clarity read it as log ratios of its levels, as they read the pyramid today; sharpening reads it as its noise separator, in place of the second noise-reduction run it makes now.
- **Sharpening keeps Richardson–Lucy.** Deconvolution doesn't fit band gains: its response as gains on the bands loses 0.1–0.5 dB in linear light and 0.4–0.8 dB in log luminance against four iterations. The separator on the ladder costs 0.04–0.09 dB.
- **Texture gets a soft limit and reads the noise-reduced image.** At a 3.3-stop edge Texture +100 darkens the dark side by 0.30 stops instead of 1.74; on four real photos its change beside strong edges drops from 0.98–1.43 stops to 0.30 (99th percentile) with the same boost on texture away from them (−4% to +2%). After noise reduction it adds 65% to the remaining noise instead of 115%.
- **The fitted preview shows Texture about as strongly as an export does at every size:** 0.82–1.26 over 24 photo and size cases with a weight per level (the build adds a term for the position within the level, aiming at 0.9–1.1), against 0.56–1.12 today, which fails at level 3 (0.63 at 700 px of a 6000 px photo).
- **Cost:** about the same uncached; dragging Texture, Clarity, Amount, Detail or Masking becomes one pass (2.9 ms to about 0.4 ms at 1:1, 15.7 to about 1.5 ms at fit on a Retina window); dragging a noise slider becomes slower (5.3 to about 9 ms at 1:1), because sharpening now measures the noise-reduced image.
- **Process 10:** new edits only; processes 1 to 9 keep today's code paths, checked by the process-stability gate.

## Today's stage, measured

Measured on an M1 Ultra (48-core GPU, 128 GB) running macOS 26, with `DSC_0750.NEF` (6064×4040, Nikon) from `tests/fixtures/raw`, on branch `w4/detail` at 397ff39. Other sessions were building throughout: the one-minute load average is beside each set of numbers. The harness was a temporary test suite in the worktree and a Python model of the stage under `/tmp`; neither is committed (see Method).

### GPU time per sub-stage

Median GPU time of the stage's command buffer over 16 runs submitted back to back, two runs (load 60–64 and 76–77; ranges where they differ by more than 10%). The 1:1 view is 2560×1600 pixels; "fit" renders the whole photo at the size given, which on a Retina window puts the stage at level 0 over the whole frame. Sub-stage times come from recipes that turn on one sub-stage at a time.

| Sub-stage, ms | 1:1 (level 0, 2689×1728 texels) | Fit 3900×2600 (level 0, 6064×4040) | Fit 2400×1600 (level 1, 3032×2020) | Fit 1200×800 (level 2, 1516×1010) |
|---|---|---|---|---|
| Noise reduction, Color 25 (default) | 2.5 | 13.6–14.5 | 3.3–3.8 | 0.6–0.7 |
| Noise reduction, Luminance 50 and Color 25 | 4.9–5.0 | 26.8–28.2 | 5.0–6.1 | 1.0–1.2 |
| Sharpening's separator | 1.9–2.9 | 9.3–13.8 | 2.9–3.9 | skipped |
| Sharpening's Richardson–Lucy and blurs | 2.4–2.5 | 15.3 | 2.4–2.8 | skipped |
| Sharpening's apply | 0.14–0.20 | 0.86–0.92 | 0.19–0.26 | skipped |
| Texture 50 | 0.25 | 1.6–1.8 | 0.23–0.27 | 0.05 |
| Clarity 50 (process 9) | 0.18–0.20 | 1.35 | 0.28–0.31 | 0.06 |
| Texture and Clarity together | 0.36–0.38 | 2.6 | 0.45–0.52 | 0.08 |
| Masks' amounts (one gradient) | 0.22–0.29 | 1.0–1.3 | 0.31–0.37 | 0.05 |
| Default edit (Color 25, sharpening 40), uncached | 6.9–9.3 | 38.9–46.3 | 8.9–11.3 | 0.6–0.7 |
| Heavy edit (Luminance 50, sharpening, Texture, Clarity, a mask), uncached | 10.1–12.8 | 56.0–65.0 | 11.4–14.3 | 1.3–1.5 |
| Dragging Texture, default edit | 2.9 | 15.7 | 3.8 | 0.7 |
| Dragging Texture, with Luminance 50 | 5.3 | 28.9 | 5.4 | 1.1 |
| Dragging Radius | 2.6 | 16.1–16.3 | 2.6–3.0 | 0.5–0.6 |

- The separator is the uncached sharpening time less the Radius drag (which reuses it); Richardson–Lucy is the Radius drag less the apply.
- Texture and Clarity cost little themselves (0.2–0.4 ms at 1:1). Dragging them is expensive because the stage caches only its output: every Texture step reruns noise reduction.
- At fit on a Retina window the stage processes 24 megapixels: the default edit costs 39–46 ms.

### Preview against export (ARC-04)

The fitted preview's change in luminance against a same-size export's (full resolution, then Lanczos), as `PreviewExportTests` measures it on `DSC_0750.NEF` (load 72–82). The gate's range is 0.8–1.25 with correlation above 0.85.

| Filter | 700 px | 1000 px | 2000 px |
|---|---|---|---|
| Texture +60 | 0.63 (correlation 0.80) | 1.00 (0.93) | 1.11 (0.97) |
| Texture −60 | 0.58 (0.75) | 0.96 (0.89) | 1.07 (0.94) |
| Texture +100 | 0.64 (0.81) | 1.02 (0.94) | 1.12 (0.98) |
| Clarity +60 | 0.95 (0.99) | 0.98 (0.99) | 0.99 (0.99) |
| Sharpening 40 to 100 | none | none | 0.34 (0.65) |

- **It isn't the measurement.** With 16-bit exports Texture +60 reads 0.65, 1.02 and 1.12; with Color noise reduction, sharpening and the lens profile off, the same. A Python model of the stage (box mips, the cubic B-spline sampling, the develop kernel's bilinear sampling, and a Lanczos downscale that agrees with `MPSImageLanczosScale` to 0.1%) reproduces 0.61, 0.99 and 1.08.
- **Where it comes from.** At 700 px the stage works at level 3, Texture's coarse level, so its band shrinks to the texels against their own smoothing. At 2000 px (level 1) the preview reads its rendered texels for the band's fine end where 1:1 reads level 1's B-spline, and boosts 4–12 px detail 2.0× where an export boosts it 1.1–1.8×.
- **A limit on any band:** even the unedited photo has 0.79–0.85× the export's amplitude at 0.25–0.5 cycles per output pixel in the preview (box mips and bilinear sampling against Lanczos), and at 700 px 80% of Texture's exported change lies there.

### Band responses

Gain in log luminance on stripes of ±0.05 stops (synthetic Bayer frames through the real session builder, sharpening with a near-noiseless model so its separator keeps the stripes), by period and work level:

| Setting | Level | 4 px | 6 px | 8 px | 12 px | 24 px | 48 px | 96 px |
|---|---|---|---|---|---|---|---|---|
| Texture +100 | 0 | 1.12 | 1.40 | 1.61 | 1.80 | 1.56 | 1.19 | 1.05 |
| Texture +100 | 1 | 1.98 | 1.99 | 2.00 | 1.99 | 1.61 | 1.20 | 1.06 |
| Texture +100 | 3 | | | | | 1.50 | 1.17 | 1.04 |
| Clarity +100 (process 9) | 0 | 1.00 | 1.00 | 1.00 | 1.04 | 1.47 | 1.92 | 1.98 |
| Clarity +100 (process 9) | 2 | | | 1.00 | 1.05 | 1.50 | 1.94 | 1.99 |
| Sharpening 100, Radius 1 | 0 | 1.56 | 1.31 | 1.19 | 1.08 | | | |
| Sharpening 100, Radius 1 | 1 | 1.16 | 1.12 | 1.08 | 1.04 | | | |
| Sharpening 100, Radius 2 | 1 | 1.72 | 1.73 | 1.58 | 1.32 | | | |

Clarity's band is the same at every level. Texture's is stronger at level 1 than at full resolution. Sharpening at Radius 1 shows about 40% of its 1:1 effect at level 1 (a Gaussian of 0.4 texels) and none at level 2 or beyond (it is skipped below 0.3 texels); Radius 2 is consistent.

### Strong edges at +100

Change in log luminance beside a step (synthetic, no noise, at 1:1): the peak within 48 px and the mean over 2–16 px, on each side.

| Setting | Dark side, peak | Dark side, 2–16 px | Bright side, peak | Bright side, 2–16 px |
|---|---|---|---|---|
| Texture +100, 3.3-stop step | −1.74 (10 px wide) | −0.45 | +0.41 | +0.05 |
| Texture +100, 1-stop step | −0.35 | −0.08 | +0.21 | +0.03 |
| Texture −100, 3.3-stop step | (lightens) | +0.23 | (darkens) | −0.03 |
| Sharpening 100 (Radius 1, Detail 25), 3.3-stop step | −0.10 (5 px) | 0.00 | +0.01 | 0.00 |
| Sharpening 100 (Radius 1, Detail 100) | −0.52 (5 px) | +0.01 | 0.00 | 0.00 |
| Sharpening 100 (Radius 2, Detail 25) | −0.14 (6 px) | −0.01 | +0.13 | 0.00 |
| Clarity +100 (process 9) | −0.15 (48 px) | −0.06 | +0.17 | +0.15 |

- **Texture has no limit**, and the log of a ratio of linear low-passes puts most of its halo on the dark side: a bright 2-pixel line on a dark ground gains 1.58 stops and darkens 0.65 stops beside it. On four real photos (Nikon, Pentax K-1 Mark II, Nikon Coolpix P7700, Sony A7C II), the 99th percentile of Texture +100's change within 2–12 px of strong edges is 0.98–1.43 stops.
- **Sharpening is held by its halo limit** (0.136 stops at Detail 25). Detail 100 leaves Richardson–Lucy's undershoot on the dark side (−0.52 stops): deconvolution in linear light undershoots by a larger share of a dark value.

### Noise

A flat noisy field (synthetic Bayer through the real builder, 2.95% relative noise in luminance), noise reduction at Luminance 60 and Color 25, then each control at +100:

| Level | After noise reduction | + Texture +100 | + Texture +50 | + Clarity +100 | + Sharpening 100 |
|---|---|---|---|---|---|
| 0 (1:1) | 0.63% | 1.36% | 0.95% | 0.82% | 0.64% |
| 1 (fit) | 0.31% | 0.61% | 0.45% | 0.43% | 0.30% |

Texture measures its band on the un-denoised pyramid (both ends at 1:1, its coarse end at fit), so it puts back noise that noise reduction removed; Clarity does too, less. Sharpening measures the separator's clean luminance and leaves noise alone.

## Design

### The decomposition

Per work area, after noise reduction:

- **Luminance:** Y, the noise-reduced image's linear Rec. 2020 luminance (`DetailStage.luma`), as sharpening reads it today.
- **Ladder:** c₀ = Y, c₍ₛ₊₁₎ = the B3 spline ([1, 4, 6, 4, 1] / 16, separable) with holes 2ˢ applied to cₛ, for s = 0 to 3; bands wₛ = cₛ − c₍ₛ₊₁₎. Kept as five half floats per texel (w₀ to w₃ and c₄), from which every level follows (c₃ = c₄ + w₃, c₁ = c₃ + w₂ + w₁, Y = c₁ + w₀).
- **Scales in full-resolution pixels:** scale s has holes of 2ˢ full-resolution pixels. At work level L the ladder starts from the texels, with holes 2ˢ⁻ᴸ texels (see Preview and export).

Why this form:

- **Linear luminance, read as log ratios.** A blur mixes linear light, so deconvolution has to stay linear: Richardson–Lucy's linearised response applied exactly (by FFT) to linear luminance comes within 0.05–0.09 dB of four real iterations, and the same response applied to log luminance loses 0.4–0.7 dB. Texture and Clarity are log ratios of linear low-passes today (log₂ of level 1 over level 3), so log₂(cₐ / c_b) keeps their character and their independence from exposure.
- **À-trous, undecimated.** Masks set gains per pixel and the separator shrinks bands per pixel; an undecimated transform does both without aliasing, which a Laplacian pyramid's decimated bands don't. Four scales cost 1.2 ms at 1:1 in a prototype kernel, separate noise as well as five (identical PSNR on the SHP-01 test set), and fit today's 64-texel margin after noise reduction (hard support 30 texels; with noise reduction's, an effective radius of about 62).
- **Not noise reduction's own coefficients.** Noise reduction decomposes the noisy texels in a variance-stabilised opponent space; the detail controls must measure the noise-reduced image in luminance. A coefficient in one space maps to the other only through a local slope, and the inputs differ, so reusing noise reduction's coefficients would make Texture depend on brightness and on noise reduction's internals (its thresholds, its non-local means). What the two share is the scale ladder, the B3 kernel and the margin budget.

### How each control reads it

**Texture.** detail_T = log₂(c₁ / c₃) (scales 1 and 2, detail of about 4 to 32 px). The boost is g · L · tanh(detail_T / L) with L = 0.25 stops and g = 1.2 × Texture / 100, or 0.5 × Texture / 100 for negative values as today.

- On stripes of ±0.15 stops, Texture +100 gains 1.30, 1.65, 1.94, 1.58 and 1.19 at 4, 6, 12, 24 and 48 px, against 1.12, 1.40, 1.80, 1.56 and 1.19 today: a little more on the finest detail.
- At a 3.3-stop step the dark side's peak is −0.30 stops (−1.74 today) and its 2–16 px band −0.18 (−0.45); at a 1-stop step, −0.27 and −0.09 (−0.35 and −0.08), so ordinary edges change little. On the four photos the change beside strong edges is 0.30 stops at the 99th percentile (0.98–1.43 today), and the mean boost on texture away from them is 0.122, 0.164, 0.139 and 0.156 stops against 0.120, 0.171, 0.141 and 0.153.
- Negative Texture keeps edges: Texture −100 lightens the dark side of the 3.3-stop step by 0.07 stops instead of 0.23.
- Read from the noise-reduced image (the engine's own noise reduction output, Luminance 60 and Color 25, on a noisy flat field), Texture +100 takes the remaining noise from 1.02% to 1.68% (today 2.19%), and boosts 12 px stripes that noise reduction left at 0.058 stops to 0.115 (today 0.132, with a third more noise beside them).

**Clarity.** detail_C = log₂ c₃ − base, with base = a · log₂ c₃ + b from Clarity's guided map (process 9's filter: a 32 px window, epsilon 0.25, gain 1.25, soft limit 0.5 stops). Texture's and Clarity's bands meet at c₃. The map is computed in the ladder's luminance for process 10 (once per photo, on first use): the guide and the band's fine end must use the same luminance, or a saturated flat area is offset by up to the difference between the two luminances (estimated at a few tenths of a stop for strong colours; not measured). Clarity's preview already matches (0.95–0.99). Reading the noise-reduced image should remove the noise Clarity adds today (0.63% to 0.82% above), which the prototype didn't measure.

**Sharpening.** The separator becomes a non-negative garrote on the ladder's bands at 3 noise sigmas of linear luminance per scale: D = c₄ + Σ garrote(wₛ, 3 σₛ(x)), with σₛ from the noise model at the local level and a new calibration table of the ladder's per-scale noise (as `NoiseCalibration` has for the opponent axes). Richardson–Lucy (4 iterations), the unsharp mask, Detail's mix, the halo limit, Masking and masks' negative Sharpness work on D as today.

| Mean PSNR gain over the input (14 crops per case) | Mild softness | Defocus | Noisy defocus |
|---|---|---|---|
| SHP-01, Radius 2, Amount 100, Detail 100 | +1.74 dB | +0.94 | +1.17 |
| Ladder separator, same | +1.66 | +0.90 | +1.08 |
| SHP-01, defaults (Radius 1, Amount 40, Detail 25) | +0.19 | +0.06 | +0.10 |
| Ladder separator, defaults | +0.17 | +0.05 | +0.09 |
| Band gains instead of Richardson–Lucy (linear light), Radius 2, Detail 100 | +1.38 to +1.45 | +0.73 to +0.85 | +0.67 to +0.92 |
| Band gains in log luminance, Radius 2, Detail 100 | +0.95 to +1.10 | +0.40 to +0.55 | +0.37 to +0.47 |

At Amount 100 and Detail 25, flat noise grows ×1.003–1.004 with the ladder separator against ×1.006–1.007 with SHP-01's (both ×1.001 at Detail 100). The separator now sees the noise-reduced image, so sharpening boosts the detail the user kept: today, with strong noise reduction, the separator (3 sigmas) keeps texture that noise reduction removed, and sharpening's ratio puts it back.

**Masks.** The amounts pass is unchanged. Each mask's Texture, Clarity and Sharpness add to the global amounts per texel before the gains, as today.

### Preview and export

At work level L the texels stand in for the ladder's finer levels. A band whose fine end is finer than the texels becomes the texels against the band's coarse end (or the level's first ladder level, when the coarse end is finer too), times a weight per level and per position within the level (p = output scale / 2ᴸ). The weights make the band's effect, after the preview's sampling, match the full-resolution band's after a Lanczos downscale; the build computes them offline from the filters' responses and fixes them in code. Where box texels are sharper than the ladder level they stand for, a [1, 6, 1] / 8 pass can match its variance instead; the build chooses between the two from the responses.

With weights per level only, fitted on the Nikon (0.99 at level 1, 1.11 at level 2, 0.68 at level 3 on texels against c₄), Texture +60 in the model:

| Photo | 700 px | 1000 px | 2000 px | Long edge ÷ 2.6 | ÷ 5.2 | ÷ 10.4 |
|---|---|---|---|---|---|---|
| Nikon 6064 px, today | 0.61 | 0.99 | 1.08 | 1.10 | 0.91 | 0.72 |
| Nikon, proposed | 1.01 | 1.00 | 1.00 | 0.99 | 0.90 | 1.26 |
| Pentax 4832 px, today | 1.03 | 0.86 | 1.11 | 1.12 | 0.89 | 0.56 |
| Pentax, proposed | 1.02 | 0.86 | 0.93 | 0.94 | 0.89 | 1.09 |
| Coolpix 4032 px, today | 0.96 | 0.83 | 1.10 | 1.11 | 0.91 | 0.65 |
| Coolpix, proposed | 0.95 | 0.82 | 0.95 | 0.96 | 0.90 | 1.19 |
| Sony 4692 px, today | 1.00 | 0.87 | 1.10 | 1.11 | 0.91 | 0.65 |
| Sony, proposed | 1.03 | 0.87 | 0.94 | 0.95 | 0.91 | 1.21 |

All 24 cases fall within 0.82–1.26 against 0.56–1.12 today. Correlations are 0.78–0.99; at level 3 they are 0.78–0.89 against today's 0.72–0.85, so about half the level-3 cases stay under the gate's 0.85, where today nearly all do. The remaining spread follows the position within the level (low near p = 1, high near p = 2), which the position term is for: the build's target is 0.9–1.1. Sharpening keeps today's behaviour at fit (gone below 0.3 texels, which ARC-04 records as Lightroom's behaviour too); the same rule could carry its low-frequency part, but it isn't prototyped and the gate doesn't measure it.

### Caching, tiling and margins

- **Margin:** 64 texels, as today.
- **Ladder cache:** the noise-reduced image and its ladder (8 + 10 bytes per texel) per work area, keyed by photo, area, noise settings and masks' Noise; two entries (the view and its overview): about 84 MB each at 1:1 on a 2560×1600 view and 440 MB at fit level 0. It replaces sharpening's separation cache; the analysis cache stays, keyed by the ladder's key and the Radius. The stage's output cache stays.
- **What a drag reruns:** Texture, Clarity, Amount, Detail, Masking and masks' Texture, Clarity and Sharpness rerun the apply pass only (and the amounts pass, for masks); Radius reruns Richardson–Lucy; a noise slider reruns noise reduction, the ladder and Richardson–Lucy.
- **Stills:** tiles as today, with no caches; Clarity's map is whole-image, so tiles agree.

### Expected cost

From the measured sub-stages, a prototype ladder kernel (4 scales, single channel: 1.17 ms at 1:1, 5.41 at fit level 0, 1.12 at fit level 1, load 50) and a prototype apply pass (0.15, 0.90 and 0.23 ms):

| ms | 1:1 today | 1:1 proposed | Fit level 0 today | Fit level 0 proposed | Fit level 1 today | Fit level 1 proposed |
|---|---|---|---|---|---|---|
| Default edit, uncached | 6.9–9.3 | about 6.5 | 38.9–46.3 | about 37 | 8.9–11.3 | about 7.3 |
| Heavy edit, uncached | 10.1–12.8 | about 9.5 | 56.0–65.0 | about 51 | 11.4–14.3 | about 9.6 |
| Dragging Texture, Clarity, Amount, Detail or Masking | 2.9 (5.3 with Luminance 50) | about 0.4 | 15.7 (28.9) | about 1.5 | 3.8 (5.4) | about 0.4 |
| Dragging Radius | 2.6 | about 2.7 | 16.3 | about 16.5 | 2.6–3.0 | about 2.7 |
| Dragging Luminance (default sharpening) | about 5.3 | about 9.2 | about 29 | about 50 | about 5.4 | about 9.2 |

The separator's noise-reduction run (1.9–2.9 ms at 1:1, 9–14 ms at fit level 0) gives way to the ladder (1.2 and 5.4 ms) and a garrote fused into Richardson–Lucy's first pass. Noise-slider drags pay Richardson–Lucy, which today stays cached across them.

## What changes visibly

Only in process 10:

1. **Texture** puts no halo along strong edges (beside them, 0.30 stops at +100 against 1–1.4), brings back no noise from the un-denoised image (the noise it adds after noise reduction falls from 115% to 65%), keeps its strength on texture, and shows in the fitted preview as in an export at small sizes. Thin bright lines and high-contrast fine detail are boosted less (a bright 2-pixel line gains 0.30 stops at +100 instead of 1.58); faint fine texture is boosted a little more.
2. **Negative Texture** smooths texture and keeps edges.
3. **Sharpening** measures the noise-reduced image, so strong noise reduction followed by sharpening no longer puts removed texture back; its restoration is within 0.1 dB of SHP-01's.
4. **Clarity** reads the noise-reduced image's c₃ and a base in the same luminance. Its band, limit and edge behaviour are process 9's; the change to expect is small and is measured in the build.

What stays identical: noise reduction (all of it), Richardson–Lucy, the unsharp mask, Detail, Masking and the halo limit, Clarity's filter and limit, masks' coverage, and every process before 10, which keeps today's code paths.

## Process versions

- **Process 10** (`EditRecipe.currentProcessVersion` = 10), noted as: "Texture, Clarity and Sharpening read one decomposition of the noise-reduced luminance: Texture puts no halos along strong edges and no noise back, and the fitted preview shows it as an export does." `LocalContrastSettings` and `SharpenSettings` gain `decomposition = processVersion >= 10`, as `edgeAware` does for process 9, and the stage chooses its path by them.
- **Gate:** `ProcessStabilityTests` records process 10's references with `TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1`, which writes only missing ones: `tests/golden/process/process-10/`, the five fixtures with the heavy and retouch edits (10 files). Processes 1 to 9 must pass unchanged.
- **Recipe goldens:** `tests/golden/recipes/process-10/`, every bundled recipe on the lint chart (95 renders, `redlamp recipe golden --record`).
- **Sidecar format:** `docs/recipes/sidecar-format.schema.json`'s `processVersion` maximum goes from 9 to 10, and `sidecar-format.md` gets process 10's row in its table, "1 to 10" in the field's description and "above 10" in the read-only rule (`SidecarSchemaTests` checks the maximum). Older builds open process-10 sidecars read-only, as designed.

## Risks

- **Texture's look.** The limit compresses high-contrast fine detail such as foliage against the sky; the gain of 1.2 restores the average. The owner should judge it on the look-development set; the build reads the limit and gain from environment overrides while tuning, as Clarity's does.
- **Noise-slider drags** become slower (about +4 ms at 1:1, +20 ms at fit level 0). Alternative B avoids it.
- **The preview weights** are fitted on four cameras; a photo with an unusual spectrum can fall outside the gate's range. The gate measures three sizes per level on the fixtures.
- **Memory:** the ladder cache holds 18 bytes per texel per entry (about 440 MB at fit level 0). Above 16 megapixels it can keep one entry, or keep only the noise-reduced image and rebuild the ladder (5.4 ms) on a drag.
- **Noise calibration** for the ladder's bands is new per sensor kind and level; it gets a test like `calibration matches the pipeline`.
- **Patents (DEC-05):** Clarity's base remains a guided filter, as in process 9. The ladder's B3 à-trous transform and the garrote are what noise reduction and sharpening's separator already use.
- **Processes 1 to 9** must not move: they keep today's code, and the gate catches any change.

## Alternatives

- **A (proposed):** one ladder of the noise-reduced image; sharpening's separator on it; Richardson–Lucy kept.
- **B, sharpening not unified:** sharpening keeps a separator independent of the user's noise reduction (today's second noise-reduction run, or a ladder of the pyramid cached per area). Noise-slider drags stay as fast as today; sharpening keeps putting back texture that strong noise reduction removes; Texture and Clarity are as in A.
- **C, sharpening as band gains:** rejected; 0.1–0.8 dB worse than Richardson–Lucy.
- **D, a Laplacian pyramid:** rejected; its decimated bands alias under per-pixel gains and shrinkage, and its grid must align across tiles.
- **E, local Laplacian filters** (Paris, Hasinoff and Kautz, 2011) for Texture and Clarity: edge-aware by construction, but about 8 to 16 pyramids per render in the fast form, and their freedom to operate is unknown. Later, if the limit's look is rejected.
- **F, edge-avoiding à-trous** (Dammertz et al., 2010; Hanika et al., 2011) for Texture: a second, range-weighted ladder (about twice the ladder's cost) that leaves strong edges in its coarse levels, so Texture needs no limit and strong texture isn't compressed. The candidate if the owner rejects the limit's look.
- **G, the smallest change:** process 10 adds the limit to Texture, reads its band from the noise-reduced image with today's pyramid sampling and weights level 3. It fixes halos, noise and the 700 px preview, but not the drag costs or sharpening's interaction with noise reduction.

## Build steps (W4-BUILD)

| Step | Size | Done when |
|---|---|---|
| 1. The ladder kernel (linear luminance, four scales, bands kept) | S | Bands sum back to Y; responses match the B3 spline's; a region equals the whole frame there |
| 2. Noise calibration for the ladder's bands | S | Measured per-scale noise within 15% of the table, per sensor kind and level |
| 3. Sharpening's separator on the ladder, behind process 10 | M | Flat noise grows under 2%; the deconvolution test passes; cached renders equal fresh ones |
| 4. The apply pass: Texture's band, limit and gain, Clarity on c₃, sharpening's boost, masks' amounts | M | Texture's edge test (both sides, per stop of boost), noise with Texture after noise reduction, masks only inside |
| 5. Clarity's map in the ladder's luminance, on first use | S | A saturated flat patch has no Clarity offset; process 9 unchanged |
| 6. Caching and the drag paths | M | Each drag reruns only what this design says; caches render what fresh renders do |
| 7. Preview weights by level and position | S–M | The gate passes for Texture ±60 and Clarity at 700, 1000 and 2000 px, within 0.9–1.1 for Texture |
| 8. Process 10 | S | References, recipe goldens, schema and table recorded; engine, recipes and document suites and the gate pass |
| 9. Benchmarks against this baseline | S | The cost table above, measured, with the load beside it |

About 2 to 3 engineer-weeks, in about nine commits.

## Decisions for the owner

1. **A or B:** sharpening measures the noise-reduced image (A, with slower noise-slider drags) or stays independent of it (B).
2. **Texture's limit and gain** (0.25 stops and 1.2), to judge by eye on the look-development set during the build.
3. **Noise-aware Texture:** shrinking Texture's bands by the separator's garrote stops it adding noise at all, but also stops it boosting faint texture near the noise floor (12 px stripes after noise reduction gain about 1.2× at 2 sigmas and 1.0× at 3, against 1.8–2.0× without it). The proposal leaves it out.
4. **Sharpening at fit:** keep today's behaviour, or extend the preview rule to it.
5. **The visible changes** listed above, for new edits.

## Method

- **GPU times:** the stage's command buffers (`gpuEndTime − gpuStartTime`), 24 submitted back to back with at most three in flight, the first 8 dropped; recipes that turn on one sub-stage at a time (noise reduction or sharpening off otherwise); the prototype ladder and apply kernels compiled at run time in the same harness.
- **Preview against export:** `PreviewExportTests`' measure at 700, 1000 and 2000 px, with 8- and 16-bit exports, and with Color noise reduction, sharpening and the lens profile off (the stage kept running by Texture 0.01, so both renders take the same path).
- **Synthetic scenes:** `DetailStageTests`' session builder (Bayer, Menon demosaic, exact Poisson–Gaussian noise or none).
- **Python model:** numpy and scipy on the engine's own level-0 texels and outputs (dumped from the harness), validated against the engine: today's Texture at 0.61, 0.99 and 1.08 against 0.63–0.65, 1.00–1.02 and 1.11–1.12; the step's −1.74 and +0.41 stops exactly. Sharpening on the restoration bake-off's test set with `shp01_calibrate.py`'s protocol and seeds (SHP-01 reproduces its recorded +1.74 and +1.17 dB).
