"""
The promo studio's synthesiser: instruments, sound effects and a mastering chain for scores written
in code, with numpy and nothing sampled, so every score is free to use on any platform.

A score script imports what it needs, adds sounds into Buses at times in seconds, and calls
master() once. Every random sound draws from `rng`, seeded by reset(), so a score renders the same
every time. Sounds are mono arrays (Bus.add pans them) unless they say they're stereo.

    from synth import Bus, kick, master, reset, write
    reset(7)
    drums = Bus(seconds=16)
    drums.add(0.0, kick(1.0))
    write("out.wav", master([drums]))

scripts/score.py (Introducing Redlamp) predates this library and keeps its own copies, so its
published score can't change.
"""

import wave

import numpy as np

SR = 48000
rng = np.random.default_rng(7)


def reset(seed=7):
    """Starts the random sounds over, as at the start of a run."""
    global rng
    rng = np.random.default_rng(seed)


def hz(midi):
    return 440.0 * 2 ** ((np.asarray(midi, dtype=float) - 69) / 12)


def times(seconds):
    return np.arange(int(round(seconds * SR))) / SR


# ---------------------------------------------------------------- filters


def shape(x, gain_of):
    """Filters a whole signal in the frequency domain by a magnitude curve of frequency."""
    spectrum = np.fft.rfft(x, axis=0)
    gain = gain_of(np.maximum(np.fft.rfftfreq(x.shape[0], 1 / SR), 1e-3))
    return np.fft.irfft(spectrum * (gain[:, None] if x.ndim == 2 else gain), n=x.shape[0], axis=0)


def lowpass(x, cutoff, order=2):
    """A Butterworth-shaped low-pass."""
    return shape(x, lambda f: 1 / np.sqrt(1 + (f / cutoff) ** (2 * order)))


def highpass(x, cutoff, order=2):
    return shape(x, lambda f: 1 / np.sqrt(1 + (cutoff / f) ** (2 * order)))


def bandpass(x, centre, octaves=1.0):
    """A band `octaves` wide (to its half-power points) round `centre`."""
    return shape(x, lambda f: np.exp(-0.5 * (np.log2(f / centre) / (octaves / 2.355)) ** 2))


def shelf(x, corner, db):
    """A high shelf from about `corner` Hz: `db` above it."""
    return shape(x, lambda f: np.sqrt(1 + (10 ** (db / 10) - 1) / (1 + (corner / f) ** 2)))


def sweep(x, start, end, width=0.9, curve=1.0):
    """A band of `x` whose centre glides from `start` to `end` Hz across the signal (an STFT)."""
    size, hop = 2048, 512
    window = np.hanning(size)
    padded = np.concatenate([x, np.zeros(size)])
    out = np.zeros_like(padded)
    norm = np.zeros_like(padded)
    freqs = np.maximum(np.fft.rfftfreq(size, 1 / SR), 1)
    for at in range(0, len(x), hop):
        k = (at / max(1, len(x))) ** curve
        centre = start * (end / start) ** k
        gain = np.exp(-0.5 * (np.log2(freqs / centre) / width) ** 2)
        frame = np.fft.irfft(np.fft.rfft(padded[at : at + size] * window) * gain, size)
        out[at : at + size] += frame * window
        norm[at : at + size] += window**2
    return out[: len(x)] / np.maximum(norm[: len(x)], 1e-3)


# ---------------------------------------------------------------- oscillators


def phase_of(freq, n, start=None):
    """Phase in cycles for a frequency that may change every sample."""
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    begin = rng.uniform(0, 1) if start is None else start
    return begin + np.cumsum(f) / SR


def harmonics(freq, n, partials, cutoff=None, order=2, limit=16000, start=None):
    """
    Additive synthesis: partials k with amplitudes amp(k), through a low-pass whose cutoff may
    change every sample, so filter envelopes cost nothing extra. `freq` may change every sample.
    """
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    phase = 2 * np.pi * phase_of(f, n, start)
    top = float(np.max(f))
    out = np.zeros(n)
    for k, amp in partials:
        if k * top > limit:
            break
        gain = amp
        if cutoff is not None:
            gain = amp / np.sqrt(1 + (k * f / np.maximum(cutoff, 20)) ** (2 * order))
        out += gain * np.sin(k * phase)
    return out


SAW = [(k, 1 / k) for k in range(1, 64)]
SQUARE = [(k, 1 / k) for k in range(1, 64, 2)]
# A pulse a quarter of a cycle wide: brighter than a square, with its even harmonics.
PULSE = [(k, abs(np.sin(np.pi * k / 4)) / k) for k in range(1, 64)]


def blep_saw(freq, n, start=None):
    """A band-limited sawtooth (polyBLEP), for long and many-voiced notes."""
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,)) / SR
    t = phase_of(f * SR, n, start) % 1.0
    out = 2 * t - 1
    low = t < f
    x = t[low] / f[low]
    out[low] -= x + x - x * x - 1
    high = t > 1 - f
    x = (t[high] - 1) / f[high]
    out[high] -= x * x + x + x + 1
    return out


def envelope(n, attack=0.005, decay=0.2, sustain=0.0, release=0.05, hold=None):
    """Attack to 1, decay to `sustain`, held until `hold` seconds, then released."""
    t = np.arange(n) / SR
    hold = n / SR - release if hold is None else hold
    rise = np.clip(t / max(attack, 1e-4), 0, 1)
    level = sustain + (1 - sustain) * np.exp(-np.maximum(t - attack, 0) / max(decay, 1e-4))
    fall = np.clip(1 - (t - hold) / max(release, 1e-4), 0, 1)
    return rise * level * fall


def pan(signal, position):
    """Mono to stereo, at -1 (left) to 1 (right), constant power; `position` may change every sample."""
    p = np.broadcast_to(np.asarray(position, dtype=float), signal.shape)
    return np.stack([signal * np.cos((p + 1) * np.pi / 4), signal * np.sin((p + 1) * np.pi / 4)], axis=1)


def saturate(x, drive=1.5):
    return np.tanh(x * drive) / np.tanh(drive)


# ---------------------------------------------------------------- drums


def kick(velocity=1.0, length=0.42, punch=1.0, click=1.0):
    """A dance kick: a sine falling from about 190 Hz to 50 Hz, a click on top, saturated."""
    t = times(length)
    pitch = 50 + 140 * np.exp(-t / (0.03 * punch)) + 40 * np.exp(-t / 0.004)
    body = np.sin(2 * np.pi * np.cumsum(pitch) / SR) * np.exp(-t / 0.28) * np.clip((length - t) / 0.05, 0, 1)
    snap = highpass(rng.standard_normal(len(t)) * np.exp(-t / 0.0025), 1800) * 0.35 * click
    return saturate(body + snap, 1.8) * velocity


def snare(velocity=1.0, tone=185.0, length=0.24, snap=1.0):
    """A tuned body and a band of noise; `tone` rises through a build."""
    t = times(length)
    body = np.sin(2 * np.pi * tone * t) * np.exp(-t / 0.05) + 0.45 * np.sin(2 * np.pi * tone * 1.63 * t) * np.exp(-t / 0.03)
    noise = bandpass(rng.standard_normal(len(t)), 4200, octaves=2.4) * np.exp(-t / 0.085) * 1.6 * snap
    attack = highpass(rng.standard_normal(len(t)) * np.exp(-t / 0.002), 3000) * 0.6
    return saturate((0.55 * body + noise + attack) * np.clip(t / 0.0008, 0, 1), 1.4) * velocity


def clap(velocity=1.0):
    """Three quick bursts and a short tail, band-passed, with a little body."""
    t = times(0.4)
    noise = rng.standard_normal(len(t))
    bursts = sum(np.where(t >= o, np.exp(-(t - o) / 0.006), 0) for o in (0, 0.0095, 0.0195))
    tail = np.exp(-t / 0.1) * 0.45
    crack = highpass(lowpass(noise * (bursts + tail), 6000), 900)
    return (crack * 0.6 + 0.25 * np.sin(2 * np.pi * 200 * t) * np.exp(-t / 0.03)) * velocity


def hat(velocity=1.0, open=False):
    t = times(0.32 if open else 0.06)
    noise = highpass(rng.standard_normal(len(t)), 7200, order=3)
    return noise * np.exp(-t / (0.11 if open else 0.014)) * np.clip(t / 0.0006, 0, 1) * velocity


def crash(velocity=1.0, length=2.4):
    """Bright noise with a ring of metal in it, stereo."""
    t = times(length)
    out = np.zeros((len(t), 2))
    for c in range(2):
        noise = highpass(rng.standard_normal(len(t)), 3800, order=2) * np.exp(-t / 0.75)
        ring = sum(np.sin(2 * np.pi * f * t + rng.uniform(0, 6.3)) * np.exp(-t / d) for f, d in ((523, 0.9), (797, 0.7), (1143, 0.5), (1672, 0.35)))
        out[:, c] = (noise + 0.04 * ring) * np.clip(t / 0.002, 0, 1)
    return out * velocity * 0.5


# ---------------------------------------------------------------- tuned


def pluck(note, velocity=1.0, length=0.3, bright=1.0, partials=SAW):
    """A short synth pluck: a filter that snaps shut, from bright to dark in about 80 ms."""
    t = times(length)
    cutoff = 300 + 5200 * bright * velocity * np.exp(-t / 0.07)
    tone = harmonics(hz(note), len(t), partials, cutoff=cutoff)
    return tone * envelope(len(t), 0.002, 0.16, 0.0, 0.03) * velocity * 0.5


def bass(note, velocity=1.0, length=0.24, bright=1.0):
    """The groove's bass: a saw with a quick filter, over a sine an octave down."""
    t = times(length)
    cutoff = 180 + 2100 * bright * np.exp(-t / 0.05)
    tone = harmonics(hz(note), len(t), SAW, cutoff=cutoff, order=3) + 0.6 * np.sin(2 * np.pi * phase_of(hz(note - 12), len(t)))
    return saturate(tone * envelope(len(t), 0.003, 0.18, 0.35, 0.03) * velocity, 1.3) * 0.6


def sub(note, seconds, velocity=1.0):
    t = times(seconds)
    return np.sin(2 * np.pi * phase_of(hz(note), len(t))) * envelope(len(t), 0.01, 10, 1.0, 0.08) * velocity


def lead(note, length, velocity=1.0, vibrato=True):
    """A bright, playful lead: a narrow pulse whose filter opens on each note, with a late vibrato."""
    t = times(length + 0.12)
    f = hz(note) * np.ones(len(t))
    if vibrato:
        f = f * 2 ** (0.12 * np.clip((t - 0.12) / 0.15, 0, 1) * np.sin(2 * np.pi * 5.6 * t) / 12)
    cutoff = 1400 + 5200 * velocity * np.exp(-t / 0.12)
    tone = harmonics(f, len(t), PULSE, cutoff=cutoff)
    return tone * envelope(len(t), 0.004, 0.18, 0.62, 0.1, hold=length) * velocity * 0.45


def supersaw(notes, seconds, voices=7, spread=22, cutoff=4200, attack=0.02, release=0.25):
    """A wide pad of detuned saws for each note, stereo."""
    n = int(round((seconds + release) * SR))
    out = np.zeros((n, 2))
    for note in notes:
        for v in range(voices):
            cents = spread * (2 * v / max(1, voices - 1) - 1)
            voice = blep_saw(hz(note) * 2 ** (cents / 1200), n)
            out += pan(voice, 0.8 * (2 * v / max(1, voices - 1) - 1))
    out = lowpass(out, cutoff, order=2) / (voices * max(1, len(notes)) ** 0.5)
    return out * envelope(n, attack, 10, 1.0, release, hold=seconds)[:, None]


def stab(notes, velocity=1.0, length=0.5, cutoff=6000):
    """A chord hit: the supersaw, short, with its filter closing."""
    pad = supersaw(notes, length, voices=5, spread=18, cutoff=cutoff, attack=0.002, release=0.12)
    t = np.arange(len(pad)) / SR
    return pad * (np.exp(-t / 0.16) * velocity)[:, None]


def bell(note, seconds=3.0, velocity=1.0):
    """Glass: a few inharmonic partials with long, separate decays."""
    t = times(seconds)
    out = np.zeros(len(t))
    for ratio, amp, tau in ((1, 1, 2.0), (2.0, 0.28, 1.3), (2.76, 0.2, 0.9), (4.07, 0.08, 0.5), (5.4, 0.04, 0.35)):
        out += amp * np.sin(2 * np.pi * hz(note) * ratio * t + rng.uniform(0, 6.3)) * np.exp(-t / tau)
    return out * np.clip(t / 0.002, 0, 1) * velocity * 0.3


# ---------------------------------------------------------------- effects


def riser(seconds, start=300, end=8000, curve=2.0):
    """Noise whose band climbs and swells into the moment it leads to, stereo."""
    n = int(round(seconds * SR))
    swell = np.linspace(0, 1, n) ** curve
    return np.stack([sweep(rng.standard_normal(n), start, end, curve=0.8) * swell for _ in range(2)], axis=1)


def whoosh(seconds, start=400, peak=2600):
    """Air rising and settling, for something that moves past the camera."""
    n = int(round(seconds * SR))
    shaped = np.sin(np.pi * np.linspace(0, 1, n) ** 0.7) ** 2
    return sweep(rng.standard_normal(n), start, peak, width=1.1) * shaped


def inhale(seconds):
    """A breath drawn in: noise that swells, darkening as it comes, stopped dead."""
    t = times(seconds)
    noise = lowpass(rng.standard_normal(len(t)), 2600)
    return noise[::-1] * (np.exp(-t / (seconds * 0.35)))[::-1] * np.clip((seconds - t) / 0.004, 0, 1)


def boom(seconds=2.0, depth=1.0):
    """A low impact: a sine falling from about 70 Hz under a dark breath of noise."""
    t = times(seconds)
    pitch = 34 + 40 * np.exp(-t / 0.12)
    body = np.sin(2 * np.pi * np.cumsum(pitch) / SR) * np.exp(-t / (0.7 * depth))
    breath = lowpass(rng.standard_normal(len(t)), 900) * np.exp(-t / 0.3) * 0.3
    return saturate((body + breath) * np.clip(t / 0.003, 0, 1), 1.2)


def hum(pitch, level):
    """
    A charging hum: a buzzy tone whose pitch (MIDI, per sample) and level (per sample) follow a
    curve, like a capacitor whining as it fills.
    """
    n = len(pitch)
    f = hz(pitch)
    tone = harmonics(f, n, SAW[:14], cutoff=2600) + 0.5 * np.sin(2 * np.pi * phase_of(f / 2, n))
    return tone * level


def zap(seconds=0.5, start=2600, end=260):
    """A shot of light: a falling chirp with a ring of FM on it, over a band of hiss."""
    t = times(seconds)
    f = start * (end / start) ** (t / seconds) ** 0.6
    mod = np.sin(2 * np.pi * phase_of(f * 1.5, len(t))) * 2.5 * np.exp(-t / 0.15)
    chirp = np.sin(2 * np.pi * phase_of(f, len(t)) + mod)
    hiss = sweep(rng.standard_normal(len(t)), 6000, 1500, width=1.2) * 0.5
    return (chirp * 0.7 + hiss) * np.exp(-t / (seconds * 0.7)) * np.clip(t / 0.003, 0, 1)


def boing(seconds=1.0, freq=300, wobble=8.0, depth=0.22):
    """A spring: a tone whose pitch wobbles and settles."""
    t = times(seconds)
    f = freq * (1 + depth * np.exp(-t / (seconds * 0.35)) * np.sin(2 * np.pi * wobble * t))
    return np.sin(2 * np.pi * phase_of(f, len(t))) * np.exp(-t / (seconds * 0.4)) * np.clip(t / 0.004, 0, 1)


def slide(seconds, start=1800, end=700):
    """A slide whistle: a pure tone gliding, with a flutter."""
    t = times(seconds)
    f = start * (end / start) ** (t / seconds) * (1 + 0.012 * np.sin(2 * np.pi * 14 * t))
    return np.sin(2 * np.pi * phase_of(f, len(t))) * np.sin(np.pi * np.clip(t / seconds, 0, 1)) ** 0.5


def knock(velocity=1.0):
    """Wood: a few damped modes over a low thump, as a block on a rope pulling taut."""
    t = times(0.2)
    modes = sum(a * np.sin(2 * np.pi * f * t) * np.exp(-t / d) for f, a, d in ((540, 1, 0.035), (1190, 0.55, 0.018), (2130, 0.3, 0.01)))
    thump = np.sin(2 * np.pi * 110 * t) * np.exp(-t / 0.05) * 0.6
    return (modes + thump) * np.clip(t / 0.0005, 0, 1) * velocity * 0.6


def creak(seconds=0.5, pitch=900):
    """A rope's creak: a train of friction grains through a resonance, rising and falling."""
    n = int(round(seconds * SR))
    t = np.arange(n) / SR
    train = np.zeros(n)
    at = 0.0
    while at < seconds:
        i = int(at * SR)
        train[i : i + 24] += rng.standard_normal(min(24, n - i)) * np.exp(-np.arange(min(24, n - i)) / 6)
        at += 1 / rng.uniform(70, 140)
    swell = np.sin(np.pi * t / seconds) ** 1.5
    return bandpass(train, pitch, octaves=0.35) * swell * 2.5


def click(velocity=1.0):
    """A mouse button: down, and up 70 ms later."""
    t = times(0.12)
    out = np.zeros(len(t))
    for at, a in ((0, 1.0), (0.07, 0.55)):
        s = t - at
        on = s >= 0
        out[on] += a * (np.sin(2 * np.pi * 2600 * s[on]) * np.exp(-s[on] / 0.004) + highpass(rng.standard_normal(on.sum()), 2500) * np.exp(-s[on] / 0.0015))
    return out * velocity * 0.5


def tick(velocity=1.0):
    t = times(0.03)
    return np.sin(2 * np.pi * 3900 * t) * np.exp(-t / 0.004) * velocity


def crackle(seconds, density, level):
    """Sparks of static: tiny bright grains at `density(t)` a second and `level(t)` loud, stereo."""
    n = int(round(seconds * SR))
    out = np.zeros((n, 2))
    at = 0.0
    while at < seconds:
        d = max(density(at), 1e-3)
        i = int(at * SR)
        size = min(int(0.003 * SR), n - i)
        grain = rng.standard_normal(size) * np.exp(-np.arange(size) / (0.0006 * SR))
        p = rng.uniform(-0.8, 0.8)
        out[i : i + size] += pan(grain * level(at) * rng.uniform(0.3, 1), p)
        at += rng.exponential(1 / d)
    return highpass(out, 2800)


# ---------------------------------------------------------------- mixing


class Bus:
    """A stereo buffer that sounds are added into, with a send to the reverb."""

    def __init__(self, seconds):
        n = int(round(seconds * SR))
        self.dry = np.zeros((n, 2))
        self.send = np.zeros((n, 2))

    def add(self, at, signal, gain=1.0, pan_to=0.0, wet=0.2):
        signal = pan(signal, pan_to) if signal.ndim == 1 else signal
        start = int(round(at * SR))
        if start < 0:
            signal = signal[-start:]
            start = 0
        end = min(start + len(signal), len(self.dry))
        if end <= start:
            return
        part = signal[: end - start] * gain
        self.dry[start:end] += part * (1 - wet * 0.5)
        self.send[start:end] += part * wet

    def duck(self, gain):
        """Multiplies the bus by a gain curve, as a sidechain does."""
        self.dry *= gain[:, None]
        self.send *= gain[:, None]


def sidechain(seconds, hits, depth=0.6, release=0.16):
    """A gain curve that dips by `depth` at each hit and recovers over `release` seconds: the pump."""
    n = int(round(seconds * SR))
    gain = np.ones(n)
    t = np.arange(int(release * 4 * SR)) / SR
    curve = 1 - depth * np.exp(-t / (release / 2.2))
    for hit in hits:
        i = int(round(hit * SR))
        span = min(len(curve), n - i)
        if span > 0:
            gain[i : i + span] = np.minimum(gain[i : i + span], curve[:span])
    return gain


def reverb(seconds=2.4, decay=0.45, predelay=0.018):
    """A synthetic room: decorrelated noise in each ear, decaying, darker as it goes."""
    t = times(seconds)
    early = rng.standard_normal((len(t), 2)) * np.exp(-t / decay)[:, None]
    dark = lowpass(early, 3200)
    blend = np.clip(t / 0.8, 0, 1)[:, None]
    ir = early * (1 - blend) * 0.5 + dark * (0.5 + 0.5 * blend)
    ir = np.vstack([np.zeros((int(predelay * SR), 2)), ir])
    return ir / np.sqrt((ir**2).sum(axis=0))


def convolve(x, ir):
    size = 1 << int(np.ceil(np.log2(len(x) + len(ir))))
    out = np.empty((len(x) + len(ir) - 1, 2))
    for c in range(2):
        out[:, c] = np.fft.irfft(np.fft.rfft(x[:, c], size) * np.fft.rfft(ir[:, c], size), size)[: out.shape[0]]
    return out


# BS.1770's K-weighting at 48 kHz: its high shelf, then its high-pass, as biquads.
K_SHELF = ([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585])
K_HIGHPASS = ([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])


def biquad_gain(f, b, a):
    z = np.exp(-2j * np.pi * f / SR)
    return np.abs((b[0] + b[1] * z + b[2] * z**2) / (a[0] + a[1] * z + a[2] * z**2))


def loudness(x):
    """
    Integrated loudness in LUFS, as ITU-R BS.1770-4 measures it (and ffmpeg's ebur128): K-weighted,
    in 400 ms blocks every 100 ms, gated at -70 LUFS and then 10 LU under the blocks' mean. The
    filters are applied by their exact magnitude, which leaves the energy in each block as is.
    """
    weighted = shape(x, lambda f: biquad_gain(f, *K_SHELF) * biquad_gain(f, *K_HIGHPASS))
    size, hop = int(0.4 * SR), int(0.1 * SR)
    power = (weighted**2).sum(axis=1)
    sums = np.concatenate([[0], np.cumsum(power)])
    starts = np.arange(0, len(power) - size + 1, hop)
    blocks = (sums[starts + size] - sums[starts]) / size
    levels = -0.691 + 10 * np.log10(np.maximum(blocks, 1e-12))
    loud = blocks[levels > -70]
    gate = -0.691 + 10 * np.log10(loud.mean()) - 10
    kept = blocks[(levels > -70) & (levels > gate)]
    return -0.691 + 10 * np.log10(kept.mean())


def true_peak(x):
    """The peak of the signal upsampled four times, in dBFS: what a player's converter will see."""
    n = len(x)
    spectrum = np.fft.rfft(x, axis=0)
    padded = np.zeros((4 * n // 2 + 1, x.shape[1]), dtype=complex)
    padded[: spectrum.shape[0]] = spectrum
    up = np.fft.irfft(padded, n=4 * n, axis=0) * 4
    return 20 * np.log10(np.max(np.abs(up)) + 1e-12)


def master(buses, seconds=None, target=-14.0, ceiling=-1.0, room=None, wet=0.8, fade=0.03):
    """
    Sums the buses and their reverb, cleans the lows, adds a little air, levels the mix to `target`
    LUFS and keeps its true peak under `ceiling` dBFS with a soft knee. Returns the stereo mix,
    `seconds` long, with a short fade at the very end so a loop doesn't click.
    """
    dry = sum(bus.dry for bus in buses)
    send = sum(bus.send for bus in buses)
    n = len(dry) if seconds is None else int(round(seconds * SR))
    wet_signal = convolve(send, room if room is not None else reverb())[: len(dry)]
    mix = highpass(dry + wet_signal * wet, 32, order=2)[:n]
    mix = shelf(mix, 7000, 2.0)
    # Limiting takes loudness away, so level, limit and measure again until it settles. Peaks between
    # samples run higher than the samples, so the limit sits under the ceiling by what they overshoot.
    gain = 10 ** ((target - loudness(mix)) / 20)
    under = 0.5
    for _ in range(4):
        limit = 10 ** ((ceiling - under) / 20)
        for _ in range(8):
            out = soft_limit(mix * gain, limit)
            miss = target - loudness(out)
            if abs(miss) < 0.1:
                break
            gain *= 10 ** (miss / 20)
        peak = true_peak(out)
        if peak <= ceiling:
            break
        under += peak - ceiling + 0.05
    ramp = int(fade * SR)
    out[-ramp:] *= np.linspace(1, 0, ramp)[:, None]
    return out


def soft_limit(x, limit, knee=0.8):
    """Leaves everything under `knee` of the limit alone and bends what's over it in under the limit."""
    out = x.copy()
    k = limit * knee
    over = np.abs(out) > k
    out[over] = np.sign(out[over]) * (k + (limit - k) * np.tanh((np.abs(out[over]) - k) / (limit - k)))
    return out


def write(path, x):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())
