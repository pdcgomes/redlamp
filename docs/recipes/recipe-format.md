# The `.redrecipe` format

A **recipe** is everything that gives a photo a look: slider settings, optionally on top of a **Base Look** that can carry a 3D look table (a LUT). One file type covers presets, profiles and LUTs alike, and it is the unit a future marketplace would distribute.

This page is the published schema (format version 1). A machine-readable [JSON Schema](recipe-format.schema.json) sits next to it. The reference implementation is `packages/RedlampRecipes`.

## Principles

- **Declarative, never executable.** A file holds JSON and table data only. Every import goes through `RecipeValidator`: a 16 MB size cap, at most 8 embedded looks, tables of 2 to 65 points per side with finite values in −0.5…1.5 and a matching SHA-256, parameters clamped to their slider ranges, and settings outside the recipe's `includes` dropped.
- **Immutable versions.** `id` plus `version` names one recipe forever. Improvements ship as a new version. Applying a recipe writes its resolved values into the edit, so a later version never changes photos already edited.
- **Content-addressed tables.** A table is identified by the SHA-256 of its space, size and Float16 values. Edits pin it through `baseLook.contentHash`, and every look ever installed stays in `Application Support/Redlamp/Looks/`, so deleting a recipe never changes an edit.
- **Forward compatible.** Unknown fields, parameters and setting groups are kept and written back unchanged; the recipe reports that it needs a newer Redlamp.
- **No images.** Previews are always rendered locally, on the user's own photo.

## Identifiers

`namespace/name[/more]`, lowercase letters, digits, `-`, `_` and `.`:

| Namespace | Used for |
| --- | --- |
| `redlamp/…` | Recipes and Base Looks that ship with Redlamp. Files from anywhere else may not use it. |
| `local/<uuid>` | Recipes made on this machine. |
| `<publisher>/<slug>` | Reserved for marketplace publishers. |

## Top level

| Field | Type | Notes |
| --- | --- | --- |
| `format` | integer | File syntax, currently `1`. |
| `id`, `version` | string, integer ≥ 1 | Identity; see above. |
| `name`, `group` | string | Display name (≤ 120 characters) and the list it appears in. |
| `summary` | string? | One line for tooltips. |
| `author` | `{name, url?}`? | |
| `license` | string? | An SPDX id such as `CC-BY-4.0`, or a marketplace license. |
| `tags` | [string] | Up to 32. |
| `processVersion` | integer | The rendering behavior the recipe was tuned with (`EditRecipe.processVersion`). |
| `includes` | [string] | The setting groups the recipe controls. Everything else in the photo is left alone. |
| `settings` | object | See below. |
| `baseLook` | reference? | The Base Look to render under the settings. |
| `embeddedBaseLooks` | [Base Look]? | Looks carried in the file so it renders anywhere. |
| `source` | object? | The recipe in another dialect, such as a camera recipe card. |
| `lintWaivers` | [string]? | Lint checks the recipe fails on purpose, such as `neutral-axis` for a toned black and white. |
| `signature` | string? | Reserved for marketplace signing. Not verified yet. |
| `created` | ISO 8601 date? | |

### Setting groups

`treatment`, `baseLook`, `whiteBalance`, `tone`, `presence`, `toneCurve`, `colorMixer`, `colorGrading`, `colorChrome`, `effects`, `detail`.

Parameters of an included group that the recipe doesn't list take their **default**, so a recipe renders the same whatever the photo had before. Lens, transform, calibration and mask settings are specific to a photo and can never be part of a recipe.

### `settings`

| Field | Type | Notes |
| --- | --- | --- |
| `values` | {parameter key: number} | Keys are the sidecar keys, for example `basic.contrast`. |
| `treatment` | `color` or `blackAndWhite`? | |
| `whiteBalance` | mode? | `asShot`, `auto`, a preset (`daylight`, …) or `custom`. As Shot and Auto are resolved per photo. |
| `pointCurve` | [{x, y}]? | 2 to 64 points in 0…1. |

### Base Look references and packages

A reference: `{id, version, name, amount, contentHash?}`. `amount` is 0…200 (100 is the look as designed).

A package, inside `embeddedBaseLooks`:

```json
{
  "id": "redlamp/base/chrome", "version": 1, "name": "Chrome",
  "summary": "Muted, dense color with hard tone.", "slot": "chrome",
  "look": {"contrast": 1.05, "saturation": 0.92, "warmth": 0},
  "table": {"size": 33, "space": "displayRec2020", "sha256": "…", "data": "<base64>"}
}
```

`look` holds the parametric part (`contrast` and `saturation` multipliers, `warmth` in OKLab b units, `greenBoost`, `skinSoftening`, `monochrome`). `table.data` is base64 of little-endian Float16 RGB triples, red varying fastest (the `.cube` order), `size`³ entries.

**Table spaces.** `displayRec2020` means display-referred linear Rec.2020, sRGB-transfer encoded: the values straight after Redlamp's tone map. The table is applied there, under every user color control, and mixed by the Base Look's Amount. `sceneLog` means scene-referred: the input is linear Rec.2020 scene light in Redlamp's scene log encoding (each channel's stops from middle grey, −10 to +6.5 EV mapped to 0–1), the output display Rec.2020 with the sRGB transfer, and the table takes the place of Redlamp's tone map; film looks and imported camera log LUTs use it. Other space names are reserved for newer Redlamps; a recipe using one is kept but reported as needing a newer Redlamp. The sidecar that records a photo's edit is described in [sidecar-format.md](sidecar-format.md).

## Applying and Amount

A recipe's Amount (0…200) moves every included value from the photo's current value towards the recipe's: 0 changes nothing, 100 is the recipe exactly, 200 goes twice as far, clamped to each slider's range. Temperature interpolates in mireds. The Base Look's amount scales with it. The edit records `appliedRecipe: {id, version, name, amount}` for provenance only; rendering never reads it.

## Dialects

`source` keeps a recipe as it was first written. Version 1 knows one dialect:

```json
"source": {"dialect": "fujifilm-card", "mappingVersion": 1, "card": {…}}
```

The card and its mapping to Redlamp values are documented in [camera-card-mapping.md](camera-card-mapping.md). Unknown dialects are kept unchanged.

## Importing other formats

- **`.cube`** (3D and 1D, with `DOMAIN_MIN`/`DOMAIN_MAX`): assumed to be built for sRGB unless told otherwise, and converted into Redlamp's space so it renders as its author intended. Stored at up to 33 points per side.
- **`.3dl`** (Autodesk Lustre and Flame): a line of input mesh points, such as `0 64 … 960 1023` for 17 points (2 to 65 points; they need not be evenly spaced), then one row of three integers per grid point, blue varying fastest and red slowest. The output bit depth (10, 12 or 16) comes from a `Mesh <log2 intervals> <bits>` line when the file has one, and otherwise from the largest value, so a 12-bit table whose values all stay below 1024 reads as 10-bit. `3DMESH`, `LUT8` and `gamma` lines are ignored. The same conversion as `.cube`.
- **HaldCLUT** images (level² points in a level³ square image): the same conversion. `redlamp recipe hald-identity` writes an identity image to grade in any editor.

Each becomes a recipe with one embedded Base Look.

### LUTs for camera log footage

A LUT made for a camera's log footage, such as a camera maker's conversion to Rec.709 or a colourist's look for log material, expects the camera's log curve and gamut as its input. Its input space is chosen on import:

| Input space | Curve | Gamut | Middle grey's signal |
| --- | --- | --- | --- |
| `slog3-sgamut3cine` | Sony S-Log3 | S-Gamut3.Cine | 420/1023 |
| `slog3-sgamut3` | Sony S-Log3 | S-Gamut3 | 420/1023 |
| `logc3-awg3` | ARRI LogC3, EI 800 | ARRI Wide Gamut 3 | 0.391 |
| `vlog-vgamut` | Panasonic V-Log | V-Gamut | 433/1023 |
| `applelog` | Apple Log | Rec.2020 | 0.488 |

The LUT's output is taken to be Rec.709 for a BT.1886 display (a pure 2.4 gamma), the target of camera makers' Rec.709 LUTs, unless sRGB is chosen.

Such a LUT is converted at import into a scene-referred table (`sceneLog`, 33 points per side), which takes the place of Redlamp's tone curve. At each grid point the scene light (linear Rec.2020) is converted to the camera's gamut and encoded with its log curve, so middle grey (0.18) reaches the LUT at the camera's own grey; the LUT is sampled tetrahedrally, with signals outside its domain clamped to its edge; and its output is decoded to linear light and converted from Rec.709 to Rec.2020. White balance, Exposure and the Basic tone sliders act on scene light before the table, and the colour controls and the tone curve on its output. The table spans −10 to +6.5 stops around middle grey, so brighter scene light renders as +6.5 stops does.

The curves are the makers' published formulas: Sony's *Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3*; ARRI's *ALEXA Log C Curve: Usage in VFX* (2017), with its exposure-value parameters for EI 800; Panasonic's *V-Log/V-Gamut Reference Manual* (2014); and Apple's *Apple Log Profile White Paper* (2023). Each gamut matrix is derived from the maker's published primaries and D65 white by SMPTE RP 177, and matches the matrices the makers print.

In the app, the import panel's *Look tables are for* menu sets the input space (sRGB unless changed) and *Output* the display. From the command line: `redlamp recipe import <file> --space slog3-sgamut3cine [--display srgb]`.
