"""Texture +100 beside strong edges in real photos: the engine's output (today) against the proposed
ladder band with its soft limit, on the same level-0 luminance."""
import numpy as np, cv2
from scipy import ndimage
from detail import FLOOR, OUT, atrous_blur, load_dump, luminance

def proposed(y, limit=0.25):
    c1 = atrous_blur(y, 1); c3 = atrous_blur(atrous_blur(c1, 2), 4)
    d = np.log2(c1 + FLOOR) - np.log2(c3 + FLOOR)
    return limit * np.tanh(d / limit) if limit else d

print("| photo | strong-edge px | today: 99th pct |boost| beside edges | proposed | today: mean |boost| in texture away from edges | proposed |")
for name in ["DSC_0750", "Pentax_K-1-Mark-II", "Nikon_Coolpix-P7700", "Sony_ILCE-7CM2"]:
    rgb, meta = load_dump(name); y = luminance(rgb, meta); h, w = y.shape
    today = np.log2(np.maximum(np.fromfile(OUT / f"{name}_texture100_Y.f32", np.float32).reshape(h, w), 1e-6) + FLOOR) - np.log2(y + FLOOR)
    prop = proposed(y)
    ls = cv2.GaussianBlur(np.log2(y + FLOOR), (0, 0), 1.5)
    gx, gy = np.gradient(ls)
    # a step of 2+ stops: the difference across +-4 px along the gradient
    strong = np.hypot(gx, gy) > 0.35
    near = ndimage.binary_dilation(strong, iterations=12) & ~ndimage.binary_dilation(strong, iterations=1)
    far = ~ndimage.binary_dilation(strong, iterations=40)
    tex = far & (np.abs(np.log2(atrous_blur(y, 1) + FLOOR) - np.log2(atrous_blur(atrous_blur(atrous_blur(y, 1), 2), 4) + FLOOR)) > 0.05)
    m = 32
    sl = (slice(m, -m), slice(m, -m))
    n, t = near[sl], tex[sl]
    print(f"| {name} | {int(strong[sl].sum())} | {np.percentile(np.abs(today[sl][n]), 99):.2f} | {np.percentile(np.abs(prop[sl][n]), 99):.2f} | {np.abs(today[sl][t]).mean():.3f} | {np.abs(prop[sl][t]).mean():.3f} |")
