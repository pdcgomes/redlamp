# MSK-25: where Sky, Subject and People masks stand

Written on 6 October 2026 for the masking workstream (MSK-25, [#269](https://github.com/pdcgomes/redlamp/issues/269)), from what Redlamp draws rather than what it stores. Lightroom Mobile's results on the same inputs are still to come; until then this says where Redlamp stands against the truth only. Conventions follow [`_conventions.md`](_conventions.md).

## In short

- **The sky's aura is mostly how an edit is applied at an edge, not the mask.** Darkening a sky by 1.5 EV through its *true* coverage still leaves a light rim along every branch: +3.3 L* on average over the branch side of the edge, against an ideal of 0, and +13.5 L* on the pixels that are mostly branch in the tests' scene of dark branches against a bright sky. Through today's Sky mask the average is +4.0, with unedited patches of sky inside dense twigs. A mask's edit is applied to each pixel's own colour, scaled by coverage, so a pixel that is part sky and part branch is darkened by too little. The fix is MSK-27.
- **Process 13's render-time edge refinement made masks worse** on skies and slightly worse on hair. It now applies only to coarse masks (MSK-26, 3ab27c1, before process 13 shipped).
- **Hair's glow beside the subject is mostly the matte's.** On the bench's heads, brightening through the true coverage shows no halo above the measurement's floor; through the closed-form matte it does. On DSC02005, Subject leaves almost twice the haze over the dark background that People does. The closed-form matte also brings back only 31% of the strands that reach past the coarse mask, and none beyond the band it solves. The fixes are MSK-32 (ViTMatte) and MSK-29 (a person's Subject from their person mask, and flyaways).
- **The edit's application adds a glow too, where hair is dark against a light background:** brightening dark strands by 1 EV through their true coverage leaves the wall beside them 2.5 L* lighter than it should be. The bench's heads hide this under their floor. MSK-27 removes it with the sky's rim.
- **Sky region failures** remain beside the edge's: thick bare branches covered as sky (a 45 MP photo), patches of sky missed inside dense twigs, and some open sky in leafy crowns left partly covered. They are MSK-28's.
- **People finds nobody in a dense crowd** (`crowd-02`), and face parts haven't been measured at all yet (MSK-30).

## How it was measured

Evidence:

- **Scenes with exact coverage:** [`edge_bench.py`](../../../research/prototypes/masking/edge_bench.py) (12 skies behind bare and leafy trees, wires and skylines) and [`hair_bench.py`](../../../research/prototypes/masking/hair_bench.py) (6 heads with 600 stray strands and a beard). Each now comes with its ideal edit: the same scene with the sky darkened by 1.5 EV, or the person brightened by 1 EV, before compositing.
- **What's drawn:** `redlamp render --coverage` (669c47d) writes a mask's coverage as the renderer draws it; `--mask-bitmap` draws a given matte and `--process` an older process version.
- **The halo:** [`mask_bench.py`](../../../research/prototypes/masking/mask_bench.py) (b575dc4) develops the scene edited through a mask and the ideal scene, and compares them in CIELAB: the mean difference over the edge band, and the signed lightness difference on the side the edit shouldn't reach. Both are developed from linear DNGs of the scenes. Redlamp develops a bitmap as display-referred: a PNG opens looking as it was, and Exposure isn't a gain on its pixels. So a PNG's mix of sky and branch isn't a mix in Redlamp's scene space, and on PNGs a deep-sky check was 7.9 ΔE off; on DNGs it is 0.77, the floor below which nothing is measured.
- **Real photos:** the [evaluation set](MSK-25-photoset.md) (115 CC0 photos in 30 cells, and 19 look-development raws), with today's masks and a contact sheet per cell, whole and at 100%. They have no labels yet, so the verdicts on them are by eye.

## Results

**Skies darkened by 1.5 EV** (12 scenes):

| | Band error | Thin structures kept | Halo (ΔE) | Rim (ΔL*) |
| --- | --- | --- | --- | --- |
| Today's Sky mask, drawn | 0.050 | 99.7% | 3.51 | +4.04 |
| The true coverage | 0 | 100% | 2.71 | +3.28 |
| Floor (deep in the sky) | | | 0.77 | |

The rim is strongest on bare trees: +8.5 L* through the true coverage on one scene, where every twig comes out lighter and greyer than it should.

**Heads brightened by 1 EV** (6 scenes):

| | Band error | Strands kept | Halo (ΔE) | Rim (ΔL*) |
| --- | --- | --- | --- | --- |
| Closed-form matte, drawn | 0.125 | 15% | 3.22 | +0.32 |
| The true coverage | 0 | 100% | 1.89 | −0.16 |
| Floor (deep in the person) | | | 1.88 | |

**Process 13's render-time edge, before it was narrowed** (MSK-26):

- On the 12 skies it raised band error from 0.050 to 0.059 and kept 94.7% of twigs and wires instead of 99.7%; on the heads it was a little worse.
- On 10 photos of 24 to 50 MP, portraits didn't change. On skies it drew partial sky over a quarter of the stored mask's sure foreground on two of five photos (a crane's lattice at night, bare branches), and lightened open sky in a leafy crown.

**DSC02005** (a portrait with stray hairs and a beard against a dark, blurred background, one of the four the hair work was tuned on), against ViTMatte as a reference:

| | Error | Haze over the background |
| --- | --- | --- |
| Subject today | 0.181 | 0.165 |
| Subject before closed-form (Vision's edge) | 0.192 | 0.186 |
| People today | 0.144 | 0.090 |

**On the evaluation set:** People found no one in `crowd-02`, a dense protest crowd. On backlit hair against a bright sky, Subject's haze runs beyond the strands. On a 45 MP photo of thick bare branches, the Sky mask covers the branches as sky.

## The quality gate

Four tests keep these from getting worse unnoticed, as process 13's render-time edge did. Their scenes have coverage known exactly, and each bound sits a little above today's result, to be tightened by the change that improves it:

- **The edit at an edge** (`MaskRenderTests`, through the engine on linear scenes). A sky darkened by 1.5 EV through its true coverage: pixels mostly branch come out 13.5 L* lighter than the ideal, while deep sky is within 0.05 L* of it. Dark strands brightened by 1 EV: the wall beside them comes out 2.5 L* lighter. MSK-27 should bring both under 1.
- **The Sky matte** (`MatteQualityTests`). Twelve branches 0.5 to 3 px wide against a blue sky, from a coarse mask that has none of them: an error of 0.019 over the edge, and every branch pixel kept out of the sky. On a clean scene the matting holds up; its failures are in the harder cases above.
- **The Subject matte** (`MatteQualityTests`). Sixteen strands reaching 4 to 24 px from a head over a light wall: an error of 0.049 over the edge, and 31% of strand pixels brought back. That share is 50–70% within 4 px of the head, 40–60% at 4–8 px, 5–12% at 8–12 px, and none beyond the 12 px past the coarse edge that the matte is solved over (2% of the long side).

## What to fix, in order of what it would change for people

1. **Edge-aware application (MSK-27).** At a partly covered pixel, apply a mask's edit to the pure colour behind it (the sky's, the subject's) rather than to the mixed pixel. This is the largest single gain: it removes most of the sky's aura even with today's masks, and helps every mask's edges. A new process version.
2. **Sky regions (MSK-28):** sky between dense twigs, thick branches taken for sky, small gaps in leafy crowns, and edges where sky and foreground colours are close.
3. **Hair and subject edges (MSK-32, MSK-29):** ViTMatte over the unsure band, where it measures better than closed-form; flyaway strands beyond the band; a person's Subject from their person mask; crowds.
4. **Face parts (MSK-30):** measured first.
5. **Tools (MSK-31):** Refine Edges sized for 4096 px masks, and Edge and Feather that keep partial coverage.

## Proposed targets

To be agreed with the owner after Lightroom Mobile's results:

- **Sky:** halo through today's mask within 0.5 ΔE of the floor, and a rim under +0.5 L*, on the 12 skies; band error at most 0.05 and thin structures kept at least 99%; no unedited patches inside dense twigs.
- **Hair:** halo within 0.5 ΔE of the floor through the shipped matte; band error at most 0.08 on the heads; most strands kept, including the gate's strands beyond 8 px.
- **Against Lightroom Mobile:** a halo at or below its own on the same scenes, and on the owner's failing photos a result the owner judges at least as good.

## Limits

- The scenes' trees, wires and hair are drawn: straighter and more regular than real ones. The two-backdrop captures would give real ones.
- The heads' floor is high (1.88 ΔE, from their dark, noisy backgrounds), so a small halo from the edit's application could hide under it.
- The evaluation set has no labels yet: its verdicts are by eye.
- Lightroom Mobile's results are still to come. Its renders and figures will stay on this Mac; this note will say in words where Redlamp is behind or ahead.
