# Pixelkit: a promo for X

A 30-second video for X about [pixelartvisuals](https://github.com/pdcgomes/pixelartvisuals), the owner's pixel-art kit for blog graphics, made entirely of what the kit draws. Every frame is drawn by `pixelkit` at its 320×180 canvas and shown six times the size, so every pixel is a 6×6 block at 1920×1080 and every word is in the kit's own bitmap fonts; the score is synthesised in the studio's library. It's the studio's second job, and its first for a project other than Redlamp.

## Brief

| | |
| --- | --- |
| Goal | Stars for `pdcgomes/pixelartvisuals` on GitHub. |
| Audience | Developers and bloggers on X who like retro computing, pixel art and tools that make things in code; people who use coding agents (Cursor, Claude Code). |
| Platforms | X, 16:9 (1920 × 1080). |
| Length | 30.4 s: 19 bars at 150 BPM. |
| The one message | One Python kit draws pixel art like this, and an agent can use it as a skill. |
| The ask | Star it on GitHub: `github.com/pdcgomes/pixelartvisuals`. |
| Tone | Warm, quirky and nerdy, as the owner asked, in the kit's own retro look; the words plain and short. |
| Must keep | Every picture from the kit itself, and every word in its fonts. Claims only from the repository's README: a Python kit and an agent skill, free and open source (MIT). Original music only. No trademarks on screen: the console is a 16-bit console, the game a street fight, the BBS and the brands made up. |
| Success | Stars on the repository in the week after posting, against the week before; views and completion on X. |

## Concept: dial in, and see what's on the board

A kid's bedroom in 1992, at night (the showcase's `bedroom.py`). The beige PC dials a BBS; the hook sits in a dialog box like a role-playing game's. The modem connects, the picture punches in on the CRT, and the BBS's menu offers a SHOWCASE. The kid picks it, the CRT switches off, and on the drop the video becomes the board's showcase: a cut on every bar through what the kit draws, faster at the end. Then how: the code behind a chart, typed beside the chart it draws, and the same chart asked of an agent. The ask is an arcade's CONTINUE? screen, counting down on the beat, until a coin goes in: THANKS FOR PLAYING, and a dithered fade.

1. **Tension.** The dial-up: the number typed key by key, the ringing, the handshake.
2. **Release.** CONNECT, the BBS, and the switch-off into the drop.
3. **Payoff.** Twelve pieces in 16 seconds, each named.
4. **The ask, plainly.** Continue? Star it on GitHub, with the address, for 4.8 s before the coin.

## Hooks

The hook is the dialog box's first line on the first frame, and the second line on beat 2. The frames script draws each hook's opening into a folder of its own; the composition's `hook` prop picks it.

| ID | Line | Why it might work |
| --- | --- | --- |
| `python` (default) | EVERY PIXEL IN THIS / VIDEO IS PYTHON. | The surprise the whole video proves. |
| `dialling` | HOLD ON. / IT'S DIALLING UP. | Names what the picture shows and promises it will connect. |
| `nophotoshop` | NO PHOTOSHOP. / JUST CODE. | The claim, in four words. |
| `bedroom` | REMEMBER THIS / BEDROOM? | Nostalgia, for the audience that had one. |
| `wait` | WAIT TILL / IT CONNECTS. | The plainest promise of a payoff. |

## Script

150 BPM at 30 fps: a beat every 12 frames, a bar every 48 (1.6 s). `video/src/pixelkit/cues.json` holds every timing; the frames script and the score both read it. The bedroom's own timeline (examples/bedroom.py) already sits on this grid: the dial command types from 0.4 to 1.6 s (beats 1 to 4), the ringing at 1.8 s (4.5), CONNECT at 2.6 s (6.5), the BBS at 3.2 s (8).

| Beat | Time | Picture | Words on screen | Sound |
| --- | --- | --- | --- | --- |
| 0 | 0.0 s | The bedroom at night: the PC, the modem, the TV's street fight, the lava lamp, the cat. | The hook's first line, in the dialog box. | The PC's power switch: a thunk and a chirp; a soft arpeggio on Fmaj7. |
| 1 to 4 | 0.4 s | The CRT types the dial command. | | A key click for each letter, the real DTMF tone for each digit. |
| 2 | 0.8 s | | The hook's second line. | |
| 4.5 | 1.8 s | RINGING. | | The ringing a caller hears (440 and 480 Hz); the triangle bass comes in. |
| 5 | 2.0 s | | | The modem's handshake: the 2100 Hz answer tone, probes, the hiss of training. |
| 6 | 2.4 s | The dialog box drops away. | | A rising slide. |
| 6.5 | 2.6 s | CONNECT 2400; the modem's lights come on. | | Two blips. |
| 7.5 | 3.0 s | The picture punches in on the CRT, twice the size. | | A falling slide. |
| 8 | 3.2 s | The BBS fills the frame: PIXEL PIT in rainbow letters. | | A chip crash, a rising chime, the kick on every beat, bass in eighths. |
| 9 to 10.5 | 3.6 s | The menu, item by item. | MESSAGES, SHOWCASE, DOOR GAMES, GOODBYE | A blip up the chord for each. |
| 11 | 4.4 s | COMMAND: S, and SHOWCASE lights up. | | A key, a blip; a snare roll begins. |
| 11.5 | 4.6 s | The CRT switches off: the picture squashes to a line, the line to a dot. | | A falling zap over the roll. |
| 12 | 4.8 s | The drop: the showcase, a piece a bar, each named in the banner, with a counter. | TRACKERS, MUSIC PLAYERS, DAWS, STOCK CHARTS, HACKER MOVIES, RPG STATS, SKYLINES, YOUR GIT LOG | The groove: kick, snare, hats, the triangle's bass, arpeggios, the pulse lead with its echo; a crash on every cut and a blip as each caption types in. |
| 44 | 17.6 s | Faster: a piece every two beats. | PLANETS, THE MOON, DIAGRAMS, AND YES, CHARTS | The lead climbs in eighths; lighter crashes. |
| 52 | 20.8 s | How: an editor with coffee.py, typed line by line, and the chart it draws growing beside it. | ONE PYTHON KIT | The drums break down; a rattle of keys per line; a blip up the chord for each bar of the chart; two for SAVED. |
| 56 | 22.4 s | An agent is asked for the same chart. | AND AN AGENT SKILL | Keys for the prompt. |
| 60 | 24.0 s | The arcade's CONTINUE? screen, invaders marching. | CONTINUE? STAR IT ON GITHUB, the address, FREE AND OPEN SOURCE | A crash; the groove and the lead's first phrase return. |
| 62 to 70 | 24.8 s | The count, 9 to 1, a number a beat. | | A beep on each. |
| 70.5 | 28.2 s | A coin: a star in place of the count, CREDIT 01. | | An arcade coin. |
| 72 | 28.8 s | THANKS FOR PLAYING, the ask still under it. | | The last hit on Cmaj9: a crash, the lead holding E, blips falling down the chord. |
| 74 | 29.6 s | The picture fades out through a dither. | | The chord dies away and fades with it. |
| 76 | 30.4 s | Black; a loop starts again in the bedroom. | | |

## Formats

16:9 only, as the brief asks: the kit's 320×180 canvas at exactly ×6. X's player keeps its controls along the bottom, where the montage's banner sits above its last 26 logical pixels (156 px); nothing that must be read is lower than that except the arcade's 1UP and CREDIT, which are decoration. A 1:1 cut would be the kit's 180×180 at ×6, and would need its own layouts.

## Sound

Original, written in code (`video/scripts/pixelkit-score.py`), on the studio's library and the chiptune voices added to it for this job (`synth.py`: `pulse`, `triangle`, `chip_noise`, `chip_kick`, `chip_snare`, `chip_hat`, `chip_crash`, `arp`, `blip`, `coin`, `dtmf`, `ringback`, `handshake`). Warm chiptune, because the brief asks for retro in so many words: the studio's default palette is dark and cinematic. It's in C major at 150 BPM, on the progression game music calls the royal road (Fmaj7, G6, Em7, Am9), with the colour notes in the arpeggios, a ii–V for the code (Dm9, G13), and a resolution to Cmaj9 at the end. The pulses carry a gentle low-pass so they're warm rather than fizzy, the lead has a dotted-eighth echo, and the drums are the chip's own noise. Mastered to −14 LUFS integrated, true peak −1.0 dBFS or under.

## Post copy

- **X:** Every pixel in this video is Python. pixelkit draws pixel-art charts, dashboards and scenes for blog posts, and works as an agent skill too. Free and open source: https://github.com/pdcgomes/pixelartvisuals
- **Alt text:** A pixel-art bedroom in 1992 at night: a beige PC dials a bulletin board while a fighting game plays on the TV. The picture zooms into the PC's screen, where the board's menu offers a showcase. A fast montage follows of pixel-art graphics: a music tracker, a music player, a beat maker, stock charts, a film's hacking screen, a role-playing character sheet, a skyline, a commit heatmap, the planets, the moon's phases, a diagram and a dashboard. Then Python code types out beside the bar chart it draws. It ends on an arcade's "Continue?" screen counting down, asking you to star the project on GitHub, until a coin goes in and it says "Thanks for playing".

## For the owner to decide

- The hook to post first.
- Whether to keep the arcade's countdown, or hold the ask still.
- Whether the promo stays in this repository's studio or moves to pixelartvisuals once it's approved.

## Building it

From `video/`, with the kit checked out at `~/src/pixelartvisuals` (or `$PIXELKIT`):

```bash
npm run pixelkit-frames     # public/pixelkit/frames/, and every other hook's opening (about 45 s)
npm run pixelkit-score      # public/pixelkit/score.wav and score.json
npm run studio              # Pixelkit › PixelkitPromo16x9, with the hook as a prop
npm run pixelkit -- --draft # out/pixelkit/pixelkit-16x9-draft.mp4
npm run pixelkit            # the render and its poster (frame 820, the countdown), after approval
```

The composition only shows the frames and plays the score: the pictures are the frames script's, so a change to a picture is a change there (or in the kit's examples), then `npm run pixelkit-frames`.

## Review notes

Checked on 7 October 2026, on the half-size draft and the frames:

- Storyboard sheet: `video/out/PixelkitPromo16x9-storyboard.jpg`, a frame at every cue over the score's level. Every cue shows what the script says.
- The first frame carries the hook's first line in the dialog box over the bedroom; the second line arrives on beat 2.
- Words: the dialog box, the montage's captions, the BBS's menu, the how titles and the ask are the large font at twice its size, 84 px tall at 1080; the address is the large font at 42 px.
- The ask (CONTINUE?, STAR IT ON GITHUB, the address) is on screen from 24.0 s to the fade at 29.6 s; the address stays to the end.
- At full size the frames are crisp: Chrome scales them with nearest neighbour, each logical pixel a 6×6 block.
- Score, by ffmpeg: −14.0 LUFS integrated, true peak −1.4 dBFS. Energy: sub 4%, low 41%, mid 43%, presence 10%, air 3%.
- Cues against the score (the report): every cue with a sound of its own within a frame; the first frame's power switch is on frame 0.
- Loudness by bar: −23.0 for the dial-up, −18.2, −15.3 for the BBS, the drop at −13.2, the montage at −13.4 to −13.1, the code's breakdown at −16.9 and −16.4, the ask at −13.2 to −13.4, the last chord's bar at −16.0. After the drop the level holds rather than climbs: the ask's octave doubling adds brightness more than level. The owner's ears decide whether it needs more.
- The encoded draft's audio against the score: 0 ms offset (their envelopes cross-correlated).
- `npx tsc --noEmit` passes.

Not checked: the full-size render (only the draft), and how it plays in X's own player.
