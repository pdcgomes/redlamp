"""What CAM-08 makes of a photo's clipped areas: per class of clipped colours, the balanced camera
RGB before and after reconstruction and its chroma once pulled below white."""
import sys
import time

import numpy as np

import cam08

path = sys.argv[1]
start = time.time()
m = cam08.load(path)
print(f"{path}\n  size {m.raw.shape}, block {m.block}, black {np.unique(m.black)}, white {m.white}, "
      f"balance {m.balance.round(4)}")
cfa = cam08.normalise(m)
model = cam08.fit(m, cfa)
if model is None:
    print("  nothing clipped")
    sys.exit()
print(f"  clip {model['clip'].round(4)}, fully clipped value {model['w']:.4f}, rim samples {model['rim_samples']}, "
      f"clipped blocks {model['clipped_blocks']}")
print(f"  rim blocks {model['rim_blocks']}, bright enough {model['rim_bright']}; rim mean {model['rim_mean_all'].round(3)}, "
      f"bright rim mean {None if model['rim_mean_bright'] is None else model['rim_mean_bright'].round(3)}")
where = model["rim_bright_where"]
if len(where):
    print(f"  bright rim rows {where[:, 0].min()}-{where[:, 0].max()} of {cfa.shape[0] // m.block}, "
          f"columns {where[:, 1].min()}-{where[:, 1].max()} of {cfa.shape[1] // m.block}")
coefficients = model["coefficients"]
for c, name in enumerate("RGB"):
    print(f"  offsets for {name}: both {coefficients[c * 3][0]:+.4f}, from {'RGB'[(c + 1) % 3]} {coefficients[c * 3 + 1][0]:+.4f}, "
          f"from {'RGB'[(c + 2) % 3]} {coefficients[c * 3 + 2][0]:+.4f}")
rebuilt = cam08.reconstruct(m, cfa, model)
before = cam08.binned(m, cfa)
after = cam08.binned(m, rebuilt)
bits = cam08.clipped_channels(m)
names = {1: "R", 2: "G", 3: "RG", 4: "B", 5: "RB", 6: "GB", 7: "RGB"}
print("  class   blocks     before (R G B balanced)      after (R G B balanced)      chroma after  hue")
for bit in sorted(names):
    sel = bits == bit
    n = int(sel.sum())
    if n < 50:
        continue
    b = before[sel].mean(axis=0)
    a = after[sel].mean(axis=0)
    chroma, hue = cam08.chroma_at_equal_lightness(cam08.to_rec2020(m, a[None, :]))
    print(f"  {names[bit]:5s} {n:9d}   {b.round(3)}   {a.round(3)}   {chroma[0]:.4f}   {hue[0]:.0f}")
np.savez_compressed(path.split("/")[-1] + ".study.npz", before=before, after=after, bits=bits,
                    balance=m.balance, rgb_cam=m.rgb_cam, clip=model["clip"])
print(f"  {time.time() - start:.0f} s")
