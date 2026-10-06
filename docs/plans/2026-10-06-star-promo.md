# Star Redlamp: a social promo

A 16-second video for social feeds that asks people to star Redlamp on GitHub. It is the website's star nudge ([docs/brand/star-nudge.md](../brand/star-nudge.md)) taken out of the page and played as a short film: the lamp charges and trembles, fires its light into a GitHub badge, a sign drops on a rope, and a cursor stars the project. It is the first job of the promo studio (`.cursor/skills/redlamp-promo-studio/`), and this document follows the studio's design template.

## Brief

| | |
| --- | --- |
| Goal | More GitHub stars for `pdcgomes/redlamp`, which had 25 on 6 October 2026. |
| Audience | Photographers on the Mac who know Lightroom, and the developers and open-source followers who hand out most GitHub stars. |
| Platforms | 9:16 for TikTok, Instagram Reels, YouTube Shorts and Stories; 1:1 for Instagram, Facebook, LinkedIn and X feeds. |
| Length | 16 s: 8 bars at 120 BPM. |
| The one message | Redlamp is a free, open-source raw editor for the Mac, and a star helps it. |
| The ask | Star Redlamp on GitHub: `github.com/pdcgomes/redlamp`. |
| Tone | Playful and quick, in the brand's plain voice: the lamp is the comedian, the words stay calm. |
| Must keep | The brand's rules ([docs/brand/README.md](../brand/README.md)): the red is light with a source, one light per picture, lit from above left, no bright point in the lens, no superlatives. "Please star us!" is the one exclamation, as the owner wrote it. |
| Success | Stars on the repository in the week after posting, against the week before; completion and replay rates where the platform reports them. |

## Concept: the lamp has one thing to ask

The nudge on the website is a gag in three beats: a lamp that can't hold it in, a shot that lands exactly on the button, and a sign that drops down to spell out the ask. On the website it plays once, at the corner of a page. Here it is the whole picture, with a camera and a score:

1. **Tension.** The lamp fills the frame, trembling harder as light gathers behind it. The snare roll in the score is what shakes it: every hit of the roll knocks the lamp, so as the roll speeds up from eighths to thirty-seconds the trembling becomes a blur.
2. **Release.** A half-beat of silence while the lamp holds its breath, then the shot. The camera pulls back to show its whole arc, and it lands on the GitHub badge on the drop.
3. **Payoff.** The badge swings and settles, the sign drops on its rope and catches on the beat, and swings to the music. A cursor stars the project, the count goes up by one, and the sign jumps.
4. **The ask, plainly.** Star Redlamp on GitHub, the address, and what Redlamp is.

It ends on the lamp's light beginning to gather again, so a feed that loops it starts over without a seam in the sound.

## Hooks

The first two seconds decide whether anyone watches the rest, and most feeds play without sound, so the hook is a line on screen over a picture that is already moving. Five, in the brand's voice; the composition takes any of them as its `hook` prop, so each can be rendered and posted as its own variant.

| ID | Line | Why it might work |
| --- | --- | --- |
| `charging` (default) | Hold on. It's charging. | Names what the picture shows and promises it will go off. |
| `favour` | This lamp has a favour to ask. | The lamp as a character; the ask is promised, not yet made. |
| `psst` | Psst. Photographers. | Calls out the audience by name. |
| `wait` | Wait for it. | The plainest promise of a payoff. |
| `day` | One click would make its day. | Gives the ending away, and makes it sweet. |

## Script

The beat sheet, at 120 BPM and 30 fps: a beat every 15 frames, a bar every 60 (2 s). Beats count from 0. `video/src/star/cues.json` holds these timings, and both the composition and the score read them from there.

| Beat | Time | Picture | Words on screen | Sound |
| --- | --- | --- | --- | --- |
| 0 | 0.0 s | The lamp, close, already lit, light gathering behind it, a faint tremble. | The hook's first line. | A low thump on the first frame; the lamp's hum starts rising; a filtered pulse in B minor. |
| 2 | 1.0 s | The camera creeps in. | The hook's second line. | |
| 4 | 2.0 s | Rays reach out; the motes thicken; the tremble grows. | Redlamp is a free raw editor for the Mac. | The snare roll in eighths, shaking the lamp; G major; a riser starts. |
| 8 | 4.0 s | The lamp shakes hard; the glow tightens. | Open source, on GitHub. | Sixteenths, then thirty-seconds from beat 10; A major. |
| 10.5 | 5.25 s | Squash: the lamp shrinks and brightens, holding its breath, and turns towards the badge to aim. The words go. The camera starts to pull back, and the badge comes into frame. | | The drums stop; the hum whines up, and an in-breath. |
| 11 | 5.5 s | The shot leaves from behind the tile's top edge and arcs across the frame; the lamp recoils, swinging back past upright. | | A zap that pans with the shot. |
| 12 | 6.0 s | The hit: a flash and sparks, the badge swells and springs back, its star spins, two lights chase round it. A camera shake. | | The drop: impact, the full groove in D major. |
| 13 to 15 | 6.5 s | The badge bumps on every kick. The camera eases in on it. | | The groove, and the lead's first phrase. |
| 15.55 | 7.78 s | The sign falls out from behind the badge: its physics takes 0.225 s to pull the rope taut, so it's let go that long before the beat. | | A slide whistle down. |
| 16 | 8.0 s | It catches on its rope, exactly on the beat, and swings in time. | Please star us! (on the sign) | A wooden knock and the rope's creak. |
| 20 | 10.0 s | A cursor glides in from below. | | A soft whoosh. |
| 22 | 11.0 s | It clicks the star: the star lights and stays lit, the count goes up by one, sparks, and the sign jumps on its rope. | | A click, a bell, a sparkle, the counter's tick. |
| 24 | 12.0 s | The end card: the camera pulls back to the whole scene, the lamp, the badge and the sign, with the ask above them. | Star Redlamp on GitHub. Then github.com/pdcgomes/redlamp (beat 25), and Every star helps photographers find it. (beat 26) | A whoosh, the last phrase of the lead. |
| 28 | 14.0 s | The end card holds. | | A final stab; the groove stops and the chord rings. |
| 30 | 15.0 s | Light begins to gather behind the lamp again. | | The hum rises again, into the loop. |
| 32 | 16.0 s | Loops to the start. | | |

## Formats

The same timeline in both shapes; only the layout and the camera's framing change.

- **1:1 (1080 × 1080).** The lamp low on the left, the badge high on the right, so the shot rises and arcs across the frame's diagonal. Words sit across the top; at the end, the ask is above the scene and the reason along the bottom.
- **9:16 (1080 × 1920).** The lamp low on the left, the badge in the upper third, the sign below it; the ask and the reason above the scene at the end. Everything that must be read stays inside the region the apps leave clear: below the top 260 px, above the bottom 480 px, and left of the right-hand 160 px where TikTok and Reels put their buttons. The composition's `guides` prop draws these zones in Studio.

## Sound

Original, written in code (`video/scripts/star-score.py`, on the studio's synth library `video/scripts/synth.py`), so it is free to use on every platform. 120 BPM in D major, the Introducing film's key: B minor for the hook, G for the build, A for the rush, then the drop's D, A, B minor, G, and D to end. The build is arranged for momentum rather than added layers alone: the roll's subdivision doubles every bar, a riser climbs with the charge, the lamp's hum follows the charge's own curve, and everything stops for a half-beat before the drop. Every visible event has a sound on the same frame: the thump, each knock of the roll, the shot's zap, the hit, the badge's spring, the sign's fall and catch, the cursor and its click. Mastered to about −14 LUFS integrated, peaks under −1 dBFS.

## Post copy

- **TikTok, Reels and Shorts:** Our lamp has one thing to ask. Redlamp is a free, open-source raw photo editor for the Mac, and a star on GitHub helps more photographers find it. github.com/pdcgomes/redlamp #photography #photoediting #lightroom #opensource #macos
- **X:** Our lamp has one thing to ask. Redlamp is a free, open-source raw editor for the Mac, built in Swift and Metal. A star helps more photographers find it: https://github.com/pdcgomes/redlamp
- **LinkedIn and Facebook:** Redlamp is a free, open-source raw photo editor for the Mac, built from scratch in Swift and Metal, with Lightroom's workflow and no subscription. It's young, and every star on GitHub helps more photographers find it. https://github.com/pdcgomes/redlamp
- **Alt text:** A red safelight trembles as light gathers behind it, then fires an arc of light into a GitHub button. A paper sign reading "Please star us!" drops on a rope below the button. A cursor stars the project, and the count goes up by one.

## For the owner to decide

- The hook to post first, and whether to post more than one as variants.
- Whether the badge shows the live star count. It reads 25 today and goes up by one at the click; with the count off, the badge shows the star alone.
- The length: 16 s holds the end card for 4 s; a 14 s cut drops the bar between the sign and the click.
