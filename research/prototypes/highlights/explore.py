"""Python model: CAM-08 as on main against candidates, per class of clipped colours, with quick looks."""
import sys
import time

import numpy as np

import cam08
import look
import variants

path, label = sys.argv[1], sys.argv[2]
which = sys.argv[3].split(",") if len(sys.argv) > 3 else ["v12", "a"]
m = cam08.load(path)
cfa = cam08.normalise(m)
bits = cam08.clipped_channels(m)
names = {1: "R", 2: "G", 3: "RG", 4: "B", 5: "RB", 6: "GB", 7: "RGB"}
results = {}
for name in which:
    start = time.time()
    if name == "v12":
        out = cam08.reconstruct(m, cfa, cam08.fit(m, cfa))
    elif name == "a":
        out, info = variants.candidate_a(m, cfa)
        print(f"  a: rim {info['rim']}, offsets G|RB {info['coefficients'][3][0]:+.4f} G|B {info['coefficients'][4][0]:+.4f} "
              f"G|R {info['coefficients'][5][0]:+.4f} B|RG {info['coefficients'][6][0]:+.4f} B|R {info['coefficients'][7][0]:+.4f}")
    elif hasattr(variants, f"candidate_{name}"):
        out, info = getattr(variants, f"candidate_{name}")(m, cfa)
        print(f"  {name}: {', '.join(f'{k} {v}' for k, v in info.items() if np.isscalar(v))}")
    results[name] = cam08.binned(m, out)
    print(f"  {name} took {time.time() - start:.0f} s", flush=True)

print("  class   blocks   " + "   ".join(f"{n:>26s}" for n in which))
for bit in sorted(names):
    sel = bits == bit
    if sel.sum() < 50:
        continue
    cells = []
    for name in which:
        a = results[name][sel].mean(axis=0)
        chroma, hue = cam08.chroma_at_equal_lightness(cam08.to_rec2020(m, a[None, :]))
        cells.append(f"{np.array2string(a, precision=3)} C{chroma[0]:.3f} h{hue[0]:+4.0f}")
    print(f"  {names[bit]:5s} {int(sel.sum()):9d}   " + "   ".join(cells))

for name in which:
    shown = look.develop(m, results[name], exposure=-1.5)
    step = max(1, shown.shape[1] // 1024)
    look.save(f"quick/{label}-{name}-exposure-1.5.jpg", shown[::step, ::step])
