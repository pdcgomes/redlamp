"""For an overexposed sample: each class's colour in the truth render (the unclipped original at the same
final exposure), and every candidate's mean and 95th-percentile OKLab difference (x 100) from it over
clipped pixels, from compare.py's report. Usage (with CAM08_OVEREXPOSE set): truth.py <raw> <name>"""
import json
import sys
from pathlib import Path

import numpy as np
import tifffile

import measure

raw, name = sys.argv[1], sys.argv[2]
folder = Path("renders") / name
truth = Path("renders") / f"{name}-truth"
report = json.loads((folder / "report.json").read_text())
settings = [s for s in ["defaults", "highlights-80", "exposure-1.5", "exposure-3"] if (folder / f"main-{s}.tif").exists()]
candidates = [c for c in ["main", "a", "b", "c", "d", "e", "e8"] if (folder / f"{c}-defaults.tif").exists()]
for setting in settings:
    path = truth / f"main-{setting}.tif"
    lab = measure.oklab_from_linear_srgb(measure.decode(str(path)))
    classes, _ = measure.class_map(raw, lab.shape[:2])
    srgb = tifffile.imread(str(path))[..., :3].astype(np.float64) / 65535 * 255
    cells = []
    for bit, label in measure.NAMES.items():
        sel = classes == bit
        if sel.sum() < 200:
            continue
        mean = srgb[sel].mean(axis=0)
        a, b = lab[sel][:, 1].mean(), lab[sel][:, 2].mean()
        cells.append(f"{label} {tuple(int(round(v)) for v in mean)} C{np.hypot(a, b):.3f} h{np.degrees(np.arctan2(b, a)):+.0f}")
    print(f"truth {setting:14s} " + ", ".join(cells))
    print("  error mean/p95: " + ", ".join(
        f"{c} {report[f'{c}/{setting}']['truth']['clipped_delta_mean']:.2f}/{report[f'{c}/{setting}']['truth']['clipped_delta_p95']:.1f}"
        for c in candidates))
