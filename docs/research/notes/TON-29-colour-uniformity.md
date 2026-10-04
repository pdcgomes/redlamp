# Colour uniformity for skin (TON-29, TON-30)

A user suggested "a uniformity tool, similar to what Capture One does", especially for skin tones. This note sets out what Capture One's tools do, what Lightroom has, what Redlamp has, what a prototype measured on a portrait, and how Redlamp could build it. Written on 4 October 2026; every source was checked that day.

## Summary

- Capture One has two tools a photographer could mean. The **Uniformity** sliders in the Color Editor's Skin Tone tab (since Capture One Pro 9.1) pull every colour inside a chosen range towards a picked colour, separately in hue, saturation and lightness, so blotchy or uneven skin becomes one even tone. **Even Skin**, in the AI Retouch Face Skin tool (since 16.6, May 2025), evens out contrast over larger areas of skin and keeps its texture.
- Lightroom added a **Variance** slider to Point Color in Classic 15.0 (October 2025), which reduces or increases the colour differences inside the sampled range. Redlamp's Lightroom comparison plans Point Color for Phase 3, with no tracker row.
- Redlamp has the pieces around it (colour work in OKLCh, Color Range masks, Face Skin and Body Skin masks) but nothing that reduces colour variation.
- In a prototype on one portrait, pulling hue and saturation towards the skin's own colour more than halved the face's hue spread (5.9° to 2.8°), cut its chroma spread by 31% and evened the redness around the nose, with lightness untouched. Pulling lightness too flattened the face: a third of its shading and 42% of its pore-scale texture went. Applied per pixel, the pull also removed 29% of the fine colour detail; low-passed over the photo, it kept all of it.
- Proposed: **TON-29**, Point Color with Capture One's uniformity, globally and inside masks, with an Even Skin Tone mask preset (Phase 3, M); **TON-30**, a spatial version that evens regions of skin and keeps fine detail and the face's shading, as Even Skin does (Phase 3, M).

## 1. Capture One

### Skin Tone uniformity

Evidence ([Adjusting skin tones](https://support.captureone.com/hc/en-us/articles/360002596077-Adjusting-skin-tones), [The Color Editor overview](https://support.captureone.com/hc/en-us/articles/360002601358-The-Color-Editor-overview), [Making local adjustments with the Color Editor](https://support.captureone.com/hc/en-us/articles/360007944857-Making-local-adjustments-with-the-Color-Editor), [The history of tools and features](https://support.captureone.com/hc/en-us/articles/360012248397-The-history-of-tools-and-features-added-to-Capture-One-Pro)):

- The Color Editor has three modes: Basic (eight colour bands), Advanced (up to 30 picked colours per photo, each with its own range), and Skin Tone, which adds three Uniformity sliders.
- The workflow is to pick the colour to keep, then widen the range on the colour wheel to take in the unwanted hues; for light skin, Capture One suggests picking a neutral tone and widening the range to the reds and yellows. Smoothness sets the falloff at the range's edge.
- Each Uniformity slider (Hue, Saturation, Lightness), moved right, brings the colours in the range closer to the picked colour on that axis. The Amount sliders shift the whole range, as in Advanced. The picked colour can be moved, to warm or cool the skin, and the range moves with it.
- Capture One suggests a rough mask over the skin (a layer), so other things of the same colour aren't changed; colour edits on overlapping layers add up. It also suggests the tab for evening out skies, with care.
- The Uniformity sliders arrived in Capture One Pro 9.1.

Assessment: the arithmetic isn't published. The description fits a pull towards the reference on each axis, weighted by how far inside the range each colour lies; the prototype below implements that reading.

### Retouch Face Skin: Even Skin

Evidence ([Retouch Face Skin tool](https://support.captureone.com/hc/en-us/articles/27336176639133-Retouch-Face-Skin-tool), [16.6.0 release notes](https://support.captureone.com/hc/en-us/articles/26809869126557-Capture-One-16-6-0-Release-Notes), [16.7 release notes](https://support.captureone.com/hc/en-us/articles/31141690629917-Capture-One-16-7-release-notes), [Retouch Faces in Capture One mobile](https://support.captureone.com/hc/en-us/articles/30277789058461-Retouch-Faces-in-Capture-One-mobile)):

- An AI tool introduced in 16.6.0 (20 May 2025). Faces are found automatically (at least 200 px on the short edge, up to 32 per photo), and its sliders apply to all faces or to one.
- Even Skin evens out differences in contrast over larger areas of skin, keeping highlights and texture; a Texture slider sets how much texture is kept. Since 16.7 a toggle takes it onto the neck. The same tool has Blemish Removal, Dark Circles, Contouring, and an Impact slider over all of them.
- Presets and Copy and Apply carry only the adjustments made to all faces.

Assessment: a spatial operation on tone (lightness differences at a larger scale), not a colour mapping. It does what the Uniformity sliders can't without flattening the face (section 4).

## 2. Lightroom

Evidence (the [Lightroom feature inventory](../../lightroom-feature-inventory.md), sections 5 and 22; [The Lightroom Queen on the October 2025 releases](https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/)):

- Point Color samples a colour, shifts its hue, saturation and luminance, sets the hue, saturation and luminance ranges, visualizes the range, takes several swatches, and works inside masks.
- Classic 15.0 (October 2025) added a Variance slider to Point Color. It raises or lowers the colour contrast inside the selection: lowered, it evens out variations such as redness in cheeks or a polarized sky; raised, it separates similar colours. It can be used without the panel's other sliders.
- In that post's comments, a reader who sampled the red patch and lowered Variance got poor results. Sampling the good skin and widening the range to the red, as a video by Julieanne Kost shows, did better, but still looked less natural to them than Capture One's skin tool had. This is one reader's account, not a measurement.

Not verified: Adobe's own pages, which refuse automated requests from the agent sandbox. Whether Variance acts on hue, saturation and luminance together, and its scale, are unknown, and so are the fields Lightroom writes inside a preset's `PointColors`.

## 3. Redlamp today

- The Color Mixer shifts eight hue bands in OKLCh, in the develop kernel after the tone curve and Base Look (`Develop.metal`); Vibrance holds back on skin hues around 55°. Neither reduces the variation inside a band.
- Color Range masks (MSK-05) select colours in OKLCh on the edit guide, and a mask's Hue and Saturation shift what they select; nothing pulls colours together.
- People masks give Face Skin (Apple Vision's landmarks, MSK-08: the face without its eyes, eyebrows and lips, so without the teeth) and Body Skin (SAM 3, MSK-13). They mark skin more precisely than the rough mask Capture One suggests.
- The Smooth Skin mask preset lowers Texture (−35) and Clarity (−10) on Face Skin. It softens texture rather than evening colour.
- Point Color is Planned for Phase 3 in the [Lightroom comparison](../../lightroom-comparison.md), with no tracker row, and Lightroom presets' Point Color is ignored on import.

## 4. Prototype

[`research/prototypes/colour/uniformity.py`](../../../research/prototypes/colour/uniformity.py), on `DSC02005` from the masking edge-case set (`build/edge-cases`, a 1366 × 2048 JPEG render of a Sony A7R V portrait in warm light, not committed). It works in OKLab (B. Ottosson, "A perceptual color space for image processing", 2020) from the sRGB file, not inside Redlamp's pipeline.

- **Reference:** the median of the face's skin-coloured pixels (L 0.425, C 0.060, h 50.6°), standing in for a click on even skin.
- **Range:** hue fully within 20° of the reference and not at all past 45°; chroma from 0.02 to 0.30 and lightness from 0.12 to 0.97, with smooth edges; inside Vision's person mask.
- **Per pixel:** each axis moves towards the reference by its amount times the range's weight (chroma as a ratio).
- **Spatial:** the same pull, low-passed under the mask with a Gaussian of 6 px, then added.
- **Scores,** over the face's skin (range weight above 0.5): the spread of hue from the reference and of chroma; the spread of lightness above 12 px (shading and blotches) and below 2 px (texture); and the RMS of the a and b channels below 2 px (fine colour detail).

| | Hue spread | Chroma spread | Lightness above 12 px | Lightness below 2 px | Colour detail below 2 px |
| --- | --- | --- | --- | --- | --- |
| Before | 5.89° | 0.0114 | 0.0823 | 0.0270 | 0.0027 |
| Per pixel: Hue 60, Saturation 40 | 2.78° (47%) | 0.0079 (69%) | unchanged | unchanged | 0.0019 (71%) |
| Per pixel: Hue 60, Saturation 40, Lightness 50 | 2.78° (47%) | 0.0079 (69%) | 0.0534 (65%) | 0.0156 (58%) | 0.0019 (71%) |
| Spatial: Hue 80, Saturation 60 | 3.35° (57%) | 0.0071 (63%) | unchanged | unchanged | 0.0027 (100%) |

Findings:

1. **Hue and saturation do the work.** The redness around the nose and lower cheeks moves to the face's own tone, and lightness is untouched, so the face keeps its modelling.
2. **Lightness uniformity flattens.** At 50 it removes a third of the face's shading and 42% of its pore-scale texture, the "plastic" look retouchers avoid. Presets should leave it at zero.
3. **Per pixel, fine colour detail goes too:** 29% of the colour detail below 2 px (pores, small spots). The spatial version keeps all of it, and at slightly higher amounts still takes 43% off the hue spread and 37% off the chroma spread.
4. **The range needs a mask.** Unmasked, the same range selects the wooden sign and the warm lights behind the subject. The person mask keeps them out, but takes in the teeth, which fall inside the range and would be pulled towards skin. Face Skin and Body Skin leave them out.

The figures (`build/proto-out/uniformity/`) aren't committed: the photo is of an identifiable person.

## 5. How Redlamp could do it

**TON-29, Point Color with uniformity.** In the develop kernel's OKLCh stage, beside the Color Mixer, each swatch has a reference colour (picked, or the median under its mask on the edit guide), hue, chroma and lightness ranges with a falloff, Lightroom's shifts, and Capture One's three uniformity amounts. What has to hold:

- The pull keeps the colour mapping monotonic, or the range's edge bands. Towards the reference it does, as long as each amount u is at most 1 and the weight w falls away from the reference: the slope of Δ ↦ Δ(1 − u·w(Δ)) is 1 − u·(w + Δ·w′), at least 1 − u. Away from the reference (Lightroom's Variance raised) the slope turns negative where the falloff is steep, so expansion needs a limit tied to the falloff.
- Hue is unreliable near grey, so the pull is weighted by colourfulness, as the Color Mixer's shifts are.
- New controls at zero leave existing edits as they render, so no new process version is needed (`ProcessStabilityTests` would show otherwise); the sidecar schema gains the swatches.
- Inside masks, each mask carries its own swatches. A Face Skin and Body Skin preset (Even Skin Tone) then evens skin in one step, its reference taken from the mask, with hue and saturation uniformity and lightness at zero.
- Lightroom presets carry Point Color as `PointColors`, which the XMP preset import ignores today ([Lightroom presets](../../recipes/lightroom-presets.md)). Mapping it, with Variance, waits on the fields inside it.

Cost: a few arithmetic operations per swatch per pixel in the fused kernel.

**TON-30, spatial uniformity.** The pull computed per pixel and low-passed under the mask, as a map at reduced resolution like the tone base and haze maps, so blotches even out and pores and freckles keep their colour; and lightness evened above pore scale inside the skin mask, keeping the face's broader shading, from the detail stage's decomposition (TON-06). That is Capture One's Even Skin, with its Texture control, and the automatic counterpart of TON-15's frequency separation. For redness in particular, Tsumura et al. separate skin colour into melanin and haemoglobin components by independent component analysis of its optical density ("Image-based skin color and texture analysis/synthesis by extracting hemoglobin and melanin information in the skin", ACM Transactions on Graphics 22(3), 2003, [doi:10.1145/882262.882344](https://doi.org/10.1145/882262.882344)), and Ojima et al. analyse uneven skin colour with them (SPIE 7897, 2011, [doi:10.1117/12.873494](https://doi.org/10.1117/12.873494)). Evening only the haemoglobin component would take out redness and leave freckles, tan and shading. It needs a patent check before it is adopted, as DEC-05 does for other methods. Performance-sensitive: one reduced-resolution map per mask.

## 6. Open questions

- Phase: the comparison has Point Color in Phase 3; as a Develop panel control it could move into Phase 2.
- Controls: one signed Variance slider (Lightroom's), three Uniformity sliders (Capture One's), or both, with Variance driving all three.
- Comparison: Capture One and Lightroom measured on the same portraits, which needs both apps.
- Coverage: more portraits, with lighter and darker skin and stronger redness; the prototype ran on one.

## Sources

Checked on 4 October 2026. Capture One's help-centre pages refuse automated requests (HTTP 403), so their text was read through the help centre's public API (`https://support.captureone.com/api/v2/help_center/en-us/articles/<id>.json`); the article IDs are in the links above. The Lightroom Queen's post was read directly.
