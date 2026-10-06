#!/usr/bin/env python3
"""
The star promo's score (src/star/StarPromo.tsx): 16 seconds at 120 BPM in D major, written from the
promo's cue sheet, src/star/cues.json, so every sound lands on the frame its picture does.

    python3 scripts/star-score.py      # public/star/score.wav, and score.json for the storyboard sheet

The build is the lamp charging: a muffled heartbeat, an arpeggio whose filter opens, a hum that
rises with the charge, crackles as the motes gather, and a snare roll whose every hit is a knock
that shakes the lamp (the cue sheet's `knocks`), doubling from eighths to thirty-seconds. A
half-beat of silence as the lamp squashes, a zap that pans with the shot, and the drop lands on the
hit: four-on-the-floor, an offbeat bass, a pumping supersaw and a bouncy lead. Then the badge's
spring, the sign's whistle and knock as it catches, the cursor, the click and the count, the end
card, and a last chord with the hum rising again into the loop. Needs numpy.
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
cue = {name: beat for name, beat in sheet["cues"].items()}


def at(beat):
    return beat * BEAT


# The chords: the groove's bass root, the pad's voicing (D on top throughout, so the pad moves
# smoothly), the arpeggio's notes and the lead's riff, a bar of eighths (None rests).
CHORDS = {
    "D": (38, [62, 66, 69, 76], [62, 66, 69, 74, 78, 74, 69, 66], [81, None, 78, 81, None, 83, 81, 78]),
    "A": (45, [61, 64, 69, 73], [57, 61, 64, 69, 73, 69, 64, 61], [76, None, 73, 76, None, 78, 76, 73]),
    "Bm": (47, [62, 66, 71, 74], [59, 62, 66, 71, 74, 71, 66, 62], [78, None, 74, 78, None, 81, 78, 74]),
    "G": (43, [62, 67, 71, 74], [55, 59, 62, 67, 71, 67, 62, 59], [74, None, 71, 74, None, 76, 74, 71]),
}


def chord_at(beat):
    for name, first, length in sheet["chords"]:
        if first <= beat < first + length:
            return name
    return sheet["chords"][-1][0]


# The charge, as the composition draws it: it starts 1.4 s before the first frame and is full as
# the lamp squashes (`chargeLevel` in src/kit/light.ts).
CHARGE_FROM = -1.4


def charge(t):
    return float(np.clip((t - CHARGE_FROM) / (at(cue["squash"]) - CHARGE_FROM), 0, 1))


s.reset(7)
drums, low, music, keys, fx = (s.Bus(TOTAL + 4) for _ in range(5))
kicks = []

HIT, DROP_END, GAP, FIRE = cue["hit"], cue["stop"], cue["squash"], cue["fire"]

# ---------------------------------------------------------------- the charge

# The first frame lands with a thump, and the hum starts.
drums.add(0, s.kick(1.0, 0.5), gain=0.8, wet=0.05)
fx.add(0, s.boom(1.6, 0.7), gain=0.35, wet=0.2)
kicks.append(0)

# Each knock that shakes the lamp is a beat: the heartbeat kick in the first bar, then the roll.
for first, last, step in sheet["knocks"]:
    for beat in np.arange(first, last - 1e-9, step):
        t = at(beat)
        level = 0.2 + 0.8 * charge(t) ** 1.2
        if beat < 4:
            if beat > 0:
                drums.add(t, s.lowpass(s.kick(0.9, 0.4), 260), gain=0.45, wet=0.05)
                kicks.append(t)
        else:
            # Denser hits play softer, so the roll's loudness climbs steadily rather than in steps.
            p = charge(t)
            hit = s.snare(level, tone=170 + 170 * p, snap=0.6 + 0.6 * p)
            drums.add(t, hit, gain=0.36 * (0.55 + 0.45 * level) * (step / 0.5) ** 0.3, pan_to=0.06 * np.sin(beat * 7), wet=0.18)

# The kick runs straight through the build, and stops for the last bar's thirty-seconds.
for beat in range(4, 10):
    drums.add(at(beat), s.kick(0.85), gain=0.42 + 0.06 * (beat - 4), wet=0.05)
    kicks.append(at(beat))

# The arpeggio, sixteenths, its filter opening and its level rising as the charge grows.
for i in range(int(GAP * 4)):
    beat = i / 4
    t = at(beat)
    _, _, arp, _ = CHORDS[chord_at(beat)]
    note = arp[i % len(arp)]
    accent = 1.0 if i % 4 == 0 else 0.7
    p = charge(t)
    music.add(t, s.pluck(note, 0.55 * accent, 0.22, bright=0.12 + 0.88 * p**1.4), gain=0.16 + 0.18 * p, pan_to=(note - 66) / 24, wet=0.22)

# A pad under the build, dark in the first bar and opening into the rush.
for name, first, length in sheet["chords"]:
    if first >= GAP:
        break
    _, voicing, _, _ = CHORDS[name]
    seconds = min(length, GAP - first) * BEAT
    pad = s.supersaw(voicing, seconds, cutoff=500 + 3800 * charge(at(first + length)) ** 2, attack=0.3, release=0.05)
    music.add(at(first), pad, gain=0.2 if first == 0 else 0.26, wet=0.35)

# The bass comes in with the build, eighths on the root.
for beat in np.arange(4, 10, 0.5):
    root, _, _, _ = CHORDS[chord_at(beat)]
    low.add(at(beat), s.bass(root, 0.75 if beat % 1 == 0 else 0.55, 0.2, bright=0.35 + 0.5 * charge(at(beat))), gain=0.4, wet=0.05)

# The riser climbs from the build to the squash.
fx.add(at(4), s.riser(at(GAP) - at(4), 280, 9000, curve=2.4), gain=0.12, wet=0.3)

# The lamp's hum follows the charge, and whines up as it squashes; it stops as the shot leaves.
n = int(at(FIRE) * s.SR)
t = np.arange(n) / s.SR
level = np.array([charge(x) for x in t[::480]])
p = np.interp(t, t[::480], level)
squash = np.clip((t - at(GAP)) / (at(FIRE) - at(GAP)), 0, 1)
pitch = 47 + 26 * p**1.5 + 7 * squash
fx.add(0, s.hum(pitch, (0.15 + 0.85 * p**2) * np.clip((at(FIRE) - t) / 0.01, 0, 1)), gain=0.075, wet=0.15)

# Crackles as the motes gather: denser and louder as it charges.
fx.add(
    0,
    s.crackle(at(GAP), lambda x: 0.35 * (30 + 220 * charge(x) ** 2), lambda x: 0.25 + 0.75 * charge(x)),
    gain=0.18,
    wet=0.25,
)

# ---------------------------------------------------------------- the squash and the shot

fx.add(at(FIRE) - 0.24, s.inhale(0.24), gain=0.3, wet=0.1)
shot = s.zap(at(HIT) - at(FIRE) + 0.12, 2800, 240)
fx.add(at(FIRE), shot, gain=0.5, pan_to=np.linspace(-0.45, 0.3, len(shot)), wet=0.3)
fx.add(at(FIRE), s.whoosh(at(HIT) - at(FIRE), 500, 4200), gain=0.25, pan_to=0.0, wet=0.3)

# ---------------------------------------------------------------- the drop

drums.add(at(HIT), s.kick(1.0, 0.6, punch=1.2), gain=0.95, wet=0.05)
fx.add(at(HIT), s.boom(2.2, 1.0), gain=0.5, wet=0.25)
drums.add(at(HIT), s.crash(1.0, 2.6), gain=0.5, wet=0.3)
music.add(at(HIT), s.stab(CHORDS["D"][1], 1.0, 0.6), gain=0.5, wet=0.3)
# The star spins: a run of glass up the chord.
for i, note in enumerate((86, 90, 93, 98)):
    keys.add(at(HIT) + 0.08 + i * 0.06, s.bell(note, 2.0, 0.7), gain=0.16, pan_to=0.15 + i * 0.1, wet=0.5)
# The badge swells and springs back.
fx.add(at(HIT) + 0.1, s.boing(0.9, 290, 7.5, 0.2), gain=0.09, pan_to=0.2, wet=0.25)

for beat in range(int(HIT), int(DROP_END)):
    t0 = at(beat)
    if beat > HIT:
        drums.add(t0, s.kick(0.95), gain=0.85, wet=0.04)
    kicks.append(t0)
    if beat % 2 == 1:
        drums.add(t0 + s.rng.uniform(-0.003, 0.003), s.clap(0.9), gain=0.34, pan_to=0.04, wet=0.25)
    for q in range(4):
        accent = (0.55, 0.25, 0.8, 0.3)[q]
        drums.add(t0 + q * BEAT / 4 + s.rng.uniform(-0.003, 0.003), s.hat(accent), gain=0.13, pan_to=0.25 if q % 2 else -0.15, wet=0.1)
    drums.add(t0 + BEAT / 2, s.hat(0.7, open=True), gain=0.09, pan_to=-0.2, wet=0.15)
    root, _, _, _ = CHORDS[chord_at(beat)]
    # The offbeat bass, with an octave jump at the end of each bar.
    lift = 12 if beat % 4 == 3 else 0
    low.add(t0 + BEAT / 2, s.bass(root + lift, 0.9, 0.24), gain=0.48, wet=0.04)
    if beat % 4 == 0:
        low.add(t0, s.sub(root - 12, BEAT * 0.9, 0.8), gain=0.35, wet=0.0)
for beat in (20, 24):
    drums.add(at(beat), s.crash(0.7, 2.0), gain=0.32, wet=0.3)

# The pumping pad, a bar per chord.
for name, first, length in sheet["chords"]:
    if first < HIT or first >= DROP_END:
        continue
    _, voicing, _, _ = CHORDS[name]
    music.add(at(first), s.supersaw(voicing, length * BEAT, cutoff=5200, attack=0.01, release=0.08), gain=0.34, wet=0.3)

# The lead's riff, a bar per chord, from the drop to the stop; the hit itself keeps its first note.
for bar_start in range(int(HIT), int(DROP_END), 4):
    _, _, _, riff = CHORDS[chord_at(bar_start)]
    for i, note in enumerate(riff):
        if note is None or (bar_start == HIT and i == 0):
            continue
        t0 = at(bar_start + i / 2)
        music.add(t0, s.lead(note, BEAT * 0.38, 0.9 if i % 3 == 0 else 0.75), gain=0.3, pan_to=-0.1, wet=0.25)
        keys.add(t0, s.bell(note + 12, 0.6, 0.25), gain=0.05, pan_to=0.3, wet=0.4)

# ---------------------------------------------------------------- the sign, the cursor and the click

catch = at(cue["catch"])
fx.add(catch - 0.22, s.slide(0.24, 1700, 760), gain=0.07, pan_to=0.25, wet=0.3)
fx.add(catch, s.knock(1.0), gain=0.45, pan_to=0.2, wet=0.15)
fx.add(catch + 0.04, s.creak(0.55, 880), gain=0.07, pan_to=0.2, wet=0.2)

fx.add(at(cue["cursor"]), s.whoosh(at(cue["hover"]) - at(cue["cursor"]), 700, 2600), gain=0.12, pan_to=np.linspace(0.6, 0.1, int((at(cue["hover"]) - at(cue["cursor"])) * s.SR)), wet=0.2)

press = at(cue["click"])
fx.add(press - 0.02, s.click(1.0), gain=0.35, pan_to=0.15, wet=0.05)
for i, note in enumerate((86, 93, 98)):
    keys.add(press + i * 0.045, s.bell(note, 2.4, 0.9), gain=0.17, pan_to=0.1 + 0.1 * i, wet=0.5)
fx.add(press + 0.2, s.tick(1.0), gain=0.12, pan_to=0.2, wet=0.1)
fx.add(press + 0.03, s.boing(0.5, 420, 9, 0.15), gain=0.06, pan_to=0.15, wet=0.2)
# The sign jumps on its rope.
fx.add(press + 0.04, s.slide(0.16, 650, 1500), gain=0.05, pan_to=0.25, wet=0.3)

# ---------------------------------------------------------------- the end

fx.add(at(cue["end"]) - 0.1, s.whoosh(0.9, 400, 2000), gain=0.14, wet=0.3)
stop = at(DROP_END)
drums.add(stop, s.kick(1.0, 0.6), gain=0.9, wet=0.1)
kicks.append(stop)
drums.add(stop, s.crash(0.9, 2.8), gain=0.42, wet=0.35)
fx.add(stop, s.boom(2.4, 1.0), gain=0.35, wet=0.3)
music.add(stop, s.stab(CHORDS["D"][1], 1.0, 0.7), gain=0.45, wet=0.35)
music.add(stop, s.supersaw(CHORDS["D"][1], (BEATS - DROP_END) * BEAT - 0.2, cutoff=2600, attack=0.05, release=0.3), gain=0.24, wet=0.45)
music.add(stop, s.lead(86, BEAT * 1.5, 0.9), gain=0.26, wet=0.35)
for i, note in enumerate((81, 86, 90)):
    keys.add(stop + 0.5 + i * BEAT, s.bell(note, 2.5, 0.7), gain=0.12, pan_to=-0.2 + 0.2 * i, wet=0.55)

# The hum comes back for the last bar, rising to where it starts, so a loop runs on without a seam.
start = at(cue["recharge"])
n = int((TOTAL - start) * s.SR)
k = np.linspace(0, 1, n)
p0 = charge(0)
fx.add(start, s.hum(40 + (47 + 26 * p0**1.5 - 40) * k, (0.15 + 0.85 * p0**2) * k**1.5), gain=0.075, wet=0.15)
fx.add(start, s.crackle(TOTAL - start, lambda x: 4 + 30 * (x / (TOTAL - start)) ** 2, lambda x: 0.3), gain=0.12, wet=0.25)

# ---------------------------------------------------------------- mix

pump = s.sidechain(TOTAL + 4, kicks, depth=0.6, release=0.16)
music.duck(1 - 0.75 * (1 - pump))
low.duck(1 - 0.55 * (1 - pump))
mix = s.master([drums, low, music, keys, fx], seconds=TOTAL, target=-14.0, ceiling=-1.0)

out = ROOT / "public/star"
out.mkdir(parents=True, exist_ok=True)
s.write(out / "score.wav", mix)

# Its level at every video frame, and its cues, for the storyboard sheet's waveform.
fps = sheet["fps"]
per = s.SR // fps
frames = len(mix) // per
rms = np.sqrt((mix[: frames * per] ** 2).mean(axis=1).reshape(frames, per).mean(axis=1))
(out / "score.json").write_text(json.dumps({"fps": fps, "level": [round(float(x), 4) for x in rms / rms.max()]}))
print(f"==> public/star/score.wav ({TOTAL:.1f} s, {s.loudness(mix):.1f} LUFS, true peak {s.true_peak(mix):.1f} dBFS)")
