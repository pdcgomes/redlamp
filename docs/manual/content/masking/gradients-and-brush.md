+++
deck = "Three components you draw yourself: a linear gradient for a sky or a foreground, a radial gradient for a face or a pool of light, and a brush for everything else."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift`",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`",
  "`packages/RedlampUI/Sources/Model/BrushSettings.swift`, `EditorModel+Brush.swift`, `EditorModel+BrushSize.swift`",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (LinearMask, RadialMask, BrushStroke)",
  "`packages/RedlampEngineAPI/Sources/ParameterSpec.swift`",
]
+++

Drawn components follow your hand, not the photo. They need no download, they appear the moment you draw them, and they're kept in the edit as shapes and strokes rather than as images, so they stay sharp at any size.

{{figure: gradients}}

## Linear Gradient

Press [[M]], or choose Linear Gradient from Create New Mask, then drag on the photo from where the effect should be full to where it should have faded out. A click without a drag places a gradient that fades over a quarter of the photo's height, downwards from the click.

The gradient is drawn as three lines: a solid line where the effect is full, a dashed line through the middle, and a solid line where it ends. Drag the round handle at either end to move that end, which also turns the gradient; drag the pin in the middle to move the whole gradient. A linear gradient has no settings of its own, so its section shows only the mask's sliders.

### Darken a bright sky

1. Press [[M]] and drag from the top of the sky to just below the horizon.
2. Lower Exposure and Highlights in the mask's section.
3. If the gradient darkens a building or a tree that rises above the horizon, click Intersect and choose Sky: the gradient then darkens only the sky, still fading towards the horizon.

## Radial Gradient

Press [[⇧M]], or choose Radial Gradient, then drag from the centre outwards: the drag sets the width and the height. Hold [[⇧]] to keep it a circle. A click without a drag places an ellipse centred on the click.

The solid ellipse is where the effect ends and the dashed one inside it is where the effect is full. Drag a handle on the solid ellipse to stretch it along that axis, the small handle just outside it to rotate it (its tooltip says Drag to rotate), and the pin in the middle to move it. The effect is inside the ellipse; tick Invert on the component to put it outside, as a vignette around a subject.

{{table: sliders maskFeather}}

Feather
: How much of the radius fades. At 0 the edge is hard; at 100 the effect fades all the way from the centre. Feather moves the dashed ellipse as you drag it.

## Brush

Press [[K]], or choose Brush, and paint on the photo. The brush stays ready until you click Done, and every stroke goes into the same component, so you can paint in as many passes as you like. To paint more into a brush component later, click the brush on its row (Paint into this brush).

### A, B and Erase

The brush's settings start with three brushes: A, B and Erase. Each keeps its own Size, Feather, Flow, Density and Auto Mask, and Redlamp remembers them when you quit, so you can keep a large soft brush and a small precise one. They start out different:

| Brush | Size | Feather | Flow | Density | Auto Mask |
| --- | --- | --- | --- | --- | --- |
| A | 25 | 50 | 100 | 100 | Off |
| B | 8 | 20 | 100 | 100 | Off |
| Erase | 15 | 50 | 100 | 100 | Off |

Hold [[⌥]] while painting to erase with whichever brush you have; let go to paint again. Erasing takes away what earlier strokes of the component painted. A brush component can't start with an erase stroke, since there is nothing yet to erase.

### The brush's sliders

{{table: sliders maskBrushSize maskBrushFeather maskBrushFlow maskBrushDensity}}

Size
: The brush's size, from a few pixels to a radius of a third of the photo's height. The slider is finer at the small end, where precision matters.

Feather
: How much of the brush's radius fades out. At 0 its edge is hard.

Flow
: How much each dab adds. Dabs build up where they overlap, so a low Flow lets you build an effect over several passes.

Density
: The most coverage a stroke can reach, however much it builds up.

Auto Mask
: A checkbox below the sliders. It keeps the brush to colours like the one under its centre, so you can paint along an edge without spilling over it.

### Size and feather as you paint

- <kbd>[</kbd> and <kbd>]</kbd> make the brush smaller and larger, by 15% of its size each press, and with [[⇧]] change its feather by 10.
- [[⌘]]-scroll over the photo changes the size by about 15% a notch, or the feather by 5 a notch with [[⇧]].
- A ring around the pointer shows the brush as it changes: the solid circle is its size and the dashed one where its feather begins, with both values beside it. Erase shows a minus sign in the middle.
- Hold [[Space]] and drag to move the photo without putting the brush down. A press of [[Space]] without a drag toggles the zoom, as it does elsewhere.
- With a pen tablet, each stroke follows the pen's pressure. A mouse paints at full pressure.

::: tip
For a clean edge, paint the inside of the area with a large soft brush, then switch to B and paint along the edge with Auto Mask on.
:::
