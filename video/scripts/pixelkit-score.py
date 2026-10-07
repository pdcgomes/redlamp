#!/usr/bin/env python3
"""
The pixelkit promo's score (src/pixelkit/PixelkitPromo.tsx): 30.4 seconds at 150 BPM in C major,
written from the promo's cue sheet, src/pixelkit/cues.json, so every sound lands on the frame its
picture does.

    python3 scripts/pixelkit-score.py      # public/pixelkit/score.wav, and score.json for the storyboard sheet

Warm chiptune, as the brief asks: an 8-bit console's pulses, triangle and noise (synth.py's
chiptune voices), over the "royal road" progression game music loves (Fmaj7, G6, Em7, Am9), with
the chords' sevenths and ninths in the arpeggios. The opening is the bedroom's own sounds: a key
click for each letter of the dial command and the real key tone for each digit, the ringing, the
modem's handshake, then CONNECT. The BBS's menu blips in, a key picks SHOWCASE, the CRT switches off
with a falling zap over a snare roll, and the groove drops with the montage: a pulse lead with an
echo, the triangle's bass, noise drums, and a crash on every cut. It breaks down for the code, a
click for each line and a rising blip for each bar of the chart, comes back for the CONTINUE?
screen with a beep on every count, takes a coin, and resolves on Cmaj9 as the picture fades.
Needs numpy.
"""

import json
from pathlib import Path

import numpy as np

import synth as s

ROOT = Path(__file__).resolve().parent.parent
sheet = json.loads((ROOT / "src/pixelkit/cues.json").read_text())
BEAT = 60 / sheet["bpm"]
FPS = sheet["fps"]
BEATS = sheet["bars"] * sheet["beatsPerBar"]
TOTAL = BEATS * BEAT
cue = sheet["cues"]


def at(beat):
    return beat * BEAT


def frame_of(seconds):
    """The time of the first frame at or after `seconds`: where a picture event first shows."""
    return np.ceil(seconds * FPS - 1e-6) / FPS


# Each chord: its root (the triangle plays it an octave or two up) and the arpeggio's notes, with
# the colour notes that make it warm.
CHORDS = {
    "Fmaj7": (41, [65, 69, 72, 76]),
    "G6": (43, [67, 71, 74, 76]),
    "Em7": (40, [64, 67, 71, 74]),
    "Am9": (45, [69, 72, 76, 83]),
    "Dm9": (38, [62, 65, 69, 76]),
    "G7sus": (43, [67, 72, 74, 77]),
    "A7": (45, [69, 73, 76, 79]),
    "G13": (43, [67, 71, 76, 77]),
    "Cmaj9": (36, [64, 67, 71, 74]),
}
# The lead, [beat, note, beats]: two passes over the montage, a climb through the quick cuts, and
# the first phrase again for the ask.
PHRASE_A = [(0, 69, 1.5), (1.5, 67, 0.5), (2, 69, 0.5), (2.5, 72, 1.5), (4, 71, 1), (5, 74, 1), (6, 76, 2),
            (8, 74, 1), (9, 76, 0.5), (9.5, 79, 1.5), (11, 76, 1), (12, 72, 1.5), (13.5, 71, 0.5), (14, 69, 2)]
PHRASE_B = [(0, 69, 0.5), (0.5, 72, 0.5), (1, 77, 1.5), (2.5, 76, 0.5), (3, 72, 1), (4, 74, 1), (5, 71, 0.5),
            (5.5, 74, 0.5), (6, 79, 2), (8, 79, 0.5), (8.5, 81, 0.5), (9, 79, 1), (10, 76, 1), (11, 74, 1),
            (12, 76, 1.5), (13.5, 74, 0.5), (14, 72, 1), (15, 71, 0.5), (15.5, 67, 0.5)]
CLIMB = [69, 72, 76, 77, 71, 74, 76, 79, 71, 74, 76, 79, 73, 76, 79, 81]
ASK = [(0, 69, 1.5), (1.5, 67, 0.5), (2, 69, 0.5), (2.5, 72, 1.5), (4, 71, 1), (5, 74, 1), (6, 76, 2),
       (8, 79, 1), (9, 76, 1), (10, 74, 1), (11, 77, 1)]


def chord_at(beat):
    for name, first, length in sheet["chords"]:
        if first <= beat < first + length:
            return name
    return sheet["chords"][-1][0]


s.reset(23)
room = s.reverb(1.8, 0.5, 0.02)
drums, low, chip, lead, fx = (s.Bus(TOTAL + 4) for _ in range(5))
kicks = []
DROP, HOW, ASK_AT, THANKS = cue["drop"], cue["how"], cue["ask"], cue["thanks"]

# ---------------------------------------------------------------- the bedroom: dialling up

# The first frame lands with the PC's power switch: a thunk and a rising chirp.
drums.add(0, s.chip_kick(0.8), gain=0.5, wet=0.1)
fx.add(0, s.pulse(84, 0.1, 0.7, duty=0.5, slide=-24, decay=0.06, sustain=0.0), gain=0.16, wet=0.3)

# A soft arpeggio under the room from the first frame, and the triangle from the second bar.
for name, first, length in sheet["chords"]:
    if first >= cue["bbs"]:
        break
    _, notes = CHORDS[name]
    chip.add(at(first), s.arp(notes, length * BEAT, 0.5, rate=20, warmth=2600), gain=0.32, pan_to=-0.25, wet=0.35)
for beat in np.arange(4, cue["bbs"], 1):
    root, _ = CHORDS[chord_at(beat)]
    low.add(at(beat), s.triangle(root + 12, BEAT * 0.8, 0.6), gain=0.4, wet=0.05)

# The dial command, typed as the bedroom's CRT types it (pixelkit's reveal()): a key click for each
# letter, the key's own tone for each digit.
typing = sheet["typing"]
text = typing["text"]
for k, ch in enumerate(text, start=1):
    p = (k - 0.5) / len(text)
    t = frame_of(at(typing["from"]) + p * (at(typing["to"]) - at(typing["from"])))
    if ch in s.DTMF:
        fx.add(t, s.dtmf(ch, 0.085), gain=0.28, pan_to=0.2, wet=0.1)
    elif ch != " ":
        fx.add(t, s.click(0.7), gain=0.22, pan_to=0.2, wet=0.05)
fx.add(at(cue["ring"]), s.ringback(at(cue["handshake"]) - at(cue["ring"]) - 0.02), gain=0.22, pan_to=0.15, wet=0.15)
shake_len = at(cue["connect"]) - at(cue["handshake"])
fx.add(at(cue["handshake"]), s.handshake(shake_len), gain=0.3, pan_to=0.1, wet=0.15)
for i, note in enumerate((84, 91)):
    fx.add(at(cue["connect"]) + i * 0.08, s.blip(note, 0.9, 0.07, duty=0.5), gain=0.3, wet=0.3)
# The dialog box drops away as the modem connects, and the picture punches in on the CRT.
fx.add(at(cue["connect"] - 0.5), s.pulse(72, 0.2, 0.6, duty=0.5, slide=12, decay=0.1, sustain=0.0), gain=0.14, wet=0.2)
fx.add(at(cue["zoom"]), s.pulse(79, 0.16, 0.7, duty=0.25, slide=-12, decay=0.08, sustain=0.0), gain=0.18, wet=0.25)

# ---------------------------------------------------------------- the BBS

drums.add(at(cue["bbs"]), s.chip_crash(0.7, 1.2), gain=0.35, wet=0.3)
for note, dt in ((72, 0), (76, 0.06), (79, 0.12), (84, 0.18)):
    chip.add(at(cue["bbs"]) + dt, s.blip(note, 0.8, 0.09, duty=0.125), gain=0.3, pan_to=-0.1, wet=0.4)
for beat in np.arange(cue["bbs"], DROP - 0.5, 1):
    drums.add(at(beat), s.chip_kick(0.85), gain=0.55, wet=0.05)
    kicks.append(at(beat))
for beat in np.arange(cue["bbs"], cue["off"], 0.5):
    root, _ = CHORDS[chord_at(beat)]
    low.add(at(beat), s.triangle(root + (24 if beat % 1 else 12), BEAT * 0.45, 0.8), gain=0.42, wet=0.05)
for name, first, length in sheet["chords"]:
    if cue["bbs"] <= first < DROP:
        _, notes = CHORDS[name]
        chip.add(at(first), s.arp(notes, length * BEAT, 0.65, rate=30, warmth=4200), gain=0.3, pan_to=-0.25, wet=0.3)
# The menu blips in item by item, up the chord; the key picks SHOWCASE.
for i, note in enumerate((79, 81, 84, 88)):
    fx.add(frame_of(at(cue["menu"] + 0.5 * i)), s.blip(note, 0.8, 0.05), gain=0.22, pan_to=0.15, wet=0.2)
fx.add(at(cue["press"]), s.click(1.0), gain=0.35, pan_to=0.1, wet=0.05)
fx.add(at(cue["press"]), s.blip(91, 0.9, 0.08, duty=0.5), gain=0.24, wet=0.25)
# A snare roll into the drop, and the CRT switching off as a falling zap.
for i, beat in enumerate(np.arange(cue["press"], DROP, 0.125)):
    drums.add(at(beat), s.chip_snare(0.35 + 0.65 * i / 8, 0.12), gain=0.4, pan_to=0.1 if i % 2 else -0.1, wet=0.15)
fx.add(at(cue["off"]), s.zap(at(DROP) - at(cue["off"]), 2400, 120), gain=0.16, wet=0.2)

# ---------------------------------------------------------------- the showcase, and the ask


def groove(first, last, weight=1.0):
    """Kick on 1, the and of 2 and 3; snare on 2 and 4; hats in eighths, open on the and of 4."""
    for bar in np.arange(first, last, 4):
        for offset in (0, 1.5, 2):
            beat = bar + offset
            drums.add(at(beat), s.chip_kick(weight * (1.0 if offset == 0 else 0.8)), gain=0.6, wet=0.04)
            kicks.append(at(beat))
        for offset in (1, 3):
            drums.add(at(bar + offset), s.chip_snare(weight), gain=0.42, wet=0.18)
        for offset in np.arange(0, 4, 0.5):
            drums.add(at(bar + offset), s.chip_hat(0.7 if offset % 1 == 0 else 0.45, open=offset == 3.5),
                      gain=0.22 * weight, pan_to=0.25, wet=0.08)


def bassline(first, last, step=0.5):
    for beat in np.arange(first, last, step):
        root, _ = CHORDS[chord_at(beat)]
        up = int(round(beat / step)) % 2
        low.add(at(beat), s.triangle(root + (24 if up else 12), BEAT * step * 0.85, 0.9), gain=0.45, wet=0.04)


def arps(first, last, gain=0.3):
    for name, start, length in sheet["chords"]:
        if first <= start < last:
            _, notes = CHORDS[name]
            chip.add(at(start), s.arp(notes, length * BEAT, 0.75, rate=30), gain=gain, pan_to=-0.3, wet=0.25)


def sing(first, phrase, velocity=0.85):
    """The lead, with a dotted-eighth echo on either side."""
    for beat, note, beats in phrase:
        tone = s.pulse(note, beats * BEAT * 0.92, velocity, duty=0.25, vibrato=0.25, warmth=5000)
        t = at(first + beat)
        lead.add(t, tone, gain=0.42, pan_to=0.05, wet=0.25)
        lead.add(t + 0.75 * BEAT, tone, gain=0.13, pan_to=-0.5, wet=0.4)
        lead.add(t + 1.5 * BEAT, tone, gain=0.05, pan_to=0.5, wet=0.5)


drums.add(at(DROP), s.chip_crash(1.0, 1.6), gain=0.45, wet=0.3)
groove(DROP, cue["quick"])
groove(cue["quick"], HOW, 1.05)
bassline(DROP, HOW)
arps(DROP, HOW)
sing(DROP, PHRASE_A)
sing(DROP + 16, PHRASE_B)
sing(cue["quick"], [(i * 0.5, note, 0.5) for i, note in enumerate(CLIMB)], 0.8)
# A crash on every cut of the montage, lighter on the quick ones, and a blip as each caption types in.
for start, *_ in sheet["montage"]:
    if start > DROP:
        quick = start >= cue["quick"]
        drums.add(at(start), s.chip_crash(0.55 if quick else 0.75, 0.6 if quick else 1.0), gain=0.3, wet=0.25)
    fx.add(at(start), s.blip(96, 0.6, 0.03, duty=0.125), gain=0.12, pan_to=0.3, wet=0.2)
drums.add(at(HOW - 0.5), s.chip_snare(0.9), gain=0.4, wet=0.2)

# How it's made: the drums break down to a kick and hats, a rattle of keys for each line typed,
# a blip up the chord for each bar of the chart, and the agent's prompt typed too.
for bar in np.arange(HOW, ASK_AT, 4):
    for offset in (0, 2):
        drums.add(at(bar + offset), s.chip_kick(0.7), gain=0.5, wet=0.04)
        kicks.append(at(bar + offset))
    for offset in np.arange(0, 4, 0.5):
        drums.add(at(bar + offset), s.chip_hat(0.5), gain=0.16, pan_to=0.25, wet=0.08)
bassline(HOW, ASK_AT, step=1)
arps(HOW, ASK_AT, gain=0.24)


def rattle(first, beats, count):
    for k in range(count):
        t = frame_of(at(first) + (k + 0.5) / count * beats * BEAT)
        fx.add(t, s.click(0.45 + 0.2 * s.rng.uniform()), gain=0.16, pan_to=0.15, wet=0.05)


for start in sheet["code"][:4]:
    rattle(start, 0.75, 7)
rattle(cue["skill"], 1.0, 9)
chart = sheet["code"][2] + 0.75
for i, note in enumerate((72, 74, 76, 79, 81, 84, 86)):
    fx.add(at(chart + i * 1.5 / 7), s.blip(note, 0.7, 0.05, duty=0.125), gain=0.18, pan_to=0.3, wet=0.3)
for i, note in enumerate((88, 91)):
    fx.add(at(sheet["code"][3] + 0.75) + i * 0.07, s.blip(note, 0.8, 0.06, duty=0.5), gain=0.2, pan_to=0.3, wet=0.3)

# The ask: the groove comes back with CONTINUE?, a beep on every count, then a coin.
drums.add(at(ASK_AT), s.chip_crash(1.0, 1.4), gain=0.45, wet=0.3)
groove(ASK_AT, THANKS)
bassline(ASK_AT, THANKS)
arps(ASK_AT, THANKS)
sing(ASK_AT, ASK)
# The ask arrives at a height: a thin pulse doubles the lead an octave up.
for beat, note, beats in ASK:
    lead.add(at(ASK_AT + beat), s.pulse(note + 12, beats * BEAT * 0.9, 0.6, duty=0.125, vibrato=0.2, warmth=4200),
             gain=0.2, pan_to=-0.15, wet=0.35)
for beat in sheet["countdown"]:
    fx.add(at(beat), s.blip(100, 0.7, 0.06, duty=0.5), gain=0.12, pan_to=0.2, wet=0.2)
fx.add(at(cue["coin"]), s.coin(1.0), gain=0.3, pan_to=0.1, wet=0.3)

# ---------------------------------------------------------------- the end

end = at(THANKS)
drums.add(end, s.chip_crash(1.0, 2.0), gain=0.45, wet=0.35)
drums.add(end, s.chip_kick(1.0), gain=0.6, wet=0.05)
kicks.append(end)
ring = TOTAL - end
root, notes = CHORDS["Cmaj9"]
chip.add(end, s.arp(notes + [79], ring, 0.8, rate=24, release=0.4), gain=0.3, pan_to=-0.25, wet=0.45)
low.add(end, s.triangle(root + 12, ring - 0.4, 0.9, release=0.4), gain=0.45, wet=0.1)
lead.add(end, s.pulse(76, ring - 0.4, 0.8, duty=0.25, vibrato=0.3, decay=0.8, sustain=0.4, release=0.4), gain=0.4, wet=0.4)
for i, note in enumerate((84, 79, 76, 72, 67, 64)):
    chip.add(end + 0.4 + i * 0.2, s.blip(note, 0.5 - 0.06 * i, 0.12, duty=0.125), gain=0.2, pan_to=-0.3 + 0.12 * i, wet=0.5)

# ---------------------------------------------------------------- mix

pump = s.sidechain(TOTAL + 4, kicks, depth=0.35, release=0.12)
chip.duck(1 - 0.4 * (1 - pump))
low.duck(1 - 0.25 * (1 - pump))
fade = at(cue["out"]) - at(cue["fade"])
mix = s.master([drums, low, chip, lead, fx], seconds=TOTAL, target=-14.0, ceiling=-1.0, room=room, wet=0.6,
               presence=2.0, fade=fade)

out = ROOT / "public/pixelkit"
out.mkdir(parents=True, exist_ok=True)
s.write(out / "score.wav", mix)

per = s.SR // FPS
frames = len(mix) // per
rms = np.sqrt((mix[: frames * per] ** 2).mean(axis=1).reshape(frames, per).mean(axis=1))
(out / "score.json").write_text(json.dumps({"fps": FPS, "level": [round(float(x), 4) for x in rms / rms.max()]}))
print(f"==> public/pixelkit/score.wav ({TOTAL:.1f} s, {s.loudness(mix):.1f} LUFS, true peak {s.true_peak(mix):.1f} dBFS)")
