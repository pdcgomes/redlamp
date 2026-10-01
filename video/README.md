# Redlamp explainer video

A ~72-second animated explainer, built in React with [Remotion](https://www.remotion.dev) and rendered to MP4, plus 9:16 and 1:1 cut-downs of about 29 seconds for social.

```bash
mise run video             # open Remotion Studio to preview and scrub every scene
mise run video -- render   # render every cut into video/out/
```

`npm run render -- Social9x16` renders a single cut. Rendering writes:

| File | Format |
| --- | --- |
| `out/redlamp-explainer-16x9.mp4` | 1920 × 1080, the full film |
| `out/redlamp-explainer-9x16.mp4` | 1080 × 1920, for Stories, Reels and Shorts |
| `out/redlamp-explainer-1x1.mp4` | 1080 × 1080, for feeds |
| `out/*-poster.jpg` | A poster still for each |
| `../web/public/video/redlamp-explainer.mp4` and its poster | A 720p copy the website embeds |

## How it's built

- `src/Explainer.tsx` lists the scenes in each cut and their lengths; scenes cross-fade into each other.
- `src/scenes/` holds the ten scenes, from the safelight warming up to the end card. Each lays itself out for 16:9, 9:16 or 1:1 from the composition's size (`src/layout.ts`).
- `src/components/` holds the shared pieces: the dark stage with its one red light and grain, the word-by-word captions, and the app icon's lens drawn in SVG so its filament can warm up.
- The brand comes from `docs/brand/README.md`: Inter Display (bundled in `public/fonts`, SIL Open Font License), the wall, steel and ruby colours, and one light per frame.

## Assets

- **Logos and film icons** are copied from `docs/` by `../web/scripts/sync-assets.mjs` before every studio session and render.
- **Photos** in `public/photos` are a CC0 landscape from the look-development set, developed by Redlamp itself as its default rendering and through five film stocks. `npm run photos` regenerates them; it needs the CLI (`SCHEME=redlamp mise run build`) and `mise run lookdev`.

## Music

The film is silent until you add a track. Put a licensed file in `public/audio/` and set `musicSrc` (for example `"audio/music.mp3"`) in the compositions' `defaultProps` in `src/Root.tsx`, or pass `--props='{"cut":"explainer","musicSrc":"audio/music.mp3"}'` to `remotion render`. It fades in and out with the film.

## Licence

Remotion is free for individuals and companies of up to three people; larger teams need a [company licence](https://www.remotion.dev/license).
