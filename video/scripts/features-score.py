#!/usr/bin/env python3
"""
A feature video's score (src/features/FeatureVideo.tsx): the series' theme in one of its arrangements
(scripts/features-theme.py), with the episode's own sounds on the frames their pictures land on. The
sounds come from the episode's board (scripts/features/boards/<episode>.py, sounds()), which times them
on the series' cue sheet as it times the picture.

    python3 scripts/features-score.py --episode e01                    # public/features/e01/score.wav
    python3 scripts/features-score.py --episode e01 --arrangement chip

The arrangement is felt until the owner picks one (docs/plans/2026-10-10-feature-videos.md, Sound).
Beside the score it writes score.json, its level at every frame for the storyboard sheet, and
cues.json, the cue sheet with every sound on screen added as a cue, for scripts/score-report.py.
Needs numpy, Pillow and pixelkit (the boards draw with it).
"""

import argparse
import importlib.util
import json
import sys
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


def press(velocity):
    """A mouse button going down and held: the first half of a click."""
    return s.click(velocity)[: int(CLICK_UP * s.SR)]


def release(velocity):
    """The button coming back up: the click's second half."""
    return s.click(velocity)[int(CLICK_UP * s.SR):]


# Each kind of sound on screen: what plays, how loud, and how much of it goes to the room.
SOUNDS = {
    "press": (lambda: press(0.8), 0.16, 0.05),
    "release": (lambda: release(0.8), 0.12, 0.05),
    "tick": (lambda: s.tick(0.6), 0.13, 0.08),
    "key": (lambda: s.key(0.9), 0.3, 0.06),
    "key up": (lambda: s.key(0.8, up=True), 0.24, 0.06),
    "flip": (lambda: s.tick(0.7), 0.16, 0.1),
}


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
    parser.add_argument("--arrangement", default="felt", choices=list(theme.ARRANGEMENTS))
    args = parser.parse_args()
    key = args.episode.lower()
    board = load(w.VIDEO / f"scripts/features/boards/{key}.py", f"board_{key}")
    if not hasattr(board, "sounds"):
        sys.exit(f"{key}'s board has no sounds() yet, so its score can't be written.")
    events = board.sounds()
    unknown = sorted({kind for _, kind, _ in events} - set(SOUNDS))
    if unknown:
        sys.exit(f"{key} has sounds this script can't play: {', '.join(unknown)}")

    buses, mastering = theme.ARRANGEMENTS[args.arrangement](sounds=on_screen(events))
    # The last 1.6 s fade out with the picture, as the last chord dies away.
    mix = s.master(buses, seconds=theme.TOTAL, target=-14.0, ceiling=-1.0, fade=1.6, **mastering)
    out = w.VIDEO / "public/features" / key
    out.mkdir(parents=True, exist_ok=True)
    s.write(out / "score.wav", mix)

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
