# The `.redlamp` sidecar format

Redlamp never writes into photos. Each edited photo gets a **sidecar** beside it, holding its edit recipe, masks, Remove, Heal and Clone spots, snapshots, rating and label, and editing history. Deleting the sidecar returns the photo to unedited.

This page is the published format: edit format 3 and history format 1. A machine-readable [JSON Schema](sidecar-format.schema.json) sits next to it. The reference implementation is `packages/RedlampDocument` (`Sidecar`, `SidecarStore`, `HistorySession`), with the edit's types in `packages/RedlampEngineAPI` (`EditRecipe`, `MaskLayer`, `RetouchSpot`). Applying a [`.redrecipe`](recipe-format.md) writes its settings into the edit recipe described here.

## Principles

- **Beside the photo, never in it.** A sidecar is named after the photo's file and sits in the same folder, so it moves, syncs and backs up with the photo, and needs no catalog.
- **Sparse.** Only values that differ from their defaults are written. A missing key means its default, so new settings need no migration and sidecars stay small.
- **Resolved, not recomputed.** Auto white balance, auto settings, applied recipes and AI masks are stored as the values and bitmaps they produced. Reading a sidecar computes nothing again, so an edit renders the same on every Mac.
- **Stable rendering.** Every edit records the process version it was made with and keeps rendering that way until the user updates it.
- **Forward compatible.** Fields a newer Redlamp wrote are kept and written back unchanged where the format has room for them. A sidecar with a newer format or process version is opened read-only, and so is one that saving would change in any other way.
- **Safe to sync.** Every read and write is coordinated, files are replaced atomically, and conflicting copies from two Macs are merged without losing an edit.

## Files

### Naming and layout

The sidecar's path is the photo's path with `.redlamp` added: `IMG_1234.CR3` has `IMG_1234.CR3.redlamp` beside it. Keeping the photo's extension gives a raw file and a JPEG of the same shot (`IMG_1234.CR3`, `IMG_1234.JPG`) a sidecar each.

The sidecar is a **package**, a folder that Finder shows as one file:

```
IMG_1234.CR3.redlamp/
  edit.json               the edit, snapshots, rating and label
  masks/<sha256>.png      mask bitmaps, named by the SHA-256 of their bytes
  history/<uuid>.json     one file per editing session
```

`edit.json` is always there, except in a package whose edit was set aside (rule 6 under [Versions and compatibility](#versions-and-compatibility)); `masks/` and `history/` exist only when something is in them. Sidecars written before format 3 are a single JSON file at the package's path, with the same content as `edit.json`. A reader must accept both; Redlamp turns a single file into a package when it next saves it.

To show a photo's badges, Redlamp reads only `recipe` and `metadata` from `edit.json`, without file coordination. That is safe because the file is only ever replaced whole.

### Writing

- `edit.json` is written to a temporary file and moved into place. Mask bitmaps are written before the edit that names them, and a new package is built beside the photo and moved in whole, so a reader never finds an edit that names a missing or partly written file.
- A sidecar whose content hasn't changed is not rewritten, so saving an unchanged edit doesn't wake sync services. A change to `modified` alone doesn't count.
- When it saves, Redlamp deletes the bitmaps that no edit, snapshot or history session uses and that no key of `edit.json` or of a history file names, since a key a newer Redlamp added may refer to one. It deletes none while a history file can't be read.
- Redlamp deletes the whole sidecar when the edit is back to its defaults (whatever `wb.temperature` and `wb.tint` hold) and there are no snapshots, rating, flag, label, unknown fields or history.
- Every read and write goes through `NSFileCoordinator`, so iCloud Drive never syncs a half-written package, and a read waits for a sidecar that iCloud Drive has evicted to download. Other tools on macOS should coordinate their writes the same way.

### Conflicting copies

When a photo is edited on two Macs before iCloud Drive syncs them, iCloud keeps the copies as conflict versions. Redlamp merges them when it next reads the sidecar, if it can read every copy and save it back unchanged (see [Versions and compatibility](#versions-and-compatibility)); otherwise it leaves them all for a Redlamp that can. It removes only the copies it merged.

- the copy with the latest `modified` wins;
- every other copy whose edit differs becomes a snapshot of the winner, named "Edit from another Mac" with the copy's date;
- the snapshots of every copy are kept, matched by `id`;
- unknown top-level fields of every copy are kept, the winner's taking precedence;
- history sessions the winner lacks are copied in, with their bitmaps.

## Conventions

- **JSON.** UTF-8. Redlamp writes it pretty-printed with sorted keys; neither the layout nor the order of keys means anything.
- **Numbers** are IEEE doubles, written in the shortest form that reads back exactly: `1` rather than `1.0`, and `1e-07` for very small values. Fields described as integers hold whole numbers.
- **Dates** are ISO 8601 with a time zone. Redlamp writes whole seconds in UTC (`2026-10-03T12:59:01Z`), so a date loses any fraction of a second when it's saved. It reads offsets (`+01:00`) and fractions of a second; a date without a time zone can't be read.
- **Ids** are UUIDs. Redlamp writes them in upper case and reads either case.
- **Hashes** are SHA-256 in lowercase hexadecimal.
- **Image points**, `{"x": …, "y": …}`, are positions in the photo as its EXIF orientation shows it, before crop, Transform and lens correction: (0, 0) is the top left corner and (1, 1) the bottom right. Masks and spots are anchored there, so they stay on the same content whatever the crop, rotation, Transform or lens correction. A point may lie outside 0…1; a gradient can start beyond the photo's edge.
- **Sizes** of radial gradients, brushes, color samples and spots are fractions of the image **height**, so a circle stays round at any aspect ratio.
- **Percentages** run from 0 to 100 unless a field says otherwise.
- **Values without a unit** are slider positions, on the scale the editor shows.

## `edit.json`

| Field | Type | Notes |
| --- | --- | --- |
| `format` | string | `app.redlamp.edit`. Always written; Redlamp doesn't check it. |
| `recipe` | object | **Required.** The edit; see [The recipe](#the-recipe). |
| `snapshots` | [snapshot] | Named versions of the edit, in the order they were made. Default `[]`. |
| `metadata` | object? | Rating, flag and label. Written only when one is set. |
| `modified` | date? | When the edit was last saved. A sidecar without it loses every conflict. |

A **snapshot** is a named version of the edit, as in Lightroom: `{"id", "name", "created", "recipe"}`, all required. `created` is a date and `recipe` a whole recipe. Snapshots are how one sidecar keeps several versions of a photo's edit.

**Metadata** is Lightroom's culling metadata: `rating` (an integer, 0 to 5 stars, required), `flag` (`pick` or `reject`) and `label` (`red`, `yellow`, `green`, `blue` or `purple`).

## The recipe

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `version` | integer | | The format version, `3`. Always written. Only used to tell that a sidecar is newer; see [Versions and compatibility](#versions-and-compatibility). |
| `processVersion` | integer | `1` | The rendering behavior the edit was made with, from 1 to the latest in [Process versions](#process-versions). Always written. Sidecars from before process versions read as 1. |
| `treatment` | string | `color` | `color` or `blackAndWhite`. Always written. |
| `baseLook` | Base Look | Redlamp Color | The look the edit renders with; see [Base Look](#base-look). Always written. |
| `whiteBalance` | string | `asShot` | The white balance popup: `asShot`, `auto`, `daylight`, `cloudy`, `shade`, `tungsten`, `fluorescent`, `flash` or `custom`. Always written. See [White balance](#white-balance). |
| `pointCurve` | [{x, y}] | straight line | The point curve: 2 or more points in increasing `x`, both coordinates 0…1, display-referred. Written only when it isn't the straight line from (0, 0) to (1, 1). |
| `values` | {key: number} | `{}` | The global sliders; see [Parameters](#parameters). Always written, even empty. |
| `pointColor` | [swatch] | `[]` | Point Color's swatches, applied right after the Color Mixer; at most 8. Written only when there are some. See [Point Color](#point-color). |
| `masks` | [mask] | `[]` | Local adjustments, applied in order on top of the global edit; at most 16. Written only when there are some. See [Masks](#masks). |
| `spots` | [spot] | `[]` | Remove, Heal and Clone spots, applied in order before everything else. Written only when there are some. See [Spots](#spots). |
| `appliedRecipe` | object? | | `{"id", "version", "name", "amount"}`, all required: the `.redrecipe` the edit was last built from, and its Amount in percent (0 to 200). Provenance only; rendering never reads it. |
| `crop` | rect | full frame | Written only when it isn't the full frame. See [Crop and geometry](#crop-and-geometry). |
| `orientation` | object | none | Written only when the photo is turned or flipped. See [Crop and geometry](#crop-and-geometry). |

A reader needs none of these keys: `{}` is an unedited photo at process version 1. Snapshots and history steps hold recipes too, in the same form.

### White balance

For a raw file, `wb.temperature` (kelvin) and `wb.tint` in `values` hold the white balance the popup resolved to:

- **`asShot`**: the photo renders with the camera's white balance. Redlamp fills in the camera's values when the photo opens, for display; rendering doesn't read them.
- **`auto`** stores the values Redlamp measured, once.
- **The presets** store their values: Daylight 5500 K and tint 10, Cloudy 6500 K and 10, Shade 7500 K and 10, Tungsten 2850 K and 0, Fluorescent 3800 K and 21, Flash 5500 K and 0.
- **`custom`** stores the user's values.

### Base Look

The look the edit renders with (Lightroom's profile), referenced as in the recipe format: `{"id", "version", "name", "amount", "contentHash"}`.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | **Required.** Redlamp's own looks are `redlamp/base/` followed by `color` (the default), `neutral`, `vivid`, `landscape`, `portrait` or `monochrome`. Looks made or imported on the Mac are `local/…`, and looks baked from a photo's embedded camera profile `local/embedded/…`. |
| `version` | integer | Default 1. Published versions of a look never change. |
| `name` | string | For display. Defaults to the built-in look's name, or else to the id. |
| `amount` | number | Strength in percent, 0 to 200; 100 is the look as designed. Default 100. |
| `contentHash` | hash? | Pins the look's table, for looks that have one, so a missing or changed table is noticed instead of rendering differently. |

Edits never store file paths: installed looks live in `Application Support/Redlamp/Looks/`, found by `id`, `version` and `contentHash`.

### Parameters

`values` maps parameter keys to numbers. The keys are `ParameterID` raw values and never change once shipped. Each value is written only when it differs from its default, and a reader clamps it to its range. Keys of local, mask and spot parameters (`local.…`, `mask.…`, `spot.…`) never appear here, and Redlamp drops them if they do. In the table, `a.{b,c}` stands for `a.b` and `a.c`.

| Keys | Range | Default | Notes |
| --- | --- | --- | --- |
| `wb.temperature` | 2000…50000 | 5500 | Kelvin. See [White balance](#white-balance). |
| `wb.tint` | −150…150 | 0 | |
| `wb.shift.{red,blue}` | −100…100 | 0 | Fine-tuning on the red and blue axes, on top of Temp and Tint. |
| `basic.exposure` | −5…5 | 0 | Stops. |
| `basic.{contrast,highlights,shadows,whites,blacks}` | −100…100 | 0 | |
| `basic.dynamicRange` | 100…400 | 100 | Highlight headroom in percent, like a camera's DR setting: 100, 200 or 400. |
| `basic.{texture,clarity,dehaze,vibrance,saturation}` | −100…100 | 0 | Negative Dehaze adds a veil. |
| `toneCurve.{highlights,lights,darks,shadows}` | −100…100 | 0 | The parametric curve's four regions. |
| `toneCurve.split.shadows` | 10…40 | 25 | Where Shadows end and Darks begin, in percent of the curve's input. |
| `toneCurve.split.midtones` | 30…70 | 50 | Where Darks end and Lights begin. |
| `toneCurve.split.highlights` | 60…90 | 75 | Where Lights end and Highlights begin. |
| `mixer.{hue,saturation,luminance}.{red,orange,yellow,green,aqua,blue,purple,magenta}` | −100…100 | 0 | The color mixer's 24 sliders. |
| `grading.{shadows,midtones,highlights,global}.hue` | 0…360 | 0 | Color grading wheels: hue in degrees. |
| `grading.{shadows,midtones,highlights,global}.saturation` | 0…100 | 0 | |
| `grading.{shadows,midtones,highlights,global}.luminance` | −100…100 | 0 | |
| `grading.blending` | 0…100 | 50 | |
| `grading.balance` | −100…100 | 0 | |
| `detail.sharpen.amount` | 0…150 | 40 | |
| `detail.sharpen.radius` | 0.5…3 | 1 | Pixels. |
| `detail.sharpen.detail` | 0…100 | 25 | |
| `detail.sharpen.masking` | 0…100 | 0 | |
| `detail.noise.{luminance,luminanceContrast}` | 0…100 | 0 | Noise reduction. |
| `detail.noise.luminanceDetail` | 0…100 | 50 | |
| `detail.noise.color` | 0…100 | 25 | |
| `detail.noise.{colorDetail,colorSmoothness}` | 0…100 | 50 | |
| `lens.{distortion,vignetting}` | −100…100 | 0 | Manual lens corrections. |
| `lens.vignettingMidpoint` | 0…100 | 50 | |
| `lens.profile` | 0…1 | 1 | Enable Profile Corrections, a switch: 1 applies the lens correction the photo's file carries, from process 5 (Fujifilm's from process 6). |
| `lens.{profileDistortion,profileVignetting}` | 0…200 | 100 | How much of the profile's correction applies, in percent. |
| `lens.removeChromaticAberration` | 0…1 | 0 | A switch: 1 corrects lateral color fringes, from the profile or measured. |
| `lens.{defringePurple,defringeGreen}` | 0…20 | 0 | Defringe amounts. |
| `lens.defringePurpleHueLow`, `lens.defringePurpleHueHigh` | 0…100 | 30, 70 | The purple fringe's hue range. |
| `lens.defringeGreenHueLow`, `lens.defringeGreenHueHigh` | 0…100 | 40, 60 | The green fringe's hue range. |
| `crop.angle` | −45…45 | 0 | Straighten, in degrees; positive turns the photo clockwise. See [Crop and geometry](#crop-and-geometry). |
| `transform.{vertical,horizontal}` | −100…100 | 0 | Perspective: negative Vertical widens the top, negative Horizontal the left side. |
| `transform.rotate` | −10…10 | 0 | Degrees, clockwise. |
| `transform.aspect` | −100…100 | 0 | Positive stretches horizontally. |
| `transform.scale` | 50…150 | 100 | Percent. |
| `transform.{offsetX,offsetY}` | −100…100 | 0 | Shares of the frame's half width and half height. |
| `effects.vignette.{amount,roundness}` | −100…100 | 0 | Post-crop vignette. |
| `effects.vignette.{midpoint,feather}` | 0…100 | 50 | |
| `effects.vignette.highlights` | 0…100 | 0 | |
| `effects.grain.{amount,color}` | 0…100 | 0 | Grain. Color is how much the grain differs between the dye layers; 0 is monochrome grain. |
| `effects.grain.size` | 0…100 | 25 | |
| `effects.grain.roughness` | 0…100 | 50 | |
| `effects.{halation,bloom}.amount` | 0…100 | 0 | Halation is the glow film gets around bright lights; Bloom is highlights glowing as through a diffusion filter. |
| `effects.{halation,bloom}.size` | 0…100 | 50 | |
| `effects.leak.{amount,variation}` | 0…100 | 0 | Light leaking in at the frame's edges. |
| `effects.leak.warmth` | −100…100 | 60 | |
| `effects.dust.amount`, `effects.scratches.amount` | 0…100 | 0 | Dust and scratches on the film. |
| `effects.frame.style` | 0…4 | 0 | A border drawn over the photo's edges, by number: 0 none, 1 keyline, 2 print border, 3 35 mm rebate, 4 slide mount. The numbers never change; a new style gets the next one. |
| `effects.frame.size` | 0…100 | 50 | |
| `effects.colorChrome`, `effects.colorChromeBlue` | 0…100 | 0 | Color Chrome deepens highly saturated colors; Color Chrome FX Blue does so for blues only. |
| `calibration.shadowsTint` | −100…100 | 0 | |
| `calibration.{red,green,blue}.{hue,saturation}` | −100…100 | 0 | The primaries' hue and saturation. |

Every value is a number, switches and the frame style included. The defaults are the same in every process version; what a value does can depend on the process version.

### Crop and geometry

- **`crop`** is `{"left", "top", "right", "bottom"}`, all required, in the *straightened frame*: the photo after its EXIF orientation, `orientation` and Transform, turned by `crop.angle` so that the crop is upright. The full frame is 0…1 on both axes. Redlamp keeps the crop inside the frame, so its edges stay within 0…1, give or take floating-point rounding.
- **`crop.angle`**, in `values`, turns the photo clockwise by that many degrees before the crop is cut.
- **`orientation`** is `{"quarterTurns", "mirrored"}`, both required: the photo is mirrored left to right first if `mirrored` is true, then turned clockwise by `quarterTurns` quarter turns (0 to 3). It applies after the camera's EXIF orientation, so image points don't change when the user turns or flips the photo.
- **Transform** is the `transform.…` parameters: a virtual camera tilted (Vertical), turned (Horizontal) and rolled (Rotate) about the frame's center, then stretched (Aspect), scaled and offset.

Followed from a pixel of the developed photo back to the image point it shows, the geometry applies in this order: the crop and its angle, then Transform, then `orientation`, then lens distortion (the manual Distortion slider, then the photo's own lens profile).

### Point Color

A swatch is a colour, the range of colours around it that it selects, and what it does to them: Lightroom's Point Color with Capture One's uniformity. The edit's swatches apply right after the Color Mixer, on the colours after the tone curve; a mask's apply after them, as far as the mask covers.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `id` | UUID | | **Required.** |
| `color` | object or string | | **Required.** `{"lightness", "chroma", "hue"}`, all required: the colour in OKLCh, lightness 0 (black) to 1 (white) on screen, hue in degrees. It stays put when other settings change, as the Color Mixer's bands do. On a mask only, `"mask"`: the mask's own colour, the median of the colours Point Color receives under the mask (weighted by how far it covers, over the whole frame uncropped, near-greys left out), worked out for each photo and following the edits before Point Color, such as white balance, so a preset and a pasted mask adapt to the photo they land on. Any other string makes the sidecar unreadable. |
| `picked` | sample? | | Where the colour was picked, as a Color Range sample: `{"center", "radius"}`. Written only when it was picked on the photo. |
| `values` | {key: number} | `{}` | The settings below, each written only when it isn't its default. Always written, even empty. A reader clamps each to its range and keeps keys it doesn't know. |

| Keys | Range | Default | Notes |
| --- | --- | --- | --- |
| `pointColor.shift.{hue,saturation,luminance}` | −100…100 | 0 | Lightroom's shifts: turn the selected colours' hue, and change their saturation and luminance. |
| `pointColor.uniformity.{hue,saturation,luminance}` | −100…100 | 0 | Capture One's uniformity: above 0, the selected colours move towards the swatch's on that axis (at 100 all the way, where the swatch selects fully); below 0 they move apart, as Lightroom's Variance raised does, never so far that colours change order. |
| `pointColor.range.{hue,saturation,luminance}` | 0…100 | 50 | How far a colour may be from the swatch's on each axis and still be selected. |
| `pointColor.range.smoothness` | 0…100 | 50 | How gradually the selection fades out at the range's edge. |

### Masks

A mask is a local adjustment: coverage built from components, and its own adjustments.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `id` | UUID | | **Required.** Other masks refer to it. |
| `name` | string | `Mask` | |
| `isVisible` | boolean | `true` | A hidden mask doesn't render. |
| `components` | [component] | `[]` | Combined in order. |
| `inverted` | boolean | `false` | The whole mask inverted, once its components have combined, as Lightroom's Invert. A component reusing this mask follows it inverted. Written only when true; a Redlamp from before it keeps the field but draws the mask uninverted. |
| `amount` | number | 100 | Scales every adjustment of the mask, in percent, 0 to 200. |
| `detail` | number | 0 | −100 to 100: above 0 keeps only the textured areas of the mask, below 0 only the flat ones. Written only when it isn't 0. |
| `adjustments` | {key: number} | `{}` | The local parameters below, each written only when it isn't 0. Always written, even empty. |
| `curves` | object? | | The mask's Curves: `{"rgb", "red", "green", "blue"}`, each a point curve like the edit's `pointCurve`, written only when it isn't straight. The RGB curve applies to every channel, then each channel's own, on the display-referred values the global point curve works on, as far as the mask covers and scaled by its amount. Missing when every curve is straight. |
| `pointColor` | [swatch] | `[]` | The mask's own Point Color swatches, after the edit's, as far as the mask covers and scaled by its amount; at most 8. Written only when there are some. See [Point Color](#point-color). |

Redlamp renders at most 16 visible masks and 64 components across them, and the editor makes no more than 16 masks.

**Local adjustments** all default to 0. A reader clamps each to its range and, like `values`, keeps keys it doesn't know.

| Keys | Range | Notes |
| --- | --- | --- |
| `local.{temperature,tint}` | −100…100 | Relative to the global white balance. |
| `local.exposure` | −4…4 | Stops. |
| `local.{contrast,highlights,shadows,whites,blacks,texture,clarity,dehaze,saturation,sharpness,noise,defringe}` | −100…100 | |
| `local.hue` | −180…180 | A hue shift, in degrees. |
| `local.moire` | 0…100 | Moiré reduction. |
| `local.{halation,bloom}` | −100…100 | The film glow effects, more or less where the mask covers; their sizes stay global. |
| `local.color.hue` | 0…360 | The Color swatch's hue, as on a color wheel: 0 is red. |
| `local.color.saturation` | 0…100 | The Color swatch's strength, a tint of its hue over what the mask covers, as Color Grading's Global wheel tints; 0 is no tint. |

A **component** is `{"id", "shape", "operation", "inverted"}`, all required. `operation` is `add`, `subtract` or `intersect`: how the component combines with the coverage of the components before it. `inverted` inverts the component's own coverage first.

The **shape** is an object with exactly one key, the component's kind. Its value holds the kind's parameters under `_0`, which is how Swift encodes an enumeration case's payload; Redlamp keeps that layout so that existing sidecars read:

```
"shape": {"radial": {"_0": {"center": {"x": 0.6, "y": 0.55}, "radiusX": 0.2, "radiusY": 0.12, "rotation": 15, "feather": 70}}}
```

| Kind | Parameters | Coverage |
| --- | --- | --- |
| `linear` | `start`, `end` (points) | Full at `start`, fading to none at `end`. |
| `radial` | `center` (point), `radiusX`, `radiusY` (fractions of the image height), `rotation` (degrees, clockwise), `feather` (0 to 100) | An ellipse with a feathered edge, full inside. |
| `brush` | `strokes` (brush strokes) | Painted strokes, in order; erase strokes take coverage away from earlier ones. |
| `luminanceRange` | `lower`, `upper`, `lowerFeather`, `upperFeather` (0 to 100); `samplePoint` (point, optional) | Full for lightness between `lower` and `upper`, fading to none over the feathers. Lightness is OKLab L × 100 of the photo with its global edit. `samplePoint` is where the eyedropper sampled, for its pin; rendering doesn't read it. |
| `colorRange` | `samples` (up to 5 `{"center", "radius"}`), `refine` (0 to 100) | Colors like any sample. A sample is the mean color over a disc of the photo with its global edit, read at every render; `radius` is a fraction of the image height, 0 for a small spot. `refine` is how far from the samples a color may be and still be selected. |
| `ai` | An [AI mask](#ai-masks) | The model's bitmap. |
| `depthRange` | `depth` (an AI mask whose bitmap is a depth map, near white); `lower`, `upper`, `lowerFeather`, `upperFeather` (0 to 100) | Full for depths between `lower` and `upper` (0 farthest, 100 nearest), fading over the feathers. |
| `maskReference` | `maskID` (the `id` of another mask) | That mask's coverage. Its own references are ignored, so references never loop. |

All parameters are required except `samplePoint`. A **brush stroke** has these keys, all required:

| Field | Type | Notes |
| --- | --- | --- |
| `points` | [point] | The dabs' centers along the stroke. |
| `pressures` | [number] | Pen pressure at each point, 0 to 1. Empty when the input had none, which means full pressure. |
| `size` | number | The brush radius, as a fraction of the image height. |
| `feather` | number | 0 to 100: the share of the radius that fades out. |
| `flow` | number | 0 to 100: how much each dab adds, so overlapping dabs build up. |
| `density` | number | 0 to 100: the most coverage the stroke can reach. |
| `erase` | boolean | Removes coverage instead of adding it. |
| `autoMask` | boolean | Keeps each dab to colors like the one under its center. |

Brush strokes and range masks live in the JSON. Only AI masks, depth maps and picked regions of spots have bitmaps.

#### AI masks

An AI mask was computed by a model from the photo without any edit, and is kept as a bitmap, so it renders the same everywhere and changes only when the user updates it.

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | string | **Required.** `subject`, `sky`, `background`, `objects`, `people` or `landscape`; `depthRange` for a depth map. |
| `provider` | string | **Required.** What computed it, for example `apple.vision.foreground`. |
| `revision` | integer | **Required.** The provider's request or model revision. |
| `osBuild` | string? | The macOS build, for system models that change with the OS. |
| `instance` | integer? | Which person or object, when the provider found several. Missing for one mask covering everyone. |
| `part` | string? | For People, the part of the person: `entirePerson`, `faceSkin`, `bodySkin`, `eyebrows`, `eyeSclera`, `iris`, `lips`, `teeth`, `hair`, `facialHair` or `clothes`. For Landscape, the class: `water`, `vegetation`, `mountains`, `architecture`, `naturalGround`, `artificialGround` or `snow`. |
| `prompts` | [point] | **Required.** Points the user clicked to guide the model; often empty. |
| `excludedPrompts` | [point]? | Points the user clicked to leave out. |
| `box` | object? | For Objects, the box dragged around the thing, or the one Find found it in: `{"left", "top", "right", "bottom"}` in the oriented frame, 0…1. Updating the mask asks the model with it again. |
| `feather` | number? | 0…100: softens the mask's edge, over up to 3% of the mask's long edge. Written only when it isn't 0. |
| `edge` | number? | −100…100: moves the mask's edge out (above 0) or in (below 0), by up to 1.5% of the mask's long edge. Written only when it isn't 0. Both are applied to the bitmap as it's drawn, which stays as the model made it. |
| `analysisHash` | string | **Required.** A hash of the render the model saw. |
| `center` | point | **Required.** Where the mask's pin is drawn. |
| `bitmap` | object | **Required.** `{"sha256", "width", "height"}`: the mask as an 8-bit grayscale PNG, `masks/<sha256>.png` in the package, covering the photo in its oriented frame, white for full coverage. The refinements are already applied. A bitmap file that is missing covers nothing. |
| `createdAt` | date | **Required.** When it was computed. |
| `refinements` | [brush stroke]? | Refine Edge strokes, in order, kept so that updating the mask can apply them to the new one. |

### Spots

Remove, Heal and Clone spots apply in order, before everything else, each to the photo as the spots before it left it. *These types are still changing: removal is being developed, so expect new fields here.*

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | **Required.** |
| `mode` | string | **Required.** `remove` fills the spot from the photo around it, patch by patch; `heal` copies the texture at `source`, matched to the color and brightness around the spot; `clone` copies `source` as it is. A reader treats any other value as `heal`. |
| `center` | point | **Required.** The circle's center, or a brushed spot's first point. |
| `source` | point | **Required.** Where Heal and Clone copy from. Remove doesn't use it and writes `center`. |
| `stroke` | [point]? | A brushed spot's points after the first, each relative to `center`, so moving the spot moves the stroke. Written only for a brushed spot. |
| `region` | AI mask? | A picked person or object: the spot is this mask grown by `radius`, instead of a circle or stroke. It stays where it was found, and `center` is its middle. |
| `radius` | number | **Required.** A fraction of the image height: the circle's or brush's radius (the Size slider gives 0.004 to 0.204), or how far a region grows past its edge (0.005). |
| `feather` | number | **Required.** 0 to 100: the share of the radius that fades out. |
| `opacity` | number | **Required.** 0 to 100. |
| `fill` | generated fill? | A Remove spot's fill made by a generative model, used instead of filling the spot from the photo. A reader that doesn't know the field keeps it and fills the spot from the photo. |

A spot whose opacity or radius is 0, or a Heal or Clone spot whose source is its center, changes nothing.

A generated fill (Generative Remove, made by FLUX.2 [klein] 4B in Redlamp) is kept as pixels, so it renders the same on any Mac, with the model or without:

| Field | Type | Notes |
| --- | --- | --- |
| `bitmap` | object | **Required.** `{"sha256", "width", "height"}`: a 16-bit RGB PNG in the package's `masks/` folder, holding the photo's camera RGB (white balanced as shot, linear) divided by `peak` and square-rooted. |
| `peak` | number | **Required.** The scale the values are stored at. |
| `box` | object | **Required.** `{"x", "y", "width", "height"}`: where the bitmap goes, in the photo's full-size pixels before its orientation. The photo's noise is added as it renders. |
| `photoSize` | object | **Required.** `{"width", "height"}`: the photo's full size as the fill was made for it. A reader whose decode of the photo is another size fills the spot from the photo instead. |
| `model` | string | **Required.** The model's manifest id (`flux2-klein-4b-fill`). |
| `modelVersion` | integer | **Required.** |
| `seed` | integer | **Required.** |
| `prompt` | string | **Required.** The name of the prompt it was made with (`remove`). |

## History files

`history/<id>.json` holds one editing session, from opening the photo to leaving it. Redlamp writes the open session's file as the session goes and doesn't keep a session without edits; once the session is over, the file is never rewritten. Redlamp keeps the 20 most recent sessions, removing the oldest as new ones start but never a file it can't read; Clear History removes every session's file but the open one's.

| Field | Type | Notes |
| --- | --- | --- |
| `format` | string | `app.redlamp.history`. |
| `version` | integer | The history format version, `1`. Redlamp skips a file with a newer one. |
| `id` | UUID | The session's id, which is also the file's name. |
| `started` | date | |
| `bitmaps` | [hash] | Every mask bitmap the steps use, sorted, so saving can keep them without reading every step. |
| `steps` | [step] | At least one. |

All of them are required. A **step** is:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID | **Required.** |
| `action` | string | **Required.** What kind of step it is, for its icon: `open`, `clear`, `restore`, `reset`, `auto`, `treatment`, `baseLook`, `whiteBalance`, `toneCurve`, `recipe`, `snapshot`, `paste`, `crop`, `rotate`, `flip`, `straighten`, `upright`, `retouch`, `edit` or `mask`; `adjustment:` followed by a parameter key for a slider (`adjustment:basic.exposure`); or `mask:` followed by a mask kind (`mask:brush`). A reader treats an action it doesn't know as `edit`. |
| `title` | string | **Required.** What the History panel shows, for example `Exposure`. |
| `before`, `after` | string? | The one value the step changed, as it was and as it became, for example `0.00` and `+0.35`. Steps that change many values have neither; some have only `after`. |
| `recipe` | recipe? | The whole edit. The first step has it. |
| `patch` | [operation]? | The change from the step before, as an [RFC 6902](https://www.rfc-editor.org/rfc/rfc6902) JSON Patch. |

Each step after the first stores its edit as a patch to the JSON of the step before's edit, as Redlamp encodes it. Redlamp writes the `add`, `remove` and `replace` operations; a path is a JSON Pointer into the recipe, with array elements addressed by index and `-` to append. A step with neither `recipe` nor `patch` leaves the edit as it was. Histories don't store bitmaps themselves: the ones they use stay in `masks/`.

## Process versions

| Version | What changed |
| --- | --- |
| 1 | The rendering before process versions existed. |
| 2 | Grain is sized to the frame rather than the sensor's pixels, and is strongest in the low midtones and shadows, as film's is. |
| 3 | A bitmap (JPEG, HEIC, PNG, TIFF) renders as the file at default settings, and halation boosts only small clipped lights, not a clipped sky. |
| 4 | A DNG's embedded camera profile corrects its color with the profile's HueSatMap. |
| 5 | The lens correction the file carries (DNG opcodes, Sony's tags) applies by default, under `lens.profile`, and a DNG's ProfileGainTableMap (Apple ProRAW's local tone mapping) applies with its embedded look. |
| 6 | Fujifilm's lens corrections apply too. |
| 7 | Highlights and Shadows are edge-aware: they move each region by its brightness and keep the detail inside it, instead of applying a curve to each pixel's own brightness. |
| 8 | Dehaze's haze map follows the photo's edges, so the sky beside a tree or a ridge is dehazed as much as the rest of it. |
| 9 | Clarity is edge-aware: a strong edge isn't treated as detail, so Clarity puts no bright and dark bands along it. |
| 10 | A photo with Remove, Heal or Clone spots has its Highlights and Shadows, Clarity, Dehaze and glow worked out from the photo as the spots leave it, so a removed object leaves no trace where they're used. |
| 11 | Texture, Clarity and sharpening work on one split of the noise-reduced luminance into bands of detail. Texture boosts medium detail and holds back the step of an edge, so it makes no halos, and negative Texture smooths that detail; sharpening restores detail that stands above the noise and leaves flat noise as noise reduction left it. |
| 12 | A Remove spot is filled only from what the edit keeps: never from its other Remove spots or from the spots after it, so removing several things at once doesn't copy one into another's hole. |
| 13 | AI masks coarser than the size masks are stored at (an iPhone's embedded mattes, face parts, and masks made before edges were solved per pixel) have their edges refined at the size the photo is drawn at, by a guided filter guided by the photo's own luminance, so an edge stays as sharp as the photo's at full size instead of showing the mask's pixels. Where the photo has no edge for a mask's to follow, the mask keeps its own. A mask's Whites and Blacks move the white and black points where it covers, as the global sliders do, instead of weighing the brightest and darkest tones. |
| 14 | A Sky mask's edit reaches only the share of an edge pixel's light that comes from the sky: at a pixel that is partly sky and partly branch, Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites and Blacks change the sky's share as they change the sky and leave the branch's, so twigs and leaves keep their own colour and brightness instead of taking on part of the edit. A mask of several components, or with Feather, blends its edit by coverage as before. Luminance and Color Range masks, and their eyedroppers, select on the photo point under each pixel when the photo is turned, flipped, cropped or straightened, or moved by Transform or distortion correction: the global edit they select on is developed over the whole photo without those, where before it was the developed frame stretched over the whole photo. An edit with more than 16 AI masks whose edges process 13 refines has every one of them refined, where before those past a photo's sixteenth were drawn unrefined. An AI mask's Feather and Edge soften or move the mask's body and leave its fine partial coverage (stray hairs, wisps a few pixels wide) as it was, faded only by an inward Edge's share, where before they blurred it away. |

New edits get the current version, 14. An edit keeps its version until the user updates it (the Process control in the Calibration panel), so every edit keeps rendering as it did when it was made.

## Versions and compatibility

A sidecar carries three version numbers:

- **The format version**, the recipe's `version`, describes the syntax. Version 2 renamed `profile` to `baseLook` and namespaced Redlamp's look ids (`redlamp.vivid` became `redlamp/base/vivid`). Version 3 added brush, range and AI mask components and made sidecars packages. Older versions are read and migrated silently: `profile` is read when there is no `baseLook`, old look ids are mapped to new ones, and the next save writes version 3. A missing `version` reads as 1.
- **The process version**, the recipe's `processVersion`, describes the rendering. It is never changed silently.
- **The history format version**, a history file's `version`.

What Redlamp does when it reads a sidecar, which is also what another reader must do to write one back safely:

1. **A newer format or process version** (`version` above 3 or `processVersion` above 11): Redlamp shows the photo with the edit, rendered with the newest behavior it has, but the sidecar is read-only. Redlamp never overwrites or deletes a read-only sidecar, its rating, flag and label can't be changed, and applying settings to many photos leaves it alone. Only these two numbers are checked; a `version` that isn't an integer is ignored.
2. **Unknown keys** are kept and written back unchanged where the format has room for them:
   - top-level keys of `edit.json`;
   - keys of a recipe, in the edit and in snapshots, and of a snapshot;
   - keys in `values`, in a mask's `adjustments` and in a swatch's `values` (they must be numbers, and don't render);
   - keys of a mask, a component, an AI mask (a depth range's depth map and a spot's region included), a Point Color swatch, a spot, `metadata` and the applied recipe;
   - component kinds in a mask's `shape` (they render nothing).

   Everywhere else in `edit.json` (shape parameters, bitmaps, the Base Look, the crop and orientation) Redlamp has nowhere to keep an unknown key, so a sidecar holding one is read-only. A shape with more than one key is read as one of them (the first in the order of the kinds table in [Masks](#masks), or else the first by name), and the sidecar is read-only. It ignores unknown keys in history files, which it never rewrites. The schema marks the objects without room for unknown keys closed (`additionalProperties: false`) and leaves the others open, so a writer that validates its sidecars puts new keys only where Redlamp keeps them.
3. **Unknown values**: a spot's `mode` reads as `heal`, and the sidecar is read-only, since saving would write `heal`; a history step's `action` reads as `edit`. Any other value outside its list (`treatment`, `whiteBalance`, a component's `operation`, an AI mask's `kind`, a swatch's `color`, `flag`, `label`) makes the sidecar unreadable.
4. **Values out of range**: parameters and local adjustments are clamped to their ranges, and the sidecar is read-only, since saving would write the clamped values. Nothing else is checked.
5. **History files** with another `format`, a newer `version`, or that can't be read are skipped, and kept.
6. **A sidecar that can't be read** opens as if the photo had no edit, read-only: Redlamp never overwrites or deletes it (it may still hold an edit, history and masks), says why over the photo, and applying settings to many photos leaves it alone. There are three cases:
   - **Damaged:** `edit.json` isn't a JSON object (it is cut short, empty, or not JSON at all). No Redlamp wrote it as it is, so Redlamp offers Start Over: it renames `edit.json` to `edit.damaged-<date>.json` in the package (a single-file sidecar becomes a package holding it under that name), where `<date>` is the local time as `yyyy-MM-dd-HHmmss`, with `-2` and on added if that name is taken. The photo then opens with no edit, and its history and masks stay. Redlamp never deletes a damaged copy: removing the sidecar removes the rest of the package and leaves the copies, and the masks a copy names are kept. Readers ignore `edit.damaged-*.json` files. A Redlamp from before Start Over keeps a damaged copy when it saves, but a save into the package deletes the masks only the copy names, and removing the sidecar deletes the copy.
   - **Unreadable:** `edit.json` is a JSON object that doesn't decode (a missing required key, a value of the wrong type or outside its list, or a date without a time zone). A newer Redlamp may have written it, so there is no Start Over.
   - **Not opened:** `edit.json` is there but can't be opened now (no permission, an I/O error, another app holding it, or iCloud Drive can't download it). Redlamp reads it again, at growing intervals up to a minute, and opens the photo with its edit once it reads.

   Validate a sidecar against the schema before writing it.

When writing a sidecar for Redlamp:

- write `format`, the recipe's `version` (3) and the `processVersion` the edit was made for, no newer than the Redlamp that will read it;
- write only values that differ from their defaults, with the exact keys above, and keep keys you don't understand;
- write bitmaps before the JSON that names them, and replace `edit.json` atomically, with file coordination on macOS;
- leave alone a sidecar with a newer format or process version.

## Edits embedded in exports

An exported file carries the edit that made it in its XMP, as Lightroom's exports carry its develop settings, so the file says how it was made and the edit can be recovered from it. Exports are new files: Redlamp still never writes into a photo.

Exports in every format (JPEG, HEIC, AVIF, PNG and TIFF) carry the edit when the Export dialog's Metadata is All or All Except Location. With None it is left out, like the rest of the metadata. An edit holds no location, so both settings embed the same edit.

The properties are in the namespace `https://redlamp.app/ns/edit/1.0/`, which Redlamp writes with the prefix `redlamp`:

| Property | Value |
| --- | --- |
| `Recipe` | The recipe as `edit.json` holds it under `recipe` (see [The recipe](#the-recipe)), written as JSON without whitespace. |
| `FormatVersion` | The recipe's `version`, for tools that don't read the JSON. |
| `ProcessVersion` | The recipe's `processVersion`. |

```xml
<rdf:Description rdf:about="" xmlns:redlamp="https://redlamp.app/ns/edit/1.0/">
   <redlamp:Recipe>{"baseLook":{"amount":100,"id":"redlamp/base/color","name":"Redlamp Color","version":1},"processVersion":9,"treatment":"color","values":{"basic.exposure":0.35},"version":3,"whiteBalance":"asShot"}</redlamp:Recipe>
   <redlamp:FormatVersion>3</redlamp:FormatVersion>
   <redlamp:ProcessVersion>9</redlamp:ProcessVersion>
</rdf:Description>
```

- **Only the recipe.** Snapshots, history, rating, flag and label stay in the sidecar. Mask bitmaps aren't embedded: an AI mask, a depth map or a spot's picked region keeps its `bitmap` (`sha256`, `width` and `height`) but not its pixels. Applied to the photo it came from, the recipe finds them in that photo's sidecar, as `masks/<sha256>.png`; anywhere else a missing bitmap covers nothing, as it does in a sidecar. Brush strokes and range masks are in the JSON, so they come back whole.
- **Size.** An edit is embedded when its XMP takes at most 256,000 bytes. Most edits take a few kilobytes, and a long brush stroke adds about 10 KB. A bigger edit is left out rather than cut short. A JPEG's main XMP segment holds about 64 KB; when the edit doesn't fit there, ImageIO writes `Recipe` in Extended XMP segments, as part 3 of the XMP specification describes, and keeps the other properties in the main segment. A reader without Extended XMP sees the versions but not the recipe. ImageIO doesn't make the segments' GUID the MD5 digest of their content that the specification asks for, so a reader that checks the digest misses the recipe too. The edit counts toward a file size limit, as the rest of the metadata does.
- **The rest of the metadata is unchanged.** ImageIO keeps some metadata only in XMP: lens details and a rating, and, in HEIC and AVIF, every IPTC field. Redlamp writes the edit beside them, and first checks, on a file of one pixel with the same metadata, that everything else reads back as it does without the edit. If it wouldn't, the edit is left out.
- **Reading it back.** Find `Recipe` by its namespace, whatever prefix the file gives it, and decode it as a recipe. An edit with a `version` or `processVersion` newer than the reader's is treated as a newer sidecar is; see [Versions and compatibility](#versions-and-compatibility). In Redlamp, `EmbeddedEdit.read` returns the recipe and its format version, or nothing when the file has no edit or it can't be read.

## The schema

[`sidecar-format.schema.json`](sidecar-format.schema.json) is JSON Schema draft 2020-12. Validate `edit.json` against the schema itself and a history file against its `#/$defs/historyFile`. The schema describes what Redlamp writes, and is stricter than Redlamp's reader where the reader is lenient: it checks ranges, lists of values and closed objects, where the reader clamps, maps or has nowhere to keep a key, and so opens the sidecar read-only. It accepts format versions up to 3 and process versions up to 12, so a sidecar from a newer Redlamp needs that Redlamp's schema.

Besides annotations, the schema uses only `type`, `enum`, `const`, `minimum`, `maximum`, `pattern`, `properties`, `patternProperties`, `additionalProperties`, `required`, `minProperties`, `maxProperties`, `items`, `prefixItems`, `minItems`, `maxItems`, `anyOf`, `oneOf` and `$ref` to its own `$defs`, so a small validator can check it.

`SidecarSchemaTests` keeps the schema and the code in step. It writes a sidecar with masks of every kind, spots of every mode, a crop, history and the other fields above through `SidecarStore`, and checks that it validates; that every key written is in the schema and every key in the schema is written; that the schema requires exactly the keys the decoder needs; that objects are open exactly where unknown keys survive a save; and that parameters, lists of values, versions and limits match the code. It also validates the examples on this page.

## Examples

A photo warmed to 5150 K, brightened, straightened by 1.5° and cropped, with a radial gradient brightening a face and softening its texture, one Heal spot, and a rating of three stars and a pick flag. Everything else is at its default, so it isn't written:

```json
{
  "format": "app.redlamp.edit",
  "modified": "2026-10-03T12:59:01Z",
  "metadata": {"rating": 3, "flag": "pick"},
  "snapshots": [],
  "recipe": {
    "version": 3,
    "processVersion": 9,
    "treatment": "color",
    "baseLook": {"id": "redlamp/base/color", "version": 1, "name": "Redlamp Color", "amount": 100},
    "whiteBalance": "custom",
    "values": {"wb.temperature": 5150, "wb.tint": 8, "basic.exposure": 0.35, "basic.shadows": 25, "crop.angle": -1.5},
    "crop": {"left": 0.04, "top": 0.06, "right": 0.97, "bottom": 0.94},
    "masks": [{
      "id": "6F1C2A4E-8B1D-4C3A-9E57-1B2D3C4E5F60", "name": "Face", "isVisible": true, "amount": 100,
      "components": [{
        "id": "0B9E7D52-2C61-4E8F-A3B4-5C6D7E8F9A0B", "operation": "add", "inverted": false,
        "shape": {"radial": {"_0": {"center": {"x": 0.42, "y": 0.38}, "radiusX": 0.12, "radiusY": 0.16, "rotation": 0, "feather": 60}}}
      }],
      "adjustments": {"local.exposure": 0.3, "local.texture": -15}
    }],
    "spots": [{
      "id": "C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B", "mode": "heal",
      "center": {"x": 0.61, "y": 0.27}, "source": {"x": 0.66, "y": 0.27},
      "radius": 0.01, "feather": 50, "opacity": 100
    }]
  }
}
```

The start of the session that made it: the photo as opened, then Exposure, then a custom white balance, each later step stored as the change from the one before:

```json
{
  "format": "app.redlamp.history",
  "version": 1,
  "id": "9A8B7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D",
  "started": "2026-10-03T12:40:00Z",
  "bitmaps": [],
  "steps": [
    {"id": "1F2E3D4C-5B6A-4798-8877-665544332211", "action": "open", "title": "Opened",
     "recipe": {"version": 3, "processVersion": 9, "treatment": "color", "whiteBalance": "asShot", "values": {},
                "baseLook": {"id": "redlamp/base/color", "version": 1, "name": "Redlamp Color", "amount": 100}}},
    {"id": "2A3B4C5D-6E7F-4081-9213-243546576879", "action": "adjustment:basic.exposure", "title": "Exposure",
     "before": "0.00", "after": "+0.35",
     "patch": [{"op": "add", "path": "/values/basic.exposure", "value": 0.35}]},
    {"id": "3B4C5D6E-7F80-4192-A324-35465768798A", "action": "whiteBalance", "title": "White Balance", "after": "Custom",
     "patch": [{"op": "replace", "path": "/whiteBalance", "value": "custom"},
               {"op": "add", "path": "/values/wb.temperature", "value": 5150},
               {"op": "add", "path": "/values/wb.tint", "value": 8}]}
  ]
}
```
