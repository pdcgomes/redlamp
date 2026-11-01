# Sharp generative fills on large areas: design (RM-20)

Generative Remove fills a spot from a square crop of the pyramid, read from the finest level where the spot fits in 1024 pixels with margin ([generative fill design](2026-10-05-generative-fill-design.md#what-the-model-is-shown)). A spot more than about 680 pixels across is filled on level 1 or coarser, and its fill is stored at that level's resolution and stretched over the spot: the D7500's parked car, with its shadow, is stored at 614 × 240 over 2456 × 960 pixels, a quarter of the photo's resolution, and looks soft at 100% beside the photo. This design measures two ways to bring such a fill to the photo's resolution, prototyped on 1 November 2026, and chooses one.

## The two ways, as prototyped

Both start from today's fill, which is unchanged, and work on the area at full size around the spot. The prototypes are on the branch `rm-20/fill-prototypes` (bb6a8610f, afdde6c87, 8b0dd5930): options that today's Generative Remove doesn't use, so with none of them set the branch fills the car exactly as `main` does (every pixel the same).

**A. A second FLUX.2 [klein] pass at reduced strength.** The fill is upsampled over the spot at full size and the area is cut into tiles of at most 1024 pixels, overlapping by 128, each corner a multiple of 16 (`GenerativeCrop.tiles`). Each tile's latents are noised to a level σ and run through the remaining steps, the photo outside the spot put back at each step as today, with the photo shown as it was (exposure and roll-off of the coarse crop), so the tiles join; the noise is drawn once for the whole area, so overlapping tiles start from the same noise (`GenerativeSchedule.noiseArea`). The tiles are decoded and blended over their overlap with linear ramps. This is SDEdit's way of editing an image by noising and denoising it part way (Meng et al., arXiv:2108.01073), run in tiles as MultiDiffusion runs a model over a larger canvas than it was trained for (Bar-Tal et al., arXiv:2302.08113), here blended once at the end rather than at each step.

- **How much noise.** On the car, σ 0.6 then 0.3 (two steps) adds grain and little else; σ 0.8 then 0.4 adds texture and keeps the coarse fill's shapes; σ 0.9, 0.6, 0.3 moves the shadow's edge and a window, and tiles start to disagree. FLUX.2 [klein]'s own four-step schedule at 4096 tokens is 1, 0.967, 0.908, 0.767, so 0.8 sits beside its last step. The measurements below use 0.8 and 0.4.
- **Which reference.** Shown itself as its reference (the photo with the upsampled fill), a tile comes back as soft as the fill: the model copies its reference closely, as RM-10 found. Without one it adds detail, and each step costs half as much (the car's six tiles took 93 seconds without a reference and 173 with one). The measurements use none.

**B. Detail transfer.** The fill keeps its shapes and takes its fine texture from the photo, at full size (`research/prototypes/generative/detail_transfer.py`, in Python with the search on the GPU through PyTorch's MPS backend). In the square root of linear camera RGB, where shot noise is about the same at every brightness, with L a Gaussian low-pass (0.6 coarse texels in the table below; wider ones after it), the result is L(fill upsampled) + (photo − L(photo)) taken from a chosen place for each block. The places are chosen in two passes:

1. Every second coarse texel of the spot is matched against every candidate around it in the coarse crop: 5 × 5 patches of the coarse fill against the photo's, in a 24-dimensional projection of the patches, and the 16 best are kept. This is an exhaustive search, as content-aware fill's is (RM-07), not PatchMatch's.
2. At full size, in raster order, each 8 × 8 block of the spot takes, from those 16 moved up to 2 pixels either way, the candidate whose low-pass best matches the fill's and whose detail best matches what is already there over the 17 × 17 pixels around the block: the photo's own outside the spot, and the blocks placed before it. Blocks are cut straight rather than blended, so the copied detail keeps its contrast and its noise (Hertzmann et al., "Image Analogies", SIGGRAPH 2001, copy a texture guided by another image in the same way; Efros and Freeman's image quilting, SIGGRAPH 2001, matches each block's overlap with what is placed).

The copied detail carries the photo's own noise, so B's fill is rendered without the noise `rl_fill_stored` adds (the prototype marks it in the fill's unknown fields). For the measurements B's fill was imported back into the CLI as the spot's fill (`--fill-import`) and rendered as any generative fill is, with Heal's rim blending.

## How they were measured

On INF-14's large cases (`research/benchmarks/removal.json`, group `large`): two real photos and three composites, each an object pasted onto a clean part of a CC0 photo, the photo being the truth (`make_removal_composites.py`). Every photo is CC0 from raw.pixls.us.

| Case | Spot | Today's fill |
| --- | --- | --- |
| `d7500-car` | Find's car with its shadow, 2456 × 960 | level 2, 614 × 240 |
| `r6m2-van` | A van picked with a click, with its shadow, 2240 × 1452 | level 2, 560 × 363 |
| `composite-paving` | An object on paving bricks, 1828 × 884 | level 2, 457 × 221 |
| `composite-grass` | An object on rough grass, 1500 × 936 | level 2, 375 × 234 |
| `composite-wall` | An object over a brick wall and a window, 980 × 696 | level 1, 490 × 348 |

`research/prototypes/generative/score_removal.py` scores the spot's area as the edit leaves it, at full size in linear camera RGB (`--dump-areas`), on luminance in its square root:

- **Sharpness:** each difference-of-Gaussian band's energy (about 2, 4 and 8 pixels across) inside the spot, less what the photo's noise model puts there, over the same in a ring of the photo around it. It depends on what the spot holds as well as on the fill (the car's spot lies mostly in shade, the ring mostly in sun), so it compares methods on a case, not cases.
- **Detail over the truth's** (composites): the same band energy over the truth's in the same place, which what the spot holds doesn't sway; 1 is as detailed as the photo there.
- **Noise:** the finest band's spread in the flattest half of the spot over the same in the ring; 1 is the photo's own grain.
- **Seam:** the gradient across the spot's edge over the gradient 10 to 16 pixels outside it; 1 is no visible edge.
- **PSNR** against the truth inside the spot, of the whole signal and of its low-pass (a Gaussian of 4 pixels).

Times are the fill's own on the M1 Ultra with the model loaded, under the load average given (two other agents shared the Mac and its GPU all day; none of these is a quiet measurement). Today's and A's coarse fills ran in the same batch, so their difference is A's tiles; B's second figure is the Python prototype, not what Metal would take.

| Case | Method | Sharpness 2 / 4 / 8 px | Noise | Seam | PSNR, low-pass (dB) | Detail over truth's, 2 / 4 px | Time (s) | Load |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| d7500-car | Content-aware | 0.93 / 0.72 / 0.43 | 0.57 | 1.02 | | | 19 | 54 |
| d7500-car | Today | 0.09 / 0.15 / 0.20 | 0.69 | 1.01 | | | 48 | 65 |
| d7500-car | A | 0.14 / 0.26 / 0.32 | 0.73 | 1.01 | | | 154 + 90 | 72 |
| d7500-car | B | 0.19 / 0.15 / 0.19 | 0.67 | 1.01 | | | 48 + 139 | 68 |
| r6m2-van | Content-aware | 0.78 / 0.66 / 0.58 | 1.06 | 1.03 | | | 9 | 56 |
| r6m2-van | Today | 0.15 / 0.36 / 0.49 | 0.58 | 1.03 | | | 130 | 63 |
| r6m2-van | A | 0.32 / 0.68 / 0.74 | 0.68 | 1.03 | | | 156 + 87 | 68 |
| r6m2-van | B | 0.22 / 0.32 / 0.46 | 0.73 | 1.03 | | | 130 + 251 | 66 |
| composite-paving | Content-aware | 0.90 / 0.92 / 0.95 | 0.94 | 0.97 | 16.6, 20.0 | 0.77 / 0.83 | 8 | 64 |
| composite-paving | Today | 0.18 / 0.44 / 0.68 | 0.22 | 0.95 | 17.7, 20.6 | 0.16 / 0.40 | 60 | 69 |
| composite-paving | A | 0.25 / 0.57 / 0.72 | 0.32 | 0.95 | 17.7, 20.8 | 0.22 / 0.51 | 168 + 38 | 70 |
| composite-paving | B | 0.38 / 0.43 / 0.64 | 0.79 | 0.95 | 17.5, 20.6 | 0.33 / 0.39 | 60 + 131 | 73 |
| composite-grass | Content-aware | 0.62 / 0.59 / 0.55 | 0.90 | 0.92 | 17.8, 19.7 | 0.66 / 0.66 | 8 | 65 |
| composite-grass | Today | 0.12 / 0.24 / 0.30 | 0.27 | 0.90 | 18.9, 20.7 | 0.12 / 0.27 | 18 | 59 |
| composite-grass | A | 0.20 / 0.39 / 0.42 | 0.34 | 0.90 | 18.6, 20.6 | 0.21 / 0.44 | 119 + 29 | 65 |
| composite-grass | B | 0.22 / 0.21 / 0.29 | 0.81 | 0.90 | 18.8, 20.7 | 0.23 / 0.24 | 18 + 76 | 51 |
| composite-wall | Content-aware | 0.85 / 1.07 / 1.51 | 0.95 | 0.95 | 11.2, 11.7 | 1.22 / 1.27 | 6 | 64 |
| composite-wall | Today | 0.56 / 0.89 / 1.26 | 0.70 | 0.91 | 12.2, 12.6 | 0.81 / 1.06 | 59 | 61 |
| composite-wall | A | 0.72 / 1.10 / 1.66 | 0.79 | 0.95 | 11.7, 12.2 | 1.03 / 1.31 | 96 + 20 | 86 |
| composite-wall | B | 0.61 / 0.88 / 1.25 | 0.88 | 0.90 | 12.2, 12.6 | 0.88 / 1.05 | 59 + 55 | 47 |

The rows are in `research/benchmarks/results/removal-2026-11-01.json`.

What they show:

- **Today's fill holds an eighth to a half of the photo's fine detail** where its level is 2 (0.09 to 0.18 at 2 pixels, 0.12 to 0.16 of the truth's), and its grain is a fifth to two thirds of the photo's: the noise model's noise is added, but on the composites, linear DNGs whose noise Redlamp measures from the image, the model is lower than the photo's real grain.
- **A adds detail in every band**, about one and a half to two times today's (the van's 4-pixel band from 0.36 to 0.68; the paving's from 0.40 to 0.51 of the truth's), and a little grain. What it adds is the model's: the PSNR against the truth doesn't rise, and falls by up to 0.5 dB on the wall and the grass, where the model's texture differs from the photo's.
- **B adds the photo's own fine texture and grain**: the 2-pixel band about doubles (the paving's 0.16 to 0.33 of the truth's), and the grain comes within 0.67 to 0.88 of the photo's, against 0.22 to 0.70 for today's. At a low-pass of 0.6 coarse texels it leaves the 4- and 8-pixel bands where the coarse fill had them, since they lie below the low-pass, and moves the PSNR by no more than 0.2 dB. A wider low-pass takes more of the photo's texture: on the paving, at 1.2 and 2 texels, the detail rose to 0.43 and 0.45 of the truth's at 2 pixels and to 0.44 and 0.48 at 4 (A: 0.22 and 0.51), with the low-pass PSNR unchanged at 20.7 dB; on the car, at 1.2, the 2-pixel band rose from 0.19 to 0.24.
- **Neither brings back structure the coarse fill lost**: brick joints that the coarse fill smeared stay smeared under A and B alike (low-pass PSNR within 0.2 dB of today's), and content-aware fill's wrong content in the reference stays wrong (the sky in the wall, RM-21). Seams don't change.
- **Content-aware fill is the sharpest on every case and the least right**: it copies the photo's own texture at full size, from the wrong places (sky into the car's drive and into the wall).

By eye, at 100%: on the car, A's paving shows some of its texture back and B's shows the photo's own grain and joint edges where today's is smooth; on the van and the paving, A's is the crisper; on the grass all three are close.

**Blind picks.** The round `removal-sharp-2026-11-01` puts today's fill, A and B (with the table's 0.6-texel low-pass) against each other in pairs on a 1:1 crop of each of the five cases, 15 pairs, in the canvas `picks-removal-sharp-2026-11-01.canvas.tsx` (the key is in `build/benchmarks/picks/removal-sharp-2026-11-01/key.json`; `research/benchmarks/picks.py analyse removal-sharp-2026-11-01` tallies it into `research/benchmarks/results/picks-removal-sharp-2026-11-01.json`). The owner hasn't marked it yet; the choice below stands unless the picks go clearly the other way.

## Cost

- **A** runs the model once more for each tile: the car's area, 2592 × 1088, is six tiles of 1024, the van's six, the paving's three. Without a reference and at two steps, a 1024-pixel tile took 15 seconds under a load average of 70 (90 seconds for the car's six; 93 seconds with the Mac less loaded, at 52). That more than doubles a large spot's fill (the car's coarse fill took 50 seconds in the same run), and the Healing tool makes three fills for each new spot, so a large spot's three variations would take about seven minutes instead of two and a half. Its peak memory is the larger of the coarse fill's and a 1024-pixel tile's without a reference, which is below the 6.6 GB a 1024-pixel fill with a reference takes (RM-10, step 6); the CLI's resident memory peaked at 3.8 GB for the car with A against 4.2 to 4.8 GB for today's fill (its resident set doesn't count all of MLX's buffers, so these compare runs rather than state the peak). Tiles of 768 would keep it below the 5.2 GB a 768-pixel fill with a reference takes.
- **B** runs no model. Its search is two passes on the GPU: the coarse match is a product of the spot's targets by its candidates by 24 dimensions (27,000 × 830,000 × 24, about 5 × 10^11 multiply-adds for the car), a fraction of a second on the M1 Ultra's GPU; the block pass scores 400 candidates over 17 × 17 × 3 values for each of 24,600 blocks (about 50 GFLOP), in about 600 wavefronts of blocks that don't depend on each other (a block waits for the one to its left and the three above it, so a wavefront is the blocks at x + 2y). Estimated at one to two seconds in Metal for the car, beside the fill's 50. The Python prototype took 139 seconds for the car under a load of 68, nearly all of it Python's loop over the blocks (its GPU search took 21 seconds with the data's preparation). Its memory is the full-size photo over the coarse crop's extent (the car's 4096 × 3712 pixels, about 0.5 GB as half floats for the photo, its low-pass, its detail and the guide), used after the model's working memory is freed: the weights stay loaded, as they do between fills today, and the search sits below the fill's peak rather than on top of it.

## The choice: B, then A where it is still soft

Build B first. It costs about two seconds against A's minute and a half, it fits any Mac the model fits, it needs no model at render time, and what it adds is the photo's own texture and grain, which is what the eye compares a fill with at 100%. It can't add what the coarse fill doesn't have, so A stays a candidate for a second step: on the van and the paving its mid-scale detail is what B doesn't give, and the blind picks will say whether that's worth its time. If they favour A clearly, A goes in as an option the Healing tool offers for a large spot after its fill ("Sharpen", a fourth step per spot), never on every variation.

RM-12's coarse-to-fine refinement for content-aware fill is the same machinery: content-aware fill's working-level result as the guide, its detail taken at full size with B's search. Building B once serves both.

## How it fits

**The stored fill.** B doesn't need its pixels stored. A generative fill stays as it is today, the coarse bitmap over the spot's box, and gains its detail map: one move per 8 × 8 block in full-size pixels (the car's 320 × 132 blocks are 42,000 moves, about 170 KB, or less as a 16-bit PNG beside the fill). Rendering computes L(upsampled fill) + (photo − L(photo)) at each block's move, which is as cheap as content-aware fill's `rl_fill_render`, and renders the same on any Mac from the photo alone, with or without the model. Stored as pixels instead, the car's fill at full size would be a 16-bit PNG of about 14 MB, against 0.8 MB today, for every variation kept in History; A's would be about 13 MB, since A has to be stored as pixels.

- **The sidecar:** a new optional field on `GeneratedFill`, the detail map (`detail`: its bitmap, block size and low-pass), and the grain it implies (no added noise where the detail is copied). A build that doesn't know it keeps it and renders today's soft fill with noise, as now; no existing edit changes, so no process version is needed. `docs/recipes/sidecar-format.schema.json` and `sidecar-format.md` gain the field.
- **The renderer:** `rl_fill_stored` gains the detail term, and skips the noise where the detail is copied.
- **Moves kept valid:** a source must lie outside every Remove spot of the edit and outside the spots after it, as RM-11 has content-aware fill's; a spot moved or resized already drops its fill.

**The Healing tool.** A large spot's fill gets its detail map straight after the model has made it, inside the same progress bar: the model's steps, then the search for the last few percent. Cancel stops either, keeping nothing, as today. On a 16 GB Mac the search runs once the model's working memory is freed, so B doesn't raise the peak. A, if it comes, is a step the photographer asks for on one spot, with its own progress (one bar over its tiles, cancellable between tiles), and it doesn't raise the peak either: one tile at a time, at most 1024 pixels, without a reference.

## What it takes to build

1. **The search on the GPU** (`RedlampKernels`, `ContentAwareFill`): a kernel that scores every candidate's projected patch against every target's (a tiled distance product with a running top 16), and one that scores each wavefront's blocks against their candidates; the projection fitted on the candidates on the CPU. Unit tests against a CPU version of both on small synthetic images, and against the Python prototype's moves on one dump.
2. **The detail map** in `GenerativeCrop` and `RedlampEngine+GenerativeFill`: made after the fill, from the full-size photo over the crop's extent; encoded with the fill.
3. **Rendering** (`rl_fill_stored`, `RetouchStage`): the detail term and its grain, with golden renders of a stored fill with and without a detail map, and the sidecar schema's new field (`SidecarSchemaTests`).
4. **The Healing tool's progress**, and a regression scenario that removes a large object generatively through the tool and checks its detail map.
5. **The patents check** before it ships: B matches patches exhaustively, as content-aware fill does, rather than propagating and perturbing nearby matches as Adobe's PatchMatch patents claim, but its guided copy and block overlap belong in DEC-05's freedom-to-operate review with RM-12's wider search, which the [removal research](../research/notes/D-removal.md#4-patent-notes) names.

About one engineer-week for steps 1 to 4, with RM-12 reusing step 1. A, if the picks call for it, is the prototype's tiling made cancellable and its fill stored as pixels: two to three days, most of them on the Healing tool's step and its scenario.

## What's left open

- The blind picks, which only the owner can mark.
- B's low-pass: 0.6 coarse texels was measured on every case, 1.2 on the car and the paving, and 2 on the paving, where it took the most of the photo's texture without moving the fill's shapes. The build should start at 1.5 and settle it on all the composites, where the truth says how much detail belongs there.
- Lightroom's Generative Remove on the same cases (INF-14's bench task `removal-generative-remove-2026-11-01`), for how sharp its fills are at full size.
- Quiet timings: every time here was taken under a load average between 47 and 86.
