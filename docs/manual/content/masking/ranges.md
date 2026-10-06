+++
deck = "Select by what is in the photo rather than where it is: a colour, a band of brightness, or a distance from the camera."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (ColorRangeMask, LuminanceRangeMask, DepthRangeMask)",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`",
  "`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift`",
  "`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift`, `RedlampEngine+Models.swift`",
]
+++

A range mask selects every part of the photo that matches what you sample, wherever it is. Color Range and Luminance Range read the photo as the Edit panels leave it, so their selections follow white balance and exposure as you change them, but not the adjustments of other masks.

Range masks are at their best as a second component. Intersect a colour range with a linear gradient to deepen only the blue of the upper sky, or subtract a luminance range from a brush to leave the brightest highlights alone.

## Color Range

1. Press [[⇧J]], or choose Color Range.
2. Click the colour you want. To take the average of an area instead, drag outwards from its centre: the circle you drag out is the area sampled.
3. [[⇧]]-click to add another colour, up to five in all. Each sample shows on the photo as a white ring while the component is selected.
4. Set Refine: how far a colour may be from the samples and still be selected.
5. Click Done.

{{table: sliders maskColorRefine}}

Below Refine, the panel counts the samples, as in 3 of 5 samples, with Remove Last to take back the most recent one. To start again, click the eyedropper on the component's row (Sample again).

## Luminance Range

Press [[⇧Q]], or choose Luminance Range, and click a tone in the photo: Redlamp selects tones like it, a band 20 wide centred on the one you clicked, fading over 15 on each side. Then shape the band with the four handles on the Luminance Range bar, which runs from black on the left to white on the right:

{{figure: luminance-range}}

The two inner handles, drawn wider, are where the selection is full; the two outer ones are where it has faded out. Drag the inner handles apart to select more tones fully, and the outer ones away from them to soften the transition. The readout with the bar shows where the selection is full, on a scale from 0 to 100.

Tick Show Luminance Map to see the photo as a map of its lightness, in place of the overlay's usual look, while you shape the band.

::: tip
To protect the highlights from a brightening mask, add a Luminance Range on the bright end with Subtract, and widen its outer handle until the transition can't be seen.
:::

## Depth Range

Press [[⇧Z]], or choose Depth Range, to select by distance from the camera. Its bar works as Luminance Range's does, from Far on the left to Near on the right, and starts with the nearer part of the scene selected.

The depth comes from the photo itself when it has a depth map, as many iPhone photos do. For other photos Redlamp estimates it, with Depth Anything 3 if you've downloaded it and otherwise with Depth Anything V2 (small), which it asks to download the first time, as described under [](#masking.ai.downloading-a-model).

::: note
A Depth Range has no Feather or Edge sliders, and no Refine Edges, unlike the other masks Redlamp computes.
:::
