# Sound: the score and its effects

The composer and sound designer write the score in `video/scripts/<slug>-score.py`, on the studio's synth library `video/scripts/synth.py`, from the promo's `cues.json`. Everything is synthesised and nothing is sampled, so the music is original and free to use on every platform, and it can be re-timed whenever the picture is. The score writes `public/<slug>/score.wav` and `score.json` (its level at every frame, for the storyboard sheet); the composition plays the WAV with `Html5Audio` and stays silent while it's missing.

## The library

`synth.py` has, at 48 kHz:

| Kind | Functions |
| --- | --- |
| Drums | `kick`, `snare` (its `tone` rises through a build), `clap`, `hat` (closed or open), `crash` |
| Tuned | `pluck` (a filter that snaps shut), `bass` (a saw with a quick filter over a sine an octave down), `sub`, `lead` (a narrow pulse with a late vibrato), `supersaw` and `stab` (detuned saws), `bell` (glass) |
| Effects | `riser`, `whoosh`, `inhale` (the breath before a drop), `boom`, `hum` (a tone that follows a pitch curve, as a charge), `zap` (a shot of light), `boing` (a spring), `slide` (a slide whistle), `knock` (wood), `creak` (rope), `click` (a mouse button), `tick`, `crackle` (static that follows a density curve) |
| Mixing | `Bus` (stereo, with a reverb send; `pan_to` may change every sample), `sidechain` (the pump), `reverb`, `master` |
| Measuring | `loudness` (ITU-R BS.1770-4, gated, as ffmpeg's `ebur128` reads it), `true_peak` (four times oversampled) |

Every random sound draws from `synth.rng`; call `reset(seed)` at the start of a score so it renders the same every time. `harmonics()` builds tones additively with a filter whose cutoff can change every sample, which is how plucks and leads get their envelopes without a per-sample loop. `scripts/score.py` (Introducing Redlamp) predates the library and keeps its own copies, so its published score can't change.

## Sync

- **One cue sheet.** Read `cues.json` and place every sound at `beat × 60 / bpm` seconds. Don't type a time in seconds.
- **If it moves, it sounds; if it lands, it lands on a beat.** Each visible event has its sound on its frame: the first frame, each knock of the roll, the shot (panned along its path), the hit, the badge's spring, the sign's fall and catch, the cursor, the click, the count.
- **Share the curves.** Where the picture follows a curve (the charge), the score computes the same one (`charge()` in `star-score.py` mirrors `chargeLevel` in `kit/light.ts`), so the hum rises exactly as the light grows.
- **Picture events driven by sound.** The star promo's lamp is shaken by the roll: both read the cue sheet's `knocks`, so each hit is a jolt.

## Arrangement for momentum

- Start with something on the first frame (a thump) so a viewer with sound on is held from the start.
- Build in steps the ear can count: a roll that doubles (eighths, sixteenths, thirty-seconds), a filter opening, a riser, a rising hum.
- Leave a half-beat of near silence before the drop.
- Land the drop on the release in the picture, with the full groove at once.
- Measure the climb, section by section, with `loudness()` on slices. The star promo's: hook −19 LUFS, build −17, rush −13, drop −12, the rest about −13.5, the tail −17.5. The drop should be the loudest moment.
- End on a chord, and lead the last bar back into the first frame for the loop.

## Mixing and mastering

- `master()` sums the buses and their reverb, takes out the rumble below 32 Hz, adds a little air above 7 kHz, levels to −14 LUFS integrated and keeps the true peak under −1 dBFS with a soft limiter, and fades the last 30 ms.
- Check with ffmpeg as well: `ffmpeg -i public/<slug>/score.wav -af ebur128=peak=true -f null -`. Its integrated loudness and `synth.loudness()` agree.
- Phones play little below 100 Hz: a bass line needs harmonics (the `bass` saw), not only a sub.
- Duck the pad and the bass under each kick (`sidechain`) so the beat pumps and stays clear.
- Draw the spectrogram to check the arrangement without listening: `ffmpeg -i score.wav -lavfi showspectrumpic=s=1600x500:legend=1:fscale=log spectrum.png`.
