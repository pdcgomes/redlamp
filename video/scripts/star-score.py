#!/usr/bin/env python3
"""
The star promo's score (src/star/StarPromo.tsx): 16 seconds at 120 BPM in D minor, written from the
promo's cue sheet, src/star/cues.json, so every sound lands on the frame its picture does.

    python3 scripts/star-score.py      # public/star/score.wav, and score.json for the storyboard sheet

Dark and cinematic. The lamp charges over a low drone: a heartbeat, a watch ticking, a felt piano
picking out a few notes, and a Shepard tone that seems to rise for ever, climbing faster as the
charge grows. From the second bar, low toms take over the roll whose every hit is a knock that shakes
the lamp (the cue sheet's `knocks`), doubling from eighths to thirty-seconds, under spiccato strings
that grow from a murmur. Half a beat of silence as the lamp holds its breath; a shot of glass as it
fires; the hit's own reverb swells up into it, and it lands as a trailer's low brass on the drop.
Then a half-time groove (the cue sheet's `groove`) under the strings' ostinato, with a line that
falls a step at a time through the sign, the click and the end card, to a last hit and the piano
alone. Needs numpy.
"""

import json
from pathlib import Path

import numpy as np

import synth as s

ROOT = Path(__file__).resolve().parent.parent
sheet = json.loads((ROOT / "src/star/cues.json").read_text())
BEAT = 60 / sheet["bpm"]
BEATS = sheet["bars"] * sheet["beatsPerBar"]
TOTAL = BEATS * BEAT
cue = sheet["cues"]


def at(beat):
    return beat * BEAT


# Each chord: its root (the bass plays it an octave up, the brass two), the strings' voicing (from
# the root up, with the colour notes that make it dark: Dm with its ninth against the third, Bb with
# its major seventh, Gm with its ninth, A with its seventh), and its ostinato, eight sixteenths
# played twice a bar.
CHORDS = {
    "Dm": (38, [50, 57, 62, 64, 65, 69], [50, 50, 57, 50, 53, 50, 52, 50]),
    "Bb": (34, [46, 53, 57, 62, 65], [46, 46, 53, 46, 50, 46, 48, 46]),
    "Gm": (31, [43, 50, 57, 58, 65], [43, 43, 50, 43, 46, 43, 45, 43]),
    "A": (33, [45, 52, 55, 61, 64], [45, 45, 52, 45, 49, 45, 50, 45]),
}
# The hit's low brass: a D minor cluster from D1 up.
CLUSTER = [26, 38, 45, 50, 53]
# The line the strings carry through the drop, falling a step at a time to D: [beat, note, beats].
LINE = [(16, 81, 2), (18, 82, 2), (20, 81, 2), (22, 79, 2), (24, 77, 2), (26, 76, 2), (28, 74, 3.5)]
# The piano's few notes while the lamp charges, and after the last hit: [beat, note, velocity].
PIANO = [
    (0, 62, 0.42), (0, 69, 0.5), (2, 70, 0.4), (3, 69, 0.34),
    (4, 74, 0.4), (4, 65, 0.3), (6, 72, 0.34), (8, 70, 0.4), (10, 69, 0.42), (10, 73, 0.32),
    (29, 69, 0.38), (30.5, 74, 0.3),
]


def chord_at(beat):
    for name, first, length in sheet["chords"]:
        if first <= beat < first + length:
            return name
    return sheet["chords"][-1][0]


# The charge, as the composition draws it: it starts 1.4 s before the first frame and is full as
# the lamp squashes (`chargeLevel` in src/kit/light.ts).
CHARGE_FROM = -1.4
GAP, FIRE, HIT, STOP = cue["squash"], cue["fire"], cue["hit"], cue["stop"]


def charge(t):
    return float(np.clip((t - CHARGE_FROM) / (at(GAP) - CHARGE_FROM), 0, 1))


s.reset(11)
room = s.reverb(3.6, 0.9, 0.03)
drums, low, bows, keys, fx = (s.Bus(TOTAL + 5) for _ in range(5))
kicks = []

# ---------------------------------------------------------------- the charge

# The first frame lands as a deep hit; a drone holds D under the whole charge, and stops dead with it.
fx.add(0, s.boom(2.4, 1.0), gain=0.3, wet=0.35)
drums.add(0, s.taiko(0.55, 58, 1.6), gain=0.5, wet=0.3)
low.add(0, s.drone([38, 45, 50], at(GAP), cutoff=420, release=0.05, attack=0.4), gain=0.5, wet=0.3)

for beat, note, velocity in PIANO:
    keys.add(at(beat), s.piano(note, velocity, 4.5), gain=0.4, pan_to=(note - 68) / 24, wet=0.55)

# Each knock that shakes the lamp is a beat: a heartbeat in the first bar, then a roll of low toms
# that grows harder and higher as it charges, with a tick of metal on top once it's fast.
for first, last, step in sheet["knocks"]:
    for beat in np.arange(first, last - 1e-9, step):
        t = at(beat)
        p = charge(t)
        if beat < 4:
            if beat > 0:
                drums.add(t, s.lowpass(s.deep_kick(0.7), 180), gain=0.6, wet=0.15)
                drums.add(t + 0.17, s.lowpass(s.deep_kick(0.45), 160), gain=0.45, wet=0.15)
                kicks.append(t)
            continue
        level = 0.2 + 0.8 * p**1.2
        tom = s.taiko(level, 88 + 40 * p, 0.45, decay=0.14)
        drums.add(t, tom, gain=0.42 * (step / 0.5) ** 0.3, pan_to=0.18 if int(beat / step) % 2 else -0.18, wet=0.22)
        if step <= 0.25:
            drums.add(t, s.tock(level, 2600), gain=0.08, pan_to=0.3, wet=0.15)

# A watch ticks under the charge, louder as it grows.
for i in range(int(GAP * 2)):
    fx.add(at(i / 2), s.tock(0.7 if i % 2 == 0 else 0.5, 2300 if i % 2 == 0 else 1900), gain=0.09 + 0.06 * charge(at(i / 2)), pan_to=0.35, wet=0.12)

# The Shepard tone: it seems to rise for ever, and climbs faster as the lamp charges.
n = int(at(GAP) * s.SR)
t = np.arange(n) / s.SR
p = np.interp(t, t[::480], [charge(x) for x in t[::480]])
fx.add(0, s.shepard(0.06 + 0.9 * p**2, (0.15 + 0.85 * p**1.5) * np.clip((at(GAP) - t) / 0.04, 0, 1)), gain=0.13, wet=0.35)

# From the second bar, the strings: spiccato sixteenths from a murmur to full, over a section that swells.
for i in range(16, int(GAP * 4)):
    beat = i / 4
    _, _, figure = CHORDS[chord_at(beat)]
    p = charge(at(beat))
    accent = 1.0 if i % 4 == 0 else 0.8 if i % 2 == 0 else 0.62
    bows.add(at(beat), s.spiccato(figure[i % 8], (0.3 + 0.7 * p) * accent, bright=0.25 + 0.7 * p), gain=0.5, wet=0.3)
for name, first, length in sheet["chords"]:
    if first < 4 or first >= GAP:
        continue
    seconds = (min(first + length, GAP) - first) * BEAT
    p0, p1 = charge(at(first)), charge(at(first) + seconds)
    for note in CHORDS[name][1][1:]:
        bows.add(at(first), s.strings(note, seconds, bright=(0.1 + 0.6 * p0, 0.2 + 0.7 * p1), attack=0.6, release=0.05), gain=0.14, wet=0.45)

# Taiko on the build's bar lines, and the bass under the rush, eighths on the root.
for beat, velocity in ((4, 0.8), (8, 0.95)):
    drums.add(at(beat), s.taiko(velocity, 60, 1.6), gain=0.6, wet=0.35)
for beat in np.arange(8, GAP, 0.5):
    low.add(at(beat), s.bass(CHORDS[chord_at(beat)][0] + 12, 0.85 if beat % 1 == 0 else 0.6, 0.22, bright=0.3), gain=0.45, wet=0.05)
fx.add(at(8), s.riser(at(GAP) - at(8), 180, 4200, curve=2.2), gain=0.09, wet=0.4)

# ---------------------------------------------------------------- the squash, the shot and the hit

# As the lamp holds its breath, everything stops, reverb and all (the mix's choke, below), but for
# a breath drawn in; the shot lands a thump as the lamp recoils.
breath = s.Bus(TOTAL + 5)
breath.add(at(FIRE) - 0.16, s.inhale(0.16), gain=0.2, wet=0.1)
drums.add(at(FIRE), s.taiko(0.45, 70, 0.8), gain=0.4, wet=0.25)
# The shot is light leaving glass: a struck pair high up, and air that crosses with it.
keys.add(at(FIRE), s.glass(98, 1.6, 0.9), gain=0.12, pan_to=-0.4, wet=0.5)
keys.add(at(FIRE), s.glass(93, 1.4, 0.7), gain=0.08, pan_to=-0.3, wet=0.5)
flight = at(HIT) - at(FIRE)
fx.add(at(FIRE), s.whoosh(flight, 900, 5200), gain=0.16, pan_to=np.linspace(-0.45, 0.3, int(round(flight * s.SR))), wet=0.35)
# The hit's own reverb, reversed, swells up into it.
hit = s.braam(CLUSTER, 3.4, 1.0)
fx.add(at(FIRE), s.swell_into(hit, flight, room), gain=0.22, wet=0.0)

low.add(at(HIT), hit, gain=0.55, wet=0.35)
drums.add(at(HIT), s.taiko(1.0, 52, 2.0), gain=0.75, wet=0.35)
drums.add(at(HIT), s.deep_kick(1.0), gain=0.8, wet=0.1)
fx.add(at(HIT), s.boom(3.0, 1.2), gain=0.3, wet=0.3)
drums.add(at(HIT), s.lowpass(s.crash(1.0, 4.0, decay=1.6), 7000), gain=0.3, wet=0.4)
kicks.append(at(HIT))

# ---------------------------------------------------------------- the drop

# Half time: a kick on the bar, the snare on its third beat, a lighter kick before the next bar.
groove = sheet["groove"]
for bar in range(groove["from"], groove["to"], sheet["beatsPerBar"]):
    for offset, weight in groove["hits"]:
        beat = bar + offset
        if beat == HIT:
            continue
        if offset == 2:
            drums.add(at(beat), s.big_snare(weight), gain=0.5, wet=0.45)
        else:
            drums.add(at(beat), s.deep_kick(weight), gain=0.62, wet=0.08)
            kicks.append(at(beat))
# Taiko on the story's beats: the sign's catch, the cursor, the end card; and a fill into the last hit.
for beat, velocity in ((16, 0.8), (20, 0.7), (24, 0.9)):
    drums.add(at(beat), s.taiko(velocity, 56, 1.8), gain=0.46, wet=0.35)
for beat, velocity, pitch in ((27, 0.6, 80), (27.25, 0.65, 86), (27.5, 0.75, 92), (27.75, 0.85, 100)):
    drums.add(at(beat), s.taiko(velocity, pitch, 0.5, decay=0.16), gain=0.45, wet=0.3)
for beat in np.arange(HIT, STOP, 0.5):
    fx.add(at(beat), s.tock(0.6 if beat % 1 == 0 else 0.45, 2300 if beat % 1 == 0 else 1900), gain=0.06, pan_to=0.35, wet=0.12)

# The strings and the brass grow through the drop, so the end card arrives at its height.
def rising(beat):
    return 0.85 + 0.4 * (beat - HIT) / (STOP - HIT)


for i in range(int(HIT * 4), int(STOP * 4)):
    beat = i / 4
    _, _, figure = CHORDS[chord_at(beat)]
    accent = 1.0 if i % 4 == 0 else 0.8 if i % 2 == 0 else 0.62
    bows.add(at(beat), s.spiccato(figure[i % 8], accent, bright=0.75), gain=0.5 * rising(beat), wet=0.3)
for beat in np.arange(HIT, STOP, 0.5):
    low.add(at(beat), s.bass(CHORDS[chord_at(beat)][0] + 12, 0.9 if beat % 1 == 0 else 0.62, 0.22, bright=0.35), gain=0.45, wet=0.05)
for name, first, length in sheet["chords"]:
    if first < HIT or first >= STOP:
        continue
    root, voicing, _ = CHORDS[name]
    seconds = length * BEAT
    for note in voicing[1:]:
        bows.add(at(first), s.strings(note, seconds, bright=(0.45, 0.7), attack=0.25, release=0.6), gain=0.14 * rising(first), wet=0.45)
    brass = root + 12
    low.add(at(first), s.drone([brass, brass + 7, brass + 12], seconds, cutoff=700 if first < 24 else 1100, release=0.4, attack=0.08), gain=0.3 * rising(first), wet=0.3)

# The line, high on the strings, with the piano marking each step.
for beat, note, beats in LINE:
    bows.add(at(beat), s.strings(note, beats * BEAT, bright=(0.5, 0.65), attack=0.12, release=0.5, voices=8, vibrato=0.005), gain=0.25, wet=0.5)
    keys.add(at(beat), s.piano(note - 12, 0.32, 3.0), gain=0.3, pan_to=0.15, wet=0.5)

# ---------------------------------------------------------------- the sign, the cursor and the click

catch = at(cue["catch"])
fx.add(catch - 0.225, s.whoosh(0.26, 1400, 500), gain=0.07, pan_to=0.25, wet=0.25)
fx.add(catch, s.knock(1.0), gain=0.4, pan_to=0.2, wet=0.15)
fx.add(catch + 0.03, s.creak(0.55, 760), gain=0.06, pan_to=0.2, wet=0.2)

glide = at(cue["hover"]) - at(cue["cursor"])
fx.add(at(cue["cursor"]), s.whoosh(glide, 700, 2400), gain=0.08, pan_to=np.linspace(0.6, 0.1, int(round(glide * s.SR))), wet=0.2)

press = at(cue["click"])
fx.add(press - 0.02, s.click(1.0), gain=0.32, pan_to=0.15, wet=0.05)
fx.add(press, s.boom(1.2, 0.5), gain=0.22, wet=0.2)
keys.add(press, s.glass(98, 3.0, 0.9), gain=0.14, pan_to=0.2, wet=0.55)
keys.add(press + 0.04, s.glass(105, 2.4, 0.6), gain=0.08, pan_to=0.3, wet=0.55)
keys.add(press, s.piano(74, 0.45, 4.0), gain=0.3, pan_to=0.1, wet=0.5)
keys.add(press, s.piano(81, 0.38, 4.0), gain=0.26, pan_to=0.2, wet=0.5)
fx.add(press + 0.2, s.tick(1.0), gain=0.1, pan_to=0.2, wet=0.1)
fx.add(press + 0.04, s.whoosh(0.2, 600, 1800), gain=0.05, pan_to=0.25, wet=0.25)

# ---------------------------------------------------------------- the end

end = at(cue["end"])
fx.add(end - 0.5, s.swell_into(s.crash(0.8, 3.0, decay=1.2), 0.5, room), gain=0.07, wet=0.0)
drums.add(end, s.lowpass(s.crash(0.8, 3.0, decay=1.2), 6500), gain=0.25, wet=0.4)

# The last hit is shorter than the first, so the last bar is quiet enough to run into the loop.
stop = at(STOP)
low.add(stop, s.braam(CLUSTER, 2.6, 0.9), gain=0.45, wet=0.4)
drums.add(stop, s.taiko(1.0, 50, 2.2), gain=0.75, wet=0.35)
drums.add(stop, s.deep_kick(1.0), gain=0.8, wet=0.1)
kicks.append(stop)
drums.add(stop, s.lowpass(s.crash(1.0, 4.0, decay=1.8), 7000), gain=0.3, wet=0.45)
fx.add(stop, s.boom(2.0, 1.0), gain=0.28, wet=0.3)
for note in CHORDS["Dm"][1][1:]:
    bows.add(stop, s.strings(note, TOTAL - stop - 0.6, bright=(0.5, 0.15), attack=0.05, release=0.6), gain=0.12, wet=0.5)
low.add(stop, s.drone([38, 50], TOTAL - stop - 0.4, cutoff=300, release=0.4, attack=0.05), gain=0.4, wet=0.3)

# The last bar runs back into the first frame: the watch and the Shepard tone start again.
again = at(cue["recharge"])
for i in range(int((TOTAL - again) * 2)):
    fx.add(again + i * BEAT / 2, s.tock(0.5, 2300 if i % 2 == 0 else 1900), gain=0.05 + 0.02 * i, pan_to=0.35, wet=0.12)
n = int((TOTAL - again) * s.SR)
k = np.linspace(0, 1, n)
p0 = charge(0)
fx.add(again, s.shepard(0.06 * np.ones(n), (0.15 + 0.85 * p0**1.5) * k**1.5), gain=0.13, wet=0.35)

# ---------------------------------------------------------------- mix

pump = s.sidechain(TOTAL + 5, kicks, depth=0.5, release=0.22)
low.duck(1 - 0.5 * (1 - pump))
bows.duck(1 - 0.3 * (1 - pump))
# The choke: the mix falls silent 20 ms into the squash and comes back as the shot leaves.
t = np.arange(int((TOTAL + 5) * s.SR)) / s.SR
choke = np.interp(t, [at(GAP) + 0.02, at(GAP) + 0.06, at(FIRE) - 0.01, at(FIRE)], [1, 0.02, 0.02, 1])
mix = s.master([drums, low, bows, keys, fx], seconds=TOTAL, target=-14.0, ceiling=-1.0, room=room, wet=0.75, choke=choke, through=[breath], presence=3.0)

out = ROOT / "public/star"
out.mkdir(parents=True, exist_ok=True)
s.write(out / "score.wav", mix)

# Its level at every video frame, for the storyboard sheet's waveform.
fps = sheet["fps"]
per = s.SR // fps
frames = len(mix) // per
rms = np.sqrt((mix[: frames * per] ** 2).mean(axis=1).reshape(frames, per).mean(axis=1))
(out / "score.json").write_text(json.dumps({"fps": fps, "level": [round(float(x), 4) for x in rms / rms.max()]}))
print(f"==> public/star/score.wav ({TOTAL:.1f} s, {s.loudness(mix):.1f} LUFS, true peak {s.true_peak(mix):.1f} dBFS)")
