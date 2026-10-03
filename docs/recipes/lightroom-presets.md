# Lightroom presets

People switching from Lightroom bring folders of develop presets: `.xmp` files of Camera Raw settings. Redlamp reads a preset into a [recipe](recipe-format.md) and a report of how each setting was carried over: **mapped** (Redlamp has the same control on the same scale), **approximated** (carried to the nearest control or scale; the note says how) or **ignored** (not carried; the note says why).

The implementation is `LightroomPreset` in `packages/RedlampRecipes`: `LightroomPresetXMP.swift` reads the file, `LightroomPresetMapping.swift` holds the table below, `LightroomPresetConverter.swift` applies it and `LightroomPresetCrop.swift` maps the crop. The `LightroomPreset*Tests` suites pin every row with presets written from the published schema, never with Adobe's files.

## What is read

- **XMP packets in UTF-8** with Camera Raw settings in the namespace `http://ns.adobe.com/camera-raw-settings/1.0/`, under any prefix (`crs` is the usual one). The settings are the properties of the packet's top-level `rdf:Description` elements; when several descriptions hold the same property, the first value is kept.
- **Both RDF forms** (XMP Specification Part 1, 7.4–7.9): simple values as attributes, `crs:Exposure2012="+0.50"`, as Lightroom Classic writes them, or as elements, `<crs:Exposure2012>+0.50</crs:Exposure2012>`; `rdf:Seq` and `rdf:Bag` lists, such as curves; `rdf:Alt` language alternatives, such as the name, read as the `x-default` item or else the first; structures as a nested `rdf:Description`, as `rdf:parseType="Resource"` or as field attributes; and qualified values through `rdf:value`.
- **A structure's fields stay inside it.** A profile (`crs:Look`) carries its own `Name`, `ProcessVersion`, treatment and curves, and a mask its own adjustments; none of them reads as the preset's.

`LightroomPreset.isPreset` tells a develop preset from a photo's sidecar, which holds Camera Raw settings too. A file is a preset when its first 64 KB mention the RDF and Camera Raw namespaces, it reads as Camera Raw settings, and either it has a `crs:PresetType` other than `Look`, in either RDF form, or, failing that, it has a non-blank `crs:Name`, `crs:Group` or `crs:UUID` and no photo metadata: no `crs:RawFileName` and no TIFF, Exif, Exif auxiliary or CIPA Exif 2.3 properties in any of its descriptions. Lightroom Classic and Camera Raw write `crs:PresetType` in the presets they save; whether every older version did isn't documented, hence the second rule. A sidecar has no preset name, group or UUID and carries the photo's file name and metadata. `convert` refuses with `notAPreset` anything that isn't a preset by these rules (a photo's sidecar included), anything that isn't well-formed XML with an `rdf:RDF` element and Camera Raw settings, a file that declares a document type (XMP has none, and its entities could expand without bound), a file larger than 16 MB (a recipe file's limit), XMP whose Camera Raw properties are all metadata, and a profile (`crs:PresetType="Look"`), which is Adobe's or another maker's file and is never converted.

## Process versions

`crs:ProcessVersion` names the set of sliders a preset was made with. Process 2012 writes `6.7`, and the versions after it (`10.0`, `11.0`, `15.x`) keep its sliders, so all of them map the same way; `LightroomImportReport.processVersion` keeps the value. Earlier versions (below 6.7: Process 2010 and Process 2003) are refused with `unsupportedProcessVersion`, because their Exposure, Recovery, Fill Light, Blacks and Brightness aren't Process 2012's sliders.

A preset made without its process version converts: its Process 2012 settings map, and any Process 2010 setting it holds is reported as ignored, with the Process 2012 setting that replaced it. The recipe is made at Redlamp's current process version.

## The recipe

- **Name:** the name passed to `convert`, else the preset's `crs:Name`, else empty, for the importer to name the recipe after the file. **Group:** the preset's `crs:Group`, else empty, for the importer to choose one. **Summary:** `crs:Description`. **Tag:** `lightroom`. The id is a new `local/` one.
- **Included groups:** exactly the setting groups the preset's settings were carried into. Lightroom applies only the settings a preset holds, while a recipe controls whole groups: an included group's unlisted values take their defaults, as with every recipe. A preset of Exposure alone includes only Tone, so it also sets Contrast, Highlights and the rest of Tone to their defaults, and leaves Presence, the Color Mixer and every other group as the photo has them. An ignored setting never includes a group.
- **Values:** only those that differ from Redlamp's default are listed, except a custom white balance's temperature and tint, which are always listed: Redlamp takes a custom white balance's unlisted temperature or tint from the photo.
- **Ranges:** a value outside Redlamp's range is clamped and reported as approximated, with the value it was clamped to.

The groups a preset can include are Treatment, White Balance, Tone, Presence, Tone Curve, Color Mixer, Color Grading, Detail and Effects. Base Look and Color Chrome are never included: Lightroom's profiles aren't converted, and Lightroom has no Color Chrome.

## Mapping

Redlamp's sliders follow Lightroom's ranges, defaults and directions, so most settings map one to one. How far each slider moves a photo hasn't yet been measured against Lightroom: response curves fitted by rendering the same photos in both apps come later (EDT-11), and where they differ they will become a new version of this mapping.

### Basic

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `ConvertToGrayscale` | Treatment: B&W for `True`, Color for `False` | mapped |
| `Exposure2012` | Exposure (−5 to +5 EV) | mapped |
| `Contrast2012`, `Highlights2012`, `Shadows2012`, `Whites2012`, `Blacks2012` | Contrast, Highlights, Shadows, Whites, Blacks (−100 to +100) | mapped |
| `Texture`, `Clarity2012`, `Dehaze`, `Vibrance`, `Saturation` | Texture, Clarity, Dehaze, Vibrance, Saturation (−100 to +100) | mapped |
| `AutoTone`, and Process 2010's `AutoExposure`, `AutoContrast`, `AutoBrightness`, `AutoShadows` | none | ignored when on: Lightroom works Auto out for each photo, and a recipe holds fixed values. Not reported when off. |
| `Exposure`, `Contrast`, `Brightness`, `Shadows`, `FillLight`, `HighlightRecovery`, `Clarity` | none | ignored: Process 2010's sliders. The note names the Process 2012 setting that replaced each (`Shadows` was Process 2010's Blacks). |

### White balance

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `WhiteBalance`: As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash | the same mode, resolved for each photo or from the preset values Lightroom uses for raw files | mapped; the preset's `Temperature`, `Tint` and relative values are then ignored, as the mode sets them |
| `WhiteBalance` Custom, `Temperature`, `Tint` | Custom, with Temp (2000 to 50000 K) and Tint (−150 to +150; positive renders more magenta, as in Lightroom) | mapped |
| `IncrementalTemperature`, `IncrementalTint` | Red Shift and Blue Shift | approximated |

Lightroom has two white balances: kelvin and tint for raw photos (`Temperature`, `Tint`), and a relative −100 to +100 for JPEGs and other rendered photos (`IncrementalTemperature`, `IncrementalTint`), which a preset made from such a photo holds. Redlamp's Temp and Tint act on raw photos only, as Lightroom's kelvin does.

When a preset holds kelvin values, they are used and the relative ones are reported as ignored. When it holds only relative values, they become Red and Blue Shift, which act on every photo: warmer is more red and less blue, and a magenta tint is more of both, one unit for one (±100 moves red or blue by ±0.3 EV), clamped to ±100. That scale isn't measured against Lightroom, and the shift also changes raw photos, which Lightroom's relative white balance leaves alone; the note says both. A recipe with shifts alone leaves the photo's own white balance as it is.

### Tone curve

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `ToneCurvePV2012` | the point curve: each `x, y` pair on 0 to 255 becomes a point on 0 to 1 | mapped |
| `ToneCurvePV2012Red`, `ToneCurvePV2012Green`, `ToneCurvePV2012Blue` | none | mapped when straight, from (0, 0) to (255, 255), which Redlamp's single curve matches; otherwise ignored, as Redlamp's point curve is one curve for all three channels |
| `ParametricShadows`, `ParametricDarks`, `ParametricLights`, `ParametricHighlights` | the parametric curve's Shadows, Darks, Lights and Highlights | mapped |
| `ParametricShadowSplit`, `ParametricMidtoneSplit`, `ParametricHighlightSplit` | the three splits (10 to 40, 30 to 70, 60 to 90) | mapped; approximated when clamped to Redlamp's narrower ranges |
| `ToneCurveName2012` | none | not reported: the points carry the curve |
| `ToneCurve`, `ToneCurveName`, `ToneCurveRed`, `ToneCurveGreen`, `ToneCurveBlue` | none | ignored: Process 2010's point curve |

A straight point curve, of any number of points, leaves Redlamp's curve straight. A curve that can't be read, or has more than 64 points (a recipe's limit), is ignored. Redlamp applies the point curve to each channel of sRGB-encoded Rec.2020 values and draws it through the points with a monotone cubic (`ToneCurveMath`).

### Color Mixer and B&W

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `HueAdjustment*`, `SaturationAdjustment*` for Red, Orange, Yellow, Green, Aqua, Blue, Purple and Magenta | the Color Mixer's Hue and Saturation for the same band | mapped |
| `LuminanceAdjustment*` | the Color Mixer's Luminance for the band | mapped in colour; ignored in black and white, where Lightroom doesn't apply it |
| `GrayMixer*` (the B&W mix) | the Color Mixer's Luminance for the band | approximated in black and white; ignored otherwise |

Redlamp has no separate B&W mix. In black and white, its Color Mixer's Luminance brightens or darkens each colour before the photo turns grey, which is the B&W mix's job, so a black-and-white preset's mix goes there; the two scales haven't been compared. A preset that doesn't convert to black and white (`ConvertToGrayscale` missing or `False`) has its B&W mix reported as ignored, as Lightroom applies the mix only to black-and-white photos.

### Color Grading

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `SplitToningShadowHue`, `SplitToningShadowSaturation`, `ColorGradeShadowLum` | Shadows: Hue, Saturation, Luminance | mapped |
| `ColorGradeMidtoneHue`, `ColorGradeMidtoneSat`, `ColorGradeMidtoneLum` | Midtones | mapped |
| `SplitToningHighlightHue`, `SplitToningHighlightSaturation`, `ColorGradeHighlightLum` | Highlights | mapped |
| `ColorGradeGlobalHue`, `ColorGradeGlobalSat`, `ColorGradeGlobalLum` | Global | mapped |
| `ColorGradeBlending`, `SplitToningBalance` | Blending, Balance | mapped |

Color Grading kept Split Toning's keys for the shadows' and highlights' hue and saturation and for Balance. Both apps' wheels put red at hue 0 and go round through yellow, green, cyan, blue and magenta.

A preset from before Color Grading holds only Split Toning settings. Lightroom renders such a preset with Blending at 100 and the new controls at zero (Adobe, *Introducing Color Grading*, 2020), so the recipe sets Blending to 100, and the report lists `ColorGradeBlending` with a note that says so.

### Detail

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `Sharpness`, `SharpenRadius`, `SharpenDetail`, `SharpenEdgeMasking` | Sharpening Amount (0 to 150), Radius (0.5 to 3.0), Detail, Masking | mapped |
| `LuminanceSmoothing`, `LuminanceNoiseReductionDetail`, `LuminanceNoiseReductionContrast` | Noise Reduction Luminance, Detail, Contrast | mapped |
| `ColorNoiseReduction`, `ColorNoiseReductionDetail`, `ColorNoiseReductionSmoothness` | Noise Reduction Color, Detail, Smoothness | mapped |

### Effects

| Camera Raw setting | Redlamp | Outcome |
| --- | --- | --- |
| `PostCropVignetteAmount`, `PostCropVignetteMidpoint`, `PostCropVignetteRoundness`, `PostCropVignetteFeather`, `PostCropVignetteHighlightContrast` | Vignette Amount, Midpoint, Roundness, Feather, Highlights | mapped |
| `PostCropVignetteStyle` | none | mapped for Highlight Priority (1); approximated for Color Priority (2) and Paint Overlay (3), which render as Highlight Priority, the only style Redlamp's vignette has |
| `GrainAmount`, `GrainSize`, `GrainFrequency` | Grain Amount, Size, Roughness | mapped |

Redlamp's vignette follows the crop, as Lightroom's post-crop vignette does. The Effects group's controls Lightroom doesn't have (grain Color, halation, bloom, light leaks, dust, scratches and the frame) take their defaults, all of which are off.

### Lens Corrections, Transform and Calibration

Redlamp keeps these with each photo, so recipes never carry them ([recipe format](recipe-format.md#setting-groups)), and each is reported as ignored with that reason:

- **Lens Corrections:** `LensProfileEnable`, whose note adds that Redlamp applies a photo's own lens profile by default, or that the preset switches it off; the other `LensProfile*` settings (setup, name and amounts); `AutoLateralCA`; `ChromaticAberrationR` and `ChromaticAberrationB`; `Defringe` and the six `Defringe*` amounts and hue ranges; `LensManualDistortionAmount`; `VignetteAmount` and `VignetteMidpoint`.
- **Transform:** `PerspectiveUpright`, `UprightVersion` and the other `Upright*` settings, which Lightroom works out for each photo; `PerspectiveVertical`, `PerspectiveHorizontal`, `PerspectiveRotate`, `PerspectiveScale`, `PerspectiveAspect`, `PerspectiveX`, `PerspectiveY`.
- **Calibration:** `ShadowTint`, `RedHue`, `RedSaturation`, `GreenHue`, `GreenSaturation`, `BlueHue`, `BlueSaturation`.

Lightroom's bookkeeping beside these (profile digests and file names, the lens match keys, Upright's solved transforms and guides) isn't reported.

### Crop

Recipes don't carry a crop either, so `HasCrop`, `CropLeft`, `CropTop`, `CropRight`, `CropBottom`, `CropAngle` and `CropConstrainToWarp` are reported as ignored, as are `CropWidth`, `CropHeight` and `CropUnit`, the size Camera Raw crops to (Redlamp sets the size when exporting). The crop is still read and mapped, for applying a preset's crop to a photo directly and for Lightroom sidecars later (EDT-12): `LightroomPresetImport.crop` holds it when `HasCrop` is `True`, and `LightroomCrop.redlampCrop(imageSize:cameraOrientation:orientation:)` gives Redlamp's crop (`EditRecipe.crop`) and its angle (`ParameterID.cropAngle`) for a given photo.

Lightroom's fields are defined this way (John R. Ellis, *SDK: Computing the corners of a crop rectangle*, 2022): all four run from 0 to 1 across the photo's pixels as the file stores them, before the camera's orientation is applied; (`CropLeft`, `CropTop`) is the crop's upper-left corner and (`CropRight`, `CropBottom`) its lower-right; and the crop is turned clockwise by `CropAngle` degrees about its centre. The two corners are therefore those of the turned crop, and its width and height depend on the photo's shape.

The conversion, for a photo whose pixels are stored W by H:

1. **Size.** The diagonal from the upper-left to the lower-right corner, in pixels, turned back by the angle: (w, h) = R(−θ) · ((R − L)·W, (B − T)·H), where R(θ) turns clockwise on screen and θ is `CropAngle`.
2. **Centre.** ((L + R)/2, (T + B)/2) goes through the camera's orientation and then the edit's own into Redlamp's canvas, the photo as shown before straightening. An odd number of quarter turns swaps w and h, and a mirror turns the crop the other way.
3. **Angle.** Redlamp turns the photo clockwise under an upright crop, which turns the crop anticlockwise over the photo, so Redlamp's angle is −θ, or +θ after a mirror.
4. **Rectangle.** Redlamp's straightened frame is the canvas turned by that angle about its centre, measured in units of the canvas's width and height. The crop is centred on the turned centre, with width w and height h in those units.

The tests check the result against Redlamp's own geometry (`GeometryMap`): for every camera orientation and edit orientation, the developed frame's four corners land on the four corners of Lightroom's turned crop, and the crop's top edge runs clockwise by `CropAngle` across the photo.

`CropConstrainToWarp` (Constrain to Image) is kept as `LightroomCrop.constrainsToImage` but not applied: in Redlamp it is a setting of the Crop tool, and the crop Lightroom stored is already constrained.

### Profiles, masks and the rest

| Camera Raw setting | Outcome |
| --- | --- |
| `CameraProfile`, `Look`, and `OverrideLookVignette` when on | ignored: Redlamp doesn't convert Lightroom's profiles, so the photo keeps its Base Look. The note names the preset's profile. |
| `MaskGroupBasedCorrections`, `GradientBasedCorrections`, `CircularGradientBasedCorrections`, `PaintBasedCorrections`, `DepthBasedCorrections`, `RangeMaskMapInfo`, `DepthMapInfo` | ignored: Redlamp keeps masks with each photo. This includes an adaptive preset's AI masks. |
| `RetouchAreas`, `RetouchInfo` | ignored: Redlamp keeps Heal and Clone spots with each photo |
| `RedEyeInfo` | ignored: red-eye corrections belong to each photo |
| `LensBlur` | ignored: Redlamp has no Lens Blur yet |
| `PointColors` | ignored: Redlamp has no Point Color yet |
| `HDREditMode`, with `HDRMaxValue` and the `SDR*` settings | ignored while HDR editing is on: Redlamp doesn't edit in HDR yet. Not reported when off. |
| `CameraModelRestriction` | ignored: Redlamp's recipes apply to photos from every camera |
| Any other setting | ignored: Redlamp doesn't read it |

The preset's own metadata (`Name`, `Group`, `Description`, `UUID`, `PresetType`, the `Supports*` flags, `Version`, `ProcessVersion`, `HasSettings` and the like) and blank fields, which Lightroom writes for fields it leaves unset, aren't reported.

## The report

`LightroomImportReport.entries` has one entry per setting, in Lightroom's panel order as above, followed by the settings Redlamp doesn't know, in alphabetical order. Each entry names the Camera Raw setting without its namespace and gives its outcome, with a note for every approximation and every ignored setting. The settings of one panel often share a note (every lens correction has the same one), so a list can group entries by note.

## Sources

- Adobe, *XMP Specification Part 1: Data Model, Serialization, and Core Properties* (ISO 16684-1), 7.4 to 7.9: the RDF forms. Published with Adobe's XMP Toolkit SDK.
- Adobe, *XMP Specification Part 2: Additional Properties* (2022), 3.3, Camera Raw namespace: the namespace, the white balance names, the ranges of `Temperature` (2000 to 50000) and `Tint` (−150 to 150), the point curve as an ordered array of points, and the crop fields.
- Phil Harvey, ExifTool tag names, *XMP crs Tags*: the names and types of Process 2012's settings, the B&W mix, Color Grading, lens, Transform, crop, mask and profile settings, and that Color Grading uses the Split Toning keys.
- John R. Ellis, *SDK: Computing the corners of a crop rectangle*, Adobe Community, June 2022: the crop fields' meaning.
- Max Wendt, *Introducing Color Grading*, Adobe Blog, 20 October 2020: how Split Toning settings render under Color Grading.
- Redlamp's controls: `ParameterSpec.swift` (ranges and defaults), `DevelopParameters.swift` and `Develop.metal` (what each control does), `Geometry.swift` (the crop's frame and angle).

No Adobe preset, profile or code was used.

## Not yet

- Response curves fitted by rendering the same photos in Lightroom and Redlamp (EDT-11), which may scale some mapped settings and will give the relative white balance and the B&W mix measured scales.
- Per-channel point curves, Point Color and Lens Blur, which Redlamp doesn't have.
- Calibration, lens corrections and Transform in recipes, which the recipe format leaves to each photo.
- Lightroom sidecars (EDT-12), which can reuse the reader, the crop mapping and the per-photo settings.
- XMP in UTF-16 or UTF-32, which the XMP specification allows and Lightroom doesn't write.
