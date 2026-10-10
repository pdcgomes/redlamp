"""
E04's track (Lightroom shortcuts): a synthwave tune in F sharp minor at 100 BPM, 8 bars and 19.2 seconds
on the series' cue sheet, src/features/cues.json, which scripts/features-score.py plays under the episode
with its own sounds. Its lead-in comes out of the opener's held D major chord on the notes that chord and
F#m9 share, F sharp, A and E, over a drone on the same three, and the music turns to F sharp minor on the
first hit, the choir bringing in C sharp and G sharp.

Where E01's theme climbs and falls back over i, VI, iv and V, and E02's falls by fifths, this one walks
up from the sixth: F#m9 under the hook, then Dmaj9, E6/9 and Amaj9 a bar each, the relative major
coming in with the full beat, and Bm9 to C#7 into the drop on F#m9; on the end line Dmaj9 to C#7, and
F#m9 on the last hit. C sharp sits in the middle of every chord. The riff is two bars, and each of the
episode's keys strikes one of its notes as it goes down: F sharp held, falling through E and C sharp to
B and back to C sharp, then E, a turn through F sharp, and up to G sharp. The answer falls the same way
and ends in the same rhythm climbing D, E, F sharp to G sharp, held through the stop, which steps down
to F sharp on the drop; the head is the riff's first bar; the closing phrase turns through G sharp and E
sharp to F sharp on the last hit.

Its sound is its own in the same synthwave family: a synth choir singing each chord on "ah"; a clean
plucked string through a chorus playing the chord in eighths, broken in thirds, with an echo a dotted
eighth later that fills the sixteenths between, as an eighties guitar's delay does; a bass from the
first step in the 3 + 3 + 2 rhythm, its third note an octave up; the riff on a chime lead, a bell's
strike over a soft square, with an echo a dotted eighth and three eighths later; the beat in half time
through the first two steps, a kick on 1 and the and of 3 and a clap on 3 over hats in eighths, then
sixteenths, and from the third four on the floor with the snare and the clap on 2 and 4 and open hats
on the offbeats; claps rolling into the stop; and choir stabs on the offbeats from the drop. On the drop
the series' sting, glass struck on F sharp, C sharp and G sharp.
"""

import importlib.util
from pathlib import Path

import numpy as np

import synth as s


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


theme = load(Path(__file__).resolve().parents[2] / "features-theme.py", "features_theme")
at, swell, opening, cue = theme.at, theme.swell, theme.opening, theme.cue
S1, S2, S3, S4, DROP, STOP, LAST = theme.S1, theme.S2, theme.S3, theme.S4, theme.DROP, theme.STOP, theme.LAST

# The chords as the cue sheet lists E01's: a name, its first beat and how many beats it lasts.
CHORDS = [("F#m9", 0, 4), ("Dmaj9", 4, 4), ("E6/9", 8, 4), ("Amaj9", 12, 4), ("Bm9", 16, 2), ("C#7", 18, 2),
          ("F#m9", 20, 4), ("Dmaj9", 24, 2), ("C#7", 26, 2), ("F#m9", 28, 4)]

# Each chord: the bass's root; the choir's voicing, C sharp in the middle of each and the voices round it
# moving by step, keeping the colour notes: the ninth against F#m's minor third, D's major seventh and
# ninth, E's sixth and ninth, A's major seventh and ninth, B minor's ninth, and C#7's E sharp, the
# leading note; and the plucked string's notes, an octave or so above.
VOICINGS = {
    "F#m9": (42, [57, 61, 64, 68], [69, 73, 76, 80]),
    "Dmaj9": (38, [57, 61, 64, 66], [66, 69, 73, 76]),
    "E6/9": (40, [56, 61, 64, 66], [68, 71, 73, 78]),
    "Amaj9": (45, [59, 61, 64, 68], [68, 71, 73, 76]),
    "Bm9": (47, [57, 61, 62, 66], [66, 69, 73, 74]),
    "C#7": (49, [56, 59, 61, 65], [65, 68, 71, 73]),
}


def chord(beat):
    return VOICINGS[theme.chord_at(beat, CHORDS)]


# The riff, [beat, note, beats] from where it starts: F sharp held, then E, C sharp, B and C sharp; then E,
# a turn through F sharp, and G sharp held. The answer ends in the same rhythm climbing D, E and F sharp
# to G sharp, held through the stop; the head is its first bar; the closing phrase turns through G sharp
# and E sharp to F sharp. The keys go down on the first beat of each bar and on the answer's third.
MOTIF = [(0, 78, 1.5), (1.5, 76, 0.5), (2, 73, 1.0), (3, 71, 0.5), (3.5, 73, 0.5),
         (4, 76, 1.0), (5, 78, 0.5), (5.5, 76, 0.5), (6, 80, 2.0)]
ANSWER = MOTIF[:5] + [(4, 74, 1.0), (5, 76, 0.5), (5.5, 78, 0.5), (6, 80, 2.0)]
HEAD = MOTIF[:5]
CLOSE = MOTIF[:2] + [(2, 80, 1.0), (3, 77, 1.0), (4, 78, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The plucked string's levels for a note and its echo, which the lead-in grows to.
ARP, ECHO = 0.3, 0.13


def guitar(note, grown=1.0, bright=0.5):
    """A note of the plucked string, darker as the lead-in starts."""
    return s.plucked(note, 0.42, 0.8, bright=bright * (0.4 + 0.6 * grown))


def tame(bus, cutoff):
    """Takes what's over `cutoff` Hz out of a bus: the clicks of a kick, a snare and a hat landing
    together, and the riser stopping dead on the drop, peak between the samples there, where the limiter
    can't catch them."""
    bus.dry = s.lowpass(bus.dry, cutoff, order=4)
    bus.send = s.lowpass(bus.send, cutoff, order=4)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)
    return out


def synthwave(sounds=theme.ui):
    theme.start(89)
    room = s.reverb(2.3, 0.58, 0.02)
    drums, low, pads, arps, lead, fx, bed = (s.Bus(theme.LENGTH) for _ in range(7))
    kicks = []

    # The lead-in, on the notes D major and F#m9 share (F sharp, A and E), on the plucked string, over a
    # drone on the same three; on the hit the choir brings in C sharp and G sharp.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [66, 69, 76, 78], [42, 45, 52], ARP * swell(0), ECHO * swell(0),
                  tone=guitar)
    # The drone gives way to the bass over the first beat it plays.
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(S1), at(S1 + 1)], [1.0, 0.0]))

    # The first frame lands as a deep hit, and the choir swells in under the plucked string.
    drums.add(at(0), s.deep_kick(0.85), gain=0.52, wet=0.12)
    fx.add(at(0), s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in CHORDS:
        _, voicing, _ = VOICINGS[name]
        last = first == LAST
        cutoff = 6000 if first >= DROP else opening(first, 0, S4, 3000, 5200)
        pad = s.choir(voicing, 2.8 if last else length * theme.BEAT, attack=0.25 if first == 0 else 0.15,
                      release=1.6 if last else 0.3, cutoff=cutoff)
        pads.add(at(first), theme.dying(pad, 1.2) if last else pad, gain=0.55 * swell(first), wet=0.5)

    # The plucked string in eighths, broken in thirds through each chord, with an echo a dotted eighth
    # later between its notes; it brightens through the build.
    for i, beat in enumerate(theme.playing(0, LAST, 0.5)):
        note = chord(beat)[2][(0, 2, 1, 3)[i % 4]]
        bright = 0.45 if beat < S1 else opening(beat, S1, STOP, 0.5, 0.85) if beat < DROP else 0.85
        tone = guitar(note, bright=bright)
        arps.add(at(beat), tone, gain=ARP * swell(beat), pan_to=(-0.2, 0.2)[i % 2], wet=0.3)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2400), gain=ECHO * swell(beat), pan_to=(0.45, -0.45)[i % 2], wet=0.45)

    # The bass from the first step in 3 + 3 + 2 sixteenths a half bar, the third an octave up, opening
    # through the steps and the build; the last root dies away.
    for half in theme.playing(S1, LAST, 2):
        for offset, up, velocity in ((0, 0, 0.9), (0.75, 0, 0.72), (1.5, 12, 0.8)):
            beat = half + offset
            if STOP <= beat < DROP:
                continue
            bright = opening(beat, S1, S3, 0.25, 0.42) if beat < S3 else opening(beat, S3, STOP, 0.45, 0.7) if beat < DROP else 0.8
            low.add(at(beat), s.bass(chord(beat)[0] + up, velocity, 0.22 if offset < 1.5 else 0.14, bright=bright),
                    gain=0.48 * swell(beat), wet=0.04)
    low.add(at(LAST), theme.dying(s.bass(42, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)

    # The beat: a kick muffled as if through a wall under the first bar; in half time through the first
    # two steps, a kick on 1 and the and of 3 and a clap on 3 in a long room, with hats in eighths, then
    # sixteenths; from the third step a kick on every beat, the snare and the clap on 2 and 4, and open
    # hats on the offbeats; and claps rolling into the stop, rising as they come.
    for beat in range(1, S1):
        drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.42, wet=0.02)
        kicks.append(at(beat))
    for beat in theme.playing(S1, LAST, 0.5):
        if ((beat % 4 not in (0, 2.5)) if beat < S3 else beat % 1) or beat == DROP:
            continue
        drums.add(at(beat), s.kick(0.95 if beat % 1 == 0 else 0.8), gain=0.54 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in theme.playing(S1 + 2, S3, 4):
        drums.add(at(beat), s.clap(0.9), gain=0.32, pan_to=-0.05, wet=0.5)
    for beat in [b for b in theme.playing(S3, LAST, 1) if b % 4 in (1, 3) and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.snare(0.85, tone=195), gain=0.34, pan_to=0.05, wet=0.22)
        drums.add(at(beat), s.clap(0.8), gain=0.22, pan_to=-0.05, wet=0.3)
    for beat in theme.playing(S1, S2, 0.5):
        drums.add(at(beat), s.hat(1.0 if beat % 1 == 0 else 0.7), gain=0.1 * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S2, LAST, 0.25):
        weight = (1.0, 0.45, 0.7, 0.45)[round(beat * 4) % 4]
        drums.add(at(beat), s.hat(weight), gain=0.09 * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S3 + 0.5, LAST, 1):
        drums.add(at(beat), s.hat(0.7, open=True), gain=0.06 * swell(beat), pan_to=-0.25, wet=0.12)
    for first, last, step in ((S4 + 2, S4 + 3, 0.25), (S4 + 3, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4 - 2) / (STOP - S4 - 2)
            drums.add(at(beat), s.clap(0.45 + 0.5 * p), gain=0.34, pan_to=-0.25 + 0.5 * p, wet=0.3)

    # The riff on the chime lead, a vibrato on the long notes, and an echo a dotted eighth and three
    # eighths later either side, which stops on the drop and the last hit; the head on the drop doubled
    # an octave up.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.chime_lead(note, beats * theme.BEAT * 0.94, 0.9, cutoff=3400 if beat >= DROP else 3000,
                            vibrato=0.14 if beats >= 1 else 0.0)
        if last:
            tone = theme.dying(tone, 1.2)
        level = 0.6 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        for later, cutoff, share, p, wet in ((0.75, 1900, 0.3, -0.5, 0.5), (1.5, 1300, 0.13, 0.5, 0.6)):
            echo = cut(s.lowpass(tone.mean(axis=1), cutoff), (stop - beat - later) * theme.BEAT)
            lead.add(at(beat + later), echo, gain=level * share, pan_to=p, wet=wet)
        if DROP <= beat < cue["endLine"]:
            lead.add(at(beat), s.chime_lead(note + 12, beats * theme.BEAT * 0.9, 0.55, cutoff=3800), gain=level * 0.3, wet=0.4)

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = s.choir([n + 12 for n in VOICINGS["F#m9"][1]], 1.0, attack=0.008, release=0.8)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.09, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop: a deep kick under the boom in the beat's kick's place, the choir's chord, a dark crash;
    # then choir stabs on the offbeats to the last hit, a crash on the call to action, and the last hit
    # with the chord left to die away under the plucked string's last chord, strummed.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.68, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.32, wet=0.35)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.22, wet=0.35)
    for beat in theme.playing(DROP, LAST, 1):
        stab = s.choir([n + 12 for n in chord(beat)[1]], 0.16, attack=0.006, release=0.12)
        pads.add(at(beat + 0.5), stab, gain=0.2, wet=0.3)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 6000), gain=0.14, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.68, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.22, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)
    for k, (note, p) in enumerate(zip(VOICINGS["F#m9"][2], (-0.3, -0.1, 0.1, 0.3))):
        arps.add(at(LAST + k * 0.125), s.plucked(note, 3.0, 0.7, bright=0.4, damp=0.999), gain=ARP * 0.7, pan_to=p, wet=0.5)

    theme.develop(fx, room, 78)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.5, release=0.17)
    low.duck(1 - 0.55 * (1 - pump))
    pads.duck(1 - 0.35 * (1 - pump))
    arps.duck(1 - 0.2 * (1 - pump))
    theme.trim(drums, 55)
    tame(drums, 12000)
    theme.trim(low, 60)
    theme.trim(fx, 45)
    tame(fx, 16000)
    theme.trim(bed, 45)
    return [drums, low, pads, arps, lead, fx, bed], dict(room=room, wet=0.55, presence=3.0)


ARRANGEMENTS = {"synthwave": synthwave}
