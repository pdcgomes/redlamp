"""Scores every render under build/proto-out/raw-denoise/renders against the scene's truth.

All images are balanced camera RGB, SIZE x SIZE, float32. Errors are measured in a square-root
encoding (roughly perceptual, as NoiseBenchmarkTests does) with 16 px borders left out.

- cpsnr / psnr_luma / ssim: fidelity to the truth
- texture: how much of the truth's fine luma detail (a 3 x 3 high-pass) survives, 1 = all
- edge MTF50, MTF at Nyquist: ISO 12233-style slanted-edge e-SFR on the edge scene, cycles/pixel
- star MTF50: where the Siemens star's 72-cycle modulation falls to half of its value at the rim
- false colour: mean chroma error where the truth is neutral (zone plate between 0.25 and 0.5
  cycles/pixel; the star)
- flat noise: luma and chroma noise in the text scene's grey patch, and their coarseness
  (the noise's 4 x 4 box average times 4 over its own size: 1 for white noise, more for blotches)
- shadow bias: the dark patch's mean colour against the truth's, as a chroma distance

Writes scores.json and summary.md in build/proto-out/raw-denoise.
"""

import json
from pathlib import Path

import numpy as np
from scipy.ndimage import uniform_filter
from skimage.metrics import structural_similarity

from common import OUT, SIZE, TESTSET, load_rgb, read_json

B = 16


def enc(x):
    return np.sqrt(np.clip(x, 0, None))


def luma(x):
    return x.mean(-1)


def chroma(e):
    return np.stack([e[..., 0] - e[..., 1], e[..., 2] - e[..., 1]], -1)


def fidelity(img, truth):
    a, b = enc(img)[B:-B, B:-B], enc(truth)[B:-B, B:-B]
    mse = np.mean((a - b) ** 2)
    la, lb = luma(a), luma(b)
    hp = lambda x: x - uniform_filter(x, 3)
    ha, hb = hp(la), hp(lb)
    return {
        "cpsnr": float(10 * np.log10(1 / max(mse, 1e-12))),
        "psnr_luma": float(10 * np.log10(1 / max(np.mean((la - lb) ** 2), 1e-12))),
        "ssim": float(structural_similarity(la, lb, data_range=1.0)),
        "texture": float(np.sum(ha * hb) / max(np.sum(hb * hb), 1e-12)),
    }


def edge_mtf(img):
    """Slanted edge at 5 degrees through the centre (make_testset.slanted_edge)."""
    lum = luma(img)
    angle = np.deg2rad(5)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE] + 0.5
    c = SIZE / 2
    distance = (xx - c) * np.cos(angle) + (yy - c) * np.sin(angle)
    rows = slice(160, SIZE - 160)
    d, v = distance[rows].ravel(), lum[rows].ravel()
    keep = np.abs(d) < 16
    d, v = d[keep], v[keep]
    bins = np.round((d + 16) * 4).astype(int)
    esf = np.bincount(bins, v, minlength=129) / np.maximum(np.bincount(bins, minlength=129), 1)
    lsf = np.diff(esf) * np.hamming(len(esf) - 1)
    spectrum = np.abs(np.fft.rfft(lsf, 1024))
    spectrum /= spectrum[0]
    freq = np.fft.rfftfreq(1024, d=0.25)
    below = np.nonzero(spectrum < 0.5)[0]
    i = below[0] if len(below) else len(freq) - 1
    mtf50 = float(np.interp(0.5, [spectrum[i], spectrum[i - 1]], [freq[i], freq[i - 1]]))
    return {"edge_mtf50": mtf50, "edge_mtf_nyquist": float(np.interp(0.5, freq, spectrum))}


def star_modulation(img, cycles=72):
    lum = luma(img)
    c = SIZE / 2
    theta = np.linspace(0, 2 * np.pi, 4096, endpoint=False)
    radii = np.arange(12, 372, 2.0)
    amp = []
    for r in radii:
        x, y = c + r * np.cos(theta) - 0.5, c + r * np.sin(theta) - 0.5
        xi, yi = np.clip(x.round().astype(int), 0, SIZE - 1), np.clip(y.round().astype(int), 0, SIZE - 1)
        samples = lum[yi, xi]
        amp.append(np.abs(np.sum(samples * np.exp(-1j * cycles * theta))) / len(theta))
    amp = np.array(amp) / np.mean(amp[-10:])
    freq = cycles / (2 * np.pi * radii)
    # From the rim inwards, the first frequency where the modulation falls below a half.
    order = np.argsort(freq)
    f, m = freq[order], amp[order]
    below = np.nonzero(m < 0.5)[0]
    mtf50 = float(f[below[0]]) if len(below) else float(f[-1])
    return {"star_mtf50": mtf50}


def false_colour(img, truth, mask):
    e = chroma(enc(img)) - chroma(enc(truth))
    return float(np.mean(np.linalg.norm(e[mask], axis=-1)))


def ring_mask(r0, r1):
    yy, xx = np.mgrid[0:SIZE, 0:SIZE] + 0.5
    r = np.hypot(xx - SIZE / 2, yy - SIZE / 2)
    return (r >= r0) & (r < r1)


def flat_noise(img, truth, box):
    x0, y0, x1, y1 = box
    n = enc(img)[y0:y1, x0:x1] - enc(truth)[y0:y1, x0:x1]
    nl, nc = luma(n), chroma(n)
    coarse = lambda z: float(np.std(uniform_filter(z, 4)) * 4 / max(np.std(z), 1e-12))
    return {
        "flat_luma_noise": float(np.std(nl)),
        "flat_chroma_noise": float(np.mean(np.std(nc, axis=(0, 1)))),
        "flat_luma_coarseness": coarse(nl),
        "flat_chroma_coarseness": float(np.mean([coarse(nc[..., 0]), coarse(nc[..., 1])])),
    }


def shadow_bias(img, truth, box):
    x0, y0, x1, y1 = box
    m = enc(img)[y0:y1, x0:x1].reshape(-1, 3).mean(0)
    t = enc(truth)[y0:y1, x0:x1].reshape(-1, 3).mean(0)
    return {"shadow_bias": float(np.linalg.norm(chroma(m[None]) - chroma(t[None]))),
            "shadow_level": float(luma(m[None])[0] - luma(t[None])[0])}


def score_one(scene, img, truth, regions):
    s = fidelity(img, truth)
    if scene == "edge":
        s.update(edge_mtf(img))
    if scene == "star":
        s.update(star_modulation(img))
        s["false_colour"] = false_colour(img, truth, ring_mask(40, 370))
    if scene == "zone":
        s["false_colour"] = false_colour(img, truth, ring_mask(192, 384))
        s["false_colour_mid"] = false_colour(img, truth, ring_mask(96, 192))
    if scene == "text":
        s.update(flat_noise(img, truth, regions["text"]["flat"]))
        s.update(shadow_bias(img, truth, regions["text"]["dark"]))
    return s


def main():
    manifest = read_json(TESTSET / "manifest.json")
    regions = manifest["regions"]
    scores = []
    for scene in manifest["scenes"]:
        truth = load_rgb(TESTSET / scene / "truth.f32", SIZE, SIZE)
        scores.append({"scene": scene, "cfa": "-", "level": "-", "method": "truth",
                       **score_one(scene, truth, truth, regions)})
        for path in sorted((OUT / "renders" / scene).rglob("*.f32")):
            if path.name.endswith(".mosaic.f32"):
                continue
            parts = path.relative_to(OUT / "renders" / scene).parts
            cfa = parts[0]
            level = parts[1] if len(parts) == 3 else "clean"
            img = load_rgb(path, SIZE, SIZE)
            scores.append({"scene": scene, "cfa": cfa, "level": level, "method": path.stem,
                           **score_one(scene, img, truth, regions)})
    (OUT / "scores.json").write_text(json.dumps(scores, indent=1))
    print(f"{len(scores)} scores")


if __name__ == "__main__":
    main()
