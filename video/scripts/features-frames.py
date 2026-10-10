#!/usr/bin/env python3
"""
The feature videos' pictures (src/features/FeatureVideo.tsx): every frame drawn by pixelkit from the
series' cue sheet (src/features/cues.json): first the opener every video starts with (world.opener),
then the episode, by its board, scripts/features/boards/<episode>.py, whose frame(c, beat, hook) draws
any moment of it. A frame is the 216 × 384 canvas, which the
composition shows five times the size with nearest-neighbour scaling; while a real photo is on screen it
is the whole 1080 × 1920 frame, with the photo at full resolution through the dither that reveals it
(world.render). A picture that comes out the same as another is written once, and frames.json lists
each frame's file for every hook.

    python3 scripts/features-frames.py --episode e01              # public/features/e01/frames/, every hook
    python3 scripts/features-frames.py --episode e01 --hook a     # one hook
    python3 scripts/features-frames.py --episode e01 --only 0,560 # these frames at 1080 × 1920, in /tmp/features-frames/

Frames are numbered from the opener's first. The hook is on screen in the opener and the episode's first
bar, so the other hooks' frames are drawn up to the first step's cue and share the rest. Needs Pillow and numpy, and pixelkit at $PIXELKIT or ~/src/pixelartvisuals.
Warnings from the kit's checks and the safe zones are printed once each; fix them all.
"""

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from features import world as w  # noqa: E402

BOARDS = w.VIDEO / "scripts/features/boards"


def load(key):
    path = BOARDS / f"{key}.py"
    spec = importlib.util.spec_from_file_location(f"board_{key}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def draw(board, f, hook):
    """Frame f with `hook`: the image to write (the canvas, or the whole frame when a real photo is on
    it) and the kit's warnings."""
    c = w.canvas()
    if f < w.OPENER_FRAMES:
        w.opener(c, f, board.EPISODE, board.EPISODE["hooks"][hook], board.FEATURE)
        overlays = []
    else:
        overlays = board.frame(c, (f - w.OPENER_FRAMES) / w.PER_BEAT, hook) or []
    image = w.render(c, w.SCALE, overlays) if overlays else c.img
    return image, w.check(c)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--episode", required=True, help="an episode with a frame() in its board, such as e01")
    parser.add_argument("--hook", help="one hook (default: every hook in docs/social/posts.json)")
    parser.add_argument("--only", help="comma-separated frames, written at 1080 × 1920 to /tmp/features-frames/")
    args = parser.parse_args()
    key = args.episode.lower()
    board = load(key)
    if not hasattr(board, "frame"):
        sys.exit(f"{key}'s board has no frame(c, beat, hook) yet, so it can't be animated.")
    hooks = [args.hook] if args.hook else list(board.EPISODE["hooks"])
    warnings = {}

    if args.only:
        out = Path("/tmp/features-frames") / key
        out.mkdir(parents=True, exist_ok=True)
        for f in (int(x) for x in args.only.split(",")):
            image, notes = draw(board, f, hooks[0])
            if image.size != (w.W * w.SCALE, w.H * w.SCALE):
                image = image.resize((w.W * w.SCALE, w.H * w.SCALE), 0)
            print(f"wrote {w.save(image, out / f'{f:04d}.png')}")
            warnings.update(dict.fromkeys(notes))
    else:
        folder = w.VIDEO / "public/features" / key
        frames_dir = folder / "frames"
        frames_dir.mkdir(parents=True, exist_ok=True)
        manifest_path = folder / "frames.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() and args.hook else {"frames": {}}
        total = w.OPENER_FRAMES + w.FRAMES
        opening = w.OPENER_FRAMES + round(w.CUE["step1"] * w.PER_BEAT)
        written = {}
        for i, hook in enumerate(hooks):
            names = []
            for f in range(total):
                if i > 0 and f >= opening:
                    names.append(manifest["frames"][hooks[0]][f])
                    continue
                image, notes = draw(board, f, hook)
                warnings.update(dict.fromkeys(notes))
                a = np.asarray(image)
                digest = hashlib.sha1(a.tobytes() + str(a.shape).encode()).hexdigest()[:12]
                name = f"{'px' if image.size == (w.W, w.H) else 'hd'}-{digest}.png"
                if name not in written:
                    if name.startswith("px"):
                        w.save(image, frames_dir / name)
                    else:
                        image.save(frames_dir / name, compress_level=6)
                    written[name] = True
                names.append(name)
            manifest["frames"][hook] = names
        manifest.update({"episode": key, "fps": w.FPS, "opener": w.OPENER_FRAMES, "frames": manifest["frames"],
                         "standIn": bool(getattr(board, "STANDING_IN", False))})
        manifest_path.write_text(json.dumps(manifest))
        used = {n for names in manifest["frames"].values() for n in names}
        for stale in frames_dir.glob("*.png"):
            if stale.name not in used:
                stale.unlink()
        print(f"==> public/features/{key}/frames/: {len(used)} pictures for {total} frames (the opener's {w.OPENER_FRAMES} "
              f"and the episode's {w.FRAMES}), hooks {', '.join(manifest['frames'])}")
    for note in warnings:
        print(f"{key}: warning: {note}")


if __name__ == "__main__":
    main()
