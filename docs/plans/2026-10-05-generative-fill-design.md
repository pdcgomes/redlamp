# Generative fill: design (RM-10)

Generative Remove fills a Remove spot that content-aware fill can't: something a third of the frame across, such as a parked car, whose surroundings have no patch that fits. It is an opt-in download that runs on the Mac (DEC-23), labelled as generated fill, and takes no words: the owner chose removal only on 5 October 2026.

## The model

FLUX.2 [klein] 4B (Black Forest Labs, Apache-2.0 weights, training data undisclosed) runs through MLX in `RedlampGenerative`, a Mac-only module nothing but the app and the CLI link.

- **The port** (`Flux2Transformer`, `Flux2VAE`, `FluxInpainter`) follows diffusers' `Flux2KleinInpaintPipeline` at strength 1: four flow-match Euler steps, the latents outside the mask put back at each step's noise level, and a reference image's latents beside the noisy ones at time 10. Against diffusers in float32 from the same noise, the VAE, the first step's velocity and the token positions match, and a whole fill is above 40 dB (`FluxInpaintTests`).
- **Precision.** The transformer's blocks are quantised to 4 bits (2.22 GB): 41 to 46 dB from float32 inside the mask, indistinguishable by eye, against 65 to 73 dB for bfloat16 (7.75 GB). A fill takes the same time at every precision, so the smallest download wins.
- **No text encoder ships.** The download carries three prompts' embeddings, encoded by diffusers' own `encode_prompt` (`convert_flux.py`): `empty`, `background` and `remove`. Step 1's Qwen3 encoder stays for tests and a prompt add-on later.
- **Delivery** is a manifest like the other models' (`flux2-klein-4b-fill.json`, 2.41 GB in 8 files, each under GitHub's 2 GB), published as a prerelease by `scripts/publish-model.py` once the owner approves the upload (DEC-26). The store resumes an interrupted file and reports progress within it, and the manifest's `testedMemory` (16 GB) is the least memory it has been tested on: Macs with less are offered it with a note that it hasn't been tested on them (RM-15).

## What the model is shown

`RedlampEngine.generativeCrop` reads a square of the pyramid around the spot, from the finest level where it fits in 1024 pixels with at least half the spot's size around it (two and a half times its size when that fits, at least 512 pixels), with the spots before it in. The model expects an sRGB picture, so the crop's linear camera RGB goes to linear sRGB, is scaled so its mean sits at a quarter, rolled off with `x / (1 + x)` and sRGB-encoded; the fill comes back through the same steps reversed (`GenerativeCrop`). The mask is the spot grown by 8 pixels, so the latents' 16-pixel cells along its edge are repainted too.

**The reference decides what comes back** (measured on the D7500's parked car and the duck sample, 5 October 2026):

| Reference | Prompt | Result |
| --- | --- | --- |
| The photo, the car in it | `remove` or `empty` | The car comes back: the model copies its reference closely |
| None | `empty` or `background` | It invents things: another car under a cover, a lawn |
| The spot filled from the photo | `empty` | It copies content-aware fill's patches |
| **The spot filled from the photo** | **`remove`** | **A clean driveway, wall and door, on three seeds** |
| The same, blurred inside the spot | `remove` | Also clean on the car; on water a dark smudge where a duck was |

Generative Remove therefore shows the model the photo with the spot filled from around it, prompted to remove (`generativeDefaults`); the CLI's `--fill-reference` and `--fill-prompt` keep the others for judging new photos. On water neither fill is clean yet: content-aware fill's vertical streaks partly survive.

## How a fill is kept and rendered

A fill is a field on a Remove spot (`RetouchSpot.fill`, a `GeneratedFill`), not a mode: a build that doesn't know the field keeps it and fills the spot from the photo, where an unknown mode would read as Heal.

- **Stored as pixels**, so it renders the same on any Mac, with the model or without: the photo's camera RGB (white balanced as shot, linear) over the spot and 16 pixels around it, at the crop's resolution, divided by its peak and square-rooted into a 16-bit RGB PNG. It goes in the package's `masks/` folder with the edit's other bitmaps, so saving, history and removing unused files need nothing new; the plan's separate `fills/` folder wasn't needed.
- **Where it goes** is a box in the photo's full-size pixels before orientation, with the photo's size: a fill made for a photo decoded at another size is left out, and the spot filled from the photo.
- **Rendered** by `RetouchStage` where content-aware fill renders: `rl_fill_stored` samples the bitmap over its box, adds noise from the photo's own noise model (seeded by the fill, so every render is the same), and keeps the photo outside the box; then Heal's rim blending matches its edge to the photo. Frames, stills and exports go the same way, and no edit renders differently from before, so no process version is needed.

## In the Healing tool

Remove's Fill is Content-Aware or Generative, and Generative is shown only where the model is offered: downloaded, or published. The first use offers the download, with its size, its licence and that its fills are labelled as generated, and, on a Mac with less memory than the model has been tested on, that it may be slow or not work there. With Generative chosen, a new Remove spot, whether clicked, brushed, picked or found, gets three fills from three seeds, the first in the edit as soon as it is made; Find's Remove All gets one per spot, one after another. Arrows go through a spot's fills, More makes three more, and Content-Aware fills it from the photo again; each is a step in History. A spot moved or resized loses its fill, which no longer fits, and is filled again. Closing the tool unloads the model.

## What a fill costs

Measured on the M1 Ultra with `FluxFillCostMeasurements` (`REDLAMP_FLUX_MEASURE`), with Metal's validation layer off; the GPU's work is the same in Debug and Release. The model loads in about 3 seconds from the SSD; then, with the reference the fill uses:

| Crop | Fill | Peak memory |
|---|---|---|
| 512 × 512 | 11 s | 4.2 GB |
| 768 × 768 | 24 s | 5.2 GB |
| 1024 × 1024 | 46 s | 6.6 GB |

The reference doubles the transformer's tokens, and so its time; without one a 1024-pixel fill takes 24 seconds. Removing the D7500's car with a Release build of the CLI, model load included, takes 40 seconds.

At first a 1024-pixel fill peaked at 13.1 GB, nearly all of it the VAE's: MLX unfolds a convolution's input into a copy for each tap of its kernel, 9 GB for a 3 × 3 convolution over 1024 × 1024 pixels of 256 channels. The VAE now convolves large inputs in bands of rows, each with the rows its kernel reaches beyond it, and normalises and applies SiLU in one kernel, which gives the same latents and fills as diffusers. MLX's cache of freed memory is capped at 1 GB while filling, which costs about 7% of the time; uncapped, it doubled what the app held.

The model has been tested on Macs with 16 GB of memory: at 6.6 GB for the fill and the app's own couple of gigabytes, an 8 GB Mac would swap. Smaller Macs are offered it too (RM-15), with a note in the download offer, in Settings › Models and in a failed fill's message that it hasn't been tested on Macs with less memory and may be slow or not work; what a fill costs on one hasn't been measured.

## Limits

- Large holes are filled at a coarser pyramid level: the car's fill is 508 × 234 pixels over 2032 × 936, so it is softer than the photo, with the photo's noise added.
- What lies outside the spot stays: the car's shadow beside it (RM-13).
