# Sound: the score and its effects

The composer and sound designer write the score in `video/scripts/<slug>-score.py`, on the studio's synth library `video/scripts/synth.py`, from the promo's `cues.json`. Everything is synthesised and nothing is sampled, so the music is original and free to use on every platform, and it can be re-timed whenever the picture is. The score writes `public/<slug>/score.wav` and `score.json` (its level at every frame, for the storyboard sheet); the composition plays the WAV with `Html5Audio` and stays silent while it's missing.

## The owner's taste

Dark, cinematic and sophisticated. The star promo's first score, in D major with a bouncy pulse lead, a pumping supersaw, four-on-the-floor with claps and hats, a boing and a slide whistle, was turned down as cheesy and too happy, and replaced by the one described here. Start from the cinematic palette; reach for the bright one (`lead`, `supersaw`, `stab`, `clap`, `hat`, `boing`, `slide`) only when a brief asks for it in so many words.

The feature videos' brief does (10 October 2026). For them the owner turned down a sweet F major tune on a square lead over felt piano as cheesy and short of energy, liked the D minor riff that replaced it, and chose its synthwave arrangement over an electronic one and a cinematic one: supersaw pads, a plucked arpeggio, an octave bass, a gated snare on 2 and 4 and the riff on a saw lead with vibrato, moving from the first frame (`video/scripts/features-theme.py`). It suits the pixel-art dashboards it plays under. The minor key, the colour notes and the held tension below still apply. He then asked for new music in every video rather than one theme for the series: a new synthwave track each time, with its own key, riff, chords and sounds, keeping the opener, its lead-in and the glass sting on the drop as the series' signature (`video/scripts/features/music/<episode>.py`).

What makes it sophisticated rather than loud:

- **A minor key, and chords with their colour notes**: a ninth against the minor third, a major seventh, a seventh on the dominant; not bare triads.
- **No tune to hum.** An ostinato drives it, and a single line moves by step (the star promo's falls a step a bar from A to D).
- **Space.** Few instruments at a time in the opening; a lone piano note can carry a bar.
- **Weight from the drums in half time**: a kick on the bar and the snare on its third beat, at 120 BPM, so it moves at the picture's pace and lands like a trailer.
- **Tension held, not dropped**: the rhythm stops for the half-beat before the drop while the strings and a swell carry on into it. The owner found a cut to silence there too abrupt.

## The library

`synth.py` has, at 48 kHz:

| Kind | Functions |
| --- | --- |
| Cinematic | `strings` (a bowed section, legato, opening up as it plays), `spiccato` (short bounced strings for an ostinato), `piano` (felt), `braam` (a trailer's low brass hit), `drone` (a dark bed), `taiko` (also a low tom, with a short `decay`), `deep_kick`, `big_snare`, `tock` (a watch's tick), `glass` (struck, or bowed with a slow `attack`), `shepard` (a Shepard–Risset tone that seems to rise for ever), `swell_into` (a sound's own reverb, reversed, swelling into it) |
| Drums | `kick`, `snare` (its `tone` rises through a build), `gated_snare` (the eighties' snare, its reverb cut short), `clap`, `hat` (closed or open), `crash` (with its `decay`) |
| Tuned | `pluck`, `bass` (a saw with a quick filter over a sine an octave down: keep its note above about D2), `sub`, `lead`, `saw_lead` (detuned saws through a filter, with vibrato), `pulse_lead` (a hollow lead of detuned pulses that can glide in from the note before), `supersaw`, `stab`, `brass` (a poly-synth's brass, which blares open: a stab when short, a swell with a slow `attack`), `bell`, `fm` (an FM electric piano, or a bell with a higher `ratio`) |
| Chiptune | `pulse` (a pulse of any width, with vibrato and a slide), `triangle` (16 steps, for bass), `chip_noise` (a 15-bit shift register), `chip_kick`, `chip_snare`, `chip_hat`, `chip_crash`, `arp` (a chord as a fast arpeggio), `blip`, `coin`; and the phone line's `dtmf`, `ringback` and `handshake`. For a brief that asks for retro, as the pixelkit promo's does |
| Effects | `riser`, `whoosh`, `inhale` (the breath before a drop), `boom`, `hum`, `zap`, `boing`, `slide`, `knock` (wood), `creak` (rope), `click` (a mouse button), `tick`, `key` (a keyboard key going down, or `up`), `crackle` |
| Mixing | `Bus` (stereo, with a reverb send; `pan_to` may change every sample), `sidechain`, `reverb`, `master` (with a `choke` and `presence`) |
| Measuring | `loudness` (ITU-R BS.1770-4, gated, as ffmpeg's `ebur128` reads it), `true_peak` (four times oversampled) |

Every random sound draws from `synth.rng`; call `reset(seed)` at the start of a score so it renders the same every time. `harmonics()` builds tones additively with a filter whose cutoff can change every sample, which is how plucks, spiccato and the braam get their envelopes without a per-sample loop. `scripts/score.py` (Introducing Redlamp) predates the library and keeps its own copies, so its published score can't change.

## Sync

- **One cue sheet.** Read `cues.json` and place every sound at `beat × 60 / bpm` seconds. Don't type a time in seconds.
- **If it moves, it sounds; if it lands, it lands on a beat.** Each visible event has its sound on its frame: the first frame, each knock of the roll, the shot (panned along its path), the hit, the sign's fall and catch, the cursor, the click, the count. Real sounds for real objects (wood, rope, glass, a mouse button), never cartoon ones.
- **Share the curves.** Where the picture follows a curve (the charge), the score computes the same one (`charge()` in `star-score.py` mirrors `chargeLevel` in `kit/light.ts`), so the Shepard tone climbs faster exactly as the light grows.
- **Share the hits.** Picture events driven by sound read the same list as the score: the star promo's lamp is shaken by the cue sheet's `knocks` (the roll), and its badge bumps on the `groove` (the drop's drum hits, each with its weight).

## Arrangement for momentum

- Something on the first frame (a deep hit) so a viewer with sound on is held from the start.
- Build in steps the ear can count: a roll that doubles (eighths, sixteenths, thirty-seconds), strings from a murmur to full, a Shepard tone that screws tighter, a riser.
- Hold the tension before the drop rather than dropping it: stop the rhythm for the squash, and let what's sustained swell on through it into the hit: the build's last chord in the strings, the riser, the Shepard tone, and the hit's own reverb reversed (`swell_into`) from the squash. The level should dip a few dB, never fall away. (`master(..., choke=…)` cuts the whole mix to silence, reverb and all, for a brief that wants a hard stop.)
- Land the hit with the full weight at once: low brass, taiko, deep kick, crash.
- Keep growing after the drop, so the end card arrives at a height; then a last hit, and a bar for it to die away in: the last chord and a few piano notes ringing out, and the last second or more faded out with the picture (`master(..., fade=1.6)`). The owner heard a run-in to a loop, cut off at the end, as the film being cut off.
- Measure the climb with `scripts/score-report.py`, bar by bar. The star promo's, in LUFS: −17.0, −16.7, −14.0, the drop at −11.6, then −14.2, −14.2, the end card at −13.5, the last hit's bar at −13.5, and the bar it dies away in at −21.6. The drop should be the loudest bar.

## Mixing and mastering

- `master()` sums the buses and their reverb, takes out what's under 36 Hz, adds a little air above 7 kHz and, with `presence`, a lift from 3 kHz; then it levels to −14 LUFS integrated and keeps the true peak under −1 dBFS with a soft limiter, and fades the last 30 ms.
- Phones play little below 100 Hz. Keep the sub to about a third of the energy and the mids (250 Hz to 2 kHz) at 15% or more, by the report: low notes need harmonics (a saw bass, the braam's saws), and a sine under 60 Hz only takes headroom (`braam` moves its sub up an octave for that reason).
- A dark mix still needs `presence` (the star promo uses 3 dB) to carry on a phone.
- Duck the bass and the strings a little under each kick (`sidechain`), so the drums stay clear.
- Check with ffmpeg as well: `ffmpeg -i public/<slug>/score.wav -af ebur128=peak=true -f null -`; its integrated loudness and `synth.loudness()` agree.
- Draw the spectrogram to see the arrangement without listening: `ffmpeg -i score.wav -lavfi showspectrumpic=s=1600x500:legend=1:fscale=log spectrum.png`. A gap shows as a dark band, on the storyboard sheet's waveform too, and the owner will see it there.

## The report

```bash
python3 scripts/score-report.py public/<slug>/score.wav --cues=src/<slug>/cues.json
```

It prints the integrated loudness and true peak; the loudness of every bar, with its chord; for every cue, how far the steepest rise in level is from the cue's time (a cue with a sound of its own should be within a frame, 33 ms; a cue with nothing new on it shows whatever is nearby); where the energy sits from the sub to the air; and the stereo width.
