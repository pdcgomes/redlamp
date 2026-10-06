#!/usr/bin/env python3
"""
A promo score's measurements, for review without listening: its loudness and true peak as the
platforms read them, its loudness bar by bar (so a build can be seen climbing), how close each cue's
sound lands to its frame, and where its energy sits from the sub to the air.

    python3 scripts/score-report.py public/star/score.wav --cues=src/star/cues.json

Needs numpy.
"""

import argparse
import json
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth as s  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("score")
parser.add_argument("--cues", required=True)
args = parser.parse_args()

with wave.open(args.score) as f:
    x = np.frombuffer(f.readframes(f.getnframes()), "<i2").reshape(-1, 2) / 32768
sheet = json.loads(Path(args.cues).read_text())
beat = 60 / sheet["bpm"]
bar = beat * sheet["beatsPerBar"]
frame = 1 / sheet["fps"]

print(f"{args.score}: {len(x) / s.SR:.2f} s, {s.loudness(x):.1f} LUFS integrated, true peak {s.true_peak(x):.1f} dBFS")

print("\nLoudness by bar (LUFS)")
chords = {first: name for name, first, _ in sheet.get("chords", [])}
for b in range(sheet["bars"]):
    part = x[int(b * bar * s.SR) : int((b + 1) * bar * s.SR)]
    level = s.loudness(part) if len(part) > 0.4 * s.SR else float("nan")
    first = b * sheet["beatsPerBar"]
    print(f"  bar {b + 1} (beats {first}-{first + sheet['beatsPerBar']})  {level:6.1f}  {'#' * max(0, int(level + 30))}  {chords.get(first, '')}")

# The steepest rise in level near each cue, in dB over 5 ms steps, so a quiet sound starting on a
# loud bed still shows. A cue with a sound of its own should land within a frame; a cue with nothing
# new on it (a pause, the loop point) shows whatever is nearby.
print("\nCues: the steepest rise in level within 60 ms of each, against the cue's time (a frame is 33 ms)")
step = s.SR // 200
mono = np.abs(x).mean(axis=1)
peaks = 20 * np.log10(np.array([mono[i : i + step].max() for i in range(0, len(mono) - step, step)]) + 1e-6)
rise = np.maximum(np.diff(peaks, prepend=peaks[0]), 0)
for name, b in sorted(sheet["cues"].items(), key=lambda item: item[1]):
    i = int(round(b * beat * 200))
    window = rise[max(0, i - 12) : i + 13]
    if len(window) == 0:
        continue
    offset = (int(np.argmax(window)) - min(i, 12)) * 5
    flag = "" if abs(offset) <= frame * 1000 else "  more than a frame off"
    print(f"  {name:10s} beat {b:5}  {offset:+4d} ms  +{window.max():4.1f} dB{flag}")

print("\nWhere the energy is (whole score)")
spectrum = np.abs(np.fft.rfft(x.mean(axis=1))) ** 2
freqs = np.fft.rfftfreq(len(x), 1 / s.SR)
for lo, hi, name in ((20, 60, "sub"), (60, 250, "low"), (250, 2000, "mid"), (2000, 8000, "presence"), (8000, 20000, "air")):
    share = 100 * spectrum[(freqs >= lo) & (freqs < hi)].sum() / spectrum.sum()
    print(f"  {name:9s} {lo:>5}-{hi:<5} Hz  {share:5.1f} %")
side, mid = (x[:, 0] - x[:, 1]) / 2, (x[:, 0] + x[:, 1]) / 2
print(f"\nStereo width (side over mid, RMS): {np.sqrt((side**2).mean()) / np.sqrt((mid**2).mean()):.2f}")
