#!/usr/bin/env python3
"""Hair-edge benchmark: a head with stray strands and a beard over real backgrounds, with known
person coverage (the subject-style counterpart of edge_bench.py).

  * backgrounds: crops of the look-development renders, sharp, softly blurred (sigma 6 px) and
    strongly blurred (sigma 20 px, like a portrait lens wide open);
  * the person, drawn at 4x supersampling: shoulders, a head, a hair cap, 600 strands leaving the
    cap (0.4 to 1.6 px wide, 20 to 320 px long, some grey), and a curly beard under the chin;
  * composited in linear light, lens blur and noise as edge_bench.py; the truth is the person's
    coverage, `thin` the strands' and beard's.

A coarse mask stands in for Vision's: the silhouette without strands or beard curls, at 512 px
and blurred, as a matte that knows the head but not the hair poking out of it.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/hair_bench.py generate
    research/prototypes/masking/.venv/bin/python research/prototypes/masking/hair_bench.py score <method>...
"""

import json
import math
import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

import edge_bench as eb

ROOT = pathlib.Path(__file__).resolve().parents[3]
LOOKDEV = ROOT / "build/masking-bakeoff"
WORK = ROOT / "build/hair-bench"
WIDTH, HEIGHT, SUPER = eb.WIDTH, eb.HEIGHT, eb.SUPER
# The standard subject edit: each scene also comes as <scene>-ideal.png, the person brightened by
# this many stops before compositing, which a Subject mask with Exposure EDIT_EV should look like.
EDIT_EV = 1.0


def backgrounds():
    renders = sorted(p for p in LOOKDEV.glob("*.png") if (LOOKDEV / f"{p.stem}-classical.png").exists())
    out = []
    for index, render in enumerate(renders[:6]):
        image = Image.open(render).convert("RGB").resize((WIDTH, HEIGHT), Image.BICUBIC)
        linear = eb.srgb_to_linear(np.asarray(image, dtype=np.float32) / 255)
        blur = [0, 6, 20][index % 3]
        if blur:
            linear = ndimage.gaussian_filter(linear, sigma=(blur, blur, 0))
        out.append((f"{render.stem}-blur{blur}", linear.astype(np.float32)))
    return out


def person(rng, grey):
    solid = Image.new("L", (WIDTH * SUPER, HEIGHT * SUPER), 0)
    hair = Image.new("L", solid.size, 0)
    strands = Image.new("L", solid.size, 0)
    s, h, t = ImageDraw.Draw(solid), ImageDraw.Draw(hair), ImageDraw.Draw(strands)
    cx, cy = WIDTH * rng.uniform(0.42, 0.58), HEIGHT * 0.45
    rx, ry = HEIGHT * 0.17, HEIGHT * 0.23
    S = SUPER
    # Shoulders and head.
    s.ellipse(((cx - HEIGHT * 0.55) * S, (HEIGHT * 0.78) * S, (cx + HEIGHT * 0.55) * S, (HEIGHT * 1.5) * S), fill=255)
    s.rectangle(((cx - rx * 0.45) * S, cy * S, (cx + rx * 0.45) * S, HEIGHT * 0.85 * S), fill=255)
    s.ellipse(((cx - rx) * S, (cy - ry) * S, (cx + rx) * S, (cy + ry) * S), fill=255)
    # The hair cap: the top of the head, a little larger.
    h.pieslice(((cx - rx * 1.06) * S, (cy - ry * 1.08) * S, (cx + rx * 1.06) * S, (cy + ry * 1.0) * S),
               180, 360, fill=255)

    def curve(points, width):
        w = max(1, int(round(width * S)))
        t.line([(x * S, y * S) for x, y in points], fill=255, width=w, joint="curve")

    # Strands leaving the cap outward, curving.
    for _ in range(600):
        angle = rng.uniform(math.pi * 1.02, math.pi * 1.98)
        x = cx + rx * 1.03 * math.cos(angle)
        y = cy + ry * 1.05 * math.sin(angle)
        length = rng.uniform(20, 320)
        direction = angle + rng.normal(0, 0.35)
        bend = rng.normal(0, 0.006)
        points = [(x, y)]
        for _ in range(int(length / 6)):
            direction += bend
            x, y = x + 6 * math.cos(direction), y + 6 * math.sin(direction)
            points.append((x, y))
        curve(points, rng.uniform(0.4, 1.6))
    # A curly beard under the chin.
    chin = (cx, cy + ry * 0.95)
    for _ in range(500):
        x, y = chin[0] + rng.normal(0, rx * 0.35), chin[1] + rng.uniform(-ry * 0.15, ry * 0.12)
        direction = rng.uniform(0, 2 * math.pi)
        points = [(x, y)]
        for _ in range(rng.integers(5, 20)):
            direction += rng.normal(0, 0.9)
            x, y = x + 5 * math.cos(direction), y + 5 * math.sin(direction) + 1.5
            points.append((x, y))
        curve(points, rng.uniform(0.5, 1.4))

    def down(image):
        a = np.asarray(image, dtype=np.float32) / 255
        return a.reshape(HEIGHT, SUPER, WIDTH, SUPER).mean(axis=(1, 3))

    solid, hair, strands = down(solid), down(hair), down(strands)
    coverage = np.clip(solid + hair + strands, 0, 1)
    thin = np.clip(strands * (1 - np.clip(solid + hair, 0, 1)), 0, 1)
    body = np.clip(solid + hair, 0, 1)
    # Colours: skin, shirt, hair (dark, or grey for the older man's).
    hair_colour = np.array([0.18, 0.17, 0.16]) if grey else np.array([0.035, 0.025, 0.02])
    skin = np.array([0.30, 0.18, 0.12])
    shirt = np.array([0.02, 0.02, 0.025])
    yy = np.arange(HEIGHT)[:, None]
    colour = np.where((yy > HEIGHT * 0.8)[..., None], shirt, skin) * np.ones((HEIGHT, WIDTH, 3))
    hair_share = np.clip(hair + strands, 0, 1)[..., None]
    colour = colour * (1 - hair_share) + hair_colour * hair_share
    texture = ndimage.gaussian_filter(rng.standard_normal((HEIGHT // 2, WIDTH // 2)), 1.5)
    texture = np.asarray(Image.fromarray(texture.astype(np.float32)).resize((WIDTH, HEIGHT), Image.BILINEAR))
    colour = colour * np.exp(0.25 * texture)[..., None]
    return coverage, thin, body, colour.astype(np.float32)


def generate():
    WORK.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(31)
    scenes = []
    for index, (name, background) in enumerate(backgrounds()):
        coverage, thin, body, colour = person(rng, grey=index % 2 == 1)
        image = coverage[..., None] * colour + (1 - coverage[..., None]) * background
        image = ndimage.gaussian_filter(image, sigma=(0.8, 0.8, 0))
        ideal = coverage[..., None] * colour * 2**EDIT_EV + (1 - coverage[..., None]) * background
        ideal = ndimage.gaussian_filter(ideal, sigma=(0.8, 0.8, 0))
        truth = ndimage.gaussian_filter(coverage, 0.8)
        thin = ndimage.gaussian_filter(thin, 0.8)
        draw = rng.standard_normal(image.shape).astype(np.float32)
        noise = draw * (0.004 + 0.01 * np.sqrt(np.clip(image, 0, 1)))
        scene = f"hair-{name}"
        Image.fromarray((eb.linear_to_srgb(image + noise) * 255 + 0.5).astype(np.uint8)).save(WORK / f"{scene}.png")
        ideal_noise = draw * (0.004 + 0.01 * np.sqrt(np.clip(ideal, 0, 1)))
        Image.fromarray((eb.linear_to_srgb(ideal + ideal_noise) * 255 + 0.5).astype(np.uint8)).save(
            WORK / f"{scene}-ideal.png",
        )
        np.savez_compressed(WORK / f"{scene}-truth.npz", sky=truth.astype(np.float16), thin=thin.astype(np.float16))
        coarse = Image.fromarray((body * 255).astype(np.uint8)).resize((512, 342), Image.BOX)
        coarse = coarse.resize((WIDTH, HEIGHT), Image.BILINEAR)
        coarse = ndimage.gaussian_filter(np.asarray(coarse, np.float32), 6)
        Image.fromarray(coarse.astype(np.uint8)).save(WORK / f"{scene}-coarse.png")
        scenes.append(scene)
        print(f"{scene}: person {truth.mean():.3f}, thin {(thin > 0.3).mean():.4f}")
    (WORK / "scenes.json").write_text(json.dumps(scenes, indent=2))


def score(methods):
    """edge_bench's scores on the background's coverage (one minus the person's), so thin recall
    is the share of strands kept in the person and leak the share of solid person lost."""
    scenes = json.loads((WORK / "scenes.json").read_text())
    for method in methods:
        rows = []
        for scene in scenes:
            path = WORK / f"{scene}-{method}.png"
            if not path.exists():
                continue
            truth = np.load(WORK / f"{scene}-truth.npz")
            mask = eb.load(path)
            person = truth["sky"].astype(np.float32)
            row = eb.score_mask(1 - mask, 1 - person, truth["thin"].astype(np.float32))
            row["falsePerson"] = float((mask[person < 0.02] > 0.5).mean())
            rows.append(row)
        if not rows:
            print(f"{method}: no masks")
            continue
        mean = lambda key: float(np.mean([r[key] for r in rows if r[key] is not None]))
        print(f"{method:28s} n={len(rows):2d}  band MAE {mean('bandMAE'):.3f}  thin MAE {mean('thinMAE'):.3f}"
              f"  strands kept {mean('thinRecall'):.3f}  person lost {mean('leak'):.4f}"
              f"  background as person {mean('falsePerson'):.4f}  IoU {mean('iou'):.3f}")


def matte():
    import sky_matte
    for scene in json.loads((WORK / "scenes.json").read_text()):
        image = np.asarray(Image.open(WORK / f"{scene}.png").convert("RGB"), np.float32) / 255
        coarse = np.asarray(Image.open(WORK / f"{scene}-coarse.png").convert("L"), np.float32) / 255
        out = sky_matte.refine_subject(image, coarse)
        Image.fromarray((out * 255 + 0.5).astype(np.uint8)).save(WORK / f"{scene}-coarse+matte.png")


if __name__ == "__main__":
    if sys.argv[1:2] == ["generate"]:
        generate()
    elif sys.argv[1:2] == ["score"]:
        score(sys.argv[2:])
    elif sys.argv[1:2] == ["matte"]:
        matte()
    else:
        sys.exit(__doc__)
