"""Runs Sánchez-Beeckman & Buades 2026 (rawnoise_25_15_9nbr.ckpt) on a synthetic Bayer tile, CPU only.

Needs deform-neighbourhood-sampling built for CPU (see open-models.md) and the patchmatch stub.

Usage:
  PYTHONPATH=build/oss/nonlocal-matchfilter/src:research/prototypes/raw_denoise/models/stubs \
    build/rawdn-venv/bin/python research/prototypes/raw_denoise/models/nonlocal_matchfilter_smoke.py
"""

import collections
import time
import typing

import numpy as np
import omegaconf
import torch as th

from nonlocal_matchfilter.networks import SimpleBlockMatchingUNet

CKPT = "build/proto-data/raw-denoise/models/nonlocal-matchfilter/rawnoise_25_15_9nbr.ckpt"
# Lightning saved Hydra containers beside the weights; allow only those data classes.
SAFE = [omegaconf.listconfig.ListConfig, omegaconf.base.ContainerMetadata, typing.Any, list,
        collections.defaultdict, dict, int, omegaconf.nodes.AnyNode, omegaconf.base.Metadata]


def load():
    with th.serialization.safe_globals(SAFE):
        ckpt = th.load(CKPT, map_location="cpu", weights_only=True)
    sd = {k[len("model."):]: v for k, v in ckpt["state_dict"].items() if k.startswith("model.")}
    net = SimpleBlockMatchingUNet(input_channels=8, output_channels=4, n_features=32,
                                  neighbours={"scale1": [5, 5], "scale2": [3, 5], "scale3": [3, 3]},
                                  max_search_dist=9.0)
    print("load_state_dict:", net.load_state_dict(sd))
    print("params:", sum(p.numel() for p in net.parameters()))
    return net.eval()


def main():
    net = load()
    rng = np.random.default_rng(0)
    h = w = 512
    yy, xx = np.mgrid[0:h, 0:w] / h
    tex = 0.05 * np.sin(80 * xx) * np.sin(60 * yy)
    rgb = np.stack([0.15 + 0.2 * np.sin(6 * xx) ** 2 + tex, 0.2 + 0.15 * yy + tex,
                    0.1 + 0.2 * np.cos(5 * yy * xx) ** 2 + tex], 0).clip(0, 1)
    bayer = np.zeros((h, w))
    bayer[0::2, 0::2] = rgb[0, 0::2, 0::2]
    bayer[0::2, 1::2] = rgb[1, 0::2, 1::2]
    bayer[1::2, 0::2] = rgb[1, 1::2, 0::2]
    bayer[1::2, 1::2] = rgb[2, 1::2, 1::2]
    # [R, Gr, B, Gb] for an RGGB mosaic, as isp/pipeline.py unpack() expects
    pack = lambda b: np.stack([b[0::2, 0::2], b[0::2, 1::2], b[1::2, 1::2], b[1::2, 0::2]], 0)
    clean = pack(bayer)
    psnr = lambda a, b: 10 * np.log10(1 / np.mean((a - b) ** 2))
    for a, b in [(0.002, 1e-5), (0.01, 1e-4)]:  # shot gain and read variance on the [0, 1] scale
        noisy = np.clip(rng.poisson(clean / a) * a + rng.normal(0, np.sqrt(b), clean.shape), 0, 1)
        sigma = np.sqrt(np.maximum(a * noisy + b, 0))
        x = th.from_numpy(np.concatenate([noisy, sigma], 0).astype(np.float32))[None]
        with th.no_grad():
            t = time.time()
            y = net(x).clamp(0, 1)[0].numpy()
            dt = time.time() - t
        print(f"a={a} b={b}: in {tuple(x.shape)} out {y.shape}  noisy {psnr(noisy, clean):.2f} dB"
              f" -> {psnr(y, clean):.2f} dB  ({dt:.1f} s CPU)")


if __name__ == "__main__":
    main()
