# Detail decomposition (TON-06)

Measurements behind `docs/plans/2026-10-03-detail-decomposition-design.md` and process 10's
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
| `crops` | Full-resolution 400 px crops of three raws at process 9 and 10 for Texture 50, 100 and -50 |

Everything is written to `/tmp/w4-detail`. `TEST_RUNNER_REDLAMP_TEXTURE_LIMIT` and
`TEST_RUNNER_REDLAMP_TEXTURE_GAIN` override Texture's limit and gain, and `TEST_RUNNER_W4_TAG` names a
run's crops. Remove the file from the test target afterwards.

## Scripts

`proto/` reads the harness's dumps with the masking prototype's virtual environment (numpy, scipy,
Pillow): `detail.py` is the ladder prototype, `arc04*.py` fit the preview weights, `halo_*.py`,
`noise_texture.py` and `sharpen_*.py` back the design's figures, `strength.py` measures Texture's change
in texture and at edges from the crops, and `sheet.py` and `pick.py` build the comparison sheets.

## Texture's limit and gain

Chosen from the crops in `crops/` (base, process 9, process 10; Texture 100 unless named):

- The limit stays at 0.25 stops. At 0.4 or 0.6, edges get back most of what the limit takes off them
  for the same texture.
- The gain goes from 1.2 to 1.6, so texture in midtones changes about as much as at process 9 on the
  Nikon fur (1.07x and 1.14x process 9's change at Texture 100), while high-contrast edges change 0.81x to
  0.90x as much and lose process 9's dark outlines. On the Sony branches process 10 changes half as much
  as process 9, most of whose change there is boosted sky noise.
- Negative Texture is not limited: it smooths and makes no halos, and without the limit the preview
  follows the export (ARC-04 correlation 0.86 rather than 0.846 at 1000 px).
