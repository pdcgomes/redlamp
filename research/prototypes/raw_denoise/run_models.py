"""Runs the open raw models (internal evaluation only) on the synthetic and RawNIND test sets.

Each model's own conventions (build/dn11-research/open-models.md, from each repository):

- RawNIND Bayer (Brummer & De Vleeschouwer 2025; darktable-ai's ONNX export): joint demosaic and
  denoise, blind. Packed RGGB, normalised, no white balance; camera RGB out at a learned gain,
  matched by one scalar to the input.
- RawNIND linear: denoises a demosaiced linear image (darktable's X-Trans path), here Redlamp's
  X-Trans demosaic; gain matched the same way.
- Gharbi et al. 2016, noise-aware Bayer (ported from the Caffe release): joint, white-balanced
  sRGB-gamma GRBG mosaic in, one Gaussian sigma; here the median per-photosite sigma after gamma.
- demosaicnet (Gharbi et al. 2016, noise-free Bayer and X-Trans): demosaic only, on the noise-free
  mosaics, as a learned "Raw Details" reference.
- Sanchez-Beeckman & Buades 2026, and PMRID (Wang et al. 2020): raw to raw, then Redlamp's demosaic
  through the harness (this script writes their mosaics and the harness jobs).

Outputs are balanced camera RGB, SIZE x SIZE float32, beside Redlamp's renders, so score.py and
real_pairs.py score them. Run with build/rawdn-venv (torch, onnxruntime, demosaicnet):

    PYTHONPATH=../../../build/oss/nonlocal-matchfilter/src:models/stubs:models \
      ../../../build/rawdn-venv/bin/python run_models.py synthetic|real
"""

import collections
import json
import os
import sys
import time
import typing

import numpy as np

from common import AS_SHOT, BAYER, CFAS, NOISE_LEVELS, OUT, ROOT, SIZE, TESTSET, XTRANS, read_json, save_f32, write_json

MODELS = ROOT / "build/proto-data/raw-denoise/models"
TIMES = collections.defaultdict(list)


def timed(name, fn, *args):
    started = time.perf_counter()
    result = fn(*args)
    TIMES[name].append(time.perf_counter() - started)
    return result


def srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * x ** (1 / 2.4) - 0.055)


def linear(y):
    y = np.clip(y, 0, 1)
    return np.where(y <= 0.04045, y / 12.92, ((y + 0.055) / 1.055) ** 2.4)


def rggb_offset(tile):
    """The (row, column) shift that puts an R at the origin of a 2 x 2 tile."""
    for oy in (0, 1):
        for ox in (0, 1):
            if tile[oy, ox] == 0 and tile[(oy + 1) % 2, (ox + 1) % 2] == 2:
                return oy, ox
    raise ValueError(f"not a Bayer tile: {tile}")


# ----------------------------------------------------------------- models


class RawNIND:
    def __init__(self):
        import onnxruntime as ort
        base = MODELS / "darktable-rawdenoise-nind/unpacked/rawdenoise-nind"
        self.bayer = ort.InferenceSession(str(base / "model_bayer.onnx"), providers=["CPUExecutionProvider"])
        self.linear_model = ort.InferenceSession(str(base / "model_linear.onnx"), providers=["CPUExecutionProvider"])

    def joint(self, raw, tile, gains):
        """raw: normalised mosaic (no white balance). Returns balanced camera RGB."""
        oy, ox = rggb_offset(tile)
        pad = 128 + 2
        m = np.pad(raw, pad, mode="reflect")[oy:, ox:]
        m = np.clip(m, 0, 1)
        h, w = (m.shape[0] // 2) * 2, (m.shape[1] // 2) * 2
        m = m[:h, :w]
        packed = np.stack([m[0::2, 0::2], m[0::2, 1::2], m[1::2, 0::2], m[1::2, 1::2]])
        out = np.zeros((3, h, w), np.float32)
        weight = np.zeros((h, w), np.float32)
        # 512 x 512 packed tiles (1024 photosites), overlapping by 128 packed, blended linearly.
        size, step = 512, 384
        ys = list(range(0, max(packed.shape[1] - size, 0) + 1, step))
        xs = list(range(0, max(packed.shape[2] - size, 0) + 1, step))
        if ys[-1] + size < packed.shape[1]:
            ys.append(packed.shape[1] - size)
        if xs[-1] + size < packed.shape[2]:
            xs.append(packed.shape[2] - size)
        ramp = np.minimum(np.minimum(np.arange(2 * size) + 1, 2 * size - np.arange(2 * size)), 128).astype(np.float32)
        window = np.outer(ramp, ramp)
        for y in ys:
            for x in xs:
                tile_in = packed[:, y:y + size, x:x + size][None].astype(np.float32)
                tile_out = self.bayer.run(None, {"input": tile_in})[0][0]
                tile_out *= tile_in.mean() / tile_out.mean()
                out[:, 2 * y:2 * y + 2 * size, 2 * x:2 * x + 2 * size] += tile_out * window
                weight[2 * y:2 * y + 2 * size, 2 * x:2 * x + 2 * size] += window
        out /= np.maximum(weight, 1e-6)
        rgb = out.transpose(1, 2, 0)
        # The tiles' scalar match compares a packed mean with an RGB mean; refine it on the CFA, where
        # each photosite's own colour in the output is compared with what the photosite recorded.
        index = np.tile(BAYER, (h // 2, w // 2))
        sampled = np.take_along_axis(rgb, index[..., None], axis=2)[..., 0]
        rgb = rgb * (m.mean() / max(sampled.mean(), 1e-9))
        # Back to the input's grid.
        rgb = rgb[pad - oy:pad - oy + raw.shape[0], pad - ox:pad - ox + raw.shape[1]]
        return (rgb * np.array(gains, np.float32)).astype(np.float32)

    def linear(self, rgb):
        """rgb: a demosaiced, white-balanced linear image (H, W, 3)."""
        pad = 128
        x = np.pad(rgb, ((pad, pad), (pad, pad), (0, 0)), mode="reflect").transpose(2, 0, 1)
        size, step = 512, 384
        h, w = x.shape[1:]
        out = np.zeros_like(x)
        weight = np.zeros((h, w), np.float32)
        ys = list(range(0, h - size + 1, step)) + ([h - size] if (h - size) % step else [])
        xs = list(range(0, w - size + 1, step)) + ([w - size] if (w - size) % step else [])
        ramp = np.minimum(np.minimum(np.arange(size) + 1, size - np.arange(size)), 64).astype(np.float32)
        window = np.outer(ramp, ramp)
        for y in sorted(set(ys)):
            for x0 in sorted(set(xs)):
                t = x[:, y:y + size, x0:x0 + size][None].astype(np.float32)
                o = self.linear_model.run(None, {"input": t})[0][0]
                o *= t.mean() / o.mean()
                out[:, y:y + size, x0:x0 + size] += o * window
                weight[y:y + size, x0:x0 + size] += window
        out /= np.maximum(weight, 1e-6)
        return out.transpose(1, 2, 0)[pad:-pad, pad:-pad].astype(np.float32)


class Gharbi:
    def __init__(self):
        import torch as th
        import demosaicnet
        import demosaicnet_noise
        self.th = th
        self.device = "mps" if th.backends.mps.is_available() else "cpu"
        self.noise = demosaicnet_noise.BayerNoiseDemosaick()
        self.noise.load_state_dict(th.load(MODELS / "demosaicnet/bayer_noise_from_caffe.pth", weights_only=True))
        self.noise = self.noise.to(self.device).eval()
        self.bayer = demosaicnet.BayerDemosaick().to(self.device).eval()
        self.xtrans = demosaicnet.XTransDemosaick().to(self.device).eval()
        cell = demosaicnet.mosaic.xtrans_cell()
        self.xtrans_cell = np.argmax(cell, 0)

    def _run(self, net, masked, sigma=None):
        th = self.th
        x = th.from_numpy(masked.astype(np.float32))[None].to(self.device)
        with th.no_grad():
            y = net(x) if sigma is None else net(x, th.tensor([sigma], dtype=th.float32, device=self.device))
        return y[0].cpu().numpy()

    def bayer_rgb(self, raw, tile, gains, sigma=None):
        """Balanced mosaic -> sRGB gamma -> GRBG masked image -> model -> linear balanced RGB."""
        index = np.tile(tile, (raw.shape[0] // 2, raw.shape[1] // 2))
        balanced = raw * np.array(gains, np.float32)[index]
        oy, ox = rggb_offset(tile)
        pad = 34
        m = np.pad(srgb(balanced), pad, mode="reflect")[oy:, ox + 1:]  # G at the origin, R beside it: GRBG
        h, w = m.shape
        masked = np.zeros((3, h, w), np.float32)
        masked[1, 0::2, 0::2] = m[0::2, 0::2]
        masked[0, 0::2, 1::2] = m[0::2, 1::2]
        masked[2, 1::2, 0::2] = m[1::2, 0::2]
        masked[1, 1::2, 1::2] = m[1::2, 1::2]
        out = self._run(self.noise if sigma is not None else self.bayer, masked, sigma)
        crop = (h - out.shape[1]) // 2
        # out[i, j] is m[i + crop, j + crop], which is the padded image at (i + crop + oy, j + crop + ox + 1).
        y0 = pad - oy - crop
        x0 = pad - ox - 1 - crop
        rgb = out[:, y0:y0 + raw.shape[0], x0:x0 + raw.shape[1]].transpose(1, 2, 0)
        return linear(rgb).astype(np.float32)

    def xtrans_rgb(self, raw, tile, gains):
        index = np.tile(tile, (raw.shape[0] // 6, raw.shape[1] // 6))
        balanced = raw * np.array(gains, np.float32)[index]
        oy, ox = next((oy, ox) for oy in range(6) for ox in range(6)
                      if np.array_equal(np.roll(tile, (-oy, -ox), (0, 1)), self.xtrans_cell))
        pad = 18
        m = np.pad(srgb(balanced), pad, mode="wrap")[oy:, ox:]
        h, w = (m.shape[0] // 6) * 6, (m.shape[1] // 6) * 6
        m = m[:h, :w]
        cell = np.tile(self.xtrans_cell, (h // 6, w // 6))
        masked = np.stack([m * (cell == c) for c in range(3)])
        out = self._run(self.xtrans, masked)
        crop = (h - out.shape[1]) // 2
        y0, x0 = pad - oy - crop, pad - ox - crop
        rgb = out[:, y0:y0 + raw.shape[0], x0:x0 + raw.shape[1]].transpose(1, 2, 0)
        return linear(rgb).astype(np.float32)


def gamma_sigma(raw, tile, gains, a, b):
    """The median noise sigma after white balance and sRGB gamma (delta method), for Gharbi's input."""
    index = np.tile(tile, (raw.shape[0] // tile.shape[0], raw.shape[1] // tile.shape[1]))
    g = np.array(gains, np.float32)[index]
    x = np.clip(raw * g, 1e-4, 1)
    sd = g * np.sqrt(np.maximum(np.array(a, np.float32)[index] * raw + np.array(b, np.float32)[index], 0))
    slope = np.where(x <= 0.0031308, 12.92, 1.055 / 2.4 * x ** (1 / 2.4 - 1))
    return float(min(np.median(slope * sd), 0.0784))


class Buades:
    def __init__(self):
        import omegaconf
        import torch as th
        from nonlocal_matchfilter.networks import SimpleBlockMatchingUNet
        self.th = th
        safe = [omegaconf.listconfig.ListConfig, omegaconf.base.ContainerMetadata, typing.Any, list,
                collections.defaultdict, dict, int, omegaconf.nodes.AnyNode, omegaconf.base.Metadata]
        with th.serialization.safe_globals(safe):
            ckpt = th.load(MODELS / "nonlocal-matchfilter/rawnoise_25_15_9nbr.ckpt", map_location="cpu", weights_only=True)
        sd = {k[len("model."):]: v for k, v in ckpt["state_dict"].items() if k.startswith("model.")}
        self.net = SimpleBlockMatchingUNet(input_channels=8, output_channels=4, n_features=32,
                                           neighbours={"scale1": [5, 5], "scale2": [3, 5], "scale3": [3, 3]},
                                           max_search_dist=9.0)
        self.net.load_state_dict(sd)
        self.net.eval()

    def __call__(self, raw, tile, a, b):
        oy, ox = rggb_offset(tile)
        pad = 8
        m = np.pad(raw, pad, mode="reflect")[oy:, ox:]
        h, w = (m.shape[0] // 8) * 8, (m.shape[1] // 8) * 8
        m = np.clip(m[:h, :w], 0, 1)
        index = np.tile(BAYER, (h // 2, w // 2))
        av = np.array(a, np.float32)[index]
        bv = np.array(b, np.float32)[index]
        sigma = np.sqrt(np.maximum(av * m + bv, 0))
        pack = lambda z: np.stack([z[0::2, 0::2], z[0::2, 1::2], z[1::2, 1::2], z[1::2, 0::2]])
        x = np.concatenate([pack(m), pack(sigma)])[None].astype(np.float32)
        with self.th.no_grad():
            y = self.net(self.th.from_numpy(x)).clamp(0, 1)[0].numpy()
        out = np.zeros((h, w), np.float32)
        out[0::2, 0::2], out[0::2, 1::2], out[1::2, 1::2], out[1::2, 0::2] = y
        return out[pad - oy:pad - oy + raw.shape[0], pad - ox:pad - ox + raw.shape[1]]


class PMRID:
    V = 959.0

    def __init__(self):
        import torch as th
        sys.path.insert(0, str(ROOT / "build/oss/PMRID"))
        from models.net_torch import Network
        self.th = th
        self.net = Network()
        self.net.load_state_dict(th.load(MODELS / "PMRID/torch_pretrained.ckp", map_location="cpu", weights_only=True))
        self.net.eval()
        self.k_poly = np.poly1d([0.0005995267, 0.00868861])
        self.s_poly = np.poly1d([7.11772e-7, 6.514934e-4, 0.11492713])

    def __call__(self, raw, tile, a, b):
        """k-sigma to the network's anchor (ISO 1600 on its phone), from this camera's own a and b."""
        k, s = float(np.mean(a)) * self.V, float(np.mean(b)) * self.V ** 2
        ka, sa = self.k_poly(1600), self.s_poly(1600)
        ck, cb = ka / k, (s / k ** 2 - sa / ka ** 2) * ka
        oy, ox = rggb_offset(tile)
        pad = 64
        m = np.pad(raw, pad, mode="reflect")[oy:, ox:]
        h, w = (m.shape[0] // 64) * 64, (m.shape[1] // 64) * 64
        m = m[:h, :w]
        packed = np.stack([m[0::2, 0::2], m[0::2, 1::2], m[1::2, 0::2], m[1::2, 1::2]])
        x = (packed * self.V * ck + cb) / self.V * 256.0
        with self.th.no_grad():
            y = self.net(self.th.from_numpy(x[None].astype(np.float32)))[0].numpy()
        y = ((y / 256.0) * self.V - cb) / ck / self.V
        out = np.zeros((h, w), np.float32)
        out[0::2, 0::2], out[0::2, 1::2], out[1::2, 0::2], out[1::2, 1::2] = y
        return out[pad - oy:pad - oy + raw.shape[0], pad - ox:pad - ox + raw.shape[1]]


# ----------------------------------------------------------------- harness jobs for raw-to-raw outputs


def harness_job(name, path, tile, a, b, gains, out_dir, prefix):
    return {
        "name": name, "mosaic": str(path), "width": SIZE, "height": SIZE,
        "cfa": [int(v) for v in tile.flatten()], "cfaWidth": tile.shape[1], "cfaHeight": tile.shape[0],
        "noiseA": [float(v) for v in a], "noiseB": [float(v) for v in b], "asShot": [float(v) for v in gains],
        "demosaic": "menon", "dual": True,
        "renders": [{"out": str(out_dir / f"{prefix}.f32"), "settings": {}},
                    {"out": str(out_dir / f"{prefix}-c25.f32"), "settings": {"color": 25}}],
    }


def raw_to_raw(jobs, name, model, noisy, tile, a, b, gains, out_dir, reference_mosaic, label):
    denoised = timed(label, model, noisy, tile, a, b)
    index = np.tile(tile, (SIZE // tile.shape[0], SIZE // tile.shape[1]))
    expected = np.mean(np.array(a)[index] * np.maximum(reference_mosaic, 0) + np.array(b)[index])
    residual = float(np.mean((denoised - reference_mosaic)[16:-16, 16:-16] ** 2) / expected)
    path = out_dir / f"{label}.mosaic.f32"
    save_f32(path, denoised)
    jobs.append(harness_job(f"{name}-{label}", path, tile, [v * residual for v in a], [v * residual for v in b],
                            gains, out_dir, label))


# ----------------------------------------------------------------- test sets


def synthetic():
    manifest = read_json(TESTSET / "manifest.json")
    nind, gharbi, buades, pmrid = RawNIND(), Gharbi(), Buades(), PMRID()
    jobs = []
    for scene in manifest["scenes"]:
        renders = OUT / "renders" / scene
        for cfa_name, tile in CFAS.items():
            clean = np.fromfile(TESTSET / scene / f"{cfa_name}-clean.f32", "<f4").reshape(SIZE, SIZE)
            # A learned demosaic on the noise-free mosaic.
            fn = gharbi.bayer_rgb if cfa_name == "bayer" else gharbi.xtrans_rgb
            save_f32(renders / cfa_name / "clean-demosaicnet.f32", timed(f"demosaicnet-{cfa_name}", fn, clean, tile, AS_SHOT))
            for level, (a, b) in NOISE_LEVELS.items():
                out = renders / cfa_name / level
                noisy = np.fromfile(TESTSET / scene / f"{cfa_name}-{level}.f32", "<f4").reshape(SIZE, SIZE)
                av, bv = [a] * 3, [b] * 3
                if cfa_name == "bayer":
                    save_f32(out / "model-nind.f32", timed("nind-bayer", nind.joint, noisy, tile, AS_SHOT))
                    sigma = gamma_sigma(noisy, tile, AS_SHOT, av, bv)
                    save_f32(out / "model-gharbi.f32", timed("gharbi-noise", gharbi.bayer_rgb, noisy, tile, AS_SHOT, sigma))
                    raw_to_raw(jobs, f"{scene}-{cfa_name}-{level}", buades, noisy, tile, av, bv, AS_SHOT, out, clean, "model-buades")
                    raw_to_raw(jobs, f"{scene}-{cfa_name}-{level}", pmrid, noisy, tile, av, bv, AS_SHOT, out, clean, "model-pmrid")
                else:
                    demosaiced = np.fromfile(out / "rl-none.f32", "<f4").reshape(SIZE, SIZE, 3)
                    save_f32(out / "model-nind-linear.f32", timed("nind-linear", nind.linear, demosaiced))
            print(scene, cfa_name, flush=True)
    write_json(OUT / "models-harness" / "jobs.json", jobs)
    write_json(OUT / "model-timings.json", {k: float(np.median(v)) for k, v in TIMES.items()})


def real():
    REAL = OUT / "real"  # real_pairs.REAL, without importing rawpy here
    meta = read_json(REAL / "meta.json")
    nind, gharbi, buades = RawNIND(), Gharbi(), Buades()
    jobs = []
    for name, m in meta.items():
        base = REAL / name
        gt = np.fromfile(base / "gt.f32", "<f4").reshape(SIZE, SIZE)
        colc = np.load(base / "colors.npy")
        tile = colc[:m["tile"], :m["tile"]]
        harness = read_json(REAL / "harness" / "jobs.json")
        gains = next(j["asShot"] for j in harness if j["name"] == f"{name}-gt")
        for iso, info in m["isos"].items():
            out = base / f"iso{iso}"
            noisy = np.fromfile(out / "noisy.f32", "<f4").reshape(SIZE, SIZE)
            a, b = info["a"], info["b"]
            if m["tile"] == 2:
                save_f32(out / "model-nind.f32", timed("nind-bayer", nind.joint, noisy, tile, gains))
                sigma = gamma_sigma(noisy, tile, gains, a, b)
                save_f32(out / "model-gharbi.f32", timed("gharbi-noise", gharbi.bayer_rgb, noisy, tile, gains, sigma))
                raw_to_raw(jobs, f"{name}-{iso}", buades, noisy, tile, a, b, gains, out, gt, "model-buades")
            else:
                demosaiced = np.fromfile(out / "rl-none.f32", "<f4").reshape(SIZE, SIZE, 3)
                save_f32(out / "model-nind-linear.f32", timed("nind-linear", nind.linear, demosaiced))
            print(name, iso, flush=True)
    write_json(REAL / "models-harness" / "jobs.json", jobs)


if __name__ == "__main__":
    {"synthetic": synthetic, "real": real}[sys.argv[1]]()
