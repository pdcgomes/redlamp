"""Measures engine renders of a raw: per class of clipped colours, the mean colour and its OKLab
chroma and hue; how sharply colour changes where clipped areas meet each other or unclipped sky
(the band); and, against a reference render, how much the rest of the photo moved.

Usage: measure.py <raw> <render.tif> [<reference.tif>]"""
import json
import sys

import numpy as np
import rawpy
import tifffile
from scipy import ndimage

import cam08

NAMES = {1: "R", 2: "G", 3: "RG", 4: "B", 5: "RB", 6: "GB", 7: "RGB"}
SRGB_TO_XYZ = cam08.XYZ_RGB


def decode(path):
    image = tifffile.imread(path).astype(np.float64) / 65535
    image = image[..., :3]
    return np.where(image <= 0.04045, image / 12.92, ((image + 0.055) / 1.055) ** 2.4)


def oklab_from_linear_srgb(rgb):
    lms = np.cbrt(np.maximum((rgb @ SRGB_TO_XYZ.T) @ cam08.XYZ_TO_LMS.T, 0))
    return lms @ cam08.LMS_TO_LAB.T


def class_map(raw_path, shape):
    """Each render pixel's class of clipped colours (0 none), oriented as the render."""
    m = cam08.load(raw_path)
    bits = cam08.clipped_channels(m)
    with rawpy.imread(raw_path) as r:
        flip = r.sizes.flip
    if flip == 3:
        bits = bits[::-1, ::-1]
    elif flip == 5:
        bits = np.rot90(bits, 1)
    elif flip == 6:
        bits = np.rot90(bits, -1)
    h, w = shape
    ys = np.minimum(((np.arange(h) + 0.5) * bits.shape[0] / h).astype(int), bits.shape[0] - 1)
    xs = np.minimum(((np.arange(w) + 0.5) * bits.shape[1] / w).astype(int), bits.shape[1] - 1)
    # A render pixel takes the most clipped class among the blocks it covers.
    scale_y, scale_x = bits.shape[0] / h, bits.shape[1] / w
    grown = ndimage.maximum_filter(bits, size=(max(1, int(np.ceil(scale_y))), max(1, int(np.ceil(scale_x)))))
    return grown[np.ix_(ys, xs)], bits


def measure(raw_path, render_path, reference_path=None):
    linear = decode(render_path)
    lab = oklab_from_linear_srgb(linear)
    classes, _ = class_map(raw_path, linear.shape[:2])
    clipped = classes > 0
    result = {"render": render_path, "classes": {}}
    inside = ndimage.binary_erosion(clipped, iterations=4)
    for bit, name in NAMES.items():
        sel = (classes == bit) & ndimage.binary_erosion(classes == bit, iterations=3)
        if sel.sum() < 200:
            continue
        srgb = np.clip(tifffile.imread(render_path)[..., :3][sel].astype(np.float64) / 65535 * 255, 0, 255)
        l, a, b = lab[sel].T
        chroma = np.hypot(a, b)
        result["classes"][name] = {
            "pixels": int(sel.sum()),
            "srgb8": [round(float(v), 1) for v in srgb.mean(axis=0)],
            "L": round(float(l.mean()), 3),
            "chroma_mean": round(float(chroma.mean()), 4),
            "chroma_p95": round(float(np.percentile(chroma, 95)), 4),
            "hue": round(float(np.degrees(np.arctan2(b.mean(), a.mean()))), 1),
        }
    # The band: the steepest change of colour (OKLab a and b, x 100 per 10 render pixels) on bright,
    # flat ground near the edges of clipped areas, against the same on unclipped bright ground.
    smooth = ndimage.gaussian_filter(lab, sigma=(2, 2, 0))
    ga = np.hypot(ndimage.sobel(smooth[..., 1], 0), ndimage.sobel(smooth[..., 1], 1)) / 8
    gb = np.hypot(ndimage.sobel(smooth[..., 2], 0), ndimage.sobel(smooth[..., 2], 1)) / 8
    gradient = np.hypot(ga, gb) * 100 * 10
    bright = ndimage.minimum_filter(lab[..., 0], size=9) > 0.55
    flat = ndimage.maximum_filter(lab[..., 0], size=9) - ndimage.minimum_filter(lab[..., 0], size=9) < 0.08
    edges = np.zeros_like(clipped)
    for axis in (0, 1):
        change = np.diff(classes, axis=axis) != 0
        if axis == 0:
            edges[1:] |= change
            edges[:-1] |= change
        else:
            edges[:, 1:] |= change
            edges[:, :-1] |= change
    near_edges = ndimage.binary_dilation(edges, iterations=12) & bright & flat
    far_sky = ~ndimage.binary_dilation(clipped, iterations=24) & bright & flat
    result["band"] = {
        "edge_pixels": int(near_edges.sum()),
        "edge_gradient_p99": round(float(np.percentile(gradient[near_edges], 99)), 3) if near_edges.any() else None,
        "edge_gradient_max": round(float(gradient[near_edges].max()), 3) if near_edges.any() else None,
        "unclipped_gradient_p99": round(float(np.percentile(gradient[far_sky], 99)), 3) if far_sky.sum() > 500 else None,
    }
    if reference_path:
        other = oklab_from_linear_srgb(decode(reference_path))
        delta = np.linalg.norm(lab - other, axis=-1) * 100
        away = ~ndimage.binary_dilation(clipped, iterations=6)
        unclipped_bright = away & (other[..., 0] > 0.85)
        result["elsewhere"] = {
            "pixels": int(away.sum()),
            "delta_mean": round(float(delta[away].mean()), 4),
            "delta_max": round(float(delta[away].max()), 3),
            "share_over_0.5": round(float((delta[away] > 0.5).mean()), 6),
            "bright_unclipped_pixels": int(unclipped_bright.sum()),
            "bright_unclipped_delta_max": round(float(delta[unclipped_bright].max()), 3) if unclipped_bright.any() else None,
        }
        result["clipped_delta_mean"] = round(float(delta[clipped].mean()), 3) if clipped.any() else None
    return result


if __name__ == "__main__":
    print(json.dumps(measure(*sys.argv[1:]), indent=1))
