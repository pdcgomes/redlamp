"""The denoise benchmark's synthetic cases (INF-14): DN-11's scenes as CFA DNGs, with their truth.

    BENCHMARK_OUT=build/benchmarks/denoise python research/prototypes/raw_denoise/make_benchmark.py \
        --scene text --cfa bayer --level iso12800

For the case `synthetic-<scene>-<cfa>-<level>` it writes, in $BENCHMARK_OUT:

- `<case>.dng`: the noisy mosaic, exactly as make_testset.py makes it (the same seeds), so the harness's
  scores and the benchmark's agree;
- `synthetic-<scene>-<cfa>-clean.dng`: the same mosaic without noise, for Lightroom's and Redlamp's own
  render of the truth (skipped when present);
- `synthetic-<scene>-truth.tif`: the scene's full-colour truth, balanced camera RGB, linear float32.

The DNGs are DNG 1.4 CFA images Lightroom and Redlamp open: the CFA pattern (Bayer RGGB or Redlamp's X-Trans
tile), black 4096 and white 65535 (room below black for the noise), ColorMatrix1 for D65 and AsShotNeutral
for the synthetic camera, whose white-balanced RGB is linear sRGB, ISOSpeedRatings, and NoiseProfile with the
exact noise model (Redlamp reads it; the clean DNG's says it's noise-free). Needs numpy, scipy, Pillow, rawpy
and tifffile (requirements.txt); run by another Python, it runs itself again with build/dn11-venv's.
"""

import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
try:
    import numpy as np
    import tifffile
except ImportError:
    venv = HERE.parents[2] / "build/dn11-venv/bin/python"
    if not venv.exists() or Path(sys.executable) == venv:
        raise SystemExit("needs numpy, scipy, Pillow, rawpy and tifffile: set up build/dn11-venv (README.md)")
    os.execv(str(venv), [str(venv), __file__, *sys.argv[1:]])

sys.path.insert(0, str(HERE))
from common import AS_SHOT, CFAS, NOISE_LEVELS, add_noise, mosaic  # noqa: E402
import make_testset as mt  # noqa: E402

SCENES = ["edge", "star", "zone", "leaves", "text", "photo-sony", "photo-nikon", "photo-canon", "photo-fuji"]
CHARTS = {"edge": mt.slanted_edge, "star": mt.siemens_star, "zone": mt.zone_plate, "leaves": mt.dead_leaves,
          "text": mt.text_and_patches}
BLACK, WHITE = 4096, 65535
XYZ_TO_SRGB = np.array([[3.2404542, -1.5371385, -0.4985314],
                        [-0.9692660, 1.8760108, 0.0415560],
                        [0.0556434, -0.2040259, 1.0572252]])
CLEAN_PROFILE = (1e-7, 1e-10)


def rational(values, denominator=1_000_000):
    out = []
    for v in values:
        out += [int(round(v * denominator)), denominator]
    return out


def write_dng(path, raw, cfa, iso, a, b, model):
    """raw: the normalised mosaic (0 black, 1 white) before white balance; a, b its noise model."""
    data = np.clip(np.round(BLACK + raw * (WHITE - BLACK)), 0, 65535).astype(np.uint16)
    p = cfa.shape[0]
    colour_matrix = np.diag(1 / np.array(AS_SHOT)) @ XYZ_TO_SRGB
    neutral = [1 / g for g in AS_SHOT]
    tags = [
        (254, 4, 1, 0, True),                                  # NewSubfileType: the main image
        (271, 2, 0, "Synthetic", True),                         # Make (LibRaw reads "Redlamp" as RED's)
        (272, 2, 0, model, True),                               # Model
        (274, 3, 1, 1, True),                                   # Orientation
        (33421, 3, 2, (p, p), True),                            # CFARepeatPatternDim
        (33422, 1, p * p, bytes(int(c) for c in cfa.flatten()), True),  # CFAPattern
        (34855, 3, 1, int(iso), True),                          # ISOSpeedRatings
        (50706, 1, 4, (1, 4, 0, 0), True),                      # DNGVersion
        (50707, 1, 4, (1, 3, 0, 0), True),                      # DNGBackwardVersion
        (50708, 2, 0, f"Synthetic {model} (DN-17)", True),      # UniqueCameraModel
        (50710, 1, 3, (0, 1, 2), True),                         # CFAPlaneColor
        (50711, 3, 1, 1, True),                                 # CFALayout: rectangular
        (50713, 3, 2, (1, 1), True),                            # BlackLevelRepeatDim
        (50714, 4, 1, BLACK, True),                             # BlackLevel
        (50717, 4, 1, WHITE, True),                             # WhiteLevel
        (50721, 10, 9, rational(colour_matrix.flatten()), True),  # ColorMatrix1: XYZ (D65) to camera
        (50728, 5, 3, rational(neutral), True),                 # AsShotNeutral
        (50778, 3, 1, 21, True),                                # CalibrationIlluminant1: D65
        (51041, 12, 6, tuple(float(v) for _ in range(3) for v in (a, b)), True),  # NoiseProfile
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(path, data, photometric=32803, compression=None, extratags=tags, metadata=None)


def scene_rgb(scene):
    if scene in CHARTS:
        return CHARTS[scene]()
    return mt.photo_crops([scene.removeprefix("photo-")])[scene]["rgb"]


def make(scene, cfa_name, level, out):
    case = f"synthetic-{scene}-{cfa_name}-{level}"
    s, l = SCENES.index(scene), list(NOISE_LEVELS).index(level)
    a, b = NOISE_LEVELS[level]
    iso = int(level.removeprefix("iso"))
    rgb = scene_rgb(scene)
    clean = mosaic(rgb, CFAS[cfa_name])
    noisy = add_noise(clean, a, b, seed=1000 * s + 10 * l + (cfa_name == "xtrans"))
    model = "X-Trans" if cfa_name == "xtrans" else "Bayer"
    write_dng(out / f"{case}.dng", noisy, CFAS[cfa_name], iso, a, b, model)
    clean_path = out / f"synthetic-{scene}-{cfa_name}-clean.dng"
    if not clean_path.exists():
        write_dng(clean_path, clean, CFAS[cfa_name], 100, *CLEAN_PROFILE, model)
    truth_path = out / f"synthetic-{scene}-truth.tif"
    if not truth_path.exists():
        tifffile.imwrite(truth_path, rgb.astype(np.float32), photometric="rgb")
    print(case)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--scene", choices=SCENES, required=True)
    parser.add_argument("--cfa", choices=list(CFAS), required=True)
    parser.add_argument("--level", choices=list(NOISE_LEVELS), required=True)
    args = parser.parse_args()
    out = Path(os.environ.get("BENCHMARK_OUT", HERE.parents[2] / "build/benchmarks/denoise"))
    make(args.scene, args.cfa, args.level, out)


if __name__ == "__main__":
    main()
