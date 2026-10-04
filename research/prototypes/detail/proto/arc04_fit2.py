"""Refinements: the weight follows the output's position within its level, p = scale / 2^L, and
levels 3+ are computed at level 2 and box-averaged (the cap)."""
import numpy as np
from detail import FLOOR, bilinear_resize, box_mips, lanczos_resize, load_dump, luminance
from arc04 import ladder, todays_texture
from arc04_fit import LIMIT

BASE = {1: 0.994, 2: 1.11}
GAMMA = {1: 0.1, 2: 0.41}
P_FIT = {1: 1.52, 2: 1.52}


def proposed(mips, level, t, p):
    gain = t if t > 0 else 0.5 * t
    y = mips[level]
    if level == 0:
        lv = ladder(y, 0, 3)
        detail = np.log2(lv[1] + FLOOR) - np.log2(lv[3] + FLOOR)
    else:
        lv = ladder(y, level, 3)
        weight = BASE[level] * (P_FIT[level] / p) ** GAMMA[level]
        detail = weight * (np.log2(y + FLOOR) - np.log2(lv[3] + FLOOR))
    return gain * LIMIT * np.tanh(detail / LIMIT)


def ratio(y, edge, t=0.6):
    h, w = y.shape
    scale = max(h, w) / edge
    shape = (round(h / scale), round(w / scale))
    mips = box_mips(y, 7)
    level = int(np.floor(np.log2(scale) + 0.01))
    work = min(level, 2)
    p = scale / 2 ** work if level <= 2 else 2.0 * 0 + scale / 2 ** level * 2  # position for the weight
    p = min(max(scale / 2 ** work, 1.0), 2.0) if level <= 2 else 1.999
    export = lanczos_resize(y * np.exp2(proposed(mips, 0, t, 1.0)), shape) - lanczos_resize(y, shape)
    edited = mips[work] * np.exp2(proposed(mips, work, t, p))
    for _ in range(level - work):
        edited = box_mips(edited, 1)[1]
    base = mips[level]
    preview = bilinear_resize(edited[:base.shape[0], :base.shape[1]], shape) - bilinear_resize(base, shape)
    r = np.sqrt((preview ** 2).sum() / (export ** 2).sum())
    c = (preview * export).sum() / np.sqrt((preview ** 2).sum() * (export ** 2).sum())
    return float(r), float(c), level


for name in ["DSC_0750", "Pentax_K-1-Mark-II", "Nikon_Coolpix-P7700", "Sony_ILCE-7CM2"]:
    y = luminance(*load_dump(name))
    long = max(y.shape)
    cells = []
    for edge in (700, 1000, 2000, round(long / 2.6), round(long / 5.2), round(long / 10.4), round(long / 4.05), round(long / 7.8)):
        r, c, level = ratio(y, edge)
        cells.append(f"{edge}px L{level}: {r:.2f} ({c:.2f})")
    print(name, "\n  " + "\n  ".join(cells))
