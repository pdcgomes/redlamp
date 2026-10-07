+++
deck = "Each mask has its own sliders, from Temp to Bloom, plus a colour tint and curves. They start at zero and apply only where the mask covers."
sources = [
  "`README.md`: Masking; Using Redlamp, slider gestures",
  "`packages/RedlampEngineAPI/Sources/ParameterID.swift` (localParameters), `ParameterSpec.swift`",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`",
  "`packages/RedlampUI/Sources/Model/EditorModel.swift`, `EditorModel+Shortcuts.swift`",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (MaskCurves, resetAdjustments)",
]
+++

Below Amount and Detail, a mask's section lists its own adjustments: the Edit panels' controls, as Lightroom's masks have them. They all start at 0, so a new mask changes nothing until you move one, and each acts only where the mask covers, in proportion to how much it covers.

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

## Working with the sliders

- They take the same gestures as every slider: double-click a label or thumb to reset it, [[⇧]]-drag for fine control, click a value to type a new one or drag it to scrub it ([[⇧]] for fine control), and use the arrow keys to step it ([[⇧]] steps by ten).
- With the Masking tool open, [[,]] and [[.]] select the previous and next of the mask's sliders, and [[-]] and [[=]] move the selected one ([[⇧]] for larger steps).
- The overlay steps aside while you drag an adjustment or Amount, and comes back when you let go. Sliders that shape the mask itself, such as Feather, Detail and Refine, keep it showing.
- Reset, beside the mask's name, sets every adjustment back to 0, straightens the curves, and returns Amount to 100 and Detail to 0. It leaves the components as they are. Reset Adjustments in the list of masks does the same.

::: lightroom
The sliders are Lightroom's, in Lightroom's order. Halation and Bloom have no Lightroom equivalent; they go with Redlamp's film effects.
:::
