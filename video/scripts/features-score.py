#!/usr/bin/env python3
"""
A feature video's score (src/features/FeatureVideo.tsx): the series' theme in one of its arrangements
(scripts/features-theme.py), with the episode's own sounds on the frames their pictures land on. The
sounds come from the episode's board (scripts/features/boards/<episode>.py, sounds()), which times them
on the series' cue sheet as it times the picture.

    python3 scripts/features-score.py --episode e01                     # public/features/e01/score.wav
    python3 scripts/features-score.py --episode e01 --arrangement pulse

It writes every arrangement as score-<arrangement>.wav, so they can be compared against the picture
(the composition's `score` prop), and the chosen one as score.wav, which the cut plays: drive until
the owner picks (docs/plans/2026-10-10-feature-videos.md, Sound). Beside them it writes score.json,
the chosen score's level at every frame for the storyboard sheet, and cues.json, the cue sheet with
every sound on screen added as a cue, for scripts/score-report.py. It also writes the opener's sound,
public/features/opener.wav, which every video shares. Needs numpy, Pillow and pixelkit (the boards
draw with it).
"""

import argparse
import importlib.util
import json
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import synth as s  # noqa: E402
from features import world as w  # noqa: E402


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


theme = load(w.VIDEO / "scripts/features-theme.py", "features_theme")
CLICK_UP = 0.07
# The whole video's loudness, as the platforms measure it, in LUFS.
TARGET = -14.0


def press(velocity):
    """A mouse button going down and held: the first half of a click."""
    return s.click(velocity)[: int(CLICK_UP * s.SR)]


def release(velocity):
    """The button coming back up: the click's second half."""
    return s.click(velocity)[int(CLICK_UP * s.SR):]


# Each kind of sound on screen: what plays, how loud, and how much of it goes to the room.
SOUNDS = {
    "press": (lambda: press(0.8), 0.2, 0.05),
    "release": (lambda: release(0.8), 0.15, 0.05),
    "tick": (lambda: s.tick(0.6), 0.16, 0.08),
    "key": (lambda: s.key(0.9), 0.36, 0.06),
    "key up": (lambda: s.key(0.8, up=True), 0.28, 0.06),
    "flip": (lambda: s.tick(0.7), 0.2, 0.1),
}


def read(path):
    with wave.open(str(path)) as f:
        return np.frombuffer(f.readframes(f.getnframes()), "<i2").reshape(-1, f.getnchannels()) / 32768


def opener(episode):
    """
    The opener's sound: the Introducing short's score under its opening scene (scripts/score.py short),
    which the pixel opener is timed to frame for frame, as far below the episode's score as it sits
    below the rest of the short, and faded out over its last three frames, where the episode's first
    hit cuts in. Its length is the cue sheet's opener, which has to be the short's opening scene.
    """
    short = w.VIDEO / "public/film/score-short.wav"
    if not short.exists():
        subprocess.run([sys.executable, "scripts/score.py", "short"], cwd=w.VIDEO, check=True)
    cuts = json.loads((w.VIDEO / "src/introducing/cuts.json").read_text())
    scene, bars = cuts["short"][0]
    assert (scene, bars) == ("safelight", w.OPENER["bars"]), f"the short opens on {bars} bars of {scene}, not the opener's"
    seconds = w.OPENER_FRAMES / w.FPS
    x = read(short)
    n = int(round(seconds * s.SR))
    head, after = x[:n], x[n:n + len(episode)]
    gap = s.loudness(after) - s.loudness(head)
    out = head * 10 ** ((s.loudness(episode) - gap - s.loudness(head)) / 20)
    ramp = int(round(3 / w.FPS * s.SR))
    out[-ramp:] *= np.linspace(1, 0, ramp)[:, None]
    return out


def on_screen(events):
    """Puts the episode's sounds, (beat, kind, pan), on an arrangement's effects bus."""

    def sounds(fx):
        for beat, kind, pan in events:
            sound, gain, wet = SOUNDS[kind]
            fx.add(theme.at(beat), sound(), gain=gain, pan_to=pan, wet=wet)

    return sounds


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--episode", required=True)
    parser.add_argument("--arrangement", default="drive", choices=list(theme.ARRANGEMENTS))
    args = parser.parse_args()
    key = args.episode.lower()
    board = load(w.VIDEO / f"scripts/features/boards/{key}.py", f"board_{key}")
    if not hasattr(board, "sounds"):
        sys.exit(f"{key}'s board has no sounds() yet, so its score can't be written.")
    events = board.sounds()
    unknown = sorted({kind for _, kind, _ in events} - set(SOUNDS))
    if unknown:
        sys.exit(f"{key} has sounds this script can't play: {', '.join(unknown)}")

    out = w.VIDEO / "public/features" / key
    out.mkdir(parents=True, exist_ok=True)
    for name, arrange in theme.ARRANGEMENTS.items():
        buses, mastering = arrange(sounds=on_screen(events))
        # The last 1.6 s fade out with the picture, as the last chord dies away. What's mastered to the
        # target is the whole video, opener and all; the opener is the quieter, so the score sits a
        # little above the target.
        target = TARGET
        for _ in range(2):
            each = s.master(buses, seconds=theme.TOTAL, target=target, ceiling=-1.0, fade=1.6, **mastering)
            target += TARGET - s.loudness(np.concatenate([opener(each), each]))
        s.write(out / f"score-{name}.wav", each)
        print(f"    score-{name}.wav: {s.loudness(each):.1f} LUFS, true peak {s.true_peak(each):.1f} dBFS")
        if name == args.arrangement:
            mix = each
    s.write(out / "score.wav", mix)
    head = opener(mix)
    s.write(w.VIDEO / "public/features/opener.wav", head)
    whole = np.concatenate([head, mix])
    print(f"    opener.wav: {len(head) / s.SR:.2f} s; with the score, {s.loudness(whole):.1f} LUFS, "
          f"true peak {s.true_peak(whole):.1f} dBFS")

    per = s.SR // w.FPS
    frames = len(mix) // per
    rms = np.sqrt((mix[: frames * per] ** 2).mean(axis=1).reshape(frames, per).mean(axis=1))
    (out / "score.json").write_text(json.dumps({"fps": w.FPS, "arrangement": args.arrangement,
                                                "level": [round(float(x), 4) for x in rms / rms.max()]}))
    counts = {}
    cues = dict(w.CUE)
    for beat, kind, _ in events:
        counts[kind] = counts.get(kind, 0) + 1
        cues[f"{kind.replace(' ', '-')}-{counts[kind]}"] = beat
    (out / "cues.json").write_text(json.dumps({**w.SHEET, "cues": cues}, indent=1))
    print(f"==> public/features/{key}/score.wav ({args.arrangement}, {theme.TOTAL:.1f} s, {s.loudness(mix):.1f} LUFS, "
          f"true peak {s.true_peak(mix):.1f} dBFS, {len(events)} sounds on screen)")


if __name__ == "__main__":
    main()
