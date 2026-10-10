"""Candidate reconstructions, as NumPy models of what a kernel would do on the mosaic."""
import numpy as np

import cam08


def rim_reference(m: cam08.Mosaic, cfa: np.ndarray, near: float):
    """Unclipped blocks bordering clipped ones whose closest channel to its clip level reaches `near`
    of it: the surface that clipped, seen just short of clipping, whatever the white balance."""
    clipped, means = cam08.blocks(m, cfa)
    rim = cam08.dilate(clipped, 2) & ~clipped
    clip = cam08.clip_levels(m)
    closeness = (means / clip).max(axis=-1)
    chosen = rim & (closeness >= near)
    return clipped, means, chosen


def offsets(reference: np.ndarray) -> np.ndarray:
    """HighlightModel.coefficients from cube-root reference colours (any count over 0)."""
    coefficients = []
    for c in range(3):
        first, second = (c + 1) % 3, (c + 2) % 3
        for observed in ([first, second], [first], [second]):
            offset = float(np.mean(reference[:, c] - reference[:, observed].mean(axis=1))) if len(reference) >= 64 else 0.0
            entry = [offset, 0.0, 0.0, 0.0]
            for o in observed:
                entry[o + 1] = 1 / len(observed)
            coefficients.append(entry)
    return np.array(coefficients, np.float32)


def predict(m: cam08.Mosaic, cfa: np.ndarray, clip: np.ndarray, coefficients: np.ndarray, usable: np.ndarray,
            floor_fully: float, radius: int = 2):
    """The CAM-08 kernel's prediction with a given choice of usable neighbours; returns the new mosaic
    and, per clipped photosite, which colours were observed."""
    own_clip = clip[m.colors]
    clipped = cfa >= own_clip
    sums, counts = cam08.neighbourhood_means(m, cfa, usable, radius)
    out = cfa.copy()
    ys, xs = np.nonzero(clipped)
    color = m.colors[ys, xs].astype(np.int64)
    first = counts[(color + 1) % 3, ys, xs] > 0
    second = counts[(color + 2) % 3, ys, xs] > 0
    none = ~first & ~second
    which = np.where(first & second, 0, np.where(first, 1, 2))
    coeff = coefficients[color * 3 + which]
    means = np.stack([np.where(counts[k, ys, xs] > 0, sums[k, ys, xs] / np.maximum(counts[k, ys, xs], 1), 0)
                      for k in range(3)], axis=1)
    root = coeff[:, 0] + (coeff[:, 1:] * np.cbrt(means)).sum(axis=1)
    predicted = np.where(root > 0, root ** 3, 0)
    low = clip[color]
    value = np.clip(predicted, low, 4 * low)
    value[none] = floor_fully
    out[ys, xs] = value
    return out, (ys, xs, none)


def candidate_a(m: cam08.Mosaic, cfa: np.ndarray, near: float = 0.0, neighbour: float = 0.5):
    """CAM-08 with brightness judged against the lowest clip level, not each colour's own: a rim block
    counts when every colour reaches half of it (and, with `near`, its closest colour reaches that
    share of its own clip level, as the engine's E8 asks)."""
    clip = cam08.clip_levels(m)
    clipped, means, near_enough = rim_reference(m, cfa, near)
    chosen = near_enough & (means >= neighbour * clip.min()).all(axis=-1)
    coefficients = offsets(np.cbrt(means[chosen]))
    own_clip = clip[m.colors]
    # A neighbour is usable when unclipped and bright next to the photosite being rebuilt; the
    # kernel compares with the clipped photosite's level, so take the lowest clip as the scale.
    usable = (cfa < own_clip) & (cfa >= neighbour * clip.min())
    out, info = predict(m, cfa, clip, coefficients, usable, float(clip.max()))
    return out, {"coefficients": coefficients, "rim": int(chosen.sum())}
