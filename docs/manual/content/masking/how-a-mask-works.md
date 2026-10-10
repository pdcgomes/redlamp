+++
deck = "A mask is a layer of its own: a set of adjustments, and a shape built from components that says where they apply."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (MaskLayer, MaskComponent, MaskOperation, MaskKind)",
  "`packages/RedlampUI/Sources/Inspector/MasksPanel.swift` (the header, the picker, messages, Add, Subtract and Intersect)",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift` (the list, the selected mask, its components)",
  "`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift`",
  "`packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift`",
  "`docs/lightroom-comparison.md`: Masking",
]
+++

The Edit panels change the whole photo. A mask changes only part of it: you make the mask, move its sliders, and the change appears only where the mask covers. A photo can hold up to 16 masks, and each keeps its own adjustments, so a sky, a face and a foreground can each be edited on their own.

## Open the Masking tool

Press [[⇧W]], or click Masking at the right of the tool strip under the histogram. Click it again, or press [[D]], to go back to Edit. Each mask that you draw has a key of its own, [[M]], [[⇧M]], [[K]], [[⇧J]], [[⇧Q]] and [[⇧Z]], and pressing one opens the tool and starts that mask at once. [[Esc]] finishes the mask you're drawing; a second [[Esc]] leaves the tool.

{{figure: masks-panel}}

Every mask starts in one picker. Before a photo has any masks it takes the list's place, titled New Mask, with a tile for each kind of mask in three groups: AI, DRAWN and RANGE. Once there are masks, New Mask at the top of the panel opens the same picker beside it. A tile is dimmed when its mask can't be made for this photo, and its tooltip says so.

The panel keeps the same order, top to bottom:

The header
: Masks, then New Mask, Mask Presets, the overlay's switch and its options, Pins, and a menu of commands for every mask. They stay where they are however long the list grows.

The armed tool
: While you draw, brush or sample, a strip under the header names what each click or drag does, with Done to finish, or Cancel before anything is made.

Messages
: Progress, a model's download question and anything that went wrong appear at the top of the list, where the mask they concern will be.

The list
: Your masks, newest first, each with a picture of what it covers; see [](#masking.manage).

The selected mask
: Its name with Invert and Reset, its Amount, its components, the selected component's own settings, then its adjustments.

## Make a mask

1. Press [[⇧W]] to open the Masking tool.
2. Click Subject in the picker. Redlamp finds the photo's main subject, names the mask Subject and shows what it covers in red.
3. Drag Exposure, Clarity or any other slider in the mask's settings. The red overlay steps aside while you drag, so you see the change itself.
4. Press [[O]] to hide or show the overlay, and [[D]] to go back to Edit.

Every change is a step in History, as it is in the Edit panels, so [[⌘Z]] undoes it.

## Components, and how they combine

A mask's shape is made of one or more **components**, listed under COMPONENTS, APPLIED TOP TO BOTTOM: a gradient, a brush, a colour range, a subject Redlamp found, and so on. The first component sets the shape. Each one after it changes the shape in one of three ways, chosen with the three buttons under the components:

Add
: The mask also covers what the new component covers.

Subtract
: The new component takes away from the mask.

Intersect
: The mask keeps only what it already covers and the new component covers too.

Each button opens the picker, titled for what it does, as in Subtract from Sky, so you choose the kind of component and how it combines in one go. The icon at the left of a component's row shows which way it combines; click it to choose Set to Add, Set to Subtract or Set to Intersect instead. The pointer over a component's row shows what that component alone covers on the photo.

{{figure: combine}}

Components combine in order, from the top of the list down, so their order can change what the mask covers. Drag a component's row onto another to move it. Masks are different: they add up whatever their order, so dragging one in the list of masks changes only the list.

The button at the end of a component's row has Delete, and for an AI mask Refine Edges and Refine Edge Brush, described under [](#masking.ai.edges). Right-click the row for the three ways to combine and, for an AI mask, the same two refinements. Deleting a mask's last component deletes the mask.

### Invert

Each component has an **Invert** checkbox, which makes it cover everything outside its shape: tick it on a radial gradient around a face to edit everything but the face.

To invert a whole mask, tick **Invert** beside its name at the top of its settings, or choose Invert from its menu in the list of masks. The mask then covers everything its components leave out, however many there are. Duplicate and Invert, in the same menu, makes an inverted copy and leaves the original as it is.

::: note
A mask's Invert is kept with the edit. An earlier Redlamp keeps it too, but draws the mask uninverted.
:::

### Use one mask inside another

The picker that Add, Subtract and Intersect open lists your other masks at its foot, under EXISTING MASK. Choosing one uses that mask's shape as a component: take a sky you've already refined out of a gradient, for example, or keep a colour range inside a person. A mask can't use itself, and a mask used this way brings only its own components, not any masks it uses in turn.

::: lightroom
Lightroom can start a new mask from an existing one. Redlamp can also add, subtract or intersect one mask inside another, and keeps the two linked: change the sky mask and the gradient that uses it changes with it. Delete the sky mask and that component covers nothing.
:::

## The mask's own sliders: Amount and Detail

A mask's settings are headed by its name, with Invert and a Reset button beside it, and Amount directly under them. Detail comes after the components and the selected component's settings, at the head of the adjustments. Both act on the mask as a whole:

{{table: sliders maskAmount maskDetail}}

Amount
: Scales every adjustment of the mask together. At 100 they apply as you set them; at 50, half as strongly; at 200, twice. Lower it to make a finished mask subtler without moving each slider.

Detail
: Keeps only the textured parts of the mask, above 0, or only its flat parts, below 0. Raise it to keep sharpening off a smooth sky; lower it to smooth skin without softening eyelashes and hair. At 0 the mask is left as its components make it.

::: lightroom
Lightroom's masks have no Detail slider. A mask's Amount is Lightroom's, from 0 to 200.
:::

## Limits

- A photo holds up to 16 masks. Making a 17th makes nothing, and the panel says A photo can have up to 16 masks: delete one to make another.
- A Color Range component holds up to five colour samples: see [](#masking.ranges).
- A mask with no components left is deleted: deleting a mask's last component deletes the mask.
