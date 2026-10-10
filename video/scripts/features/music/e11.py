"""
E11's track (Command palette): a synthwave tune in G minor at 100 BPM, 8 bars and 19.2 seconds on the
series' cue sheet, src/features/cues.json, which scripts/features-score.py plays under the episode with
its own sounds. G minor is in its Dorian colour, with E natural, so its tonic chord, Gm6/9, shares D, E
and A with the opener's held D major chord, G minor's dominant: the lead-in runs on D, E and A over a
drone on D, A and E stacked in fifths, and on the first hit a low G comes in under them and the pads
bring in B flat.

Where E01's theme climbs and falls back over i, VI, iv and V, E02's chords fall by fifths and E08's bass
walks down, this one's bass climbs the scale a bar at a time, G, A, B flat and C, under Gm6/9, Am11,
Bbmaj9#11 and C13, every chord keeping the Dorian E; then E flattens for Am7(b5) to D7(b9) into the drop,
and comes back on Gm6/9; on the end line Ebmaj9 to D7(b9), and Gm6/9 on the last hit. The riff is typed
in one rhythm, two sixteenths and a held note, twice a bar: D, E and G held, E, G and A held, then G and
E; then F, E and D held, E, D and C held. The answer plays the riff's first bar over C13, then climbs
Am7(b5) from C through E flat to G and falls through A, G and F sharp to E flat, held through the stop,
which sinks to D on the drop as the head turns up to E natural; the closing phrase is the head with E
flat, then G, F sharp and G on the last hit.

Its sound is its own in the same synthwave family: a step sequencer's line of sixteenths in the low
middle, a saw and a square through a resonant filter that snaps shut, the chord's top note ticking on
every other step under an accent every third step, so the accents wheel across the bar; pads from an FM
synthesiser whose tone blooms as each chord swells in; a bass on the offbeats from the first step,
pumping against a kick on every beat; a drum machine's rimshot on 2 and 4, then from the third step a
snare on 2 and 4 with a rimshot a sixteenth before each and open hats on the offbeats, over a shaker in
sixteenths from the second step; toms falling and doubling into the stop; the riff on a hard-sync lead,
whose bright peak falls through the harmonics as each note speaks, sliding into its held notes, with an
echo a beat later; and from the drop, the pads' chord in short stabs a sixteenth before 2 and 4. On the
drop the series' sting, glass struck on G, D and A.
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
CHORDS = [("Gm6/9", 0, 4), ("Am11", 4, 4), ("Bbmaj9#11", 8, 4), ("C13", 12, 4), ("Am7(b5)", 16, 2), ("D7(b9)", 18, 2),
          ("Gm6/9", 20, 4), ("Ebmaj9", 24, 2), ("D7(b9)", 26, 2), ("Gm6/9", 28, 4)]

# Each chord: the bass's root, climbing the scale; the pads' voicing, its voices moving by step and
# keeping the colour notes: G minor's sixth and ninth, A minor's eleventh, B flat's major seventh, ninth
# and sharp eleventh, C's ninth and thirteenth over its flat seventh, then E flat in A's half-diminished
# chord and in D7's flat ninth over its leading note; and the sequence's four notes, root first, the last
# the one that ticks.
VOICINGS = {
    "Gm6/9": (43, [58, 62, 64, 69], [55, 58, 62, 64]),
    "Am11": (45, [60, 62, 64, 67], [57, 60, 64, 67]),
    "Bbmaj9#11": (46, [60, 62, 64, 69], [58, 62, 64, 69]),
    "C13": (48, [58, 62, 64, 69], [60, 64, 67, 70]),
    "Am7(b5)": (45, [57, 60, 63, 67], [57, 60, 63, 67]),
    "D7(b9)": (50, [57, 60, 63, 66], [54, 57, 60, 63]),
    "Ebmaj9": (51, [58, 62, 65, 67], [55, 58, 62, 65]),
}


def chord(beat):
    return VOICINGS[theme.chord_at(beat, CHORDS)]


# The sequence's steps through the chord's four notes, two beats long: the root, then the top note on
# every other step.
LINE = (0, 3, 1, 3, 2, 3, 1, 3)

# The riff, [beat, note, beats] from where it starts, typed in one rhythm, two sixteenths and a held
# note, twice a bar: D, E and G held, E, G and A held, then G and E; then F, E and D held, E, D and C
# held. The answer plays the first bar again, then climbs from C through E flat to G and falls through
# A, G and F sharp to E flat, held through the stop; the head is the riff's first bar; the closing phrase
# is the head with E flat for E, falling through G and F sharp and up to G on the last hit.
MOTIF = [(0, 74, 0.25), (0.25, 76, 0.25), (0.5, 79, 1.0), (1.5, 76, 0.25), (1.75, 79, 0.25), (2, 81, 1.0), (3, 79, 0.5),
         (3.5, 76, 0.5), (4, 77, 0.25), (4.25, 76, 0.25), (4.5, 74, 1.0), (5.5, 76, 0.25), (5.75, 74, 0.25), (6, 72, 2.0)]
ANSWER = MOTIF[:8] + [(4, 72, 0.25), (4.25, 75, 0.25), (4.5, 79, 1.0), (5.5, 81, 0.25), (5.75, 79, 0.25), (6, 78, 0.5),
                      (6.5, 75, 1.5)]
HEAD = MOTIF[:8]
CLOSE = [(0, 74, 0.25), (0.25, 75, 0.25), (0.5, 79, 1.0), (1.5, 75, 0.25), (1.75, 79, 0.25), (2, 81, 1.0), (3, 79, 0.5),
         (3.5, 78, 0.5), (4, 79, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The sequence's levels for a note and, in the lead-in, its echo, which the lead-in grows to.
ARP, ECHO = 0.18, 0.05


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)[:, None] if out.ndim == 2 else np.linspace(1, 0, fade)
    return out


def stab(notes, seconds, index):
    """The pads' chord struck short: the FM pad with no swell, dying away."""
    return theme.dying(s.fm_pad(notes, seconds, index=index, attack=0.005, release=0.12, bloom=0.0), seconds * 0.6)


def synthwave(sounds=theme.ui):
    theme.start(113)
    room = s.reverb(2.2, 0.55, 0.02)
    drums, low, pads, arps, lead, fx, bed = (s.Bus(theme.LENGTH) for _ in range(7))
    kicks = []

    # The lead-in, on the notes D major and G minor's Dorian chord share (D, E and A), on the sequence's own
    # voice, over a drone on D, A and E, and D and A an octave above it swelling up into the hit; on the hit
    # G comes in under the drone in two octaves, held steady so the first bar's level doesn't swing with the
    # drone's slow beating, and the pads bring in B flat; the drone and the G give way to the bass as it
    # comes in with the first step. None of them shares a note, so they don't beat against each other.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [62, 64, 69, 74], [50, 57, 64], ARP * swell(0), ECHO * swell(0),
                  tone=lambda note, grown: s.seq_pluck(note, 0.9, 0.11, cutoff=300 + 900 * grown, accent=0.5 * grown))
    bed.add(at(-theme.LEAD_IN), s.drone([62, 69], theme.PRE, cutoff=700, release=0.15, attack=theme.PRE), gain=0.7, wet=0.3)
    bed.add(at(0), s.fm_pad([43, 55], at(S1) - at(0), index=0.6, attack=0.03, release=0.4, bloom=0.3, detune=0), gain=0.28,
            wet=0.25)
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(S1), at(S1 + 1)], [1.0, 0.0]))

    # The first frame lands as a deep hit, under the pads, each chord's tone blooming and settling, brighter
    # through the build.
    drums.add(at(0), s.deep_kick(0.85), gain=0.6, wet=0.12)
    fx.add(at(0), s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in CHORDS:
        _, voicing, _ = VOICINGS[name]
        last = first == LAST
        index = 1.6 if first >= DROP else opening(first, 0, S4, 0.9, 1.4)
        pad = s.fm_pad(voicing, 2.8 if last else length * theme.BEAT, index=index, attack=0.12, release=1.6 if last else 0.3)
        pads.add(at(first), theme.dying(pad, 1.2) if last else pad, gain=0.13 * swell(first), wet=0.45)

    # The sequence: sixteenths through the chord, the top note on every other step and an accent on every
    # third, dark under the hook and opening through the build; on the last hit its chord rolls up from G
    # and rings.
    for i, beat in enumerate(theme.playing(0, LAST, 0.25)):
        step = round(beat * 4) % 16
        note = chord(beat)[2][LINE[step % 8]]
        accented = step % 3 == 0
        cutoff = (380 if beat < S1 else opening(beat, S1, S3, 450, 750) if beat < S3
                  else opening(beat, S3, STOP, 800, 1400) if beat < DROP else 1250)
        tone = s.seq_pluck(note, 1.0 if accented else 0.75, 0.11, cutoff=cutoff, accent=0.6 if accented else 0.0)
        arps.add(at(beat), tone, gain=ARP * swell(beat), pan_to=(-0.25, 0.25)[i % 2], wet=0.2)
    for i, note in enumerate(VOICINGS["Gm6/9"][2] + [69]):
        ring = theme.dying(s.seq_pluck(note, 0.8, 2.0, cutoff=900, accent=0.4), 0.8)
        arps.add(at(LAST + i * 0.25), ring, gain=ARP * 0.9, pan_to=-0.3 + 0.15 * i, wet=0.5)

    # The bass on the offbeats from the first step, up the octave on the bar's last, opening through the
    # build; the last root dies away.
    for beat in theme.playing(S1, LAST, 1):
        if STOP <= beat + 0.5 < DROP:
            continue
        root = chord(beat)[0] + (12 if beat % 4 == 3 else 0)
        bright = (opening(beat, S1, S3, 0.3, 0.45) if beat < S3 else opening(beat, S3, STOP, 0.45, 0.75) if beat < DROP
                  else 0.85)
        low.add(at(beat + 0.5), s.bass(root, 0.85, 0.22, bright=bright), gain=0.4 * swell(beat), wet=0.04)
    low.add(at(LAST), theme.dying(s.bass(43, 0.9, 3.0, bright=0.35), 0.9), gain=0.4, wet=0.1)

    # The beat: a kick on every beat, muffled as if through a wall under the first bar and left to the deep
    # kick on the drop; a rimshot on 2 and 4 from the first step; a shaker in sixteenths from the second;
    # from the third a snare on 2 and 4 with a rimshot under it and another a sixteenth before it, and open
    # hats on the offbeats; toms falling and doubling into the stop.
    for beat in theme.playing(1, LAST, 1):
        if beat < S1:
            drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.5, wet=0.02)
        elif beat != DROP:
            drums.add(at(beat), s.kick(0.95, length=0.32), gain=0.56 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in [b for b in theme.playing(S1, S3, 1) if b % 4 in (1, 3)]:
        drums.add(at(beat), s.rimshot(0.9), gain=0.22, pan_to=-0.15, wet=0.15)
    for beat in [b for b in theme.playing(S3, LAST, 1) if b % 4 in (1, 3) and not S4 + 2 <= b < DROP]:
        drums.add(at(beat), s.snare(0.9, tone=205), gain=0.34, pan_to=0.05, wet=0.22)
        drums.add(at(beat), s.rimshot(0.8), gain=0.16, pan_to=-0.15, wet=0.15)
        drums.add(at(beat - 0.25), s.rimshot(0.7), gain=0.15, pan_to=-0.25, wet=0.12)
    for beat in theme.playing(S2, LAST, 0.25):
        weight = (0.6, 0.2, 0.9, 0.35)[round(beat * 4) % 4]
        drums.add(at(beat), s.shaker(weight), gain=0.12 * swell(beat), pan_to=0.35, wet=0.08)
    for beat in theme.playing(S3 + 0.5, LAST, 1):
        drums.add(at(beat), s.hat(0.7, open=True), gain=0.05 * swell(beat), pan_to=-0.25, wet=0.12)
    for first, last, step in ((S4 + 2, S4 + 3, 0.25), (S4 + 3, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4 - 2) / (STOP - S4 - 2)
            drums.add(at(beat), s.taiko(0.5 + 0.4 * p, 175 - 90 * p, 0.3, decay=0.1), gain=0.4, pan_to=0.35 - 0.7 * p,
                      wet=0.25)

    # The riff on the sync lead, its held notes sliding in from the note before, a vibrato on them, and an
    # echo a beat later, which stops on the drop and the last hit so the E flat sinks to D cleanly; the
    # head on the drop doubled an octave up.
    previous = None
    for beat, note, beats in TUNE:
        last = beat >= LAST
        joined = previous and previous[2] <= 0.5 and abs(previous[0] + previous[2] - beat) < 1e-9 and beats >= 1
        glide = previous[1] if joined else None
        tone = s.sync_lead(note, beats * theme.BEAT * 0.94, 0.9, glide=glide, cutoff=2600 if beat >= DROP else 2300,
                           vibrato=0.14 if beats >= 1 else 0.0)
        if last:
            tone = theme.dying(tone, 1.0)
        level = 0.85 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        echo = cut(s.lowpass(tone, 1700), (stop - beat - 1) * theme.BEAT)
        lead.add(at(beat + 1), echo, gain=level * 0.28, pan_to=-0.45, wet=0.5)
        if DROP <= beat < cue["endLine"]:
            doubled = s.sync_lead(note + 12, beats * theme.BEAT * 0.9, 0.55, glide=None if glide is None else glide + 12,
                                  cutoff=3000)
            lead.add(at(beat), doubled, gain=level * 0.3, wet=0.4)
        previous = (beat, note, beats)

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = stab([n + 12 for n in VOICINGS["Gm6/9"][1]], 1.2, 2.4)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.09, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop: a deep kick under the boom, the chord struck an octave up and a dark crash; then the
    # chord in short stabs a sixteenth before 2 and 4 to the last hit, a crash on the call to action, and
    # the last hit, with the chord left to die away.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.68, wet=0.08)
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.22, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.22, wet=0.35)
    for beat in [b for b in theme.playing(DROP, LAST, 1) if b % 4 in (1, 3)]:
        pads.add(at(beat - 0.25), stab(chord(beat - 0.25)[1], 0.16, 2.2), gain=0.2, wet=0.3)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 6000), gain=0.14, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.68, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.22, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)

    theme.develop(fx, room, 79)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.5, release=0.17)
    low.duck(1 - 0.55 * (1 - pump))
    pads.duck(1 - 0.4 * (1 - pump))
    arps.duck(1 - 0.25 * (1 - pump))
    theme.trim(drums, 55)
    theme.trim(low, 60)
    theme.trim(fx, 45)
    theme.trim(bed, 45)
    return [drums, low, pads, arps, lead, fx, bed], dict(room=room, wet=0.55, presence=3.0)


ARRANGEMENTS = {"synthwave": synthwave}
