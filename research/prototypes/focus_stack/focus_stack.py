"""Classical focus-stacking proof of concept (research only; the product version is Metal).

Pipeline (see docs/research/ai-findings.md, focus stacking):
  1. Chained ECC alignment (affine) on low-resolution luma, referenced to the narrowest-view end,
     then refined directly against the reference; per-channel gain fit in linear light.
  2. Focus volume: sum-modified-Laplacian on encoded luma at 1/4 resolution.
  3. Depth solve: guided-filter cost-volume regularization, argmax, parabolic sub-frame refinement,
     low-confidence fill from a coarser solve.
  4. Streaming fusion, one frame in memory at a time:
       smooth  depth map: tent-weighted blend of the two frames around the fractional depth
       detail  Laplacian pyramid, max region-energy selection per level, averaged base
       auto    pyramid selection constrained to +/- window frames of the depth estimate, released
               when an out-of-window frame is tau times more salient; depth-map coefficients at
               coarse levels and where fine-level saliency is below the noise floor (grit suppression)

Usage:
  build/research-venv/bin/python research/prototypes/focus_stack/focus_stack.py FRAME_DIR --out OUT_DIR
"""

import argparse
import json
import pathlib
import time

import cv2
import numpy as np

LUMA = np.array([0.0722, 0.7152, 0.2126], dtype=np.float32)  # BGR order


def srgb_to_linear(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).astype(np.float32)


def linear_to_srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def load(path: pathlib.Path, max_size: int | None) -> np.ndarray:
    img = cv2.imread(str(path), cv2.IMREAD_COLOR).astype(np.float32) / 255.0
    if max_size and max(img.shape[:2]) > max_size:
        scale = max_size / max(img.shape[:2])
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    return img


def encoded_luma(bgr_srgb: np.ndarray) -> np.ndarray:
    return bgr_srgb @ LUMA


def guided_filter(guide: np.ndarray, src: np.ndarray, radius: int, eps: float) -> np.ndarray:
    """He, Sun and Tang (TPAMI 2013), single-channel guide."""
    k = (2 * radius + 1, 2 * radius + 1)
    mean = lambda a: cv2.boxFilter(a, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    mean_i, mean_p = mean(guide), mean(src)
    cov_ip = mean(guide * src) - mean_i * mean_p
    var_i = mean(guide * guide) - mean_i * mean_i
    a = cov_ip / (var_i + eps)
    b = mean_p - a * mean_i
    return mean(a) * guide + mean(b)


def sml(luma: np.ndarray, radius: int) -> np.ndarray:
    """Sum-modified-Laplacian (Nayar and Nakagawa 1994) over a (2r+1)^2 window."""
    kx = np.array([[-1, 2, -1]], dtype=np.float32)
    ml = np.abs(cv2.filter2D(luma, -1, kx)) + np.abs(cv2.filter2D(luma, -1, kx.T))
    return cv2.boxFilter(ml, -1, (2 * radius + 1, 2 * radius + 1), normalize=True)


def as3x3(m: np.ndarray) -> np.ndarray:
    return np.vstack([m, [0, 0, 1]]).astype(np.float64)


def ecc(template: np.ndarray, image: np.ndarray, init: np.ndarray) -> tuple[np.ndarray, float]:
    """Affine warp W with image(W x) ~ template(x), coarse to fine over 3 levels."""
    warp = init.astype(np.float32)[:2].copy()
    criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 60, 1e-5)
    levels = [(cv2.resize(template, None, fx=s, fy=s, interpolation=cv2.INTER_AREA),
               cv2.resize(image, None, fx=s, fy=s, interpolation=cv2.INTER_AREA), s) for s in (0.25, 0.5, 1.0)]
    rho = 0.0
    for t, i, s in levels:
        w = warp.copy()
        w[:, 2] *= s
        try:
            rho, w = cv2.findTransformECC(t, i, w, cv2.MOTION_AFFINE, criteria, None, 5)
        except cv2.error:
            return init, 0.0
        w[:, 2] /= s
        warp = w
    return as3x3(warp), float(rho)


def laplacian_pyramid(img: np.ndarray, levels: int) -> list[np.ndarray]:
    pyr, cur = [], img
    for _ in range(levels):
        down = cv2.pyrDown(cur)
        pyr.append(cur - cv2.pyrUp(down, dstsize=(cur.shape[1], cur.shape[0])))
        cur = down
    pyr.append(cur)
    return pyr


def collapse(pyr: list[np.ndarray]) -> np.ndarray:
    cur = pyr[-1]
    for lap in reversed(pyr[:-1]):
        cur = cv2.pyrUp(cur, dstsize=(lap.shape[1], lap.shape[0])) + lap
    return cur


def saliency(coef: np.ndarray) -> np.ndarray:
    y = coef @ LUMA
    return cv2.GaussianBlur(y * y, (3, 3), 1.0)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", type=pathlib.Path)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--max-size", type=int, default=None, help="downscale long edge (speed)")
    ap.add_argument("--radius", type=int, default=5, help="focus window radius at full resolution")
    ap.add_argument("--smoothing", type=int, default=8, help="guided filter radius at 1/4 resolution")
    ap.add_argument("--window", type=float, default=2.0, help="Auto: constraint window in frames")
    ap.add_argument("--tau", type=float, default=1.5, help="Auto: release ratio for out-of-window detail")
    ap.add_argument("--noise-k", type=float, default=3.0, help="grit suppression threshold in sigma")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    paths = sorted(p for p in args.frames.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
                   and p.stem.lower() != "expected")
    timings: dict[str, float] = {}
    t_all = time.perf_counter()

    # Pass 1: low-resolution analysis and alignment.
    t0 = time.perf_counter()
    first = load(paths[0], args.max_size)
    height, width = first.shape[:2]
    align_scale = min(1.0, 1536 / max(height, width))
    low = lambda img: cv2.resize(encoded_luma(img), None, fx=align_scale, fy=align_scale, interpolation=cv2.INTER_AREA)
    lumas_align = [low(first)]
    chain = [np.eye(3)]  # maps frame-0 coords to frame-i coords (alignment resolution)
    rhos = [1.0]
    for p in paths[1:]:
        lumas_align.append(low(load(p, args.max_size)))
        w, rho = ecc(lumas_align[-2], lumas_align[-1], np.eye(3))
        chain.append(w @ chain[-1])
        rhos.append(rho)
    # Reference = narrowest field of view: the end whose content appears largest.
    det_last = np.linalg.det(chain[-1][:2, :2])
    ref = 0 if det_last < 1 else len(paths) - 1
    to_ref = np.linalg.inv(chain[ref])
    transforms = [c @ to_ref for c in chain]  # reference coords -> frame-i coords
    refined = 0
    for i in range(len(paths)):
        if i == ref:
            continue
        w, rho = ecc(lumas_align[ref], lumas_align[i], transforms[i])
        if rho > 0.85:
            transforms[i], refined = w, refined + 1
    s = np.diag([align_scale, align_scale, 1.0])
    full_transforms = [np.linalg.inv(s) @ t @ s for t in transforms]
    timings["align"] = time.perf_counter() - t0

    # Focus volume at 1/4 resolution plus photometric gains, reading each frame once more.
    t0 = time.perf_counter()
    q = 0.25
    qh, qw = int(height * q), int(width * q)
    ref_img = load(paths[ref], args.max_size)
    ref_lin = srgb_to_linear(ref_img)
    mid = (ref_lin > 0.05) & (ref_lin < 0.9)
    volume = np.zeros((len(paths), qh, qw), np.float32)
    lumas_q = np.zeros_like(volume)
    gains = []
    r_q = max(1, round(args.radius * q))
    for i, p in enumerate(paths):
        img = cv2.warpAffine(load(p, args.max_size), full_transforms[i][:2], (width, height),
                             flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP, borderMode=cv2.BORDER_REFLECT)
        lin = srgb_to_linear(img)
        gain = np.array([np.median(ref_lin[..., c][mid[..., c]] / np.maximum(lin[..., c][mid[..., c]], 1e-4))
                         for c in range(3)], dtype=np.float32)
        gains.append(np.clip(gain, 0.8, 1.25))
        lq = cv2.resize(encoded_luma(img), (qw, qh), interpolation=cv2.INTER_AREA)
        lumas_q[i] = lq
        volume[i] = sml(lq, r_q)
    timings["focusVolume"] = time.perf_counter() - t0

    # Depth solve.
    t0 = time.perf_counter()
    raw_idx = np.argmax(volume, axis=0)
    guide = np.take_along_axis(lumas_q, raw_idx[None], axis=0)[0]
    eps = 1e-3 * float(volume.max()) ** 2
    fine = np.stack([guided_filter(guide, v, args.smoothing, eps) for v in volume])
    coarse = np.stack([guided_filter(guide, v, args.smoothing * 4, eps) for v in volume])

    def solve(cost):
        idx = np.argmax(cost, axis=0)
        n = cost.shape[0]
        lo, hi = np.clip(idx - 1, 0, n - 1), np.clip(idx + 1, 0, n - 1)
        c0 = np.take_along_axis(cost, lo[None], 0)[0]
        c1 = np.take_along_axis(cost, idx[None], 0)[0]
        c2 = np.take_along_axis(cost, hi[None], 0)[0]
        denom = c0 - 2 * c1 + c2
        offset = np.where(np.abs(denom) > 1e-12, 0.5 * (c0 - c2) / denom, 0.0)
        return np.clip(idx + np.clip(offset, -0.5, 0.5), 0, n - 1).astype(np.float32)

    peak = fine.max(axis=0)
    noise_floor = float(np.median(volume))
    confidence = (peak - fine.mean(axis=0)) / (peak + 1e-12)
    confident = (peak > 2 * noise_floor) & (confidence > 0.15)
    depth_q = np.where(confident, solve(fine), solve(coarse))
    depth = cv2.resize(depth_q, (width, height), interpolation=cv2.INTER_LINEAR)
    timings["depthSolve"] = time.perf_counter() - t0

    # Pass 2: streaming full-resolution fusion.
    t0 = time.perf_counter()
    levels = max(3, int(np.floor(np.log2(min(height, width)))) - 5)
    coarse_from = levels - 2  # the two coarsest detail levels come from the depth map
    ref_pyr = laplacian_pyramid(ref_lin, levels)
    sigma = float(np.median(np.abs(ref_pyr[0] @ LUMA)) / 0.6745)
    grit = (args.noise_k * sigma) ** 2
    shapes = [lvl.shape for lvl in ref_pyr]
    depth_lv = [cv2.resize(depth, (sh[1], sh[0]), interpolation=cv2.INTER_LINEAR) for sh in shapes]
    smooth_img = np.zeros_like(ref_lin)
    tent_pyr = [np.zeros(sh, np.float32) for sh in shapes]
    det_c = [np.zeros(sh, np.float32) for sh in shapes[:-1]]
    det_s = [np.full(sh[:2], -1.0, np.float32) for sh in shapes[:-1]]
    in_c = [np.zeros(sh, np.float32) for sh in shapes[:-1]]
    in_s = [np.full(sh[:2], -1.0, np.float32) for sh in shapes[:-1]]
    out_c = [np.zeros(sh, np.float32) for sh in shapes[:-1]]
    out_s = [np.full(sh[:2], -1.0, np.float32) for sh in shapes[:-1]]
    base_sum = np.zeros(shapes[-1], np.float32)
    for i, p in enumerate(paths):
        img = cv2.warpAffine(load(p, args.max_size), full_transforms[i][:2], (width, height),
                             flags=cv2.INTER_LANCZOS4 | cv2.WARP_INVERSE_MAP, borderMode=cv2.BORDER_REFLECT)
        lin = srgb_to_linear(np.clip(img, 0, 1)) * gains[i]
        tent = np.maximum(0.0, 1.0 - np.abs(depth - i))[..., None]
        smooth_img += tent * lin
        pyr = laplacian_pyramid(lin, levels)
        base_sum += pyr[-1]
        for lv in range(levels + 1):
            t = np.maximum(0.0, 1.0 - np.abs(depth_lv[lv] - i))[..., None]
            tent_pyr[lv] += t * pyr[lv]
        for lv in range(levels):
            sal = saliency(pyr[lv])
            better = sal > det_s[lv]
            det_c[lv][better], det_s[lv][better] = pyr[lv][better], sal[better]
            inside = np.abs(depth_lv[lv] - i) <= args.window
            b_in = inside & (sal > in_s[lv])
            in_c[lv][b_in], in_s[lv][b_in] = pyr[lv][b_in], sal[b_in]
            b_out = ~inside & (sal > out_s[lv])
            out_c[lv][b_out], out_s[lv][b_out] = pyr[lv][b_out], sal[b_out]
    n = len(paths)
    detail_pyr = det_c + [base_sum / n]
    auto_pyr = []
    for lv in range(levels):
        if lv >= coarse_from:
            auto_pyr.append(tent_pyr[lv])
            continue
        release = (out_s[lv] > args.tau * in_s[lv])[..., None]
        chosen = np.where(release, out_c[lv], in_c[lv])
        if lv <= 1:
            best = np.maximum(in_s[lv], out_s[lv])[..., None]
            chosen = np.where(best < grit, tent_pyr[lv], chosen)
        auto_pyr.append(chosen)
    auto_pyr.append(tent_pyr[-1])
    results = {"smooth": smooth_img, "detail": collapse(detail_pyr), "auto": collapse(auto_pyr)}
    timings["fusion"] = time.perf_counter() - t0
    timings["total"] = time.perf_counter() - t_all

    for name, lin in results.items():
        cv2.imwrite(str(args.out / f"fused-{name}.png"), (linear_to_srgb(lin) * 255 + 0.5).astype(np.uint8))
    depth_vis = cv2.applyColorMap((depth / max(1, n - 1) * 255).astype(np.uint8), cv2.COLORMAP_TURBO)
    cv2.imwrite(str(args.out / "depth.png"), depth_vis)
    report = {
        "frames": n, "size": [width, height], "reference": ref, "pyramidLevels": levels,
        "alignment": {"model": "affine", "refinedAgainstReference": refined,
                      "minChainedECC": round(min(rhos), 3),
                      "maxScaleChange": round(float(max(abs(np.sqrt(abs(np.linalg.det(t[:2, :2]))) - 1)
                                                        for t in full_transforms)), 4)},
        "confidentDepthFraction": round(float(confident.mean()), 3),
        "timingsSeconds": {k: round(v, 2) for k, v in timings.items()},
        "params": vars(args) | {"frames": str(args.frames), "out": str(args.out)},
    }
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
