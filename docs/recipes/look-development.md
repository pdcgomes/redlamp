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

Results (ΔE to the camera JPEG, OKLab × 100, on scenes the fit never saw). The first measured versions used the CC0 pairs alone:

| Slot | Camera film simulation | Scenes | Redlamp Color | Hand-designed v1 | Measured v2 |
| --- | --- | --- | --- | --- | --- |
| `standard` | Provia | 28 | 7.83 | 7.57 | **2.73** |
| `vivid-slide` | Velvia | 10 | 4.45 | 5.51 | **3.39** |
| `chrome` | Classic Chrome | 4 | 6.19 | 6.24 | **3.43** (few scenes: provisional) |

Adding the review-site pairs (`review-pairs.json`, below) gave a larger and harder test set, so the numbers aren't comparable with the table above. On it, the previous version is mostly scored on photos it never saw:

| Slot | Photos (bodies) | Redlamp Color | Previous version | New version | Shipped |
| --- | --- | --- | --- | --- | --- |
| `standard` | 120 (50) | 5.38 | v2 4.21 | **v3 3.26** | yes |
| `chrome` | 18 (5) | 5.72 | v2 5.52 | **v3 4.61** | yes |
| `soft-slide` | 5 (3) | 12.84 | v1 12.77 | **v2 4.57** | yes, provisional |
| `vivid-slide` | 13 (12) | 4.09 | v2 2.84 (seen 10 of 13) | v3 3.19 | no: not shown better |
| `cinema` | 4 (1) | 4.76 | v1 2.69 | v2 0.88 | no: four night scenes only |

The Soft Slide numbers include a large brightness difference between Redlamp and the camera on these bodies (TON-14). The other slots still need data: Eterna has only night scenes; Classic Negative, Nostalgic Negative, Pro Neg and Reala Ace none; Acros none; and the only Monochrome files were toned (Monochromatic Color), which the fetcher now rejects. Twenty to forty varied scenes per simulation, from any Fujifilm body re-rendered in camera or in X RAW Studio, are enough; add them to the manifest and rerun `profile`. The approach isn't Fujifilm-specific: any camera that embeds its own full-size rendering can be profiled the same way.

**Legal check still open:** closely matching a camera maker's rendering is a grey area. The looks keep Redlamp's own slot names.

### More data

Surveyed 2026-09-30 ([TON-20](../research/research-tracker.md#4-color-tone-and-detail)):

- **Review sites publish raw files.** Photography Blog's sample pages link 2,899 Fujifilm RAFs from 48 bodies (X-Pro1 to GFX100RF), each carrying the camera's JPEG. Reviewers shoot the default: 2,860 are Provia, and the rest are 17 Classic Chrome, 6 Astia, 4 Velvia, 4 Eterna (night only), 9 toned Monochrome and one Monochrome + Red. `research/profiler/fetch_review_pairs.py` surveys them (the first 512 KB of each file), selects neutral files (two Provia per body, up to eight of anything else) into `review-pairs.json`, and downloads them into `build/profiler/review/`; `redlamp recipe profile` reads both manifests. The files are copyrighted: they're used as references only, never shipped or committed ([DEC-17](../research/research-tracker.md#1-decisions-and-legal-questions)). Fetchers are slow (about one request a second), resumable, and stop at the first refusal: a faster first survey got us blocked for a while. Imaging Resource, DPReview and ePhotozine refuse automated requests outright.
- **Simulation-to-simulation pairs.** Film-simulation bracketing, and blog posts showing one frame in every simulation, give JPEG pairs with no raw. A simulation can be fitted relative to one already measured (Provia): measured Provia, then the Provia-to-X table. Web-sized, already-clipped JPEGs make these weaker than raw pairs.
- **Recipe cards.** Sites such as filmsimrecipes.com and Fuji X Weekly list settings cards that the `fujifilm-card` dialect imports directly ([DEC-18](../research/research-tracker.md#1-decisions-and-legal-questions)).
- **A camera.** One Fujifilm body for a few days: 30–40 varied raws, each re-rendered in camera through every simulation, is still the cleanest set.

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
