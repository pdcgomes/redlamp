"""Run Apple's VideoToolbox super-resolution scaler (vt_superres.swift) over the upscaling items.

The scaler only offers 4x on the M1 Ultra, so 2x items run at 4x and are downscaled (area filter),
as in note B. Output values are clipped to [0, 1] by the scaler.

Usage: build/restoration-venv/bin/python research/prototypes/restoration/run_vt.py
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import cv2
import numpy as np

from common import OUT, TESTSET, load_manifest, read_rgb, write_rgb

METHOD = "vt_superres"
HERE = Path(__file__).resolve().parent


def main() -> None:
    manifest = load_manifest()
    items = [i for i in manifest["items"] if i["task"] == "sr"] + [r for r in manifest["real"] if r["task"] == "sr"]
    work = OUT / "vt-work"
    (work / "in").mkdir(parents=True, exist_ok=True)
    for item in items:
        image = read_rgb(TESTSET / item["lq"])
        h, w = image.shape[:2]
        (work / "in" / f"{item['id']}.bin").write_bytes(np.array([w, h], np.uint32).tobytes() + image.astype(np.float32).tobytes())
    result = subprocess.run(["swift", str(HERE / "vt_superres.swift"), str(work / "in"), str(work / "out")],
                            check=True, capture_output=True, text=True)
    times = {line.split()[0]: float(line.split()[1]) for line in result.stdout.splitlines() if line.strip()}
    for item in items:
        data = (work / "out" / f"{item['id']}.bin").read_bytes()
        w, h = np.frombuffer(data[:8], np.uint32)
        out = np.frombuffer(data[8:], np.float32).reshape(h, w, 3)
        if item["factor"] != 4:
            size = (int(w * item["factor"] / 4), int(h * item["factor"] / 4))
            out = cv2.resize(out, size, interpolation=cv2.INTER_AREA)
        write_rgb(OUT / "outputs" / METHOD / f"{item['id']}.png", out)
    (OUT / "runs" / f"{METHOD}.json").write_text(json.dumps(dict(
        method=METHOD, task="sr", device="VideoToolbox (macOS 26)", times=times,
        note="VTSuperResolutionScaler .image revision1 at 4x (2x = 4x then area downscale); Apple OS API"), indent=1))
    print(f"{METHOD}: {len(times)} items, median {np.median(list(times.values())):.3f} s")


if __name__ == "__main__":
    main()
