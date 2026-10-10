"""Which samples clipped, and in which colours: blocks per class of clipped colours."""
import sys
import time

import numpy as np

import cam08

names = {1: "R", 2: "G", 3: "RG", 4: "B", 5: "RB", 6: "GB", 7: "RGB"}
for path in sys.argv[1:]:
    start = time.time()
    try:
        m = cam08.load(path)
    except Exception as error:  # noqa: BLE001
        print(f"{path.split('/')[-1]}: {error}")
        continue
    if m.raw.ndim != 2:
        print(f"{path.split('/')[-1]}: not a mosaic")
        continue
    bits = cam08.clipped_channels(m)
    total = bits.size
    counts = {names[b]: int((bits == b).sum()) for b in names}
    shown = ", ".join(f"{k} {v / total * 100:.2f}%" for k, v in counts.items() if v / total >= 0.0005)
    print(f"{path.split('/')[-1]}: block {m.block}, white {m.white:.0f}, balance {m.balance.round(3)}, "
          f"clipped {(bits > 0).mean() * 100:.2f}% [{shown}] ({time.time() - start:.0f} s)", flush=True)
