#!/usr/bin/env python3
"""Scores Remove fills on the removal benchmark (INF-14; RM-20, RM-21) from the areas the prototype
CLI on the branch rm-20/fill-prototypes writes (`redlamp render … --dump-areas <folder>`): each
Remove spot's surroundings at full size in the photo's linear camera RGB, before and after, its
shape and the photo's noise model.

    python3 score_removal.py <areas folder> [--truth <areas folder>] [--spot 0] [--json]

Everything is measured in the square root of linear camera RGB, normalised by the area's median
(where shot noise is about the same at every brightness), on luminance:

- sharpness: the energy of three difference-of-Gaussian bands (about 2, 4 and 8 pixels across)
  inside the spot, less what the photo's noise model puts in them, over the same in a ring of the
  photo around it; 1 is as detailed as the surroundings, 0 is flat.
- noise: the noise inside the spot (the finest band's median absolute deviation, in flat places)
  over what the noise model predicts there; the ring's own ratio is given beside it.
- seam: the gradient across the spot's edge (2 pixels either side) over the gradient 10 to 16
  pixels outside it; 1 is no visible edge.
- with a truth (the same spot's areas from the photo without the object): PSNR inside the spot,
  of the whole signal and of its low-pass (a Gaussian of 4 pixels), and each band's energy (less
  the noise model's) over the truth's in the same place, which the content there doesn't sway.
"""

import argparse
import json
import pathlib

import numpy as np
from scipy import ndimage

LUMA = np.array([0.27, 0.67, 0.06], dtype=np.float32)
BANDS = (1.0, 2.0, 4.0)


def read(folder, spot):
    info = json.loads((folder / f"area-{spot}.json").read_text())
    shape = (info["height"], info["width"])
    before = np.fromfile(folder / f"area-{spot}-before.f32", dtype=np.float32).reshape(*shape, 3)
    after = np.fromfile(folder / f"area-{spot}-after.f32", dtype=np.float32).reshape(*shape, 3)
    hole = np.fromfile(folder / f"area-{spot}-hole.u8", dtype=np.uint8).reshape(shape) > 0
    return info, before, after, hole


def band(image, sigma):
    return ndimage.gaussian_filter(image, sigma) - ndimage.gaussian_filter(image, 2 * sigma)


def band_gain(sigma):
    """The sum of the squared kernel: a band's output variance for unit white noise."""
    delta = np.zeros((129, 129), dtype=np.float32)
    delta[64, 64] = 1
    return float((band(delta, sigma) ** 2).sum())


def perceptual(rgb, scale):
    return np.sqrt(np.maximum(rgb, 0) / scale)


def noise_variance(rgb, scale, a, b):
    """The noise model's variance of perceptual luminance (delta method through the square root)."""
    value = np.maximum(rgb, 1e-6)
    variance = (a * value + b) / (4 * value * scale)
    return (variance * LUMA ** 2).sum(-1)


def regions(hole, size):
    inner = ndimage.binary_erosion(hole, iterations=6)
    reach = int(np.clip(0.15 * size, 32, 160))
    outside = ndimage.distance_transform_edt(~hole)
    ring = (outside > 8) & (outside <= 8 + reach)
    inside_distance = ndimage.distance_transform_edt(hole)
    edge = ((outside > 0) & (outside <= 2)) | ((inside_distance > 0) & (inside_distance <= 2))
    control = (outside > 10) & (outside <= 16)
    return inner, ring, edge, control


def score(folder, spot=0, truth=None):
    info, before, after, hole = read(folder, spot)
    a, b = np.array(info["noiseA"], dtype=np.float32), np.array(info["noiseB"], dtype=np.float32)
    ys, xs = np.nonzero(hole)
    size = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1
    scale = float(np.median(before[~hole].mean(-1))) or 1.0
    luma = perceptual(after, scale) @ LUMA
    inner, ring, edge, control = regions(hole, size)
    noise = noise_variance(after, scale, a, b)
    result = {"size": int(size), "area": int(hole.sum())}
    sharp = {}
    for sigma in BANDS:
        response = band(luma, sigma)
        gain = band_gain(sigma)
        energy = lambda where: float((response[where] ** 2).mean() - gain * noise[where].mean())
        inside, around = energy(inner), energy(ring)
        sharp[f"{2 * sigma:g}px"] = round(inside / around, 3) if around > 0 else None
    result["sharpness"] = sharp
    fine = band(luma, 0.5)
    fine_gain = band_gain(0.5)
    texture = ndimage.uniform_filter(band(luma, 2.0) ** 2, 9)

    def measured_noise(where):
        # Flat places: the half of the region with the least texture.
        flat = where & (texture <= np.median(texture[where]))
        sigma = 1.4826 * np.median(np.abs(fine[flat] - np.median(fine[flat])))
        expected = np.sqrt(fine_gain * noise[flat].mean())
        return round(float(sigma / expected), 3)

    result["noise"] = {"spot": measured_noise(inner), "ring": measured_noise(ring)}
    gy, gx = ndimage.sobel(ndimage.gaussian_filter(luma, 1.0), 0), ndimage.sobel(ndimage.gaussian_filter(luma, 1.0), 1)
    gradient = np.hypot(gx, gy)
    result["seam"] = round(float(gradient[edge].mean() / gradient[control].mean()), 3)
    if truth is not None:
        _, true_before, _, true_hole = read(truth, spot)
        if true_hole.shape == hole.shape:
            target = perceptual(true_before, scale) @ LUMA
            where = ndimage.binary_dilation(hole, iterations=4)
            error = (luma - target)[where]
            peak = float(np.percentile(target, 99.5))
            result["psnr"] = round(float(10 * np.log10(peak ** 2 / max((error ** 2).mean(), 1e-12))), 2)
            low = ndimage.gaussian_filter(luma, 4) - ndimage.gaussian_filter(target, 4)
            result["psnrLow"] = round(float(10 * np.log10(peak ** 2 / max((low[where] ** 2).mean(), 1e-12))), 2)
            detail = {}
            for sigma in BANDS:
                response, truth_response = band(luma, sigma), band(target, sigma)
                gain = band_gain(sigma)
                fill_energy = (response[inner] ** 2).mean() - gain * noise[inner].mean()
                truth_energy = (truth_response[inner] ** 2).mean() - gain * noise[inner].mean()
                detail[f"{2 * sigma:g}px"] = round(float(fill_energy / truth_energy), 3) if truth_energy > 0 else None
            result["detailVsTruth"] = detail
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("areas", type=pathlib.Path)
    parser.add_argument("--truth", type=pathlib.Path)
    parser.add_argument("--spot", type=int, default=0)
    args = parser.parse_args()
    print(json.dumps(score(args.areas, args.spot, args.truth), indent=2))


if __name__ == "__main__":
    main()
