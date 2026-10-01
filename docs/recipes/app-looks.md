# Measuring phone-app looks

The owner decided (DEC-19 in [the research tracker](../research/research-tracker.md)) to measure the filters of phone apps such as Prequel and Lightroom mobile presets pixel for pixel into Redlamp's own look tables. The results ship only under Redlamp's own names. This page covers the two capture kits the owner runs through an app, the importer that turns the exports into a recipe, and what that can and can't capture. Other look tools are in [look-development.md](look-development.md).

```bash
redlamp recipe app-kit --compact [-o <folder>]  # one image: build/app-looks/kit-compact/redlamp-kit.png
redlamp recipe app-kit [-o <folder>]            # full kit: build/app-looks/kit/ and build/app-looks/redlamp-capture-kit.zip
redlamp recipe app-import <folder|export> --name "Redlamp name" [--app prequel|lightroom] [--filter "App's name"] \
    [--kit <kit folder>] [--install]
```

There are two kits. The **one-image kit** is the everyday one: one pick, one apply and one export per filter. The **full kit** (three charts and eight photos) is the high-fidelity option, for a filter worth the eleven exports: a 25-point lattice, larger patches, and full-size photos for the spatial effects. `app-import` reads either; the barcode says which, and a folder holding both uses the full charts.

## Why not a HaldCLUT

A HaldCLUT read cell by cell only works if the image comes back untouched. Phone apps resize it (often to 1080 px), crop it to 1:1, 4:5 or 9:16, compress it as JPEG, and add spatial effects on top of the colour: vignette, grain, blur, glow, light leaks, dust and borders. The capture chart is built to survive all of that and to measure the spatial effects separately from the colour.

## The one-image kit

`redlamp recipe app-kit --compact` writes `build/app-looks/kit-compact/`: `redlamp-kit.png`, a `README.txt` with the phone steps, and `kit.json` (which also lists the photo tiles' subjects in order).

- **Canvas: 3072 × 3072, square.** Square because "Original" in both apps then leaves it as it is, and a square is the one shape from which both a 4:5 portrait and a 5:4 landscape crop keep the central 80% of the other axis. Everything the colour needs (lattice, markers, barcode, ramp, line pairs) sits inside the central 80% of both axes, so either crop keeps it; the photo tiles are inside the central 80% of the width, so a 4:5 crop keeps them too. 3072 px is as large as the patches need to be while staying an ordinary image size for both apps.
- **PNG, not JPEG.** It reaches the app exactly: a JPEG would subsample the lattice's chroma and requantise it before the filter even runs, and that error would be measured as part of the look. Apps read PNGs from Photos without trouble, and their JPEG export is fine.
- **Lattice: 21 points per axis (9,261 colours), 14 px patches**, in one image: 21 blue slices as 21 × 21 blocks in a 5 × 5 grid, with the four blocks next to the centre left empty so the gain field has grey inside the lattice. Apps typically scale the long edge to 2048 px (patches 9.3 px) or 1440 px (6.6 px); the importer reads the inner half of each patch, which stays clear of the neighbours' resampling and JPEG spill down to about 6 px. A 25-point lattice would drop to 5.5 px at 1440 px; 21 is the largest that stays above 6. The table keeps the measured 21 points, and `LookTableImport.adapt` resamples it smoothly (trilinear, then converted at 33 points) like any imported `.cube`.
- **Markers and barcode:** the same finder patterns as the full kit (12 px modules), at the lattice's corners and edge midpoints. Their rectangle isn't square, unlike the full charts', so neither layout's fit can land on the other's markers, and the barcode (two copies, top and bottom) carries code 9 for the compact layout.
- **Resolution probe:** twelve groups of vertical black and white bars beside the top-centre marker, with periods from 24 down to 2.5 kit pixels. The importer finds the period where the bars' contrast falls to half that of the coarsest group; a clean resample does that at about 1.9 export pixels per period. It reports the export's size, the scale from the markers, the effective scale from the bars, and the patch size in export pixels. It warns when patches are under 6 px, and when the detail is below 80% of the pixel scale (an app that softened the image or scaled it up from a smaller one).
- **Grey surround and ramp:** sRGB 0.46 with a probe grid over the whole frame, for the gain field (vignette) and grain; the grey ramp is under the lattice.
- **Photo tiles:** the eight kit photos (sky, foliage, night, interior, contrast, colours, both portraits), centre-cropped to 3:2 at 585 × 390, four above the lattice and four below. Each is measured against the same region of the kit image through the table, for grain, sharpness, glow and residual ΔE.

**The vignette comes from the whole image.** The app vignettes the whole frame it exports, so the vignette is fitted to the grey field over the whole image (in the export's frame, or the image's if the app cropped after vignetting), and the tiles are corrected with that vignette rather than fitting their own; a 585 px tile only sees a sliver of the falloff.

## The full kit

`redlamp recipe app-kit` writes the kit to `build/app-looks/kit/` and zips it into `build/app-looks/redlamp-capture-kit.zip`:

| File | What it is |
| --- | --- |
| `redlamp-kit-chart-1.png` … `-3.png` | The colour charts (8-bit sRGB, 2048 × 2048) |
| `redlamp-kit-photo-1-sky.jpg` … `-8-skin-light.jpg` | Eight neutral photos, 2048 px on the long edge |
| `README.txt` | Step-by-step phone instructions for Prequel and Lightroom mobile |
| `kit.json` | Every file with its role, size, SHA-256 and source |

### The chart layout

- **Lattice:** 25 points per axis (15,625 colours), split over three charts. Each chart holds up to nine blue slices, as 25 × 25-patch blocks in a 3 × 3 grid. Red varies along x and green along y; patches are 18 px, so they are about 9.5 px after a downscale to 1080 px. Chart 3 has seven slices and two empty blocks.
- **Patch order:** natural order, so neighbouring patches differ by one lattice step. JPEG chroma blocks (16 px after subsampling) and resampling kernels then only ever mix near-identical colours; a scrambled order would make every JPEG block straddle unrelated colours.
- **Surround:** neutral grey, sRGB 0.46, with 36 px grey gaps between the blocks. The importer samples it on a sparse grid (about 2,000 probes per chart, including the gaps that reach into the middle of the lattice) to measure the filter's spatial gain field and its grain.
- **Markers:** eight QR-style finder patterns (a 1:1:3:1:1 black and white square inside a white quiet ring, 90 px) at the lattice's corners and edge midpoints. A 4:5 crop of the square keeps all eight and the whole lattice.
- **Chart number:** a 7-cell barcode on each side of the top-centre marker: a black and a white reference, four bits of the chart number and a parity cell.
- **Ramp:** a grey ramp from black to white under the lattice. It gives the neutral tone curve at every level, grain by level, and a check of the table at levels between lattice points.

### The photos

`research/app-looks/kit-photos.json` lists them; nothing but that list is committed.

| Photo | Source |
| --- | --- |
| sky, foliage, night (tungsten), interior, contrast (high dynamic range), colours (colour chart) | Look-development raws (CC0, raw.pixls.us): Sony ILCE-6700, Nikon Z f, Canon EOS Kiss F, Canon PowerShot SX130 IS, Leica D-LUX 6, Sigma fp. Rendered neutrally by the engine at 2048 px |
| skin-deep | [Face portrait (Unsplash)](https://commons.wikimedia.org/wiki/File:Face_portrait_(Unsplash).jpg), William Stitt, CC0 |
| skin-light | [Outdoor portrait (Unsplash)](https://commons.wikimedia.org/wiki/File:Outdoor_portrait_(Unsplash).jpg), Anthony Ginsbrook, CC0 |

The look-development set has no portraits, so the two portraits come from Wikimedia Commons; their licences were checked on the file pages. `app-kit` downloads them once, one request at a time, into `build/app-looks/sources/`, checks the SHA-1 Commons publishes, and resizes them. The raws need `mise run lookdev` first.

## The phone workflow

Each kit's `README.txt` has the full steps.

### One-image kit

1. AirDrop `redlamp-kit.png` to the iPhone; it lands in Photos.
2. Per filter, no crop, no rotation, nothing else added, largest size and best quality:
   - **Prequel:** start a new edit, pick `redlamp-kit`, choose "Original" if asked, apply the filter, save to the library. Start the next filter from the same kit image.
   - **Lightroom mobile:** import the kit image once. Then, per preset: open it, Presets, choose the preset, check mark (Amount 100); Share > Export As JPG, Largest Available, quality 100, sRGB, Output Sharpening off, no watermark; then ... > Reset > All (or To Import). The reset matters: a preset changes only the settings it contains, so the previous preset's other settings would carry over. That apply, export, reset loop is the fastest way through many presets: no re-import, no copies. Copies (Create Copy) or Versions also work if each preset should stay visible in Lightroom, at the cost of more taps.
3. AirDrop the exports back to the Mac.
4. Import each export on its own, as a file or from a folder of its own: `redlamp recipe app-import ~/Downloads/IMG_1234.JPG --name "Ember" --app prequel --filter "…" --install`. Several one-image exports in one folder are refused, since each is a different filter.

### Full kit

1. AirDrop the kit's images (not the zip) to the iPhone; they land in Photos.
2. Apply one filter to every kit image, at the same strength, without cropping, rotating or adding anything, and export at the largest size and best quality.
   - **Prequel:** pick the image, keep the Original format, apply the filter, save to the library. Repeat for each image.
   - **Lightroom mobile:** add all kit images, apply the preset to one, Copy Settings (everything except crop and geometry), Paste Settings onto the rest, then Export As JPG, largest size, quality 100, sRGB, no watermark, no output sharpening.
3. AirDrop the exports back into a folder of their own per filter, for example `~/Downloads/capture-warm-film`. Renamed files are fine.
4. Run `redlamp recipe app-import ~/Downloads/capture-warm-film --name "Ember" --app prequel --filter "…" --install`.

## The importer

`AppLookImport` (in `RedlampRecipes/Sources/AppLooks/`) reads the chart exports. `CaptureLayout` holds both layouts (`.full` and `.compact`); the same steps run on either:

1. **Find the chart.** Finder patterns are detected against a local-mean binarisation, so the filter's tone curve and vignette don't matter. A consensus fit over marker pairs, for each layout, gives the scale and offset (one scale per axis if the app stretched the image, which is reported). The layout whose barcode reads as its own wins; the barcode also gives the chart number (or the file name, if the barcode was damaged). Photos have no markers.
2. **Refuse a cut lattice.** If the transformed lattice doesn't fit inside the export, the import stops with "the app cut the colour lattice" and the visible fraction.
3. **Measure the spatial field.** Median grey at every probe is fitted with a smooth per-channel field (bilinear on a coarse grid, with a thin-plate-like penalty, then refitted twice with outlying probes such as dust or a watermark down-weighted). The luminance field is fitted to Redlamp's own vignette model (amount, midpoint and feather at roundness 0), in the export's frame and in the chart's frame, and the better of the two is kept: that tells a vignette applied after a crop from one applied before it. The field's colour variation is reported as irregularity, which flags light leaks.
4. **Read the patches.** Each patch's inner 50% is sampled; the per-channel median is divided by the field relative to the frame's centre. Patches with more internal spread than six times the typical one (overlays, text, dust) are dropped.
5. **Build the table.** Missing lattice points (dropped patches, a chart that didn't come back) are filled by the smoothest continuation of the measured points' difference from identity. The result is a 25-point (full) or 21-point (one-image) table in sRGB display space, converted into Redlamp's space by `LookTableImport.adapt` at 33 points, exactly like an imported `.cube`.
6. **Report.** The layout and lattice size, the export's size and resolution (see the probe above), points measured and filled, patch spread, the ramp against the table (ΔE), non-monotonic steps, clipping, the highlight clip and shadow crush points, the vignette and its fit, and grain (luminance and colour spread on flat grey, its correlation length, and by level from the ramp).

For a one-image export, each photo tile is then compared with the same region of the kit image (resampled to the export's pixel grid through the marker transform), with the whole-image vignette as the gain. For the full kit, for each kit photo, `PhotoPairAnalysis` compares the export with the kit photo passed through the fitted table. Exports are matched to kit photos by name if the app kept it, otherwise by correlating the high-pass of log luminance, which ignores both the tone curve and the vignette. From each pair it reports:

- the residual ΔE after the table and vignette (a large one means the filter adapts per image or adds local effects);
- a vignette fitted to the block-wise luminance ratio (used when the charts gave none);
- grain as extra high-frequency variance in flat mid-tones;
- sharpness as the edge contrast ratio (below 1 is blur or softening);
- glow as extra light beside bright areas.

These feed Redlamp's vignette and grain settings now; glow is reported for a future halation or bloom stage.

## What lands in Redlamp

`app-import` writes into `build/app-looks/out/<name>/`:

- `<name>.redrecipe`: the table as an embedded Base Look, plus Effects: the vignette (amount, midpoint, feather) and grain (amount, size) when they are at least 3. It is in the `Imported` group with the tags `lut` and `captured`, so the Recipe Lab lists it under Imported LUTs.
- `report.json` and `report.txt`.
- `contact-sheet.jpg`: for the first chart (or the one-image export and each of its tiles) and each photo, the kit image, the app's export, and the new look. Photos made from raws are rendered by the engine with the recipe; the charts and portraits have no raw, so the table and vignette are applied directly. The engine's neutral pass over an already rendered JPEG isn't an identity.

`--install` installs the recipe into the library, where the Recipe Lab picks it up: compare it against the app's exports, lint it (measured looks often trip the neutral-axis and skin-hue checks because the filters really do shift them; add lint waivers deliberately), and rename or regroup it before it ships.

**Names.** The recipe's name, the Base Look's name and the output folder use only `--name`, which is refused if it contains the app's or the filter's name. The app and filter names are kept only in `report.json` and in the recipe's private `source` payload (`dialect: redlamp.app-capture`, under `provenance`), which no Redlamp view shows. Strip that payload before a captured look is bundled into the app.

## Limits

- **Only global, fixed colour transforms become a table.** Per-image adaptive filters (auto tone, auto white balance, "smart" or AI filters, scene detection) give a different transform for every photo. The chart measures only what they did to the chart, and the photo residuals show it.
- **Local effects can't be captured:** face- or subject-aware retouching, sky replacement, masks, portrait blur and texture overlays that follow content.
- **Spatial effects are approximate.** The vignette is Redlamp's radial model; off-centre or shaped vignettes and light leaks show up as irregularity and are divided out of the table but not reproduced. A brightening vignette is corrected as a gain, which is wrong for its effect on dark colours. Random overlays that change on every export (dust, leaks) are measured on the charts only.
- **Grain doesn't transfer exactly.** The app's grain is measured on export pixels; Redlamp's is anchored to sensor pixels (0.6–3.5 px), so the suggested amount and size match the export's look at its size only roughly. JPEG compression removes most colour grain before the importer sees it.
- **Blur, glow and bloom** are reported, not applied: Redlamp has no halation stage yet.
- **Lightroom presets behave differently on JPEGs than on raws**: white balance becomes relative, and profiles meant for raws apply differently. The capture measures the preset as applied to a rendered image, which is where Redlamp's Base Look sits (after the tone map).
- **Clipping is baked in.** Colours the app clipped come back clipped; the report flags it.
- **Rotation isn't supported**, and a 9:16 crop of the square cuts the lattice (by design, the importer refuses it).
- **The one-image kit trades detail for speed.** 21 lattice points instead of 25 (a filter with sharp hue bends between points is smoothed a little more), 6.6 px patches at 1440 px, and photo tiles small enough that grain, sharpness and glow are rougher than from full-size photos. An export under 1440 px gets a warning; use the full kit for a filter that matters.

## Accuracy

`CompactKitTests` runs the same look through the one-image kit: a 4:5 crop, a −30 vignette over the exported frame, grain (σ 0.012), a resize so the long edge is 2048 px or 1440 px, and JPEG at quality 0.8. Against the known look, at the 21³ lattice points and on a 25³ grid between them:

| Export | Lattice points ΔE mean / max | 25³ grid ΔE mean / max | Vignette (true −30) | Patches |
| --- | --- | --- | --- | --- |
| 2048 px | 0.29 / 1.68 | 0.24 / 1.67 | −29.9, export frame, corner 0.701 (true 0.700) | 9.3 px |
| 1440 px | 0.39 / 1.68 | 0.33 / 1.68 | −29.9, export frame, corner 0.701 | 6.6 px |

All eight tiles are measured at both sizes. The effective scale matches the pixel scale for a clean resize, and an export scaled up from 900 px to 2048 px is flagged (detail as at scale 0.25 against 0.67).

`AppLookTests` builds a warm, contrasty look with a 15° hue rotation, applies it to the three charts with a −30 vignette and Gaussian grain (σ 0.015), resizes them to 0.53×, crops part of the margin asymmetrically and saves them as JPEG at quality 0.8. The recovered table matches the known one at every lattice point to a mean OKLab ΔE × 100 of 0.41 (maximum 2.04), and the vignette comes back as −29.4 with a corner gain of 0.706 (true 0.700), in the chart's frame. A photo pair recovers a −40 vignette exactly, with a residual of ΔE 0.22. On a simulated app (a warm fade, a −25 vignette, grain, 1080 px, JPEG 80, files renamed), the CLI matched all eight photos by content (similarity above 0.98), measured the vignette as −25 from the charts and −24 to −26 from each photo, and rendering the raw with the new recipe reproduced the true look to a mean ΔE of 1.25.
