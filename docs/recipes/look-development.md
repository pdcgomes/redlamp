# Look development

How recipes are made, checked and shipped. The format is in [recipe-format.md](recipe-format.md), camera cards in [camera-card-mapping.md](camera-card-mapping.md), and the agent studio in [agent-studio.md](agent-studio.md).

## The look-development set

`research/look-dev/manifest.json` lists 40 CC0 raw files from raw.pixls.us across 40 camera bodies. They're tagged by scene: landscape, sky, foliage, water, autumn, snow, street, architecture, night, tungsten, low light, high dynamic range, animals, flowers, still life, and a color chart. `mise run lookdev` downloads them into `build/look-dev/` and checks every SHA-256. They are never committed.

**Gap:** raw.pixls.us holds test shots, so there are no portraits. Skin is covered by the lint chart's eight skin patches until own or commissioned CC0 portraits are added.

## The Recipe Lab

In the harness (`mise run harness`), under **Recipes → Recipe Lab**:

- **Gallery.** Every recipe, Base Look and imported LUT, rendered on the chosen look-dev image or the lint chart. It filters by kind, group, tag, lint status and search, and Lightroom's words work in the search: "preset", "profile", "LUT".
- **Compare.** Before and after, A and B side by side, A/B flicker, and one recipe across the whole set. Right-click a tile to make it B.
- **Inspect.** Metadata, the included settings and their values, the camera card, the Base Look's parameters and table statistics (strength, grey chroma, steepest slope, out-of-range entries), the lint results, and the file itself.
- **Create.** Start a new recipe, a new camera card, a duplicate, or an imported `.cube` or HaldCLUT. Pick a Base Look and the settings to include. **Edit in Develop** applies the draft to the harness editor's photo, where the real Develop panels change it, and **Capture from Develop** brings the chosen groups back. The draft previews and lints live, then saves to My Recipes or exports a `.redrecipe`.
- **Runs.** The agent studio's runs; see [agent-studio.md](agent-studio.md).

The Lab renders on its own engine, so it never disturbs the editor's photo. Its views live in `RedlampUI/Sources/Recipes/Lab/`, so the app and a future companion app can host them too.

## The CLI

```bash
redlamp recipe list [--query <text>]
redlamp recipe show <recipe>
redlamp recipe lint all                      # exit 1 if any recipe fails
redlamp recipe render <raw> --recipe <recipe> -o out.jpg [--amount 50]
redlamp recipe contact-sheet --lookdev --original --recipes group:Street -o sheet.jpg
redlamp recipe hald-identity -o identity.png
redlamp recipe import graded.png --name "My Look" --install
redlamp recipe import look.cube -o look.redrecipe
redlamp recipe export <recipe> -o look.redrecipe [--cube look.cube]
redlamp recipe fingerprint ref1.jpg ref2.jpg
redlamp recipe fit --references ref*.jpg [--lut] -o fitted.redrecipe
redlamp recipe build-pack                    # regenerate the bundled film-style Base Looks
redlamp recipe golden [--record]
```

A `<recipe>` is a path, an id, a bundled slug (`street/gritty`) or a name.

## Making a look in any editor (HaldCLUT)

1. `redlamp recipe hald-identity -o identity.png` writes a 64-point identity table as a 512×512 sRGB image.
2. In any editor (Photoshop, Affinity, Resolve, Capture One), grade a photo, then apply exactly the same adjustments to `identity.png`. Keep it in sRGB, and don't resize, crop or sharpen it.
3. `redlamp recipe import graded.png --name "My Look" --install` turns it into a recipe with an embedded Base Look, converted into Redlamp's space so it renders as graded.

`.cube` files work the same way; they're assumed to be built for sRGB unless you pass `--space rec2020`.

## Measured Base Looks (the profiler)

Hand-designed looks are guesses; film simulations are precise, so the film slots are fitted to cameras' own renderings. Every modern Fujifilm raw file embeds the camera's full-size JPEG, rendered with the film simulation set at capture and named in its EXIF. With a neutral Redlamp render of the same raw, that is an exact before-and-after pair.

```bash
mise run profile-data                          # CC0 pairs from raw.pixls.us into build/profiler (1.4 GB)
redlamp recipe profile [--slots chrome,…] [--install]
```

`research/profiler/fujifilm-pairs.json` keeps one CC0 file per camera and film simulation, and only files whose other settings are neutral (Color, Highlight and Shadow tone 0, dynamic range 100%). For each slot, the profiler:

1. **Renders and extracts.** It renders the raw with Redlamp Color and pulls out the camera JPEG.
2. **Aligns.** It matches scale and offset by correlating luminance edges, because the camera corrects lens distortion and crops slightly.
3. **Samples** colors in flat areas away from edges, clipping and the corners (the camera corrects vignetting), capped per color cell so a big sky can't outvote everything else.
4. **Removes each camera's own exposure and color offset** against the average. Redlamp and each body scale raws slightly differently, by up to ±0.9 EV, and that isn't part of the look.
5. **Fits a smooth 25-point table** with the GPU's own tetrahedral interpolation. It chooses the smoothness by leaving whole scenes out, and takes the most accurate fit that passes the banding and monotonic-lightness lint checks.

Each fit ships as the slot's next Base Look version. Earlier versions stay bundled for the edits that pinned them; menus offer only the newest; the Lab lists every version. Recipes built on a re-measured slot are published as a new version too.

Results (ΔE to the camera JPEG, OKLab × 100, on scenes the fit never saw):

| Slot | Camera film simulation | Scenes | Redlamp Color | Hand-designed v1 | Measured v2 |
| --- | --- | --- | --- | --- | --- |
| `standard` | Provia | 28 | 7.83 | 7.57 | **2.73** |
| `vivid-slide` | Velvia | 10 | 4.45 | 5.51 | **3.39** |
| `chrome` | Classic Chrome | 4 | 6.19 | 6.24 | **3.43** (few scenes: provisional) |

The other slots need data: Astia has one clean public scene, Eterna none (only files shot with Highlight and Shadow −2), and Classic Negative, Nostalgic Negative, Pro Neg, Acros and Reala Ace none at all. Twenty to forty varied scenes per simulation, from any Fujifilm body re-rendered in camera or in X RAW Studio, are enough; add them to the manifest and rerun `profile`. The approach isn't Fujifilm-specific: any camera that embeds its own full-size rendering can be profiled the same way.

**Legal check still open:** closely matching a camera maker's rendering is a grey area. The looks keep Redlamp's own slot names.

## Lint

Five deterministic checks, run on a synthetic chart through the real pipeline. Each compares the recipe's render with a neutral render, with vignette and grain removed:

| Check | Measures | Warn / fail |
| --- | --- | --- |
| `neutral-axis` | Chroma added to the grey ramp | 0.025 / 0.05 |
| `skin-hue` | Hue shift of eight skin patches, weighted by their chroma | 10° / 20° |
| `monotonic-luminance` | Largest lightness drop as the ramp brightens | 0.004 / 0.012 |
| `banding` | Abrupt contrast changes along smooth gradients (plateaus and jumps) | 2.5 / 4.5 |
| `clipping` | Colors newly clipped to pure black or white | 3% / 10% |

A recipe that deliberately fails a check (a toned black and white, a warm cross-process look) lists it in `lintWaivers`. Lint is a guardrail against broken looks, not a judge of taste. No bundled recipe fails.

## Shipping a recipe

1. Add it to `packages/RedlampRecipes/Sources/StarterPack.swift` with an original name. Never use a photographer's, brand's or film stock's name.
2. `redlamp recipe lint all` must not fail.
3. `redlamp recipe golden --record` records its golden render in `tests/golden/recipes/process-<n>/`. Existing golden renders are never overwritten, and the tests compare every bundled recipe against its own.
4. A published recipe never changes. To improve one, publish the same id with `version + 1` and record a golden render for the new version.

The bundled film-style Base Looks are `LookDesign`s in `StarterPackLooks.swift`, turned into 25-point tables by `redlamp recipe build-pack`. A test checks that the shipped tables still match their designs; a changed design must bump the look's version.
