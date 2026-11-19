# EDT-28: output sharpening, measured against Lightroom

November 2026. How Lightroom's Screen sharpening was measured, and how Redlamp's operator (`OutputSharpen.metal`, described in [the export design](../../plans/2026-10-01-export-design.md#output-sharpening-edt-28)) compares with it.

## Method

A synthetic chart (2048 × 1365, 16-bit sRGB) holds steps at several levels and sizes, 1 px lines, sine gratings at seven periods and three amplitudes, a ramp with a 4 px grating on it, noise patches and colour edges, some of equal luminance in linear light. The owner exported it from Lightroom (the cloud app, version 10.0) at full size with every Output Sharpening setting and without, and the large version (6000 × 4000) reduced to 2048 and 1024 px. Each setting is compared with the same series' export without sharpening, so the difference is the sharpening alone. The chart, its patch list, the analysis script and the exports stay outside the repository, with the owner.

Redlamp's operator was measured the same way: `OutputSharpeningTests`' study test (`TEST_RUNNER_REDLAMP_OUTPUT_SHARPENING_STUDY=<folder>`) runs the chart through the export's last step at each level and writes the results beside Lightroom's, and the same script measures both. Redlamp's export without sharpening differs from Lightroom's by at most 0.00075.

## Lightroom's Screen sharpening

- An unsharp mask on encoded values, with a Gaussian of sigma about 0.6 px. Isotropic, with no threshold.
- Fixed in output pixels: the same gains after its own reduction to 2048 and to 1024 px as at full size.
- A tone mask: full strength near encoded 0.55, falling to none at black and white. Measured share of full strength at 0.05, 0.15 … 0.95: 0, 0.10, 0.40, 0.60, 0.80, 1, 0.88, 0.64, 0.27, 0.02.
- It changes chroma at colour edges, including edges of equal luminance; which space it works in was not resolved.
- Matte and Glossy add a wide Gaussian (sigma about 2.45 and 2.15 px) to a narrow part about 0.4 of Screen's, with a soft threshold. They are not implemented.

## Comparison

Gain on a sine grating about 0.5 (contrast with sharpening over without), by period in output pixels:

| Level | Amplitude | | 16 | 8 | 6 | 4 | 3 | 2.5 | 2.2 |
|---|---|---|---|---|---|---|---|---|---|
| Low | 0.02 | Lightroom | 1.013 | 1.048 | 1.083 | 1.163 | 1.244 | 1.292 | 1.315 |
| | | Redlamp | 1.012 | 1.048 | 1.082 | 1.164 | 1.246 | 1.298 | 1.321 |
| | 0.10 | Lightroom | 1.012 | 1.047 | 1.080 | 1.164 | 1.243 | 1.292 | 1.316 |
| | | Redlamp | 1.012 | 1.046 | 1.079 | 1.161 | 1.239 | 1.290 | 1.315 |
| Standard | 0.02 | Lightroom | 1.021 | 1.081 | 1.138 | 1.273 | 1.407 | 1.488 | 1.525 |
| | | Redlamp | 1.021 | 1.080 | 1.137 | 1.274 | 1.411 | 1.496 | 1.535 |
| | 0.10 | Lightroom | 1.020 | 1.078 | 1.133 | 1.274 | 1.405 | 1.487 | 1.526 |
| | | Redlamp | 1.020 | 1.077 | 1.131 | 1.268 | 1.398 | 1.484 | 1.524 |
| | 0.35 | Lightroom | 1.009 | 1.036 | 1.061 | 1.180 | 1.243 | 1.321 | 1.366 |
| | | Redlamp | 1.008 | 1.032 | 1.059 | 1.170 | 1.216 | 1.298 | 1.349 |
| High | 0.02 | Lightroom | 1.034 | 1.129 | 1.221 | 1.436 | 1.650 | 1.780 | 1.839 |
| | | Redlamp | 1.033 | 1.128 | 1.219 | 1.439 | 1.658 | 1.794 | 1.856 |
| | 0.10 | Lightroom | 1.033 | 1.125 | 1.212 | 1.438 | 1.649 | 1.779 | 1.841 |
| | | Redlamp | 1.032 | 1.122 | 1.209 | 1.429 | 1.637 | 1.774 | 1.839 |
| | 0.35 | Lightroom | 1.014 | 1.057 | 1.097 | 1.290 | 1.393 | 1.518 | 1.591 |
| | | Redlamp | 1.013 | 1.051 | 1.094 | 1.272 | 1.345 | 1.477 | 1.559 |

At amplitudes of 0.35 Redlamp's gain is up to 0.05 lower. Its tone mask is read at each pixel's own level, and a large grating spends more of its time away from 0.55; Lightroom probably reads its mask from something smoother, which was not measured.

What is added across a 1 px line (0.6 on 0.5), per unit of the line's height, beside it, on it and beside it:

| Level | Lightroom | Redlamp |
|---|---|---|
| Low | −0.082, 0.169, −0.082 | −0.082, 0.169, −0.082 |
| Standard | −0.136, 0.282, −0.136 | −0.137, 0.282, −0.137 |
| High | −0.216, 0.450, −0.216 | −0.220, 0.452, −0.220 |

Gain on the 4 px grating along the ramp at Standard, by level:

| Level | 0.05 | 0.15 | 0.25 | 0.35 | 0.45 | 0.55 | 0.65 | 0.75 | 0.85 | 0.95 |
|---|---|---|---|---|---|---|---|---|---|---|
| Lightroom | 1.00 | 1.03 | 1.12 | 1.18 | 1.24 | 1.30 | 1.27 | 1.20 | 1.09 | 1.01 |
| Redlamp | 1.00 | 1.04 | 1.11 | 1.18 | 1.25 | 1.29 | 1.27 | 1.18 | 1.08 | 1.01 |

Halo at Standard, as a share of the step, dark side and light side: 0.30/0.70 Lightroom 8.8% and 10.2%, Redlamp 7.1% and 11.6%; 0.45/0.55 12.4% and 14.7%, Redlamp 12.4% and 14.6%; 0.05/0.95 none and 0.3%, Redlamp 0.2% and 0.5%; 0/1 none in either.

At edges between colours of equal luminance Lightroom changes luminance by up to 0.009 and chroma by up to 0.04; Redlamp changes neither. At other colour edges both change luminance by similar amounts, and Redlamp keeps each pixel's channel proportions.

## Reduced exports

The large chart (6000 × 4000) reduced to a 2048 long edge, as 16-bit TIFF in sRGB, by Lightroom (its series 2) and by `redlamp export --long-edge 2048 --sharpen <level>`, with Redlamp's capture sharpening and colour noise reduction at 0, as the chart's were in Lightroom.

The sharpening alone (each level against its own export without it) matches as it does at full size: within 0.021 of gain at every period at amplitude 0.10, and within 0.016 at 0.02.

The files differ more, because the two resamplers differ. Grating contrast after reduction without sharpening, over the chart drawn at 2048 px (whose pixels average the pattern over their area), amplitude 0.10:

| Period (px) | 16 | 8 | 6 | 4 | 3 | 2.5 | 2.2 |
|---|---|---|---|---|---|---|---|
| Lightroom | 1.005 | 1.018 | 1.026 | 1.027 | 0.989 | 0.908 | 0.825 |
| Redlamp | 1.006 | 1.027 | 1.049 | 1.104 | 1.176 | 1.043 | 0.912 |

Redlamp's column is a textbook Lanczos-3, widened to the reduction: computed independently, it reproduces Redlamp's export to a mean of 0.0004. It keeps more of the finest detail than averaging over each output pixel does; Lightroom's resampler keeps about what averaging keeps. So with sharpening, the file holds more contrast at fine periods than Lightroom's at the same level:

| Period (px) | | 8 | 6 | 4 | 3 | 2.5 | 2.2 |
|---|---|---|---|---|---|---|---|
| Low | Lightroom | 1.065 | 1.107 | 1.195 | 1.215 | 1.173 | 1.085 |
| | Redlamp | 1.074 | 1.130 | 1.280 | 1.436 | 1.345 | 1.200 |
| Standard | Lightroom | 1.097 | 1.161 | 1.307 | 1.366 | 1.350 | 1.258 |
| | Redlamp | 1.105 | 1.185 | 1.398 | 1.610 | 1.546 | 1.393 |
| High | Lightroom | 1.145 | 1.243 | 1.476 | 1.593 | 1.616 | 1.518 |
| | Redlamp | 1.152 | 1.267 | 1.574 | 1.870 | 1.847 | 1.681 |

At a 4 px period Redlamp's Low is close to Lightroom's Standard (1.280 against 1.307); at 3 px and finer, Redlamp's Low is above it.

Amounts fitted to the files instead were worked out and not adopted. The amount for each level that brings the reduced file's grating contrast nearest Lightroom's file's at the same level, over periods of 16 to 3 px and amplitudes of 0.02 and 0.10, is about 0.20, 0.52 and 1.00 for Low, Standard and High, with the same sigma, leaving an rms difference of 0.03 to 0.04 in gain; a wider Gaussian (sigma 1.2 px, 5 × 5) fits a little better. The owner compared exports at Lightroom's amounts on 19 November 2026 and kept them: a reduced file from Redlamp at a level is crisper than Lightroom's at the same name, and Lightroom's unsharpened reduction shows moiré on the chart's zone plate where Redlamp's doesn't.

## Choices

- Luminance is taken in linear light and encoded, rather than as a weighted sum of encoded channels: on greys the two are the same, and edges of equal luminance stay as they are.
- Only reduced exports are sharpened. Redlamp's Lanczos-3 keeps 100% of modulation down to a 3.3 px period and 54% at Nyquist (6000 → 2048 px), so this is an added crispness, as Lightroom's is, rather than a correction for the reduction.
- The levels keep Lightroom's names and its operator's amounts, which the owner preferred to amounts fitted to Lightroom's files: on a reduced export, Standard raises a 4 px grating's contrast by 27% over Redlamp's own unsharpened reduction, which is already crisper than Lightroom's.
