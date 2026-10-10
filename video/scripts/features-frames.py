#!/usr/bin/env python3
"""
The feature videos' pictures (src/features/FeatureVideo.tsx): every frame drawn by pixelkit from the
series' cue sheet (src/features/cues.json): first the opener every video starts with (world.opener),
then the episode, by its board, scripts/features/boards/<episode>.py, whose frame(c, beat, hook) draws
any moment of it. A frame is the 216 × 384 canvas in the reel's margin (world.MARGIN), 270 × 480,
which the composition shows four times the size with nearest-neighbour scaling, so the picture keeps
clear of the sides tall phones crop. The glows and fades that cover the whole canvas carry on into the
margin, dithered in step with the canvas. While a real photo is on screen a frame is the whole
1080 × 1920 frame, with the photo through the dither that reveals it (world.render). A picture that
comes out the same as another is written once, and frames.json lists each frame's file for every hook.

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
    """Frame f with `hook`: the image to write (the framed canvas, or the whole frame when a real photo
    is on it) and the kit's warnings."""
    c = w.canvas()
    spread = []
    for name in ("glow", "dissolve"):
        def recorded(*args, _call=getattr(c, name), _name=name, **kwargs):
            if kwargs.get("region") is None:
                spread.append((_name, args, kwargs))
            return _call(*args, **kwargs)
        setattr(c, name, recorded)
    if f < w.OPENER_FRAMES:
        w.opener(c, f, board.EPISODE, board.EPISODE["hooks"][hook], board.FEATURE)
        overlays = []
    else:
        overlays = board.frame(c, (f - w.OPENER_FRAMES) / w.PER_BEAT, hook) or []
    margin = framed(c.img, spread)
    if not overlays:
        return margin, w.check(c)
    whole = margin.resize((margin.width * w.SHOWN, margin.height * w.SHOWN), 0)
    whole.paste(w.render(c, w.SHOWN, overlays), (w.MARGIN[0] * w.SHOWN, w.MARGIN[1] * w.SHOWN))
    return whole, w.check(c)


def framed(image, spread):
    """The canvas in the reel's margin. The glows and fades drawn over the whole canvas (`spread`) are
    drawn again on the margin, whose origin falls on the 4 × 4 ordered dither's grid as the canvas's
    does, so they carry on across the edge."""
    mx, my = w.MARGIN
    pad = -mx % 4
    margin = w.canvas(w.W + 2 * (mx + pad), w.H + 2 * my)
    for name, args, kwargs in spread:
        if name == "glow":
            cx, cy, *rest = args
            margin.glow(cx + mx + pad, cy + my, *rest, **kwargs)
        else:
            getattr(margin, name)(*args, **kwargs)
    out = margin.img.crop((pad, 0, pad + w.FRAME[0], w.FRAME[1]))
    out.paste(image, (mx, my))
    return out


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
            if image.size == w.FRAME:
                image = image.resize((w.FRAME[0] * w.SHOWN, w.FRAME[1] * w.SHOWN), 0)
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
                name = f"{'px' if image.size == w.FRAME else 'hd'}-{digest}.png"
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
