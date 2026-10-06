# MSK-25: the mask evaluation photoset

Made on 6 October 2026 for the masking workstream's benchmark (MSK-25, [#269](https://github.com/pdcgomes/redlamp/issues/269)). Conventions follow [`_conventions.md`](_conventions.md).

## Why

Until now, Sky, Subject and People masks were measured on 14 daylight landscape raws (the look-development set's sky photos) and on a few portraits kept only on one Mac, with no recorded licence ([MSK-17 limits](MSK-17-sky-bakeoff.md#limits)). There was no CC0 photo of a person anywhere in the repository. This set gives every condition masks are known to struggle with photos anyone can download and use, so a result can be reproduced from a clean checkout.

## What's in it

115 CC0 photos from Wikimedia Commons, in 30 cells, each a condition and the masks it tests ([`research/mask-eval/cells.json`](../../../research/mask-eval/cells.json)). [`manifest.json`](../../../research/mask-eval/manifest.json) lists each photo with its Commons file page, author, licence, SHA-256, size, camera, cell and condition tags. It also names the 19 look-development raws that count too: the 14 with sky, the backlit ones and the animals.

| Cells | Masks | Photos |
| --- | --- | --- |
| Bare trees, leafy trees (with gaps of sky), wires and pylons, haze and fog, a low sun or bright horizon, sunsets, dusk and blue hour, overcast behind pale buildings, sea horizons, glass and water reflecting the sky, snow and mountains, a small patch of sky between buildings | Sky | 46 |
| Loose hair against busy and against plain backgrounds, backlit hair, curly and afro hair, blond and white hair, beards, glasses and hats, groups of two to four, crowds, whole figures, low-key and high-key portraits, dogs and a cat, and other subjects (a kingfisher, a flower, a car) | Subject, People, and their parts (hair, facial hair, body skin, clothes) | 51 |
| Smiles with teeth, eyes, lips and brows, elderly faces, faces with glasses | Face parts | 18 |

- Every photo carries its camera's EXIF. The long side is 2,636 to 8,368 px, with a median of 5,184 px (about 24 MP).
- 96 photographers. The most from one is 7 (Wilfredor, mostly skies), then 5 (Leonhard Lenz, trees).
- The ages, skin tones and genders were chosen to vary across the people and face cells.

## How it was made

Evidence:

- **Candidates.** [`photoset.py`](../../../research/prototypes/masking/photoset.py) `search` asks the Commons API, for each cell's queries, for JPEGs over 700 KB in Category:CC-Zero. It keeps a file only if Commons reports its licence as CC0 (`LicenseShortName`, read on 6 October 2026), its long side is at least 2,400 px, and its title, categories and description don't suggest a painting, scan, poster, collage, render, AI-generated image, black-and-white photo or statue. Most CC0 photos on Commons have short descriptions, so the queries are a word or two. Photos with camera EXIF come first, then by size; each cell keeps 20 candidates with 320 px previews and a numbered contact sheet.
- **Picks, by eye.** For each cell, a reviewer went through every contact sheet against written criteria:
  - a real colour photograph straight from a camera, with no heavy processing, filter, border, watermark or overlay;
  - the cell's condition clear and large in the frame;
  - variety across the set, with no two photos from one series.

  A first round of 600 candidates gave 99 photos. A second round of 220 candidates, searched again where cells came up short or lacked range, filled most of the gaps, and a few photos were taken from another cell's sheet where they fitted better.
- **Originals.** `photoset.py fetch --record` downloaded the 115 originals (1.0 GB) and recorded their SHA-256; `mise run maskeval` downloads them into `build/mask-eval/` and checks them, as `mise run lookdev` does for its raws. The photos are never committed.

Assessment: the set covers 29 of its 30 cells as planned, and the review rejected most of what the searches found. A search for "backlit" also returns keyboards, and "groups" Quaker meeting houses. So the picks depend on the reviewers' eye; you can drop any photo you think doesn't belong, and the manifest is rebuilt from the picks.

## Gaps

- **No close-ups of children's faces.** The face-ages cell has two elderly men only; face-eyes and face-glasses each have one child.
- **No raws.** Every photo here is a JPEG, most compressed for the web, and `ClosedFormMatte` is known to follow JPEG blocks in dark areas. Raw behaviour (noise, the full tonal range) comes from the look-development raws and your own photos.
- **Hair.** Backlit hair is mostly young women: no backlit man, and no backlit face with dark skin. There is no man with loose hair against a busy background, no African or East Asian man with a full beard, and no tight coils on a plain background.
- **Groups and faces.** No dark-skinned group, and no parent with a young child facing the camera. Two of the smiles and two of the faces with glasses are medium shots, where the face is small.
- **Sky.** No dark night sky over a lit skyline (dusk and blue hour only), no lake horizon, and few featureless overcast skies. Several skies come from a few photographers' series.
- **No labels yet.** Trimaps and exact-coverage scenes come with the benchmark, MSK-25's next step.

## People in the photos

CC0 covers copyright, not the people in a photo; 9 of these carry Commons' personality-rights notice. They are used to evaluate masks, and never in the app, the site or marketing.
