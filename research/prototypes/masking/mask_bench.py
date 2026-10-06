"""The mask benchmark (MSK-25): what Redlamp draws and how an edit through a mask looks, scored.

    .venv/bin/python mask_bench.py run [--sets edge,hair] [--cli <redlamp>]
    .venv/bin/python mask_bench.py score [--sets edge,hair]
    .venv/bin/python mask_bench.py eval      today's masks for the evaluation set (`mise run maskeval`)
    .venv/bin/python mask_bench.py sheets    a contact sheet per cell, whole and at 100% where the edge is busiest
    .venv/bin/python mask_bench.py eval      today's masks for the evaluation set (`mise run maskeval`)
    .venv/bin/python mask_bench.py sheets    a contact sheet per cell, whole and at 100% where the edge is busiest

Exact-coverage scenes (`edge_bench.py generate`, `hair_bench.py generate`): skies behind bare and
leafy trees, wires and skylines, and heads with stray strands and beards, each with its true
coverage and <scene>-ideal.png, the scene edited before compositing (sky -1.5 EV, person +1 EV).

  * coverage: the mask Redlamp makes today (`redlamp mask`; for the heads, which Vision doesn't
    take for people, the bench's closed-form matte) and what the renderer draws of it
    (`redlamp render --coverage`), scored as edge_bench.py does: band error, thin-structure error
    and recall, leak;
  * halo: the scene edited through its mask (`--mask-set local.exposure=...`) against the ideal
    scene, both developed by redlamp: mean CIELAB difference over the edge band, and the signed
    lightness difference on the side the edit shouldn't reach (a light rim is positive). Edited
    once through the stored mask and once through the true coverage, so the matte's share of the
    halo and the way the edit is applied (MSK-27) show apart. Both are developed from linear DNGs
    of the scenes: Redlamp develops a bitmap as display-referred (it opens looking as it was, and
    Exposure isn't a gain on its pixels), so a PNG's mix of sky and branch in linear light isn't a
    mix in Redlamp's scene space, where a raw's is.

Everything is written to build/mask-bench/<set>/, and `score` writes report.json beside them.
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import edge_bench as eb  # noqa: E402
import hair_bench as hb  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / "build/mask-bench"
CLI = ROOT / "build/DerivedData-masking/Build/Products/Release/redlamp"
SETS = {
    "edge": {"work": eb.WORK, "kind": "sky", "ev": eb.EDIT_EV, "masked": "sky"},
    "hair": {"work": hb.WORK, "kind": "subject", "ev": hb.EDIT_EV, "masked": "person"},
}


def linear(path):
    rgb = cv2.imread(str(path))[..., ::-1].astype(np.float32) / 255
    return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)


def write_dng(path, rgb):
    """A linear DNG whose camera RGB is linear sRGB, balanced for D65."""
    import tifffile

    xyz_to_srgb = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
    srational = [v for x in xyz_to_srgb for v in (int(round(x * 10000)), 10000)]
    tifffile.imwrite(
        path, np.round(np.clip(rgb, 0, 1) * 65535).astype(np.uint16), photometric=34892, planarconfig="contig",
        metadata=None, extratags=[
            (254, 4, 1, 0, True), (271, "s", 0, "Redlamp", True), (272, "s", 0, "Mask bench", True),
            (50706, 1, 4, (1, 4, 0, 0), True), (50707, 1, 4, (1, 1, 0, 0), True),
            (50708, "s", 0, "Redlamp Mask bench", True), (50717, 4, 3, (65535, 65535, 65535), True),
            (50721, 10, 9, srational, True), (50778, 3, 1, 21, True), (50728, 5, 3, (1, 1, 1, 1, 1, 1), True),
        ],
    )


def redlamp(cli, *args):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"redlamp {' '.join(map(str, args))}: {result.stderr.strip() or result.stdout.strip()}")


def run(names, cli):
    for name in names:
        spec = SETS[name]
        out = OUT / name
        out.mkdir(parents=True, exist_ok=True)
        for scene in json.loads((spec["work"] / "scenes.json").read_text()):
            image, ideal = spec["work"] / f"{scene}.png", spec["work"] / f"{scene}-ideal.png"
            stored, oracle = out / f"{scene}-stored.png", out / f"{scene}-oracle.png"
            if not stored.exists():
                if name == "edge":
                    redlamp(cli, "mask", image, "--kind", "sky", "-o", stored)
                else:
                    shutil.copy(spec["work"] / f"{scene}-cf.png", stored)
            truth = np.load(spec["work"] / f"{scene}-truth.npz")["sky"].astype(np.float32)
            Image.fromarray(np.round(np.clip(truth, 0, 1) * 255).astype(np.uint8)).save(oracle)
            raw, ideal_raw = out / f"{scene}.dng", out / f"{scene}-ideal.dng"
            if not raw.exists():
                write_dng(raw, linear(image))
                write_dng(ideal_raw, linear(ideal))
            kind, ev = spec["kind"], f"local.exposure={spec['ev']}"
            redlamp(cli, "render", image, "--mask-bitmap", f"{kind}={stored}", "--coverage", "-o", out / f"{scene}-drawn.png")
            redlamp(cli, "render", raw, "--mask-bitmap", f"{kind}={stored}", "--mask-set", ev, "--16bit", "-o", out / f"{scene}-edit.png")
            redlamp(cli, "render", raw, "--mask-bitmap", f"{kind}={oracle}", "--mask-set", ev, "--16bit", "-o", out / f"{scene}-oracle-edit.png")
            redlamp(cli, "render", ideal_raw, "--16bit", "-o", out / f"{scene}-ideal-render.png")
            print(f"{name}/{scene}: done")


def lab(path):
    """CIELAB (D65) of an sRGB PNG, 8 or 16 bits."""
    bgr = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    rgb = bgr[..., :3][..., ::-1].astype(np.float32) / (65535 if bgr.dtype == np.uint16 else 255)
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    xyz = linear @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    xyz /= np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def halo(edit, ideal, truth):
    """Over the edge band (where the truth is mixed, and 16 px around it): the mean CIELAB
    difference, and the signed lightness difference on the side the edit shouldn't reach; with the
    difference deep inside the masked area, which should be nought, as a check."""
    a, b = lab(edit), lab(ideal)
    mixed = (truth > 0.02) & (truth < 0.98)
    band = ndimage.binary_dilation(mixed, iterations=16)
    outside = band & (truth < 0.5)
    deep = (truth > 0.999) & ~ndimage.binary_dilation(band, iterations=32)
    difference = np.linalg.norm(a - b, axis=-1)
    return {
        "haloDE": float(difference[band].mean()),
        "rimL": float((a[..., 0] - b[..., 0])[outside].mean()),
        "deepDE": float(difference[deep].mean()) if deep.any() else None,
    }


def score(names):
    report = json.loads((OUT / "report.json").read_text()) if (OUT / "report.json").exists() else {}
    for name in names:
        spec = SETS[name]
        out = OUT / name
        rows = []
        for scene in json.loads((spec["work"] / "scenes.json").read_text()):
            if not (out / f"{scene}-ideal-render.png").exists():
                continue
            t = np.load(spec["work"] / f"{scene}-truth.npz")
            truth, thin = t["sky"].astype(np.float32), t["thin"].astype(np.float32)
            row = {"scene": scene}
            for what in ("stored", "drawn"):
                mask = eb.load(out / f"{scene}-{what}.png")
                if name == "hair":
                    scores = eb.score_mask(1 - mask, 1 - truth, thin)
                else:
                    scores = eb.score_mask(mask, truth, thin)
                row[what] = {k: scores[k] for k in ("bandMAE", "thinMAE", "thinRecall", "leak")}
            ideal = out / f"{scene}-ideal-render.png"
            row["halo"] = halo(out / f"{scene}-edit.png", ideal, truth)
            row["oracleHalo"] = halo(out / f"{scene}-oracle-edit.png", ideal, truth)
            rows.append(row)
        report[name] = rows

        def mean(path):
            values = [r for r in (pick(row, path) for row in rows) if r is not None]
            return float(np.mean(values)) if values else float("nan")

        print(f"{name} ({len(rows)} scenes, {spec['masked']} edited by {spec['ev']:+.1f} EV)")
        print(f"  drawn coverage: band error {mean('drawn.bandMAE'):.3f}, thin error {mean('drawn.thinMAE'):.3f}, "
              f"thin recall {mean('drawn.thinRecall'):.3f}, leak {mean('drawn.leak'):.4f}")
        for label, key in (("stored mask", "halo"), ("true coverage", "oracleHalo")):
            print(f"  halo through the {label}: ΔE {mean(key + '.haloDE'):.2f} over the edge band, "
                  f"rim ΔL* {mean(key + '.rimL'):+.2f} outside the mask, deep ΔE {mean(key + '.deepDE'):.2f}")
    (OUT / "report.json").write_text(json.dumps(report, indent=1))


EVAL = ROOT / "research/mask-eval/manifest.json"
EVAL_KINDS = ("sky", "subject", "people")


def eval_photos():
    """(path, file stem, cell, masks it tests) for the evaluation set and the look-development raws it names."""
    manifest = json.loads(EVAL.read_text())
    photos = [(ROOT / "build/mask-eval" / i["file"], pathlib.Path(i["file"]).stem, i["cell"], i["masks"])
              for i in manifest["images"]]
    photos += [(ROOT / "build/look-dev" / i["file"], pathlib.Path(i["file"]).stem, "look-dev", i["masks"])
               for i in manifest["lookDev"]]
    return [p for p in photos if p[0].exists()]


def eval_masks(cli):
    """Today's masks for each photo of the evaluation set, for the masks its cell tests."""
    out = OUT / "eval"
    out.mkdir(parents=True, exist_ok=True)
    failures = {}
    for path, stem, cell, masks in eval_photos():
        for kind in (k for k in EVAL_KINDS if k in masks):
            target = out / f"{stem}-{kind}.png"
            if target.exists() or list(out.glob(f"{stem}-{kind}-*.png")):
                continue
            try:
                redlamp(cli, "mask", path, "--kind", kind, "-o", target)
            except RuntimeError as error:
                failures[f"{stem} {kind}"] = str(error).splitlines()[-1][-160:]
        print(f"eval/{stem}: done")
    (out / "failures.json").write_text(json.dumps(failures, indent=1))
    print(f"{len(failures)} masks not made: {out / 'failures.json'}")


def eval_mask(stem, kind, size):
    """A photo's mask of `kind` at `size` (several people's combined), or None."""
    out = OUT / "eval"
    paths = [out / f"{stem}-{kind}.png"] if (out / f"{stem}-{kind}.png").exists() else sorted(out.glob(f"{stem}-{kind}-*.png"))
    if not paths:
        return None
    masks = [np.asarray(Image.open(p).convert("L").resize(size, Image.BILINEAR), np.float32) / 255 for p in paths]
    return np.max(masks, axis=0)


def eval_sheets():
    """A sheet per cell: each photo whole with its mask in the app's red overlay, and at 100% where
    its edge is busiest (the 320 px window with the most partly covered pixels)."""
    from PIL import ImageOps

    sheets = OUT / "eval" / "sheets"
    sheets.mkdir(parents=True, exist_ok=True)
    by_cell = {}
    for path, stem, cell, masks in eval_photos():
        by_cell.setdefault(cell, []).append((path, stem, masks))
    red = np.array([0.95, 0.18, 0.18], np.float32)
    for cell, photos in by_cell.items():
        rows = []
        for path, stem, masks in photos:
            photo_image = ImageOps.exif_transpose(Image.open(path)).convert("RGB") if path.suffix.lower() in (".jpg", ".jpeg", ".png") else None
            if photo_image is None:
                rendered = OUT / "eval" / f"{stem}-photo.jpg"
                if not rendered.exists():
                    redlamp(CLI, "render", path, "-o", rendered)
                photo_image = Image.open(rendered).convert("RGB")
            photo = np.asarray(photo_image, np.float32) / 255
            for kind in (k for k in EVAL_KINDS if k in masks):
                mask = eval_mask(stem, kind, photo_image.size)
                if mask is None:
                    continue
                shown = photo * (1 - 0.55 * mask[..., None]) + red * 0.55 * mask[..., None]
                partial = ((mask > 0.05) & (mask < 0.95)).astype(np.float32)
                density = ndimage.uniform_filter(partial, 320)
                y, x = np.unravel_index(np.argmax(density[160:-160, 160:-160]), density[160:-160, 160:-160].shape)
                whole = Image.fromarray((np.clip(shown, 0, 1) * 255).astype(np.uint8))
                whole.thumbnail((480, 480))
                crop = Image.fromarray((np.clip(shown[y : y + 320, x : x + 320], 0, 1) * 255).astype(np.uint8))
                plain = Image.fromarray((np.clip(photo[y : y + 320, x : x + 320], 0, 1) * 255).astype(np.uint8))
                rows.append((f"{stem} · {kind}", whole, plain, crop))
        if not rows:
            continue
        width = 480 + 4 + 320 + 4 + 320
        height = sum(max(r[1].height, 320) + 20 for r in rows)
        sheet = Image.new("RGB", (width, height), (22, 22, 22))
        draw = ImageDraw.Draw(sheet)
        top = 0
        for label, whole, plain, crop in rows:
            draw.text((3, top + 3), f"{label}   (whole, then 100%: the photo and the mask)", fill=(230, 230, 230))
            sheet.paste(whole, (0, top + 18))
            sheet.paste(plain, (484, top + 18))
            sheet.paste(crop, (808, top + 18))
            top += max(whole.height, 320) + 20
        sheet.save(sheets / f"{cell}.jpg", quality=88)
        print(f"sheet: {sheets / (cell + '.jpg')}")


EVAL = ROOT / "research/mask-eval/manifest.json"
EVAL_KINDS = ("sky", "subject", "people")


def eval_photos():
    """(path, file stem, cell, masks it tests) for the evaluation set and the look-development raws it names."""
    manifest = json.loads(EVAL.read_text())
    photos = [(ROOT / "build/mask-eval" / i["file"], pathlib.Path(i["file"]).stem, i["cell"], i["masks"])
              for i in manifest["images"]]
    photos += [(ROOT / "build/look-dev" / i["file"], pathlib.Path(i["file"]).stem, "look-dev", i["masks"])
               for i in manifest["lookDev"]]
    return [p for p in photos if p[0].exists()]


def eval_masks(cli):
    """Today's masks for each photo of the evaluation set, for the masks its cell tests."""
    out = OUT / "eval"
    out.mkdir(parents=True, exist_ok=True)
    failures = {}
    for path, stem, cell, masks in eval_photos():
        for kind in (k for k in EVAL_KINDS if k in masks):
            target = out / f"{stem}-{kind}.png"
            if target.exists() or list(out.glob(f"{stem}-{kind}-*.png")):
                continue
            try:
                redlamp(cli, "mask", path, "--kind", kind, "-o", target)
            except RuntimeError as error:
                failures[f"{stem} {kind}"] = str(error).splitlines()[-1][-160:]
        print(f"eval/{stem}: done")
    (out / "failures.json").write_text(json.dumps(failures, indent=1))
    print(f"{len(failures)} masks not made: {out / 'failures.json'}")


def eval_mask(stem, kind, size):
    """A photo's mask of `kind` at `size` (several people's combined), or None."""
    out = OUT / "eval"
    paths = [out / f"{stem}-{kind}.png"] if (out / f"{stem}-{kind}.png").exists() else sorted(out.glob(f"{stem}-{kind}-*.png"))
    if not paths:
        return None
    masks = [np.asarray(Image.open(p).convert("L").resize(size, Image.BILINEAR), np.float32) / 255 for p in paths]
    return np.max(masks, axis=0)


def eval_sheets():
    """A sheet per cell: each photo whole with its mask in the app's red overlay, and at 100% where
    its edge is busiest (the 320 px window with the most partly covered pixels)."""
    from PIL import ImageOps

    sheets = OUT / "eval" / "sheets"
    sheets.mkdir(parents=True, exist_ok=True)
    by_cell = {}
    for path, stem, cell, masks in eval_photos():
        by_cell.setdefault(cell, []).append((path, stem, masks))
    red = np.array([0.95, 0.18, 0.18], np.float32)
    for cell, photos in by_cell.items():
        rows = []
        for path, stem, masks in photos:
            photo_image = ImageOps.exif_transpose(Image.open(path)).convert("RGB") if path.suffix.lower() in (".jpg", ".jpeg", ".png") else None
            if photo_image is None:
                rendered = OUT / "eval" / f"{stem}-photo.jpg"
                if not rendered.exists():
                    redlamp(CLI, "render", path, "-o", rendered)
                photo_image = Image.open(rendered).convert("RGB")
            photo = np.asarray(photo_image, np.float32) / 255
            for kind in (k for k in EVAL_KINDS if k in masks):
                mask = eval_mask(stem, kind, photo_image.size)
                if mask is None:
                    continue
                shown = photo * (1 - 0.55 * mask[..., None]) + red * 0.55 * mask[..., None]
                partial = ((mask > 0.05) & (mask < 0.95)).astype(np.float32)
                density = ndimage.uniform_filter(partial, 320)
                y, x = np.unravel_index(np.argmax(density[160:-160, 160:-160]), density[160:-160, 160:-160].shape)
                whole = Image.fromarray((np.clip(shown, 0, 1) * 255).astype(np.uint8))
                whole.thumbnail((480, 480))
                crop = Image.fromarray((np.clip(shown[y : y + 320, x : x + 320], 0, 1) * 255).astype(np.uint8))
                plain = Image.fromarray((np.clip(photo[y : y + 320, x : x + 320], 0, 1) * 255).astype(np.uint8))
                rows.append((f"{stem} · {kind}", whole, plain, crop))
        if not rows:
            continue
        width = 480 + 4 + 320 + 4 + 320
        height = sum(max(r[1].height, 320) + 20 for r in rows)
        sheet = Image.new("RGB", (width, height), (22, 22, 22))
        draw = ImageDraw.Draw(sheet)
        top = 0
        for label, whole, plain, crop in rows:
            draw.text((3, top + 3), f"{label}   (whole, then 100%: the photo and the mask)", fill=(230, 230, 230))
            sheet.paste(whole, (0, top + 18))
            sheet.paste(plain, (484, top + 18))
            sheet.paste(crop, (808, top + 18))
            top += max(whole.height, 320) + 20
        sheet.save(sheets / f"{cell}.jpg", quality=88)
        print(f"sheet: {sheets / (cell + '.jpg')}")


def pick(row, path):
    for key in path.split("."):
        row = row.get(key) if isinstance(row, dict) else None
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "score", "eval", "sheets"])
    parser.add_argument("--sets", default="edge,hair")
    parser.add_argument("--cli", default=str(CLI))
    args = parser.parse_args()
    names = args.sets.split(",")
    if args.command == "eval":
        eval_masks(pathlib.Path(args.cli))
    elif args.command == "sheets":
        eval_sheets()
    else:
        if args.command == "run":
            run(names, pathlib.Path(args.cli))
        score(names)


if __name__ == "__main__":
    main()
