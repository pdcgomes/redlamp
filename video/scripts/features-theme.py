#!/usr/bin/env python3
"""
The feature videos' theme (src/features/): one tune in D minor at 100 BPM, 8 bars and 19.2 seconds,
in three arrangements, written from the series' cue sheet, src/features/cues.json, so every sound
lands on the frame its picture does.

    python3 scripts/features-theme.py              # public/features/theme-synthwave.wav, theme-drive.wav, theme-pulse.wav
    python3 scripts/features-theme.py synthwave    # one of them

The owner turned down the first theme, a sweet tune in F major on a soft square lead over felt piano,
as cheesy and short of energy (10 October 2026). This one moves from the first frame and builds to
the real result, the drop at 12.0 s. Under the hook, sixteenths and a beat held back; from the first
step a two-bar riff in the dotted rhythm of 3 + 3 + 2 sixteenths, climbing from A to F and falling
back; the full beat from the third step; a roll and a riser through the fourth, the rhythm stopping
half a beat before the drop while the riser and the hit's own reverb swell on into it. On the drop,
the riff's head over struck glass, the same in every video; from the end line the closing phrase,
turning through A7 to D minor on the last hit, and the last chord dying away as the picture fades.

- synthwave: the series' (the owner, 10 October 2026). A sixteenth-note arpeggio through the chords
  from the first frame, wide detuned-saw pads that open through the build, an octave-jumping bass in
  eighths, a kick on every beat from the third step with the gated snare on 2 and 4, falling toms
  into the drop, and the riff on the saw lead with a vibrato and an echo.
- drive: electronic. A four-on-the-floor kick, a rolling bass in sixteenths that opens through the
  build, closed and open hats, a backbeat snare, dark chord stabs on the offbeats from the drop, an
  arpeggio, and the riff on two detuned saws with an echo.
- pulse: cinematic, after the star promo. Spiccato strings in sixteenths, a ticking watch, taiko and
  low toms, a deep kick and a film snare from the third step, a Shepard tone climbing into the drop,
  the trailer's low brass on it, and the riff on the strings with the piano under it.

Each arrangement leaves a video's own sounds to `sounds`, which puts them on its effects bus; the
sketches have quiet clicks and ticks in their place. Needs numpy.
"""

import json
import sys
from pathlib import Path

import numpy as np

import synth as s

ROOT = Path(__file__).resolve().parent.parent
sheet = json.loads((ROOT / "src/features/cues.json").read_text())
BEAT = 60 / sheet["bpm"]
BAR = sheet["beatsPerBar"]
BEATS = sheet["bars"] * BAR
TOTAL = BEATS * BEAT
cue = sheet["cues"]
STEPS = [cue["step1"], cue["step2"], cue["step3"], cue["step4"]]
S1, S2, S3, S4 = STEPS
DROP = cue["result"]
# The rhythm stops for the half beat before the drop; what's sustained swells on through it.
STOP = DROP - 0.5
LAST = sheet["chords"][-1][1]


def at(beat):
    return beat * BEAT


# Each chord: the bass's root, and the voicing above it, which moves as little as it can from chord to
# chord and keeps the colour notes that make it dark: the ninth against Dm's minor third, Bb's major
# seventh, G minor's ninth, A's suspended fourth before its leading note.
CHORDS = {
    "Dm9": (50, [57, 60, 64, 65]),
    "Bbmaj7": (46, [58, 62, 65, 69]),
    "Gm9": (43, [58, 62, 65, 69]),
    "A7sus": (45, [57, 62, 64, 67]),
    "C6": (48, [57, 60, 64, 67]),
    "A7": (45, [57, 61, 64, 67]),
}


def chord_at(beat):
    for name, first, length in sheet["chords"]:
        if first <= beat < first + length:
            return name
    return sheet["chords"][-1][0]


# The riff, [beat, note, beats] from where it starts: A, D and E in the dotted rhythm, up to F on the
# third beat and back down; then C, D and the A held. The answer ends on D instead; the head is its
# first bar; the closing phrase turns through C sharp to D on the last hit.
MOTIF = [(0, 69, 0.75), (0.75, 74, 0.75), (1.5, 76, 0.5), (2, 77, 1.0), (3, 76, 0.5), (3.5, 74, 0.5),
         (4, 72, 0.75), (4.75, 74, 0.75), (5.5, 69, 2.5)]
ANSWER = MOTIF[:6] + [(4, 72, 0.75), (4.75, 76, 0.75), (5.5, 74, 2.0)]
HEAD = MOTIF[:6]
CLOSE = MOTIF[:5] + [(3.5, 73, 0.5), (4, 74, 4.0)]


def placed(first, part):
    return [(first + beat, note, beats) for beat, note, beats in part]


TUNE = placed(S1, MOTIF) + placed(S3, ANSWER) + placed(DROP, HEAD) + placed(cue["endLine"], CLOSE)

# How fully the arrangement plays from each cue: held back under the hook, growing through the steps,
# full on the drop, then easing a little for the end line and the last chord.
SWELL = [(cue["hook"], 0.72), (S1, 0.78), (S3, 0.84), (DROP, 1.0), (cue["endLine"], 0.94), (LAST, 0.85)]


def swell(beat):
    return [level for first, level in SWELL if first <= beat][-1]


def opening(beat, start, end, low, high):
    """`low` before `start`, `high` after `end`, and the way between in a curve that hurries at the end."""
    t = min(1.0, max(0.0, (beat - start) / (end - start)))
    return low + (high - low) * t ** 1.6


def playing(first, last, step):
    """Beats from `first` up to `last`, every `step`, leaving out the stop before the drop."""
    return [b for b in np.arange(first, last - 1e-9, step) if not STOP <= b < DROP]


def start(seed):
    """Starts an arrangement's random sounds over, so it renders the same whichever are rendered with it."""
    s.reset(seed)
    s._pianos.clear()


def dying(x, seconds):
    """`x`, dying away by 1/e every `seconds`."""
    fall = np.exp(-np.arange(len(x)) / s.SR / seconds)
    return x * (fall[:, None] if x.ndim == 2 else fall)


def trim(bus, cutoff):
    """Takes what's under `cutoff` Hz out of a bus: a phone plays none of it, and it takes headroom."""
    bus.dry = s.highpass(bus.dry, cutoff, order=2)
    bus.send = s.highpass(bus.send, cutoff, order=2)


def develop(bus, room):
    """The sting on the drop, the same in every video: glass struck on D, A and E, its own reverb
    swelling up into it."""
    struck = sum(s.pan(s.glass(note, 4.0, velocity), p) for note, velocity, p in ((74, 0.9, -0.3), (81, 0.7, 0.2), (88, 0.5, 0.45)))
    bus.add(at(DROP - 1), s.swell_into(struck, BEAT, room), gain=0.07, wet=0.0)
    bus.add(at(DROP), struck, gain=0.32, wet=0.5)


def ui(fx):
    """Where each video's own sounds will sit, quiet: a click on every step and a tick on the flip."""
    for beat in STEPS:
        fx.add(at(beat), s.click(0.8), gain=0.16, pan_to=0.25, wet=0.05)
    fx.add(at(cue["flip"]), s.tick(0.7), gain=0.18, pan_to=0.25, wet=0.1)


# ---------------------------------------------------------------- the arrangements


def drive(sounds=ui):
    start(43)
    room = s.reverb(1.6, 0.45, 0.018)
    drums, low, pads, lead, fx = (s.Bus(TOTAL + 4) for _ in range(5))
    kicks = []

    # The first frame lands as a deep hit. The kick plays on every beat, muffled as if through a wall
    # under the hook, then full; it stops with the rhythm and comes back on the drop.
    drums.add(0, s.deep_kick(0.9), gain=0.6, wet=0.1)
    fx.add(0, s.boom(1.6, 0.8), gain=0.22, wet=0.3)
    for beat in playing(1, LAST, 1):
        kick = s.kick(0.95)
        if beat < S1:
            drums.add(at(beat), s.lowpass(kick, 220), gain=0.5, wet=0.02)
        else:
            drums.add(at(beat), kick, gain=0.56 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))

    # The backbeat from the third step, and a roll of sixteenths up to the stop, rising as it comes.
    for beat in [b for b in playing(S3, LAST, 1) if b % BAR in (1, 3) and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.snare(0.9, tone=190), gain=0.4, pan_to=0.05, wet=0.22)
    roll = np.arange(S4 + 2, STOP, 0.25)
    for i, beat in enumerate(roll):
        p = i / max(1, len(roll) - 1)
        drums.add(at(beat), s.snare(0.4 + 0.55 * p, tone=180 + 70 * p, length=0.16), gain=0.3, pan_to=0.05, wet=0.2)

    # Closed hats in sixteenths from the first step; open ones on the offbeats from the second.
    for beat in playing(S1, LAST, 0.25):
        weight = (1.0, 0.4, 0.65, 0.4)[int(round(beat * 4)) % 4]
        drums.add(at(beat), s.hat(weight), gain=0.09 * swell(beat), pan_to=0.3, wet=0.05)
    for beat in playing(S2 + 0.5, LAST, 1):
        drums.add(at(beat), s.hat(0.8, open=True), gain=0.07 * swell(beat), pan_to=-0.25, wet=0.12)

    # The bass rolls in sixteenths between the kicks, its filter opening through the steps and the
    # build; the last chord's root holds and dies away.
    for beat in np.arange(0, LAST, 1):
        if STOP <= beat < DROP:
            continue
        root, _ = CHORDS[chord_at(beat)]
        bright = (0.12 if beat < S1 else opening(beat, S1, S3, 0.22, 0.4) if beat < S3
                  else opening(beat, S3, STOP, 0.42, 0.7) if beat < DROP else 0.9)
        for offset, note, velocity in ((0.25, root, 0.8), (0.5, root, 0.66), (0.75, root + 12, 0.74)):
            if STOP <= beat + offset < DROP:
                continue
            low.add(at(beat + offset), s.bass(note, velocity, 0.13, bright=bright), gain=0.36 * swell(beat), wet=0.04)
    low.add(at(LAST), dying(s.bass(50, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)
    low.add(at(LAST), dying(s.sub(38, 2.5, 0.8), 0.8), gain=0.22, wet=0.0)

    # A dark bed under everything, opening as it goes; the build's last chord holds through the stop.
    for name, first, length in sheet["chords"]:
        _, voicing = CHORDS[name]
        last = first == LAST
        seconds = (DROP - first) if first + length == DROP else length
        cutoff = 900 if first >= DROP else opening(first, 0, S4, 360, 820)
        bed = s.drone(voicing, at(seconds) if not last else 2.6, cutoff=cutoff, release=1.6 if last else 0.15,
                      attack=0.4 if first == 0 else 0.05)
        pads.add(at(first), dying(bed, 1.1) if last else bed, gain=0.3 * swell(first), wet=0.35)

    # From the drop, dark chord stabs on the offbeats, and an arpeggio in sixteenths.
    for beat in playing(DROP, LAST, 1):
        _, voicing = CHORDS[chord_at(beat)]
        pads.add(at(beat + 0.5), s.stab([n + 12 for n in voicing], 0.8, 0.22, cutoff=2300), gain=0.17, wet=0.25)
    for i, beat in enumerate(playing(DROP, LAST, 0.25)):
        _, voicing = CHORDS[chord_at(beat)]
        note = [n + 12 for n in voicing][(0, 2, 1, 3)[i % 4]]
        lead.add(at(beat), s.pluck(note, 0.7, 0.16, bright=0.45), gain=0.1, pan_to=(-0.35, 0.35)[i % 2], wet=0.3)

    # The riff on two detuned saws, with an echo a dotted eighth later either side; the head on the
    # drop doubled an octave up.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.saw_lead(note, beats * BEAT * 0.92, 0.9, cutoff=2600 if beat >= DROP else 2000)
        if last:
            tone = dying(tone, 1.0)
        level = 0.55 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.25)
        lead.add(at(beat + 0.75), s.lowpass(tone, 1600), gain=level * 0.3, pan_to=-0.5, wet=0.45)
        lead.add(at(beat + 1.5), s.lowpass(tone, 1100), gain=level * 0.12, pan_to=0.5, wet=0.55)
        if DROP <= beat < cue["endLine"]:
            lead.add(at(beat), s.saw_lead(note + 12, beats * BEAT * 0.9, 0.6, cutoff=3200), gain=level * 0.35, wet=0.35)

    # The build: a riser through the fourth step, and the hit's own reverb swelling up into the drop.
    hit = s.stab([n + 12 for n in CHORDS["Dm9"][1]], 1.0, 1.2, cutoff=3000)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.09, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.22, wet=0.0)

    # The drop: a deep kick under the boom, the chord at full width, and a dark crash.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.7, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.26, wet=0.3)
    pads.add(at(DROP), hit, gain=0.24, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6000), gain=0.2, wet=0.35)
    # A swell into the flip, and a hit on the call to action.
    fx.add(at(cue["flip"] - 1), s.swell_into(s.crash(0.6, 2.0, decay=0.9), BEAT, room), gain=0.05, wet=0.0)
    pads.add(at(cue["cta"]), s.stab([n + 12 for n in CHORDS[chord_at(cue["cta"])][1]], 0.9, 0.5, cutoff=2600), gain=0.2, wet=0.3)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.6, 2.0, decay=0.9), 5000), gain=0.12, wet=0.35)

    # The last hit, and the chord left to die away.
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.7, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.24, wet=0.3)
    pads.add(at(LAST), dying(s.stab([n + 12 for n in CHORDS["Dm9"][1]], 0.9, 2.4, cutoff=2200), 1.0), gain=0.2, wet=0.4)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 5500), gain=0.16, wet=0.4)

    develop(fx, room)
    sounds(fx)

    pump = s.sidechain(TOTAL + 4, kicks, depth=0.5, release=0.17)
    low.duck(1 - 0.55 * (1 - pump))
    pads.duck(1 - 0.35 * (1 - pump))
    trim(drums, 55)
    trim(low, 60)
    trim(fx, 45)
    return [drums, low, pads, lead, fx], dict(room=room, wet=0.5, presence=3.0)


# Each chord's spiccato figure, eight sixteenths played twice a bar: the root, its fifth, its third and
# a passing note, as the star promo's ostinato.
FIGURES = {
    "Dm9": [50, 50, 57, 50, 53, 50, 52, 50],
    "Bbmaj7": [46, 46, 53, 46, 50, 46, 48, 46],
    "Gm9": [43, 43, 50, 43, 46, 43, 45, 43],
    "A7sus": [45, 45, 52, 45, 50, 45, 52, 45],
    "C6": [48, 48, 55, 48, 52, 48, 50, 48],
    "A7": [45, 45, 52, 45, 49, 45, 52, 45],
}
CLUSTER = [26, 38, 45, 50, 53]


def pulse(sounds=ui):
    start(47)
    room = s.reverb(3.0, 0.75, 0.025)
    drums, low, bows, keys, fx = (s.Bus(TOTAL + 4) for _ in range(5))
    kicks = []

    # The first frame lands as a deep hit over a drone on D, which holds to the stop.
    fx.add(0, s.boom(2.4, 1.0), gain=0.28, wet=0.35)
    drums.add(0, s.taiko(0.6, 58, 1.6), gain=0.5, wet=0.3)
    low.add(0, s.drone([38, 45, 50], at(STOP) - 0.02, cutoff=520, release=0.05, attack=0.2), gain=0.5, wet=0.3)

    # Spiccato sixteenths from the first frame, from a murmur to full at the stop, and full after it.
    for i in range(int(LAST * 4)):
        beat = i / 4
        if STOP <= beat < DROP:
            continue
        p = opening(beat, 0, STOP, 0.45, 1.0) if beat < DROP else 1.0
        accent = 1.0 if i % 4 == 0 else 0.8 if i % 2 == 0 else 0.62
        figure = FIGURES[chord_at(beat)]
        bows.add(at(beat), s.spiccato(figure[i % 8], (0.35 + 0.65 * p) * accent, bright=0.3 + 0.55 * p), gain=0.5, wet=0.3)

    # A watch ticks in eighths, then in sixteenths from the third step.
    for beat in playing(0, LAST, 0.5) + playing(S3 + 0.25, LAST, 0.5):
        main = beat % 1 == 0
        fx.add(at(beat), s.tock(0.7 if main else 0.5, 2300 if main else 1900), gain=0.07 * swell(beat), pan_to=0.35, wet=0.12)

    # Taiko on the bar lines; a heartbeat of deep kicks in the first steps; from the third step, a kick
    # on the first and third beats and the film snare on the second and fourth.
    for beat, velocity in ((S1, 0.75), (S2, 0.85), (S3, 0.95), (S4, 0.9)):
        drums.add(at(beat), s.taiko(velocity, 58, 1.6), gain=0.5, wet=0.35)
    for beat in playing(S1, S3, 1):
        drums.add(at(beat), s.lowpass(s.deep_kick(0.75), 240), gain=0.55, wet=0.1)
        kicks.append(at(beat))
    for beat in playing(S3, LAST, 1):
        if beat % 2 == 0:
            drums.add(at(beat), s.deep_kick(0.9), gain=0.62, wet=0.08)
            kicks.append(at(beat))
        elif not S4 + 2 <= beat < DROP:
            drums.add(at(beat), s.big_snare(0.85), gain=0.42, wet=0.4)
    # Low toms through the fourth step, doubling from eighths to sixteenths to thirty-seconds.
    for first, last, step in ((S4, S4 + 2, 0.5), (S4 + 2, S4 + 3, 0.25), (S4 + 3, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4) / (STOP - S4)
            drums.add(at(beat), s.taiko(0.3 + 0.6 * p, 88 + 40 * p, 0.45, decay=0.14), gain=0.4,
                      pan_to=0.18 if int(beat / step) % 2 else -0.18, wet=0.22)

    # The bass in eighths on the root from the second step.
    for beat in playing(S2, LAST, 0.5):
        root, _ = CHORDS[chord_at(beat)]
        low.add(at(beat), s.bass(root, 0.9 if beat % 1 == 0 else 0.62, 0.22, bright=0.35), gain=0.42 * swell(beat), wet=0.05)

    # The strings hold each chord from the first step, opening as they go; the build's last chord holds
    # on through the stop and swells into the drop.
    for name, first, length in sheet["chords"]:
        if first < S1:
            continue
        _, voicing = CHORDS[name]
        last = first == LAST
        held = first + length == DROP
        seconds = 2.4 if last else length * BEAT
        p = opening(first, S1, DROP, 0.2, 0.9) if first < DROP else 0.75
        for note in voicing:
            tone = s.strings(note, seconds, bright=(p * 0.7, p), attack=0.25, release=1.6 if last else 0.3)
            if held:
                tone = tone * (np.linspace(1, 1.8, len(tone)) ** 1.5)[:, None]
            bows.add(at(first), dying(tone, 1.1) if last else tone, gain=0.13 * swell(first), wet=0.45)

    # The riff, on the strings with the piano an octave down marking each note.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.strings(note, 0.6 if last else beats * BEAT * 0.95, bright=(0.45, 0.65), attack=0.05,
                         release=2.0 if last else 0.25, voices=6, vibrato=0.0045)
        bows.add(at(beat), tone, gain=0.22 * swell(beat), wet=0.45)
        keys.add(at(beat), s.piano(note - 12, 0.4, 3.0 if last else 1.6), gain=0.3, pan_to=0.12, wet=0.45)

    # The Shepard tone climbs from the first step, faster through the build, into the drop.
    n = int(at(DROP) * s.SR)
    t = np.arange(n) / s.SR
    p = np.clip((t - at(S1)) / (at(DROP) - at(S1)), 0, 1)
    level = 0.9 * p ** 1.3 * np.clip((at(DROP) - t) / 0.03, 0, 1)
    fx.add(0, s.shepard(0.1 + 1.6 * p ** 2.5, level), gain=0.12, wet=0.35)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 200, 5500, curve=2.4), gain=0.08, wet=0.4)

    # The drop: the trailer's low brass, its reverb swelling up into it from the stop.
    hit = s.braam(CLUSTER, 3.2, 1.0)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.28, wet=0.0)
    low.add(at(DROP), hit, gain=0.5, wet=0.35)
    drums.add(at(DROP), s.taiko(1.0, 52, 2.0), gain=0.7, wet=0.35)
    fx.add(at(DROP), s.boom(2.6, 1.1), gain=0.28, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(1.0, 3.6, decay=1.5), 6500), gain=0.24, wet=0.4)
    # Taiko on the flip and the call to action.
    for beat, velocity in ((cue["flip"], 0.7), (cue["cta"], 0.85)):
        drums.add(at(beat), s.taiko(velocity, 56, 1.6), gain=0.45, wet=0.35)

    # The last hit, shorter than the first, and the piano alone as the chord dies away.
    drums.add(at(LAST), s.taiko(1.0, 50, 2.2), gain=0.7, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.75, wet=0.1)
    kicks.append(at(LAST))
    low.add(at(LAST), s.braam(CLUSTER, 2.4, 0.85), gain=0.42, wet=0.4)
    fx.add(at(LAST), s.boom(2.0, 0.9), gain=0.24, wet=0.3)
    for beat, note, velocity in ((LAST + 1, 69, 0.34), (LAST + 2.5, 74, 0.28)):
        keys.add(at(beat), s.piano(note, velocity, 3.0), gain=0.3, pan_to=0.1, wet=0.55)

    develop(fx, room)
    sounds(fx)

    pump = s.sidechain(TOTAL + 4, kicks, depth=0.45, release=0.2)
    low.duck(1 - 0.45 * (1 - pump))
    bows.duck(1 - 0.25 * (1 - pump))
    trim(drums, 55)
    trim(low, 60)
    trim(fx, 45)
    return [drums, low, bows, keys, fx], dict(room=room, wet=0.65, presence=3.0)


def toms(beat):
    """An electronic tom, higher at the start of a fill and falling with it."""
    return s.taiko(0.75, 150 - 40 * ((beat - (S4 + 2)) / (STOP - S4 - 2)), 0.35, decay=0.11)


def synthwave(sounds=ui):
    start(53)
    room = s.reverb(2.2, 0.55, 0.02)
    drums, low, pads, arps, lead, fx = (s.Bus(TOTAL + 4) for _ in range(6))
    kicks = []

    # The first frame lands as a deep hit; the pads come in slowly under the arpeggio.
    drums.add(0, s.deep_kick(0.85), gain=0.6, wet=0.12)
    fx.add(0, s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in sheet["chords"]:
        _, voicing = CHORDS[name]
        last = first == LAST
        cutoff = 2600 if first >= DROP else opening(first, 0, S4, 1100, 2300)
        pad = s.supersaw(voicing, 2.8 if last else length * BEAT, voices=6, spread=18, cutoff=cutoff,
                         attack=0.35 if first == 0 else 0.12, release=1.6 if last else 0.3)
        pads.add(at(first), dying(pad, 1.2) if last else pad, gain=0.27 * swell(first), wet=0.45)

    # The arpeggio: sixteenths up and down the chord an octave up, with an echo a dotted eighth later,
    # darker in the first bar and opening through the build.
    for i, beat in enumerate(playing(0, LAST, 0.25)):
        _, voicing = CHORDS[chord_at(beat)]
        note = [n + 12 for n in voicing][(0, 1, 2, 3, 2, 1, 3, 2)[i % 8]]
        bright = 0.4 if beat < S1 else opening(beat, S1, STOP, 0.45, 0.85) if beat < DROP else 0.8
        tone = s.pluck(note, 0.8, 0.18, bright=bright)
        arps.add(at(beat), tone, gain=0.13 * swell(beat), pan_to=(-0.3, 0.3)[i % 2], wet=0.25)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2200), gain=0.05 * swell(beat), pan_to=(0.4, -0.4)[i % 2], wet=0.4)

    # The bass jumps the octave in eighths on each chord's root from the first step; the last root dies away.
    for beat in playing(S1, LAST, 0.5):
        root, _ = CHORDS[chord_at(beat)]
        up = round(beat * 2) % 2
        low.add(at(beat), s.bass(root + 12 * up, 0.85 if not up else 0.7, 0.24, bright=0.5 if beat >= DROP else 0.35),
                gain=0.38 * swell(beat), wet=0.04)
    low.add(at(LAST), dying(s.bass(50, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)

    # The beat: a kick muffled as if through a wall under the first bar, on 1 and 3 from the first step
    # and on every beat from the third, with the gated snare on 2 and 4; a fill of falling toms into the stop.
    for beat in range(1, S1):
        drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.5, wet=0.02)
        kicks.append(at(beat))
    for beat in playing(S1, LAST, 1):
        if beat < S3 and beat % 2:
            continue
        drums.add(at(beat), s.kick(0.95), gain=0.54 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in [b for b in playing(S3, LAST, 1) if b % BAR in (1, 3) and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.gated_snare(0.9), gain=0.36, pan_to=0.05, wet=0.15)
    for beat in playing(S2, LAST, 0.5):
        drums.add(at(beat), s.hat(1.0 if beat % 1 == 0 else 0.6), gain=0.08 * swell(beat), pan_to=0.3, wet=0.06)
    for beat in playing(DROP, LAST, 0.25):
        if beat % 0.5:
            drums.add(at(beat), s.hat(0.45), gain=0.06, pan_to=0.35, wet=0.06)
    for beat in np.arange(S4 + 2, STOP, 0.25):
        drums.add(at(beat), toms(beat), gain=0.42, pan_to=0.3 - 0.6 * (beat - S4 - 2) / 1.5, wet=0.25)

    # The riff on the saw lead, with a vibrato on the long notes and an echo either side; the head on
    # the drop doubled an octave up.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.saw_lead(note, beats * BEAT * 0.94, 0.9, cutoff=3000 if beat >= DROP else 2400,
                          vibrato=0.18 if beats >= 1 else 0.0)
        if last:
            tone = dying(tone, 1.0)
        level = 0.5 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        lead.add(at(beat + 0.75), s.lowpass(tone, 1800), gain=level * 0.32, pan_to=-0.5, wet=0.5)
        lead.add(at(beat + 1.5), s.lowpass(tone, 1200), gain=level * 0.14, pan_to=0.5, wet=0.6)
        if DROP <= beat < cue["endLine"]:
            lead.add(at(beat), s.saw_lead(note + 12, beats * BEAT * 0.9, 0.55, cutoff=3600, vibrato=0.12),
                     gain=level * 0.3, wet=0.4)

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = s.stab([n + 12 for n in CHORDS["Dm9"][1]], 1.0, 1.2, cutoff=3000)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.09, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop, a hit on the call to action, and the last hit with the chord left to die away.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.68, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.22, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.22, wet=0.35)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 6000), gain=0.14, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.68, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.22, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)

    develop(fx, room)
    sounds(fx)

    pump = s.sidechain(TOTAL + 4, kicks, depth=0.5, release=0.18)
    low.duck(1 - 0.5 * (1 - pump))
    pads.duck(1 - 0.4 * (1 - pump))
    arps.duck(1 - 0.2 * (1 - pump))
    trim(drums, 55)
    trim(low, 60)
    trim(fx, 45)
    return [drums, low, pads, arps, lead, fx], dict(room=room, wet=0.55, presence=3.0)


# Each arrangement returns its buses and how they're mastered. `sounds` puts a video's own sounds on its
# effects bus; the sketches have ui's in their place.
ARRANGEMENTS = {"synthwave": synthwave, "drive": drive, "pulse": pulse}

if __name__ == "__main__":
    names = sys.argv[1:] or list(ARRANGEMENTS)
    unknown = [name for name in names if name not in ARRANGEMENTS]
    if unknown:
        sys.exit(f"No arrangement called {', '.join(unknown)}: choose from {', '.join(ARRANGEMENTS)}.")
    out = ROOT / "public/features"
    out.mkdir(parents=True, exist_ok=True)
    for name in names:
        buses, mastering = ARRANGEMENTS[name]()
        # The last 1.6 s fade out with the picture, as the last chord dies away.
        mix = s.master(buses, seconds=TOTAL, target=-14.0, ceiling=-1.0, fade=1.6, **mastering)
        s.write(out / f"theme-{name}.wav", mix)
        print(f"==> public/features/theme-{name}.wav ({TOTAL:.1f} s, {s.loudness(mix):.1f} LUFS, true peak {s.true_peak(mix):.1f} dBFS)")
