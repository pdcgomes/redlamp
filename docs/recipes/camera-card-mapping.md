# Camera recipe cards

Photographers share Fujifilm-style "film recipes" as a card of in-camera settings: a film simulation plus about a dozen tone, color, white balance and grain settings. Redlamp reads and writes these cards as the `fujifilm-card` dialect of a [recipe](recipe-format.md). The card is kept inside the recipe next to the values it resolves to, so it can be shown and edited in its own terms.

The implementation is `CameraRecipeCard` in `packages/RedlampRecipes`. Every row below is pinned by `CameraRecipeCardTests`.

## Film simulation slots

Redlamp uses **its own slot names**. Each slot is filled by a bundled Base Look with the character described, and a card names the slot, not a camera maker's film simulation. Whether camera makers' names may appear as import labels (for example "compatible with Classic Chrome cards") is waiting on a legal check; until then they don't appear anywhere in the UI.

| Slot | Character |
| --- | --- |
| `standard` | Balanced slide-film color, the everyday default. |
| `vivid-slide` | Saturated, contrasty slide film with deep blues and greens. |
| `soft-slide` | Soft slide film: gentle contrast and flattering skin. |
| `chrome` | Muted, dense color with hard tone and cool, deep blues. |
| `negative-high` | Portrait negative with a little extra contrast. |
| `negative-standard` | Soft portrait negative, low contrast and natural skin. |
| `negative-classic` | Snapshot negative: hard shadows, cyan-green cast, magenta reds. |
| `negative-nostalgic` | Warm, amber-tinted highlights and softly faded color. |
| `cinema` | Motion-picture look: flat, very muted, teal-leaning shadows. |
| `bleach` | Bleach bypass: silvery, desaturated and contrasty. |
| `monochrome` | Fine, neutral black and white. |
| `monochrome-yellow`, `-red`, `-green` | Black and white through a color filter. |
| `sepia` | Warm brown-toned monochrome. |

`standard`, `vivid-slide` and `chrome` are filled by version 2 looks measured from cameras' own renderings ([look development](look-development.md#measured-base-looks-the-profiler)); the other slots are still hand-designed version 1 looks.

A card resolves its slot to whichever look fills it when the card is resolved, and pins that look by id, version and table hash. When a better look later fills a slot (for example one fitted by the planned `redlamp-profiler`), existing edits keep the look they were made with.

## Mapping, version 1

`mappingVersion` records which mapping a recipe was resolved with. Improving a row means bumping the version; recipes are only re-resolved when the user edits their card.

| Card field | Range | Redlamp values |
| --- | --- | --- |
| Highlight tone | −2 … +4, half steps | Highlights ×12, Whites ×5 per step |
| Shadow tone | −2 … +4, half steps | Shadows ×−12, Blacks ×−5 per step (+ is harder) |
| Color | −4 … +4 | Saturation ×7 per step |
| Color Chrome, Chrome FX Blue | off, weak, strong | Color Chrome / Chrome FX Blue 0, 45, 85 |
| Dynamic range | DR100, DR200, DR400, auto | Dynamic Range 100, 200, 400 (auto is 200) |
| White balance | auto, as shot, a preset, or a Kelvin value | The same mode; Kelvin sets Temp in Custom mode |
| WB shift R, B | −9 … +9 | Red Shift, Blue Shift ×11 per step |
| Grain | off, weak, strong; small, large | Amount 22 or 40; Size 20 or 55; Roughness 60 when strong |
| Clarity | −5 … +5 | Clarity ×8 (renders from Phase 2) |
| Sharpness | −4 … +4 | Sharpening Amount 40 + 10 per step (renders from Phase 2) |
| Noise reduction | −4 … +4 | Luminance noise reduction 3 × (step + 4) |
| Exposure | −3 … +3 EV | Exposure |
| Monochrome WC, MG | −9 … +9 | Global color-grading wheel: warm is hue 45, magenta 330, 3 saturation per step |

Monochrome slots also set the B&W treatment, and waive the `neutral-axis` and `skin-hue` lint checks. Sepia adds warm toning on top.

A card controls Treatment, Base Look, White Balance, Tone, Presence, Color Chrome, Effects, Detail and Color Grading. Applying one replaces the photo's settings in all of those groups.

## What the new Redlamp controls do

The Effects panel's **Camera Recipe** group holds the controls these cards needed:

- **Dynamic Range** (100 to 400): compresses highlights above +0.5 EV, up to half their slope at 400, so bright areas keep detail like a camera's DR setting.
- **Color Chrome** and **Chrome FX Blue** (0 to 100): deepen and slightly densify strongly saturated colors, or blues only. They don't act in black and white.
- **Red Shift** and **Blue Shift** (−100 to +100): white-balance fine-tuning on the red and blue channels, ±0.3 EV at the ends, on top of Temp and Tint.

All default to no change, so existing edits render as before.
