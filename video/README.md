# Redlamp promo video

A 24-second promotional film for photographers who know Lightroom, built in React with [Remotion](https://www.remotion.dev) and rendered to MP4, plus a 20-second cut for 9:16 and 1:1 social feeds.

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

- `src/Explainer.tsx` lists the scenes in each cut, their lengths, and whether each arrives with a zoom or a whip pan (`src/transitions.tsx`).
- `src/scenes/` holds the eight beats: the hook, the editor with a cursor making slider moves, speed, masks, film, originals, the essentials, and the end card. Each lays itself out for 16:9, 9:16 or 1:1 from the composition's size.
- Motion uses three springs in `src/layout.ts`: `pop` for arrivals (with overshoot), `snap` for exits and travel, and `drag` for slider thumbs. Beats sit on a 120 BPM grid (a beat every 15 frames), and the red light flares on them.
- Everything on screen is drawn: `src/components/Landscape.tsx` is a vector landscape whose palette runs through the small colour grade in `src/grade.ts`, so slider edits, masks and film looks all change the same drawing. Interface that isn't the point of a shot is skeleton bars.
- The brand comes from `docs/brand/README.md`: Inter Display (bundled in `public/fonts`, SIL Open Font License), the wall, steel and ruby colours, and one light per frame. The only address shown is redlamp.app.

## Introducing Redlamp

A 102-second film that introduces Redlamp on real captures of the app in its Neutral theme, with 57-second cuts for 9:16 and 4:5 feeds, and a score written in code. It's calmer than the explainer: a scene every ten seconds or so, cut to a 72 BPM grid, ending on its promise: everything you know, nothing you don't need.

```bash
PROMO_OUT=video/public/film/captures scripts/capture-promo.sh ~/Pictures/redlamp-promo   # from the repo root
cd video
npm run film-assets -- ~/Pictures/redlamp-promo   # the engine's renders, from the same photos
python3 scripts/score.py                          # the scores (needs numpy)
npm run introducing                               # every cut and its poster, into out/introducing/
```

`mise run video -- introducing` runs the last step. `npm run introducing -- --4k --prores` adds a 3840 × 2160 master and ProRes 422 HQ masters for editing.

| File | Format |
| --- | --- |
| `out/introducing/introducing-redlamp-16x9.mp4` | 1920 × 1080, 102 s: YouTube, X, LinkedIn and Reddit |
| `out/introducing/introducing-redlamp-9x16.mp4` | 1080 × 1920, 57 s: Shorts, Reels, TikTok and Stories |
| `out/introducing/introducing-redlamp-4x5.mp4` | 1080 × 1350, 57 s: Instagram and Facebook feeds, Reddit on phones |
| `out/introducing/*-poster.jpg` | A poster still for each |
| `out/introducing/introducing-redlamp-story-1-title.png`, `-story-2-end.png` | 1080 × 1920 PNGs of the film's title and its closing address, to post as Stories ahead of the film |

Remotion renders H.264, H.265, VP8 and VP9 (WebM), ProRes and GIF, so any other format is one flag away (`npx remotion render Introducing out/introducing.webm --codec=vp9`), or ffmpeg can transcode the ProRes master.

### How it's built

- `src/introducing/cuts.json` lists each cut's scenes and their lengths in bars. `Introducing.tsx` lays them out on the bar lines and dissolves across them; `scripts/score.py` writes each cut's score from the same file: a bed of pad, felt piano and bells under a beat that builds scene by scene, from a heartbeat at the MacBook to the full groove at the film looks, then drops away for the closing line. Its cues land on the beats the pictures do: each History step, the push into the display, the edit lifting off, the subject separating, the CineStill wipe, each film stock, the keys, the closing line and the icon.
- `src/introducing/scenes/` holds the ten scenes: the safelight, the MacBook, the familiar panels and shortcuts, every step in History, the originals, masks, film looks, the keyboard, native, and the end. Each lays itself out for 16:9, 9:16 or 4:5. `Posters.tsx` freezes the first and last where they come to rest, for the Stories stills.
- Everything on screen is the app or the engine. Window captures come from `scripts/capture-promo.sh`, with the Folders panel cleared so only the shot's folder shows, and the edit the app saved for the hero kept beside its capture. `scripts/film-assets.mjs` renders the rest with the redlamp CLI, listing it in `public/film/renders/manifest.json`: the hero raw at every History step of that saved edit, the Subject and Background masks a portrait comes apart along, and one frame through each film stock in the deck. Its `promo.txt` roles add `cutout` and `stocks` to the capture script's.
- The 3D is CSS 3D in Remotion's Chrome. `components/MacBook.tsx` is a 16-inch MacBook Pro built from the real one's proportions; `components/Space.tsx` holds the camera, and `project()`, which finds where a point of a 3D sheet lands so 2D lines (the History panel's leader lines) can meet it; `components/Sheet.tsx` is a sheet of an onion-skin stack, cut out by a mask when it has one.
- Words follow the brand: Inter Display headlines that come up the way a print does in the developer, and only claims the README makes. While photos are on screen the room is the app's neutral grey; the safelight's red light is kept for the opening and the end.

The score is synthesised in `scripts/score.py` and nothing in it is sampled, so it's free to use. To use a licensed track instead, put it in `public/` and pass `--props='{"cut":"film","musicSrc":"audio/track.wav"}'`; anything at 72 BPM keeps the cuts on the beat.

### The app's welcome

The app opens with the film's opening the first time it runs, and again from Help › Welcome to Redlamp. `npm run welcome` renders it into `../apps/RedlampMac/Resources/Welcome.mp4`, which the app ships. `src/introducing/Welcome.tsx` plays the opening as it is, with the length the film gives it, then raises the logo to the top of the frame, where the window's pages appear (`packages/RedlampUI/Sources/Welcome/`), and holds the last frame while the score dies away. It runs 16.7 s at 1920 × 1080, for a 960 × 540 point window.

- The score is the `welcome` cut in `cuts.json`: the opening, then two bars that hold its last chord. `score.py` draws the opening's sounds as it draws the film's and plays them in the film's reverb at the film's level, so they sound as they do in the film. Levelled to −16 LUFS on its own, the quiet opening would come out far louder.
- It's HEVC Main10, about 2.5 MB, encoded by VideoToolbox through Remotion's ffmpeg from a ProRes 4444 master. In 8 bits the glow's dark gradient bands on the held frame, and Remotion's own HEVC encoder is 8-bit only.

## Star Redlamp

An 18-second promo for social feeds, in 9:16 and 1:1, that asks people to star Redlamp on GitHub: the website's star nudge ([docs/brand/star-nudge.md](../docs/brand/star-nudge.md)) played as a short film. The lamp charges and trembles to a snare roll, fires its light into the GitHub badge on the drop, a sign drops on its rope and catches on the beat, and a cursor stars the project. Its brief, hooks, script and post copy are in the [design](../docs/plans/2026-10-06-star-promo.md).

```bash
python3 scripts/star-score.py   # the score (needs numpy)
npm run studio                  # StarPromo9x16 and StarPromo1x1, under Star
npm run star                    # both cuts and their posters, into out/star/
```

Each hook is a value of the compositions' `hook` prop (`charging`, `favour`, `psst`, `wait`, `day`). `npm run star -- --hook=psst` renders another, `--hooks` every one, `--no-count` the badge without its star count, and `--draft` a half-size preview. The badge shows the repository's star count as GitHub reports it when the promo renders, and one more after the click; in the agent sandbox, run it with `NODE_USE_ENV_PROXY=1` so the count can reach GitHub. `mise run video -- star` runs the same script.

| File | Format |
| --- | --- |
| `out/star/star-redlamp-9x16.mp4` | 1080 × 1920, 18 s: TikTok, Reels, Shorts and Stories |
| `out/star/star-redlamp-1x1.mp4` | 1080 × 1080, 18 s: feeds |
| `out/star/*-poster.jpg` | The sign hanging under the badge, for covers |

### How it's built

- `src/star/cues.json` holds every timing, in beats on a 120 BPM grid, and `src/star/copy.ts` every word. `StarPromo.tsx` lays one timeline out for each shape, with a camera that creeps in on the lamp as it charges, pulls back for the shot, pushes in on the badge and pulls back for the end card.
- Its pieces are the promo kit in `src/kit/`: the nudge's light, redrawn frame by frame from a seeded random source (`light.ts`); the lamp, shaken by each knock of the roll (`Lamp.tsx`); the GitHub badge (`GitHubBadge.tsx`); and the website's sign physics, `web/lib/hanging-sign.ts` itself, simulated once per shape and cached (`rope.ts`, `Sign.tsx`). Canvases draw in software, since headless Chrome can capture a frame before a GPU canvas is painted, and on a busy machine it has captured whole frames before painting them, as white: `npm run star`, `review` and `storyboard` check every still and every frame they write (`scripts/blank.mjs`) and render it again.
- `scripts/star-score.py` writes the score from the same cue sheet with the synth library, `scripts/synth.py`: dark and cinematic, in D minor. A drone, a heartbeat, a watch ticking and a Shepard tone that climbs faster as the lamp charges; low toms for the build's roll, each hit a knock that shakes the lamp, under spiccato strings; the rhythm stopping for the squash while a swell carries on into the hit; a shot of glass, and the hit landing as a trailer's low brass on the drop, into a half-time groove whose drum hits (the cue sheet's `groove`) the badge bumps on. It's mastered to −14 LUFS with true peaks under −1 dBFS; the library's meter reads as ffmpeg's `ebur128` does, and `python3 scripts/score-report.py public/star/score.wav --cues=src/star/cues.json` measures it bar by bar and cue by cue.
- `npm run storyboard -- StarPromo9x16 --cues=src/star/cues.json --score=star/score.json` lays a frame out at every cue over the score's level, into `out/`.

## The promo studio

New promos follow the project skill [redlamp-promo-studio](../.cursor/skills/redlamp-promo-studio/SKILL.md), which works like a small agency: a brief, hooks and copy, a script on a music grid, scenes from the kit, the edit, a score from `synth.py`, review and delivery, each with a guide, and the owner approving the script, the cut and the render. `npm run review` renders stills at chosen frames or at every cue, and `npm run storyboard` the storyboard sheet.

## Stills

Nine product-brief images for the Reddit announcement, at 2880 × 1800 (a Mac App Store size), each a headline and a few words over real captures of the app. The [design](../docs/plans/2026-10-01-reddit-screenshots-design.md) has their copy and which posts use them.

```bash
mise run video -- stills                    # render every still into video/out/stills/
mise run video -- stills still-04-film      # or just some
scripts/capture-promo.sh ~/Pictures/promo   # capture the app from a folder of your photos
```

- `src/stills/images/` holds one component per image and `src/stills/components/` the pieces they share. They appear in Remotion Studio under **Stills**. Each render writes a PNG master and a JPEG for uploading.
- The captures come from `scripts/capture-promo.sh`. It opens the Debug app on a copy of the folder at a 1600 × 1000 window on a Retina screen, applies a script per shot, and saves the window into `public/promo/`, which is never committed. A `promo.txt` in the folder names the photo for each role; the script's header lists them. Shots use the app's default theme and only the models testers get, and your own preferences come back afterwards.
- `src/stills/regions.ts` says where things sit in a 1600 × 1000 capture, such as the photo at Fit or the Masks panel, so crops survive new photos.
- A capture that doesn't exist yet shows as a labelled placeholder with its name and region. The hero falls back to the README's `hero.png`.
- Stills whose id starts with `held-` wait for captures nobody has yet, such as a focus stack, and only render when named.

## Assets

The logo, the app icon's lens and the film icons are copied from `docs/` by `../web/scripts/sync-assets.mjs` before every studio session and render.

## Music

The film is silent until you add a track. Pick one at 120 BPM so the cuts land on the beat, put the licensed file in `public/audio/`, and set `musicSrc` (for example `"audio/music.mp3"`) in the compositions' `defaultProps` in `src/Root.tsx`, or pass `--props='{"cut":"explainer","musicSrc":"audio/music.mp3"}'` to `remotion render`.

## Licence

Remotion is free for individuals and companies of up to three people; larger teams need a [company licence](https://www.remotion.dev/license).
