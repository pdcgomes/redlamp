# Redlamp feature videos for Instagram and TikTok

Ten vertical videos, each about one Redlamp feature and 29.2 seconds long with Redlamp's opener. In every video Redlamp's editor, drawn in pixel art as a colourful dashboard, shows the feature step by step and then its result before and after, and the video ends with "Download free" and "redlamp.app". They are made in the promo studio (`.cursor/skills/redlamp-promo-studio/SKILL.md`) and run from the social room (`.cursor/skills/redlamp-social/SKILL.md`).

The captions, posting times and alt text are in [`docs/social/posts.json`](../social/posts.json). The social room shows them, and the Instagram publisher posts from them, so the file is the one place they change.

## Brief

| | |
| --- | --- |
| Goal | Downloads of Redlamp from redlamp.app, read as release downloads per day from the GitHub API, beside each post's views and profile visits. |
| Audience | Lightroom users, both those who edit every day and those who edit now and then, and people who use phone filter apps or other photo editors. |
| Platforms | Instagram Reels and TikTok, 9:16 at 1080 × 1920. |
| Length | 29.2 s: Redlamp's opener (10 s), then 8 bars at 100 BPM (19.2 s). |
| The message | One feature per video, shown so that it is understood at once. |
| The ask | Download free at redlamp.app. The captions add "link in bio". |
| Tone | Simple and direct (the owner, 10 October 2026). The words say what is on screen. |
| Must keep | The brand ([docs/brand/README.md](../brand/README.md)): the red is light with a source, one red light per picture, no bright point in the lamp's lens. Claims only from the README and the [Lightroom comparison](../lightroom-comparison.md). Original music only. |
| Success | Release downloads in the week after each post against the week before, and each post's views, average watch time, shares, saves and follows at 48 hours and 7 days. |

## Copy rules

The owner asked for simple, direct language: nothing that reads as written by AI, nothing whimsical, people understand at once what they are shown, and a clear call to action. For every video and caption:

- Every line says what is on screen or what the viewer gets. Features have the names photographers know.
- At most two lines on screen at once, and at most 17 characters a line, in the kit's large font at twice its size.
- No wordplay, puns, characters that talk, metaphors, rhetorical questions, "not X, it's Y" constructions or triplets for rhythm.
- No em or en dashes, exclamation marks, emoji or superlatives, and none of: seamless, effortless, unlock, elevate, game-changer, magic, level up, supercharge, revolutionary, ultimate.
- Every video ends with DOWNLOAD FREE / REDLAMP.APP.
- Captions: one sentence on what the video shows, then the standard lines (what Redlamp is, the download with "link in bio", the requirements and "It's in early development"), then three to five hashtags. A caption that names a trademark ends with the line saying Redlamp isn't affiliated with its owner.
- Claims only from the README or the Lightroom comparison, with the source named under each episode below. British spelling.

`room.py status` checks the line lengths and the banned words and punctuation in `posts.json`.

## The format

Every video opens with Redlamp's opener in pixel art, so the series looks and sounds like the rest of Redlamp's videos (the owner, 10 October 2026). It is the looks explainer's intro (`video/scripts/looks-frames.py` on the `promo/looks-explainer` branch), which redraws Introducing Redlamp's opening scene frame for frame, laid out for the vertical frame: the hook on the dark wall from the first frame, where the episode's caption stands; the lamp coming out of the dark and warming under it; the hook going as the lens settles into the logo; A RAW PHOTO EDITOR / FOR THE MAC. under the logo; then, where the hook was, the episode's title from `docs/social/posts.json` (FREE ALTERNATIVE / TO LIGHTROOM), so people know what this one is about and that it isn't one they've seen. The episodes aren't numbered, since there may be more (the owner, 10 October 2026). All of it holds for a bar to be read (the owner, 10 October 2026), then the logo and its line give way to the episode's header above the title, which stays as the caption of the episode's first bar. So the hook and the title are each seen once, and the brand's line says only what Redlamp is: the end card's DOWNLOAD FREE says the rest in every video (the owner found the word "free" used too often, 10 October 2026). The first two bars are the Introducing short's opening scene frame for frame, under its own sound; the third holds the scene's last chord, as the looks explainer and the app's welcome do: three bars of the film's 72 BPM grid, 10 s, as long as the film cut's own opening. The episode cuts in on its first hit, with the hook back in its place. Full-width lines can't sit under the lamp as they do in the 16:9 intro, where the apps' side buttons are, which is why the hook and the subtitle stand where the caption does.

The episode follows one cue sheet, `video/src/features/cues.json`: 100 BPM at 30 fps, a beat every 18 frames, a bar every 2.4 s. The times below are the episode's own, from its first frame, 6.7 s into the video.

| Bar | Time | What happens |
| --- | --- | --- |
| 1 | 0.0 s | The episode's title, held from the opener, over the pixel editor with the photo it will work on. |
| 2 to 5 | 2.4 s to 12.0 s | The feature in the pixel editor, in two to four labelled steps, one a bar. Each click, key press and slider move lands on a beat. |
| 6 | 12.0 s | The result. The pixel photo fills the stage as it was opened, then develops into the edit through an ordered dither at 13.2 s. The words say what the result shows: BEFORE AND AFTER for an edit. |
| 7 | 14.4 s | The end line, then DOWNLOAD FREE / REDLAMP.APP from 15.6 s under the lamp mark. |
| 8 | 16.8 s | The card holds. The picture and the sound fade out from 17.4 s; a feed that loops the video starts again on the hook. |

- **Picture:** the editor drawn as pixelkit's dashboards are (the DAW, the fruit music player and the system monitor in `~/src/pixelartvisuals`). The owner chose this over the editor with his real photo as more colourful and more inviting, and asked for every episode to be built this way (10 October 2026). Panels in the kit's navy, each with its accent; a pixel-art scene where the photo would be, developed by the episode's sliders at their values; the sliders as coloured meters over a live RGB histogram and an LED level; and a card for what each bar says, drawn rather than written (in E01, a plan at $0 a month, a network panel with nothing uploaded, the licence over a heatmap of commits). Bitmap capitals, one accent per meaning. The only red is the lamp's light and the editor's own red mask overlay.
- **Grid:** 216 × 384 logical pixels at ×5.
- **Safe zones:** nothing to read in the top 260 px, the bottom 480 px, or the right-hand 160 px between 700 and 1600 px down, where TikTok and Instagram put their own controls.
- **Header:** a strip with Redlamp's safelight mark and the feature: REDLAMP · SUBJECT MASK.
- **Values on screen** are the edit's own: the sliders move to the values the scene is developed with, so what they read and what the picture does match.
- **Covers:** the opener's frame 100, 3.3 s in (each post's `coverMs`, 3333): the hook over the lamp at its warmest, chosen as the cover on both platforms. Its words sit inside the middle 3:4 of the frame, which Instagram's profile grid shows.
- **Results** are pixel art too, so the whole video is one picture. Redlamp's renders of the owner's photos, planned under [Real results](#real-results), are kept for a version of an episode with the real photo, as E01 has.

### How a video is built

E01 sets the template (`scripts/features/boards/e01.py`), and every episode is built the same way in `video/`:

- **The board**, `scripts/features/boards/<episode>.py`, draws the video with the shared pieces in `scripts/features/world.py`. Its `frame(c, beat, hook)` draws any moment from the beat, and its `sounds()` lists each sound on screen as a beat, a kind and a pan, both timed on the cue sheet. The storyboard's eight panels are moments of `frame()`. The dashboard's pieces are in `world.py`'s dashboard section: `scene()` develops a pixel-art scene, such as `dusk()`, with the episode's slider values, and `photo_panel()`, `histogram()`, `meters()` and `card()` draw the photo, its histogram, the sliders and the cards.
- **A version with the real photo**, if one is wanted, is a board of its own, as `boards/e01-photo.py` is, with the episode's beats, words and sounds. Its result, through `scripts/features/results.py`, is rendered by the `redlamp` CLI (`$REDLAMP_CLI`, or `build/cli/redlamp`) from the owner's sidecar beside the raw: AFTER with his edit, BEFORE with its crop alone, and each step of a drag with the sliders moved so far, so the pixel photo changes as the real one does. Renders are kept in `public/features/<board>/results/` and made again only when something that went into them changes. It plays in Studio with `"episode": "e01-photo"` and renders with `--episode=e01-photo`.
- **The frames**, `npm run features-frames -- --episode e01`: every frame drawn by pixelkit at 216 × 384, or at 1080 × 1920 while a real photo is on screen, where it shows at full resolution through the ordered dither that resolves it out of the pixel photo. A picture that comes out the same as another is written once, and `frames.json` lists each hook's frames.
- **The score**, `npm run features-score -- --episode e01`: the theme in the series' arrangement, synthwave, with the episode's sounds on their frames, and the opener's sound with the theme's lead-in over its end; with `score.json` for the storyboard sheet and a cue sheet of every sound for `scripts/score-report.py`.
- **The opener** is `opener()` in `scripts/features/world.py`, timed by the cue sheet's `opener` section: three bars at 72 BPM, the first two (`scene`) the short's opening scene, which `scripts/features-score.py` checks against `src/introducing/cuts.json`, and the beats the hook goes, the lens settles, the brand's line and the title come in, and the header takes over. The frames script draws it before each episode, with the episode's hook, its title and its feature.
- **The composition**, `FeatureVideo` in Remotion Studio's Features folder, plays the frames and the two scores, with `episode`, `hook`, `score`, `opener` and `guides` props. With `opener` off it plays the episode alone, on its cue sheet's own frames, as `scripts/storyboard.mjs` and the review stills expect.
- **The render**, `npm run features -- --episode=e01 [--hook=a] [--draft]`, writes `~/src/redlamp-social/renders/<the post's file>` and its cover, once the owner has approved the cut. A draft is half the size, named `…-draft.mp4`.

## Sound

One theme for the series, in the same shape in every video so the series sounds like one thing: a two-bar riff in D minor that moves from the first frame and builds to the result, the drop at 12.0 s, with the same sting on the drop (the riff's head over struck glass) and the same ending. The owner asked for a catchy motif that isn't aggressive, then turned down the first theme, a sweet tune in F major on a soft square lead over felt piano in half time, as cheesy and short of energy. Of the D minor theme's arrangements he chose a synthwave one, keeping the opener's own sound (all 10 October 2026).

- **Shape:** under the hook, sixteenths and a beat held back; the riff from the first step; the full beat from the third; a roll and a riser through the fourth, the rhythm stopping half a beat before the drop while the riser and the hit's own reverb swell on into it; the drop, the loudest bar; the closing phrase from the end line, through A7 to D minor on the last hit; and the last chord dying away as the picture fades.
- **Arrangement:** synthwave, in `video/scripts/features-theme.py`: supersaw pads, a plucked arpeggio in sixteenths with an echo a dotted eighth later, opening through the build, and a bass jumping the octave in eighths. A kick muffled as if through a wall plays under the hook, then on 1 and 3 from the first step and on every beat from the third, with a gated snare on 2 and 4 and a fill of falling toms into the stop. The riff is on a saw lead with vibrato on its long notes and an echo either side, its head doubled an octave up on the drop. Drive (electronic: four on the floor, offbeat chord stabs, the riff on two detuned saws) and pulse (cinematic, after the star promo: spiccato strings, taiko, a Shepard tone into the drop and low brass on it), which it was chosen over, stay in the same file. The sketches are `video/public/features/theme-<arrangement>.wav`.
- **Sync:** every click, key and slider move on screen has its sound on the same frame. The sound comes from the cue sheet, as the picture does.
- **Each video's score** is synthwave, with the video's own clicks, ticks and keys on the frames their pictures land on (`video/scripts/features-score.py`). It writes drive and pulse too, which the composition's `score` prop plays (`score-drive`, `score-pulse`).
- **The opener's sound** is the Introducing short's own score under its opening scene, sample for sample, then its last chord held for the third bar, drawn by `scripts/score.py` in the same room and at the same level, with a breath of air rising into the episode's first hit. It is kept as far below the episode as the short's opening sits below the rest of the short (3 LU). Over its last 2.4 s comes the theme's lead-in, a bar of the theme at its own tempo, so the cut into the episode isn't abrupt (the owner, 10 October 2026). The arpeggio grows out of nothing on the notes the held D major chord and the theme's D minor share (A, D and E), over a kick muffled further than the first bar's and a drone on D and A, with the first hit's reverb swelling up into it, while the held chord eases down by 3 dB. The music turns to minor on the hit, and the drone carries on under the first bar until the bass comes in. The lead-in is rendered with the arrangement, so `video/scripts/features-score.py` writes each episode's opener beside its score: `opener.wav` for `score.wav`, and `opener-<arrangement>.wav` for the others.
- **Mastering:** each video, opener and all, is mastered to −14 LUFS integrated with a true peak at or under −1 dBFS (the limiter is set at −1.2 dBFS, which its soft knee can overshoot), so the episode's score sits at about −13.1 LUFS; no more than about a quarter of the energy is under 60 Hz, which phones don't play.
- **Audio name:** on both platforms, "Redlamp theme".

## The episodes

Each episode has five hooks. Hook A is posted first on both platforms. Hook B goes out two days later on Instagram as a trial reel, which only people who don't follow the account see, so the two hooks can be compared.

### E01 Free alternative to Lightroom

- **Shows:** a free, open-source raw photo editor for Mac, with no subscription and no cloud.
- **For:** everyone, and people paying a monthly subscription for photo editing.
- **Source:** README, Support Redlamp ("Redlamp is free, with no subscription and no cloud") and Goals 8 (open source, MPL-2.0); Why Redlamp (the panel layout, slider names and keyboard shortcuts carry over).
- **Posts:** Tue 27 Oct, 18:00 (A); Thu 29 Oct, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | A FREE RAW PHOTO / EDITOR FOR MAC |
| b | NO SUBSCRIPTION. / NO CLOUD. |
| c | EDIT RAW PHOTOS / FOR FREE |
| d | FREE, OPEN SOURCE / RAW EDITOR |
| e | FREE, AND WORKS / LIKE LIGHTROOM |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The dashboard: a pixel-art dusk as opened (DUSK.ARW), its histogram and level, and the four sliders as coloured meters at zero. | FREE ALTERNATIVE TO LIGHTROOM (the title, held from the opener) | A deep hit on the first frame, then the arpeggio over a kick muffled as if through a wall. |
| 2 | 2.4 s | The pointer drags EXPOSURE to the edit's value and the dusk brightens; the PLAN card: $0 PER MONTH. | NO SUBSCRIPTION | The riff starts; a slider tick on each beat of the drag. |
| 3 | 4.8 s | HIGHLIGHTS and SHADOWS move to the edit's values; the NETWORK card: 0 B uploaded, ON YOUR MAC. | NO CLOUD | The riff; ticks. |
| 4 | 7.2 s | VIBRANCE moves to the edit's value and the dusk gains colour; the SOURCE card: MPL-2.0 over a heatmap of commits. | OPEN SOURCE | The riff's answer; the full beat comes in. |
| 5 | 9.6 s | The backslash key shows the dusk before, then after. | FAMILIAR LAYOUT / AND SHORTCUTS | A key click on the beat; falling toms into the stop. |
| 6 | 12.0 s | The dusk fills the stage as opened, then develops into the edit at 13.2 s. | BEFORE AND AFTER | The drop and the sting; sparkles on the flip. |
| 7 | 14.4 s | The end card. | RAW PHOTO EDITOR / FOR MAC, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E02 Subject mask

- **Shows:** the person selected in one click by an AI mask that runs on the Mac, the mask inverted to select the background, and the background darkened so the subject stands out.
- **For:** people who edit now and then, portrait and family photographers, people used to phone filter apps.
- **Source:** README, Masking: the AI masks (Subject, "with Apple Vision's built-in models and nothing to download"), Invert ("as Lightroom's"), Subject edges "solved per pixel too ..., which brings back stray hairs", and the mask presets (Darken Background); Models on demand ("Every model runs on the Mac; photos are never uploaded").
- **Photo:** the owner's son at a colour run (`IMG_3557.jpg`), in mirrored sunglasses against a soft park background. It replaces the sky mask on trees, whose result wasn't good enough to show (the owner, 10 October 2026).
- **Posts:** Fri 30 Oct, 18:00 (A); Sun 1 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | SELECT THE PERSON / IN ONE CLICK |
| b | AI SUBJECT MASK / ON YOUR MAC |
| c | MAKE YOUR SUBJECT / STAND OUT |
| d | ONE CLICK SELECTS / THE SUBJECT |
| e | MASKS THAT FIND / PEOPLE FOR YOU |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The dashboard: the photo as opened, labelled as its raw (IMG_3557.DNG), in pixel art, its histogram and level, and the Masks panel with SUBJECT, SKY, BACKGROUND and PEOPLE in their accents, and the mask's INVERT and EXPOSURE dim until there is a mask. | SUBJECT MASK (the title, held from the opener) | A deep hit on the first frame, then the arpeggio over a kick muffled as if through a wall. |
| 2 | 2.4 s | The pointer comes in and clicks SUBJECT on the bar's third beat; the AI MODEL card: DOWNLOAD 0 B, ON YOUR MAC, its chip running from the click. | CLICK SUBJECT | The riff starts; a click on SUBJECT. |
| 3 | 4.8 s | The red overlay fills up the boy from his shirt to his hair in three sixteenths, the background clear; the EDGE ×3 card magnifies the edge of his hair under it. | SELECTED / ACCURATELY | Four soft blips rising as the overlay fills. |
| 4 | 7.2 s | INVERT is clicked on the bar's second beat; the overlay moves to the background, and the INVERT card's mask thumbnail turns over from SUBJECT to BACKGROUND. | INVERT IT FOR / THE BACKGROUND | The riff's answer and the full beat; a click on INVERT. |
| 5 | 9.6 s | The mask's EXPOSURE goes down to −1.00, a step a beat; the background darkens and the boy stands out, and the LEVEL card shows the background's level falling below his. | DARKEN THE / BACKGROUND | A click on the knob and a slider tick a beat; toms fall into the stop. |
| 6 | 12.0 s | The photo fills the stage as opened, then develops into the edit at 13.2 s: the background a stop darker, the boy as he was. | BEFORE AND AFTER | The drop and the sting; a tick on the flip. |
| 7 | 14.4 s | The end card. | AI MASKS THAT RUN / ON YOUR MAC, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E03 Film looks

- **Shows:** looks of 30 real film stocks, built from each film's datasheet.
- **For:** people who use film filters and presets, and film photographers.
- **Source:** README, Film simulations (36 looks from 30 stocks, "built from the data in each manufacturer's own datasheet: characteristic curves, spectral sensitivities and dye spectra") and its trademark line; Lightroom comparison, film stock simulations (Beyond: "Lightroom's film-inspired presets don't replicate particular films").
- **Posts:** Tue 3 Nov, 18:00 (A); Thu 5 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | LOOKS OF 30 REAL / FILM STOCKS |
| b | 36 FILM LOOKS / FROM DATASHEETS |
| c | PORTRA, TRI-X AND / CINESTILL LOOKS |
| d | FILM LOOKS FOR / YOUR RAW PHOTOS |
| e | FILM LOOKS MADE / FROM FILM DATA |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with a photo open and the Base Look list showing film names. | FILM LOOKS (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | A datasheet's characteristic curve draws itself on a chart. | BUILT FROM EACH / FILM'S DATASHEET | The motif starts; a soft tone rising with the curve. |
| 3 | 4.8 s | PORTRA 400 is chosen; the photo warms. | PORTRA 400 | A blip as the look applies. |
| 4 | 7.2 s | TRI-X 400, then CINESTILL 800T two beats later. | TRI-X 400, then CINESTILL 800T | A blip for each; the drums come in. |
| 5 | 9.6 s | VELVIA 50, then HP5 PLUS. | VELVIA 50, then HP5 PLUS | A blip for each. |
| 6 | 12.0 s | The pixel photo in the five looks, one a beat. | FIVE FILM LOOKS | The sting, then a blip a beat. |
| 7 | 14.4 s | The end card. | 36 FILM LOOKS / FROM 30 STOCKS, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E04 Lightroom shortcuts

- **Shows:** Lightroom Classic's keyboard shortcuts, panel order and slider names, working in Redlamp.
- **For:** Lightroom users, especially those who edit from the keyboard.
- **Source:** README, Goals 1 (the Develop module's layout, panel order, slider names, ranges and defaults, and single-key shortcuts carry over); Workspace ("Lightroom Classic's keyboard shortcuts: 98 actions on 96 key bindings"); Keyboard shortcuts (R crop, K brush, \ before and after, V black and white).
- **Posts:** Fri 6 Nov, 18:00 (A); Sun 8 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | SAME SHORTCUTS / AS LIGHTROOM |
| b | LIGHTROOM LAYOUT, / FREE ON MAC |
| c | LIGHTROOM USERS: / YOUR KEYS WORK |
| d | 98 LIGHTROOM / SHORTCUTS |
| e | PANELS AND KEYS / LIKE LIGHTROOM |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor, with a keyboard under it. | LIGHTROOM SHORTCUTS (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | R is pressed; the crop frame appears. | R  CROP | A key click; each key plays a note of the motif. |
| 3 | 4.8 s | K is pressed; the brush ring appears. | K  BRUSH | A key click and the motif's next note. |
| 4 | 7.2 s | Backslash is pressed; the photo shows before, then after. | \  BEFORE / AFTER | A key click; the drums come in. |
| 5 | 9.6 s | V is pressed; the photo turns black and white. | V  BLACK & WHITE | A key click. |
| 6 | 12.0 s | The editor's panels in Lightroom's order, then its shortcut list at 13.2 s, as dashboard panels. | SAME PANEL ORDER, then 98 SHORTCUTS | The sting. |
| 7 | 14.4 s | The end card. | FAMILIAR LAYOUT / AND SHORTCUTS, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E05 Presets and LUTs

- **Shows:** Lightroom develop presets dropped into Redlamp, with a report of what came across, and LUTs imported too.
- **For:** Lightroom users with presets they made or bought.
- **Source:** README, Workspace, Recipes: "Lightroom develop presets (`.xmp`) import too, one, several or a folder at a time, by the menu or by dropping them on the panel, with a report of what came across exactly, approximately or not at all", and `.cube`, `.3dl` and HaldCLUT import.
- **Posts:** Tue 10 Nov, 18:00 (A); Thu 12 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | BRING YOUR / LIGHTROOM PRESETS |
| b | YOUR .XMP PRESETS / IMPORT HERE |
| c | IMPORT LIGHTROOM / PRESETS AND LUTS |
| d | DROP IN YOUR / .XMP PRESETS |
| e | LUTS AND PRESETS / IN ONE PANEL |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with the Recipes panel open, and three .XMP files beside it. | PRESETS AND LUTS (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | The pointer drags the files onto the Recipes panel. | DROP IN .XMP / PRESETS | The motif starts; a soft drop sound on the beat. |
| 3 | 4.8 s | The import report: settings marked EXACT, APPROXIMATE and NOT AT ALL. | IT SHOWS WHAT / CAME ACROSS | A tick for each row. |
| 4 | 7.2 s | A .CUBE file is dropped and joins the list. | .CUBE AND .3DL / LUTS TOO | A drop sound; the drums come in. |
| 5 | 9.6 s | A preset is clicked; the photo changes. | CLICK TO APPLY | A click on the beat. |
| 6 | 12.0 s | The pixel photo with an imported preset, before, then after at 13.2 s. | BEFORE AND AFTER | The sting. |
| 7 | 14.4 s | The end card. | PRESETS AND LUTS / IMPORT, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E06 Folders

- **Shows:** no import step and no catalogue: a folder opens and its photos are there; edits are saved next to each photo, and the original is never changed.
- **For:** Lightroom Classic users who manage a catalogue, and anyone worried about their originals.
- **Source:** README, Why Redlamp ("Redlamp is an editor, not a catalog"); Workspace, Folders ("Nothing on disk is moved or changed") and the sidecar next to each photo (`IMG_1234.ARW.redlamp`); Measured performance (all 50,000 photos listed in 209 ms).
- **Posts:** Fri 13 Nov, 18:00 (A); Sun 15 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | NO IMPORT STEP. / OPEN A FOLDER. |
| b | EDITS SAVED NEXT / TO YOUR PHOTOS |
| c | NO CATALOGUE. / JUST YOUR FOLDERS |
| d | OPEN A FOLDER / AND START EDITING |
| e | YOUR ORIGINALS / STAY UNTOUCHED |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with an empty filmstrip and the Folders panel's + button. | FOLDERS (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | The pointer clicks +; a folder is added. | ADD A FOLDER | The motif starts; a click on the beat. |
| 3 | 4.8 s | The filmstrip fills at once, with a readout: 50,000 PHOTOS · 0.2 S. | 50,000 PHOTOS / LISTED IN 0.2 S | A quick run of soft ticks as the thumbnails arrive. |
| 4 | 7.2 s | A file list: after an edit, IMG_1234.ARW.REDLAMP appears next to IMG_1234.ARW. | EDITS SAVED NEXT / TO THE PHOTO | A soft click; the drums come in. |
| 5 | 9.6 s | IMG_1234.ARW is marked UNCHANGED. | THE ORIGINAL IS / NEVER CHANGED | The motif's answer. |
| 6 | 12.0 s | The Folders panel and the filmstrip full of the folder's photos, as dashboard panels. | YOUR FOLDERS, / AS THEY ARE | The sting. |
| 7 | 14.4 s | The end card. | YOUR ORIGINALS / ARE NEVER CHANGED, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E07 Speed

- **Shows:** a slider change rendering in 1.8 ms and a 24 MP raw opening in 0.16 s, measured on an M1 Ultra.
- **For:** people with large shoots, and anyone whose editor feels slow.
- **Source:** README, the performance card (1.8 ms to render a slider change and 160 ms to open a 24 MP raw, on an Apple M1 Ultra with a Release build), drawn from `docs/performance/history.jsonl`; Goals 4. The figures are read again from `docs/performance` before the video renders and before it posts.
- **Posts:** Tue 17 Nov, 18:00 (A); Thu 19 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | A SLIDER CHANGE / RENDERS IN 1.8 MS |
| b | A 24 MP RAW OPENS / IN 0.16 SECONDS |
| c | 1.8 MS PER / SLIDER CHANGE |
| d | NATIVE ON / APPLE SILICON |
| e | OPEN A RAW / IN 0.16 S |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with a photo open, the EXPOSURE slider, and a readout: RENDER 1.8 MS. | SPEED (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | The pointer drags EXPOSURE up to +1.00; the photo follows on each beat. | DRAG A SLIDER | The motif starts; a slider tick a beat. |
| 3 | 4.8 s | The drag comes back down to −0.50; the readout stays at 1.8 MS. | 1.8 MS PER CHANGE | Ticks. |
| 4 | 7.2 s | A raw opens from the filmstrip, with a readout: OPEN 0.16 S. | A 24 MP RAW OPENS / IN 0.16 S | A click; the drums come in. |
| 5 | 9.6 s | The readouts, with where they were measured. | MEASURED ON / AN M1 ULTRA | The motif's answer. |
| 6 | 12.0 s | The pixel photo as EXPOSURE moves, a render a beat. | THE PHOTO FOLLOWS / THE SLIDER | The sting, then a tick a beat. |
| 7 | 14.4 s | The end card. | BUILT FOR / APPLE SILICON, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E08 Camera recipes

- **Shows:** camera-style recipes built from Fujifilm-style recipe cards, previewed by hovering, applied with a click, then set with Amount.
- **For:** Fujifilm shooters and people who follow film recipes.
- **Source:** README, Workspace, Recipes ("39 bundled recipes in eight groups, including camera-style ones built from Fujifilm-style recipe cards. Hover to preview, click to apply, then adjust the recipe's Amount"); Screenshots (Chrome Street on a Fujifilm X-T3 RAF); Lightroom comparison, camera recipe cards (Lightroom: No). Typing a card in is only in the Recipe Lab, which isn't in the app people download, so the video doesn't show it. Cards use Redlamp's own slot names, and camera makers' film simulation names don't appear in the app ([camera-card-mapping.md](../recipes/camera-card-mapping.md)), so none appear in the video.
- **Posts:** Fri 20 Nov, 18:00 (A); Sun 22 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | CAMERA-STYLE / RECIPES, BUILT IN |
| b | FUJIFILM-STYLE / RECIPES ON RAWS |
| c | HOVER TO PREVIEW / A FILM RECIPE |
| d | FILM RECIPES / FOR ANY RAW |
| e | RECIPES FROM / CAMERA CARDS |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with a Fujifilm raw open and the Recipes panel's camera recipes listed. | CAMERA RECIPES (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | The pointer moves over CHROME STREET; the photo previews it. | HOVER TO PREVIEW | The motif starts; a soft tick as the preview changes. |
| 3 | 4.8 s | The pointer moves over BRIGHT SLIDE, then CINEMA TEAL, two more of the camera recipes; the preview follows. | ONE RECIPE / AT A TIME | A tick for each. |
| 4 | 7.2 s | CHROME STREET is clicked. | CLICK TO APPLY | A click; the drums come in. |
| 5 | 9.6 s | The recipe's AMOUNT moves from 100 to 70. | SET THE AMOUNT | Slider ticks. |
| 6 | 12.0 s | Chrome Street on the pixel photo, before, then after at 13.2 s. | BEFORE AND AFTER | The sting. |
| 7 | 14.4 s | The end card. | CAMERA RECIPES / FOR YOUR RAWS, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E09 Remove by name

- **Shows:** the name of what to remove typed in, such as power lines; Redlamp finds and removes them, on the Mac, with no credits.
- **For:** people who edit now and then, and travel and street photographers.
- **Source:** Lightroom comparison, find and remove things named in words (Lightroom: No; Redlamp: Done, RM-08: "Trash, signs, cables and more, found anywhere in the photo"); README, In progress, Remove ("Find outlines things named in words ... power lines, cables, signs, traffic cones ...", "Remove All removes them all"); Goals 6 ("running on the device with no cloud and no credits"). The README still lists Remove under In progress: check its status before this video is built.
- **Posts:** Tue 24 Nov, 18:00 (A); Thu 26 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | FIND AND REMOVE / POWER LINES |
| b | TYPE WHAT TO / REMOVE |
| c | REMOVE CABLES, / SIGNS AND CONES |
| d | REMOVE ALL / POWER LINES |
| e | NO CREDITS / TO REMOVE THINGS |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with a street photo crossed by power lines, and the Remove panel's FIND field. | REMOVE BY NAME (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | POWER LINES is typed into FIND. | TYPE WHAT TO / REMOVE | The motif starts; key clicks on the beats. |
| 3 | 4.8 s | Each power line is outlined; a count reads 4 FOUND. | REDLAMP FINDS / EACH ONE | A blip for each outline. |
| 4 | 7.2 s | The pointer clicks REMOVE ALL; the lines go, one a beat. | REMOVE ALL | A click, then a soft sound a line; the drums come in. |
| 5 | 9.6 s | The clean photo. | DONE ON YOUR MAC | The motif's answer. |
| 6 | 12.0 s | The pixel street, before, then after at 13.2 s. | BEFORE AND AFTER | The sting. |
| 7 | 14.4 s | The end card. | ON YOUR MAC. / NO CREDITS. Then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### E10 Focus stacking

- **Shows:** Redlamp finding a focus stack and merging it into one sharp photo that edits like a raw.
- **For:** macro, product and landscape photographers.
- **Source:** README, Goals 6 (focus stacking "is something Lightroom doesn't offer at all"); Focus stacking ("Stacks are found for you", the "Focus stack detected: N frames" banner with Merge, "The result develops like a raw"). The number of frames on screen and in hook B must match the real stack used for the result.
- **Posts:** Fri 27 Nov, 18:00 (A); Sun 29 Nov, Instagram trial reel (B).

| ID | Hook |
| --- | --- |
| a | FOCUS STACKING, / BUILT IN |
| b | 25 FRAMES INTO / ONE SHARP PHOTO |
| c | STACK FOCUS / IN ONE CLICK |
| d | LIGHTROOM CAN'T / FOCUS STACK |
| e | SHARP FROM FRONT / TO BACK |

| Bar | Time | Picture | Words | Sound |
| --- | --- | --- | --- | --- |
| 1 | 0.0 s | The editor with a filmstrip of 25 near-identical close-ups of a flower. | FOCUS STACKING (the title, held from the opener) | A deep hit on the first frame, then sixteenths under a beat held back. |
| 2 | 2.4 s | A banner slides in: FOCUS STACK DETECTED · 25 FRAMES · MERGE. | IT FINDS THE / STACK FOR YOU | The motif starts; a soft chime with the banner. |
| 3 | 4.8 s | The pointer clicks MERGE. | CLICK MERGE | A click on the beat. |
| 4 | 7.2 s | Frames, each sharp in a different band, combine into one, a band a beat. | ONE SHARP PHOTO | A soft blip a band; the drums come in. |
| 5 | 9.6 s | Sliders move on the merged photo. | EDIT IT LIKE / A RAW | Slider ticks. |
| 6 | 12.0 s | One frame of the stack, then the merged photo at 13.2 s. | ONE FRAME, then 25 FRAMES MERGED | The sting. |
| 7 | 14.4 s | The end card. | FOCUS STACKING / IN YOUR EDITOR, then DOWNLOAD FREE / REDLAMP.APP | The theme's last phrase. |
| 8 | 16.8 s | The card holds and fades. | DOWNLOAD FREE / REDLAMP.APP | The last chord dies away. |

### Reserves

Two of these go out on Tue 1 Dec and Fri 4 Dec, chosen from the first eight posts' numbers.

- **Command palette:** type a setting and its value, such as EXPOSURE 0.7, and it's set (README, Workspace, Command palette).
- **Masks for eyes, lips and teeth:** People masks and their parts (README, Masking).
- **Film effects:** halation, grain, light leaks and frames (README, Film simulations; Lightroom comparison).
- **All ten results:** a cut of the ten videos' results.

## Schedule

All times are 18:00 London time. The second hook of each goes out two days later on Instagram as a trial reel.

| Date | Video | Platforms |
| --- | --- | --- |
| Tue 27 Oct | E01 Free alternative to Lightroom | Instagram, TikTok |
| Fri 30 Oct | E02 Subject mask | Instagram, TikTok |
| Tue 3 Nov | E03 Film looks | Instagram, TikTok |
| Fri 6 Nov | E04 Lightroom shortcuts | Instagram, TikTok |
| Tue 10 Nov | E05 Presets and LUTs | Instagram, TikTok |
| Fri 13 Nov | E06 Folders | Instagram, TikTok |
| Tue 17 Nov | E07 Speed | Instagram, TikTok |
| Fri 20 Nov | E08 Camera recipes | Instagram, TikTok |
| Tue 24 Nov | E09 Remove by name | Instagram, TikTok |
| Fri 27 Nov | E10 Focus stacking | Instagram, TikTok |
| Tue 1 Dec and Fri 4 Dec | Two reserves | Instagram, TikTok |

Each group of four is approved by the Friday before it starts: 23 October, 6 November and 20 November.

## Posting

- **Approval:** a post goes out only when the owner has approved its cut (in Remotion Studio, then Approve cut in the social room) and the post itself (Approve post in the room).
- **Instagram:** the publisher posts each approved post at its time through Instagram's API, uploading the video from the Mac. It posts the trial reels too, and reads each post's numbers and comments. Replies are drafted in the room and sent only once the owner approves each one.
- **TikTok:** TikTok's API can't post publicly for us. Posts from an app TikTok hasn't audited stay private, and its guidelines rule out a tool that uploads to the accounts you or your team manage. So the owner schedules each post in TikTok Studio on the web, using the caption and cover the room gives, and marks it Scheduled, then Posted with its link. TikTok's numbers come from TikTok Studio at each review.

## Real results

Superseded on 10 October 2026, when the owner chose the dashboard look, whose results are pixel art ([The format](#the-format)). This plan is kept for a version of an episode with the real photo, as E01 has (`boards/e01-photo.py`).

Every result is a photo the owner took, rendered by Redlamp with the `redlamp` CLI and shown at full resolution where the pixel photo was, so it is the best-looking picture in the video. A window capture is used only where the app itself is the result (E04 and E06), taken at full size with `scripts/capture-promo.sh` and shown, not cropped from. Captures and README images already in the repository stand in on the storyboards until the owner's photos arrive.

The owner's photos go in `~/src/redlamp-social/photos/`, outside the repository, where agents can read them (they can't read `~/Pictures` or `~/Downloads`). Each one keeps its Redlamp sidecar if it has an edit, so the result is his edit.

| Video | Photo | Result |
| --- | --- | --- |
| E01 Free alternative to Lightroom | The cosplayer with orange hair: the raw, `DSC02372.ARW`, and his edit in Redlamp beside it | Before (the raw with the edit's crop alone) and after (the edit), and every step of the drags. Until his edit is saved, a stand-in: his JPEG's crop, found by matching it against the whole frame, with Exposure +1.00, Highlights −40, Shadows −60 and Vibrance +30 |
| E02 Subject mask | The owner's son at a colour run (`IMG_3557.jpg`) | The background darkened with an inverted Subject mask, before and after |
| E03 Film looks | The street-food cook at the grill (`DSC03230 (2).jpg`) | The photo in Portra 400, Tri-X 400, CineStill 800T, Velvia 50 and HP5 Plus |
| E04 Lightroom shortcuts | The man in the green shirt (`DSC03301 (2).jpg`) for the black-and-white step, and a capture of the app | The app window, then its shortcut list |
| E05 Presets and LUTs | The two girls on a scooter (`DSC03201 (2).jpg`), and a `.xmp` preset the owner made | The photo with the imported preset, before and after |
| E06 Folders | All of the owner's photos in one folder, as the filmstrip | The Folders panel and the filmstrip, captured from the app |
| E07 Speed | The shopkeeper among her jars (`DSC01584 (2).jpg`), and a 24 MP raw for the open step | The photo as Exposure moves, one real render a beat |
| E08 Camera recipes | A Fujifilm raw: the README's X-T3 raw `AFXT2720.RAF`, or one of the owner's | Chrome Street on it, before and after |
| E09 Remove by name | The flooded street with power lines (`DSC01898.jpg`) | Before and after the power lines are removed |
| E10 Focus stacking | The snail on a leaf (`DSC00983.jpg`) as the subject; the real result needs a focus-bracketed series | One frame against the merged stack |

The photos are the owner's JPEGs, 1365 × 2048 from a Sony α7R V and 1536 × 2048 from an iPhone, all portrait, so they crop to 9:16 without losing much. The raws and their Redlamp edits would give the sharpest results and keep "raw photo editor" literally true; the JPEGs work until then. The watch (`DSC00959.jpg`), the leaf with a drop (`DSC00973.jpg`) and the man on the motorbike (`DSC03213.jpg`) are spare. The dancer can still replace any of these.

## Review notes

### E01, 10 October 2026

The first cut, for the owner's review in Studio, with hook A or B and the stand-in edit. The owner turned down its felt score as cheesy and short of energy; the second cut has the new theme, in drive and in pulse.

- **Picture:** every frame was drawn with no warning from the kit or the safe zones (179 pictures for 576 frames, both hooks), and stills with the `guides` prop show every word clear of the apps' zones in each bar. Captions are 70 px tall. The hook's seven words are on screen for 2.4 s, under the 2.6 s the checklist's rule of thumb asks for; DOWNLOAD FREE / REDLAMP.APP stays 3.6 s. The storyboard sheet (`out/features/e01-storyboard.jpg`) shows every cue's frame over the score's level.
- **Sound, first cut (felt):** −14.0 LUFS integrated and a true peak of −1.8 dBFS by ffmpeg; the result's bar the loudest (−11.9 LUFS).
- **Sound, second cut:** by ffmpeg, drive measures −14.0 LUFS with a true peak of −1.2 dBFS, and pulse −13.9 LUFS and −1.1 dBFS. Both climb to the drop, the loudest bar: drive from −18.8 LUFS under the hook to −12.0 on the drop, pulse from −20.8 to −11.2. Under 60 Hz sits 23% of drive's energy and 22% of pulse's, with 33% and 22% in the mids. Above 2.5 kHz the presses, ticks, keys and the flip land within 5 ms of their beats; two button releases are covered by a hat or the watch's tick on the same sixteenth. In both drafts the audio is 0 ms from the score.
- **With the opener:** 29.2 s, its first 300 frames the pixel opener with its hold and title (464 pictures for both hooks' 876 frames, with no warning from the kit or the safe zones). On screen, "free" is in the hook, the title and DOWNLOAD FREE, where it was in six places before. The opener's sound crosses into the held chord at the bar line with no step in the waveform. The episode's score starts exactly 300 frames (10 s) in, by cross-correlating each draft's audio with it. The whole measures −14.1 LUFS in both drafts by ffmpeg, with true peaks of −1.3 dBFS (drive) and −1.4 dBFS (pulse).
- **Not checked:** how it plays at full speed and size, and how the ticks and the key sit in the mix on a phone. Those are for the owner's viewing in Studio.

### E01's UI variation, 10 October 2026

The owner found the pixelartvisuals pieces (the DAW, the fruit music player, the system monitor) more colourful and interesting than the editor with the real photo, and asked to explore a variation built from them. `video/scripts/features/boards/e01-ui.py` (now `boards/e01.py`) keeps E01's beats, words and sounds, and draws the editor as one of those dashboards: the panels in the kit's navy with an accent each, a pixel-art dusk in place of the photo, developed by E01's four sliders at E01's values, the sliders as coloured meters over a live RGB histogram and an LED level, and a card for what each bar says (a plan at $0 a month, a network panel with nothing uploaded, the licence over a heatmap of commits). The result is the dusk before and after, filling the stage, under BEFORE AND AFTER. It played in Studio as `"episode": "e01-ui"` until it became E01's cut (below). Its frames raise no warning (773 pictures for 876 frames), and its draft measures −14.1 LUFS with a true peak of −1.3 dBFS.

### E01's lead-in, 10 October 2026

The owner found the cut from the opener's sound into the theme too abrupt and asked for a ramp. Measured in 200 ms steps, the opener's held chord was a steady bed at about −18.5 dB; at the cut it stopped within three frames, and after the first hit the theme's first bar fell to −26 to −31 dB between its muffled kicks, its pads 14 dB under the kicks and no bass until the second bar. The theme's lead-in now rises through the opener's last bar into the hit, and the drone keeps the theme's first bar within about 2 dB of the held chord between kicks (−19 to −21 dB). The 400 ms either side of the cut measure −14.8 and −15.0 LUFS, where they were −17.4 and −16.4. With the opener, each arrangement measures −14.0 LUFS with a true peak of −1.1 to −1.2 dBFS; the episode's sounds still land on their beats (median 0.0 ms; one button release reads 24 ms early, under an arpeggio note on the same sixteenth, as one did before); and 18.8% of the score's energy is under 60 Hz.

### E01 approved, 10 October 2026

The owner approved E01's cut, in the dashboard look with the synthwave score and the lead-in, as the series' first reel: hook A posts on Tue 27 Oct and hook B goes out as an Instagram trial reel on Thu 29 Oct. Its videos and covers are rendered in `~/src/redlamp-social/renders/` (`e01-a.mp4`, `e01-b.mp4`).

### E02, 10 October 2026

The first cut, in E01's dashboard look with the synthwave score and the lead-in, for the owner's review in Studio, with hook A or B (`boards/e02.py`). The photo is the owner's `IMG_3557.jpg` in pixel art, cropped about the boy to each panel and locked to 32 of its own colours, found by clustering its pixels in Oklab, so the lenses' rainbow and the frame's cyan keep a colour each. The overlay is Apple Vision's Subject mask for the photo, and the darkened background is the mask's Exposure, −1.00, applied to the photo in linear light. Redlamp's Darken Background preset uses −0.50, which barely shows at this size. The owner asked for the photo to be labelled as a raw rather than a JPEG, so it reads IMG_3557.DNG, as his iPhone's raw would be, and for bar 3 to read SELECTED / ACCURATELY in place of HE IS SELECTED, / HAIR INCLUDED (10 October 2026).

- **Picture:** every frame was drawn with no warning from the kit or the safe zones (483 pictures for both hooks' 876 frames, the opener's included), and the storyboard drawn with the covered zones outlined (`--zones`) shows every word clear of them. Each click comes after the words that ask for it, SUBJECT two beats into its bar and INVERT one beat in, where E01's presses land with its words. The cards come up over the park at the photo's left, clear of the boy. The LEVEL card measures the pixel photo: the background's brightness falls from 0.38 to 0.27 while the boy's stays at 0.34.
- **Sound:** the score measures −13.1 LUFS, and the whole video −14.0 LUFS with a true peak of −1.1 dBFS (drive and pulse −14.0 LUFS and −1.2 dBFS). It climbs from −16.3 LUFS under the hook to −10.8 on the drop, with 20.9% of its energy under 60 Hz. The overlay's fill has a sound of its own, `fill` in `features-score.py`: four blips climbing G minor a sixteenth apart, an octave over the arpeggio, each about −31 dBFS, as loud as a click and 7 to 8 dB under the music in their band. Above 2.5 kHz, 10 of the 11 sounds on screen land within 5 ms of their beats (median −0.5 ms); INVERT's button release reads 21 ms late, under the riff's note, an arpeggio note and a hat on the same eighth. Taken out of the score by subtracting the arrangement without them, all 11 land within 1 ms.
- **Drafts:** both are 29.2 s (876 frames) and measure −14.1 LUFS with a true peak of −1.5 dBFS by ffmpeg. The episode's score starts exactly 10 s in, by cross-correlating each draft's audio with it.
- **Not checked:** how it plays at full speed and size, and how the fill's blips sit in the mix on a phone. Those are for the owner's viewing in Studio.

## For the owner to decide

- The hook each video leads with. A is the default, and B is tested as a trial reel.
- Whether "Lightroom" may appear on screen (E04 a, b, c, d and e, E05 a and c, E01 e, E10 d) as well as in the captions, never with Adobe's logo or interface. E01's title, FREE ALTERNATIVE TO LIGHTROOM, already names it in the opener, as the owner asked on 10 October, so E01's captions say Redlamp isn't affiliated with Adobe. Whether film stock names may appear on screen (E03), with the README's trademark line in the caption. Whether "Fujifilm-style" may appear on screen (E08 b).
- Whether any episode should also have a version with the real photo, as E01 has. Its photos would go in `~/src/redlamp-social/photos/`, as [Real results](#real-results) lists.

## Results

Added a week after each group of four: release downloads before and after, and each post's views, average watch time, shares, saves and follows on both platforms, with the hook that ran.
