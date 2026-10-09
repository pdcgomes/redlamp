+++
deck = "Each mask has its own sliders, from Temp to Bloom, plus a colour tint and curves. They start at zero and apply only where the mask covers."
sources = [
  "`README.md`: Masking; Using Redlamp, slider gestures",
  "`packages/RedlampEngineAPI/Sources/ParameterID.swift` (localParameters), `ParameterSpec.swift`",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift` (SelectedMaskEditor, MaskColorSwatch, MaskCurvesEditor, ResetMaskButton)",
  "`packages/RedlampUI/Sources/Inspector/PointColorControls.swift` (MaskPointColor, PointColorSwatches, PointColorVisualizeToggle); `packages/RedlampEngineAPI/Sources/MaskPresets.swift` (Even Skin Tone)",
  "`packages/RedlampUI/Sources/Model/EditorModel.swift`, `EditorModel+Shortcuts.swift`",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (MaskCurves, resetAdjustments)",
]
+++

Below Detail, a mask's settings list its own adjustments: the Edit panels' controls, as Lightroom's masks have them. They all start at 0, so a new mask changes nothing until you move one, and each acts only where the mask covers, in proportion to how much it covers.

{{figure: mask-adjustments}}

## The sliders

{{table: sliders localTemperature localTint localExposure localContrast localHighlights localShadows localWhites localBlacks localTexture localClarity localDehaze localHue localSaturation localSharpness localNoise localMoire localDefringe localHalation localBloom}}

Most do what their namesakes in the Edit panels do, on part of the photo. A few differ:

Temp and Tint
: Warm or cool, and shift towards green or magenta, from −100 to 100, rather than setting a colour temperature in kelvins as White Balance does.

Exposure
: Runs from −4 to +4 stops. The Edit panel's runs to 5 either way.

Hue
: Turns every hue the mask covers by up to 180 degrees either way.

Moiré and Defringe
: Clean up the coloured patterns of moiré, and coloured fringes along high-contrast edges, in one part of the photo.

Halation and Bloom
: Strengthen or weaken the Effects panel's film glows where the mask covers. How far each glow spreads stays as Effects sets it.

## Color

The Color row's swatch tints what the mask covers. Click it for a colour wheel, with Color Hue and Color Saturation sliders beneath. At a saturation of 0 there's no tint, and the swatch shows a line through it.

{{table: sliders localColorHue localColorSaturation}}

## Curve

A point curve for RGB, Red, Green and Blue, chosen above the graph, working on the photo as the Tone Curve panel's point curve does but only where the mask covers. The button beside the channels straightens all four curves; it's dimmed while they're straight.

## Point Color

The last of a mask's settings is Point Color: a swatch for each colour to change, up to eight, and its sliders, acting only where the mask covers.

1. Click the eyedropper, then a colour on the photo, to add a swatch for it. Or click the button beside it to add a swatch of the mask's own colour, the median of the colours under it, found again for each photo.
2. Click a swatch to edit it; the trash button deletes the selected one.
3. Move its sliders, in three groups, each with Hue, Saturation and Luminance:

Shift
: Moves the swatch's colours, from −100 to 100.

Uniformity
: Above 0 pulls the colours in the swatch's range towards its colour; below 0 pushes them apart. From −100 to 100.

Range
: How far from the swatch a colour may be and still change, from 0 to 100, 50 to start, with Smoothness for how gently the change fades out.

Tick Visualize Range to see what the selected swatch selects in colour, and the rest of the photo in grey. The Even Skin Tone preset makes a skin mask with a swatch of the skin's own colour and its Uniformity raised: see [](#masking.manage.mask-presets).

## Working with the sliders

- They take the same gestures as every slider: double-click a label or thumb to reset it, [[⇧]]-drag for fine control, click a value to type a new one or drag it to scrub it ([[⇧]] for fine control), and use the arrow keys to step it ([[⇧]] steps by ten).
- With the Masking tool open, [[,]] and [[.]] select the previous and next of the mask's sliders, and [[-]] and [[=]] move the selected one ([[⇧]] for larger steps).
- The overlay steps aside while you drag an adjustment or Amount, and comes back when you let go. Sliders that shape the mask itself, such as Feather, Detail and Refine, keep it showing.
- Reset, beside the mask's name at the top of its settings, sets every adjustment back to 0, straightens the curves, removes its Point Color swatches, and returns Amount to 100 and Detail to 0. It leaves the components as they are. Reset Adjustments, in the mask's menu in the list, does the same.

::: lightroom
The sliders are Lightroom's, in Lightroom's order. Halation and Bloom have no Lightroom equivalent; they go with Redlamp's film effects.
:::
