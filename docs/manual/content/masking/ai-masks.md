+++
deck = "Let Redlamp find the subject, the sky, people and their features, an object you point at, or a kind of landscape. Every model runs on your Mac."
sources = [
  "`README.md`: Masking",
  "`packages/RedlampEngineAPI/Sources/Masks.swift` (MaskKind, PersonPart, LandscapeClass, AIMask)",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`; `packages/RedlampUI/Sources/Settings/ModelsSettings.swift`",
  "`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift`, `EditorModel+Objects.swift`, `EditorModel+EdgeBrush.swift`",
  "`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift`, `RedlampEngine+Models.swift`",
  "`packages/RedlampMasking/Resources/Models/*.json` (model names, sizes and licences)",
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

Click the mask's tile, or choose it from Create New Mask: there is nothing to draw. While the model works the panel says so, as in Finding subject…, and every tile waits. The mask is named after what was found: Subject, Sky, Teeth, Mountains. When there's nothing to find, the panel says that instead, as in No sky was found in this photo.

To add an AI mask to a mask you've already made, choose it from Add, Subtract or Intersect under the mask's components.

## People

People opens a list of parts: Entire Person, Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth, Hair, Facial Hair and Clothes. A part mask covers that part on everyone in the photo. People makes one component per person, so you can leave someone out later by deleting their component; when you subtract or intersect people, they come as one component. In the grid of tiles, People makes an Entire Person mask straight away.

- **Hair** comes from the photo's own hair matte when it has one, as iPhone portraits do, and otherwise from SAM 3.
- **Body Skin, Facial Hair and Clothes** need SAM 3.

::: caution
These parts don't offer to download SAM 3: until it's downloaded they report that they need it. Download it in Settings › Models, or make a Landscape mask, which asks.
:::

## Objects

1. Choose Objects. As you move the pointer over the photo, Redlamp tints what a click would select.
2. Click the thing you want, or drag a box around it.
3. Click again, or drag another box, to add to the selection. Hold [[⌥]] to take away instead.
4. Click Done.

To brush over things rather than box them, choose Brush beside Drag in the panel before you drag. A stroke selects what it passes over, and adds to the selection, or takes away with [[⌥]], as clicks do.

## Landscape

Choose Landscape, then one kind: Water, Vegetation, Mountains, Architecture, Natural Ground, Artificial Ground or Snow. Each part of the photo belongs to one kind only, so a Water mask and a Natural Ground mask never overlap. Sky is a mask of its own, not a kind of landscape. Two presets make Landscape masks with their adjustments ready, Brighten Snow and Enhance Vegetation, described under [](#masking.manage.mask-presets).

## Downloading a model

The first time a mask needs a model, the panel names it and its size, for example: Objects masks use Segment Anything 2.1 (tiny), a 79.6 MB download. It runs on this Mac; your photos are never uploaded. Click Download, or press Return, to download the model and carry on with the mask; Not Now leaves it. Nothing downloads without your say.

| Model | Used for | Size | Licence |
| --- | --- | --- | --- |
| Segment Anything 2.1 (tiny) | Objects | 79.6 MB | Apache-2.0 |
| SAM 3 | Landscape; Hair, Facial Hair, Body Skin and Clothes | 988.1 MB | SAM License |
| Depth Anything 3 (mono, large) | Better Sky masks; Depth Range | 336.1 MB | Apache-2.0 |
| Depth Anything V2 (small) | Depth Range on photos without a depth map | 49.8 MB | Apache-2.0 |

Settings › Models lists every model Redlamp can download, with its size and licence, a Download button for each one you don't have, and Remove for each one you do.

## AI masks stay where they are

An AI mask is found once, from the photo without its edit, and kept with the edit. It never moves while you work, and it looks the same in every export and on every Mac. When models improve, choose Update AI Masks from the … menu beside Presets: Redlamp finds every AI mask in the edit again, keeping each component's place, how it combines and whether it's inverted. With several photos selected, Update AI Masks on 6 Photos (or however many) updates them all. Pasting or syncing settings onto another photo finds its AI masks again for that photo.

## Edges

A selected AI component, other than a Depth Range, has two sliders of its own:

{{table: sliders maskAIFeather maskAIEdge}}

Feather
: Softens the mask's edge.

Edge
: Moves the edge outwards, above 0, or inwards, below 0. Both sliders leave the mask as it was found at 0.

Right-click an AI component for two more ways to work on its edge:

Refine Edges
: Snaps the mask's edges harder to the edges in the photo. It has no settings.

Refine Edge Brush
: Paint over an edge, such as hair, fur or a frayed sleeve, and Redlamp works the edge out again there from the photo, hair by hair, leaving the rest of the mask as it was. Its Size slider, from 1 to 100 and 12 to start, is in the panel, and <kbd>[</kbd>, <kbd>]</kbd> and [[⌘]]-scroll change it. Each stroke is a step in History and is kept with the mask, so Update AI Masks applies it again. Click Done, or press [[Esc]], to finish.

::: lightroom
Lightroom's AI masks are all here, Feather and Edge included, as Lightroom Classic 15.5 has them. Refining an edge works differently: Refine Edges snaps the whole mask to the photo, and the Refine Edge Brush works an edge out again only where you paint.
:::
