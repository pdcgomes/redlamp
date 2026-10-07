#!/usr/bin/env python3
"""A person's Subject edge from their person mask (MSK-29).

On DSC02005 the Subject matte leaves almost twice the haze over the dark background that the
People matte does (MSK-25). Vision's Subject mask runs a sliver outside the hair, onto the
background, where its person mask doesn't; the trimap holds that sliver as sure subject and the
solve spreads a haze from it. The candidate: near the edge of the person Subject is, Subject takes
the person's mask, except where it reaches well beyond the person (a skirt in flight, a bag), which
keeps Subject's own edge. Where that person's mask reaches past Subject's (a strand, a hand), the
person's is taken too; other people's never are.

Measured on 7 October 2026 and not shipped. On the five portraits, Subject's trimap made unsure
wherever the person's disagrees with it (`consensus`) took the error around the person's edge from
0.062 to 0.059 and the haze by 8% (DSC02005: 0.081 to 0.065); taking the person's mask outright
(`from_person`) did better there and worse elsewhere. On the evaluation set (`eval`, against a
build of the engine with `consensus` in ClosedFormMatte, since taken out), where the two
masks disagree the person's is often the wrong one, and colour can't tell: Vision's person
instances take birds for people (the ducks lost their heads; only people a detected face or body
confirms should count), and its person masks miss the bright rim of backlit hair, dark hair in a
low-key photo and fur held beside the person, and take in a person's shadow on the wall. Two
photos came out cleaner, four worse.

`masks` makes, with redlamp, each portrait's Subject and People masks as Vision gives them
(REDLAMP_EDGE_MATTE=off) and as the app stores them, in build/subject-person/. `score` solves
each candidate with pymatting (the matting energy of ClosedFormMatte) at 1024 px and scores it as
subject_haze.py does, over the band around the person where ViTMatte's matte (with the widest
trimap) stands for the truth: the mean error, the strands kept, and the haze (the matte's mean
over background the reference says is clear).

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/subject_person.py masks
    research/prototypes/masking/.venv/bin/python research/prototypes/masking/subject_person.py score
"""

import json
import os
import pathlib
import subprocess
import sys

import numpy as np
import pymatting
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from portrait_bench import trimap  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
EDGES = ROOT / "build/edge-cases"
WORK = ROOT / "build/subject-person"
CLI = pathlib.Path(os.environ.get("REDLAMP_CLI", ROOT / "build/DerivedData-masking/Build/Products/Release/redlamp"))
PHOTOS = ["DSC02005", "DSC03301", "DSC02424", "DSC01584", "dancer"]
LONG = 1024
# ClosedFormMatte's bands, as fractions of the long side.
INNER, SUBJECT_INNER, OUTER = 0.006, 0.01, 0.02
# How near a person's edge Subject takes the person's mask; what Subject covers further beyond the
# person is its own.
NEAR = 0.02


def source(name):
    return EDGES / (f"{name}.jpg" if (EDGES / f"{name}.jpg").exists() else f"{name}.png")


def run(*args, env=None):
    result = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True,
                            env={**os.environ, **(env or {})})
    if result.returncode != 0:
        print(f"  redlamp {' '.join(map(str, args[:4]))}: {(result.stderr or result.stdout).strip()[-200:]}")


def masks():
    WORK.mkdir(parents=True, exist_ok=True)
    for name in PHOTOS:
        for kind in ("subject", "people"):
            coarse = WORK / f"{name}-{kind}-coarse.png"
            if not coarse.exists() and not list(WORK.glob(f"{name}-{kind}-coarse-*.png")):
                run("mask", source(name), "--kind", kind, "-o", coarse, env={"REDLAMP_EDGE_MATTE": "off"})
            app = WORK / f"{name}-{kind}-app.png"
            if not app.exists() and not list(WORK.glob(f"{name}-{kind}-app-*.png")):
                run("mask", source(name), "--kind", kind, "-o", app)
        print(f"{name}: masks made", flush=True)


def load(path, size, mode="L"):
    return np.asarray(Image.open(path).convert(mode).resize(size, Image.BILINEAR), np.float64) / 255


def masks_of(name, kind, which, size):
    single = WORK / f"{name}-{kind}-{which}.png"
    paths = [single] if single.exists() else sorted(WORK.glob(f"{name}-{kind}-{which}-*.png"))
    return [load(p, size) for p in paths]


def mask(name, kind, which, size):
    """The mask, several people's combined; None if there is none."""
    found = masks_of(name, kind, which, size)
    return np.max(found, axis=0) if found else None


def subject_person(subject, people):
    """The people Subject is: those it covers over half of (at least the one it covers most)."""
    s = subject > 0.5
    shares = [float((s & (p > 0.5)).sum() / max((p > 0.5).sum(), 1)) for p in people]
    chosen = [p for p, share in zip(people, shares) if share > 0.5] or [people[int(np.argmax(shares))]]
    return np.max(chosen, axis=0)


def from_person(subject, person):
    """Subject's coverage with the person's near the person's edge (see the module's note).

    What Subject covers beyond the person is its own (a skirt in flight, a bag) where it reaches
    further than NEAR from the person, with what joins it to the person; nearer than that it is a
    sliver of background, and the person's edge stands. Returns the coarse mask and Subject's own.
    """
    long = max(subject.shape)
    reach = NEAR * long
    s, p = subject > 0.5, person > 0.5
    beyond = s & ~p
    far = beyond & (ndimage.distance_transform_edt(~p) > reach)
    own = beyond & (ndimage.distance_transform_edt(~far) <= reach) if far.any() else np.zeros_like(beyond)
    edge = ndimage.distance_transform_edt(~p) + ndimage.distance_transform_edt(p)
    near = (edge <= reach) & ~own
    added = p & ~s & ndimage.binary_dilation(s, iterations=round(reach))
    out = subject.copy()
    take = near | added
    out[take] = person[take]
    return out, own


def consensus(subject, person, own):
    """Subject's trimap, unsure wherever the person's disagrees with it, except on Subject's own
    parts beyond the person: sure only where both are sure."""
    s = trimap(subject, inner=SUBJECT_INNER, outer=OUTER)
    p = trimap(person, inner=INNER, outer=OUTER)
    agreed = np.where(s == p, s, 0.5)
    long = max(subject.shape)
    mine = ndimage.distance_transform_edt(~own) <= NEAR * long if own.any() else np.zeros_like(own)
    return np.where(mine, s, agreed)


def solve(image, coarse, inner, near_person=None, tri=None):
    """Closed-form from `coarse`'s trimap (or `tri`); INNER instead of `inner` where `near_person`."""
    if tri is None:
        tri = trimap(coarse, inner=inner, outer=OUTER)
        if near_person is not None:
            tri = np.where(near_person, trimap(coarse, inner=INNER, outer=OUTER), tri)
    return np.clip(pymatting.estimate_alpha_cf(image, tri, laplacian_kwargs={"epsilon": 1e-5}), 0, 1)


def score():
    rows = {}
    for name in PHOTOS:
        full = Image.open(source(name))
        size = (round(full.width * LONG / max(full.size)), round(full.height * LONG / max(full.size)))
        image = load(source(name), size, "RGB")
        subject = mask(name, "subject", "coarse", size)
        people = masks_of(name, "people", "coarse", size)
        truth = load(EDGES / f"{name}-vitmatte-open.png", size)
        if subject is None or not people:
            print(f"{name}: no {'subject' if subject is None else 'person'} mask")
            continue
        person = np.max(people, axis=0)
        theirs = subject_person(subject, people)
        combined, own = from_person(subject, theirs)
        long = max(subject.shape)
        # Scored where the reference can speak for Subject: along the person, away from what
        # Subject covers of its own, which the person's reference counts as background.
        mine = ndimage.distance_transform_edt(~own) <= NEAR * long if own.any() else np.zeros_like(own)
        unknown = (trimap(person, inner=0.012, outer=0.035) == 0.5) & ~mine
        strands = unknown & (person < 0.5) & (truth > 0.1) & (truth < 0.9)
        background = unknown & (truth < 0.02)
        edge = ndimage.distance_transform_edt(theirs <= 0.5) + ndimage.distance_transform_edt(theirs > 0.5)
        candidates = {
            "subject": solve(image, subject, SUBJECT_INNER),
            "people": solve(image, person, INNER),
            "subject-from-person": solve(image, combined, SUBJECT_INNER, near_person=(edge <= NEAR * long) & ~mine),
            "subject-consensus": solve(image, None, None, tri=consensus(subject, theirs, own)),
        }
        for kind in ("subject", "people"):
            app = mask(name, kind, "app", size)
            if app is not None:
                candidates[f"{kind}-app"] = app
        rows[name] = {}
        for label, alpha in candidates.items():
            row = {"error": float(np.abs(alpha - truth)[unknown].mean()),
                   "strands": float((alpha[strands] > 0.1).mean()) if strands.any() else None,
                   "haze": float(alpha[background].mean())}
            rows[name][label] = row
            print(f"{name:9s} {label:20s} error {row['error']:.4f}  strands {row['strands'] or 0:.2f}  "
                  f"haze {row['haze']:.4f}", flush=True)
        Image.fromarray((candidates["subject-from-person"] * 255).round().astype(np.uint8)).save(
            WORK / f"{name}-subject-from-person-cf.png")
        Image.fromarray((own * 255).astype(np.uint8)).save(WORK / f"{name}-subject-own.png")
    print("\nmean")
    labels = sorted({label for r in rows.values() for label in r})
    for label in labels:
        picked = [r[label] for r in rows.values() if label in r]
        print(f"  {label:20s} error {np.mean([p['error'] for p in picked]):.4f}  "
              f"strands {np.mean([p['strands'] or 0 for p in picked]):.2f}  "
              f"haze {np.mean([p['haze'] for p in picked]):.4f}  ({len(picked)} photos)")
    (WORK / "report.json").write_text(json.dumps(rows, indent=1) + "\n")


def union(folder, stem, kind, size):
    """A photo's mask of `kind` in `folder`, several people's combined; None if there is none."""
    single = folder / f"{stem}-{kind}.png"
    paths = [single] if single.exists() else sorted(folder.glob(f"{stem}-{kind}-*.png"))
    return np.max([load(p, size) for p in paths], axis=0) if paths else None


def evaluation_set(kind="subject", folder="eval-person", against="eval-strands-app"):
    """The evaluation set's masks of `kind` from this build (REDLAMP_CLI), in build/mask-bench/
    `folder`, against those in `against` (the strands-only build's by default): how much they
    differ over their edges, and a sheet per cell at 100% where they differ most: the photo, then
    the old matte and the new over mid-grey."""
    import mask_bench as mb

    before = mb.OUT / against
    out = mb.OUT / folder
    (out / "sheets").mkdir(parents=True, exist_ok=True)
    report, rows = {}, {}
    for path, stem, cell, kinds in mb.eval_photos():
        if kind not in kinds or union(before, stem, kind, (8, 8)) is None:
            continue
        target = out / f"{stem}-{kind}.png"
        if union(out, stem, kind, (8, 8)) is None:
            run("mask", path, "--kind", kind, "-o", target)
        made = sorted(out.glob(f"{stem}-{kind}*.png"))
        if not made:
            report[stem] = {"cell": cell, "failed": True}
            continue
        size = Image.open(made[0]).size
        new = union(out, stem, kind, size)
        old = union(before, stem, kind, size)
        edge = ndimage.binary_dilation(((old > 0.02) & (old < 0.98)) | ((new > 0.02) & (new < 0.98)), iterations=2)
        difference = np.abs(new - old)
        report[stem] = {
            "cell": cell, "difference": float(difference[edge].mean()) if edge.any() else 0.0,
            "added": float(((new - old) > 0.25).mean()), "removed": float(((old - new) > 0.25).mean()),
        }
        preview = mb.OUT / "eval" / f"{stem}-photo.jpg"
        photo = np.asarray(Image.open(preview if preview.exists() else path).convert("RGB").resize(size, Image.LANCZOS),
                           np.float32)
        height, width = min(400, size[1]), min(600, size[0])
        summed = ndimage.uniform_filter(difference, size=(height, width), mode="constant")
        y, x = np.unravel_index(np.argmax(summed), summed.shape)
        y0 = int(np.clip(y - height // 2, 0, size[1] - height))
        x0 = int(np.clip(x - width // 2, 0, size[0] - width))
        crop = photo[y0:y0 + height, x0:x0 + width]

        def over_grey(matte):
            a = matte[y0:y0 + height, x0:x0 + width, None]
            return a * crop + (1 - a) * 128

        panels = [crop, over_grey(old), over_grey(new)]
        rows.setdefault(cell, []).append(
            np.concatenate([np.pad(p, ((0, 6), (0, 6), (0, 0)), constant_values=255) for p in panels], axis=1))
        print(f"{stem}: difference {report[stem]['difference']:.3f}, added {report[stem]['added']:.4f}, "
              f"removed {report[stem]['removed']:.4f}", flush=True)
    (out / "report.json").write_text(json.dumps(report, indent=1) + "\n")
    for cell, cell_rows in rows.items():
        width = max(r.shape[1] for r in cell_rows)
        sheet = np.concatenate([np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0)), constant_values=255)
                                for r in cell_rows], axis=0)
        Image.fromarray(sheet.astype(np.uint8)).save(out / "sheets" / f"{cell}.jpg", quality=88)
    made = [r for r in report.values() if "difference" in r]
    changed = [r for r in made if r["difference"] > 0.002]
    print(f"\n{len(made)} {kind} masks, {len(changed)} changed; "
          f"mean added {np.mean([r['added'] for r in made]):.4f}, removed {np.mean([r['removed'] for r in made]):.4f}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "score"
    {"masks": masks, "score": score, "eval": evaluation_set}[command](*sys.argv[2:])
