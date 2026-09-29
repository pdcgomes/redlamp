"""Compare focus-stack PoC outputs with a reference result and with the sharpest single frame.

Writes a contact sheet of matching crops and prints a no-reference sharpness score
(mean Tenengrad on luma) plus PSNR/SSIM of each result against the reference, after
aligning the reference to our geometry with ECC. Agreement with a reference tool is
not ground truth; it shows whether two independent stackers reach similar results.

Usage:
  compare.py RESULT_DIR --frames FRAME_DIR [--reference expected.jpg] [--crop x,y,size]...
"""

import argparse
import json
import pathlib

import cv2
import numpy as np
from skimage.metrics import structural_similarity


def luma(img):
    return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0


def tenengrad(img):
    y = luma(img)
    gx, gy = cv2.Sobel(y, cv2.CV_32F, 1, 0), cv2.Sobel(y, cv2.CV_32F, 0, 1)
    return float(np.mean(gx * gx + gy * gy))


def align_to(target, moving):
    warp = np.eye(2, 3, dtype=np.float32)
    criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 100, 1e-6)
    small = 0.5
    t = cv2.resize(luma(target), None, fx=small, fy=small)
    m = cv2.resize(luma(moving), (t.shape[1], t.shape[0]))
    _, warp = cv2.findTransformECC(t, m, warp, cv2.MOTION_AFFINE, criteria, None, 5)
    warp[:, 2] /= small
    sx, sy = moving.shape[1] / target.shape[1], moving.shape[0] / target.shape[0]
    warp[0, :2] *= sx
    warp[1, :2] *= sy
    return cv2.warpAffine(moving, warp, (target.shape[1], target.shape[0]),
                          flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP, borderMode=cv2.BORDER_REFLECT)


def label(img, text):
    out = img.copy()
    cv2.rectangle(out, (0, 0), (out.shape[1], 26), (0, 0, 0), -1)
    cv2.putText(out, text, (6, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", type=pathlib.Path)
    ap.add_argument("--frames", type=pathlib.Path, required=True)
    ap.add_argument("--reference", type=pathlib.Path)
    ap.add_argument("--crop", action="append", default=[], help="x,y,size in result pixels")
    args = ap.parse_args()

    images = {name: cv2.imread(str(args.results / f"fused-{name}.png")) for name in ("smooth", "detail", "auto")}
    height, width = images["auto"].shape[:2]
    frames = sorted(p for p in args.frames.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
                    and p.stem.lower() != "expected")
    singles = [cv2.resize(cv2.imread(str(p)), (width, height), interpolation=cv2.INTER_AREA) for p in frames]
    best = max(range(len(singles)), key=lambda i: tenengrad(singles[i]))
    panels = {f"best single frame ({best})": singles[best], **images}
    if args.reference:
        panels["reference tool"] = align_to(images["auto"], cv2.imread(str(args.reference)))

    metrics = {}
    for name, img in panels.items():
        row = {"tenengrad": round(tenengrad(img) * 1000, 3)}
        if args.reference and name != "reference tool":
            ref = panels["reference tool"]
            margin = 32
            a, b = img[margin:-margin, margin:-margin], ref[margin:-margin, margin:-margin]
            mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
            row["psnrVsReference"] = round(10 * np.log10(255 ** 2 / mse), 2)
            row["ssimVsReference"] = round(float(structural_similarity(luma(a), luma(b), data_range=1.0)), 4)
        metrics[name] = row

    crops = [tuple(int(v) for v in c.split(",")) for c in args.crop] or [(width // 2 - 200, height // 2 - 200, 400)]
    rows = []
    for x, y, size in crops:
        tiles = [label(cv2.resize(img[y:y + size, x:x + size], (400, 400), interpolation=cv2.INTER_NEAREST), name)
                 for name, img in panels.items()]
        rows.append(np.hstack(tiles))
    depth = cv2.imread(str(args.results / "depth.png"))
    overview = np.hstack([label(cv2.resize(images["auto"], (533, 400)), "auto (full frame)"),
                          label(cv2.resize(depth, (533, 400)), "depth map")])
    pad = np.zeros((400, rows[0].shape[1] - overview.shape[1], 3), np.uint8)
    sheet = np.vstack([np.hstack([overview, pad])] + rows)
    cv2.imwrite(str(args.results / "comparison.jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 90])
    (args.results / "comparison.json").write_text(json.dumps(metrics, indent=2))
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
