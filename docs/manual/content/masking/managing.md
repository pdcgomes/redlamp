+++
deck = "Name, hide, reorder and reuse masks; see what each one covers; choose how the overlay shows them; and keep the masks you make often as presets."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampUI/Sources/Inspector/MasksPanel.swift` (the header, MaskThumbnail)",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift` (MaskList, MaskOverlayOptions, MaskPresetsMenu, MaskActionsMenu)",
  "`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift`",
  "`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift`, `EditorModel+MaskPresets.swift`, `EditorModel+MaskThumbnails.swift`, `EditorModel+Shortcuts.swift`",
  "`packages/RedlampUI/Sources/Model/SettingsSync.swift`, `EditorModel+Sync.swift`; `packages/RedlampUI/Sources/Filmstrip/FilmstripView.swift` (presets on several photos)",
  "`packages/RedlampEngineAPI/Sources/Rendering.swift` (MaskOverlayStyle), `MaskPresets.swift`",
]
+++

The list at the top of the Masks panel holds the photo's masks, newest at the top. Each row shows a picture of what the mask covers, white on black in the photo's shape, then its name and an eye that hides the mask or shows it again. A hidden mask stays in the edit, with its name dimmed, but changes nothing.

Move the pointer over a row and the photo shows what that mask covers, in the overlay's colour and mode, even while the overlay is off. So does the pointer over a component's row, for that component alone, and over a pin.

## The list of masks

Click a mask to select it and see its settings. Double-click its name to rename it. Drag a mask onto another to reorder the list; since masks add up, the order doesn't change the photo. New masks are called Mask 1, Mask 2 and so on, and AI masks are named after what they found.

The selected row, and the row under the pointer, has a menu button at its end. Right-clicking any row opens the same menu:

Rename…
: Edit its name in place.

Invert
: Invert the whole mask; the item is ticked while it's inverted.

Duplicate
: A copy with the same components and adjustments, named after the original with Copy at the end.

Duplicate and Invert
: The same copy, inverted as a whole.

Reset Adjustments
: Set its adjustments back to their defaults, keeping its shape.

Save as Mask Preset…
: Keep it as a preset; see [](#masking.manage.mask-presets).

Delete
: Remove it. The item names the mask, as in Delete Sky; [[⌫]] deletes the selected mask too.

The menu at the right of the panel's header, after Pins, has Update AI Masks, described under [](#masking.ai.ai-masks-stay-where-they-are); Update AI Masks on 6 Photos (or however many) while several photos are selected; and Delete All Masks.

## Show one mask alone

[[⌥]]-click a mask's eye to show that mask alone, hiding the others, and [[⌥]]-click it again to show them all. Each is one step in History, Show Only Sky and Show All Masks, and since showing and hiding are part of the edit, an export matches what you see. A plain click on the eye hides or shows only that mask.

## Pins

Every mask but the selected one shows as a white pin on the photo, inside the mask where it covers most, so a crescent's or a ring's pin sits on the shape rather than in its middle. Until Redlamp has drawn the mask's picture, the pin sits at its first component's centre. The pointer over a pin shows that mask on the photo, and its tooltip names it; click the pin to select its mask.

The selected mask shows its components' handles and pins instead, and dragging a pin moves its component. Press [[H]], or click Pins in the panel's header, to hide the pins and handles so you can see the photo, and again to show them.

## The overlay

The overlay's switch, the half-filled circle at the top of the panel, shows what the selected mask covers, in red at 55% to start; [[O]] does the same. The overlay steps aside while you drag one of the mask's adjustments, and while you look at Before. It also steps aside when you choose a tool to make a new mask, so you see only what the new mask selects, and shows the new mask once your first click or stroke has made it.

The button beside the switch, Overlay Options, opens three settings:

Mode
: One of six ways of showing the mask, in the table below.

Color
: Red, Green, Blue or White. [[⇧O]] steps through them.

Opacity
: How strongly the colour tints the photo, from 0 to 100%. Drag the slider, or drag or type the value beside it.

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

Mask Presets, the wand at the top of the panel, lists Redlamp's presets and then yours. Each preset makes a mask and sets its adjustments; the AI masks in it are found again for the photo it's applied to. A preset is dimmed when the photo can't make its mask. The mask it makes is an ordinary mask, named after the preset, so change anything you like.

| Preset | Mask | Adjustments |
| --- | --- | --- |
| Blue Sky | Sky | Temp −12, Exposure −0.30, Highlights −25, Saturation +15 |
| Brighten Subject | Subject | Exposure +0.35, Shadows +15, Clarity +8 |
| Darken Background | Background | Exposure −0.50, Saturation −15 |
| Smooth Skin | People › Face Skin | Texture −35, Clarity −10 |
| Even Skin Tone | People › Face Skin and Body Skin | A Point Color swatch of the skin's own colour, pulling its hues and saturations together |
| Whiten Teeth | People › Teeth | Exposure +0.25, Saturation −45 |
| Pop Eyes | People › Iris and Pupil | Exposure +0.30, Clarity +20, Saturation +15 |
| Brighten Snow | Landscape › Snow | Exposure +0.35, Whites +15, Temp −4, Clarity +5 |
| Enhance Vegetation | Landscape › Vegetation | Saturation +12, Texture +10, Shadows +10 |

Even Skin Tone leaves the skin's lightness alone, which keeps a face's shading and texture. Its Body Skin needs SAM 3; without it, the preset evens the face alone.

### On several photos

With several photos selected in the filmstrip, the presets sit under Apply to 5 Selected Photos, with your count, and a preset goes to every one of them. The open photo gets it as a step of its history. The others get it in the background, one at a time, each with its AI masks found for that photo, while the filmstrip shows how far it has gone, as in Apply Blue Sky: 2 of 5, with Cancel beside it.

A photo the preset's masks can't be found in, such as a Smooth Skin on a photo with no face, is left as it was, and so is a photo with 16 masks already; the filmstrip says how many were left alone, and why. Undo Sync Settings, in the Photo menu, takes the preset back from the other photos, and Undo from the open one. To apply a preset to the open photo alone, select only that photo.

### Save your own

Choose Save as Mask Preset… from a mask's menu. Redlamp asks for the preset's name, with the mask's own to start; a preset with the same name is replaced. Everything is kept but brush strokes, which belong to one photo: gradients and ranges are kept as they are, and AI masks are found again on each photo the preset is applied to. To delete one of your presets, use Delete Preset at the bottom of the Mask Presets menu.

::: note
Your presets are kept in Redlamp's settings on this Mac, not as files, so they don't travel with your photos.
:::
