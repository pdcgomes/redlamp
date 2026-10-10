#!/usr/bin/env python3
"""
The feature videos' theme (src/features/): one tune in F major at 100 BPM, 8 bars and 19.2 seconds,
in three arrangements for the owner to choose between by ear, written from the series' cue sheet,
src/features/cues.json, so every sound lands on the frame its picture does.

    python3 scripts/features-theme.py              # public/features/theme-chip.wav, theme-felt.wav, theme-strings.wav
    python3 scripts/features-theme.py felt         # one of them

A soft chord and a gentle hit on the first frame, rising into a two-bar motif (up a sixth from C to
A, down a step to G, then falling an octave) on the first step, answered on the third as the
arrangement fills in; its head over struck glass at the result, the same in every video; the head
once more from the end line, closing on F through B flat minor, and the last chord dying away as the
picture fades. A quiet click on each step and a tick on the flip, where the videos' own sounds go.

- chip: a sound chip's four channels, warmed: a soft square lead with an echo, a second pulse
  breaking the chords, the triangle's bass and the noise channel's drums.
- felt: the same lead over a felt piano, a soft kit and a little vinyl crackle far back.
- strings: a felt piano and a string section carrying the motif, a chip blip on its head.

Needs numpy.
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
LAST = sheet["chords"][-1][1]


def at(beat):
    return beat * BEAT


# Each chord: its root, for the bass, and its voicing without the root, from the third or the seventh
# up, with the colour notes that make it warm (a major seventh, a ninth, a sixth).
CHORDS = {
    "Bbmaj9": (46, [57, 60, 62, 65]),
    "Am7": (45, [55, 60, 64, 69]),
    "Dm9": (38, [53, 57, 60, 64]),
    "Gm9": (43, [58, 62, 65, 69]),
    "C9sus": (48, [58, 62, 65, 67]),
    "Fmaj9": (41, [57, 60, 64, 67]),
    "Bbm6": (46, [55, 58, 61, 65]),
}
F_MAJOR = {5, 7, 9, 10, 0, 2, 4}

# The tune, [beat, note, beats] from where each part starts. The motif goes up a sixth from C to A,
# down a step to G, then falls an octave to A; its answer climbs to B flat instead and is left open
# on G. Its head comes at the result in every video, and from the end line closes on F.
MOTIF = [(0, 72, 0.5), (0.5, 81, 1), (1.5, 79, 1.5), (3, 76, 0.5), (3.5, 77, 0.5),
         (4, 76, 1.5), (5.5, 74, 0.5), (6, 72, 0.5), (6.5, 69, 1.5)]
ANSWER = MOTIF[:3] + [(3, 77, 0.5), (3.5, 79, 0.5), (4, 81, 1.5), (5.5, 82, 0.5), (6, 81, 0.5), (6.5, 79, 1.5)]
HEAD = [(0, 72, 0.5), (0.5, 81, 1.5), (2, 79, 2)]
CLOSE = HEAD + [(4, 77, 4)]
# The first chord's top notes, one a beat, rising into the motif.
RISE = [(1, 62, 1), (2, 65, 1), (3, 69, 1)]


def placed(first, part):
    return [(first + beat, note, beats) for beat, note, beats in part]


TUNE = placed(cue["step1"], MOTIF) + placed(cue["step3"], ANSWER) + placed(cue["result"], HEAD) + placed(cue["endLine"], CLOSE)
HEADS = placed(cue["step1"], MOTIF[:3]) + placed(cue["step3"], ANSWER[:3]) + placed(cue["result"], HEAD) + placed(cue["endLine"], CLOSE[:3])

# How fully the arrangement plays from each cue: soft for the hook, growing through the steps to the
# result, then easing for the end line and the last chord.
SWELL = [(cue["hook"], 0.72), (cue["step1"], 0.75), (cue["step3"], 0.88), (cue["result"], 1.0), (cue["endLine"], 0.86), (LAST, 0.8)]


def swell(beat):
    return [level for first, level in SWELL if first <= beat][-1]


def chords():
    return [(name, first, length) for name, first, length in sheet["chords"]]


def step_toward(target, below):
    """The note of the scale a step below `target` (or above it), to lead the bass into it."""
    note = target - 1 if below else target + 1
    while note % 12 not in F_MAJOR:
        note += -1 if below else 1
    return note


def bassline():
    """
    The bass, [beat, note, beats]: each chord's root, held in the first bar and from the end line;
    under the motif on 1 and the and of 3; from the answer to the flip on 1 and the and of 2, then
    the fifth, and a step into the next chord.
    """
    notes = []
    progression = chords()
    for k, (name, first, length) in enumerate(progression):
        root, _ = CHORDS[name]
        if first == LAST:
            notes.append((first, root, length))
        elif first < cue["step1"] or first >= cue["endLine"]:
            notes.append((first, root, length - 0.25))
        elif first < cue["step3"]:
            notes += [(first, root, 1.75), (first + 2.5, root, 1.25)]
        else:
            notes += [(first, root, 1.25), (first + 1.5, root, 0.5)]
            if length == BAR:
                following = CHORDS[progression[k + 1][0]][0]
                notes += [(first + 2.5, root + 7, 0.75), (first + 3.5, step_toward(following, following > root), 0.5)]
    return notes


def half_time(first, last, hats, ghost=False):
    hits = []
    for bar in range(first, last, BAR):
        hits += [(bar, "kick", 1.0), (bar + 2, "snare", 1.0)]
        if ghost:
            hits.append((bar + 3.5, "kick", 0.5))
        hits += [(bar + offset, "hat", 1.0 if offset % 1 == 0 else 0.65) for offset in np.arange(0, BAR, hats)]
    return hits


# The beat, [beat, drum, weight], in half time: the gentle hit alone on the first frame; under the
# motif a kick on 1, the snare on 3 and hats on the beat; from the answer to the flip hats in eighths
# and a light kick into each bar; hats on the beat again from the end line, and a last kick under
# the last chord.
GROOVE = ([(cue["hook"], "kick", 0.8)] + half_time(cue["step1"], cue["step3"], 1)
          + half_time(cue["step3"], cue["endLine"], 0.5, ghost=True) + half_time(cue["endLine"], LAST, 1)
          + [(LAST, "kick", 0.7)])


def start(seed):
    """Starts an arrangement's random sounds over, so it renders the same whichever are rendered with it."""
    s.reset(seed)
    s._pianos.clear()


def dying(x, seconds):
    """`x`, dying away by 1/e every `seconds`."""
    fall = np.exp(-np.arange(len(x)) / s.SR / seconds)
    return x * (fall[:, None] if x.ndim == 2 else fall)


def play(drums, kit):
    """The beat on a kit, {drum: (sound of a weight, gain, pan, wet)}. Returns the kicks' times, for the sidechain."""
    kicks = []
    for beat, drum, weight in GROOVE:
        sound, gain, pan_to, wet = kit[drum]
        drums.add(at(beat), sound(weight), gain=gain * swell(beat), pan_to=pan_to, wet=wet)
        if drum == "kick":
            kicks.append(at(beat))
    return kicks


def sing(lead, gain):
    """The tune on a soft square: low-passed, with a gentle vibrato and a dotted-eighth echo either side."""
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.pulse(note, beats * BEAT * 0.94, 0.9 if beats >= 1 else 0.78, duty=0.5, vibrato=0.15, attack=0.01,
                       decay=1.2 if last else 0.35, sustain=0.0 if last else 0.6, release=0.1, warmth=2600)
        tone = s.lowpass(tone, 3400)
        level = gain * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, pan_to=0.05, wet=0.25)
        lead.add(at(beat + 0.75), s.lowpass(tone, 1800), gain=level * 0.3, pan_to=-0.5, wet=0.45)
        lead.add(at(beat + 1.5), s.lowpass(tone, 1200), gain=level * 0.12, pan_to=0.5, wet=0.55)


def strike(keys, first, velocity, dies=None):
    """
    The chord at `first` on the felt piano: its root and fifth in the left hand, then the voicing,
    rolled a little, as full as the swell. Its notes are damped as the next chord comes in, as a
    pedal is changed, or let go to die away by 1/e every `dies` seconds.
    """
    name, length = [(name, length) for name, start, length in chords() if start == first][0]
    root, voicing = CHORDS[name]
    level = swell(first)

    def key(note, v):
        if dies:
            return dying(s.piano(note, v, 4.0), dies)
        return s.piano(note, v, length * BEAT + 0.3)

    keys.add(at(first), key(root, velocity), gain=0.4 * level, pan_to=-0.2, wet=0.35)
    keys.add(at(first), key(root + 7, velocity * 0.6), gain=0.24 * level, pan_to=-0.15, wet=0.35)
    for i, note in enumerate(voicing):
        keys.add(at(first + 0.02 * (i + 1)), key(note, velocity * 0.85), gain=0.36 * level, pan_to=(note - 62) / 24, wet=0.45)


def rise(keys):
    """The first chord's top notes on the felt piano, one a beat, each held until the motif comes in."""
    for beat, note, beats in placed(cue["hook"], RISE):
        tone = s.piano(note, 0.36, at(cue["step1"] - beat) + 0.3)
        keys.add(at(beat), tone, gain=0.36, pan_to=(note - 62) / 24, wet=0.5)


def develop(bus, room):
    """The sting under the result's head, the same in every video: glass struck on F, C and G, its own reverb swelling up into it."""
    struck = sum(s.pan(s.glass(note, 4.0, velocity), p) for note, velocity, p in ((77, 0.9, -0.3), (84, 0.7, 0.2), (91, 0.5, 0.45)))
    bus.add(at(cue["result"] - 1), s.swell_into(struck, BEAT, room), gain=0.07, wet=0.0)
    bus.add(at(cue["result"]), struck, gain=0.3, wet=0.5)


def ui(fx):
    """Where each video's own sounds will sit, quiet: a click on every step and a tick on the flip."""
    for beat in STEPS:
        fx.add(at(beat), s.click(0.8), gain=0.14, pan_to=0.25, wet=0.05)
    fx.add(at(cue["flip"]), s.tick(0.7), gain=0.16, pan_to=0.25, wet=0.1)


# ---------------------------------------------------------------- the arrangements


def chip(sounds=ui):
    start(31)
    room = s.reverb(1.6, 0.42, 0.015)
    drums, low, pulse2, lead, fx = (s.Bus(TOTAL + 4) for _ in range(5))
    kicks = play(drums, {
        "kick": (lambda w: s.lowpass(s.chip_kick(0.85 * w), 2500), 0.5, 0.0, 0.05),
        "snare": (lambda w: s.lowpass(s.chip_snare(0.5 * w, 0.15), 5000), 0.34, 0.1, 0.2),
        "hat": (lambda w: s.chip_hat(0.5 * w), 0.2, 0.3, 0.08),
    })
    for beat, note, beats in bassline():
        last = beat >= LAST
        tone = s.triangle(note, beats * BEAT * 0.92, 0.9, release=0.6 if last else 0.03)
        low.add(at(beat), dying(tone, 1.0) if last else tone, gain=0.24 * swell(beat), wet=0.05)

    # The second pulse: the first and last chords whole, as a fast arpeggio; between them the chords
    # broken, in quarters under the motif and in eighths from the answer.
    def note_on(beat, note, beats):
        tone = s.pulse(note, beats * BEAT * 0.8, 0.7, duty=0.25, attack=0.003, decay=0.14, sustain=0.35, release=0.05, warmth=2200)
        pulse2.add(at(beat), tone, gain=0.4 * swell(beat), pan_to=-0.3, wet=0.3)

    for name, first, length in chords():
        _, voicing = CHORDS[name]
        if first in (cue["hook"], LAST):
            whole = s.arp(voicing, length * BEAT, 0.7, rate=24, duty=0.25, release=0.3, warmth=2000)
            pulse2.add(at(first), dying(whole, 1.0), gain=0.4 * swell(first), pan_to=-0.25, wet=0.35)
            continue
        step, order = ((1, (0, 1, 2, 3)) if first < cue["step3"] else (0.5, (0, 2, 1, 3)))
        for i, beat in enumerate(np.arange(first, first + length, step)):
            note_on(beat, voicing[order[i % 4]], step)
    for beat, note, beats in placed(cue["hook"], RISE):
        note_on(beat, note, beats)

    sing(lead, 0.42)
    # The result's head, doubled an octave up on a thin pulse over the glass.
    for beat, note, beats in placed(cue["result"], HEAD):
        lead.add(at(beat), s.pulse(note + 12, beats * BEAT * 0.9, 0.6, duty=0.125, vibrato=0.12, warmth=3000),
                 gain=0.14, pan_to=-0.2, wet=0.4)
    develop(fx, room)
    sounds(fx)

    pump = s.sidechain(TOTAL + 4, kicks, depth=0.35, release=0.15)
    low.duck(1 - 0.4 * (1 - pump))
    pulse2.duck(1 - 0.25 * (1 - pump))
    return [drums, low, pulse2, lead, fx], dict(room=room, wet=0.6, presence=3.0)


def felt(sounds=ui):
    start(37)
    room = s.reverb(2.2, 0.55, 0.02)
    drums, keys, lead, fx = (s.Bus(TOTAL + 4) for _ in range(4))
    kicks = play(drums, {
        "kick": (lambda w: s.lowpass(s.deep_kick(0.7 * w), 900), 0.32, 0.0, 0.08),
        "snare": (lambda w: s.lowpass(s.snare(0.5 * w, tone=190, length=0.2, snap=0.55), 4500), 0.24, 0.08, 0.35),
        "hat": (lambda w: s.lowpass(s.hat(0.5 * w), 9000), 0.11, 0.3, 0.1),
    })
    # The piano: each chord rolled, and struck again on the and of 2 under the motif and its answer.
    for name, first, length in chords():
        _, voicing = CHORDS[name]
        strike(keys, first, 0.45, dies=1.2 if first == LAST else None)
        if length == BAR and cue["step1"] <= first < cue["result"]:
            for i, note in enumerate(voicing):
                tone = s.piano(note, 0.3, (length - 1.5) * BEAT + 0.3)
                keys.add(at(first + 1.5 + 0.02 * i), tone, gain=0.3 * swell(first), pan_to=(note - 62) / 24, wet=0.45)
    rise(keys)

    sing(lead, 0.5)
    fx.add(at(cue["hook"]), s.lowpass(s.crackle(TOTAL + 1, lambda t: 14, lambda t: 0.6), 7500), gain=0.035, wet=0.4)
    develop(fx, room)
    sounds(fx)

    pump = s.sidechain(TOTAL + 4, kicks, depth=0.35, release=0.18)
    keys.duck(1 - 0.15 * (1 - pump))
    return [drums, keys, lead, fx], dict(room=room, wet=0.7, presence=3.0)


def strings(sounds=ui):
    start(41)
    room = s.reverb(3.0, 0.7, 0.025)
    drums, low, bows, keys, fx = (s.Bus(TOTAL + 4) for _ in range(5))
    kicks = play(drums, {
        "kick": (lambda w: s.lowpass(s.deep_kick(0.6 * w), 700), 0.32, 0.0, 0.1),
        "snare": (lambda w: s.lowpass(s.snare(0.45 * w, tone=175, length=0.25, snap=0.45), 3500), 0.24, 0.05, 0.45),
        "hat": (lambda w: s.lowpass(s.hat(0.4 * w), 8000), 0.08, 0.3, 0.12),
    })
    # The piano: each chord, softly after the first, rising into the motif; then the tune over them.
    for name, first, length in chords():
        strike(keys, first, 0.42 if first == 0 else 0.3, dies=1.2 if first == LAST else None)
    rise(keys)
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.piano(note, 0.55 if beats >= 1 else 0.48, 4.0 if last else beats * BEAT + 0.5)
        keys.add(at(beat), dying(tone, 1.4) if last else tone, gain=0.55, pan_to=0.1, wet=0.45)

    # The strings: the chords, from a murmur on the first frame, the cellos on the roots, and the
    # tune with the piano from the answer on; the last chord let go to die away.
    for name, first, length in chords():
        root, voicing = CHORDS[name]
        last = first == LAST
        seconds, release = (0.6, 2.4) if last else (length * BEAT, 0.5)
        for note in voicing:
            tone = s.strings(note, seconds, bright=(0.25, 0.4), attack=0.6 if first == 0 else 0.25, release=release)
            bows.add(at(first), tone, gain=0.06 * swell(first), wet=0.5)
        low.add(at(first), s.strings(root, seconds, bright=(0.3, 0.45), attack=0.15, release=release, voices=4),
                gain=0.11 * swell(first), wet=0.35)
    for beat, note, beats in TUNE:
        if beat < cue["step3"]:
            continue
        last = beat >= LAST
        tone = s.strings(note, 0.6 if last else beats * BEAT * 0.97, bright=(0.45, 0.6), attack=0.07,
                         release=2.4 if last else 0.3, voices=6, vibrato=0.0045)
        bows.add(at(beat), tone, gain=0.16 * swell(beat) ** 2, wet=0.5)
    for beat, note, beats in HEADS:
        fx.add(at(beat), s.blip(note + 12, 0.7, 0.07, duty=0.5), gain=0.1, pan_to=0.35, wet=0.4)
    develop(fx, room)
    sounds(fx)

    pump = s.sidechain(TOTAL + 4, kicks, depth=0.4, release=0.2)
    low.duck(1 - 0.4 * (1 - pump))
    bows.duck(1 - 0.2 * (1 - pump))
    return [drums, low, bows, keys, fx], dict(room=room, wet=0.7, presence=3.0)


# Each arrangement returns its buses and how they're mastered. `sounds` puts a video's own sounds on its
# effects bus; the sketches have ui's in their place.
ARRANGEMENTS = {"chip": chip, "felt": felt, "strings": strings}

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
