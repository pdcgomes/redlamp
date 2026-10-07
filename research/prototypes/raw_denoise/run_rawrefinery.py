"""RawRefinery's models (rymuelle/RawRefinery and its backend RawForge) on the DN-11 test sets.

Internal evaluation only: the code is MIT; the weights carry no licence of their own and were trained
on RawNIND alone (CC BY-SA 4.0), its TEST_ scenes included, so the real pairs aren't held out for
them and only the synthetic scenes are. Each model gets the input RawForge 0.2.3 gives it
(RawForge/application/helpers/get_image.py and main.py, 3 July 2026):

- TreeNetDenoise, Light, SuperLight and Heavy (Bayer): the camera-to-linear-Rec. 2020 matrix applied to
  each 2 x 2 block of the mosaic (RawHandler), a Malvar 2004 demosaic, clipped to [0, 1]; ISO / 6400 as
  the conditioning; 256 px tiles overlapping by a quarter, blended. The synthetic camera's matrix is its
  white balance, so its blocks don't mix colours as a real camera's do.
- JDD (DemoRestormerDiT_to_demo_cont_cont_768_RawNIND): six channels, each photosite in its colour's
  plane and the three planes' masks, in camera RGB divided by the white level with the black level kept,
  768 px tiles, and the mean black level subtracted from the result. JDD256 (DemoRestormerDiT_to_demo_cont)
  takes the black level subtracted, in 256 px tiles. Synthetic mosaics get a Sony 14-bit black level
  (512 of 16383), the commonest in the training set.
- TreeNetDenoiseXTrans and RestormerXTrans (X-Trans): LibRaw's demosaic as RawForge calls it (AHD, which on
  X-Trans is Markesteijn's three passes) in camera RGB without white balance, black subtracted, divided by
  the white level; the X-Trans TreeNet's conditioning is 0 (cond_scale 0).

The JDD archives were traced on CUDA with torch.device("cuda:0") in the rotary embedding, so they don't
run on a Mac as published; `fetch` verifies every file against the author's key and writes copies with
that constant replaced. Outputs are balanced camera RGB beside Redlamp's renders (`model-rr-*.f32`), so
score.py and real_pairs.py score them. With build/rawdn-venv (torch, rawpy, colour-demosaicing):

    ../../../build/rawdn-venv/bin/python run_rawrefinery.py fetch|synthetic|real|fp16|conditioning
    ../../../build/dn11-venv/bin/python run_rawrefinery.py figures|summary   # after score.py and real_pairs.py score
"""

import collections
import os
import subprocess
import sys
import time
import zipfile

import numpy as np

from common import AS_SHOT, CFAS, NOISE_LEVELS, OUT, ROOT, SIZE, TESTSET, cfa_index, read_json, save_f32, write_json

MODELS = ROOT / "build/proto-data/raw-denoise/models/rawrefinery"
RAF = ROOT / "tests/fixtures/raw/AFXT2720.RAF"
REAL = OUT / "real"
OFFSET = 600  # where synthetic X-Trans mosaics go in the X-T3 raw: a multiple of 6 keeps the phase
SONY_BLACK = 512 / 16383
XYZ_TO_REC2020 = np.array([
    [1.71666343, -0.35567332, -0.25336809],
    [-0.66667384, 1.61645574, 0.0157683],
    [0.01764248, -0.04277698, 0.94224328],
])

RELEASES = "https://github.com/rymuelle"
FILES = {
    "ShadowWeightedL1.pt": "RawRefinery/releases/download/v1.2.1-alpha",
    "ShadowWeightedL1_light.pt": "RawRefinery/releases/download/v1.2.1-alpha",
    "ShadowWeightedL1_super_light.pt": "RawRefinery/releases/download/v1.2.1-alpha",
    "ShadowWeightedL1_24_deep_500.pt": "RawRefinery/releases/download/v1.2.1-alpha",
    "Deblur_deep_24.pt": "RawRefinery/releases/download/v1.2.1-alpha",
    "realblur_gamma_140.pt": "RawRefinery/releases/download/v1.2.1-alpha",
    "xtrans_fixed_exposure_no_conditioning_400.pt": "RawForge/releases/download/xtrans_v1.0.0",
    "restormer.pt": "RawForge/releases/download/xtrans_v1.0.0",
    "DemoRestormerDiT_to_demo_cont_cont_768_RawNIND.pt": "RawForge/releases/download/JDD_v1.0.0",
    "DemoRestormerDiT_to_demo_cont.pt": "RawForge/releases/download/JDD_v1.0.0",
    "ShadowWeightedL1.onnx": "RawForge/releases/download/onnx_v1.0.0",
}
CUDA_TRACED = ["DemoRestormerDiT_to_demo_cont_cont_768_RawNIND.pt", "DemoRestormerDiT_to_demo_cont.pt"]

BAYER_TREENETS = {
    "rr-treenet": "ShadowWeightedL1.pt",
    "rr-treenet-light": "ShadowWeightedL1_light.pt",
    "rr-treenet-superlight": "ShadowWeightedL1_super_light.pt",
    "rr-treenet-heavy": "ShadowWeightedL1_24_deep_500.pt",
}
JDDS = {
    "rr-jdd": ("DemoRestormerDiT_to_demo_cont_cont_768_RawNIND", 768, False),
    "rr-jdd256": ("DemoRestormerDiT_to_demo_cont", 256, True),
}
XTRANS_MODELS = {
    "rr-xtrans-treenet": ("xtrans_fixed_exposure_no_conditioning_400.pt", 256),
    "rr-xtrans-restormer": ("restormer.pt", 256),
}
TIMES = collections.defaultdict(list)


# ----------------------------------------------------------------- the files


def fetch():
    """Downloads the registry's models, checks each against its signature, and patches the CUDA traces."""
    MODELS.mkdir(parents=True, exist_ok=True)
    key = MODELS / "pub.pem"
    source = (ROOT / "build/oss/rawforge/RawForge/application/ModelHandler.py").read_text()
    key.write_text(source[source.index("-----BEGIN"):source.index("-----END PUBLIC KEY-----") + 24] + "\n")
    for name, release in FILES.items():
        for suffix in ("", ".sig"):
            path = MODELS / (name + suffix)
            if not path.exists():
                subprocess.run(["curl", "-sSL", "-o", str(path), f"{RELEASES}/{release}/{name}{suffix}"], check=True)
        subprocess.run(["openssl", "dgst", "-sha256", "-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:auto",
                        "-verify", str(key), "-signature", str(MODELS / (name + ".sig")), str(MODELS / name)], check=True)
    for name in CUDA_TRACED:
        for device in ("cpu", "mps"):
            with zipfile.ZipFile(MODELS / name) as src, \
                    zipfile.ZipFile(MODELS / name.replace(".pt", f".{device}.pt"), "w", zipfile.ZIP_STORED) as dst:
                for info in src.infolist():
                    data = src.read(info.filename)
                    if info.filename.endswith("DiTBottlneck.py"):
                        data = data.replace(b'torch.device("cuda:0")', f'torch.device("{device}")'.encode())
                    dst.writestr(info, data)


# ----------------------------------------------------------------- running a model


class Net:
    def __init__(self, file, device, half=False):
        import torch
        self.torch = torch
        self.device = device
        self.half = half
        self.model = torch.jit.load(str(MODELS / file), map_location="cpu").eval().to(device)

    def __call__(self, x, cond=None):
        th = self.torch
        t = th.from_numpy(np.ascontiguousarray(x, np.float32))[None].to(self.device)
        args = [t] if cond is None else [t, th.tensor([[cond]], dtype=th.float32, device=self.device)]
        with th.no_grad():
            if self.half:
                with th.autocast(device_type=self.device, dtype=th.float16):
                    y = self.model(*args)
            else:
                y = self.model(*args)
        return y[0].float().cpu().numpy()


def tiled(fn, x, tile, overlap=0.25):
    """Runs fn over tile x tile windows of x (C, H, W) overlapping by `overlap`, blended linearly."""
    _, h, w = x.shape
    if h <= tile and w <= tile:
        return fn(x)
    step = int(tile * (1 - overlap))
    starts = lambda n: sorted(set(list(range(0, n - tile + 1, step)) + [n - tile]))
    ramp = np.minimum(np.minimum(np.arange(tile) + 1, tile - np.arange(tile)), tile - step).astype(np.float32)
    window = np.outer(ramp, ramp)
    out, weight = None, np.zeros((h, w), np.float32)
    for y in starts(h):
        for x0 in starts(w):
            o = fn(x[:, y:y + tile, x0:x0 + tile])
            if out is None:
                out = np.zeros((o.shape[0], h, w), np.float32)
            out[:, y:y + tile, x0:x0 + tile] += o * window
            weight[y:y + tile, x0:x0 + tile] += window
    return out / weight


def timed(name, fn, *args):
    started = time.perf_counter()
    result = fn(*args)
    TIMES[name].append(time.perf_counter() - started)
    return result


def device():
    import torch
    return "mps" if torch.backends.mps.is_available() else "cpu"


# ----------------------------------------------------------------- inputs as RawForge makes them


def rggb_offset(tile):
    for oy in (0, 1):
        for ox in (0, 1):
            if tile[oy, ox] == 0 and tile[(oy + 1) % 2, (ox + 1) % 2] == 2:
                return oy, ox
    raise ValueError(f"not a Bayer tile: {tile}")


def treenet_rgb(mosaic, tile, cam_to_rec2020):
    """RawHandler.as_rgb(colorspace='lin_rec2020', Malvar 2004, clip): the matrix on each RGGB block, then the demosaic.

    Returns the (3, H, W) input and a function that takes the model's output back to camera RGB.
    """
    from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004
    oy, ox = rggb_offset(tile)
    pad = 4
    m = np.pad(mosaic, pad, mode="reflect")[oy:, ox:]  # reflect keeps a Bayer mosaic's phase
    h, w = (m.shape[0] // 2) * 2, (m.shape[1] // 2) * 2
    m = m[:h, :w]
    t = cam_to_rec2020
    block = np.array([
        [t[0, 0], t[0, 1] / 2, t[0, 1] / 2, t[0, 2]],
        [t[1, 0], t[1, 1], 0.0, t[1, 2]],
        [t[1, 0], 0.0, t[1, 1], t[1, 2]],
        [t[2, 0], t[2, 1] / 2, t[2, 1] / 2, t[2, 2]],
    ])
    rggb = np.stack([m[0::2, 0::2], m[0::2, 1::2], m[1::2, 0::2], m[1::2, 1::2]]).reshape(4, -1)
    rggb = (block @ rggb).reshape(4, h // 2, w // 2)
    mixed = np.zeros_like(m)
    mixed[0::2, 0::2], mixed[0::2, 1::2], mixed[1::2, 0::2], mixed[1::2, 1::2] = rggb
    rgb = np.clip(demosaicing_CFA_Bayer_Malvar2004(mixed, "RGGB"), 0, 1).transpose(2, 0, 1).astype(np.float32)
    inverse = np.linalg.inv(cam_to_rec2020)

    def back(out):
        cam = np.einsum("ij,jhw->ihw", inverse, out)
        return cam[:, pad - oy:pad - oy + mosaic.shape[0], pad - ox:pad - ox + mosaic.shape[1]]
    return rgb, back


def six_channels(mosaic, tile, black, subtract_black):
    """RawHandlerRawpy.compute_mask_and_sparse, from a normalised mosaic: raw / white, black kept unless subtracted."""
    index = cfa_index(tile, *mosaic.shape)
    v = mosaic * (1 - black) + (0 if subtract_black else black)
    v = np.clip(v, 0, 1)
    mask = np.stack([index == c for c in range(3)]).astype(np.float32)
    return np.concatenate([mask * v[None], mask]).astype(np.float32)


def libraw_rgb(mosaic, raf, y0, x0):
    """LibRaw's demosaic as RawForge's 'rawpy' path calls it, on `mosaic` written into `raf` at (y0, x0)."""
    import rawpy
    raw = rawpy.imread(str(raf))
    black, white = float(np.mean(raw.black_level_per_channel)), float(raw.white_level)
    h, w = mosaic.shape
    raw.raw_image_visible[y0:y0 + h, x0:x0 + w] = np.clip(np.round(black + mosaic * (white - black)), 0, 65535).astype(np.uint16)
    out = raw.postprocess(
        user_wb=[1, 1, 1, 1], output_color=rawpy.ColorSpace.raw, demosaic_algorithm=rawpy.DemosaicAlgorithm(3),
        no_auto_bright=True, use_camera_wb=False, use_auto_wb=False, gamma=(1, 1), user_flip=0, output_bps=16,
        no_auto_scale=True,
    )
    rgb = out[y0:y0 + h, x0:x0 + w].astype(np.float32).transpose(2, 0, 1) / white
    return rgb, white / (white - black)


# ----------------------------------------------------------------- the models on one mosaic


def run_bayer(nets, out_dir, mosaic, tile, gains, cam_to_rec2020, iso, black):
    rgb, back = treenet_rgb(mosaic, tile, cam_to_rec2020)
    g = np.array(gains, np.float32)[:, None, None]
    for name, net in nets["treenet"].items():
        out = timed(name, tiled, lambda x: net(x, min(iso, 65535) / 6400), rgb, 256)
        save_f32(out_dir / f"model-{name}.f32", (back(out) * g).transpose(1, 2, 0))
    run_jdds(nets, out_dir, mosaic, tile, gains, black)


def run_jdds(nets, out_dir, mosaic, tile, gains, black):
    g = np.array(gains, np.float32)[:, None, None]
    for name, (_, size, subtract) in JDDS.items():
        x = six_channels(mosaic, tile, black, subtract)
        out = timed(name, tiled, nets["jdd"][name], x, size)
        out = (out if subtract else out - black) / (1 - black)
        save_f32(out_dir / f"model-{name}.f32", (out * g).transpose(1, 2, 0))


def run_xtrans(nets, out_dir, mosaic, tile, gains, raf, y0, x0):
    rgb, scale = libraw_rgb(mosaic, raf, y0, x0)
    g = np.array(gains, np.float32)[:, None, None]
    for name, (_, size) in XTRANS_MODELS.items():
        out = timed(name, tiled, lambda x: nets["xtrans"][name](x, 0.0), rgb, size)
        save_f32(out_dir / f"model-{name}.f32", (out * scale * g).transpose(1, 2, 0))
    save_f32(out_dir / "rr-libraw-3pass.f32", (rgb * scale * g).transpose(1, 2, 0))


def load_nets(dev, half=False):
    jdd_dev = dev if dev in ("cpu", "mps") else "cpu"
    return {
        "treenet": {name: Net(file, dev, half) for name, file in BAYER_TREENETS.items()},
        "jdd": {name: Net(f"{file}.{jdd_dev}.pt", jdd_dev, half) for name, (file, _, _) in JDDS.items()},
        "xtrans": {name: Net(file, dev, half) for name, (file, _) in XTRANS_MODELS.items()},
    }


# ----------------------------------------------------------------- the test sets


def synthetic():
    manifest = read_json(TESTSET / "manifest.json")
    nets = load_nets(device())
    wb = np.diag(AS_SHOT)  # the synthetic camera: balanced camera RGB stands for linear Rec. 2020
    for scene in manifest["scenes"]:
        renders = OUT / "renders" / scene
        for cfa_name, tile in CFAS.items():
            for level in NOISE_LEVELS:
                out = renders / cfa_name / level
                noisy = np.fromfile(TESTSET / scene / f"{cfa_name}-{level}.f32", "<f4").reshape(SIZE, SIZE)
                iso = int(level.removeprefix("iso"))
                if cfa_name == "bayer":
                    run_bayer(nets, out, noisy, tile, AS_SHOT, wb, iso, SONY_BLACK)
                else:
                    run_xtrans(nets, out, noisy, tile, AS_SHOT, RAF, OFFSET, OFFSET)
                    run_jdds(nets, out, noisy, tile, AS_SHOT, 1022 / 16383)
            print(scene, cfa_name, flush=True)
    write_json(OUT / "rawrefinery-timings.json", {k: float(np.median(v)) for k, v in TIMES.items()})


def real():
    import rawpy
    meta = read_json(REAL / "meta.json")
    harness = read_json(REAL / "harness" / "jobs.json")
    subset = {f"{e['cfa'].lower().replace('-', '')}-{e['scene']}": e for e in read_json(ROOT / "build/proto-data/raw-denoise/rawnind/subset.json")}
    nets = load_nets(device())
    for name, m in meta.items():
        base = REAL / name
        colc = np.load(base / "colors.npy")
        tile = colc[:m["tile"], :m["tile"]]
        gains = next(j["asShot"] for j in harness if j["name"] == f"{name}-gt")
        gt_file = ROOT / "build/proto-data/raw-denoise/rawnind" / subset[name]["gt"]
        raw = rawpy.imread(str(gt_file))
        black = float(np.mean(raw.black_level_per_channel)) / raw.white_level
        cam_to_rec2020 = XYZ_TO_REC2020 @ np.linalg.inv(raw.rgb_xyz_matrix[:3])
        x0, y0 = m["origin"]
        for iso, info in m["isos"].items():
            out = base / f"iso{iso}"
            noisy = np.fromfile(out / "noisy.f32", "<f4").reshape(SIZE, SIZE)
            if m["tile"] == 2:
                run_bayer(nets, out, noisy, tile, gains, cam_to_rec2020, int(iso), black)
            else:
                run_xtrans(nets, out, noisy, tile, gains, gt_file, y0, x0)
                run_jdds(nets, out, noisy, tile, gains, black)
            print(name, iso, flush=True)


def fp16():
    """The default denoisers as RawForge runs them on a GPU (autocast to float16) against float32."""
    if device() != "mps":
        raise SystemExit("needs the GPU (MPS)")
    full, half = load_nets("mps"), load_nets("mps", half=True)
    rows = []
    for scene in ["photo-sony", "text", "leaves"]:
        for level in NOISE_LEVELS:
            noisy = np.fromfile(TESTSET / scene / f"bayer-{level}.f32", "<f4").reshape(SIZE, SIZE)
            rgb, _ = treenet_rgb(noisy, CFAS["bayer"], np.diag(AS_SHOT))
            cond = int(level.removeprefix("iso")) / 6400
            pairs = [("rr-treenet", lambda n: tiled(lambda x: n["treenet"]["rr-treenet"](x, cond), rgb, 256)),
                     ("rr-jdd", lambda n: n["jdd"]["rr-jdd"](six_channels(noisy, CFAS["bayer"], SONY_BLACK, False)))]
            for name, run in pairs:
                a, b = run(full), run(half)
                bad = int(np.count_nonzero(~np.isfinite(b)))
                diff = np.abs(np.nan_to_num(b) - a)
                psnr = 10 * np.log10(1 / max(float(np.mean(diff ** 2)), 1e-12))
                rows.append({"scene": scene, "level": level, "model": name, "nonfinite": bad,
                             "max_abs": float(diff.max()), "psnr_vs_fp32": psnr})
                print(rows[-1], flush=True)
    write_json(OUT / "rawrefinery-fp16.json", rows)


def conditioning():
    """TreeNet's response to its ISO input: each level's photos at conditioning values from ISO 800 to 204800."""
    from score import fidelity
    net = Net(BAYER_TREENETS["rr-treenet"], device())
    rows = []
    for level in NOISE_LEVELS:
        for iso in (800, 3200, 12800, 51200, 204800):
            scores = []
            for scene in PHOTOS:
                noisy = np.fromfile(TESTSET / scene / f"bayer-{level}.f32", "<f4").reshape(SIZE, SIZE)
                truth = np.fromfile(TESTSET / scene / "truth.f32", "<f4").reshape(SIZE, SIZE, 3)
                rgb, back = treenet_rgb(noisy, CFAS["bayer"], np.diag(AS_SHOT))
                out = tiled(lambda x: net(x, min(iso, 65535) / 6400), rgb, 256)
                scores.append(fidelity((back(out) * np.array(AS_SHOT, np.float32)[:, None, None]).transpose(1, 2, 0), truth))
            rows.append({"level": level, "iso": iso, "cpsnr": float(np.mean([s["cpsnr"] for s in scores])),
                         "texture": float(np.mean([s["texture"] for s in scores]))})
            print(rows[-1], flush=True)
    write_json(OUT / "rawrefinery-conditioning.json", rows)


def figures():
    """The study's contact sheets, from the CC0 Sony crop and the synthetic text chart (build/dn11-venv)."""
    from figures import camera_to_srgb, sheet
    bayer = [
        ("Redlamp, Luminance 50", "rl-l50"),
        ("Buades 2026, then Redlamp (research only)", "model-buades"),
        ("RawRefinery TreeNet", "model-rr-treenet"),
        ("RawRefinery TreeNet SuperLight", "model-rr-treenet-superlight"),
        ("RawForge joint model (JDD)", "model-rr-jdd"),
    ]
    xtrans = [
        ("Redlamp, Markesteijn, Luminance 50", "mk-l50"),
        ("RawForge X-Trans TreeNet", "model-rr-xtrans-treenet"),
        ("RawForge X-Trans Restormer", "model-rr-xtrans-restormer"),
        ("RawForge JDD (no X-Trans training)", "model-rr-jdd"),
    ]
    sheet("photo-sony", "bayer", "iso51200", bayer, (300, 360, 128), matrix=camera_to_srgb(),
          name="rawrefinery-sheet-photo-sony-bayer-iso51200.jpg")
    sheet("text", "bayer", "iso51200", bayer, (16, 8, 128), name="rawrefinery-sheet-text-bayer-iso51200.jpg")
    sheet("text", "xtrans", "iso51200", xtrans, (16, 8, 128), name="rawrefinery-sheet-text-xtrans-iso51200.jpg")


# ----------------------------------------------------------------- tables


PHOTOS = ["photo-sony", "photo-nikon", "photo-canon", "photo-fuji", "leaves"]
SYNTHETIC_ROWS = {
    "bayer": [
        ("rl-c25", "Redlamp default (Color 25)"),
        ("rl-l25", "Redlamp, Luminance 25"),
        ("rl-l50", "Redlamp, Luminance 50"),
        ("pre-half-l25", "Half mosaic NL-means, then Luminance 25"),
        ("model-buades", "Buades 2026, then Redlamp's demosaic"),
        ("model-pmrid", "PMRID, then Redlamp's demosaic"),
        ("model-nind", "RawNIND joint (darktable's model)"),
        ("model-gharbi", "Gharbi 2016 joint, noise-aware"),
        ("model-rr-treenet", "RawRefinery TreeNet (default)"),
        ("model-rr-treenet-heavy", "RawRefinery TreeNet Heavy"),
        ("model-rr-treenet-light", "RawRefinery TreeNet Light"),
        ("model-rr-treenet-superlight", "RawRefinery TreeNet SuperLight"),
        ("model-rr-jdd", "RawForge JDD (joint, 768 px tiles)"),
        ("model-rr-jdd256", "RawForge JDD256 (joint, 256 px tiles)"),
    ],
    "xtrans": [
        ("mk-c25", "Redlamp, Markesteijn, Color 25"),
        ("mk-l25", "Redlamp, Markesteijn, Luminance 25"),
        ("mk-l50", "Redlamp, Markesteijn, Luminance 50"),
        ("rr-libraw-3pass", "LibRaw Markesteijn 3 passes, no noise reduction"),
        ("model-nind-linear", "RawNIND linear, after Redlamp's old X-Trans demosaic"),
        ("model-rr-xtrans-treenet", "RawForge X-Trans TreeNet, after LibRaw's demosaic"),
        ("model-rr-xtrans-restormer", "RawForge X-Trans Restormer, after LibRaw's demosaic"),
        ("model-rr-jdd", "RawForge JDD (joint, 768 px tiles)"),
        ("model-rr-jdd256", "RawForge JDD256 (joint, 256 px tiles)"),
    ],
}


def summary():
    import json
    scores = json.load(open(OUT / "scores.json"))
    by = collections.defaultdict(dict)
    for s in scores:
        by[(s["scene"], s["cfa"], s["level"])][s["method"]] = s
    lines = ["# RawRefinery on the DN-11 test set", ""]
    for cfa, rows in SYNTHETIC_ROWS.items():
        lines += [f"## {cfa}: photos and dead leaves, colour PSNR (dB) / texture kept", "",
                  "| Method | " + " | ".join(NOISE_LEVELS) + " |", "| --- |" + " --- |" * len(NOISE_LEVELS)]
        for method, label in rows:
            cells = []
            for level in NOISE_LEVELS:
                vals = [by[(s, cfa, level)][method] for s in PHOTOS if method in by[(s, cfa, level)]]
                cells.append(f"{np.mean([v['cpsnr'] for v in vals]):.2f} / {np.mean([v['texture'] for v in vals]):.2f}"
                             if len(vals) == len(PHOTOS) else "")
            if any(cells):
                lines.append(f"| {label} | " + " | ".join(cells) + " |")
        lines.append("")
        lines += [f"## {cfa}: charts at each level (edge MTF50, zone false colour, text PSNR, flat chroma noise, shadow bias)", "",
                  "| Method | Level | Edge MTF50 | Zone false colour | Text PSNR | Flat luma noise | Flat chroma noise | Shadow colour bias |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        for level in NOISE_LEVELS:
            for method, label in rows:
                e, z, t = (by[(scene, cfa, level)].get(method) for scene in ("edge", "zone", "text"))
                if e and z and t:
                    lines.append(f"| {label} | {level} | {e['edge_mtf50']:.3f} | {z['false_colour']:.4f} | {t['cpsnr']:.2f} | "
                                 f"{t['flat_luma_noise']:.4f} | {t['flat_chroma_noise']:.4f} | {t['shadow_bias']:.4f} |")
        lines.append("")
    if (REAL / "scores.json").exists():
        rows = json.load(open(REAL / "scores.json"))
        meta = read_json(REAL / "meta.json")
        table = collections.defaultdict(list)
        for r in rows:
            level = "highest" if r["iso"] == max(int(i) for i in meta[r["scene"]]["isos"]) else "lower"
            table[(r["cfa"], level, r["method"])].append(r)
        lines += ["## Real RawNIND pairs (in RawRefinery's training data): colour PSNR full resolution / binned, texture", "",
                  "| CFA | ISO | Method | Pairs | Full resolution | Binned | Texture |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for (cfa, level, method), v in sorted(table.items()):
            lines.append(f"| {cfa} | {level} | {method} | {len(v)} | {np.mean([x['cpsnr'] for x in v]):.2f} | "
                         f"{np.mean([x['cpsnr_binned'] for x in v]):.2f} | {np.mean([x['texture'] for x in v]):.2f} |")
    (OUT / "rawrefinery-summary.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    {"fetch": fetch, "synthetic": synthetic, "real": real, "fp16": fp16, "conditioning": conditioning,
     "figures": figures, "summary": summary}[sys.argv[1]]()
