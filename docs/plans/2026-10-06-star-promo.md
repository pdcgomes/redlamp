# Star Redlamp: a social promo

An 18-second video for social feeds that asks people to star Redlamp on GitHub. It is the website's star nudge ([docs/brand/star-nudge.md](../brand/star-nudge.md)) taken out of the page and played as a short film: the lamp charges and trembles, fires its light into a GitHub badge, a sign drops on a rope, and a cursor stars the project. It is the first job of the promo studio (`.cursor/skills/redlamp-promo-studio/`), and this document follows the studio's design template.

## Brief

| | |
| --- | --- |
| Goal | More GitHub stars for `pdcgomes/redlamp`, which had 25 on 6 October 2026. |
| Audience | Photographers on the Mac who know Lightroom, and the developers and open-source followers who hand out most GitHub stars. |
| Platforms | 9:16 for TikTok, Instagram Reels, YouTube Shorts and Stories; 1:1 for Instagram, Facebook, LinkedIn and X feeds. |
| Length | 18 s: 9 bars at 120 BPM. |
| The one message | Redlamp is a free, open-source raw editor for the Mac, and a star helps it. |
| The ask | Star Redlamp on GitHub: `github.com/pdcgomes/redlamp`. |
| Tone | Playful and quick in what happens, in the brand's plain voice: the lamp is the comedian, the words stay calm, and the music is dark and cinematic. |
| Must keep | The brand's rules ([docs/brand/README.md](../brand/README.md)): the red is light with a source, one light per picture, lit from above left, no bright point in the lens, no superlatives. "Please star us!" is the one exclamation, as the owner wrote it. |
| Success | Stars on the repository in the week after posting, against the week before; completion and replay rates where the platform reports them. |

## Concept: the lamp has one thing to ask

The nudge on the website is a gag in three beats: a lamp that can't hold it in, a shot that lands exactly on the button, and a sign that drops down to spell out the ask. On the website it plays once, at the corner of a page. Here it is the whole picture, with a camera and a score:

1. **Tension.** The lamp fills the frame, trembling harder as light gathers behind it. The snare roll in the score is what shakes it: every hit of the roll knocks the lamp, so as the roll speeds up from eighths to thirty-seconds the trembling becomes a blur.
2. **Release.** A half-beat of silence while the lamp holds its breath, then the shot. The camera pulls back to show its whole arc, and it lands on the GitHub badge on the drop.
3. **Payoff.** The badge swings and settles, the sign drops on its rope and catches on the beat, and swings to the music. A cursor stars the project, the count goes up by one, and the sign jumps.
4. **The ask, plainly.** Star Redlamp on GitHub, the address, and what Redlamp is.

It opens on the lamp at rest, so the light's arrival is a surprise, and it ends as the last chord dies away and the picture fades out; a feed that loops it starts again from rest.

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
| 0 | 0.0 s | The lamp, close and at rest, lit as it always is: nothing gathers yet, so the light's arrival is a surprise. | The hook's first line. | A deep hit on the first frame; a low drone on D; a felt piano's open fifth; a watch ticking. |
| 1.5 | 0.75 s | Light starts to gather behind the lamp: the first motes, and a glow coming up. | | A Shepard tone that seems to rise for ever comes in with it. |
| 2 | 1.0 s | The camera creeps in. | The hook's second line. | A heartbeat on each beat of the first bar. |
| 4 | 2.0 s | Rays reach out; the motes thicken; the tremble grows. | Redlamp is a free raw editor for the Mac. | Low toms take over the roll, in eighths, each hit shaking the lamp; a taiko on the bar; spiccato strings come in under a section that swells, on B flat. |
| 8 | 4.0 s | The lamp shakes hard; the glow tightens. | Open source, on GitHub. | The toms in sixteenths, then thirty-seconds from beat 10, with a tick of metal; the bass in eighths; a riser; G minor, then A. |
| 10.5 | 5.25 s | Squash: the lamp shrinks and brightens, holding its breath, and turns towards the badge to aim. The words go. The camera starts to pull back, and the badge comes into frame. |  | The rhythm stops; the strings, the riser and the Shepard tone swell on through it, and the hit's reverb, reversed, starts to rise. |
| 11 | 5.5 s | The shot leaves from behind the tile's top edge and arcs across the frame; the lamp recoils, swinging back past upright. |  | A thump as the lamp recoils; a shot of struck glass, and air that pans with it; the swell climbs on into the hit. |
| 12 | 6.0 s | The hit: a flash and sparks, the badge swells and springs back, its star spins, two lights chase round it. A camera shake. |  | The drop: a trailer's low brass on a D minor cluster, a taiko, a deep kick and a dark crash; the half-time groove begins. |
| 13 to 15 | 6.5 s | The badge bumps on each of the drums' hits. The camera eases in on it. |  | A kick on each bar, the snare on its third beat and a lighter kick before the next, and the badge bumps on each; the strings' ostinato and the bass. |
| 15.55 | 7.78 s | The sign falls out from behind the badge: its physics takes 0.225 s to pull the rope taut, so it's let go that long before the beat. |  | Air as it falls. |
| 16 | 8.0 s | It catches on its rope, exactly on the beat, and swings in time. | Please star us! (on the sign) | A taiko, a wooden knock and the rope's creak; the strings' line starts high on A and falls a step every bar. |
| 20 | 10.0 s | A cursor glides in from below. |  | A taiko, and a soft whoosh from the right. |
| 22 | 11.0 s | It clicks the star: the star lights and stays lit, the count goes up by one, sparks, and the sign jumps on its rope. |  | A click, a sub thump, struck glass and a piano's fifth, and the counter's tick; the line falls to G. |
| 24 | 12.0 s | The end card: the camera pulls back to the whole scene, the lamp, the badge and the sign, with the ask above them. | Star Redlamp on GitHub. Then github.com/pdcgomes/redlamp (beat 25), and Every star helps photographers find it. (beat 26) | A reversed cymbal into it, a taiko and a crash; the brass opens up. |
| 28 | 14.0 s | The end card holds. |  | A last hit of the low brass; the groove stops; the strings hold D minor as they darken, and the piano plays alone. |
| 34 | 17.0 s | The picture fades out to the wall. | | The last chord and the piano die away, and the sound fades with the picture. |
| 36 | 18.0 s | The end; a feed that loops it starts again on the lamp at rest. | | |

## Formats

The same timeline in both shapes; only the layout and the camera's framing change.

- **1:1 (1080 × 1080).** The lamp low on the left, the badge high on the right, so the shot rises and arcs across the frame's diagonal. Words sit across the top; at the end, the ask is above the scene and the reason along the bottom.
- **9:16 (1080 × 1920).** The lamp low on the left, the badge in the upper third, the sign below it; the ask and the reason above the scene at the end. Everything that must be read stays inside the region the apps leave clear: below the top 260 px, above the bottom 480 px, and left of the right-hand 160 px where TikTok and Reels put their buttons. The composition's `guides` prop draws these zones in Studio.

## Sound

Original, written in code (`video/scripts/star-score.py`, on the studio's synth library `video/scripts/synth.py`), so it is free to use on every platform. Dark and cinematic: 120 BPM in D minor, with the drums in half time after the drop, so it moves at the picture's pace and lands with a trailer's weight. D minor under the charge, B flat for the build, G minor and A for the rush, then D minor, B flat, G minor, B flat and A, and D minor to end; the chords carry their colour notes (a ninth against the minor third, a major seventh) rather than plain triads. The build is arranged for momentum rather than added layers alone: the roll's subdivision doubles every bar, spiccato strings grow from a murmur, a Shepard tone climbs faster as the lamp charges, and for the half-beat squash the rhythm stops while the strings, the riser and the Shepard tone swell on through it into the hit (a cut to silence there, tried first, was too abrupt). There's no tune to hum: the strings' ostinato drives it, and one line falls a step at a time from the sign to the last chord. Every visible event has a sound on the same frame: the first frame, each knock of the roll, the shot, the hit, the sign's fall and catch, the cursor and its click, the end card. The last bar lets the final chord and the piano die away, and the last 1.6 s fade out with the picture. Mastered to −14 LUFS integrated, true peaks under −1 dBFS; `scripts/score-report.py` measures it bar by bar and cue by cue. The first score, in D major with a bouncy lead, a pumping supersaw and cartoon effects, was turned down by the owner as cheesy and too happy.

## Post copy

- **TikTok, Reels and Shorts:** Our lamp has one thing to ask. Redlamp is a free, open-source raw photo editor for the Mac, and a star on GitHub helps more photographers find it. github.com/pdcgomes/redlamp #photography #photoediting #lightroom #opensource #macos
- **X:** Our lamp has one thing to ask. Redlamp is a free, open-source raw editor for the Mac, built in Swift and Metal. A star helps more photographers find it: https://github.com/pdcgomes/redlamp
- **LinkedIn and Facebook:** Redlamp is a free, open-source raw photo editor for the Mac, built from scratch in Swift and Metal, with Lightroom's workflow and no subscription. It's young, and every star on GitHub helps more photographers find it. https://github.com/pdcgomes/redlamp
- **Alt text:** A red safelight trembles as light gathers behind it, then fires an arc of light into a GitHub button. A paper sign reading "Please star us!" drops on a rope below the button. A cursor stars the project, and the count goes up by one.

## For the owner to decide

- The hook to post first, and whether to post more than one as variants.
- Whether the badge shows the live star count. It reads 25 today and goes up by one at the click; with the count off, the badge shows the star alone.
- The length: 18 s, a bar longer than first planned so the last hit can die away; the end card holds for 5 s before the fade.
