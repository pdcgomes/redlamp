#!/usr/bin/env python3
"""
The film's score, written in code: a 72 BPM piece in D major for a warm pad, a felt piano, a soft
bass and glass bells, over a beat that builds scene by scene (a heartbeat, then ticks, a running
pulse, then the full groove at the film looks) and drops away for the closing line. Its cues land
on the beats the pictures do: each History step, the push into the display, the edit lifting off,
the subject separating, the CineStill wipe, each film stock, the keys, each closing line and the
icon. One WAV per cut, laid out from src/introducing/cuts.json:

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

# Each scene, for the lengths it has in the cuts (in beats): its chords (name, beats), the beat's
# level in each of its bars (0 none, 1 a heartbeat, 2 with ticks, 3 a running pulse, 4 the full
# groove), how the piano plays, and its cues in beats from its start (negative: from its end).
SCENES = {
    "safelight": {
        12: ([("D", 8), ("Dadd9", 4)], [0, 0, 0]),
        8: ([("D", 4), ("Dadd9", 4)], [0, 0]),
        "piano": None,
        "cues": [("drone", 0), ("bloom", -2)],
    },
    "reveal": {
        12: ([("Dmaj9", 4), ("Bm9", 4), ("Gmaj9", 4)], [0, 1, 1]),
        10: ([("Dmaj9", 4), ("Bm9", 4), ("Gmaj9", 2)], [1, 1, 1]),
        "piano": "full",
        "cues": [("swell", 0), ("power", 0.5), ("push", -0.5)],
    },
    "familiar": {12: ([("Asus2", 4), ("Dmaj9", 4), ("F#m7", 4)], [2, 2, 2]), "piano": "full", "cues": []},
    "steps": {
        16: ([("Gmaj9", 4), ("Aadd9", 4), ("Bm9", 4), ("Gmaj7", 4)], [3, 3, 3, 3]),
        14: ([("Gmaj9", 4), ("Aadd9", 4), ("Bm9", 4), ("Asus2", 2)], [2, 3, 3, 3]),
        "piano": "pulse",
        "cues": [("rise", 1), ("rise", 2), ("rise", 3), ("rise", 4), ("rise", 5)],
    },
    "originals": {10: ([("Dmaj9/F#", 4), ("Em9", 6)], [2, 2, 1]), "piano": "full", "cues": [("whoosh", 0.5)]},
    "masks": {
        16: ([("Gmaj9", 4), ("A6", 4), ("Bm9", 4), ("F#m7", 4)], [2, 3, 4, 4]),
        12: ([("Gmaj9", 4), ("A6", 4), ("F#m7", 4)], [3, 4, 4]),
        "piano": "pulse",
        "cues": [("lift", 1), ("window", -5.5)],
    },
    "film": {
        16: ([("Gmaj9", 4), ("Dmaj9", 4), ("Em9", 4), ("Asus2", 4)], [4, 4, 4, 4]),
        12: ([("Gmaj9", 4), ("Em9", 4), ("Asus2", 4)], [4, 4, 4]),
        "piano": "pulse",
        "cues": [("wipe", 1), ("deck", 7), ("deck", 9), ("deck", 11), ("deck", 13), ("deck", 15)],
    },
    "keyboard": {8: ([("Bm9", 4), ("Gmaj9", 4)], [3, 3]), "piano": "sparse", "cues": [("key", 1), ("key", 1.5), ("open", 2)]},
    "native": {8: ([("Dmaj9/F#", 4), ("Gmaj9", 2), ("Asus2", 2)], [3, 4]), "piano": "full", "cues": []},
    # The closing line's phrases land on these beats (`closing` in src/introducing/scenes/End.tsx).
    "end": {
        12: ([("Dmaj9", 12)], [0, 0, 0]),
        "piano": "last",
        "cues": [("drop", 0), ("word", 2), ("icon", 6)],
    },
    # The app's welcome (src/introducing/Welcome.tsx): the opening's last chord, held while the logo
    # rises and the window's pages appear, then the fade.
    "hold": {8: ([("Dadd9", 8)], [0, 0]), "piano": None, "cues": []},
}

# A cut that opens as another does sounds just as that one's opening: its sounds are drawn as that
# cut's are, and it plays in that cut's room (the reverb, drawn after every scene) at that cut's
# level. On its own the level would follow the loudness target, which would make the welcome's
# quiet opening far louder than the film's.
OPENS_LIKE = {"welcome": "film"}

RISE = [81, 83, 85, 86, 88]
DECK = [78, 81, 76, 83, 74]

# The beat at each level, as (beat within the bar, velocity).
KICK = {
    1: [(0, 0.8)],
    2: [(0, 0.82), (2, 0.6)],
    3: [(0, 0.86), (1, 0.52), (2, 0.72), (3, 0.52)],
    4: [(0, 0.9), (1, 0.58), (2, 0.78), (3, 0.58), (3.5, 0.32)],
}
HAT = {
    2: [(b + 0.5, 0.26) for b in range(4)],
    3: [(b / 2, 0.3 if b % 2 else 0.16) for b in range(8)],
    4: [(b / 4, (0.28, 0.12, 0.22, 0.12)[b % 4]) for b in range(16)],
}
CLAP = {4: [(1, 0.55), (3, 0.6)]}


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


def sweep(x, start, end, width=0.9):
    """A band of `x` whose centre glides from `start` to `end` Hz, frame by frame (an STFT)."""
    size, hop = 2048, 512
    window = np.hanning(size)
    padded = np.concatenate([x, np.zeros(size)])
    out = np.zeros_like(padded)
    norm = np.zeros_like(padded)
    freqs = np.maximum(np.fft.rfftfreq(size, 1 / SR), 1)
    for at in range(0, len(x), hop):
        centre = start * (end / start) ** (at / max(1, len(x)))
        gain = np.exp(-0.5 * (np.log2(freqs / centre) / width) ** 2)
        frame = np.fft.irfft(np.fft.rfft(padded[at : at + size] * window) * gain, size)
        out[at : at + size] += frame * window
        norm[at : at + size] += window**2
    return out[: len(x)] / np.maximum(norm[: len(x)], 1e-3)


class Bus:
    """A stereo buffer that sounds are added into, with a send to the reverb."""

    def __init__(self, samples):
        self.dry = np.zeros((samples, 2))
        self.send = np.zeros((samples, 2))

    def add(self, at, signal, gain=1.0, pan=0.0, wet=0.4):
        start = int(round(at * SR))
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


def pad(note, seconds, attack=1.1, release=1.6, harmonics=(1, 0.42, 0.2, 0.1, 0.05), voices=(-6, 0, 6)):
    """Detuned voices of a soft, few-harmonic tone, slowly breathing."""
    n = int((seconds + release) * SR)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    for i, cents in enumerate(voices):
        pan = np.linspace(-0.5, 0.5, len(voices))[i] if len(voices) > 1 else 0
        f = hz(note) * 2 ** (cents / 1200)
        tone = np.zeros(n)
        for k, amp in enumerate(harmonics, start=1):
            if f * k < 7000:
                tone += amp * np.sin(2 * np.pi * f * k * t + rng.uniform(0, 2 * np.pi))
        breathe = 1 + 0.12 * np.sin(2 * np.pi * rng.uniform(0.07, 0.16) * t + rng.uniform(0, 6.3))
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        out += (tone * breathe)[:, None] * np.array([left, right])
    return out * envelope(n, attack, release, hold=seconds)[:, None] / len(voices)


def strings(note, seconds, bright_from, bright_to, release=1.8):
    """A bowed ensemble that opens up as it plays: its upper harmonics come in from `bright_from`
    to `bright_to` (0 dark, 1 open)."""
    n = int((seconds + release) * SR)
    t = np.arange(n) / SR
    bright = np.linspace(bright_from, bright_to, n)
    out = np.zeros((n, 2))
    for i, cents in enumerate((-11, -4, 3, 10)):
        pan = (-0.6, -0.2, 0.2, 0.6)[i]
        f = hz(note) * 2 ** (cents / 1200)
        vibrato = 1 + 0.0025 * np.sin(2 * np.pi * rng.uniform(4.5, 5.5) * t)
        phase = 2 * np.pi * np.cumsum(f * vibrato) / SR + rng.uniform(0, 6.3)
        tone = np.zeros(n)
        for k in range(1, 11):
            if f * k > 9000:
                break
            weight = 1.0 if k <= 2 else bright ** (0.5 * (k - 2))
            tone += weight * np.sin(k * phase) / k
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        out += tone[:, None] * np.array([left, right])
    return out * envelope(n, 2.2, release, hold=seconds)[:, None] / 4


_cache = {}


def cached(key, make):
    if key not in _cache:
        _cache[key] = make()
    return _cache[key]


def piano(note, velocity, seconds=4.8):
    """A felt piano: two slightly detuned strings of inharmonic partials, the high ones dying first."""

    def make():
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
        return out * np.clip(t / 0.004, 0, 1) * np.clip((seconds - t) / 0.4, 0, 1) * 0.35

    return cached(("piano", note, round(velocity, 2), seconds), make)


def bell(note, seconds=4.0, velocity=1.0):
    """Glass: a few inharmonic partials with long, separate decays."""

    def make():
        n = int(seconds * SR)
        t = np.arange(n) / SR
        out = np.zeros(n)
        for ratio, amp, tau in ((1, 1, 2.2), (2.0, 0.28, 1.4), (2.76, 0.2, 1.0), (4.07, 0.08, 0.6), (5.4, 0.04, 0.4)):
            out += amp * np.sin(2 * np.pi * hz(note) * ratio * t + rng.uniform(0, 6.3)) * np.exp(-t / tau)
        return out * np.clip(t / 0.002, 0, 1) * velocity * 0.3

    return cached(("bell", note, seconds, round(velocity, 2)), make)


def bass(note, seconds, attack=0.6, release=1.2):
    n = int((seconds + release) * SR)
    t = np.arange(n) / SR
    f = hz(note)
    tone = np.sin(2 * np.pi * f * t) + 0.18 * np.sin(4 * np.pi * f * t)
    return tone * envelope(n, attack, release, hold=seconds)


def pluck(note, velocity):
    """The pulse's bass: a short, rounded saw, its brightness following how hard it's played."""

    def make():
        n = int(0.42 * SR)
        t = np.arange(n) / SR
        f = hz(note)
        out = np.zeros(n)
        for k in range(1, 9):
            out += np.sin(2 * np.pi * f * k * t) / k * np.exp(-t / (0.32 / (1 + (1.4 - velocity) * 0.5 * k)))
        return np.tanh(out * 1.2) * np.clip(t / 0.003, 0, 1) * velocity

    return cached(("pluck", note, round(velocity, 2)), make)


def kick(velocity):
    """Soft and round: a falling sine with a little click, so small speakers still hear it."""

    def make():
        n = int(0.55 * SR)
        t = np.arange(n) / SR
        pitch = 47 + 68 * np.exp(-t / 0.042)
        body = np.sin(2 * np.pi * np.cumsum(pitch) / SR) * np.exp(-t / 0.26)
        click = lowpass(rng.standard_normal(n) * np.exp(-t / 0.0035), 4200) * 0.45
        return np.tanh((body + click) * 1.5) / np.tanh(1.5) * velocity

    return cached(("kick", round(velocity, 2)), make)


def hat(velocity, variant):
    def make():
        n = int(0.07 * SR)
        t = np.arange(n) / SR
        noise = highpass(rng.standard_normal(n), 7000, order=3)
        return noise * np.exp(-t / 0.016) * np.clip(t / 0.0008, 0, 1)

    return cached(("hat", variant), make) * velocity


def clap(velocity, variant):
    """Three quick bursts and a short tail, band-passed, with a little body."""

    def make():
        n = int(0.45 * SR)
        t = np.arange(n) / SR
        noise = rng.standard_normal(n)
        bursts = sum(np.where(t >= o, np.exp(-(t - o) / 0.006), 0) for o in (0, 0.0095, 0.0195))
        tail = np.exp(-t / 0.11) * 0.45
        crack = highpass(lowpass(noise * (bursts + tail), 5200), 900)
        return crack * 0.5 + 0.3 * np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.035)

    return cached(("clap", variant), make) * velocity


def boom(seconds=3.0, depth=1.0):
    """A low impact: a sine falling from E1 to D1 under a dark breath of noise."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    pitch = hz(26) + 14 * np.exp(-t / 0.25)
    body = np.sin(2 * np.pi * np.cumsum(pitch) / SR) * np.exp(-t / (0.9 * depth))
    air_ = lowpass(rng.standard_normal(n), 900) * np.exp(-t / 0.35) * 0.25
    return (body + air_) * np.clip(t / 0.004, 0, 1)


def riser(seconds, start=250, end=4000, curve=2.2):
    """Noise whose band glides up and swells into the cue it leads to."""
    n = int(seconds * SR)
    swell = np.linspace(0, 1, n) ** curve * (1 - np.clip((np.arange(n) - n + 0.02 * SR) / (0.02 * SR), 0, 1))
    return np.stack([sweep(rng.standard_normal(n), start, end) * swell for _ in range(2)], axis=1)


def whoosh(seconds, start=400, peak=2600):
    """Air rising and settling, for something that moves past the camera."""
    n = int(seconds * SR)
    shaped = np.sin(np.pi * np.linspace(0, 1, n) ** 0.7) ** 2
    return np.stack([sweep(rng.standard_normal(n), start, peak, width=1.1) * shaped for _ in range(2)], axis=1)


def air(seconds, cutoff=1400, form="swell"):
    """Filtered noise: a breath of room tone, or a swell that rises into a cue."""
    n = int(seconds * SR)
    noise = lowpass(rng.standard_normal((n, 2)), cutoff, order=2)
    t = np.linspace(0, 1, n)
    curve = t**2.2 * (1 - np.clip((t - 0.97) / 0.03, 0, 1)) if form == "swell" else np.sin(np.pi * t) ** 2
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


def fresh():
    """Starts the random sounds over, as at the start of a run, so a cut draws them as the run's
    first cut does."""
    global rng
    rng = np.random.default_rng(7)
    _cache.clear()


def jitter(seconds=0.004):
    return rng.uniform(-seconds, seconds)


def score(cut, scenes, room=None, save=True):
    """Writes a cut's score, and returns its room and level: its reverb and the gain that levelled
    it. `room` plays the cut in another's instead (`OPENS_LIKE`)."""
    total = sum(bars * 4 for _, bars in scenes) * BEAT
    samples = int(total * SR) + SR * 8
    pads, low, keys, drums, fx = (Bus(samples) for _ in range(5))
    kicks = []
    at = 0.0
    bar_index = 0
    for scene, bars in scenes:
        beats = int(round(bars * 4))
        spec = SCENES[scene]
        chords, levels = spec[beats]
        style = spec["piano"]
        # The bars of the groove at full level, so the strings can open up across them.
        full = [i for i, level in enumerate(levels) if level >= 4]

        when = at
        for c, (name, length) in enumerate(chords):
            root, voicing, upper = CHORDS[name]
            seconds = length * BEAT
            drone = name == "D"
            for note in voicing:
                pads.add(when, pad(note, seconds, attack=2.4 if drone else 1.1), gain=0.045 if drone else 0.04, wet=0.6)
            # Once the pulse plays the bass line, the held bass only fills under it.
            under_pulse = levels[min(int((when - at) / BEAT) // 4, len(levels) - 1)] >= 3
            low.add(when, bass(root, seconds), gain=0.032 if drone else 0.019 if under_pulse else 0.035, wet=0.15)
            for b in range(length):
                bar = int((when - at) / BEAT + b) // 4
                level = levels[min(bar, len(levels) - 1)]
                beat_at = when + b * BEAT
                in_bar = int(round((beat_at - at) / BEAT)) % 4
                # The piano: sparse phrases, or a soft running arpeggio once the pulse is in.
                if upper and style:
                    if style == "pulse" and level >= 3:
                        for half in (0, 0.5):
                            step = (bar_index * 8 + in_bar * 2 + int(half * 2)) % 6
                            note = upper[(0, 1, 2, 3, 2, 1)[step] % len(upper)]
                            keys.add(beat_at + half * BEAT + jitter(0.006), piano(note, 0.3 if half == 0 else 0.24, 1.8), gain=0.2, pan=(note - 76) / 30, wet=0.4)
                    elif style == "last" and (c < len(chords) - 1 or b > 0):
                        pass
                    elif in_bar == 0 and b % 4 == 0:
                        choice = [upper[(bar_index + b // 4) % len(upper)], upper[(bar_index + 2 + b // 4) % len(upper)], upper[(bar_index + 1) % len(upper)]]
                        hits = [(0, 0.55)] if style in ("sparse", "last", "pulse") else [(0, 0.55), (1.5, 0.38), (2.5, 0.42)]
                        for (offset, velocity), note in zip(hits, choice):
                            if b + offset < length:
                                keys.add(beat_at + offset * BEAT, piano(note, velocity), gain=0.27, pan=(note - 76) / 30, wet=0.42)
            # The strings open up across the groove's full bars.
            if full:
                bar = int((when - at) / BEAT) // 4
                if levels[min(bar, len(levels) - 1)] >= 4:
                    spread = max(1, len(full) * 4)
                    start = ((when - at) / BEAT - full[0] * 4) / spread
                    finish = start + length / spread
                    for note in voicing[1:]:
                        pads.add(when, strings(note + 12, seconds, 0.15 + 0.85 * start, 0.15 + 0.85 * finish), gain=0.016, wet=0.55)
            if style and upper:
                bar_index += max(1, length // 4)
            when += seconds

        # The beat, a bar at a time; the pulse's bass follows the chord under each eighth note.
        starts = np.cumsum([0] + [length for _, length in chords])

        def root_at(beat, starts=starts, chords=chords):
            return CHORDS[chords[int(np.searchsorted(starts, beat, side="right")) - 1][0]][0]

        def inside(beat, beats=beats):
            return beat < beats - 1e-6

        for bar, level in enumerate(levels):
            first = bar * 4
            for offset, velocity in KICK.get(level, []):
                if inside(first + offset):
                    t = at + (first + offset) * BEAT
                    drums.add(t, kick(velocity * rng.uniform(0.94, 1.0)), gain=0.27, wet=0.08)
                    kicks.append(t)
            for i, (offset, velocity) in enumerate(HAT.get(level, [])):
                if inside(first + offset):
                    t = at + (first + offset) * BEAT + jitter()
                    drums.add(t, hat(velocity * rng.uniform(0.85, 1.05), i % 6), gain=0.2, pan=0.25 if i % 2 else -0.15, wet=0.12)
            for i, (offset, velocity) in enumerate(CLAP.get(level, [])):
                if inside(first + offset):
                    drums.add(at + (first + offset) * BEAT + jitter(0.003), clap(velocity, i % 3), gain=0.15, pan=0.05, wet=0.35)
            if level >= 3:
                for eighth in range(8):
                    beat = first + eighth / 2
                    if not inside(beat):
                        break
                    octave = 12 if level >= 4 and eighth in (3, 7) else 0
                    velocity = min(1, (0.95 if eighth % 2 == 0 else 0.6) * (1.1 if eighth == 0 else 1))
                    low.add(at + beat * BEAT, pluck(root_at(beat) + octave, velocity), gain=0.05, wet=0.1)

        for cue, beat in spec["cues"]:
            # A shorter cut of the scene has fewer of its pictures, so its later cues go too.
            if beat >= beats:
                continue
            t = at + (beat if beat >= 0 else beats + beat) * BEAT
            if cue == "drone":
                fx.add(t, air(beats * BEAT, cutoff=700, form="breath"), gain=0.05, wet=0.5)
                for note in (74, 81):
                    pads.add(t + 2.5, pad(note, beats * BEAT - 4, attack=3.5, release=2.5), gain=0.012, wet=0.8)
            elif cue == "bloom":
                fx.add(t - 1.6, air(1.6, cutoff=1600), gain=0.03, wet=0.6)
                for note, delay in ((74, 0), (78, 0.06), (81, 0.12), (86, 0.18)):
                    keys.add(t + delay, bell(note, 5, 0.8), gain=0.16, pan=(note - 80) / 20, wet=0.65)
                fx.add(t, boom(2.6, 0.8), gain=0.07, wet=0.3)
            elif cue == "swell":
                fx.add(t - 2 * BEAT, air(2 * BEAT, cutoff=1400), gain=0.028, wet=0.6)
            elif cue == "power":
                for note, delay in ((81, 0), (86, 0.11)):
                    keys.add(t + delay, bell(note, 3, 0.45), gain=0.1, pan=0.3, wet=0.6)
            elif cue == "push":
                fx.add(t - 3 * BEAT, riser(3 * BEAT, 300, 5000), gain=0.07, wet=0.4)
                fx.add(t, boom(2.2, 0.6), gain=0.08, wet=0.35)
                fx.add(t, whoosh(0.9, 2000, 400), gain=0.05, wet=0.5)
            elif cue == "whoosh":
                fx.add(t, whoosh(2 * BEAT), gain=0.06, wet=0.5)
            elif cue == "lift":
                fx.add(t, riser(4.75 * BEAT, 220, 2600, curve=1.6), gain=0.05, wet=0.5)
                keys.add(t + 4.75 * BEAT, bell(90, 3, 0.4), gain=0.09, pan=-0.3, wet=0.7)
            elif cue == "window":
                fx.add(t, boom(1.8, 0.5), gain=0.06, wet=0.35)
                keys.add(t, bell(88, 3, 0.5), gain=0.1, pan=0.3, wet=0.6)
            elif cue == "rise":
                keys.add(t, bell(RISE[int(beat) - 1], 4.5, 0.75), gain=0.18, pan=-0.3 + 0.15 * beat, wet=0.55)
            elif cue == "wipe":
                fx.add(t, riser(3.85 * BEAT, 400, 7000, curve=1.4), gain=0.05, wet=0.45)
                for note, delay in ((90, 0), (93, 0.07)):
                    keys.add(t + 3.85 * BEAT + delay, bell(note, 3, 0.4), gain=0.09, pan=0.35, wet=0.7)
            elif cue == "deck":
                keys.add(t, bell(DECK[int((beat - 7) / 2) % len(DECK)], 4, 0.6), gain=0.16, pan=0.25, wet=0.55)
            elif cue == "key":
                n = int(0.05 * SR)
                k = np.arange(n) / SR
                click = rng.standard_normal(n) * np.exp(-k / 0.003) * 0.5 + np.sin(2 * np.pi * 110 * k) * np.exp(-k / 0.018)
                fx.add(t, np.convolve(click, np.ones(5) / 5, mode="same"), gain=0.12, wet=0.15)
            elif cue == "open":
                keys.add(t, bell(88, 3, 0.5), gain=0.12, pan=0.3, wet=0.6)
            elif cue == "drop":
                # The beat stops, a riser has led into it from the bar before, and a low impact lands.
                fx.add(t - 4 * BEAT, riser(4 * BEAT, 200, 6000, curve=2.6), gain=0.08, wet=0.45)
                fx.add(t, boom(4.0, 1.1), gain=0.12, wet=0.4)
                keys.add(t, bell(74, 5, 0.6), gain=0.12, wet=0.7)
            elif cue == "word":
                # A step up from the drop's D, to the A above it.
                fx.add(t, boom(2.0, 0.45), gain=0.05, wet=0.35)
                keys.add(t, bell(81, 4, 0.55), gain=0.12, pan=0.2, wet=0.65)
            elif cue == "icon":
                for note, delay in ((74, 0), (81, 0.08), (85, 0.16), (90, 0.24)):
                    keys.add(t + delay, bell(note, 6, 0.7), gain=0.14, pan=(note - 82) / 20, wet=0.7)
                fx.add(t, boom(3.0, 0.8), gain=0.07, wet=0.4)
        at += beats * BEAT

    # The pads and bass give way a little to each kick, so the beat breathes.
    t = np.arange(samples) / SR
    duck = np.ones(samples)
    for k in kicks:
        start = int(k * SR)
        span = min(samples - start, int(0.45 * SR))
        duck[start : start + span] *= 1 - 0.32 * np.exp(-t[:span] / 0.13)
    for bus in (pads, low):
        bus.dry *= duck[:, None]
        bus.send *= duck[:, None]

    buses = (pads, low, keys, drums, fx)
    dry = sum(bus.dry for bus in buses)
    send = sum(bus.send for bus in buses)
    ir, gain = room or (reverb(), None)
    wet = convolve(send, ir)[: samples]
    n = int(total * SR)
    mix = highpass(lowpass(dry + wet * 0.85, 14000, order=1), 32)[:n]
    # A little air on top: +2.5 dB from about 6 kHz, so the ticks and bells carry on small speakers.
    mix = shape(mix, lambda f: np.sqrt(1 + (10 ** (2.5 / 10) - 1) / (1 + (6000 / np.maximum(f, 1e-3)) ** 2)))
    # Level: about -16 LUFS, quiet enough to sit under a voice or a feed's own sound, with a soft
    # knee above -2 dBFS instead of clipping, and a fade at the very end.
    if gain is None:
        gain = 10 ** ((-15.3 - loudness(mix)) / 20)
    mix *= gain
    knee = 0.79
    over = np.abs(mix) > knee
    mix[over] = np.sign(mix[over]) * (knee + (1 - knee) * np.tanh((np.abs(mix[over]) - knee) / (1 - knee)))
    fade = np.clip((n - np.arange(n)) / (2.2 * SR), 0, 1) ** 1.5
    mix *= fade[:, None]
    if save:
        out = ROOT / "public/film" / f"score-{cut}.wav"
        out.parent.mkdir(parents=True, exist_ok=True)
        write(out, mix)
        print(f"==> {out.relative_to(ROOT)} ({total:.1f} s)")
    return ir, gain


cuts = json.loads((ROOT / "src/introducing/cuts.json").read_text())
for cut in sys.argv[1:] or list(cuts):
    if cut in OPENS_LIKE:
        like = OPENS_LIKE[cut]
        fresh()
        room = score(like, cuts[like], save=False)
        fresh()
        score(cut, cuts[cut], room)
    else:
        score(cut, cuts[cut])
