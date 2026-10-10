"""
E08's track (Camera recipes): a synthwave tune in A minor at 100 BPM, 8 bars and 19.2 seconds on the
series' cue sheet, src/features/cues.json, which scripts/features-score.py plays under the episode with
its own sounds. Its lead-in comes out of the opener's held D major chord on the notes that chord and
Am11 share, A, D and E, over a drone on A and E, and the music turns to A minor on the first hit, the
pads and the arpeggio bringing in C.

Where E01's theme climbs and falls back over i, VI, iv and V and E02's falls by fifths, this one's bass
walks down the scale a bar at a time, A, G, F and E, under Am11, G6/9, Fmaj7#11 and Em11, then on down
to D under Dm9 and back up to E7(b9) into the drop on Am11; on the end line Fmaj9 to E7(b9), and Am9 on
the last hit. E sits on top of every pad but Dm9's and E7(b9)'s, where F leans on it. The riff is two
bars of one gesture: a long note, then two sixteenths stepping up into the next, A, then C and D into E,
then F and G into A, held, and down through G and E to C, pushed in. The answer climbs the same way
from A to F and falls through E, D and B to G sharp, the leading note, held through the stop, which
rises to A on the drop; the head is the riff's first bar, whose last two sixteenths lead into the
closing phrase on the end line: A held, then down through G, E, D, B and G sharp to A on the last hit.

Its sound is its own in the same synthwave family, every part of it through a resonant filter: pads
whose filter sweeps open and shut once a chord, its peak singing through the harmonics; a wooden FM
mallet rolling up and down the chord in sixteenths, in waves of six, so each wave starts somewhere new
in the bar; a bass on the last two sixteenths of every beat, pushing into the kick, from the first step;
the riff on a resonant mono lead whose peak sings down onto each note, its long notes sliding in from
the sixteenths before them, with an echo a beat later; a kick on every beat, muffled as if through a
wall under the hook, hats on the offbeats from the first step and in sixteenths from the second, and
from the third a film snare on 2 and 4 and open hats on the offbeats; toms in triplets rising into the
stop; and from the drop the mallet doubled an octave up. On the drop the series' sting, glass struck on
A, E and B.
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
CHORDS = [("Am11", 0, 4), ("G6/9", 4, 4), ("Fmaj7#11", 8, 4), ("Em11", 12, 4), ("Dm9", 16, 2), ("E7(b9)", 18, 2),
          ("Am11", 20, 4), ("Fmaj9", 24, 2), ("E7(b9)", 26, 2), ("Am9", 28, 4)]

# Each chord: the bass's root, walking down the scale; the pads' voicing, E on top and the inner voices
# moving by step, keeping the colour notes: Am's eleventh and seventh, G's sixth and ninth, F's major
# seventh and raised eleventh, E minor's eleventh, D minor's ninth against its third, E7's minor ninth
# over its leading note; and the arpeggio's four notes above them, which on the first hit keep the
# lead-in's A, D and E and add C.
VOICINGS = {
    "Am11": (45, [55, 60, 62, 64], [69, 72, 74, 76]),
    "G6/9": (43, [57, 59, 62, 64], [69, 71, 74, 76]),
    "Fmaj7#11": (41, [57, 59, 60, 64], [69, 71, 72, 76]),
    "Em11": (40, [55, 57, 62, 64], [67, 69, 71, 74]),
    "Dm9": (38, [57, 60, 64, 65], [69, 72, 76, 77]),
    "E7(b9)": (40, [56, 59, 62, 65], [68, 71, 74, 77]),
    "Fmaj9": (41, [55, 57, 60, 64], [67, 69, 72, 76]),
    "Am9": (45, [55, 59, 60, 64], [71, 72, 76, 79]),
}


def chord(beat):
    return VOICINGS[theme.chord_at(beat, CHORDS)]


# The riff, [beat, note, beats] from where it starts: A held, C and D up into E, F and G up into A held,
# then G, E and C pushed in. The answer climbs the same way to F and falls through E, D and B to G sharp,
# held through the stop; the head is the riff's first bar; the closing phrase holds A and falls through
# G, E, D, B and G sharp to A on the last hit.
MOTIF = [(0, 69, 1.0), (1.5, 72, 0.25), (1.75, 74, 0.25), (2, 76, 1.0), (3.5, 77, 0.25), (3.75, 79, 0.25),
         (4, 81, 1.5), (5.5, 79, 0.5), (6, 76, 0.75), (6.75, 72, 1.25)]
ANSWER = MOTIF[:4] + [(3.5, 74, 0.25), (3.75, 76, 0.25), (4, 77, 1.0), (5, 76, 0.5), (5.5, 74, 0.5), (6, 71, 0.5),
                      (6.5, 68, 1.5)]
HEAD = MOTIF[:6]
CLOSE = [(0, 81, 1.5), (1.5, 79, 0.5), (2, 76, 0.75), (2.75, 74, 0.25), (3, 71, 0.5), (3.5, 68, 0.5), (4, 69, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The arpeggio's levels for a note and its echo, which the lead-in grows to.
ARP, ECHO = 0.16, 0.04


def mallet(note, velocity, bright):
    """A note of the arpeggio: a wooden bar struck by a mallet, FM at four times its pitch, its strike
    brighter as `bright` goes from 0 to 1, then ringing on as a near sine."""
    return theme.dying(s.fm(note, 0.5, velocity, ratio=4, index=0.5 + 1.5 * bright, decay=0.05), 0.22)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)[:, None] if out.ndim == 2 else np.linspace(1, 0, fade)
    return out


def synthwave(sounds=theme.ui):
    theme.start(83)
    room = s.reverb(2.4, 0.6, 0.02)
    drums, low, pads, arps, lead, fx, bed = (s.Bus(theme.LENGTH) for _ in range(7))
    kicks = []

    # The lead-in, on the notes D major and A minor share (A, D and E) over a drone on A and E, on the
    # arpeggio's own mallet; on the hit the pads and the arpeggio bring in C.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [64, 69, 74, 76], [45, 52, 57], ARP * swell(0), ECHO * swell(0),
                  tone=lambda note, grown: mallet(note, 0.8, 0.15 + 0.35 * grown))
    # The drone gives way to the bass as it comes in with the first step.
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(S1), at(S1 + 1)], [1.0, 0.0]))

    # The first frame lands as a deep hit, and the pads swell in under the arpeggio, each chord's filter
    # sweeping open and shut over it, wider through the build.
    drums.add(at(0), s.deep_kick(0.85), gain=0.6, wet=0.12)
    fx.add(at(0), s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in CHORDS:
        _, voicing, _ = VOICINGS[name]
        last = first == LAST
        top = 3400 if first >= DROP else opening(first, 0, S4, 1700, 3000)
        seconds = 2.8 if last else length * theme.BEAT
        pad = s.sweep_pad(voicing, seconds, low=420 if first < DROP else 600, high=top, period=length * theme.BEAT,
                          attack=0.25 if first == 0 else 0.12, release=1.6 if last else 0.3)
        pads.add(at(first), theme.dying(pad, 1.2) if last else pad, gain=0.24 * swell(first), wet=0.45)

    # The arpeggio: the mallet up and down the chord in sixteenths, in waves of six with the first of each
    # a little harder, so the waves drift across the bar; it brightens through the build, and from the drop
    # it's doubled an octave up.
    for i, beat in enumerate(theme.playing(0, LAST, 0.25)):
        note = chord(beat)[2][(0, 1, 2, 3, 2, 1)[i % 6]]
        bright = 0.3 if beat < S1 else opening(beat, S1, STOP, 0.35, 0.8) if beat < DROP else 0.85
        velocity = 0.85 if i % 6 == 0 else 0.68
        tone = mallet(note, velocity, bright)
        arps.add(at(beat), tone, gain=ARP * swell(beat), pan_to=(-0.35, 0.35)[i % 2], wet=0.3)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2200), gain=ECHO * swell(beat), pan_to=(0.4, -0.4)[i % 2], wet=0.45)
        if DROP <= beat:
            arps.add(at(beat), mallet(note + 12, velocity * 0.8, 0.6), gain=ARP * 0.35, pan_to=(0.5, -0.5)[i % 2],
                     wet=0.4)

    # The bass from the first step, on the last two sixteenths of every beat, pushing into the kick, the
    # second up the octave before each bar line; its filter opens through the build, and the last root
    # dies away.
    for beat in theme.playing(S1, LAST, 1):
        root = chord(beat)[0]
        bright = (opening(beat, S1, S3, 0.25, 0.4) if beat < S3 else opening(beat, S3, STOP, 0.42, 0.7)
                  if beat < DROP else 0.85)
        for offset, velocity in ((0.5, 0.85), (0.75, 0.72)):
            if STOP <= beat + offset < DROP:
                continue
            note = root + (12 if offset == 0.75 and beat % 4 == 3 else 0)
            low.add(at(beat + offset), s.bass(note, velocity, 0.2, bright=bright), gain=0.37 * swell(beat), wet=0.04)
    low.add(at(LAST), theme.dying(s.bass(45, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)

    # The beat: a kick on every beat, muffled as if through a wall under the first bar; hats on the
    # offbeats from the first step and in sixteenths from the second; from the third the film snare on 2
    # and 4 and open hats on the offbeats; toms in triplets, then twice as fast, rising into the stop.
    for beat in theme.playing(1, LAST, 1):
        if beat < S1:
            drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.5, wet=0.02)
        else:
            drums.add(at(beat), s.kick(0.95, length=0.34), gain=0.56 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in [b for b in theme.playing(S3, LAST, 1) if b % 4 in (1, 3) and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.big_snare(0.8), gain=0.34, pan_to=0.05, wet=0.3)
    for beat in theme.playing(S1 + 0.5, S2, 1):
        drums.add(at(beat), s.hat(0.9), gain=0.09 * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S2, LAST, 0.25):
        drums.add(at(beat), s.hat((1.0, 0.45, 0.7, 0.45)[round(beat * 4) % 4]), gain=0.085 * swell(beat), pan_to=0.3,
                  wet=0.06)
    for beat in theme.playing(S3 + 0.5, LAST, 1):
        drums.add(at(beat), s.hat(0.7, open=True), gain=0.06 * swell(beat), pan_to=-0.25, wet=0.12)
    for first, last, step in ((S4 + 2, S4 + 3, 1 / 3), (S4 + 3, STOP, 1 / 6)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4 - 2) / (STOP - S4 - 2)
            drums.add(at(beat), s.taiko(0.45 + 0.45 * p, 90 + 70 * p, 0.32, decay=0.1), gain=0.4,
                      pan_to=0.3 - 0.6 * p, wet=0.25)

    # The riff on the resonant lead, its long notes sliding in from the sixteenths before them, a vibrato
    # on them, and an echo a beat later, which stops on the drop and the last hit so the G sharp resolves;
    # the head on the drop doubled an octave up.
    previous = None
    for beat, note, beats in TUNE:
        last = beat >= LAST
        glide = previous[1] if previous and previous[2] <= 0.25 and previous[0] + previous[2] == beat else None
        tone = s.reso_lead(note, beats * theme.BEAT * 0.94, 0.9, glide=glide, cutoff=2000 if beat >= DROP else 1600,
                           vibrato=0.14 if beats >= 1 else 0.0)
        if last:
            tone = theme.dying(tone, 1.0)
        level = 0.62 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        echo = cut(s.lowpass(tone, 1700), (stop - beat - 1) * theme.BEAT)
        lead.add(at(beat + 1), echo, gain=level * 0.3, pan_to=-0.45, wet=0.5)
        if DROP <= beat < cue["endLine"]:
            doubled = s.reso_lead(note + 12, beats * theme.BEAT * 0.9, 0.55, glide=None if glide is None else glide + 12,
                                  cutoff=2600)
            lead.add(at(beat), doubled, gain=level * 0.3, wet=0.4)
        previous = (beat, note, beats)

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = s.sweep_pad([n + 12 for n in VOICINGS["Am11"][1]], 1.2, low=1800, high=3600, period=2.4, attack=0.01,
                      release=0.6)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.09, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop: a deep kick under the boom, the chord at full width and a dark crash; a crash on the call
    # to action; the last hit, with the chord left to die away under the mallet's last chord.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.68, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.3, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.22, wet=0.35)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 6000), gain=0.14, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.68, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.22, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)
    for note, p in zip(VOICINGS["Am9"][2], (-0.3, -0.1, 0.1, 0.3)):
        arps.add(at(LAST), s.fm(note, 3.0, 0.7, ratio=4, index=1.0, decay=0.08), gain=ARP * 0.7, pan_to=p, wet=0.5)

    theme.develop(fx, room, 69)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.5, release=0.17)
    low.duck(1 - 0.55 * (1 - pump))
    pads.duck(1 - 0.4 * (1 - pump))
    arps.duck(1 - 0.2 * (1 - pump))
    theme.trim(drums, 55)
    theme.trim(low, 60)
    theme.trim(fx, 45)
    theme.trim(bed, 45)
    return [drums, low, pads, arps, lead, fx, bed], dict(room=room, wet=0.55, presence=3.0)


ARRANGEMENTS = {"synthwave": synthwave}
