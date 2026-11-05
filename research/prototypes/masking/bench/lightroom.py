"""Lightroom desktop's masks for the bench (MSK-38), decoded from its exports.

Lightroom gives back rendered photos, not masks, so each mask is measured through one fixed edit:
Exposure −2.00 inside it and nothing else. Each photo is exported five ways, by preset: Baseline
(no edit), Global (Exposure −2.00 on the whole photo), and Select Subject, Select Sky and Select
Background with Exposure −2.00 inside the mask. In linear light, where a pixel's masked export lies
between its baseline and its global export says how much the mask covers it:

* blend: Lightroom mixes the edited and unedited results by the mask's coverage, so coverage is
  (baseline − masked) / (baseline − global), whatever its tone curve does;
* scale: Lightroom scales the slider by the coverage, so coverage is
  log(masked / baseline) / log(global / baseline), exact while the curve is close to a power.

The calibration says which: a grey card painted with a brush at Density 50 (coverage 0.5) and
Exposure −2.00, exported as `brush`, against its baseline and global exports. Channels too dark or
too clipped to change by the edit say nothing; a pixel where none does is marked unknown.

    maskbench lightroom prepare     the import folders, the grey card and the inbox folders
    maskbench lightroom calibrate   blend or scale, from the grey card's three exports
    maskbench lightroom decode      every export in the inbox, into lightroom/<version>/<kind>/
    maskbench lightroom selftest    decodes simulated exports of both kinds, to check the decoding

Exports are matched to photos by their file names (Lightroom's "original file name"); a photo's
exports are deleted once all its kinds are decoded. Decoded masks stay on this Mac: only numbers
and verdicts enter the repository (DEC-17, DEC-41).
"""

import json
import pathlib
import re
import subprocess
import sys

import cv2
import numpy as np

import common as c

PRESETS = ("baseline", "global") + c.KINDS
CALIBRATION_PHOTOS = ("sky-bare-trees-01", "sky-overcast-01", "hair-busy-background-01", "pets-01", "groups-01",
                      "Canon_Canon-PowerShot-S3IS")
CARD = "grey-card"
CARD_LEVELS = (0.05, 0.18, 0.45, 0.8)
EXPOSURE = -2.0
MIN_CHANGE = 0.01


def to_linear(encoded):
    return np.where(encoded <= 0.04045, encoded / 12.92, ((encoded + 0.055) / 1.055) ** 2.4)


def to_srgb(linear):
    linear = np.clip(linear, 0, 1)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055)


def read_linear(path):
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None:
        raise FileNotFoundError(path)
    scale = 65535.0 if image.dtype == np.uint16 else 255.0
    image = image[..., :3][..., ::-1].astype(np.float32) / scale if image.ndim == 3 else \
        np.repeat(image[..., None].astype(np.float32) / scale, 3, axis=2)
    return to_linear(image)


def creator_tool(path):
    """The app that wrote an export, from its XMP (`xmp:CreatorTool`)."""
    head = path.read_bytes()[:400_000].decode("latin-1")
    found = re.search(r"CreatorTool(?:>|=\")([^<\"]+)", head)
    return found.group(1).strip() if found else None


def coverage(baseline, edited, globally, model):
    """Coverage from 0 to 1 per pixel, and where it is unknown, from three linear RGB exports."""
    change = baseline - globally
    if model == "blend":
        valid = change > MIN_CHANGE
        each = (baseline - edited) / np.where(valid, change, 1)
        weight = np.where(valid, change ** 2, 0)
    else:
        valid = (baseline > 0.002) & (globally > 1e-5) & (change > MIN_CHANGE) & (edited > 1e-5)
        ratio = np.log(np.where(valid, globally, 1) / np.where(valid, baseline, 1))
        each = np.log(np.where(valid, edited, 1) / np.where(valid, baseline, 1)) / np.where(valid, ratio, 1)
        weight = np.where(valid, change ** 2, 0)
    total = weight.sum(axis=2)
    cover = np.where(total > 0, (each * weight).sum(axis=2) / np.where(total > 0, total, 1), 0)
    return np.clip(cover, 0, 1).astype(np.float32), total <= 0


def exports(inbox, preset):
    folder = inbox / preset
    if not folder.exists():
        return {}
    found = {}
    for path in folder.iterdir():
        if path.suffix.lower() in (".tif", ".tiff", ".png", ".jpg", ".jpeg"):
            found[re.sub(r"(-\d+| copy)$", "", path.stem)] = path
    return found


def prepare(_args):
    entries = {e["id"]: e for e in c.pool() if e["path"].exists()}
    calibration = c.LIGHTROOM / "import/calibration"
    every = c.LIGHTROOM / "import/pool"
    for folder in (calibration, every):
        folder.mkdir(parents=True, exist_ok=True)
    card = np.zeros((1365, 2048, 3), np.float32)
    for index, level in enumerate(CARD_LEVELS):
        card[:, index * 512:(index + 1) * 512] = to_srgb(np.float32(level))
    cv2.imwrite(str(calibration / f"{CARD}.tif"), (card * 65535 + 0.5).astype(np.uint16))
    for photo_id in CALIBRATION_PHOTOS:
        if photo_id in entries:
            clone(entries[photo_id]["path"], calibration)
    for entry in entries.values():
        clone(entry["path"], every)
    for preset in PRESETS + ("brush",):
        (c.LIGHTROOM / "inbox" / preset).mkdir(parents=True, exist_ok=True)
    print(f"==> {calibration.relative_to(c.ROOT)}: the grey card and {len(CALIBRATION_PHOTOS)} photos")
    print(f"==> {every.relative_to(c.ROOT)}: {len(entries)} photos")
    print(f"==> exports go to {(c.LIGHTROOM / 'inbox').relative_to(c.ROOT)}/<preset>/ "
          f"({', '.join(PRESETS)}; and brush, for the grey card only)")


def clone(source, folder):
    target = folder / source.name
    if not target.exists():
        subprocess.run(["cp", "-c", str(source), str(target)], check=True)


def calibrate(args):
    inbox = c.pathlib.Path(args.inbox)
    paths = {preset: exports(inbox, preset).get(CARD) for preset in ("baseline", "global", "brush")}
    missing = [preset for preset, path in paths.items() if path is None]
    if missing:
        sys.exit(f"the grey card's {', '.join(missing)} export{'s are' if len(missing) > 1 else ' is'} "
                 f"missing from {inbox}")
    b, g, m = (read_linear(paths[p]) for p in ("baseline", "global", "brush"))
    width = b.shape[1]
    bands = []
    for index, level in enumerate(CARD_LEVELS):
        x0, x1 = int(width * (index + 0.2) / 4), int(width * (index + 0.8) / 4)
        y0, y1 = int(b.shape[0] * 0.2), int(b.shape[0] * 0.8)
        patch = lambda image: image[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)  # noqa: E731
        pb, pg, pm = patch(b), patch(g), patch(m)
        blend, _ = coverage(pb[None, None], pm[None, None], pg[None, None], "blend")
        scale, _ = coverage(pb[None, None], pm[None, None], pg[None, None], "scale")
        bands.append({"level": level, "baseline": pb.tolist(), "global": pg.tolist(), "brush": pm.tolist(),
                      "blend": float(blend[0, 0]), "scale": float(scale[0, 0])})
    error = {model: float(np.mean([abs(band[model] - 0.5) for band in bands])) for model in ("blend", "scale")}
    model = min(error, key=error.get)
    result = {"model": model, "error": error, "bands": bands, "creatorTool": creator_tool(paths["brush"]),
              "made": c.now()}
    (c.LIGHTROOM / "calibration.json").write_text(json.dumps(result, indent=1) + "\n")
    for band in bands:
        print(f"    grey {band['level']:.2f}: coverage {band['blend']:.3f} if Lightroom blends, "
              f"{band['scale']:.3f} if it scales the slider (painted 0.5)")
    print(f"==> {model}: mean error {error[model]:.3f} against {error['scale' if model == 'blend' else 'blend']:.3f}")


def calibrated_model(args):
    if args.model != "auto":
        return args.model
    path = c.LIGHTROOM / "calibration.json"
    if not path.exists():
        sys.exit("no calibration yet: export the grey card (maskbench lightroom calibrate), or pass --model")
    return json.loads(path.read_text())["model"]


def decode(args):
    inbox = c.pathlib.Path(args.inbox)
    model = calibrated_model(args)
    found = {preset: exports(inbox, preset) for preset in PRESETS}
    entries = {e["id"]: e for e in c.pool()}
    tools = {creator_tool(path) for path in list(found["baseline"].values())[:3]} - {None}
    tool = sorted(tools)[0] if tools else "Lightroom"
    version = re.search(r"(\d+(?:\.\d+)+)", tool)
    folder = c.LIGHTROOM / (version.group(1) if version else c.now()[:10])
    decoded = 0
    for photo_id, base in sorted(found["baseline"].items()):
        entry = entries.get(photo_id)
        if entry is None or photo_id not in found["global"]:
            continue
        size = c.size_of(entry)
        b, g = read_linear(base), read_linear(found["global"][photo_id])
        done = []
        for kind in c.KINDS:
            path = found[kind].get(photo_id)
            if path is None:
                continue
            m = read_linear(path)
            if m.shape != b.shape:
                print(f"    {photo_id} {kind}: {m.shape[1]}x{m.shape[0]}, its baseline {b.shape[1]}x{b.shape[0]}",
                      file=sys.stderr)
                continue
            cover, unknown = coverage(b, m, g, model)
            aspect = abs(cover.shape[1] / cover.shape[0] - size[0] / size[1]) / (size[0] / size[1])
            if aspect > 0.02:
                print(f"    {photo_id}: Lightroom's frame is {aspect:.1%} off the bench's in shape", file=sys.stderr)
            c.write_mask(c.mask_path(folder, kind, photo_id), cv2.resize(cover, size, interpolation=cv2.INTER_AREA))
            unknown_path = c.unknown_path(folder, kind, photo_id)
            if unknown.mean() > 0.0005:
                c.write_mask(unknown_path, cv2.resize(unknown.astype(np.float32), size, interpolation=cv2.INTER_AREA))
            elif unknown_path.exists():
                unknown_path.unlink()
            done.append(path)
            decoded += 1
        if len(done) == sum(photo_id in found[kind] for kind in c.KINDS) and done:
            for path in done + [base, found["global"][photo_id]]:
                path.unlink()
    (folder).mkdir(parents=True, exist_ok=True)
    (folder / "version.json").write_text(json.dumps({"creatorTool": tool, "model": model, "decoded": c.now(),
                                                     "masks": decoded}, indent=1) + "\n")
    print(f"==> {decoded} masks decoded from {tool} ({model}) into {folder.relative_to(c.ROOT)}")


def selftest(_args):
    """Decodes simulated exports, blended and scaled, made through an S-shaped tone curve."""
    entry = next(e for e in c.pool() if e["id"] == "sky-bare-trees-01")
    photo = to_linear(cv2.imread(str(c.bench_jpeg(entry)))[..., ::-1].astype(np.float32) / 255)
    height, width = photo.shape[:2]
    yy, xx = np.mgrid[0:height, 0:width]
    truth = np.clip(1.2 - np.hypot(xx - width * 0.5, yy - height * 0.45) / (0.3 * min(width, height)), 0, 1)
    gain = 2 ** EXPOSURE

    def tone(linear):
        return linear / (linear + 0.18) * 1.18

    def export(linear):
        return to_linear(np.round(to_srgb(np.clip(linear, 0, 1)) * 65535) / 65535)

    b, g = export(tone(photo)), export(tone(photo * gain))
    blended = export(tone(photo) * (1 - truth[..., None]) + tone(photo * gain) * truth[..., None])
    scaled = export(tone(photo * gain ** truth[..., None]))
    ok = True
    for name, edited in (("blended", blended), ("scaled", scaled)):
        for model in ("blend", "scale"):
            cover, unknown = coverage(b, edited, g, model)
            error = float(np.abs(cover - truth)[~unknown].mean())
            right = (name == "blended") == (model == "blend")
            print(f"    {name} exports decoded as {model}: mean error {error:.4f}, unknown {unknown.mean():.2%}"
                  f"{'' if right else ' (the wrong decoding, for comparison)'}")
            ok &= error < 0.02 if right else True
    print("==> selftest passed" if ok else "==> selftest FAILED")
    sys.exit(0 if ok else 1)


def main(args):
    {"prepare": prepare, "calibrate": calibrate, "decode": decode, "selftest": selftest}[args.action](args)
