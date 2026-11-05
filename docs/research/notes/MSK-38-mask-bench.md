# MSK-38: the mask bench, and what it shows so far

Written on 5 November 2026 for the masking workstream (MSK-38, [#532](https://github.com/pdcgomes/redlamp/issues/532); MSK-39, [#533](https://github.com/pdcgomes/redlamp/issues/533); MSK-40, [#534](https://github.com/pdcgomes/redlamp/issues/534)), from the bench's first runs. Lightroom desktop's masks and the owner's verdicts are still to come, so this compares Redlamp with candidate models: it says where they choose different regions, not which is right. Conventions follow [`_conventions.md`](_conventions.md); the design is [`2026-11-05-mask-bench-design.md`](../../plans/2026-11-05-mask-bench-design.md).

## In short

- **The bench runs.** `mise run maskbench` (`rl masks …`) makes each contender's Subject, Sky and Background masks for the pool through `redlamp mask --batch`, scores any source against another, decodes Lightroom desktop's exports, and serves a review page where the owner judges pairs blind. `maskbench check` is the regression check before a mask change ships.
- **Subject finds nothing on a third of the evaluation set:** 45 of its 134 photos, mostly bare and leafy trees, snowy mountains, glass facades and other skies. Background, its inverse, finds nothing on the same 45. Lightroom's Select Subject always returns a selection, so these are the first problem area to put in front of the owner.
- **Where a subject is found, BiRefNet agrees with Vision's closely** (median IoU 0.979, boundary F 0.820 over 134 photos), but their regions differ by over 1% of the frame on 24% of photos and by over 5% on 15%, mostly on those 45. Which is right needs Lightroom and the owner.
- **On the whole pool (536 photos) today's Subject finds nothing on 210.** BEN2, which always selects something, differs from it by over 5% of the frame on 37% of photos. Keeping only the instances Vision's saliency picks out changes almost nothing (a region difference over 1% of the frame on 2% of photos), so extra instances aren't Subject's problem. Segment Anything 2.1 large, prompted with each part of Vision's Subject, redraws the region by over 5% of the frame on 7% of photos (boundary F 0.943 with today's); whether for the better waits on the owner.
- **Sky takes plain backgrounds for sky.** On the 59 of the first 134 photos that Vision's classifier gives under 0.01 of sky (portraits, faces, animals, objects), today's Sky covers over 5% of the frame on 25: a studio's white, grey or navy backdrop, a jellyfish tank, a whole forest. OneFormer covers none of them. Vision's classifier gives those photos 0.001 to 0.003 of sky and real skies 0.107 (an antenna against overcast) to 0.95, so a gate on it (`REDLAMP_SKY_GATE=0.01`, 625ce5aa6) takes the false sky away: across the 536 photos it removes a sky over 5% of the frame from 76 and keeps it on 272. Of the 76, six were chosen for their sky: four forest canopies, a misty forest and a window, where today's masks covered trees as much as sky; the seventh is the no-sky cell's, rightly emptied. The owner judges the trade.
- **The optional models change Sky a great deal:** without them, Sky's region differs from Sky with them by over 1% of the frame on 39% of photos and by over 5% on 22%, and finds no sky on 48 photos against 32; against OneFormer on the 60 photos chosen for sky, IoU 0.375 without them and 0.940 with them.
- **A larger Segment Anything changes Sky little.** With 2.1 base+ or large in place of tiny, Sky's region barely moves (IoU 0.998 with today's on the 60 sky photos, a region difference over 1% of the frame on 2% of them), its edges follow OneFormer's somewhat better (boundary F 0.669 and 0.674, from 0.564), and its false skies stay at 25 of 59. Large's 457 MB buys nothing over base+'s 166 MB.
- **Depth Anything 3's sky on its own follows OneFormer's edges better still** (boundary F 0.753, IoU 0.948 against 0.940), with slightly fewer false skies (23 of 59). This was measured by accident, when the first runs meant for Segment Anything base+ and large ran without them (the app's downloads time out in the agents' sandbox; `maskbench fetch-model` now puts a model in place through Python, and a contender whose model is missing stops), so Sky had no Segment Anything at all.
- **A lifted analysis render changes almost nothing** (Subject IoU 0.999 with today's; Sky's region differs by over 1% of the frame on 6% of photos).
- **BiRefNet can run in Redlamp.** Its deformable convolutions, which Core ML lacks, written as bilinear samples and a matrix product match torchvision's within 2e-6; the lite model converts to a 101 MB float16 Core ML program that takes 0.25 s a photo on the GPU, with a mask of IoU 0.9995 against PyTorch's. RMBG-2.0 shares the architecture.
- **Redlamp's masks repeat from run to run:** the regression check found 0 of the quick subset's 108 masks moved against the first run.

## The bench

- **Pool:** the evaluation set's 115 CC0 photos and 19 look-development raws, then 404 more CC0 photos from Wikimedia Commons in 26 new cells (538 photos): subjects the set lacked (wildlife, birds, vehicles, objects, food, flowers and insects, buildings, small subjects in large scenes, several subjects, action, clutter, silhouettes, camouflage, glass), skies it lacked (reflections, windows, canopies, stars, cities at night, aerial views, overcast streets, storms, rainbows), and photos with no clear subject and with no sky. The new cells' photos were taken in the search's order (camera EXIF first, then size), not picked by eye; each cell's contact sheet is in `build/mask-eval/sheets/` and `maskbench pool drop` takes out any that doesn't belong. A quick subset of 88 serves the regression check.
- **Contenders** (`research/mask-eval/contenders.json`): today's Redlamp, Redlamp without its downloads, and the candidates below, each region given Redlamp's own edges (Refine Edges) so it shows what shipping it would draw.
- **Scores:** missed and extra area, IoU, boundary F at 0.25% of the diagonal, and the disagreement split into region errors (more than 1% of the diagonal from either edge) and edge differences.
- **Lightroom desktop:** five presets (Baseline, Global Exposure −2.00, and Subject, Sky and Background with Exposure −2.00 inside), a grey card painted at Density 50 to say whether Lightroom blends its output or scales the slider, and a decoder that recovers each pixel's coverage in linear light. On simulated exports through an S-shaped curve, decoding as the exports were made comes within 0.0000 (blended) and 0.0098 (scaled) of the true coverage on average; the wrong decoding is off by about 0.02.
- **Speed:** 2.1 s a mask with two processes on the M1 Ultra (the first run's 804 masks in 11 min 48 s); a candidate's region with Redlamp's edges, 5 to 7 s, as each is solved from scratch.

## Candidates and their licences

| Candidate | Masks | Weights | Training data | Verdict |
| --- | --- | --- | --- | --- |
| BiRefNet (general, high resolution, lite) | Subject | MIT | Partly DIS5K, research-only | Would need a decision row to ship, as DEC-35 did for ViTMatte |
| BRIA RMBG-2.0 | Subject | CC BY-NC 4.0, gated | Images BRIA licensed | Would need BRIA's commercial licence; not yet run (Hugging Face refuses this Mac's token until BRIA's terms are accepted) |
| BEN2 | Subject | MIT | DIS5K and PramaLLC's own 22,000 images | As BiRefNet |
| InSPyReNet | Subject | Not read | | Not run |
| Vision's salient instances (`REDLAMP_SUBJECT_INSTANCES=salient`) | Subject | Apple's OS | | Ships today |
| Segment Anything 2.1 large prompted by Vision (`REDLAMP_SUBJECT_SAM=1`) | Subject | Apache-2.0 | SA-1B, SA-V (DEC-24) | Ships today (457 MB) |
| A lifted analysis render (`REDLAMP_ANALYSIS_RENDER=lifted`) | All | | | Ships today |
| Segment Anything 2.1 base+ and large for Sky (`REDLAMP_SAM_MODEL`) | Sky | Apache-2.0 | SA-1B, SA-V (DEC-24) | Ships today (166 and 457 MB) |
| OneFormer (ADE20K) | Sky | MIT | ADE20K, partly Places | Evaluation only (DEC-24) |
| fal's BiRefNet v2 and SAM 3 | Subject, Sky | Provider's terms | | Waits on the owner's key (DEC-39) |

## What waits

- **Lightroom's masks:** the owner's Lightroom desktop, its presets, the calibration pass and the batch (the canvas has the steps).
- **The owner's verdicts:** a first round can start now, Subject from today's Redlamp against BiRefNet (`mise run maskbench -- review --a redlamp --b birefnet`).
- **RMBG-2.0:** BRIA's terms accepted on Hugging Face.

## Limits

- Agreement between two contenders isn't correctness; every comparison here waits on a reference.
- The new cells' photos are the search's first results, not picked by eye; a few in each cell are off topic (a keyboard among the silhouettes).
- All the new photos are JPEGs from Commons; raws come only from the 19 look-development files.
- Timings come from a Mac under a load average of 30 to 60 from other work, so they say little about speed.
