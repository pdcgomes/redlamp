"""
E02's track (Subject mask): a synthwave tune in B minor at 100 BPM, 8 bars and 19.2 seconds on the
series' cue sheet, src/features/cues.json, which scripts/features-score.py plays under the episode with
its own sounds. Its lead-in comes out of the opener's held D major chord on the notes that chord and B
minor share, D, F sharp and A, and the music turns to the relative minor on the first hit, the bass
dropping a third from D to B under the same three notes.

Where E01's theme climbs and falls back over i, VI, iv and V, this one's chords fall by fifths, B, E,
A, D and G, to F sharp into the drop: Bm9, Em9, A13 and D6/9 a bar each, then Gmaj9 to F#7 and Bm9 on
the drop; on the end line Gmaj9 to F#7 again, and Bm9 on the last hit. Every voicing keeps F sharp on
top. The riff is two bars: up B minor from B to A, the A pushed a sixteenth early, and down by step;
then D sighing onto C sharp, A, and C sharp pushed in again. The answer ends instead on A sharp, pushed
in and held through the stop, which resolves to B on the drop; the head is the riff's first bar; the
closing phrase pushes in E where the riff has A, and falls through C sharp and A sharp to B on the last
hit. Each pushed note slides in from the note before.

Its sound is its own in the same synthwave family: a bass rolling in sixteenths from the first frame,
pumped by a kick on every beat; brass pads swelling in on each chord, as a poly-synth's do, and brass
stabs on the offbeats from the drop; an electric piano arpeggio in eighths with an echo a dotted eighth
later; claps on 2 and 4 from the second step, with a snare from the third; rising toms into the stop;
and the riff on a hollow pulse lead, with an echo a beat and two beats later. On the drop the series'
sting, glass struck on B, F sharp and C sharp.
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
CHORDS = [("Bm9", 0, 4), ("Em9", 4, 4), ("A13", 8, 4), ("D6/9", 12, 4), ("Gmaj9", 16, 2), ("F#7", 18, 2),
          ("Bm9", 20, 4), ("Gmaj9", 24, 2), ("F#7", 26, 2), ("Bm9", 28, 4)]

# Each chord: the bass's root; the pads' voicing, with F sharp on top and the inner voices moving by
# step, keeping the colour notes: the ninth against Bm's minor third, A's thirteenth over its seventh,
# D's sixth and ninth and G's major seventh; and the arpeggio's notes, an octave or so above. A's pad
# leaves its third to the riff, which comes down onto it from D, and G's leaves its ninth to the
# arpeggio, under the riff's A sharp pushed in ahead of F#7; the arpeggio leaves G to the pads, a
# semitone over their F sharp.
VOICINGS = {
    "Bm9": (47, [57, 61, 62, 66], [71, 74, 78, 85]),
    "Em9": (52, [55, 59, 62, 66], [71, 74, 78, 83]),
    "A13": (45, [55, 59, 64, 66], [69, 73, 78, 81]),
    "D6/9": (50, [57, 59, 64, 66], [69, 74, 76, 81]),
    "Gmaj9": (43, [55, 59, 62, 66], [69, 71, 74, 78]),
    "F#7": (42, [58, 61, 64, 66], [70, 73, 76, 78]),
}


def chord(beat):
    return VOICINGS[theme.chord_at(beat, CHORDS)]


# The riff, [beat, note, beats] from where it starts: B, D and F sharp, A pushed in on the last
# sixteenth of the second beat, then F sharp and E; then D onto C sharp, A, and C sharp pushed in. The
# answer ends on A sharp, held through the stop; the head is its first bar; the closing phrase pushes in
# E instead of A, and turns down through C sharp and A sharp to B on the last hit.
MOTIF = [(0, 71, 0.5), (0.5, 74, 0.5), (1, 78, 0.75), (1.75, 81, 1.25), (3, 78, 0.5), (3.5, 76, 0.5),
         (4, 74, 0.5), (4.5, 73, 0.5), (5, 69, 0.75), (5.75, 73, 2.25)]
ANSWER = MOTIF[:6] + [(4, 74, 0.5), (4.5, 73, 0.5), (5, 71, 0.75), (5.75, 70, 2.25)]
HEAD = MOTIF[:6]
CLOSE = MOTIF[:3] + [(1.75, 76, 1.25), (3, 73, 0.5), (3.5, 70, 0.5), (4, 71, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The arpeggio's levels for a note and its echo, which the lead-in grows to.
ARP, ECHO = 0.15, 0.06


def piano(note, grown):
    """A note of the arpeggio in the lead-in, darker as it starts."""
    return s.fm(note, 0.4, 0.8, index=0.8 + grown)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)
    return out


def synthwave(sounds=theme.ui):
    theme.start(73)
    room = s.reverb(2.4, 0.6, 0.02)
    drums, low, pads, arps, lead, fx, bed = (s.Bus(theme.LENGTH) for _ in range(7))
    kicks = []

    # The lead-in, on the notes D major and B minor share (A, D and F sharp), over a drone on the same
    # three, on the arpeggio's own electric piano; on the hit the bass comes in on B under them.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [69, 74, 78, 81], [50, 54, 57], ARP * swell(0), ECHO * swell(0),
                  tone=piano)
    # The drone gives way to the bass as it rolls in over the first bar.
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(0), at(S1), at(S1 + 1)], [1.0, 0.75, 0.0]))

    # The first frame lands as a deep hit, and the brass swells in under the arpeggio.
    drums.add(at(0), s.deep_kick(0.85), gain=0.6, wet=0.12)
    fx.add(at(0), s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in CHORDS:
        _, voicing, _ = VOICINGS[name]
        last = first == LAST
        cutoff = 2600 if first >= DROP else opening(first, 0, S4, 1100, 2200)
        pad = s.brass(voicing, 2.8 if last else length * theme.BEAT, 0.8, cutoff=cutoff, attack=0.45 if first == 0 else 0.12,
                      release=1.6 if last else 0.3)
        pads.add(at(first), theme.dying(pad, 1.2) if last else pad, gain=0.13 * swell(first), wet=0.45)

    # The arpeggio in eighths, through each chord and back, with an echo a dotted eighth later between
    # its notes; it brightens through the build.
    for i, beat in enumerate(theme.playing(0, LAST, 0.5)):
        note = chord(beat)[2][(0, 1, 2, 3, 2, 1, 3, 2)[i % 8]]
        index = 1.8 if beat < S1 else opening(beat, S1, STOP, 2.0, 3.0) if beat < DROP else 3.0
        tone = s.fm(note, 0.55, 0.8, index=index)
        arps.add(at(beat), tone, gain=ARP * swell(beat), pan_to=(-0.3, 0.3)[i % 2], wet=0.3)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2200), gain=ECHO * swell(beat), pan_to=(0.4, -0.4)[i % 2], wet=0.45)

    # The bass rolls in sixteenths between the kicks from the first frame, dark and growing under the
    # first bar, opening through the steps and the build, and jumping the octave on the last sixteenth of
    # the second and fourth beats, where the riff pushes in; the last root dies away.
    for beat in theme.playing(0, LAST, 0.25):
        sixteenth = round(beat * 4) % 16
        if sixteenth % 4 == 0:
            continue
        root = chord(beat)[0] + (12 if sixteenth in (7, 15) else 0)
        bright = (0.12 if beat < S1 else opening(beat, S1, S3, 0.25, 0.4) if beat < S3
                  else opening(beat, S3, STOP, 0.42, 0.75) if beat < DROP else 0.85)
        level = 0.3 * swell(beat) * (opening(beat, 0, S1, 0.55, 0.9) if beat < S1 else 1.0)
        low.add(at(beat), s.bass(root, (0.75, 0.9, 0.7)[sixteenth % 4 - 1], 0.13, bright=bright), gain=level, wet=0.04)
    low.add(at(LAST), theme.dying(s.bass(47, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)

    # The beat: a short kick on every beat, muffled as if through a wall under the first bar; hats on the
    # offbeats from the first step; claps on 2 and 4 from the second, the snare with them from the third,
    # with the hats in sixteenths and open ones on the offbeats; toms rising into the stop.
    for beat in theme.playing(1, LAST, 1):
        if beat < S1:
            drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.5, wet=0.02)
        else:
            drums.add(at(beat), s.kick(0.95, length=0.3), gain=0.54 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in [b for b in theme.playing(S2, LAST, 1) if b % 4 in (1, 3) and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.clap(0.9), gain=0.28 if beat < S3 else 0.32, pan_to=-0.05, wet=0.3)
        if beat >= S3:
            drums.add(at(beat), s.snare(0.85, tone=200), gain=0.36, pan_to=0.05, wet=0.22)
    for beat in theme.playing(S1 + 0.5, S3, 1):
        drums.add(at(beat), s.hat(0.9), gain=0.1 * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S3, LAST, 0.25):
        drums.add(at(beat), s.hat((1.0, 0.45, 0.7, 0.45)[round(beat * 4) % 4]), gain=0.1 * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S3 + 0.5, LAST, 1):
        drums.add(at(beat), s.hat(0.7, open=True), gain=0.06 * swell(beat), pan_to=-0.25, wet=0.12)
    for first, last, step in ((S4 + 2, S4 + 3, 0.25), (S4 + 3, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4 - 2) / (STOP - S4 - 2)
            drums.add(at(beat), s.taiko(0.45 + 0.45 * p, 95 + 75 * p, 0.3, decay=0.1), gain=0.4, pan_to=-0.3 + 0.6 * p, wet=0.25)

    # The riff on the pulse lead, its pushed notes sliding in from the note before, a vibrato on the
    # long notes, and an echo a beat and two beats later either side, which stops on the drop and the
    # last hit, so the A sharp resolves; the head on the drop doubled an octave up.
    previous = None
    for beat, note, beats in TUNE:
        last = beat >= LAST
        glide = previous if beat % 1 == 0.75 else None
        tone = s.pulse_lead(note, beats * theme.BEAT * 0.94, 0.9, glide=glide, cutoff=3600 if beat >= DROP else 3100,
                            vibrato=0.15 if beats >= 1 else 0.0)
        if last:
            tone = theme.dying(tone, 1.0)
        level = 0.55 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        for later, cutoff, share, p, wet in ((1, 1800, 0.3, -0.5, 0.5), (2, 1200, 0.12, 0.5, 0.6)):
            echo = cut(s.lowpass(tone.mean(axis=1), cutoff), (stop - beat - later) * theme.BEAT)
            lead.add(at(beat + later), echo, gain=level * share, pan_to=p, wet=wet)
        if DROP <= beat < cue["endLine"]:
            lead.add(at(beat), s.pulse_lead(note + 12, beats * theme.BEAT * 0.9, 0.55, glide=None if glide is None else glide + 12,
                                            cutoff=3600), gain=level * 0.3, wet=0.4)
        previous = note

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = s.brass([n + 12 for n in VOICINGS["Bm9"][1]], 1.2, 1.0, cutoff=2800, attack=0.02, release=0.6)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.09, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop: a deep kick under the boom, the brass at full width, a dark crash; then stabs on the
    # offbeats to the last hit, a crash on the call to action, and the last hit with the chord left to
    # die away under the electric piano's last chord.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.68, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.18, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.22, wet=0.35)
    for beat in theme.playing(DROP, LAST, 1):
        pads.add(at(beat + 0.5), s.brass(chord(beat)[1], 0.16, 0.9, cutoff=3000, attack=0.015, release=0.12), gain=0.14, wet=0.3)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 6000), gain=0.14, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.68, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.22, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)
    for note, p in zip(VOICINGS["Bm9"][2], (-0.3, -0.1, 0.1, 0.3)):
        arps.add(at(LAST), s.fm(note, 3.0, 0.7, index=1.6), gain=ARP * 0.8, pan_to=p, wet=0.5)

    theme.develop(fx, room, 71)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.55, release=0.16)
    low.duck(1 - 0.6 * (1 - pump))
    pads.duck(1 - 0.4 * (1 - pump))
    arps.duck(1 - 0.2 * (1 - pump))
    theme.trim(drums, 55)
    theme.trim(low, 60)
    theme.trim(fx, 45)
    theme.trim(bed, 45)
    return [drums, low, pads, arps, lead, fx, bed], dict(room=room, wet=0.55, presence=3.0)


ARRANGEMENTS = {"synthwave": synthwave}
