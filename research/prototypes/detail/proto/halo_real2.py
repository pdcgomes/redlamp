import numpy as np, cv2
from scipy import ndimage
from detail import FLOOR, OUT, atrous_blur, load_dump, luminance

def proposed(y, limit, gain=1.0):
    c1 = atrous_blur(y, 1); c3 = atrous_blur(atrous_blur(c1, 2), 4)
    d = np.log2(np.maximum(c1, 0) + FLOOR) - np.log2(np.maximum(c3, 0) + FLOOR)
    return gain * limit * np.tanh(d / limit)

variants = [(0.25, 1.0), (0.25, 1.2), (0.35, 1.0), (0.35, 1.1)]
print("| photo | today: 99th pct beside edges | today: mean in texture | " + " | ".join(f"limit {l} gain {g}: edges / texture" for l, g in variants) + " |")
for name in ["DSC_0750", "Pentax_K-1-Mark-II", "Nikon_Coolpix-P7700", "Sony_ILCE-7CM2"]:
    rgb, meta = load_dump(name); y = np.maximum(luminance(rgb, meta), 0); h, w = y.shape
    out = np.maximum(np.fromfile(OUT / f"{name}_texture100_Y.f32", np.float32).reshape(h, w), 0)
    today = np.log2(out + FLOOR) - np.log2(y + FLOOR)
    ls = cv2.GaussianBlur(np.log2(y + FLOOR), (0, 0), 1.5)
    gx, gy = np.gradient(ls)
    strong = np.hypot(gx, gy) > 0.35
    near = ndimage.binary_dilation(strong, iterations=12) & ~ndimage.binary_dilation(strong, iterations=1)
    far = ~ndimage.binary_dilation(strong, iterations=40)
    c1 = atrous_blur(y, 1); c3 = atrous_blur(atrous_blur(c1, 2), 4)
    tex = far & (np.abs(np.log2(c1 + FLOOR) - np.log2(np.maximum(c3, 0) + FLOOR)) > 0.05)
    sl = (slice(32, -32), slice(32, -32)); n, t = near[sl], tex[sl]
    cells = []
    for l, g in variants:
        p = proposed(y, l, g)
        cells.append(f"{np.percentile(np.abs(p[sl][n]), 99):.2f} / {np.abs(p[sl][t]).mean():.3f}")
    print(f"| {name} | {np.percentile(np.abs(today[sl][n]), 99):.2f} | {np.abs(today[sl][t]).mean():.3f} | " + " | ".join(cells) + " |")
