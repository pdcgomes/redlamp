# The mask bench, then better Subject and Sky regions (MSK-38, MSK-39, MSK-40)

5 November 2026. The owner's request and decisions, from the chat that planned it.

## Why

People who have tried Redlamp's AI masks say that, even with the optional models downloaded, they are far behind Lightroom's. Sky, Subject and Background are the masks photographers use most, and they need to work as well as Lightroom's. The owner asked for the options to improve them, and for a bench where he can check masking results across a large pool of CC0 photos, find the problem areas and refine them one by one.

## Where masks stand

- **Subject** is every foreground instance Apple Vision returns (`VNGenerateForegroundInstanceMaskRequest`, `VisionMaskProvider.subject`), its edge then solved per pixel by closed-form matting with ViTMatte's strands. **Background** is its inverse.
- **Sky** arbitrates Segment Anything 2.1 tiny, seeded inside the classical estimate, with Depth Anything 3's sky (`RedlampEngine.modelSky`), then `SkyMatte` solves its edge.
- Since MSK-17, nearly all the masking work has gone into edges (MSK-26 to MSK-33). Which region a mask selects hasn't changed.
- The evidence so far: synthetic scenes with exact coverage, OneFormer as a stand-in reference on 14 photos (MSK-17), and the 115 CC0 photos of the evaluation set, unlabelled and judged by eye (MSK-25). Lightroom's masks were never collected: the bench tasks for Lightroom Mobile have waited in Redlamp Bench's outbox since 8 October.

## The bench (MSK-38)

**Pool.** The evaluation set (115 CC0 photos from Wikimedia Commons in 30 cells, and the 19 look-development raws) to begin with. After the first survey it grows to about 600 photos, aimed at the problem areas the survey finds: Commons and Openverse CC0 photos, raw.pixls.us raws, and hard negatives (no sky, no clear subject). Each photo's source, author, licence and checksum are in the manifest; `mise run maskeval` downloads them and they're never committed. A quick subset of about 120 photos serves iteration.

**Contenders.** Each is a named way of making a mask of a kind, listed in `research/mask-eval/contenders.json` with its licence status (cleared, evaluation only, commercial, cloud):

- Redlamp at a commit, through `redlamp mask --batch`, which keeps the models loaded between photos.
- Python candidates in the research environment. Each candidate's region goes through Redlamp's own edge solve (`redlamp mask --from <region.png> --refine-edges`), so it shows what shipping it would draw.
- Lightroom desktop's masks, decoded from its exports.

A run writes `build/mask-bench/runs/<run>/<contender>/<kind>/<photo>.png` at 2048 px on the long side, with `run.json` naming the commit, the models each mask used and the time each took.

**Lightroom desktop** (the owner's choice). The pool goes into an album. Five presets, made once: Baseline; Global, with Exposure −2.00; and Select Subject, Select Sky and Select Background, each with Exposure −2.00 inside the mask and nothing else. One export preset: 16-bit TIF, 2048 px on the long side, sRGB, no sharpening, original file names. Each batch is: select all, apply a preset, export to its folder, reset. Lightroom's adaptive presets recompute their masks for each photo, so a batch costs minutes of the owner's time, not a step per photo.

Coverage is decoded per pixel in linear light, from where the masked export lies between the baseline and the global export. A calibration pass first (six photos, and a grey card painted with a Density 50 brush) shows whether Lightroom blends its output by the mask or scales the slider by it, and which decoding applies. Pixels near black or clipped in either export are marked unknown. Lightroom's version is read from the exports' metadata, the exports are deleted once decoded, and the coverage maps stay on this Mac: only numbers and verdicts enter the repository (DEC-17, DEC-41).

**Scores**, per photo and kind, against Lightroom and against accepted references: missed and extra area as shares of the reference, IoU, boundary F at a tolerance tied to the photo's diagonal, and the disagreement split into region errors (blobs away from either edge) and edge differences (a band along it), so a gap can be told to be the region's or the edge's.

**Review page** (`mise run maskbench -- review`, in the browser). One photo and kind at a time, two masks shown as A and B in random order, their sources revealed only after the answer. Lightroom's red overlay, the mask alone, or the unmasked part darkened; Space flips between A and B, and Z zooms to 100% where they disagree most. 1 A is better, 2 B is better, 3 both are right, 4 both are wrong, 0 can't tell; then tags for what's wrong and a note. R accepts a mask as the photo's reference. Queues: largest disagreement first, a random sample (so rates aren't skewed by the ranking), a cell, or what changed since a run. A problem-areas page counts verdicts by kind, cell and tag, with win, tie and loss rates against Lightroom. Verdicts are appended to `research/mask-eval/verdicts.jsonl`, which is committed.

**The loop.** The largest problem area becomes a tracker row with its photos as its regression subset; a fix or a candidate runs on the quick subset, then on the pool; the owner reviews only the photos that changed. Accepted references from open models make a growing labelled CC0 set, which can train MSK-12's sky head later. References taken from Lightroom's masks are never used for that.

**Regression check.** `mise run maskbench -- check` runs the quick subset with the working tree's CLI against the last accepted run and the references, lists the photos whose masks moved, and opens the review page on them. It runs before a mask change ships.

## What the bench compares

**Subject (MSK-39), and Background with it:**

- Dedicated subject models: BiRefNet (general, the 2048 px high-resolution model and lite; MIT weights, trained partly on DIS5K, which is research-only), BRIA's RMBG-2.0 (BiRefNet's architecture trained on images BRIA licensed; CC BY-NC weights, so shipping it needs BRIA's commercial licence), and BEN2 and InSPyReNet once their licences are read.
- Choosing the subject as Lightroom does: keep the salient instances among Vision's (saliency, faces and people, size, focus, depth) rather than every one.
- Crisper regions: Segment Anything 2.1 large (Apple's Core ML packages, Apache-2.0, cleared under DEC-24) prompted with the chosen region's box and points.
- An analysis render with the shadows lifted and the highlights recovered, since masks are found on the default develop.
- Cloud models through the photographer's own key (DEC-39): fal serves BiRefNet v2, SAM 3 and RMBG-2.0.

**Sky (MSK-40):** Segment Anything 2.1 base+ and large in place of tiny, seeded as today; seeds that keep out water, glass, snow and pale walls, inside Depth Anything 3's sky where it's there; and OneFormer as a ceiling for evaluation only (ADE20K's images come partly from Places, which DEC-24 excludes from shipping).

**Edges:** MSK-27, MSK-28 and MSK-29 continue, ordered by how often the bench finds edge differences rather than region errors.

None ships until it beats today's masks on the bench. A new model needs no process version: AI masks are stored with the edit, so it changes only masks made or updated after it ships.

## Decisions

- **Lightroom desktop on this Mac** for Lightroom's masks, through presets and batch exports (the owner, 5 November 2026).
- **Every candidate is tried,** commercial and cloud included; shipping is decided per model on the measurements, as ViTMatte was under DEC-35 (the owner, 5 November 2026).
- **The review page is a local page in the browser,** built with the bench's Python tools and no package; a harness scene remains the alternative (default).

## What needs the owner

Installing Lightroom desktop and signing in; making the presets and the export preset once; the calibration pass and each batch; review rounds of about 30 minutes; agreeing targets after the first survey; and, depending on what wins, a fal key with a spending limit, BRIA's commercial terms, a decision row for a winner trained on research-only data, and approval before each model upload (DEC-26).

## Records

The tracker rows MSK-38, MSK-39 and MSK-40; findings in `docs/research/notes/MSK-38-mask-bench.md`; the workstream canvas `ws-mask-bench`.
