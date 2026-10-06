+++
deck = "A mask is a layer of its own: a set of adjustments, and a shape built from components that says where they apply."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (MaskLayer, MaskComponent, MaskOperation, MaskKind)",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`",
  "`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift`",
  "`packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift`",
  "`docs/lightroom-comparison.md`: Masking",
]
+++

The Edit panels change the whole photo. A mask changes only part of it: you make the mask, move its sliders, and the change appears only where the mask covers. A photo can hold up to 16 masks, and each keeps its own adjustments, so a sky, a face and a foreground can each be edited on their own.

## Open the Masking tool

Press [[⇧W]], or click Masking at the right of the tool strip under the histogram. Click it again, or press [[D]], to go back to Edit. Each mask that you draw has a key of its own, [[M]], [[⇧M]], [[K]], [[⇧J]], [[⇧Q]] and [[⇧Z]], and pressing one opens the tool and starts that mask at once. [[Esc]] finishes the mask you're drawing; a second [[Esc]] leaves the tool.

Before a photo has any masks, the panel shows a grid of tiles under CREATE NEW MASK, one for each kind of mask. Once there are masks, the same kinds are in the Create New Mask menu under the list of masks.

{{figure: masks-panel}}

## Make a mask

1. Press [[⇧W]] to open the Masking tool.
2. Click Subject in the grid. Redlamp finds the photo's main subject, names the mask Subject and shows what it covers in red.
3. Drag Exposure, Clarity or any other slider in the mask's section. The red overlay steps aside while you drag, so you see the change itself.
4. Press [[O]] to hide or show the overlay, and [[D]] to go back to Edit.

Every change is a step in History, as it is in the Edit panels, so [[⌘Z]] undoes it.

## Components, and how they combine

A mask's shape is made of one or more **components**, listed under COMPONENTS: a gradient, a brush, a colour range, a subject Redlamp found, and so on. The first component sets the shape. Each one after it changes the shape in one of three ways, chosen with the three buttons under the list:

Add
: The mask also covers what the new component covers.

Subtract
: The new component takes away from the mask.

Intersect
: The mask keeps only what it already covers and the new component covers too.

Each button opens the whole list of mask kinds, so you choose the kind of component and how it combines in one go. The icon at the left of a component's row shows which way it combines. To change it later, right-click the row and choose Set to Add, Set to Subtract or Set to Intersect.

{{figure: combine}}

Components combine in order, from the top of the list down, so their order can change what the mask covers. Drag a component's row onto another to move it. Masks are different: they add up whatever their order, so dragging one in the list of masks changes only the list.

### Invert

Each component has an **Invert** checkbox, which makes it cover everything outside its shape: tick it on a radial gradient around a face to edit everything but the face. To invert a whole mask, right-click it in the list of masks and choose Duplicate and Invert. The copy has every one of its components inverted, which, for a mask of one component, is everything the original leaves out.

### Use one mask inside another

Add, Subtract and Intersect also list your other masks, under Existing Mask. Choosing one uses that mask's shape as a component: take a sky you've already refined out of a gradient, for example, or keep a colour range inside a person. A mask can't use itself, and a mask used this way brings only its own components, not any masks it uses in turn.

::: lightroom
Lightroom can start a new mask from an existing one. Redlamp can also add, subtract or intersect one mask inside another, and keeps the two linked: change the sky mask and the gradient that uses it changes with it. Delete the sky mask and that component covers nothing.
:::

## The mask's own sliders: Amount and Detail

Below the components, the mask's section is headed by its name, with a Reset button beside it. Its first two sliders act on the mask as a whole:

{{table: sliders maskAmount maskDetail}}

Amount
: Scales every adjustment of the mask together. At 100 they apply as you set them; at 50, half as strongly; at 200, twice. Lower it to make a finished mask subtler without moving each slider.

Detail
: Keeps only the textured parts of the mask, above 0, or only its flat parts, below 0. Raise it to keep sharpening off a smooth sky; lower it to smooth skin without softening eyelashes and hair. At 0 the mask is left as its components make it.

::: lightroom
Lightroom's masks have no Detail slider. A mask's Amount is Lightroom's, from 0 to 200.
:::

## Limits

- A photo holds up to 16 masks.
- A Color Range component holds up to five colour samples: see [](#masking.ranges).
- A mask with no components left is deleted: deleting a mask's last component deletes the mask.
