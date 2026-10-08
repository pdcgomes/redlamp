+++
deck = "Name, hide, reorder and reuse masks; choose how the overlay shows them; and keep the masks you make often as presets."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`",
  "`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift`",
  "`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift`, `EditorModel+MaskPresets.swift`, `EditorModel+Shortcuts.swift`",
  "`packages/RedlampEngineAPI/Sources/Rendering.swift` (MaskOverlayStyle), `MaskPresets.swift`",
]
+++

The list at the top of the Masks panel holds the photo's masks, newest at the top. Each row shows the icon of the mask's first component, its name, and an eye that hides the mask or shows it again. A hidden mask stays in the edit, with its name dimmed, but changes nothing.

## The list of masks

Click a mask to select it and see its components and sliders. Double-click its name to rename it. Drag a mask onto another to reorder the list; since masks add up, the order doesn't change the photo. New masks are called Mask 1, Mask 2 and so on, and AI masks are named after what they found.

Right-click a mask for:

Rename…
: Edit its name in place.

Duplicate
: A copy with the same components and adjustments, named after the original with Copy at the end.

Duplicate and Invert
: A copy with every component inverted.

Reset Adjustments
: Set its adjustments back to their defaults, keeping its shape.

Save as Mask Preset
: Keep it as a preset under its current name; see [](#masking.manage.mask-presets).

Delete
: Remove it. The menu item names the mask, as in Delete Sky; [[⌫]] deletes the selected mask too.

The … menu at the end of the row of buttons under the list has Update AI Masks, described under [](#masking.ai.ai-masks-stay-where-they-are); Update AI Masks on 6 Photos (or however many) while several photos are selected; and Delete All Masks.

## Pins

Every mask but the selected one shows as a white pin on the photo, at the centre of its first component; click a pin to select its mask. The selected mask shows its components' handles and pins instead, and dragging a pin moves its component. Press [[H]] to hide the pins and handles, so you can see the photo, and again to show them.

## The overlay

Show Overlay, at the top of the panel, shows what the selected mask covers, in red at 55% to start; [[O]] does the same. Only the selected mask is shown. The overlay steps aside while you drag one of the mask's adjustments, and while you look at Before. It also steps aside when you choose a tool to make a new mask, so you see only what the new mask selects, and shows the new mask once your first click or stroke has made it. The button beside Show Overlay chooses how the overlay looks, with three settings:

Mode
: One of six ways of showing the mask, in the table below.

Color
: Red, Green, Blue or White. [[⇧O]] steps through them.

Opacity
: How strongly the colour tints the photo.

| Mode | What you see |
| --- | --- |
| Color Overlay | The colour over what the mask covers, on the photo |
| Color Overlay on B&W | The colour over what the mask covers, on a black-and-white photo |
| Image on Black | The photo where the mask covers, black elsewhere |
| Image on White | The photo where the mask covers, white elsewhere |
| B&W | The mask itself: white where it covers, black where it doesn't |
| Image on B&W | The photo in colour where the mask covers, in black and white elsewhere |

Color and Opacity apply only to the two Color Overlay modes; in the others they're dimmed. While you shape a Luminance Range, Show Luminance Map replaces the mode with a map of the photo's lightness.

::: tip
Image on Black shows a soft edge for what it is. Use it to check the edge of a Subject or Sky mask before you add an effect that would make a halo obvious.
:::

## Mask presets

Presets, beside Create New Mask, lists Redlamp's presets and then yours. Each preset makes a mask and sets its adjustments; the AI masks in it are found again for the photo it's applied to. A preset is dimmed when the photo can't make its mask. The mask it makes is an ordinary mask, named after the preset, so change anything you like.

| Preset | Mask | Adjustments |
| --- | --- | --- |
| Blue Sky | Sky | Temp −12, Exposure −0.30, Highlights −25, Saturation +15 |
| Brighten Subject | Subject | Exposure +0.35, Shadows +15, Clarity +8 |
| Darken Background | Background | Exposure −0.50, Saturation −15 |
| Smooth Skin | People › Face Skin | Texture −35, Clarity −10 |
| Whiten Teeth | People › Teeth | Exposure +0.25, Saturation −45 |
| Pop Eyes | People › Iris and Pupil | Exposure +0.30, Clarity +20, Saturation +15 |
| Brighten Snow | Landscape › Snow | Exposure +0.35, Whites +15, Temp −4, Clarity +5 |
| Enhance Vegetation | Landscape › Vegetation | Saturation +12, Texture +10, Shadows +10 |

### Save your own

Right-click a mask in the list and choose Save as Mask Preset. The preset takes the mask's name, so rename the mask first; a preset with the same name is replaced. Everything is kept but brush strokes, which belong to one photo: gradients and ranges are kept as they are, and AI masks are found again on each photo the preset is applied to. To delete one of your presets, use Delete Preset at the bottom of the Presets menu.

::: note
Your presets are kept in Redlamp's settings on this Mac, not as files, so they don't travel with your photos.
:::
