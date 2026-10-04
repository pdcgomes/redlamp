import sys, glob, os, numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter
d = '/tmp/w4-detail/crops'
tags = sys.argv[1].split(',')
def lin(f):
    a = np.asarray(Image.open(f).convert('RGB'), dtype=np.float64) / 255
    a = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return np.log2(a @ [0.2126, 0.7152, 0.0722] + 1e-3)
for prefix in sorted({os.path.basename(f).rsplit('_', 1)[0] for f in glob.glob(f'{d}/*_base.png')}):
    base = lin(f'{d}/{prefix}_base.png')
    # Where the step is large (edges) versus the rest (texture), from the base's gradient.
    g = np.hypot(*np.gradient(gaussian_filter(base, 1.5)))
    mid = (base > -5) & (base < -0.5)
    edge = (g > np.percentile(g, 92)) & mid
    flat = ~(g > np.percentile(g, 92)) & mid
    row = []
    for v in (50, 100, -50):
        for t in ['p9'] + tags:
            f = f'{d}/{prefix}_{t}_t{v}.png'
            if not os.path.exists(f): continue
            diff = lin(f) - base
            row.append(f'{t}/{v}: tex {np.sqrt((diff[flat]**2).mean()):.3f} edge {np.sqrt((diff[edge]**2).mean()):.3f}')
    print(prefix, ' | '.join(row))
