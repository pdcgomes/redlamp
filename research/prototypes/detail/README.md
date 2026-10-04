# Detail decomposition (TON-06)

Measurements behind `docs/plans/2026-10-03-detail-decomposition-design.md` and process 11's
Texture, Clarity and sharpening. Nothing here ships; the product version is `DetailStage+Ladder.swift`
and `DetailLadder.metal`.

## Harness

`harness/W4BaselineTests.swift` is a Swift Testing suite run inside the engine's test target. Copy it
into `packages/RedlampEngine/Tests`, run `mise exec -- tuist generate --no-open`, and pick its parts
with `TEST_RUNNER_W4_PART` (comma separated):

| Part | Measures |
| --- | --- |
| `timing` | GPU time per detail sub-stage and drag, with the load average |
| `preview` | ARC-04: the fitted preview against a downscaled export, written as `.f32` files |
| `halo`, `sweep`, `sweepsharpen`, `noise` | Halos at edges, per-scale bands, and noise after noise reduction |
| `ladder` | The ladder kernel's cost by format |
| `dump`, `noisedump` | Full-resolution luminance and flat noise fields for the Python scripts |
| `crops` | Full-resolution 400 px crops of three raws at process 9 and 11 for Texture 50, 100 and -50 |

Everything is written to `/tmp/w4-detail`. `TEST_RUNNER_REDLAMP_TEXTURE_LIMIT` and
`TEST_RUNNER_REDLAMP_TEXTURE_GAIN` override Texture's limit and gain, and `TEST_RUNNER_W4_TAG` names a
run's crops. Remove the file from the test target afterwards.

## Scripts

`proto/` reads the harness's dumps with the masking prototype's virtual environment (numpy, scipy,
Pillow): `detail.py` is the ladder prototype, `arc04*.py` fit the preview weights, `halo_*.py`,
`noise_texture.py` and `sharpen_*.py` back the design's figures, `strength.py` measures Texture's change
in texture and at edges from the crops, and `sheet.py` and `pick.py` build the comparison sheets.

## Texture's limit and gain

Chosen from the crops in `crops/` (base, process 9, process 11; Texture 100 unless named):

- The limit stays at 0.25 stops. At 0.4 or 0.6, edges get back most of what the limit takes off them
  for the same texture.
- The gain goes from 1.2 to 1.6, so texture in midtones changes about as much as at process 9 on the
  Nikon fur (1.07x and 1.14x process 9's change at Texture 100), while high-contrast edges change 0.81x to
  0.90x as much and lose process 9's dark outlines. On the Sony branches process 11 changes half as much
  as process 9, most of whose change there is boosted sky noise.
- Negative Texture is not limited: it smooths and makes no halos, and without the limit the preview
  follows the export (ARC-04 correlation 0.86 rather than 0.846 at 1000 px).

## GPU times, process 9 against 11

The decomposition was process 10 when these were measured; the detail stage is the same at 11.
The harness's `timing` part with `TEST_RUNNER_W4_PROCESS=9` and `=11`, on `DSC_0750.NEF` (6064×4040) on an
M1 Ultra: median GPU time of the stage's command buffer over 16 renders. Other sessions were building;
the one-minute load average was 27–31 throughout. Drags change the slider each render with the caches on.

| ms, process 9 → 11 | 1:1 (2689×1728 texels) | Fit level 0 (6064×4040) | Fit level 1 (3032×2020) |
| --- | --- | --- | --- |
| Default edit, uncached | 8.7 → 6.8 | 62.9 → 40.8 | 11.8 → 8.9 |
| Heavy edit (NR L50, Texture, Clarity, mask), uncached | 16.0 → 10.1 | 71.4 → 62.8 | 13.6 → 11.3 |
| Texture drag | 3.1 → 0.27 | 20.8 → 27.2 | 3.8 → 0.27 |
| Texture drag with Luminance 50 | 6.3 → 0.28 | 36.6 → 42.9 | 8.1 → 0.28 |
| Clarity drag | 3.6 → 0.23 | 20.6 → 27.1 | 5.5 → 0.33 |
| Amount drag | 2.7 → 0.20 | 19.4 → 27.1 | 5.1 → 0.28 |
| Masking drag | 2.6 → 0.24 | 24.8 → 27.3 | 4.1 → 0.31 |
| Radius drag | 6.2 → 2.8 | 36.4 → 48.3 | 6.8 → 3.4 |
| Luminance drag | 5.8 → 9.7 | 41.1 → 58.3 | 5.3 → 10.8 |

At fit level 0 the work area is 24 megapixels, above `DetailStage.ladderCacheTexels` (16M), so the stage
keeps only the noise-reduced source (8 bytes a texel, taken out of the scratch budget, so the stage stays
within `EngineMemoryTests`' 1200 MB) and takes the ladder on each drag. Measured after that change (load
32–41, process 9 measured again beside it):

| Fit level 0, ms | Process 9 | Process 11 |
| --- | --- | --- |
| Texture drag | 21.0 | 11.6 |
| Texture drag with Luminance 50 | 36.7 | 12.1 |
| Clarity drag | 20.5 | 12.8 |
| Amount drag | 19.4 | 11.9 |
| Masking drag | 19.6 | 11.3 |
| Radius drag | 36.2 | 26.1 |
| Luminance drag | 35.3 | 62.1 |

Each drag runs in 3 tiles: the ladder of the whole frame, the final pass, and copies of the cached
sharpening analysis into each tile and of each tile into the output.
