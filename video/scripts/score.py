#!/usr/bin/env python3
"""
The film's score, written in code: a slow 72 BPM piece in D major for a warm pad, a felt piano,
a soft bass and glass bells, cued to the beats the pictures land on (each History step, each film
stock, the keys, the logo). One WAV per cut, laid out from src/introducing/cuts.json:

    python3 scripts/score.py           # every cut, into public/film/score-<cut>.wav
    python3 scripts/score.py short     # or just one

Needs numpy. Every sound is synthesised here and nothing is sampled, so the score is free to use.
"""

import json
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SR = 48000
BEAT = 60 / 72
rng = np.random.default_rng(7)

# A chord: its bass note, the pad's voicing and the notes the piano picks from (MIDI numbers).
CHORDS = {
    "D": (38, [50, 57, 62], []),
    "Dadd9": (38, [57, 62, 64, 66], [74, 76, 78, 81]),
    "Dmaj9": (38, [57, 61, 64, 66], [73, 76, 78, 81]),
    "Dmaj9/F#": (42, [57, 61, 62, 64], [73, 74, 78, 81]),
    "Bm9": (47, [54, 57, 61, 62], [71, 73, 74, 78]),
    "Gmaj9": (43, [54, 57, 59, 62], [71, 74, 78, 81]),
    "Gmaj7": (43, [54, 59, 62, 66], [71, 74, 78, 79]),
    "Asus2": (45, [52, 57, 59, 64], [69, 71, 76, 81]),
    "Aadd9": (45, [52, 57, 59, 61], [71, 73, 76, 81]),
    "A6": (45, [54, 57, 61, 64], [73, 76, 78, 81]),
    "F#m7": (42, [57, 61, 64, 66], [73, 76, 78, 81]),
    "Em9": (40, [55, 59, 62, 66], [71, 74, 78, 79]),
}

# Each scene's chords (name, beats) for the length it has in a cut, how the piano plays over it,
# and its cues in beats from the scene's start (negative counts from its end).
SCENES = {
    "safelight": {
        12: [("D", 8), ("Dadd9", 4)],
        8: [("D", 4), ("Dadd9", 4)],
        "piano": None,
        "cues": [("drone", 0), ("bloom", -2)],
    },
    "reveal": {
        12: [("Dmaj9", 4), ("Bm9", 4), ("Gmaj9", 4)],
        10: [("Dmaj9", 4), ("Bm9", 4), ("Gmaj9", 2)],
        "piano": "full",
        "cues": [("swell", 0)],
    },
    "familiar": {12: [("Asus2", 4), ("Dmaj9", 4), ("F#m7", 4)], "piano": "full", "cues": []},
    "steps": {
        16: [("Gmaj9", 4), ("Aadd9", 4), ("Bm9", 4), ("Gmaj7", 4)],
        14: [("Gmaj9", 4), ("Aadd9", 4), ("Bm9", 4), ("Asus2", 2)],
        "piano": "sparse",
        "cues": [("rise", 1), ("rise", 2), ("rise", 3), ("rise", 4), ("rise", 5)],
    },
    "originals": {10: [("Dmaj9/F#", 4), ("Em9", 6)], "piano": "full", "cues": []},
    "masks": {
        16: [("Gmaj9", 4), ("A6", 4), ("Bm9", 4), ("F#m7", 4)],
        12: [("Gmaj9", 4), ("A6", 4), ("F#m7", 4)],
        "piano": "full",
        "cues": [],
    },
    "film": {
        16: [("Gmaj9", 4), ("Dmaj9", 4), ("Em9", 4), ("Asus2", 4)],
        12: [("Gmaj9", 4), ("Em9", 4), ("Asus2", 4)],
        "piano": "sparse",
        "cues": [("shimmer", 1), ("deck", 7), ("deck", 9), ("deck", 11), ("deck", 13), ("deck", 15)],
    },
    "keyboard": {8: [("Bm9", 4), ("Gmaj9", 4)], "piano": "sparse", "cues": [("key", 1), ("key", 1.5), ("open", 2)]},
    "native": {8: [("Dmaj9/F#", 4), ("Gmaj9", 2), ("Asus2", 2)], "piano": "full", "cues": []},
    "end": {10: [("Dmaj9", 10)], 8: [("Dmaj9", 8)], "piano": "last", "cues": [("swell", 0), ("icon", 4)]},
}

RISE = [81, 83, 85, 86, 88]
DECK = [78, 81, 76, 83, 74]


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def shape(x, gain_of):
    """Filters a whole signal in the frequency domain by a magnitude curve of frequency."""
    spectrum = np.fft.rfft(x, axis=0)
    gain = gain_of(np.fft.rfftfreq(x.shape[0], 1 / SR))
    return np.fft.irfft(spectrum * (gain[:, None] if x.ndim == 2 else gain), n=x.shape[0], axis=0)


def lowpass(x, cutoff, order=2):
    """A Butterworth-shaped low-pass."""
    return shape(x, lambda f: 1 / np.sqrt(1 + (f / cutoff) ** (2 * order)))


def highpass(x, cutoff, order=2):
    return shape(x, lambda f: 1 / np.sqrt(1 + (cutoff / np.maximum(f, 1e-3)) ** (2 * order)))


def loudness(x):
    """Integrated loudness in LUFS, near enough for music without silence: K-weighted (BS.1770's
    high shelf and high-pass, as magnitude curves), without the gate."""
    weighted = shape(
        x,
        lambda f: (1 / np.sqrt(1 + (38 / np.maximum(f, 1e-3)) ** 4)) * np.sqrt(1 + (10 ** (4 / 10) - 1) / (1 + (1500 / np.maximum(f, 1e-3)) ** 2)),
    )
    return -0.691 + 10 * np.log10((weighted**2).mean(axis=0).sum())


class Track:
    """A stereo buffer that notes are added into, with a send to the reverb."""

    def __init__(self, seconds):
        self.dry = np.zeros((int(seconds * SR) + SR * 8, 2))
        self.send = np.zeros_like(self.dry)

    def add(self, at, signal, gain=1.0, pan=0.0, wet=0.4):
        start = int(at * SR)
        if start < 0:
            signal = signal[-start:]
            start = 0
        end = min(start + len(signal), len(self.dry))
        signal = signal[: end - start]
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        stereo = signal[:, None] * np.array([left, right]) * gain if signal.ndim == 1 else signal * gain
        self.dry[start:end] += stereo * (1 - wet * 0.5)
        self.send[start:end] += stereo * wet


def envelope(n, attack, release, hold=None):
    t = np.arange(n) / SR
    hold = (n / SR - release) if hold is None else hold
    rise = np.clip(t / max(attack, 1e-3), 0, 1)
    fall = np.clip(1 - (t - hold) / max(release, 1e-3), 0, 1)
    return (np.sin(rise * np.pi / 2) ** 2) * (np.sin(fall * np.pi / 2) ** 2)


def pad(note, seconds, attack=1.1, release=1.6):
    """Three detuned voices of a soft, few-harmonic tone, slowly breathing."""
    n = int((seconds + release) * SR)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    for cents, pan in ((-6, -0.45), (0, 0), (6, 0.45)):
        f = hz(note) * 2 ** (cents / 1200)
        tone = np.zeros(n)
        for k, amp in enumerate((1, 0.42, 0.2, 0.1, 0.05), start=1):
            if f * k < 7000:
                tone += amp * np.sin(2 * np.pi * f * k * t + rng.uniform(0, 2 * np.pi))
        breathe = 1 + 0.12 * np.sin(2 * np.pi * rng.uniform(0.07, 0.16) * t + rng.uniform(0, 6.3))
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        out += (tone * breathe)[:, None] * np.array([left, right])
    return out * envelope(n, attack, release, hold=seconds)[:, None] / 3


def piano(note, velocity, seconds=4.8):
    """A felt piano: two slightly detuned strings of inharmonic partials, the high ones dying first."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    f0 = hz(note)
    out = np.zeros(n)
    for string in (-0.6, 0.6):
        f = f0 * 2 ** (string / 1200)
        for k in range(1, 13):
            fk = k * f * np.sqrt(1 + 0.00035 * k * k)
            if fk > 9000:
                break
            amp = velocity ** (1 + 0.15 * k) / k**1.15
            tau = 2.8 / (1 + 0.55 * (k - 1))
            out += amp * np.sin(2 * np.pi * fk * t + rng.uniform(0, 6.3)) * np.exp(-t / tau)
    hammer = rng.standard_normal(n) * np.exp(-t / 0.006) * 0.04 * velocity
    out = out + np.convolve(hammer, np.ones(9) / 9, mode="same")
    attack = np.clip(t / 0.004, 0, 1)
    release = np.clip((seconds - t) / 0.4, 0, 1)
    return out * attack * release * 0.35


def bell(note, seconds=4.0, velocity=1.0):
    """Glass: a few inharmonic partials with long, separate decays."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for ratio, amp, tau in ((1, 1, 2.2), (2.0, 0.28, 1.4), (2.76, 0.2, 1.0), (4.07, 0.08, 0.6), (5.4, 0.04, 0.4)):
        out += amp * np.sin(2 * np.pi * hz(note) * ratio * t + rng.uniform(0, 6.3)) * np.exp(-t / tau)
    return out * np.clip(t / 0.002, 0, 1) * velocity * 0.3


def bass(note, seconds, attack=0.6, release=1.2):
    n = int((seconds + release) * SR)
    t = np.arange(n) / SR
    f = hz(note)
    tone = np.sin(2 * np.pi * f * t) + 0.18 * np.sin(4 * np.pi * f * t)
    return tone * envelope(n, attack, release, hold=seconds)


def air(seconds, cutoff=1400, shape="swell"):
    """Filtered noise: a breath of room tone, or a swell that rises into a cue."""
    n = int(seconds * SR)
    noise = lowpass(rng.standard_normal((n, 2)), cutoff, order=2)
    t = np.linspace(0, 1, n)
    curve = t**2.2 * (1 - np.clip((t - 0.97) / 0.03, 0, 1)) if shape == "swell" else np.sin(np.pi * t) ** 2
    return noise * curve[:, None]


def reverb(seconds=4.5, decay=0.62, predelay=0.024):
    """A synthetic hall: decorrelated noise in each ear, decaying, darker as it goes."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    early = rng.standard_normal((n, 2)) * np.exp(-t / decay)[:, None]
    dark = lowpass(early, 2600)
    blend = np.clip(t / 1.2, 0, 1)[:, None]
    ir = early * (1 - blend) * 0.5 + dark * (0.5 + 0.5 * blend)
    ir = np.vstack([np.zeros((int(predelay * SR), 2)), ir])
    return ir / np.sqrt((ir**2).sum(axis=0))


def convolve(x, ir):
    size = 1 << int(np.ceil(np.log2(len(x) + len(ir))))
    out = np.empty((len(x) + len(ir) - 1, 2))
    for c in range(2):
        out[:, c] = np.fft.irfft(np.fft.rfft(x[:, c], size) * np.fft.rfft(ir[:, c], size), size)[: out.shape[0]]
    return out


def write(path, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())


def score(cut, scenes):
    total = sum(bars * 4 for _, bars in scenes) * BEAT
    track = Track(total)
    at = 0.0
    bar = 0
    for scene, bars in scenes:
        beats = int(round(bars * 4))
        spec = SCENES[scene]
        chords = spec[beats] if beats in spec else spec[max(k for k in spec if isinstance(k, int))]
        when = at
        for i, (name, length) in enumerate(chords):
            root, voicing, upper = CHORDS[name]
            seconds = length * BEAT
            drone = name == "D"
            for note in voicing:
                track.add(when, pad(note, seconds, attack=2.4 if drone else 1.1), gain=0.045 if drone else 0.04, wet=0.6)
            track.add(when, bass(root, seconds), gain=0.032 if drone else 0.035, wet=0.15)
            style = spec["piano"]
            if upper and style and not (style == "last" and i < len(chords) - 1):
                for b in range(0, length, 4):
                    choice = [upper[(bar + b // 4) % len(upper)], upper[(bar + 2 + b // 4) % len(upper)], upper[(bar + 1) % len(upper)]]
                    hits = [(0, 0.55)] if style in ("sparse", "last") else [(0, 0.55), (1.5, 0.38), (2.5, 0.42)]
                    for (offset, velocity), note in zip(hits, choice):
                        if b + offset < length:
                            track.add(when + (b + offset) * BEAT, piano(note, velocity), gain=0.27, pan=(note - 76) / 30, wet=0.42)
                bar += max(1, length // 4)
            when += seconds
        for cue, beat in spec["cues"]:
            # A shorter cut of the scene has fewer of its pictures, so its later cues go too.
            if beat >= beats:
                continue
            t = at + (beat if beat >= 0 else beats + beat) * BEAT
            if cue == "drone":
                track.add(t, air(beats * BEAT, cutoff=700, shape="breath"), gain=0.05, wet=0.5)
                for note in (74, 81):
                    track.add(t + 2.5, pad(note, beats * BEAT - 4, attack=3.5, release=2.5), gain=0.012, wet=0.8)
            elif cue == "bloom":
                track.add(t - 1.6, air(1.6, cutoff=1600), gain=0.03, wet=0.6)
                for note, delay in ((74, 0), (78, 0.06), (81, 0.12), (86, 0.18)):
                    track.add(t + delay, bell(note, 5, 0.8), gain=0.16, pan=(note - 80) / 20, wet=0.65)
                track.add(t, bass(38, 2.2, attack=0.03, release=2.5), gain=0.05, wet=0.25)
            elif cue == "swell":
                track.add(t - 2 * BEAT, air(2 * BEAT, cutoff=1400), gain=0.028, wet=0.6)
            elif cue == "rise":
                track.add(t, bell(RISE[int(beat) - 1], 4.5, 0.75), gain=0.18, pan=-0.3 + 0.15 * beat, wet=0.55)
            elif cue == "deck":
                track.add(t, bell(DECK[int((beat - 7) / 2) % len(DECK)], 4, 0.6), gain=0.16, pan=0.25, wet=0.55)
            elif cue == "shimmer":
                for note in (86, 90, 93):
                    track.add(t, pad(note, 4 * BEAT, attack=1.6, release=2.0), gain=0.008, wet=0.85)
            elif cue == "key":
                n = int(0.05 * SR)
                k = np.arange(n) / SR
                click = rng.standard_normal(n) * np.exp(-k / 0.003) * 0.5 + np.sin(2 * np.pi * 110 * k) * np.exp(-k / 0.018)
                track.add(t, np.convolve(click, np.ones(5) / 5, mode="same"), gain=0.12, wet=0.15)
            elif cue == "open":
                track.add(t, bell(88, 3, 0.5), gain=0.12, pan=0.3, wet=0.6)
            elif cue == "icon":
                for note, delay in ((74, 0), (81, 0.08), (85, 0.16), (90, 0.24)):
                    track.add(t + delay, bell(note, 6, 0.7), gain=0.14, pan=(note - 82) / 20, wet=0.7)
        at += beats * BEAT

    wet = convolve(track.send, reverb())[: len(track.dry)]
    mix = track.dry + wet * 0.85
    n = int(total * SR)
    mix = highpass(lowpass(mix, 11000, order=1), 35)[:n]
    # Level: about -16 LUFS, quiet enough to sit under a voice or a feed's own sound, with a soft knee
    # above -2 dBFS instead of clipping, and a fade at the very end.
    mix *= 10 ** ((-15.3 - loudness(mix)) / 20)
    knee = 0.79
    over = np.abs(mix) > knee
    mix[over] = np.sign(mix[over]) * (knee + (1 - knee) * np.tanh((np.abs(mix[over]) - knee) / (1 - knee)))
    fade = np.clip((n - np.arange(n)) / (2.2 * SR), 0, 1) ** 1.5
    mix *= fade[:, None]
    out = ROOT / "public/film" / f"score-{cut}.wav"
    out.parent.mkdir(parents=True, exist_ok=True)
    write(out, mix)
    print(f"==> {out.relative_to(ROOT)} ({total:.1f} s)")


cuts = json.loads((ROOT / "src/introducing/cuts.json").read_text())
for cut in sys.argv[1:] or list(cuts):
    score(cut, cuts[cut])
