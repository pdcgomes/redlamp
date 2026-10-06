# Edge-aware application of mask edits: design (MSK-27)

A mask's edit is applied to each pixel's own colour, with the mask's parameters scaled by its coverage (`Develop.metal`: `localTone += coverage[i] * layers[i].tone`). At a pixel that is partly sky and partly branch, Exposure −1.5 EV becomes a gain of 2^(−1.5α) on the mixed colour: the branch's share is darkened with the sky's, and the sky's share by too little. So twigs come out lighter and greyer than they would if the sky had been darkened before the two mixed. Through a perfect mask, pixels that are mostly branch come out 13.5 L* too light in the quality gate's scene, and the halo over the edges of edge_bench's skies is 2.71 ΔE against a floor of 0.77 ([the review](../research/notes/MSK-25-mask-review.md)). This is most of what reads as the sky's aura.

## The idea

- **The edit reaches only the masked share of an edge pixel's light.** A pixel's light C is the masked side's share M (its coverage α times the masked side's pure colour F) plus the rest. The pixel develops as it does today with every other mask's parameters (S(C), the rest), and the mask adds the difference its own parameters make to F, scaled by α: out = S(C) + α·[S_mask(F) − S(F)], before the tone curve. With no edit in the mask the difference is nothing, so nothing that renders today changes; a pixel wholly inside or outside the mask renders as it does today. For Exposure alone this is C + α(2^ev − 1)F.
- **F from the colours on either side.** F̂ is filled in from the nearest pixels wholly inside the mask (coverage at least 0.98), and B̂ from those wholly outside it (at most 0.02), by push-pull, as `StackDepth.fill` does. The masked share is their mix by coverage, M = (1 − α)·αF̂ + α·(C − (1 − α)B̂), clamped between nothing and C, and F = M/α. The inside estimate's error is scaled by α and the outside's by 1 − α, so the mix errs by at most a quarter of the two estimates' errors together.
- **The maps:** F̂ and B̂ are computed once per mask and photo on the analysis grid, in the sensor's orientation, from the analysis image's camera RGB, and kept as two half-float slices of a texture array, as process 13's edge coefficients are (`MaskEdges`). The develop kernel samples them at the pixel and takes them through what the pixel's own colour went through first: vignetting, Dehaze and, for a bitmap, the undone tone curve.
- **Which masks:** Sky, as an AI mask's only component, without Feather (Feather asks for a soft edit, which blending gives). Subject and People wait for ViTMatte's mattes (MSK-32): through today's closed-form mattes the prototype's halo rose from 3.44 to 3.63 ΔE. A mask of several components keeps blending.
- **Which controls:** the per-pixel, scene-referred ones: Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites and Blacks. Dehaze, halation, bloom, Defringe and Moiré read the pixels around and keep blending by coverage, as do the display-referred controls (Hue, Saturation, the Color swatch, Curves) and the detail stage's (Clarity, Texture, Sharpening, Noise).
- **In the kernel:** where a split mask's coverage is mixed (between 0.002 and 0.998), its scene-referred parameters leave the summed ones and the pixel develops with the rest. F goes through the same per-pixel stages twice, with and without the mask's parameters, and α times the difference joins the pixel before the tone curve. The stages F goes through are the pixel's own, without those that read the pixels around: white balance, the camera matrix, the profile's hue and saturation map and gain table, Exposure, Calibration's Shadows Tint, the tone controls and the end points. The tone controls and end points move into functions both use.
- **Process version 14** (the owner's choice, 6 October 2026): process 13 and earlier keep blending.
- **Cost:** six push-pulls per mask and photo on the CPU, on about 1.5 MP; in the kernel, two more passes through the per-pixel stages at mixed pixels only.

## Validation

The prototype ([`edge_apply.py`](../../research/prototypes/masking/edge_apply.py), 1dcfe02) applies Exposure to the masked share of each edge pixel on edge_bench's 12 skies and hair_bench's 6 heads, through each scene's true coverage and today's mask, and develops each result with redlamp from a linear DNG. Its simulation of today's application is within 0.45 ΔE of redlamp's own. In the engine: the quality gate's sky test at process 14, renders without an edit unchanged, process 13 and earlier unchanged (`ProcessStabilityTests`), and `mask_bench.py` through the true coverage and today's Sky mask, against the prototype.

## Steps

1. This design and the prototype (1dcfe02).
2. The colour maps (`MaskColors`), with a unit test.
3. The kernel behind process 14, with render tests; the quality gate's sky bound tightened.
4. Process 14's references, and the sidecar schema's maximum and table.
5. `mask_bench.py` on the engine; the tracker, README, the Lightroom comparison and this design's results.

## Results

**The prototype, on the 12 skies darkened by 1.5 EV.** The error at mixed pixels is the mean lightness difference from the scene darkened before compositing over pixels mostly branch (true sky coverage 0.05 to 0.5); the halo is the mean CIELAB difference over the edge band, whose floor deep in the sky is 0.75 ΔE.

| Application | True coverage: error at mixed pixels | Halo | Today's Sky mask: error at mixed pixels | Halo |
| --- | --- | --- | --- | --- |
| Today's (simulated) | +11.7 L* | 3.17 ΔE | +14.1 L* | 4.00 ΔE |
| From the inside colour | +0.1 | 1.65 | +7.4 | 3.32 |
| From the outside colour | +0.6 | 1.37 | +6.3 | 2.85 |
| Both, by coverage | +0.2 | 1.27 | +7.4 | 3.11 |

Through the true coverage the edit's part of the aura is nearly gone; through today's Sky mask the error halves, and what is left is the mask's (unedited sky inside dense twigs, MSK-28).

**In the engine (process 14).** The quality gate's scene (dark branches 0.5 to 3 px wide against a bright sky, darkened by 1.5 EV through its true coverage): pixels mostly branch come out 0.5 L* darker than the ideal, against 13.5 L* lighter at process 13; deep sky is within 0.05 L* of the ideal at both. A Sky mask without an edit draws as it does at process 13, and with one, every pixel wholly inside or outside it does too (`MaskRenderTests`). Process 13 and earlier render as recorded (`ProcessStabilityTests`).

**In the engine, on edge_bench's 12 skies** (`mask_bench.py`, darkened by 1.5 EV, developed from linear DNGs):

| | Process 13 | Process 14 |
| --- | --- | --- |
| Halo through the true coverage | 2.71 ΔE | 0.93 ΔE |
| Rim through the true coverage | +3.28 L* | +0.13 L* |
| Halo through today's Sky mask | 3.51 ΔE | 2.67 ΔE |
| Rim through today's Sky mask | +4.04 L* | +2.11 L* |
| Floor, deep in the sky | 0.77 ΔE | 0.74 ΔE |

Through the true coverage the halo is within 0.2 ΔE of the floor, so the edit's part of the aura is gone. Through today's Sky mask the rim halves; the rest is the mask's (sky left out inside dense twigs, MSK-28).

**On the 6 heads brightened by 1 EV,** both estimates by coverage take the halo through the true coverage from 2.04 to 1.08 ΔE, but through today's closed-form mattes it rises from 3.44 to 3.63. (Brightening before the DNG is written clips highlights that redlamp's own Exposure keeps, so the floor on this path is 4.4 ΔE; the methods compare with each other, not with the floor.)

## Limits

- F̂ and B̂ are smooth. Where the colour behind a pixel changes within a few pixels (a twig in front of a cloud's edge), the estimate is off, by at most a quarter of both estimates' errors.
- Pixels the mask has wrong stay wrong.
- The controls that keep blending keep the halo they have today.
