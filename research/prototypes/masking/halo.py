#!/usr/bin/env python3
"""The halo around people against pale, blurred backgrounds, and a colour check against it.

Closed-form matting (ClosedFormMatte, what Redlamp computes for Subject, Background and People)
spreads a faint coverage over background whose colour is close to the person's, such as hair
against a pale, out-of-focus wall. A colour check: estimate the colour of the sure background and
the sure person near each pixel of the uncertain band (each spread from its trimap region by a
normalised blur), and where the pixel's own colour says it is background (its share of the way
from background to person, Smith and Blinn's projection), take coverage down to that share,
trusting it as far as the two colours are apart.

Scored as portrait_bench.py does, against ViTMatte's matte (the open trimap), over the wide
uncertain band: error (MAE), strands kept (reference 0.1-0.9 beyond Vision's edge, kept > 0.1),
and the halo (mean coverage where the reference has none, < 0.02).

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/halo.py
"""

import pathlib
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from portrait_bench import PORTRAITS, WORK, trimap  # noqa: E402

MATTES = {"DSC02005": "DSC02005-swift-cf.png", "DSC03301": "DSC03301-swift-cf.png",
          "DSC02424": "DSC02424-swift-cf-1.png", "DSC01584": "DSC01584-swift-cf.png"}


def spread(colours, weights, sigma):
    """Each pixel's mean colour of the weighted region near it (normalised Gaussian)."""
    total = ndimage.gaussian_filter(weights, sigma)
    out = np.stack([ndimage.gaussian_filter(colours[..., c] * weights, sigma) for c in range(3)], -1)
    return out / np.maximum(total, 1e-6)[..., None], total


def colour_share(image, tri, sigma):
    """The pixel's share of the way from its background colour to its person colour, and how far
    apart those two colours are."""
    background, _ = spread(image, (tri == 0).astype(np.float32), sigma)
    person, _ = spread(image, (tri == 1).astype(np.float32), sigma)
    span = person - background
    length = (span ** 2).sum(-1)
    share = np.clip(((image - background) * span).sum(-1) / np.maximum(length, 1e-6), 0, 1)
    return share, np.sqrt(length)


def main():
    rows = {}
    for name, mask_name in PORTRAITS.items():
        image = Image.open(WORK / f"{name}.jpg").convert("RGB")
        array = np.asarray(image, np.float32) / 255
        long = max(image.size)
        coarse = np.asarray(Image.open(WORK / mask_name).convert("L").resize(image.size, Image.BILINEAR), np.float32) / 255
        tri = trimap(coarse)
        wide = trimap(coarse, inner=0.012, outer=0.035)
        truth = np.asarray(Image.open(WORK / f"{name}-vitmatte-open.png").convert("L"), np.float32) / 255
        matte = np.asarray(Image.open(WORK / MATTES[name]).convert("L").resize(image.size, Image.BILINEAR), np.float32) / 255
        unknown = wide == 0.5
        strands = unknown & (coarse < 0.5) & (truth > 0.1) & (truth < 0.9)
        halo = unknown & (truth < 0.02)
        candidates = {"closed-form": matte}
        share, apart = colour_share(array, tri, 0.01 * long)
        trust = np.clip(apart / 0.1, 0, 1)
        lowered = matte - trust * np.maximum(matte - share, 0)
        candidates["down to share"] = np.where(tri == 0.5, lowered, matte)
        # Only what is all but background: a strand's share is small but not nothing.
        for low, high in ((0.02, 0.1), (0.03, 0.15), (0.05, 0.2)):
            keep = np.clip((share - low) / (high - low), 0, 1)
            vetoed = matte * (1 - trust * (1 - keep))
            candidates[f"veto {low}-{high}"] = np.where(tri == 0.5, vetoed, matte)
        for label, alpha in candidates.items():
            mae = float(np.abs(alpha - truth)[unknown].mean())
            kept = float((alpha[strands] > 0.1).mean())
            fog = float(alpha[halo].mean())
            rows.setdefault(label, []).append((mae, kept, fog))
            print(f"{name} {label:22s} MAE {mae:.4f} strands {kept:.2f} halo {fog:.4f}", flush=True)
            if label != "closed-form":
                Image.fromarray((alpha * 255).astype(np.uint8)).save(WORK / f"{name}-halo-{label.replace(' ', '_')}.png")
    print("\nmean over portraits")
    for label, values in rows.items():
        a = np.array(values)
        print(f"  {label:22s} MAE {a[:, 0].mean():.4f} strands {a[:, 1].mean():.2f} halo {a[:, 2].mean():.4f}")


if __name__ == "__main__":
    main()
