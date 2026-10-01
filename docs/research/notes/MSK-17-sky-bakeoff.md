# MSK-17: Sky mask bake-off

Run 2026-10-01 on an M1 Ultra (macOS 26.6), by `research/prototypes/masking/sky_bakeoff.py`. Raw scores are in `research/prototypes/masking/sky-bakeoff-results.json`. Conventions follow [`_conventions.md`](_conventions.md).

## Question

Redlamp's Sky mask has no Apple API behind it. Can an open model, or Segment Anything without any training, give a Sky mask good enough to ship, or do we need to train our own head (MSK-12)?

## Method

- **Photos:** the 14 photos tagged "sky" in the CC0 look-development set (`research/look-dev/manifest.json`), as analysis renders: the default develop, sRGB, 2048 px. That is what every AI mask is computed from.
- **Reference:** OneFormer (ADE20K, Swin-L), the strongest open semantic segmenter. It is trained on ADE20K, whose terms are non-commercial, so it can never ship. It stands in for ground truth until a hand-labelled set exists (see Limits).
- **Scores:** IoU, and a boundary F-score that counts edges within 1% of the image diagonal, both against the reference. Times are wall clock per photo, including the CLI opening the raw.

| Candidate | What it is | Licence verdict |
| --- | --- | --- |
| Classical estimate | `SkyEstimator`: bright, smooth, sky-coloured pixels grown from the top edge, then a guided filter | Ours |
| Auto-prompted SAM 2.1 | Segment Anything 2.1 tiny, prompted with up to four points deep inside the classical estimate (`SkyEstimator.seeds`) | Apache-2.0 weights by the data's owner (Meta). Shippable once DEC-02 is accepted |
| Florence-2 base | `<REFERRING_EXPRESSION_SEGMENTATION>` "sky", rasterised polygons | MIT weights; training data (FLD-5B) unclear. A labeller at most |
| OneFormer ADE20K | The ceiling | Non-commercial data: never ships |
| Depth Anything 3 Mono-L (sky output) | The sky head of `depth-anything/DA3MONO-LARGE` (0.35B parameters, 1.2 GB), at 504 px, PyTorch on the GPU (MPS) | Apache-2.0 weights; data "public academic datasets" (not audited): UNCLEAR |
| SAM 3 (text prompt "sky") | `facebook/sam3` (0.85B parameters, 3.4 GB) through Transformers 5 on the GPU (MPS), every instance merged; `sam3_sky.py` in its own environment | Custom SAM License (gated; pass-through and no-reverse-engineering terms): UNCLEAR, counsel |

## Results

| Candidate | Found sky | Mean IoU | Mean boundary F | Worst IoU | Time per photo |
| --- | --- | --- | --- | --- | --- |
| Mean of auto-prompted SAM 2.1 and DA3 | 14 / 14 | **0.945** | **0.937** | 0.709 (FZ28) | both, below |
| Depth Anything 3 Mono-L sky | 14 / 14 | 0.929 | 0.887 | 0.697 (Coolpix P7700) | 0.26–0.61 s warm (MPS) |
| SAM 3, text prompt "sky" | 14 / 14 | 0.924 | 0.894 | 0.579 (FZ28) | 0.95 s warm (MPS), 72 s to load |
| Auto-prompted SAM 2.1 | 14 / 14 | 0.920 | 0.894 | 0.585 (FZ28) | 1.6–3.1 s (CLI, cold) |
| Classical estimate | 14 / 14 | 0.898 | 0.821 | 0.622 (Coolpix P7700) | 1.3–6.5 s (CLI, cold) |
| Florence-2 base | 14 / 14 | 0.661 | 0.657 | 0.138 | 19–80 s (CPU) |

The SAM–DA3 combination averages the two soft masks. Their union scores 0.931 / 0.892 and their intersection 0.918 / 0.888, so neither helps. Adding SAM 3 to any mix doesn't help either: SAM 2.1 with SAM 3 scores 0.924 / 0.895, DA3 with SAM 3 0.923 / 0.889, and all three 0.930 / 0.902.

![Contact sheet: render, OneFormer, classical, DA3, Florence-2, auto-prompted SAM 2.1, SAM 3](../../images/masking-sky-bakeoff.jpg)

The columns of the contact sheet are the render, OneFormer, the classical estimate, Depth Anything 3, Florence-2, auto-prompted SAM 2.1 and SAM 3.

- **Auto-prompted SAM 2.1 is the best shippable candidate.** Its edges are clearly better: boundary F is 0.894 against 0.821. Where the classical estimate fails it recovers most of the sky. On the Coolpix P7700 (a tree line) it scores 0.937 against 0.622, on the Panasonic TZ200D 0.947 against 0.869, and on the Pixel 6 Pro (distant mountains the estimate spills into) 0.976 against 0.876.
- **It has one clear failure.** On the Panasonic FZ28 it scores 0.585 against the estimate's 0.808: SAM took a sub-region of a cloudy sky as "the object".
- **The classical estimate is good on clear skies** (0.94–0.99 on eight of the photos). It fails where the sky's brightness or colour changes across the frame.
- **Depth Anything 3's sky head is the best single model** on overlap (IoU 0.929), close to SAM on edges, and fast: about 0.3 s on the GPU once loaded. Its failures are the opposite of SAM's. It loses the Coolpix tree line (0.697, where SAM gets 0.937), and keeps the FZ28's cloudy sky that SAM drops (0.839 against 0.585).
- **SAM 3 adds nothing over SAM 2.1.** Asked for "sky" by text, its score is within 0.02 of SAM 2.1's (seeded from the classical estimate) on every photo, and it fails on the same two. It is also 0.85B parameters and under a custom licence.
- **Where the SAM models fail, it is bare trees.** Both treat a leafless tree crown as an object and cut around its silhouette, leaving out the sky seen between the branches (and power lines). OneFormer and DA3 count that sky as sky, and so would an editor darkening it. So the lower scores on those photos are a real weakness, not only the reference's bias:

![Panasonic FZ28 and FX150: render, OneFormer, DA3, SAM 2.1, SAM 3](../../images/masking-sky-disagreements.jpg)

- **Averaging the two is clearly best:** 0.945 / 0.937, with a worst case of 0.709. Each covers the other's failure.
- **Florence-2 is not competitive.** Its polygons are coarse and it often selects only part of the sky. It is also far too slow on the CPU to be interactive.

## Decision

- **Depth Anything 3 is the candidate to evaluate next.** Mixed with SAM it is the best Sky by a clear margin, and Depth Range could use it too. Before it can ship it needs a training-data audit (counsel, with DEC-02). It also needs a Core ML conversion: there is no official one, and at 0.35B parameters it is about 700 MB in fp16.
- **Until then, ship Sky as auto-prompted SAM 2.1** (default `REDLAMP_SKY_METHOD=auto`) when its model is on the Mac, with the classical estimate as the fallback. An embedded sky matte, when the file has one, wins over both.
- **No Sky head training (MSK-12) for now.** Revisit it if hand-labelled scores show tree lines and hair need better than SAM's edges.
- **Landscape classes and people parts still need a trained head (MSK-13).** Unlike sky, there is no classical estimate to seed SAM with for water, vegetation or skin. Every open model that knows those classes (OneFormer, Mask2Former, SegFormer) is trained on non-commercial data.

## Limits

- **The reference is a model, not ground truth.** Scores measure agreement with OneFormer, so a candidate that beats OneFormer at an edge is scored down for it. The next step is a hand-labelled set: 50 photos we have rights to, labelled by drafting with SAM 2.1 and checking by hand.
- **The set is small** and nearly all landscapes in daylight. Sunsets, night, fog, snow fields and window reflections are missing.
- **Running DA3 here took workarounds.** Its package requires xformers (which doesn't build on macOS, and it falls back without it). `pycolmap` and PyTorch each load an OpenMP runtime, so the script needs `KMP_DUPLICATE_LIB_OK=TRUE`. Its preprocessing pool is forced to run sequentially.
- **SAM 3 runs in its own environment** (`.venv-sam3`, Transformers 5), because Florence-2's remote code needs Transformers 4.x.
- **Shipping SAM waits on DEC-02 (counsel).** Until it is accepted, the model is offered only with evaluation models turned on (Settings › Models).
