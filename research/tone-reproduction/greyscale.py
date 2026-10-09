#!/usr/bin/env python3
"""How Redlamp reproduces a chart's grey scale (TON-39, CAM-28).

For each shot in a manifest (charts.json beside this script), it renders the raw with the
`redlamp` CLI as 16-bit sRGB TIFFs and measures each grey patch's L* against the chart's
reference values:

1. White balance: Temperature and Tint searched until the anchor patch (normally the chart's
   middle grey) is neutral.
2. As exposed: Exposure 0, with Redlamp Neutral and Redlamp Color.
3. Anchored: Exposure set so the anchor patch reads its reference L* under Neutral, which leaves
   only the tone curve's shape in the differences.
4. Where the shot put an 18% grey, in stops below the sensor's clip: the anchor patch's scene
   value, recovered through the tone curve's exact inverse, scaled from its reference to 18%.
5. The model of the curve (Develop.metal's constants) for the same grey position, beside the
   measurement.
6. Redlamp Reproduction (no tone curve), with Exposure set so the anchor patch reads its reference:
   every other patch should then read its own L*, but for flare in the shot.

Usage, from the repository root:

    python3 -m venv build/tone-reproduction/venv
    build/tone-reproduction/venv/bin/pip install numpy tifffile
    build/tone-reproduction/venv/bin/python research/tone-reproduction/greyscale.py \
        --redlamp build/DerivedData/Build/Products/Release/redlamp

It prints a Markdown table per shot and writes build/tone-reproduction/results.json.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
import tifffile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "tone-reproduction"

# The default tone curve, from packages/RedlampKernels/Sources/Shaders/Develop.metal.
MIDDLE_GREY = 0.18
SHOULDER_START = 0.54358851
SHOULDER_START_Y = 0.8
SHOULDER_WIDTH_EV = 2.40548194
SHOULDER_POWER = 3.25537943
FILMIC_AT_ONE = 0.80379747
# Redlamp's built-in looks' contrast (BaseLook.swift), as DevelopParameters applies it.
LOOK_CONTRAST = {"neutral": 0.72, "color": 1.0}


def filmic(x: float) -> float:
    return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)


def curve(x: float) -> float:
    if x <= SHOULDER_START:
        return filmic(x) / FILMIC_AT_ONE
    u = min(math.log2(x / SHOULDER_START) / SHOULDER_WIDTH_EV, 1.0)
    return 1 - (1 - SHOULDER_START_Y) * (1 - u) ** SHOULDER_POWER


def inverse_curve(y: float) -> float:
    y = min(max(y, 0.0), 1.0)
    if y <= SHOULDER_START_Y:
        t = y * FILMIC_AT_ONE
        a, b, c = 2.43 * t - 2.51, 0.59 * t - 0.03, 0.14 * t
        return max((-b - math.sqrt(max(b * b - 4 * a * c, 0.0))) / (2 * a), 0.0)
    u = 1 - ((1 - y) / (1 - SHOULDER_START_Y)) ** (1 / SHOULDER_POWER)
    return SHOULDER_START * 2 ** (u * SHOULDER_WIDTH_EV)


def lstar(y: float) -> float:
    f = y ** (1 / 3) if y > 216 / 24389 else y * 841 / 108 + 4 / 29
    return 116 * f - 16


def y_of_lstar(value: float) -> float:
    f = (value + 16) / 116
    return f**3 if f**3 > 216 / 24389 else (f - 4 / 29) * 108 / 841


def modelled(scene_y: float, look: str) -> float:
    """L* of a neutral of scene luminance `scene_y` (sensor clip 1) through a built-in look."""
    contrast = (LOOK_CONTRAST[look] - 1) * 0.6
    ev = math.log2(max(scene_y, 1e-9) / MIDDLE_GREY)
    return lstar(curve(MIDDLE_GREY * 2 ** (ev * (1 + contrast))))


def srgb_decode(v: np.ndarray) -> np.ndarray:
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


SRGB_TO_XYZ = np.array(
    [[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]]
)
D65 = SRGB_TO_XYZ @ np.ones(3)


def lab(linear: np.ndarray) -> tuple[float, float, float]:
    xyz = SRGB_TO_XYZ @ linear / D65
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), xyz * 841 / 108 + 4 / 29)
    return float(116 * f[1] - 16), float(500 * (f[0] - f[1])), float(200 * (f[1] - f[2]))


class Shot:
    def __init__(self, entry: dict, redlamp: Path, size: int):
        self.entry = entry
        self.raw = (ROOT / entry["file"]).resolve()
        self.redlamp = redlamp
        self.size = size
        self.references = entry["referenceL"]
        self.anchor = entry["anchor"]

    def render(self, name: str, look: str, exposure: float, temperature: float, tint: float) -> np.ndarray:
        out = OUT / f"{self.entry['id']}-{name}.tif"
        subprocess.run(
            [
                str(self.redlamp), "render", str(self.raw), "-o", str(out), "--size", str(self.size), "--16bit",
                "--base-look", look, "--wb", "daylight", "--set", f"temperature={temperature}",
                "--set", f"tint={tint}", "--set", f"exposure={exposure}",
            ],
            check=True, capture_output=True,
        )
        image = tifffile.imread(out)
        return image[..., :3].astype(np.float64) / 65535

    def patches(self, image: np.ndarray) -> list[np.ndarray]:
        """Each grey patch's mean linear sRGB."""
        height, width = image.shape[:2]
        half = max(2, int(self.entry["patchHalfSize"] * width))
        means = []
        for x, y in self.entry["greyPatches"]:
            cx, cy = int(x * width), int(y * height)
            box = image[cy - half : cy + half + 1, cx - half : cx + half + 1]
            means.append(srgb_decode(box).reshape(-1, 3).mean(axis=0))
        return means

    def neutral_balance(self) -> tuple[float, float]:
        temperature, tint = self.entry.get("startTemperature", 5500.0), 0.0
        for _ in range(8):
            image = self.render("wb", "neutral", 0, temperature, tint)
            _, a, b = lab(self.patches(image)[self.anchor])
            if abs(a) < 0.3 and abs(b) < 0.3:
                break
            # Warmer temperature makes the render yellower (b up), more tint more magenta (a up).
            temperature *= 2 ** (-b / 40)
            tint -= a * 1.5
        return temperature, tint


def measure(shot: Shot) -> dict:
    temperature, tint = shot.neutral_balance()
    result = {"id": shot.entry["id"], "camera": shot.entry["camera"], "temperature": temperature, "tint": tint}
    for look in ("neutral", "color"):
        image = shot.render(f"{look}-ev0", look, 0, temperature, tint)
        result[f"{look}AsExposed"] = [lab(p)[0] for p in shot.patches(image)]

    # The anchor's scene value through the Color look's inverse (contrast 1, so the curve alone).
    anchor_display = sum(shot.patches(shot.render("color-ev0", "color", 0, temperature, tint))[shot.anchor] * [0.2126, 0.7152, 0.0722])
    anchor_scene = inverse_curve(anchor_display)
    grey_scene = anchor_scene * MIDDLE_GREY / y_of_lstar(shot.references[shot.anchor])
    result["greyStopsBelowClip"] = -math.log2(grey_scene)

    # Anchored: Exposure so the anchor reads its reference under Neutral (bisection).
    low, high = -3.0, 3.0
    for _ in range(12):
        exposure = (low + high) / 2
        image = shot.render("neutral-anchored", "neutral", exposure, temperature, tint)
        value = lab(shot.patches(image)[shot.anchor])[0]
        if value < shot.references[shot.anchor]:
            low = exposure
        else:
            high = exposure
    result["anchoredExposure"] = exposure
    result["neutralAnchored"] = [lab(p)[0] for p in shot.patches(image)]

    result["model"] = {
        look: [modelled(y_of_lstar(ref) / MIDDLE_GREY * grey_scene, look) for ref in shot.references]
        for look in ("neutral", "color")
    }

    # Redlamp Reproduction: without a curve the anchor's light scales with Exposure, so a step or two
    # of the ratio to its reference anchors it.
    reference = shot.references[shot.anchor]
    exposure = 0.0
    image = shot.render("reproduction-anchored", "reproduction", exposure, temperature, tint)
    for _ in range(3):
        value = lab(shot.patches(image)[shot.anchor])[0]
        if abs(value - reference) < 0.02:
            break
        exposure += math.log2(y_of_lstar(reference) / y_of_lstar(value))
        image = shot.render("reproduction-anchored", "reproduction", exposure, temperature, tint)
    result["reproductionExposure"] = exposure
    result["reproductionAnchored"] = [lab(p)[0] for p in shot.patches(image)]
    return result


def table(shot: Shot, result: dict) -> str:
    names = shot.entry["patchNames"]
    rows = [
        ("Reference L*", shot.references),
        ("Neutral, Exposure 0", result["neutralAsExposed"]),
        ("Neutral, model", result["model"]["neutral"]),
        ("Color, Exposure 0", result["colorAsExposed"]),
        ("Color, model", result["model"]["color"]),
        (f"Neutral, Exposure {result['anchoredExposure']:+.2f} (anchored)", result["neutralAnchored"]),
        (
            f"Reproduction, Exposure {result['reproductionExposure']:+.2f} (anchored)",
            result["reproductionAnchored"],
        ),
    ]
    lines = [
        f"### {shot.entry['camera']} ({shot.entry['id']})",
        "",
        f"White balance {result['temperature']:.0f} K, tint {result['tint']:+.0f}; an 18% grey at "
        f"{result['greyStopsBelowClip']:.2f} stops below clip.",
        "",
        "| | " + " | ".join(names) + " |",
        "|---" * (len(names) + 1) + "|",
    ]
    for label, values in rows:
        lines.append(f"| {label} | " + " | ".join(f"{v:.1f}" for v in values) + " |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--redlamp", type=Path, required=True, help="the redlamp CLI")
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("charts.json"))
    parser.add_argument("--size", type=int, default=1600, help="long edge of the renders")
    parser.add_argument("--only", help="measure only the shot with this id")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    shots = json.loads(args.manifest.read_text())["shots"]
    results = []
    for entry in shots:
        if args.only and entry["id"] != args.only:
            continue
        shot = Shot(entry, args.redlamp.resolve(), args.size)
        if not shot.raw.exists():
            print(f"skipping {entry['id']}: {shot.raw} isn't there", file=sys.stderr)
            continue
        result = measure(shot)
        results.append(result)
        print(table(shot, result), end="\n\n")
    (OUT / "results.json").write_text(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
