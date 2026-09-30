"""Build the restoration bake-off test set.

1. Render the CC0 raw fixtures with Redlamp (neutral look, sharpening off, 16-bit sRGB).
2. Download a small public-domain / CC0 Wikimedia panel (faces, signage, tiny people).
3. Cut 1024 px regions, area-reduce them to 512 px ground truth, and apply degradations:
   bicubic 2x and 4x downscale, a "real-world" 4x (blur, noise, JPEG), Gaussian softness,
   disc defocus, linear and trajectory motion blur, and defocus with sensor-like noise.
4. Keep native-resolution crops as a "real" set with no ground truth.

Usage:
  build/restoration-venv/bin/python research/prototypes/restoration/make_testset.py \
      --redlamp build/restoration-dd/Build/Products/Release/redlamp
"""

from __future__ import annotations

import argparse
import json
import subprocess
import urllib.request

import cv2
import numpy as np

from common import (DATA, REPO, TESTSET, convolve_linear, disc_psf, downscale, gaussian_psf, jpeg,
                    linear_motion_psf, poisson_gaussian_noise, read_rgb, trajectory_motion_psf, write_rgb)

FIXTURES = REPO / "tests/fixtures/raw"
RENDERS = DATA / "renders"
PANEL = DATA / "panel"
UA = "RedlampResearch/1.0 (research prototype)"

# Wikimedia Commons files; licences read from the Commons API (extmetadata.LicenseShortName) on 2026-09-30.
PANEL_FILES = {
    "exp64": ("https://upload.wikimedia.org/wikipedia/commons/f/f1/Expedition_64_crew_portrait.jpg",
              "Public domain (NASA)", "File:Expedition_64_crew_portrait.jpg"),
    "sts135": ("https://upload.wikimedia.org/wikipedia/commons/6/6f/STS-135_crew_portrait.jpg",
               "Public domain (NASA)", "File:STS-135_crew_portrait.jpg"),
    "lincoln": ("https://upload.wikimedia.org/wikipedia/commons/1/1c/%21941_Lincoln_Continental_Coupe%2C_Series_57_"
                "-_Automobile_Driving_Museum_-_El_Segundo%2C_CA_-_DSC01970.jpg", "CC0",
                "File:!941_Lincoln_Continental_Coupe,_Series_57_-_Automobile_Driving_Museum_-_El_Segundo,_CA_-_DSC01970.jpg"),
    "square": ("https://upload.wikimedia.org/wikipedia/commons/9/9c/%21Defurovy_La%C5%BEany_-_n%C3%A1m%C4%9Bst%C3%AD.jpg",
               "CC0", "File:!Defurovy_Lažany_-_náměstí.jpg"),
}

# name: (source, centre x, centre y, crop size at source resolution, tags). Crops are area-resized to 512.
# Ground truth comes from a 2x (or larger) area reduction: an unsharpened 100% raw render has almost no
# energy near Nyquist, so a 4x downscale of it would lose nothing and every upscaler would look perfect.
CROPS = {
    "fuji_text": ("AFXT2720", 4575, 2623, 1024, ["text", "x-trans"]),
    "nikon_globe": ("DSC_0750", 4700, 2600, 1024, ["text"]),
    "nikon_monkey": ("DSC_0750", 3078, 1400, 1024, ["fur", "eyes"]),
    "sony_branches": ("_DSC0009", 1764, 882, 1024, ["foliage", "fine"]),
    "sony_roof": ("_DSC0009", 5294, 3528, 1024, ["repeating"]),
    "canon_wall": ("Canon_EOS_R6_RAW_ISO_100_nocrop_nodual", 1074, 806, 1024, ["texture"]),
    "canon_figure": ("Canon_EOS_R6_RAW_ISO_100_nocrop_nodual", 4135, 1504, 1024, ["smooth", "eyes"]),
    "iphone_grass": ("IMG_1361", 1576, 2758, 1024, ["foliage", "fine"]),
    "leica_dial": ("LEICAQ3", 2443, 2522, 1024, ["text", "edges"]),
    "leica_fur": ("LEICAQ3", 1497, 1497, 1024, ["fur"]),
    "exp64_faces": ("panel/exp64", 2020, 1740, 1024, ["faces"]),
    "sts135_faces": ("panel/sts135", 1019, 1107, 1024, ["faces"]),
    "lincoln_poster": ("panel/lincoln", 1496, 500, 1024, ["text"]),
    "square_people": ("panel/square", 2876, 2184, 1024, ["tiny-people", "text"]),
}

# Real inputs with no ground truth: native crops, already as soft as the lens made them.
REAL = {
    "fuji_plush_defocus": ("AFXT2720", 1525, 2013, 512, "deblur"),
    "nikon_toy_defocus": ("DSC_0750", 888, 3730, 512, "deblur"),
}
NOISE = dict(a=0.0015, b=2e-6)  # roughly a mid/high-ISO full-frame raw after exposure normalisation


def degradations() -> dict:
    return {
        "x2": dict(task="sr", factor=2, desc="bicubic 2x downscale"),
        "x4": dict(task="sr", factor=4, desc="bicubic 4x downscale"),
        "x4_real": dict(task="sr", factor=4, desc="Gaussian sigma 1.2 px (linear), 4x downscale, noise, JPEG q80"),
        "soft_g1.5": dict(task="deblur", factor=1, desc="Gaussian softness sigma 1.5 px (linear)",
                          psf=gaussian_psf(1.5)),
        "defocus_r4": dict(task="deblur", factor=1, desc="disc defocus radius 4 px (linear)", psf=disc_psf(4)),
        "motion_lin15": dict(task="deblur", factor=1, desc="linear motion 15 px at 30 deg (linear)",
                             psf=linear_motion_psf(15, 30)),
        "motion_traj21": dict(task="deblur", factor=1, desc="camera-shake trajectory in a 21 px support (linear)",
                              psf=trajectory_motion_psf(21, seed=7)),
        "defocus_r3_noise": dict(task="deblur", factor=1, desc="disc defocus radius 3 px + Poisson-Gaussian noise",
                                 psf=disc_psf(3), noise=True),
    }


def apply(name: str, spec: dict, gt: np.ndarray, seed: int) -> np.ndarray:
    if name == "x4_real":
        lq = downscale(convolve_linear(gt, gaussian_psf(1.2)), 4)
        return jpeg(poisson_gaussian_noise(lq, seed=seed, **NOISE), 80)
    if spec["task"] == "sr":
        return downscale(gt, spec["factor"])
    lq = convolve_linear(gt, spec["psf"])
    if spec.get("noise"):
        lq = poisson_gaussian_noise(lq, seed=seed, **NOISE)
    return np.clip(lq, 0, 1)


def render_fixtures(redlamp: str) -> None:
    RENDERS.mkdir(parents=True, exist_ok=True)
    for raw in sorted(FIXTURES.iterdir()):
        if raw.suffix.upper() not in {".NEF", ".ARW", ".RAF", ".CR3", ".DNG"}:
            continue
        out = RENDERS / f"{raw.stem}.png"
        if out.exists():
            continue
        subprocess.run([redlamp, "render", str(raw), "-o", str(out), "--16bit", "--base-look", "neutral",
                        "--set", "sharpenAmount=0"], check=True)


def fetch_panel() -> None:
    PANEL.mkdir(parents=True, exist_ok=True)
    for name, (url, _, _) in PANEL_FILES.items():
        out = PANEL / f"{name}.jpg"
        if not out.exists():
            request = urllib.request.Request(url, headers={"User-Agent": UA})
            out.write_bytes(urllib.request.urlopen(request).read())


def source_image(source: str) -> np.ndarray:
    if source.startswith("panel/"):
        return read_rgb(PANEL / f"{source.removeprefix('panel/')}.jpg")
    return read_rgb(RENDERS / f"{source}.png")


def cut(image: np.ndarray, cx: int, cy: int, size: int, out: int = 512) -> np.ndarray:
    h, w = image.shape[:2]
    x0 = int(np.clip(cx - size // 2, 0, w - size))
    y0 = int(np.clip(cy - size // 2, 0, h - size))
    crop = image[y0:y0 + size, x0:x0 + size]
    if size != out:
        crop = cv2.resize(crop, (out, out), interpolation=cv2.INTER_AREA)
    return crop


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--redlamp", default=str(REPO / "build/restoration-dd/Build/Products/Release/redlamp"))
    args = parser.parse_args()
    render_fixtures(args.redlamp)
    fetch_panel()

    specs = degradations()
    cache: dict[str, np.ndarray] = {}
    manifest: dict = {"crops": {}, "degradations": {}, "items": [], "real": [], "noise": NOISE}
    (TESTSET / "psf").mkdir(parents=True, exist_ok=True)
    for name, spec in specs.items():
        manifest["degradations"][name] = {k: v for k, v in spec.items() if k != "psf"}
        if "psf" in spec:
            np.save(TESTSET / "psf" / f"{name}.npy", spec["psf"])

    for index, (crop_name, (source, cx, cy, size, tags)) in enumerate(CROPS.items()):
        if source not in cache:
            cache[source] = source_image(source)
        gt = cut(cache[source], cx, cy, size)
        write_rgb(TESTSET / "gt" / f"{crop_name}.png", gt)
        licence = PANEL_FILES[source.removeprefix("panel/")][1] if source.startswith("panel/") else "CC0 (raw.pixls.us)"
        manifest["crops"][crop_name] = dict(source=source, cx=cx, cy=cy, size=size, tags=tags, license=licence)
        for d_index, (d_name, spec) in enumerate(specs.items()):
            lq = apply(d_name, spec, gt, seed=1000 * index + d_index)
            item_id = f"{crop_name}__{d_name}"
            write_rgb(TESTSET / "lq" / f"{item_id}.png", lq)
            manifest["items"].append(dict(id=item_id, crop=crop_name, degradation=d_name, task=spec["task"],
                                          factor=spec["factor"], lq=f"lq/{item_id}.png", gt=f"gt/{crop_name}.png",
                                          tags=tags))
        # A native-resolution 256 px crop at the same centre is a real 2x upscaling input with no ground truth.
        if not source.startswith("panel/"):
            real = cut(cache[source], cx, cy, 256, out=256)
            write_rgb(TESTSET / "real" / f"{crop_name}.png", real)
            manifest["real"].append(dict(id=f"{crop_name}__real", crop=crop_name, task="sr", factor=2,
                                         lq=f"real/{crop_name}.png", tags=tags))
    for crop_name, (source, cx, cy, size, task) in REAL.items():
        if source not in cache:
            cache[source] = source_image(source)
        real = cut(cache[source], cx, cy, size)
        write_rgb(TESTSET / "real" / f"{crop_name}.png", real)
        manifest["real"].append(dict(id=f"{crop_name}__real", crop=crop_name, task=task, factor=1,
                                     lq=f"real/{crop_name}.png", tags=["real-defocus"]))
    manifest["panel"] = {k: dict(url=v[0], license=v[1], commons=v[2]) for k, v in PANEL_FILES.items()}
    (TESTSET / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"{len(manifest['items'])} degraded items, {len(manifest['real'])} real items -> {TESTSET}")


if __name__ == "__main__":
    main()
