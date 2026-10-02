#!/usr/bin/env python3
"""Closed-form matting (Levin, Lischinski and Weiss, 2008) without building its matrix, as
CFMatte.swift does it: the matting Laplacian applied through 3x3 box filters (He, Sun and Tang,
2010), conjugate gradients over the unknown pixels only, preconditioned by the Laplacian's
diagonal, started from the coarse mask.

For a window k of 3x3 pixels with colour mean mu_k and covariance S_k,
    D_k = (S_k + eps/9 I)^-1
and for any field p
    a_k = D_k (mean_k(I p) - mu_k mean_k(p)),   b_k = mean_k(p) - a_k . mu_k
    (L p)_i = 9 p_i - sum over the 9 windows k containing i of (a_k . I_i + b_k).

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/cf_matte.py
compares it with pymatting's closed-form solve on the portraits.
"""

import time

import numpy as np
from scipy import ndimage


def box3(x):
    """Sum over each 3x3 window (edges replicated), per channel."""
    size = (3, 3) + (1,) * (x.ndim - 2)
    return ndimage.uniform_filter(x, size=size, mode="nearest") * 9


class Laplacian:
    def __init__(self, image, eps=1e-5):
        self.image = image.astype(np.float64)
        self.mu = box3(self.image) / 9
        products = self.image[..., :, None] * self.image[..., None, :]
        sigma = box3(products.reshape(products.shape[:2] + (9,))).reshape(products.shape) / 9
        sigma -= self.mu[..., :, None] * self.mu[..., None, :]
        self.delta = np.linalg.inv(sigma + eps / 9 * np.eye(3))
        # The diagonal: sum over windows k containing i of 1 - (1 + d^T D_k d) / 9, d = I_i - mu_k.
        h, w, _ = image.shape
        diagonal = np.zeros((h, w))
        padded_mu = np.pad(self.mu, ((1, 1), (1, 1), (0, 0)), mode="edge")
        padded_delta = np.pad(self.delta, ((1, 1), (1, 1), (0, 0), (0, 0)), mode="edge")
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                mu = padded_mu[1 + dy: 1 + dy + h, 1 + dx: 1 + dx + w]
                delta = padded_delta[1 + dy: 1 + dy + h, 1 + dx: 1 + dx + w]
                d = self.image - mu
                diagonal += 1 - (1 + np.einsum("...i,...ij,...j->...", d, delta, d)) / 9
        self.diagonal = diagonal

    def __call__(self, p):
        mean_p = box3(p) / 9
        mean_ip = box3(self.image * p[..., None]) / 9
        a = np.einsum("...ij,...j->...i", self.delta, mean_ip - self.mu * mean_p[..., None])
        b = mean_p - (a * self.mu).sum(-1)
        return 9 * p - ((box3(a) * self.image).sum(-1) + box3(b))


def solve(image, trimap, initial, eps=1e-5, iterations=400, tolerance=1e-4):
    """`trimap` 0 (background), 1 (subject), 0.5 (unknown); `initial` the coarse mask."""
    laplacian = Laplacian(image, eps)
    unknown = trimap == 0.5
    known = np.where(unknown, 0.0, trimap)
    # L (known + x) = 0 on the unknown pixels: A x = -L known there.
    rhs = -laplacian(known)[unknown]
    def apply(x):
        field = np.zeros(trimap.shape)
        field[unknown] = x
        return laplacian(field)[unknown]
    inverse_diagonal = 1 / np.maximum(laplacian.diagonal[unknown], 1e-6)
    x = initial[unknown].astype(np.float64)
    r = rhs - apply(x)
    z = r * inverse_diagonal
    d = z.copy()
    rz = r @ z
    norm = np.linalg.norm(rhs) + 1e-12
    for iteration in range(iterations):
        q = apply(d)
        step = rz / (d @ q)
        x += step * d
        r -= step * q
        if np.linalg.norm(r) / norm < tolerance:
            break
        z = r * inverse_diagonal
        rz_next = r @ z
        d = z + (rz_next / rz) * d
        rz = rz_next
    out = known.copy()
    out[unknown] = x
    return np.clip(out, 0, 1), iteration + 1


def main():
    import pymatting
    from PIL import Image

    import portrait_bench as pb

    for name, mask in pb.PORTRAITS.items():
        image = Image.open(pb.WORK / f"{name}.jpg").convert("RGB")
        array = np.asarray(image, np.float64) / 255
        coarse = np.asarray(Image.open(pb.WORK / mask).convert("L").resize(image.size, Image.BILINEAR), np.float32) / 255
        tri = pb.trimap(coarse)
        reference = np.clip(pymatting.estimate_alpha_cf(array, tri.astype(np.float64),
                                                        laplacian_kwargs={"epsilon": 1e-5}), 0, 1)
        for iterations in (50, 150, 400):
            started = time.perf_counter()
            alpha, used = solve(array, tri, coarse, iterations=iterations)
            unknown = tri == 0.5
            print(f"{name} {iterations:3d} iterations (used {used}): MAE against pymatting "
                  f"{np.abs(alpha - reference)[unknown].mean():.4f}  {time.perf_counter() - started:.1f} s", flush=True)


if __name__ == "__main__":
    main()
