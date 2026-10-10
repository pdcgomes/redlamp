"""
E03's track (Film looks): a synthwave tune in E minor at 100 BPM, 8 bars and 19.2 seconds on the
series' cue sheet, src/features/cues.json, which scripts/features-score.py plays under the episode with
its own sounds. Its lead-in comes out of the opener's held D major chord on the notes that chord and Em9
share, D, E and F sharp, over a drone on the same three with E at the bottom, and the music turns to E
minor on the first hit, its third and fifth coming in with the pads.

Where E01's theme climbs and falls back and E02's chords fall by fifths, this one goes from the tonic
to its minor fifth and on to C, then lifts to A major, the brighter fourth that E minor's Dorian mode
has: Em9, Bm11, Cmaj7#11 and A6/9 a bar each; then Cmaj9, and B7sus4 letting down to B7 into the drop
on Em9; on the end line Am9 to B7, and Em9 on the last hit. The riff is two bars, each a long note and
a quick fall: B held, then A, F sharp and A onto E; then the same a third lower, G held and down through
F sharp, E and D to B. The answer plays the riff's first bar again over A major, then turns back up
from G through F sharp and E to F sharp, held through the stop, which leaps to B on the drop; the head
is the riff's first bar; the closing phrase turns through D sharp, the leading note, to E on the last
hit.

Its sound is its own in the same synthwave family, an eighties poly-synth's pulses whose width sweeps:
a pad swelling in on each chord; an arpeggio plucked in sixteenths, climbing each half bar in steps of
three, its width swinging from hollow to bright and back over two bars, with an echo a dotted eighth
later; and the riff on a lead, with an echo, doubled an octave up on the drop. Under them a bass holding
its root under the hook, then galloping on each beat, an eighth and two sixteenths, from the first step;
a kick on 1 and 3 with a push on the and of 4 and a snare in a long room on 2 and 4 from the first step,
then four on the floor and a tambourine in sixteenths from the third; and a snare roll doubling into
the stop. On the drop the series' sting, glass struck on E, B and F sharp.
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
CHORDS = [("Em9", 0, 4), ("Bm11", 4, 4), ("Cmaj7#11", 8, 4), ("A6/9", 12, 4), ("Cmaj9", 16, 2), ("B7sus4", 18, 1),
          ("B7", 19, 1), ("Em9", 20, 4), ("Am9", 24, 2), ("B7", 26, 2), ("Em9", 28, 4)]

# Each chord: the bass's root; the pads' voicing, its voices moving by step from chord to chord and
# keeping the colour notes: the ninth against Em's minor third, B minor's eleventh, C's major seventh
# and sharp eleventh, A's sixth and ninth with its major third, C sharp, and B's suspended fourth, which
# lets down to D sharp; and the arpeggio's notes, an octave or so above.
VOICINGS = {
    "Em9": (52, [55, 59, 62, 66], [64, 67, 71, 78]),
    "Bm11": (47, [54, 57, 62, 64], [62, 66, 71, 76]),
    "Cmaj7#11": (48, [52, 55, 59, 66], [60, 64, 66, 71]),
    "A6/9": (45, [54, 59, 61, 64], [61, 64, 69, 71]),
    "Cmaj9": (48, [55, 59, 62, 64], [60, 64, 67, 74]),
    "B7sus4": (47, [54, 57, 59, 64], [59, 64, 66, 69]),
    "B7": (47, [54, 57, 59, 63], [59, 63, 66, 69]),
    "Am9": (45, [55, 59, 60, 64], [57, 60, 64, 71]),
}


def chord(beat):
    return VOICINGS[theme.chord_at(beat, CHORDS)]


# The riff, [beat, note, beats] from where it starts: B held a beat and a half, A, F sharp and A, then
# E; then G held, F sharp, E and D, then B. The answer turns from G through F sharp and E back up to F
# sharp, held through the stop; the head is the riff's first bar; the closing phrase puts D sharp where
# the riff has E, and resolves to E on the last hit.
MOTIF = [(0, 83, 1.5), (1.5, 81, 0.5), (2, 78, 0.5), (2.5, 81, 0.5), (3, 76, 1.0),
         (4, 79, 1.5), (5.5, 78, 0.5), (6, 76, 0.5), (6.5, 74, 0.5), (7, 71, 1.0)]
ANSWER = MOTIF[:5] + [(4, 79, 1.5), (5.5, 78, 0.5), (6, 76, 0.5), (6.5, 78, 1.5)]
HEAD = MOTIF[:5]
CLOSE = MOTIF[:4] + [(3, 75, 1.0), (4, 76, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The arpeggio's levels for a note and its echo, which the lead-in grows to.
ARP, ECHO = 0.16, 0.06
# Which of the chord's four notes each sixteenth of a half bar plays: three steps up from the lowest,
# from the next and from the next again, so each half bar climbs.
CLIMB = (0, 1, 2, 1, 2, 3, 2, 3)


def pulsed(note, beat, bright):
    """A note of the arpeggio: a pulse plucked, its width swinging from a square to a narrow pulse and back
    over two bars, so the arpeggio turns from hollow to bright and back."""
    return s.pluck(note, 0.8, 0.16, bright=bright, partials=s.pulse_partials(0.5 - 0.3 * abs(np.sin(np.pi * beat / 8))))


def growing(note, grown):
    """A note of the arpeggio in the lead-in, darker as it starts."""
    return s.pluck(note, 0.8, 0.16, bright=0.12 + 0.25 * grown, partials=s.SQUARE)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)
    return out


def synthwave(sounds=theme.ui):
    theme.start(79)
    room = s.reverb(2.2, 0.55, 0.02)
    drums, low, pads, arps, lead, fx, bed = (s.Bus(theme.LENGTH) for _ in range(7))
    kicks = []

    # The lead-in, on the notes D major and Em9 share (D, E and F sharp), over a drone on the same three
    # with E at the bottom, on the arpeggio's pluck; the drone carries on under the first bar and gives
    # way to the bass as it comes in with the first step.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [66, 74, 76, 78], [52, 62, 66], ARP * swell(0), ECHO * swell(0),
                  tone=growing)
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(0), at(S1), at(S1 + 1)], [1.0, 1.0, 0.0]))

    # The first frame lands as a deep hit, and the pad swells in under the arpeggio, opening through the
    # build.
    drums.add(at(0), s.deep_kick(0.85), gain=0.6, wet=0.12)
    fx.add(at(0), s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in CHORDS:
        _, voicing, _ = VOICINGS[name]
        last = first == LAST
        cutoff = 2800 if first >= DROP else opening(first, 0, S4, 1400, 2400)
        pad = s.pwm_pad(voicing, 2.8 if last else length * theme.BEAT, cutoff=cutoff, attack=0.45 if first == 0 else 0.12,
                        release=1.6 if last else 0.3)
        pads.add(at(first), theme.dying(pad, 1.2) if last else pad, gain=0.2 * swell(first), wet=0.45)

    # The arpeggio in sixteenths, climbing each half bar, with an echo a dotted eighth later between its
    # notes; it brightens through the build and is doubled an octave up from the drop.
    for i, beat in enumerate(theme.playing(0, LAST, 0.25)):
        note = chord(beat)[2][CLIMB[round(beat * 4) % 8]]
        bright = 0.3 if beat < S1 else opening(beat, S1, STOP, 0.35, 0.75) if beat < DROP else 0.8
        tone = pulsed(note, beat, bright)
        arps.add(at(beat), tone, gain=ARP * swell(beat), pan_to=(-0.3, 0.3)[i % 2], wet=0.25)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2200), gain=ECHO * swell(beat), pan_to=(0.4, -0.4)[i % 2], wet=0.4)
        if beat >= DROP:
            arps.add(at(beat), pulsed(note + 12, beat, 0.6), gain=ARP * 0.45, pan_to=(0.35, -0.35)[i % 2], wet=0.3)

    # The bass holds its root under the hook, swelling in over the hit's first beat, then gallops on each
    # beat from the first step, an eighth and two sixteenths on the root, opening through the steps and
    # the build; the last root dies away.
    held = s.bass(52, 0.85, at(S1) - at(0) - 0.05, bright=0.15)
    held = held * np.clip(np.arange(len(held)) / s.SR / theme.BEAT, 0, 1)
    low.add(at(0), theme.dying(held, 2.4), gain=0.3, wet=0.08)
    for beat in theme.playing(S1, LAST, 1):
        root = chord(beat)[0]
        bright = opening(beat, S1, STOP, 0.25, 0.6) if beat < DROP else 0.75
        for offset, velocity, length in ((0, 0.9, 0.22), (0.5, 0.62, 0.12), (0.75, 0.74, 0.12)):
            if STOP <= beat + offset < DROP:
                continue
            low.add(at(beat + offset), s.bass(root, velocity, length, bright=bright), gain=0.34 * swell(beat), wet=0.04)
    low.add(at(LAST), theme.dying(s.bass(52, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)

    # The beat: a kick muffled as if through a wall under the first bar; from the first step a kick on 1
    # and 3 with a push on the and of 4, and a snare in a long room on 2 and 4, growing with the second
    # step; from the third step a kick on every beat; hats in eighths from the first step, a tambourine in
    # sixteenths from the third, and a snare roll doubling into the stop.
    for beat in range(1, S1):
        drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.5, wet=0.02)
        kicks.append(at(beat))
    for beat in theme.playing(S1, LAST, 0.5):
        if beat < S3 and beat % 4 not in (0, 2, 3.5) or beat >= S3 and beat % 1:
            continue
        drums.add(at(beat), s.kick(0.95, length=0.32, click=0.6), gain=0.54 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in [b for b in theme.playing(S1, LAST, 1) if b % 2 == 1 and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.snare(0.85, tone=196, length=0.22), gain=0.28 if beat < S2 else 0.34 if beat < S3 else 0.38,
                  pan_to=0.05, wet=0.45)
    for beat in theme.playing(S1, LAST, 0.5):
        drums.add(at(beat), s.hat(0.8 if beat % 1 else 0.5), gain=0.08 * swell(beat), pan_to=0.3, wet=0.05)
    for beat in theme.playing(S3, LAST, 0.25):
        drums.add(at(beat), s.tambourine((0.45, 0.3, 0.9, 0.3)[round(beat * 4) % 4]), gain=0.12 * swell(beat), pan_to=-0.3,
                  wet=0.15)
    for first, last, step in ((S4 + 2, S4 + 3, 0.25), (S4 + 3, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4 - 2) / (STOP - S4 - 2)
            drums.add(at(beat), s.snare(0.35 + 0.55 * p, tone=185 + 80 * p, length=0.14), gain=0.26, pan_to=-0.2 + 0.4 * p,
                      wet=0.25)

    # The riff on the lead whose pulse width sweeps, a vibrato on its long notes, and an echo a dotted
    # eighth and a dotted quarter later either side, which stops on the drop and the last hit so the held
    # note resolves; the head on the drop doubled an octave up.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        tone = s.pwm_lead(note, beats * theme.BEAT * 0.94, 0.9, cutoff=3200 if beat >= DROP else 2600,
                          vibrato=0.15 if beats >= 1 else 0.0)
        if last:
            tone = theme.dying(tone, 1.0)
        level = 0.5 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        for later, cutoff, share, p, wet in ((0.75, 1800, 0.3, -0.5, 0.5), (1.5, 1200, 0.12, 0.5, 0.6)):
            echo = cut(s.lowpass(tone.mean(axis=1), cutoff), (stop - beat - later) * theme.BEAT)
            lead.add(at(beat + later), echo, gain=level * share, pan_to=p, wet=wet)
        if DROP <= beat < cue["endLine"]:
            lead.add(at(beat), s.pwm_lead(note + 12, beats * theme.BEAT * 0.9, 0.55, cutoff=3600), gain=level * 0.36, wet=0.4)

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = s.pwm_pad([n + 12 for n in VOICINGS["Em9"][1]], 1.2, cutoff=3600, attack=0.02, release=0.6)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.08, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop: a deep kick under the boom, the pad at full width and a dark crash; a crash on the call to
    # action, and the last hit, with the arpeggio's last chord rising after it into the room.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.68, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.26, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.22, wet=0.35)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 6000), gain=0.14, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.68, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.22, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)
    for i, (note, p) in enumerate(zip(VOICINGS["Em9"][2], (-0.3, -0.1, 0.1, 0.3))):
        arps.add(at(LAST + i / 4), s.pluck(note + 12, 0.7, 0.3, bright=0.5, partials=s.SQUARE), gain=ARP * 0.9, pan_to=p,
                 wet=0.55)

    theme.develop(fx, room, 76)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.5, release=0.18)
    low.duck(1 - 0.55 * (1 - pump))
    pads.duck(1 - 0.35 * (1 - pump))
    arps.duck(1 - 0.2 * (1 - pump))
    theme.trim(drums, 55)
    theme.trim(low, 60)
    theme.trim(fx, 45)
    theme.trim(bed, 45)
    return [drums, low, pads, arps, lead, fx, bed], dict(room=room, wet=0.55, presence=3.0)


ARRANGEMENTS = {"synthwave": synthwave}
