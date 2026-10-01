# Film and cinematic looks: design

The owner's goal: Base Looks and recipes with real film-stock and cinematic quality, on a par with the best Lightroom mobile presets and Prequel filters. Absolutely critical to the product.

## What we're building

Four families, in this order:

1. **Film stocks and cinematic grades** (first): nine stocks modelled physically, under Redlamp's own names. Portra 400-, Ektar 100-, Gold 200-, Superia 400-, CineStill 800T-like colour negatives, Vision3 500T on a 2383-like print for the motion-picture look, Provia 100F- and Velvia 50-like slide film, and Tri-X- and HP5-like black and white.
2. **Mood filters** in the spirit of Prequel: strong one-tap looks with glow, soft focus, light leaks, dust and colour shifts.
3. **Everyday presets** in the spirit of Lightroom mobile: versatile looks that adapt well.

Mood and everyday looks are built on the film and print model where they can be.

## Two sources of truth

- **Manufacturers' datasheets** drive a physical film-and-print model: characteristic curves, spectral sensitivities and spectral dye densities, digitised clean-room from the official PDFs into `research/film-data/` (curves are facts; the PDFs are never committed).
- **The apps' own outputs, measured pixel for pixel** (owner decision DEC-19): a capture kit is run through each filter on the phone, and the importer turns the exports into a Redlamp table plus measured vignette and grain. Looks ship only under Redlamp's own names; app and filter names stay in private provenance.

## Engine

- **Scene-referred Base Looks** (done): a look table indexed by log scene exposure (`sceneLog`, −10 to +6.5 EV around middle grey) that takes the place of Redlamp's tone curve, mixed with it by the look's Amount. Film latitude, shoulder and toe, and colour crossovers are functions of exposure, which a display-referred table after the tone map can't express.
- **Physical effects** (tracker TON-17 to TON-19), in the develop kernel as Effects settings:
  - **Halation** (Amount, Size): red glow around bright lights, strong for CineStill, which has no anti-halation layer. It's added in scene-linear light from a per-session glow source, the pyramid's highlights at up to 1024 px. Near-clipped highlights get back up to 4 stops, because a sensor clips a street light that film records many stops brighter. It's read as a round, long-tailed blur over half-octave mip levels. Only light spilling past an edge glows, so an evenly bright area keeps its colour. It reaches red widest and green a quarter as much.
  - **Bloom** (Amount, Size): the same glow in every colour, plus a share of all the light, for a mist filter's lower contrast.
  - **Grain Color**: decorrelates the grain per dye layer. Still to do: grain strength by density, and size relative to the frame.
- **Texture effects** for mood looks (later): light leaks, dust and frames as procedural or bundled textures.

## The film model (`packages/RedlampRecipes/Sources/Film/`)

Offline, in Swift, generating Base Look tables:

1. Scene colour to spectrum (sigmoid-polynomial spectral upsampling, cached by chromaticity).
2. Layer exposures through the film's spectral sensitivities, normalised so mid-grey sits at a chosen density.
3. Characteristic curves to density; interlayer effects in the density domain; colour masking (coloured couplers cancelling unwanted dye absorption).
4. Negative transmittance from dyes and base; printer light through it onto the print stock; the print's curves and dyes.
5. Viewing illuminant (xenon for cinema print, D50 for paper and slides) and CIE colour matching to display Rec.2020.
6. Mid-grey balanced neutral by solving the printer lights (or slide layer exposures), so crossovers away from grey remain. Print timing (`printNeutral`, 0.6 by default) then pulls the print's grey scale partly back to neutral, as a colourist times a print. Without it, Vision3 on 2383 has shadows 1.7 times bluer than red.
7. A negative with no print is **scanned** instead. A print carries print-system contrast (about 1.7), which reads too hard on a screen, and the familiar look of stocks such as Portra comes from lab scans anyway. The scanner:
   - reads the negative through Status M-like sensors;
   - is calibrated on a grey scale (`scanNeutral`), so greys stay neutral and keep the middle layer's toe and shoulder;
   - has a colour matrix fitted on moderate colours;
   - has a scanner profile for its signature: Frontier-like (punchier, saturated, green-cyan shadows, warm highlights) or Noritsu-like (softer, near neutral). Both are characterised from how labs describe them, not measured.

Datasheets come from `research/film-data/`. Portra, Ektar, Gold and Superia publish no individual dye curves and borrow Vision3's.

**The catalogue** (`FilmLookCatalog`) pairs each stock with its rendering, scanner, print timing and effects. That's 11 looks:
- colour negatives: Portra 400, Ektar 100, Gold 200, Superia 400 and CineStill 800T;
- Vision3 500T printed on 2383;
- slides: Provia 100F and Velvia 50;
- black and white: Tri-X 400, HP5 Plus, and Tri-X printed on Multigrade.

Grain follows each datasheet's granularity. Kodak's Print Grain Index converts as (PGI − 25) × 0.6; slide rms is used as is; black-and-white rms is multiplied by 2.2. Where a datasheet gives no figure, the look is set beside its nearest peer. `redlamp recipe film --all` (or `--look <id>`) writes each look as a recipe with its Base Look and Effects into `build/film/looks/`, with one contact sheet. `--install` writes the bundled tables (`packages/RedlampRecipes/Resources/BaseLooks/stock-<id>.json`, 33³). `--readme` writes the icons and examples in `docs/images/film/`.

**In the app:**
- All 11 looks ship under their stock names; the owner will take the trademark question to counsel.
- The Base Look menu and browser list them under Film Stocks, with icons. The icons are drawn in CoreGraphics (`FilmIcon`): a canister, slide mount, reel or paper print in the stock's colours, in Redlamp's own design.
- Window ▸ Film Looks (`⇧⌘L`, `FilmCatalogView`) shows the open photo in every film; click applies a look with its effects.

## Checking quality

Lint (neutral axis, monotonic lightness, banding, clipping) on every generated table; contact sheets and the Recipe Lab on the 40-image look-development set; side by side against the apps' own outputs for app-measured looks; the owner's picks in the Lab decide what ships.

## Milestones

1. Scene-referred Base Looks in the engine, and the film model on synthetic data. *Done.*
2. Datasheet curves for the nine stocks, 2383 and a colour paper; masking; the first measured stocks. *Done:* 13 stocks, with masking, print timing and the lab scanner.
3. Halation, bloom and grain v2; film-stock recipes that use them. *Done apart from density-dependent grain:* halation, bloom, colour grain and the 11-look catalogue.
4. The app capture kit and importer; the owner's first ten app looks.
5. Mood looks with texture effects; everyday presets.
