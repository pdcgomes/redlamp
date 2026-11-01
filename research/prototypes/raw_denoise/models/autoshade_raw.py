"""AutoShade's raw denoiser (v2 weights) on a Bayer mosaic, as its sidecar runs it.

Adapted for internal evaluation from skymanbp/autoshade `python/denoise_raw.py` and `python/denoise.py`
(MIT, Copyright (c) 2026 skymanbp; commit 8f25a8a of 27 October 2026). The steps are the sidecar's:

1. the four half-resolution planes R, G1, G2, B of the normalised mosaic, bounded above at white only;
2. a noise model var = a x + b per plane, given (as the harness gives every method Redlamp's own) or
   measured blind from the frame's flat 32 x 32 blocks, as the sidecar measures it;
3. the generalised Anscombe transform per plane, a noise field measured per 256-sample cell and divided
   out, and one affine into [0, 1] read off the noise model, so the network's sigma is one number;
4. DRUNet-colour (KAIR, MIT; `network_unet.py` and `basicblock.py` at the commits the sidecar pins) with
   the sigma as a fourth channel, on the triplets (R, G1, B) and (R, G2, B); R and B are the mean of
   their two estimates; 512-sample tiles overlapping by 32 with a linear feather;
5. the field multiplied back and the exact unbiased inverse (Makitalo and Foi 2013), clipped to [0, 1].

OpenCV's dilate, box blur and bilinear resize are replaced by their scipy and numpy equivalents, with
the same borders. The sidecar runs float32 on Apple's GPU; `dtype` adds float16 for DN-17's checks.
"""

import importlib.util
import sys
import types
from pathlib import Path

import numpy as np
from scipy.ndimage import binary_dilation, uniform_filter

BLOCK = 32
WHITE_BOX5 = 0.96
TEXTURELESS_SLACK = 1.25
MIN_BLOCKS_PER_PLANE = 50
MIN_BLOCKS_POOLED = 20
BLOCK_VARIANCE_SPREAD = 0.12
UNIDENTIFIABLE_SHOT_SHARE = 0.5
SIGMA_SCALE = 1.0
FIELD_CELL = 8
FIELD_POINT_SIGMA = 3.0
FIELD_MIN_KEPT = 0.5
FIELD_MIN_BLOCKS = 8
FIELD_SMOOTH_CELLS = 1.0
FIELD_PRIOR_BLOCKS = 0.5
FIELD_CLAMP = (0.5, 2.0)
PLANES = ("R", "G1", "G2", "B")

WEIGHTS = "autoshade-raw-denoise-v2.pth"
WEIGHTS_SHA256 = "ffafa40a53f52092149db2fcf03636117ad6855e1068142d4f6b03b634e9f9c4"
KAIR = {
    "network_unet.py": ("345c87f8364322c40eef52e575f98af893f04126",
                        "8043b6350f1589d5f08892e3be0b4d12c5a502058014285107b7360696d12bf5"),
    "basicblock.py": ("5d55a5fb88d20eb811dc7ccf6342b921039191cf",
                      "48406db8867394ac5ae233ebeec7711ac10acfc3a6bbf0072c33aa77d659b6fd"),
}


# ----------------------------------------------------------------- planes


def phases(tile):
    """{plane: (row, column)} in a 2 x 2 tile (0 red, 1 green, 2 blue); greens named in raster order."""
    out, g = {}, 0
    for i in range(4):
        y, x = divmod(i, 2)
        c = int(tile[y, x])
        if c == 1:
            g += 1
            out[f"G{g}"] = (y, x)
        else:
            out["R" if c == 0 else "B"] = (y, x)
    if sorted(out) != sorted(PLANES):
        raise ValueError(f"not a Bayer tile: {tile}")
    return out


def split_planes(mosaic, where):
    h2, w2 = mosaic.shape[0] // 2 * 2, mosaic.shape[1] // 2 * 2
    return {n: mosaic[dy:h2:2, dx:w2:2] for n, (dy, dx) in where.items()}


def merge_planes(planes, where, border):
    out = border.copy()
    h2, w2 = border.shape[0] // 2 * 2, border.shape[1] // 2 * 2
    for n, (dy, dx) in where.items():
        out[dy:h2:2, dx:w2:2] = planes[n]
    return out


# ----------------------------------------------------------------- the blind noise model


def _blocks(a, b):
    bh, bw = a.shape[0] // b, a.shape[1] // b
    return a[: bh * b, : bw * b].reshape(bh, b, bw, b).transpose(0, 2, 1, 3)


def _haar_diag(x):
    h, w = x.shape[0] // 2 * 2, x.shape[1] // 2 * 2
    x = x[:h, :w]
    return (x[0::2, 0::2] - x[0::2, 1::2] - x[1::2, 0::2] + x[1::2, 1::2]) / 2.0


def block_statistics(plane):
    m = _blocks(plane, BLOCK).mean(axis=(2, 3))
    d = _blocks(_haar_diag(plane), BLOCK // 2)
    med = np.median(d, axis=(2, 3), keepdims=True)
    mad = np.median(np.abs(d - med), axis=(2, 3)) / 0.6745
    bv = _blocks(plane - uniform_filter(plane, 5, mode="mirror"), BLOCK).var(axis=(2, 3))
    return m, mad ** 2, bv


def physical_model(a, b, means):
    if a > 0.0:
        return a, max(b, 0.0)
    x0 = float(np.mean(means)) if len(means) else 0.0
    var0 = max(a * x0 + b, 0.0)
    if x0 <= 0.0 or var0 <= 0.0:
        return 1e-6, max(b, 0.0)
    return UNIDENTIFIABLE_SHOT_SHARE * var0 / x0, (1.0 - UNIDENTIFIABLE_SHOT_SHARE) * var0


def fit_ab(means, variances):
    m = np.asarray(means, np.float64)
    v = np.asarray(variances, np.float64)
    keep = np.ones(len(m), bool)
    a = b = 0.0
    for _ in range(3):
        design = np.stack([m[keep], np.ones(keep.sum())], axis=1)
        (a, b), *_ = np.linalg.lstsq(design, v[keep], rcond=None)
        expected = np.clip(a * m + b, 1e-12, None)
        refined = keep & ~((v - expected) > 3.0 * BLOCK_VARIANCE_SPREAD * expected)
        if refined.sum() < max(MIN_BLOCKS_POOLED, 2) or np.array_equal(refined, keep):
            break
        keep = refined
    return physical_model(float(a), float(b), m[keep])


def noise_model(planes):
    """{plane: (a, b)} measured from the frame, as the sidecar does; None when it would refuse."""
    samples = {}
    for name, plane in planes.items():
        m, wv, bv = block_statistics(plane.astype(np.float32, copy=False))
        keep = (bv <= TEXTURELESS_SLACK * WHITE_BOX5 * wv) & (m < 0.9)
        samples[name] = (m[keep], wv[keep])
    pooled_m = np.concatenate([s[0] for s in samples.values()])
    pooled_v = np.concatenate([s[1] for s in samples.values()])
    if len(pooled_m) < MIN_BLOCKS_POOLED:
        return None
    pooled = fit_ab(pooled_m, pooled_v)
    return {n: fit_ab(m, v) if len(m) >= MIN_BLOCKS_PER_PLANE else pooled for n, (m, v) in samples.items()}


# ----------------------------------------------------------------- stabilisation and the noise field


def gat(x, a, b):
    return 2.0 * np.sqrt(np.clip(x / a + 3.0 / 8.0 + b / (a * a), 0.0, None))


def igat(z, a, b):
    z = np.clip(z, 1e-3, None)
    ia = (0.25 * z ** 2 + 0.25 * np.sqrt(1.5) / z - (11.0 / 8.0) / z ** 2
          + (5.0 / 8.0) * np.sqrt(1.5) / z ** 3 - 1.0 / 8.0)
    return a * (ia - b / (a * a))


def model_affine(ab):
    hi = max(float(gat(1.0, *ab[n])) for n in PLANES)
    return 0.0, max(hi, 1e-6)


def _haar_bands(x):
    h, w = x.shape[0] // 2 * 2, x.shape[1] // 2 * 2
    a, b, c, e = x[0:h:2, 0:w:2], x[0:h:2, 1:w:2], x[1:h:2, 0:w:2], x[1:h:2, 1:w:2]
    return (a + b + c + e) / 2.0, (a + b - c - e) / 2.0, (a - b + c - e) / 2.0, (a - b - c + e) / 2.0


def _cell_sigma(hh, use):
    q = FIELD_CELL * BLOCK // 2
    cy, cx = -(-hh.shape[0] // q), -(-hh.shape[1] // q)
    grid = np.full((cy * q, cx * q), np.nan, np.float32)
    grid[: hh.shape[0], : hh.shape[1]] = np.where(use, hh, np.nan)
    cells = grid.reshape(cy, q, cx, q).transpose(0, 2, 1, 3).reshape(cy, cx, -1)
    count = np.isfinite(cells).sum(axis=2)
    sigma = np.ones((cy, cx), np.float32)
    some = count > 0
    if some.any():
        v = cells[some]
        sigma[some] = np.nanmedian(np.abs(v - np.nanmedian(v, axis=1, keepdims=True)), axis=1) / 0.6745
    return sigma, count


def measured_cells(z, white):
    q = BLOCK // 2
    ll, lh, hl, hh = (_blocks(band, q) for band in _haar_bands(z))
    bh, bw = hh.shape[:2]
    flat = lambda blocks: blocks.transpose(0, 2, 1, 3).reshape(bh * q, bw * q)
    per_quad = lambda cells: np.repeat(np.repeat(cells, FIELD_CELL * q, 0), FIELD_CELL * q, 1)[: bh * q, : bw * q]
    w = white[: bh * BLOCK, : bw * BLOCK]
    clipped = w[0::2, 0::2] | w[0::2, 1::2] | w[1::2, 0::2] | w[1::2, 1::2]
    hh_q = flat(hh)
    rough, _ = _cell_sigma(hh_q, ~clipped)
    excess = flat(ll - np.median(ll, axis=(2, 3), keepdims=True))
    lit = binary_dilation(excess > FIELD_POINT_SIGMA * per_quad(rough), structure=np.ones((3, 3), bool), border_value=0)
    keep = ~(lit | clipped)
    reference, _ = _cell_sigma(hh_q, keep)
    kept_b = _blocks(keep, q)

    def spread(band):
        v = np.where(kept_b | ~kept_b.any(axis=(2, 3), keepdims=True), np.where(kept_b, band, 0.0), np.nan).reshape(bh, bw, -1)
        return (np.nanmedian(np.abs(v - np.nanmedian(v, axis=2, keepdims=True)), axis=2) / 0.6745) ** 2

    allowed = TEXTURELESS_SLACK * _blocks(per_quad(reference), q)[:, :, 0, 0] ** 2
    admitted = (kept_b.sum(axis=(2, 3)) >= FIELD_MIN_KEPT * q * q) & ((spread(lh) + spread(hl)) / 2.0 <= allowed)
    sigma, count = _cell_sigma(hh_q, keep & np.repeat(np.repeat(admitted, q, 0), q, 1))
    return sigma, count.astype(np.float32) / float(q * q)


def noise_field(z, white):
    sigma, blocks_worth = measured_cells(z, white)
    measured = (blocks_worth >= FIELD_MIN_BLOCKS) & (sigma > 0.0)
    cy, cx = sigma.shape
    yy, xx = (g.ravel().astype(np.float64) for g in np.mgrid[0:cy, 0:cx])
    dy, dx = yy[None, :] - yy[:, None], xx[None, :] - xx[:, None]
    k = (np.where(measured, blocks_worth, 0.0).ravel()[None, :]
         * np.exp(-(dy ** 2 + dx ** 2) / (2.0 * FIELD_SMOOTH_CELLS ** 2)))
    design = np.stack([np.ones_like(dy), dy, dx], axis=2)
    lhs = np.einsum("ij,ijk,ijl->ikl", k, design, design) + FIELD_PRIOR_BLOCKS * np.eye(3)
    rhs = np.einsum("ij,ijk,j->ik", k, design, np.where(measured, sigma, 1.0).ravel().astype(np.float64))
    rhs[:, 0] += FIELD_PRIOR_BLOCKS
    field = np.linalg.solve(lhs, rhs[:, :, None])[:, 0, 0].reshape(cy, cx)
    return np.clip(field, *FIELD_CLAMP).astype(np.float32)


def _resize_linear(a, out_h, out_w):
    """OpenCV's INTER_LINEAR enlargement: pixel centres aligned, coordinates held at the border."""
    def taps(n_in, n_out):
        s = np.clip((np.arange(n_out) + 0.5) * n_in / n_out - 0.5, 0, n_in - 1)
        i0 = np.floor(s).astype(int)
        return i0, np.minimum(i0 + 1, n_in - 1), (s - i0).astype(np.float32)
    y0, y1, fy = taps(a.shape[0], out_h)
    x0, x1, fx = taps(a.shape[1], out_w)
    top = a[y0][:, x0] * (1 - fx) + a[y0][:, x1] * fx
    bottom = a[y1][:, x0] * (1 - fx) + a[y1][:, x1] * fx
    return (top * (1 - fy)[:, None] + bottom * fy[:, None]).astype(np.float32)


def field_at(field, shape):
    cell_px = FIELD_CELL * BLOCK
    return _resize_linear(field, field.shape[0] * cell_px, field.shape[1] * cell_px)[: shape[0], : shape[1]]


# ----------------------------------------------------------------- the network


def _load_module(qualname, path):
    spec = importlib.util.spec_from_file_location(qualname, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[qualname] = module
    spec.loader.exec_module(module)
    return module


def load_model(folder: Path, device="cpu"):
    """DRUNet-colour with AutoShade's weights; `folder` holds them and KAIR's two files."""
    import hashlib
    import torch
    for name, (_, sha) in KAIR.items():
        if hashlib.sha256((folder / name).read_bytes()).hexdigest() != sha:
            raise ValueError(f"{name} doesn't match the commit AutoShade pins")
    # network_unet.py imports `models.basicblock`; a package of that name is lent for the import only,
    # since other models in the harness (PMRID) have a `models` package of their own.
    names = ("models", "models.basicblock", "models.network_unet")
    saved = {n: sys.modules.pop(n) for n in names if n in sys.modules}
    package = types.ModuleType("models")
    package.__path__ = []
    sys.modules["models"] = package
    try:
        _load_module("models.basicblock", folder / "basicblock.py")
        unet = _load_module("models.network_unet", folder / "network_unet.py")
    finally:
        for n in names:
            sys.modules.pop(n, None)
        sys.modules.update(saved)
    model = unet.UNetRes(in_nc=4, out_nc=3, nc=[64, 128, 256, 512], nb=4, act_mode="R",
                         downsample_mode="strideconv", upsample_mode="convtranspose", bias=False)
    model.load_state_dict(torch.load(folder / WEIGHTS, map_location="cpu", weights_only=True), strict=True)
    return model.eval().to(device)


def tile_window(th, tw, overlap):
    wy, wx = np.ones(th, np.float32), np.ones(tw, np.float32)
    overlap = min(overlap, th // 2, tw // 2)
    if overlap > 0:
        ramp = np.linspace(0, 1, overlap, dtype=np.float32)
        wy[:overlap] = np.minimum(wy[:overlap], ramp)
        wy[-overlap:] = np.minimum(wy[-overlap:], ramp[::-1])
        wx[:overlap] = np.minimum(wx[:overlap], ramp)
        wx[-overlap:] = np.minimum(wx[-overlap:], ramp[::-1])
    return np.clip(np.outer(wy, wx), 1e-3, 1.0)


def run_tiled(model, rgb, sigma, device, tile=512, overlap=32, dtype=None):
    """rgb: H x W x 3 in [0, 1]. dtype None runs float32; "half" casts the network and its input to
    float16, "autocast" runs PyTorch's mixed precision."""
    import torch
    tile = max(64, int(tile))
    overlap = int(np.clip(overlap, 0, tile // 2))
    h, w, _ = rgb.shape
    acc = np.zeros((h, w, 3), np.float32)
    wsum = np.zeros((h, w, 1), np.float32)
    step = max(1, tile - overlap)
    ys = list(range(0, max(1, h - overlap), step)) if h > tile else [0]
    xs = list(range(0, max(1, w - overlap), step)) if w > tile else [0]
    net = model.half() if dtype == "half" else model
    with torch.no_grad():
        for y in ys:
            for x in xs:
                y1, x1 = min(y + tile, h), min(x + tile, w)
                y0, x0 = max(0, y1 - tile), max(0, x1 - tile)
                patch = rgb[y0:y1, x0:x1, :]
                ph, pw = patch.shape[:2]
                padded = np.pad(patch, ((0, (-ph) % 8), (0, (-pw) % 8), (0, 0)), mode="edge")
                t = torch.from_numpy(np.ascontiguousarray(padded.transpose(2, 0, 1))).unsqueeze(0)
                s = torch.full((1, 1, t.shape[2], t.shape[3]), float(sigma))
                x_in = torch.cat((t, s), dim=1).to(device)
                if dtype == "half":
                    out = net(x_in.half())
                elif dtype == "autocast":
                    with torch.autocast(device_type=device, dtype=torch.float16):
                        out = net(x_in)
                else:
                    out = net(x_in)
                out = out.squeeze(0).float().clamp(0, 1).cpu().numpy().transpose(1, 2, 0)[:ph, :pw]
                win = tile_window(ph, pw, overlap)[:, :, None]
                acc[y0:y1, x0:x1, :] += out * win
                wsum[y0:y1, x0:x1, :] += win
    if dtype == "half":
        model.float()
    wsum[wsum == 0] = 1.0
    return acc / wsum


# ----------------------------------------------------------------- the whole sidecar


def denoise(mosaic, tile, model, device, a=None, b=None, tile_size=512, overlap=32, dtype=None, stats=None,
            field=True):
    """mosaic: normalised (0 black, 1 white), values below black kept. `a` and `b` per colour (red, green,
    blue); None measures them blind, as the sidecar does. `field` False leaves out the noise field (1
    everywhere), for a noise model known to be right. Returns the denoised mosaic, or None where the
    sidecar would refuse (too little flat area to measure the noise)."""
    where = phases(tile)
    planes = {n: np.minimum(p, 1.0).astype(np.float32) for n, p in split_planes(mosaic, where).items()}
    if a is None:
        ab = noise_model(planes)
        if ab is None:
            return None
    else:
        colour = {"R": 0, "G1": 1, "G2": 1, "B": 2}
        ab = {n: (float(a[colour[n]]), float(b[colour[n]])) for n in PLANES}
    z = {n: gat(p, *ab[n]) for n, p in planes.items()}
    lo, span = model_affine(ab)
    cell = FIELD_CELL * BLOCK
    flat_field = lambda shape: np.ones((-(-shape[0] // cell), -(-shape[1] // cell)), np.float32)
    fields = {n: noise_field(z[n], planes[n] >= 1.0) if field else flat_field(z[n].shape) for n in PLANES}
    span /= min(float(f.min()) for f in fields.values())
    zn = {n: np.clip((z[n] / field_at(fields[n], z[n].shape) - lo) / span, 0.0, 1.0).astype(np.float32) for n in PLANES}
    sigma = SIGMA_SCALE / span
    estimates = {g: run_tiled(model, np.stack([zn["R"], zn[g], zn["B"]], axis=2), sigma, device, tile_size, overlap, dtype)
                 for g in ("G1", "G2")}
    cleaned = {
        "R": (estimates["G1"][:, :, 0] + estimates["G2"][:, :, 0]) / 2.0,
        "G1": estimates["G1"][:, :, 1],
        "G2": estimates["G2"][:, :, 1],
        "B": (estimates["G1"][:, :, 2] + estimates["G2"][:, :, 2]) / 2.0,
    }
    out = {n: np.clip(igat((cleaned[n] * span + lo) * field_at(fields[n], cleaned[n].shape), *ab[n]), 0.0, 1.0)
           for n in PLANES}
    if stats is not None:
        stats.update({"ab": {n: list(v) for n, v in ab.items()}, "sigma": float(sigma),
                      "field": {n: [float(f.min()), float(f.max())] for n, f in fields.items()}})
    return merge_planes({n: v.astype(np.float32) for n, v in out.items()}, where, mosaic.astype(np.float32))
