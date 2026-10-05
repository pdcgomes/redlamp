# Point Color with uniformity: design (TON-29)

Lightroom's Point Color, with Capture One's uniformity: pick a colour on the photo, shift it and the colours near it, and pull those colours together, so blotchy skin evens out to one tone. It works on the whole photo and inside masks, and an Even Skin Tone mask preset does it for skin in one step. Tracker: TON-29 (#181); it waits on TON-31 (#190), where the colour controls sit, and TON-30 (#182), the spatial version, follows it. The research, sources and a prototype's measurements are in [the note](../research/notes/TON-29-colour-uniformity.md).

**Status (2026-10-06):** approved; building on the `point-color/build` branch. Steps 1 (`model`) to 5 (`masks`) done, with the mask's own colour in step 5; the command palette and the Delete key moved to step 7. Next: tuning (step 6).

## Decisions (the owner)

- **Phase 2** (2026-10-04): Point Color is Develop parity.
- **TON-30 waits** until TON-29 has shipped (2026-10-04).
- **TON-31 first** (2026-10-05): the comparison of the colour controls before and after the tone curve runs before Point Color is built, so Point Color goes where they end up.
- **The colour controls stay after the tone curve** (2026-10-05), as [TON-31's A/B](../research/notes/TON-31-colour-stage.md) recommends, to revisit with HDR output in Phase 4. Point Color goes right after the Color Mixer, there.
- **The design approved** (2026-10-05), with three Uniformity sliders and up to 8 swatches on the edit and on each mask.

## A swatch

Up to 8 swatches on the edit, and up to 8 on each mask. Each has:

- **A colour,** in OKLCh. Either picked with the eyedropper (then where it was picked is kept, so the panel can show it) or, on a mask, **the mask's own colour** (below).
- **A range:** how far in hue, saturation (chroma) and luminance (lightness) a colour can be from the swatch's and still be selected, and Smoothness, how gradually the selection fades out at the range's edge.
- **Shift:** Hue, Saturation and Luminance, −100 to 100, scaled as the Color Mixer's sliders until EDT-11 fits them against Lightroom's.
- **Uniformity:** Hue, Saturation and Luminance, −100 to 100. Above 0, the colours in the range move towards the swatch's colour on that axis; at 100, all the way where the range selects fully. Below 0 they move apart (Lightroom's Variance raised), up to a limit that keeps the colours in order. Lightroom's Variance is the negative of a uniformity.

The swatch stores a colour, not a place on the photo, so it means the same in presets, in Copy Settings and Sync, and in Lightroom's presets. Like the Color Mixer's bands, it stays put when white balance or exposure change afterwards.

## The arithmetic

In the develop kernel, right after the Color Mixer: after the tone curve and the Base Look, in OKLCh, where TON-31 kept the colour controls.

- **The weight** is the product of three trapezoids around the swatch's colour, one per axis, with smooth edges (as the Luminance Range mask's), hue measured on the circle. It is multiplied by the pixel's colourfulness, as the Color Mixer's shifts are, since hue means little near grey.
- **The pull** works on each axis's distance from the swatch: hue as the shorter arc, chroma as a ratio, lightness as a difference. A uniformity `u` above 0 scales the distance by `1 − u·w`, where `w` is the weight. Since `w` falls away from the swatch's colour, the mapping's slope, `1 − u·(w + d·w′)`, is at least `1 − u`: colours never change order.
- **Pushing apart** scales the distance by `1 + k·w`. Where the weight falls steeply, the slope `1 + k·(w + d·w′)` can turn negative, so colours would cross and the range's edge would band. For each swatch's range, the engine works out the largest `k` that keeps the slope at least 0.25 everywhere, and −100 maps to it.
- **Shift** then moves the selected colours by the shift times `w`.
- **Several swatches:** each one's change is worked out from the same input colour, and the changes add up, as the Color Mixer's bands blend. A mask's swatches come after the edit's own, scaled by the mask's coverage and Amount, like its other adjustments.
- **Cost:** a few dozen arithmetic operations per active swatch per pixel; swatches at their defaults are skipped.

## The swatch's colour

- **Picking.** The eyedropper works like Color Range's (a click, or a drag for a larger disc). It reads the colour that Point Color receives there, averaged over the disc. That needs its own sample: the edit guide holds the edit's final colours, Point Color's own effect included. A one-off render of Point Color's input, with the edit's masks, at the guide's size (2048 px), is read as `sampleEditGuide` reads the edit guide (`RedlampEngine.pointColorInput(sampledAt:radius:recipe:)`).
- **The mask's own colour,** for a swatch on a mask: the median of Point Color's input under the mask, near-greys left out. It comes from a small render of Point Color's input with the edit's masks (512 px, about a quarter of a megapixel, of the frame uncropped), with the mask's coverage in alpha; a histogram kernel counts OKLab lightness, a and b under the mask, weighted by its coverage and by chroma from 0.01 to 0.03, and a one-thread kernel writes their medians into a small buffer the develop pass reads. Near-greys are left out because, where they outnumber the skin (white clothes inside a body skin mask, grey hair), they made the colour grey and the swatch selected nothing (step 6). All of it is in the render's own command buffer, so nothing waits on the CPU and nothing needs a cache: it's measured again for every render that has such a swatch. It follows the photo's white balance and every edit before Point Color, and works on every photo the mask is pasted to: AI masks are recomputed for each photo, and so is their colour.
- **Visualize Range,** as in Lightroom: the develop kernel shows the selected swatch's selection, colour where it selects and grey elsewhere, as Visualize Spots draws its own view.

## The panel

- **The Color Mixer panel** gains Point Color beside HSL and Color in its picker, as Lightroom's Color Mixer has Point Color. It shows the swatches (the eyedropper adds one, up to eight, and with eight picks the selected swatch's colour again; click selects; the bin deletes the selected one), then Shift, Uniformity and Range for the selected swatch, dimmed until there is one, and Visualize Range. Leaving the mode ends the eyedropper and Visualize Range; the white balance eyedropper and Point Color's are never on together.
- **The mask panel** gets the same section, with the mask's own colour as a choice for a swatch's colour. While the Masking tool is open, the eyedropper, the swatches and the sliders act on the selected mask's swatches (a click, or a disc dragged out to average, as the Color Range eyedropper does), and leaving the tool ends the eyedropper and Visualize Range.
- **The command palette** finds Point Color and its sliders, which act on the selected swatch, and the Delete key deletes it (step 7: the palette's sliders need a swatch to act on).
- **The component harness** gets a Point Color specimen beside the Color Mixer's: the Point Color parity scene, with two swatches.
- **Report a Bug** lists Point Color as a feature of Develop (`develop.point-color`), and its sliders report it.

## The Even Skin Tone preset

- **Components:** People's Face Skin, plus Body Skin when SAM 3 is installed (Face Skin alone otherwise).
- **One swatch** with the mask's own colour; range: hue fully within 20° and none past 45°, all but near-greys, deep shadows and speculars (Hue Range 47, Saturation Range 64, Luminance Range 37, Smoothness 50); uniformity: Hue 50, Saturation 35, Luminance 0. Luminance stays at 0: in the prototype, uniformity on lightness took a third of the face's shading and 42% of its pore-scale texture. On four portraits (step 6, the TON-29 note's "Even Skin Tone on four portraits"), these values take 41–48% off the skin's hue spread and 28–33% off its chroma spread, leave about two thirds of its fine colour detail, and barely move anything else; they stay.
- `MaskPreset` gains swatches (each applied mask gets swatches of its own) and optional parts: Body Skin is left out when it can't be computed, as before SAM 3 is installed, rather than failing the preset.

## Format and interoperability

- **`pointColor`,** a list of swatches on the recipe and on each mask: an `id`, the `color` (OKLCh `lightness`, `chroma` and `hue`, or `"mask"`), `picked` (a Color Range sample: where it was picked, when it was), and `values`, its settings under `pointColor.…` keys. Those settings are parameters scoped to the selected swatch, as `local.…` ones are to the selected mask, so the panel's slider rows, the command palette and the regression catalogue handle them as they do the others. Older Redlamps keep the key, as they keep recipe and mask keys they don't know, and don't render it, as with any newer setting. No new format or process version: edits without Point Color render, and are written, as they were (`SidecarGoldenTests`). `sidecar-format.md` and the schema describe it (`SidecarSchemaTests`).
- **Copy Settings:** a Point Color item in the Color Mixer group; masks carry their own swatches.
- **Lightroom presets:** their `PointColors` are ignored today. They map once Lightroom's fields are known, from a preset with Point Color and Variance set (asked of the owner).

## Steps

1. `model`: swatches in `RedlampEngineAPI` (recipe and mask), the format and schema, and Copy Settings, with tests.
2. `kernel`: the stage, the push-apart limit and Visualize Range, with unit and render tests.
3. `probe`: the render of Point Color's input and the eyedropper's sample.
4. `panel`: the Color Mixer's Point Color mode and its harness specimen.
5. `masks`: swatches in masks (the GPU layout and the mask panel), the mask's own colour, and the Even Skin Tone preset.
6. `tune`: the prototype and the engine on more portraits, for the preset's values and the default range; the preview against a downscaled export; a performance run after merging.
7. `docs`: the README, the comparison, the tracker and the sidecar format; the Lightroom preset mapping when its fields are known; the command palette's Point Color sliders and the Delete key.

## Testing

- **Arithmetic:** nothing changes at the defaults; uniformity 100 takes the fully selected colours to the swatch's; colours stay in order along hue, chroma and lightness ramps for every slider value, the push-apart limit included; hue wraps at 0° and 360°; greys stay grey.
- **Renders:** on a synthetic chart with skin-like patches, colours in the range move towards the swatch and colours outside it don't; a mask's swatch acts only under the mask; golden renders for Point Color edits.
- **Stability:** edits without Point Color render exactly as before (`ProcessStabilityTests`).
- **Format:** round trips, unknown keys inside a swatch kept, and the schema.
- **The app:** the end-to-end suite's contract (ARC-07, ARC-08) claims Point Color's sliders and eyedropper in a scenario (`develop.point-color`: a click on the canvas adds the swatch), and Point Color in masks in another (`masking.point-color`); `masking.presets` applies Even Skin Tone with the other built-in presets. The feedback catalogue lists Point Color as a feature of Develop and of Masking.

## Gates

- Performance-sensitive: the develop kernel's per-pixel work and the two renders of Point Color's input; recorded after merging.

## Open questions

- **Lightroom's semantics:** what its ranges and Variance do on each axis isn't checked against Adobe's pages or measured.
