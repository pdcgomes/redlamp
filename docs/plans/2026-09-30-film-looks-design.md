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
- **Physical effects** (next, tracker TON-17 to TON-19): halation (red glow around bright lights, strong for CineStill, which has no anti-halation layer), bloom and diffusion, and grain v2 (density-dependent, per dye layer, sized relative to a 35 mm frame).
- **Texture effects** for mood looks (later): light leaks, dust and frames as procedural or bundled textures.

## The film model (`packages/RedlampRecipes/Sources/Film/`)

Offline, in Swift, generating Base Look tables:

1. Scene colour to spectrum (sigmoid-polynomial spectral upsampling, cached by chromaticity).
2. Layer exposures through the film's spectral sensitivities, normalised so mid-grey sits at a chosen density.
3. Characteristic curves to density; interlayer effects in the density domain; colour masking (coloured couplers cancelling unwanted dye absorption).
4. Negative transmittance from dyes and base; printer light through it onto the print stock; the print's curves and dyes.
5. Viewing illuminant (xenon for cinema print, D50 for paper and slides) and CIE colour matching to display Rec.2020.
6. Mid-grey balanced neutral by solving the printer lights (or slide layer exposures), so crossovers away from grey remain.

A look definition (stock, print, exposure, interlayer, grey density, display grey, flare, plus recipe settings for grain, halation and colour) is data in the repo; `redlamp recipe film` builds it and a contact sheet.

## Checking quality

Lint (neutral axis, monotonic lightness, banding, clipping) on every generated table; contact sheets and the Recipe Lab on the 40-image look-development set; side by side against the apps' own outputs for app-measured looks; the owner's picks in the Lab decide what ships.

## Milestones

1. Scene-referred Base Looks in the engine, and the film model on synthetic data. *Done.*
2. Datasheet curves for the nine stocks, 2383 and a colour paper; masking; the first measured stocks.
3. Halation, bloom and grain v2; film-stock recipes that use them.
4. The app capture kit and importer; the owner's first ten app looks.
5. Mood looks with texture effects; everyday presets.
