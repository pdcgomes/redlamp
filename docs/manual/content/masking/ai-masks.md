+++
deck = "Let Redlamp find the subject, the sky, people and their features, an object you point at, or a kind of landscape. Every model runs on your Mac."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampEngineAPI/Sources/Masks.swift`",
  "`packages/RedlampUI/Sources/Inspector/MasksPanel.swift`, `PeoplePickerView.swift`, `MaskingPanel.swift`",
  "`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift`, `+PeoplePicker.swift`, `+Objects.swift`, `+EdgeBrush.swift`",
  "`packages/RedlampEngine/Sources/RedlampEngine+Models.swift`; `packages/RedlampMasking/Resources/Models/*.json`",
  "`docs/lightroom-comparison.md`: Masking",
]
+++

AI masks are found by models that run on your Mac; photos are never uploaded. Subject, Background, Sky and most of People use models built into macOS and work straight away. Objects, Landscape, Depth Range and four People parts use models that Redlamp downloads the first time you need one, after showing you its size and asking.

| Mask | Selects | Model | Download |
| --- | --- | --- | --- |
| Subject | The photo's main subject | Built into macOS | None |
| Background | Everything but the subject | Built into macOS | None |
| Sky | The sky, through branches and wires | Built into macOS, and Depth Anything 3 when downloaded | None |
| People | Each person, or one part of each | Built into macOS; SAM 3 for four parts | None, or 988.1 MB |
| Objects | The thing you click, box or brush | Segment Anything 2.1 (tiny) | 79.6 MB |
| Landscape | One kind of landscape, such as Water | SAM 3 | 988.1 MB |
| Depth Range | A band of distance from the camera | The photo's depth map, or Depth Anything V2 (small) | None, or 49.8 MB |

## Make one

Click the mask's tile in the picker, under AI: there is nothing to draw. While the model works, a row at the top of the list says so, as in Finding subject…, and the picker's tiles wait. The mask is named after what was found: Subject, Sky, Teeth, Mountains. When there's nothing to find, the top of the list says that instead, as in No sky was found in this photo, with Report… to send it to Redlamp's developers.

To add an AI mask to a mask you've already made, click Add, Subtract or Intersect under its components and choose it in the picker.

## People

People opens the People picker in the panel, where the list was, so the photo stays clear while you choose:

1. Click People in the picker. Redlamp finds who is in the photo and shows each person, left to right, as a square crop around their face, or around the whole person when no face is found. Someone alone in the photo starts ticked. The pointer over a crop outlines that person on the photo.
2. Click the people to mask, or tick All when there are several.
3. Under PARTS, tick what to mask: Entire Person, Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth, Hair, Facial Hair or Clothes. Entire Person is ticked to start.
4. With more than one person ticked, tick Separate masks, one for each person, to give each a mask of their own.
5. Click Create Mask, or Create 3 Masks (or however many) with Separate masks. Cancel, or [[Esc]], puts the list back.

Each component made names its part and its person, as in Face Skin · Person 2, so you can leave someone out later by deleting their component. Opened from Add, Subtract or Intersect, the picker's title says which, as in People · Subtract from Sky, and its button reads Add, Subtract or Intersect. When nobody is found, the picker says No people were found in this photo.

A part marked SAM 3 needs that model. Ticking it asks to download it, as described under [](#masking.ai.downloading-a-model), and Not Now unticks the part again.

- **Hair** comes from the photo's own hair matte when it has one, as iPhone portraits do, and otherwise from SAM 3.
- **Body Skin, Facial Hair and Clothes** need SAM 3.

When a part isn't found on anyone, the panel says so, as in Not found: Teeth, Lips, and makes the rest.

## Objects

1. Choose Objects in the picker. As you move the pointer over the photo, Redlamp tints what a click would select.
2. Click the thing you want, or drag a box around it.
3. Click again, or drag another box, to add to the selection. Hold [[⌥]] to take away instead.
4. Click Done, in the strip under the panel's header.

To brush over things rather than box them, set Drag to Brush in the same strip before you drag. A stroke selects what it passes over, and adds to the selection, or takes away with [[⌥]], as clicks do.

## Landscape

Click Landscape in the picker, then one kind: Water, Vegetation, Mountains, Architecture, Natural Ground, Artificial Ground or Snow. Each part of the photo belongs to one kind only, so a Water mask and a Natural Ground mask never overlap. Sky is a mask of its own, not a kind of landscape. Two presets make Landscape masks with their adjustments ready, Brighten Snow and Enhance Vegetation, described under [](#masking.manage.mask-presets).

## Downloading a model

The first time a mask needs a model, the panel names it and its size, at the top of the list and, when you chose a tile, in the picker itself, for example: Objects masks use Segment Anything 2.1 (tiny), a 79.6 MB download. It runs on this Mac; your photos are never uploaded. You can remove it in Settings › Models. Click Download, or press Return, to download the model and carry on with the mask; Not Now leaves it. Nothing downloads without your say.

| Model | Used for | Size | Licence |
| --- | --- | --- | --- |
| Segment Anything 2.1 (tiny) | Objects | 79.6 MB | Apache-2.0 |
| SAM 3 | Landscape; Hair, Facial Hair, Body Skin and Clothes | 988.1 MB | SAM License |
| Depth Anything 3 (mono, large) | Better Sky masks; Depth Range | 336.1 MB | Apache-2.0 |
| Depth Anything V2 (small) | Depth Range on photos without a depth map | 49.8 MB | Apache-2.0 |
| ViTMatte (base) | Stray hairs on the edges of Subject, Background and People masks | 108.9 MB | Apache-2.0 |

Nothing asks for ViTMatte: download it in Settings › Models, and Subject, Background and People masks, and Refine Edges, keep more of the strands at their edges.

## AI masks stay where they are

An AI mask is found once, from the photo without its edit, and kept with the edit. It never moves while you work, and it looks the same in every export and on every Mac. When models improve, choose Update AI Masks from the menu at the right of the panel's header: Redlamp finds every AI mask in the edit again, keeping each component's place, how it combines and whether it's inverted, on every selected photo when there are several. Pasting or syncing settings onto another photo finds its AI masks again for that photo.

## Edges

A selected AI component, other than a Depth Range, has two sliders of its own, and two buttons under them that are also on its menu button and its right-click menu:

{{table: sliders maskAIFeather maskAIEdge}}

Feather
: Softens the mask's edge.

Edge
: Moves the edge outwards, above 0, or inwards, below 0. Both sliders leave the mask as it was found at 0.

Refine Edges
: Solves the mask's edge again from the photo, as masks of its kind are made now, bringing back stray hairs an older mask missed. It has no settings.

Refine Edge Brush
: Paint over an edge, such as hair, fur or a frayed sleeve, and Redlamp works the edge out again there from the photo, hair by hair, leaving the rest of the mask as it was. Its Size, from 1 to 100 and 12 to start, is in the strip under the panel's header, with a value to drag or type; <kbd>[</kbd>, <kbd>]</kbd> and [[⌘]]-scroll change it too. Each stroke is a step in History and is kept with the mask, so Update AI Masks applies it again. Click Done, or press [[Esc]], to finish.

::: lightroom
Lightroom's AI masks are all here, Feather and Edge included, as Lightroom Classic 15.5 has them. Refining an edge works differently: Refine Edges solves the whole edge again, and the Refine Edge Brush only where you paint.
:::
