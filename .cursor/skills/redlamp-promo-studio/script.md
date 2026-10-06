# The script and the beat sheet

The scriptwriter turns the concept into a beat sheet on a music grid: what happens on each beat, in the picture, in words and in sound. Its timings go into `video/src/<slug>/cues.json`, which the composition and the score both read, so they meet on the same frames.

## The grid

Pick a tempo whose beat is a whole number of frames at 30 fps, so cues land exactly on frames:

| BPM | Frames a beat | Feel |
| --- | --- | --- |
| 72 | 25 | Calm: Introducing Redlamp |
| 100 | 18 | Easy |
| 120 | 15 | Energetic: the explainer, the star promo |
| 150 | 12 | Driving |

A bar is four beats. Lay the promo out in whole bars: 8 bars at 120 BPM is 16 seconds.

## The cue sheet

```json
{
  "bpm": 120, "fps": 30, "beatsPerBar": 4, "bars": 8,
  "chords": [["Bm", 0, 4], ["G", 4, 4], ["A", 8, 4], ["D", 12, 4]],
  "knocks": [[4, 8, 0.5], [8, 10, 0.25]],
  "cues": { "hook": 0, "squash": 10.5, "fire": 11, "hit": 12, "catch": 16, "click": 22, "end": 24 }
}
```

- `cues` names every moment that both the picture and the sound care about, in beats from the start (fractions are fine: 10.5 is the "and" of beat 10). `kit/grid.ts` turns them into frames (`grid(sheet).cue("hit")`), and the score into seconds.
- `chords` is the harmony, as [chord, first beat, beats]; anything that should change with it can read it.
- A promo can add its own lists, as the star promo's `knocks` (the roll that shakes the lamp, as [from, to, every] in beats); type them in the composition (`CueSheet & { knocks: … }`).

## Structure for momentum

Energy should climb to the payoff and then make room for the ask. The star promo's eight bars:

| Bars | Section | Picture | Sound |
| --- | --- | --- | --- |
| 1 | Hook | Already moving; the hook line | Something on the first frame; a pulse |
| 2 to 3 | Build | Tension rising, the context in words | The roll doubles each bar; a riser |
| End of 3 | The gap | The breath before it goes | Half a beat of near silence |
| 4 | Drop | The release, on the downbeat | The full groove arrives |
| 5 to 6 | Payoff | The consequence; the ask in the picture | The groove; each event its sound |
| 7 to 8 | The ask | The ask in words, held | The groove, then a last chord; the loop's run-in |

## The beat sheet

A table in the design doc, one row per cue: Beat, Time, Picture, Words on screen, Sound. Every picture event that should have a sound gets a row, and every sound has its picture. Physical events (a sign catching on its rope, a ball landing) are made to land on beats by timing their start (`fallTime` in `kit/rope.ts`), not the other way round.

## The storyboard

Once the scenes render, the storyboard sheet lays a frame out at every cue, over the score's level with the cues marked (`npm run storyboard`, [review.md](review.md)). Put it in the review notes; it's the quickest way for the owner to see the whole script.
