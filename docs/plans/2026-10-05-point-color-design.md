# Point Color with uniformity: design (TON-29)

Lightroom's Point Color, with Capture One's uniformity: pick a colour on the photo, shift it and the colours near it, and pull those colours together, so blotchy skin evens out to one tone. It works on the whole photo and inside masks, and an Even Skin Tone mask preset does it for skin in one step. Tracker: TON-29 (#181); it waits on TON-31 (#190), where the colour controls sit, and TON-30 (#182), the spatial version, follows it. The research, sources and a prototype's measurements are in [the note](../research/notes/TON-29-colour-uniformity.md).

**Status (2026-10-05):** proposed, waiting on the owner's approval. Building starts after TON-31's comparison.

## Decisions (the owner)

- **Phase 2** (2026-10-04): Point Color is Develop parity.
- **TON-30 waits** until TON-29 has shipped (2026-10-04).
- **TON-31 first** (2026-10-05): the comparison of the colour controls before and after the tone curve runs before Point Color is built, so Point Color goes where they end up.

## A swatch

Up to 8 swatches on the edit, and up to 8 on each mask. Each has:

- **A colour,** in OKLCh. Either picked with the eyedropper (then where it was picked is kept, so the panel can show it) or, on a mask, **the mask's own colour** (below).
- **A range:** how far in hue, saturation (chroma) and luminance (lightness) a colour can be from the swatch's and still be selected, and Smoothness, how gradually the selection fades out at the range's edge.
- **Shift:** Hue, Saturation and Luminance, −100 to 100, scaled as the Color Mixer's sliders until EDT-11 fits them against Lightroom's.
- **Uniformity:** Hue, Saturation and Luminance, −100 to 100. Above 0, the colours in the range move towards the swatch's colour on that axis; at 100, all the way where the range selects fully. Below 0 they move apart (Lightroom's Variance raised), up to a limit that keeps the colours in order. Lightroom's Variance is the negative of a uniformity.

The swatch stores a colour, not a place on the photo, so it means the same in presets, in Copy Settings and Sync, and in Lightroom's presets. Like the Color Mixer's bands, it stays put when white balance or exposure change afterwards.

## The arithmetic

In the develop kernel, right after the Color Mixer. Today that's after the tone curve and the Base Look, in OKLCh; if TON-31 moves the Color Mixer before the tone curve, Point Color moves with it, and its lightness range is set on scene-referred lightness.

- **The weight** is the product of three trapezoids around the swatch's colour, one per axis, with smooth edges (as the Luminance Range mask's), hue measured on the circle. It is multiplied by the pixel's colourfulness, as the Color Mixer's shifts are, since hue means little near grey.
- **The pull** works on each axis's distance from the swatch: hue as the shorter arc, chroma as a ratio, lightness as a difference. A uniformity `u` above 0 scales the distance by `1 − u·w`, where `w` is the weight. Since `w` falls away from the swatch's colour, the mapping's slope, `1 − u·(w + d·w′)`, is at least `1 − u`: colours never change order.
- **Pushing apart** scales the distance by `1 + k·w`. Where the weight falls steeply, the slope `1 + k·(w + d·w′)` can turn negative, so colours would cross and the range's edge would band. For each swatch's range, the engine works out the largest `k` that keeps the slope at least 0.25 everywhere, and −100 maps to it.
- **Shift** then moves the selected colours by the shift times `w`.
- **Several swatches:** each one's change is worked out from the same input colour, and the changes add up, as the Color Mixer's bands blend. A mask's swatches come after the edit's own, scaled by the mask's coverage and Amount, like its other adjustments.
- **Cost:** a few dozen arithmetic operations per active swatch per pixel; swatches at their defaults are skipped.

## The swatch's colour

- **Picking.** The eyedropper works like Color Range's (a click, or a drag for a larger disc). It reads the colour that Point Color receives there, averaged over the disc. That needs its own sample: the edit guide holds the edit's final colours, Point Color's own effect included. A one-off render of Point Color's input, at the guide's size (2048 px), is read as `sampleEditGuide` reads the edit guide.
- **The mask's own colour,** for a swatch on a mask: the median of Point Color's input under the mask. It comes from a small render of Point Color's input with the edit's masks (512 px, about a quarter of a megapixel), made again when anything before Point Color, the mask or the photo changes, and handed to the develop pass in a small buffer. It follows the photo's white balance, and works on every photo the mask is pasted to: AI masks are recomputed for each photo, and so is their colour.
- **Visualize Range,** as in Lightroom: the develop kernel shows the selected swatch's selection, colour where it selects and grey elsewhere, as Visualize Spots draws its own view.

## The panel

- **The Color Mixer panel** gains Point Color beside HSL and Color in its picker, as Lightroom's Color Mixer has Point Color. It shows the swatches (the eyedropper adds one; click selects; Delete removes), then Shift, Uniformity and Range for the selected swatch, and Visualize Range.
- **The mask panel** gets the same section, with the mask's own colour as a choice for a swatch's colour.
- **The command palette** finds Point Color and its sliders, which act on the selected swatch.
- **The component harness** gets a Point Color specimen beside the Color Mixer's.

## The Even Skin Tone preset

- **Components:** People's Face Skin, plus Body Skin when SAM 3 is installed (Face Skin alone otherwise).
- **One swatch** with the mask's own colour; range: hue fully within 20° and none past 45°, all but near-greys, deep shadows and speculars; uniformity: Hue 50, Saturation 35, Luminance 0. Luminance stays at 0: in the prototype, uniformity on lightness took a third of the face's shading and 42% of its pore-scale texture. These are starting values, to tune in step 6.
- `MaskPreset` gains swatches.

## Format and interoperability

- **`pointColor`,** a list of swatches on the recipe and on each mask: an `id`, the `color` (OKLCh `L`, `C`, `h`, or `"mask"`), `picked` (where it was picked from, when it was), and `range`, `shift` and `uniformity` (numbers only). Older Redlamps keep the key, as they keep recipe and mask keys they don't know, and don't render it, as with any newer setting. No new format or process version: edits without Point Color render as they did. `sidecar-format.md` and the schema describe it (`SidecarSchemaTests`).
- **Copy Settings:** a Point Color item in the Color Mixer group; masks carry their own swatches.
- **Lightroom presets:** their `PointColors` are ignored today. They map once Lightroom's fields are known, from a preset with Point Color and Variance set (asked of the owner).

## Steps

1. `model`: swatches in `RedlampEngineAPI` (recipe and mask), the format and schema, and Copy Settings, with tests.
2. `kernel`: the stage, the push-apart limit and Visualize Range, with unit and render tests.
3. `probe`: the render of Point Color's input, the eyedropper's sample, and the mask's own colour.
4. `panel`: the Color Mixer's Point Color mode and its harness specimen.
5. `masks`: swatches in masks (the GPU layout and the mask panel), and the Even Skin Tone preset.
6. `tune`: the prototype and the engine on more portraits, for the preset's values and the default range; the preview against a downscaled export; a performance run after merging.
7. `docs`: the README, the comparison, the tracker and the sidecar format; the Lightroom preset mapping when its fields are known.

## Testing

- **Arithmetic:** nothing changes at the defaults; uniformity 100 takes the fully selected colours to the swatch's; colours stay in order along hue, chroma and lightness ramps for every slider value, the push-apart limit included; hue wraps at 0° and 360°; greys stay grey.
- **Renders:** on a synthetic chart with skin-like patches, colours in the range move towards the swatch and colours outside it don't; a mask's swatch acts only under the mask; golden renders for Point Color edits.
- **Stability:** edits without Point Color render exactly as before (`ProcessStabilityTests`).
- **Format:** round trips, unknown keys inside a swatch kept, and the schema.
- **The app:** the end-to-end suite's contract (ARC-07, ARC-08) claims Point Color's mode, sliders and eyedropper in a scenario, and the feedback catalogue lists Point Color as a feature of the Color Mixer area.

## Gates

- Building waits on TON-31's comparison.
- Performance-sensitive: the develop kernel's per-pixel work and the two renders of Point Color's input; recorded after merging.

## Open questions

- **Controls:** three Uniformity sliders (proposed here), or Lightroom's single Variance, or both with Variance driving all three.
- **Swatches:** 8 on the edit and 8 per mask, or fewer.
- **Lightroom's semantics:** what its ranges and Variance do on each axis isn't checked against Adobe's pages or measured.
