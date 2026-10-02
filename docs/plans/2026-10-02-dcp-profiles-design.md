# DCP camera profiles (TON-09)

Approved 2026-10-02.

A DCP (DNG Camera Profile, part of the DNG specification) describes how one camera model sees colour. It has up to four parts: colour matrices; a **HueSatMap** that corrects the matrices' errors (usually two, for tungsten and daylight); a **LookTable**, the creative look; and a **tone curve**. Profiles arrive embedded in DNG files (the Pixel 4a fixture carries Adobe Standard with matrices, a 90 × 30 HueSatMap and a 36 × 8 × 16 LookTable; the iPhone fixtures carry Apple's 257-point tone curve) or as `.dcp` files a user imports.

## Decisions

- **Split, as Lightroom does.** The calibration (matrices and HueSatMap) is applied automatically underneath, like Lightroom's base DCP under its Adobe Raw and Creative profiles. The look (LookTable and tone curve) becomes a Base Look that can be picked, mixed with Amount, saved in a recipe or swapped for another look, which keeps the calibration.
- **New edits start in Redlamp's own default look**, with the embedded look offered in the Base Look menu, as Lightroom opens raws in Adobe Color.

## 1. Reading profiles

`DNGProfile` (RedlampServices, beside `DNGColorCalibration`) reads the profile tags from a DNG's IFD 0 or from a `.dcp` (the same tags in a TIFF container whose magic is `IIRC`): ProfileName, ProfileCopyright, ProfileEmbedPolicy, UniqueCameraModel / ProfileCalibrationSignature, ProfileHueSatMapDims and Data1/Data2 with ProfileHueSatMapEncoding, ProfileLookTableDims and Data with ProfileLookTableEncoding, ProfileToneCurve and BaselineExposureOffset. Matrices and illuminants keep coming from `DNGColorCalibration` (CAM-04). A profile's identity is the SHA-256 of its tags, so the same profile in many files is one profile.

## 2. Calibration

The HueSatMap runs in the develop kernel straight after the camera matrix, before exposure, where the DNG specification places it: linear Rec.2020 to linear ProPhoto (D50), then Adobe's HSV, a trilinear lookup with wrapping hue (hue shift in degrees, saturation and value scales), and back. The two tables are blended on the CPU with the matrices' colour-temperature weight and uploaded as one small texture, cached per weight. It is gated by **process version 4**: existing edits render exactly as before. Among the fixtures only the Pixel changes.

## 3. The Embedded Base Look

When a file opens with a LookTable or a tone curve, Redlamp bakes them into a 33³ `sceneLog` table: scene light to ProPhoto, the LookTable, the tone curve applied with Adobe's hue-preserving RGB method (`RefBaselineRGBTone`), then display Rec.2020. Without a tone curve (the Pixel) the bake uses `RedlampToneCurve`. The look registers as "Embedded: <profile name>" under `embedded/<profile hash>`, versioned by the bake method, and appears in an Embedded section of the Base Look menu for that photo. The baked table is stored with every other installed look, so a later bake never changes an edit that pinned one. A recipe may embed the look only when the profile's embed policy allows copying (0 or 3).

## 4. Order of work and tests

1. Reader and HueSatMap behind process 4. Tests: the three fixtures read as expected; an identity HueSatMap changes nothing; the GPU matches a CPU reference of the specification's math; process 3 golden renders are unchanged.
2. The Embedded Base Look. Tests: a curve-only bake reproduces the curve on neutrals; the Pixel's look renders; Amount 0 equals Redlamp Color.
3. `.dcp` import: an imported profile's look becomes a Base Look, and its calibration is offered per camera model through a Calibration choice the edit pins.
4. Later (TON-14): the profiler writes DCPs.

## Out of scope

ProfileHueSatMap / LookTable value encodings other than linear and sRGB gamma (none exist), DefaultBlackRender (Redlamp doesn't subtract an automatic black), and shipping any Adobe profile: Redlamp only reads profiles the user's files or imports carry.
