"""Smoke tests for the raw-mosaic models staged for the DN-11 bake-off.

Each test builds a synthetic clean RGB scene, mosaics it (RGGB Bayer or X-Trans), adds
Poisson-Gaussian noise, runs one model on CPU (and MPS where it works), and prints PSNR
against the clean target. Synthetic and tiny: this checks the plumbing, not quality.

Usage (from the repository root):
  build/rawdn-venv/bin/python -W ignore research/prototypes/raw_denoise/models/smoke_models.py [rawnind|demosaicnet|pmrid|kokkinos|all]
"""

import os
import sys
import time

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
MODELS = os.path.join(ROOT, "build/proto-data/raw-denoise/models")
psnr = lambda a, b, peak=1.0: 10 * np.log10(peak**2 / np.mean((a - b) ** 2))


def scene(h, w):
    yy, xx = np.mgrid[0:h, 0:w] / h
    tex = 0.05 * np.sin(80 * xx) * np.sin(60 * yy)
    return np.stack([0.15 + 0.2 * np.sin(6 * xx) ** 2 + tex, 0.2 + 0.15 * yy + tex,
                     0.1 + 0.2 * np.cos(5 * yy * xx) ** 2 + tex], 0).clip(0, 1).astype(np.float32)


def rggb(rgb):
    b = np.zeros(rgb.shape[1:], np.float32)
    b[0::2, 0::2] = rgb[0, 0::2, 0::2]
    b[0::2, 1::2] = rgb[1, 0::2, 1::2]
    b[1::2, 0::2] = rgb[1, 1::2, 0::2]
    b[1::2, 1::2] = rgb[2, 1::2, 1::2]
    return b


def pg(x, a, b, rng):
    """Poisson-Gaussian noise, variance a*x + b on the [0, 1] scale."""
    return (rng.poisson(np.clip(x, 0, None) / a) * a + rng.normal(0, np.sqrt(b), x.shape)).astype(np.float32)


def rawnind():
    """darktable-ai rawdenoise-nind 1.0 (RawNIND UtNet2), ONNX Runtime CPU."""
    import onnxruntime as ort

    base = os.path.join(MODELS, "darktable-rawdenoise-nind/unpacked/rawdenoise-nind")
    rng = np.random.default_rng(0)
    rgb = scene(1024, 1024)
    noisy = np.clip(pg(rggb(rgb), 0.01, 4e-4, rng), 0, 1)
    packed = np.stack([noisy[0::2, 0::2], noisy[0::2, 1::2], noisy[1::2, 0::2], noisy[1::2, 1::2]])[None]
    s = ort.InferenceSession(os.path.join(base, "model_bayer.onnx"), providers=["CPUExecutionProvider"])
    t = time.time()
    y = s.run(None, {"input": packed})[0][0]
    y *= packed.mean() / y.mean()  # output_scale: match_gain
    print(f"rawnind bayer  CPU: in {packed.shape} -> out {y.shape} camRGB, {time.time() - t:.2f} s,"
          f" PSNR {psnr(y, rgb):.2f} dB (synthetic camRGB = scene RGB)")
    lin = scene(512, 512)
    noisy = pg(lin, 0.01, 1e-4, rng)[None]
    s = ort.InferenceSession(os.path.join(base, "model_linear.onnx"), providers=["CPUExecutionProvider"])
    t = time.time()
    y = s.run(None, {"input": noisy})[0][0]
    y *= noisy.mean() / y.mean()  # the learned gain is about -3e9: match_gain fixes sign and scale
    print(f"rawnind linear CPU: in {noisy.shape} -> out {y.shape}, {time.time() - t:.2f} s,"
          f" noisy {psnr(noisy[0], lin):.2f} dB -> {psnr(y, lin):.2f} dB")


def demosaicnet():
    """Gharbi et al. 2016: PyPI demosaicnet (Bayer, X-Trans) plus the ported noise-aware Bayer model."""
    import torch as th
    import demosaicnet as dm

    sys.path.insert(0, os.path.dirname(__file__))
    import demosaicnet_noise as dn

    rng = np.random.default_rng(0)
    # sRGB-gamma, white-balanced scene: what these models were trained on
    rgb = scene(132, 132) ** (1 / 2.2)
    devices = ["cpu", "mps"] if th.backends.mps.is_available() else ["cpu"]
    noise_net = dn.BayerNoiseDemosaick()
    noise_net.load_state_dict(th.load(os.path.join(MODELS, "demosaicnet/bayer_noise_from_caffe.pth"), weights_only=True))
    for dev in devices:
        for name, net, mosaic in [("BayerDemosaick", dm.BayerDemosaick(), dm.bayer(rgb)),
                                  ("XTransDemosaick", dm.XTransDemosaick(), dm.xtrans(rgb))]:
            net = net.to(dev).eval()
            with th.no_grad():
                y = net(th.from_numpy(mosaic)[None].to(dev))[0].cpu().numpy()
            c = (rgb.shape[1] - y.shape[1]) // 2
            print(f"demosaicnet {name:15s} {dev}: out {y.shape} (crop {c}/side), noise-free PSNR"
                  f" {psnr(np.clip(y, 0, 1), rgb[:, c:c + y.shape[1], c:c + y.shape[2]]):.2f} dB")
        net = noise_net.to(dev).eval()
        sigma = 0.04
        x = th.from_numpy(dn.grbg((rgb + rng.normal(0, sigma, rgb.shape)).astype(np.float32)))[None].to(dev)
        with th.no_grad():
            y = net(x, th.tensor([sigma], device=dev))[0].cpu().numpy()
        c = (rgb.shape[1] - y.shape[1]) // 2
        print(f"demosaicnet bayer_noise     {dev}: sigma={sigma} out {y.shape},"
              f" PSNR {psnr(np.clip(y, 0, 1), rgb[:, c:c + y.shape[1], c:c + y.shape[2]]):.2f} dB")


def pmrid():
    """PMRID (ECCV 2020) PyTorch model, k-sigma transform with the OPPO Reno 10x calibration."""
    import torch as th

    sys.path.insert(0, os.path.join(ROOT, "build/oss/PMRID"))
    from models.net_torch import Network

    net = Network()
    net.load_state_dict(th.load(os.path.join(MODELS, "PMRID/torch_pretrained.ckp"), map_location="cpu", weights_only=True))
    net.eval()
    k_poly, s_poly, v, anchor = np.poly1d([0.0005995267, 0.00868861]), np.poly1d([7.11772e-7, 6.514934e-4, 0.11492713]), 959.0, 1600

    def ksigma(x, k, s, inverse=False):
        ka, sa = k_poly(anchor), s_poly(anchor)
        ck, cb = ka / k, (s / k**2 - sa / ka**2) * ka
        x = x * v
        return ((x * ck + cb) if not inverse else (x - cb) / ck) / v

    rng = np.random.default_rng(0)
    clean = rggb(scene(1024, 1024))
    iso = 3200
    k, s = k_poly(iso), s_poly(iso)  # for another camera: k = a*V, s = b*V**2 from its own (a, b)
    noisy = (rng.poisson(clean * v / k) * k + rng.normal(0, np.sqrt(s), clean.shape)) / v
    pack = lambda b: np.stack([b[0::2, 0::2], b[0::2, 1::2], b[1::2, 0::2], b[1::2, 1::2]])
    x, c = pack(noisy).astype(np.float32), pack(clean)
    for dev in ["cpu", "mps"] if th.backends.mps.is_available() else ["cpu"]:
        net.to(dev)
        with th.no_grad():
            y = net(th.from_numpy((ksigma(x, k, s) * 256.0).astype(np.float32))[None].to(dev))[0].cpu().numpy()
        y = ksigma(y / 256.0, k, s, inverse=True)
        print(f"pmrid {dev}: ISO {iso}, noisy {psnr(x, c):.2f} dB -> {psnr(np.clip(y, 0, 1), c):.2f} dB")


def kokkinos():
    """Kokkinos & Lefkimmiatis (MMNet/ResDNet), bayer_noisy, CPU; needs a contiguity patch for torch 2.x."""
    import torch as th
    import torch.nn.functional as F

    repo = os.path.join(ROOT, "build/oss/deep_demosaick")
    sys.path.insert(0, repo)
    cwd = os.getcwd()
    os.chdir(repo)
    import l2proj

    orig = l2proj.L2Proj.forward
    l2proj.L2Proj.forward = lambda self, x, stdn, alpha: orig(self, x.contiguous(), stdn, alpha)
    from residual_model_resdnet import BasicBlock, ResNet_Den
    from MMNet_TBPTT import MMNet
    from problems import Demosaic
    import utils

    os.chdir(cwd)
    mp = th.load(os.path.join(MODELS, "deep_demosaick/bayer_noisy/model_best.pth"), map_location="cpu", weights_only=True)
    mm = MMNet(ResNet_Den(BasicBlock, mp[2], weightnorm=True), max_iter=mp[1])
    mm.load_state_dict(mp[0])
    mm.eval()
    rng = np.random.default_rng(0)
    h = w = 256
    rgb = np.transpose(scene(h, w), (1, 2, 0)) * 255  # linear, white-balanced, 0..255
    mask = utils.generate_mask((h + 16, w + 16), pattern="RGGB")
    for sigma in [5, 10]:
        bayer = (rgb * mask[8:-8, 8:-8]).sum(-1) + rng.normal(0, sigma, (h, w))
        with th.no_grad():
            m = F.pad(th.FloatTensor(bayer)[None, None], (8, 8, 8, 8), "reflect")[:, 0]
            mk = th.FloatTensor(mask)[None]
            p = Demosaic((m[..., None] * mk).permute(0, 3, 1, 2), mk.permute(0, 3, 1, 2))
            y = mm.forward_all_iter(p, max_iter=mm.max_iter, init=True, noise_estimation=True)
        y = y[0].permute(1, 2, 0).numpy()[8:-8, 8:-8]
        print(f"kokkinos bayer_noisy cpu: sigma={sigma}/255 -> PSNR {psnr(y, rgb, 255):.2f} dB")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    for name, fn in [("rawnind", rawnind), ("demosaicnet", demosaicnet), ("pmrid", pmrid), ("kokkinos", kokkinos)]:
        if which in (name, "all"):
            fn()
