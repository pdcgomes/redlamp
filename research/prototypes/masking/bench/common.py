"""Paths, the pool, and masks at the bench's size, for the mask bench's tools (MSK-38).

A source names whose masks to read: `<contender>` (its latest run), `<contender>@<run>`, `lightroom`
(the latest version decoded) or `lightroom@<version>`. Every mask is a single-channel 8-bit PNG
the size of the photo's bench JPEG (2048 px on the long side, as the photo is displayed).
"""

import datetime
import json
import os
import pathlib
import subprocess

import cv2
import numpy as np
from PIL import Image, ImageOps

ROOT = pathlib.Path(__file__).resolve().parents[4]
EVAL = ROOT / "research/mask-eval"
MANIFEST = EVAL / "manifest.json"
CONTENDERS = EVAL / "contenders.json"
QUICK = EVAL / "quick.json"
ACCEPTED = EVAL / "accepted.json"
VERDICTS = EVAL / "verdicts.jsonl"
REFERENCES = EVAL / "references.jsonl"
WORK = ROOT / "build/mask-bench"
RUNS = WORK / "runs"
LIGHTROOM = WORK / "lightroom"
PHOTOS = WORK / "photos"
REFS = WORK / "references"
SCORES = WORK / "scores"
DERIVED = ROOT / "build/DerivedData-maskbench"
CLI = pathlib.Path(os.environ.get("REDLAMP_CLI", DERIVED / "Build/Products/Release/redlamp"))
SIZE = 2048
KINDS = ("subject", "sky", "background")
BITMAP_SUFFIXES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".webp"}


def pool():
    """Every photo in the pool, in the manifest's order: its ID, file, cell, conditions, the masks it
    was chosen for, and whether it's a raw."""
    manifest = json.loads(MANIFEST.read_text())
    photos = []
    for image in manifest["images"]:
        photos.append({
            "id": pathlib.Path(image["file"]).stem,
            "path": ROOT / "build/mask-eval" / image["file"],
            "cell": image["cell"],
            "conditions": image.get("conditions", []),
            "masks": image.get("masks", []),
            "raw": pathlib.Path(image["file"]).suffix.lower() not in BITMAP_SUFFIXES,
            "longEdge": max(image.get("width", 0), image.get("height", 0)),
        })
    for image in manifest.get("lookDev", []):
        photos.append({
            "id": pathlib.Path(image["file"]).stem,
            "path": ROOT / "build/look-dev" / image["file"],
            "cell": "look-dev",
            "conditions": image.get("conditions", []),
            "masks": image.get("masks", []),
            "raw": pathlib.Path(image["file"]).suffix.lower() not in BITMAP_SUFFIXES,
        })
    return photos


def select(which):
    """Photos by name: `all`, `quick` (research/mask-eval/quick.json), a cell (`cell:sky-sunset`), or
    IDs separated by commas."""
    photos = pool()
    if which == "all":
        return photos
    if which == "quick":
        ids = set(json.loads(QUICK.read_text())["photos"])
        return [p for p in photos if p["id"] in ids]
    if which.startswith("cell:"):
        return [p for p in photos if p["cell"] == which[5:]]
    ids = set(which.split(","))
    return [p for p in photos if p["id"] in ids]


def photo(photo_id):
    return next(p for p in pool() if p["id"] == photo_id)


def bench_size(width, height):
    scale = SIZE / max(width, height)
    return max(1, round(width * scale)), max(1, round(height * scale))


def bench_jpeg(entry):
    """The photo at the bench's size as displayed (EXIF orientation applied); a raw as Redlamp's
    default develop. Made once, in build/mask-bench/photos."""
    path = PHOTOS / f"{entry['id']}.jpg"
    if path.exists():
        return path
    PHOTOS.mkdir(parents=True, exist_ok=True)
    if entry["raw"]:
        subprocess.run([str(CLI), "render", str(entry["path"]), "-o", str(path), "--size", str(SIZE)],
                       check=True, capture_output=True)
    else:
        with Image.open(entry["path"]) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            image = image.resize(bench_size(*image.size), Image.LANCZOS)
            image.save(path, quality=92)
    return path


def size_of(entry):
    """The photo's size at the bench, from its bench JPEG."""
    with Image.open(bench_jpeg(entry)) as image:
        return image.size


def read_mask(path, size):
    """A mask PNG as coverage from 0 to 1 at `size` (width, height). A mask whose sides are swapped
    relative to `size` is an error: masks are kept as the photo is displayed."""
    mask = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if mask is None:
        raise FileNotFoundError(path)
    if mask.ndim == 3:
        mask = mask[..., 0] if mask.shape[2] in (1, 2) else cv2.cvtColor(mask[..., :3], cv2.COLOR_BGR2GRAY)
    scale = 65535.0 if mask.dtype == np.uint16 else 255.0
    mask = mask.astype(np.float32) / scale
    height, width = mask.shape
    if (width > height) != (size[0] > size[1]) and width != height and size[0] != size[1]:
        raise ValueError(f"{path.name} is {width}x{height}, the photo {size[0]}x{size[1]}")
    if (width, height) != tuple(size):
        shrinking = width > size[0]
        mask = cv2.resize(mask, tuple(size), interpolation=cv2.INTER_AREA if shrinking else cv2.INTER_LINEAR)
    return np.clip(mask, 0, 1)


def write_mask(path, mask):
    path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), np.clip(mask * 255 + 0.5, 0, 255).astype(np.uint8))


def commit():
    """HEAD's short hash, with `+dirty` when the app's or packages' sources have changes."""
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout
    dirty = subprocess.run(["git", "status", "--porcelain", "--", "apps", "packages"], cwd=ROOT,
                           capture_output=True, text=True).stdout.strip()
    return head.strip() + ("+dirty" if dirty else "")


def now():
    return datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds")


def contenders():
    return {c["id"]: c for c in json.loads(CONTENDERS.read_text())["contenders"]}


def runs_of(contender, checks=False):
    """The runs holding `contender`'s masks, oldest first by when they were made; `maskbench check`'s
    own runs (named `…-check`) only when `checks`."""
    if not RUNS.exists():
        return []

    def made(run):
        path = run / "run.json"
        return json.loads(path.read_text()).get("created", "") if path.exists() else ""

    runs = [run for run in RUNS.iterdir() if (run / contender).is_dir() and (checks or not run.name.endswith("-check"))]
    return [run.name for run in sorted(runs, key=lambda run: (made(run), run.name))]


def lightroom_versions():
    if not LIGHTROOM.exists():
        return []
    return sorted(v.name for v in LIGHTROOM.iterdir() if (v / "version.json").exists())


def resolve(source):
    """The folder holding a source's masks (`<folder>/<kind>/<photo>.png`), and the source's full name."""
    name, _, pinned = source.partition("@")
    if name == "lightroom":
        versions = lightroom_versions()
        version = pinned or (versions[-1] if versions else None)
        if not version:
            raise SystemExit("no Lightroom masks decoded yet (maskbench lightroom decode)")
        return LIGHTROOM / version, f"lightroom@{version}"
    runs = runs_of(name)
    run = pinned or (runs[-1] if runs else None)
    if not run or not (RUNS / run / name).is_dir():
        raise SystemExit(f"no run of {name}{'@' + pinned if pinned else ''} (maskbench run --contenders {name})")
    return RUNS / run / name, f"{name}@{run}"


def mask_path(folder, kind, photo_id):
    return folder / kind / f"{photo_id}.png"


def unknown_path(folder, kind, photo_id):
    """Pixels the source couldn't say anything about (Lightroom's, where an export was too dark or clipped)."""
    return folder / kind / f"{photo_id}.unknown.png"
