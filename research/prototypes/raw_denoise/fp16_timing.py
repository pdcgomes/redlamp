"""DN-17: float16 against float32 at the tile sizes each model would run at, and a 24 MP photo's time and memory.

Inputs are the CC0 Sony A7 III (Bayer, 24 MP) and Fujifilm X-T3 (X-Trans, 26 MP) fixtures, exposed as make_testset.py
exposes its photos (median green 0.15) and given the three synthetic noise levels.

    R=../../../build/rawdn-venv/bin/python; M="env PYTHONPATH=../../../build/oss/nonlocal-matchfilter/src:models/stubs:models $R -W ignore"
    $M fp16_timing.py prepare                  # the noisy mosaics, and AutoShade's network inputs as tiles for Core ML
    $M fp16_timing.py fp16 autoshade|jdd|starfish|buades   # float16 against float32: MPS (Buades: CPU, no Metal kernel)
    $M fp16_timing.py time autoshade|jdd|starfish|buades   # one 24 MP photo: seconds and peak memory, one model per process
    ../../../build/coreml-venv/bin/python fp16_timing.py coreml autoshade   # coremltools: the Neural Engine and the GPU in float16

Each writes JSON rows to build/proto-out/raw-denoise/fp16/, with the load average when it ran.
"""

import json
import os
import resource
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "models"))
from common import NOISE_LEVELS, OUT, ROOT, add_noise  # noqa: E402

FOLDER = OUT / "fp16"
MODELS = ROOT / "build/proto-data/raw-denoise/models"
TILES = (256, 512, 768)
SOURCES = {"bayer": "_DSC0009.ARW", "xtrans": "AFXT2720.RAF"}
GAINS = {"bayer": (2.2, 1.0, 1.75), "xtrans": (2.0, 1.0, 1.6)}


def load_avg():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()


def peak_rss_gb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9  # bytes on macOS


def write_rows(name, rows):
    FOLDER.mkdir(parents=True, exist_ok=True)
    path = FOLDER / f"{name}.json"
    path.write_text(json.dumps(rows, indent=1))
    print(f"wrote {path}")


# ----------------------------------------------------------------- inputs


def prepare():
    import rawpy
    FOLDER.mkdir(parents=True, exist_ok=True)
    for cfa_name, file in SOURCES.items():
        raw = rawpy.imread(str(ROOT / "tests/fixtures/raw" / file))
        data = raw.raw_image_visible.astype(np.float32)
        colours = raw.raw_colors_visible.copy()
        colours[colours == 3] = 1
        black = np.array(raw.black_level_per_channel, np.float32)[raw.raw_colors_visible]
        x = (data - black) / (raw.white_level - black)
        p = 2 if cfa_name == "bayer" else 6
        h, w = x.shape[0] // p * p, x.shape[1] // p * p
        x, colours = x[:h, :w], colours[:h, :w]
        x = np.clip(x * (0.15 / max(np.median(x[colours == 1]), 1e-4)), 0, 1).astype(np.float32)
        tile = colours[:p, :p]
        np.save(FOLDER / f"{cfa_name}-tile.npy", tile)
        for l, (level, (a, b)) in enumerate(NOISE_LEVELS.items()):
            np.save(FOLDER / f"{cfa_name}-{level}.npy", add_noise(x, a, b, seed=77 + l))
        print(cfa_name, file, x.shape, "tile", tile.tolist())
    autoshade_tiles()


def mosaic(cfa_name, level):
    return np.load(FOLDER / f"{cfa_name}-{level}.npy"), np.load(FOLDER / f"{cfa_name}-tile.npy")


def autoshade_inputs(noisy, tile, a, b):
    """AutoShade's network input for the frame: the (R, G1, B) triplet in [0, 1] and the sigma."""
    import autoshade_raw as asr
    where = asr.phases(tile)
    planes = {n: np.minimum(p, 1.0).astype(np.float32) for n, p in asr.split_planes(noisy, where).items()}
    ab = {n: (a, b) for n in asr.PLANES}
    z = {n: asr.gat(p, *ab[n]) for n, p in planes.items()}
    lo, span = asr.model_affine(ab)
    fields = {n: asr.noise_field(z[n], planes[n] >= 1.0) for n in asr.PLANES}
    span /= min(float(f.min()) for f in fields.values())
    zn = {n: np.clip((z[n] / asr.field_at(fields[n], z[n].shape) - lo) / span, 0, 1).astype(np.float32) for n in asr.PLANES}
    return np.stack([zn["R"], zn["G1"], zn["B"]], 0), asr.SIGMA_SCALE / span


def centre_crop(x, size):
    h, w = x.shape[-2:]
    y0, x0 = (h - size) // 2 // 6 * 6, (w - size) // 2 // 6 * 6
    return x[..., y0:y0 + size, x0:x0 + size]


def autoshade_tiles():
    for level, (a, b) in NOISE_LEVELS.items():
        noisy, tile = mosaic("bayer", level)
        triplet, sigma = autoshade_inputs(noisy, tile, a, b)
        for size in TILES:
            t = centre_crop(triplet, size)
            x = np.concatenate([t, np.full((1, size, size), sigma, np.float32)], 0)[None]
            np.save(FOLDER / f"autoshade-input-{level}-{size}.npy", x.astype(np.float32))
    print("AutoShade tiles saved")


# ----------------------------------------------------------------- float16 against float32


def compare(a, b):
    bad = int(np.count_nonzero(~np.isfinite(b)))
    diff = np.abs(np.nan_to_num(b, nan=0, posinf=0, neginf=0) - a)
    psnr = 10 * np.log10(1 / max(float(np.mean(diff ** 2)), 1e-12)) if bad == 0 else None
    return {"nonfinite": bad, "nonfinite_share": bad / b.size, "max_abs": float(diff.max()), "psnr_vs_fp32": psnr}


def fp16(model):
    import torch
    rows = []
    started = load_avg()
    if model == "autoshade":
        import autoshade_raw as asr
        net = asr.load_model(MODELS / "autoshade", "mps")
        for level in NOISE_LEVELS:
            for size in TILES:
                x = torch.from_numpy(np.load(FOLDER / f"autoshade-input-{level}-{size}.npy"))
                with torch.no_grad():
                    ref = net(x.to("mps")).float().cpu().numpy()
                    with torch.autocast(device_type="mps", dtype=torch.float16):
                        auto = net(x.to("mps")).float().cpu().numpy()
                    half = net.half()(x.half().to("mps")).float().cpu().numpy()
                    net.float()
                for mode, out in (("autocast", auto), ("half", half)):
                    rows.append({"model": model, "device": "mps", "level": level, "tile": size, "mode": mode, **compare(ref, out)})
                    print(rows[-1], flush=True)
    elif model == "jdd":
        import run_rawrefinery as rr
        full = rr.Net(f"{rr.JDDS['rr-jdd'][0]}.mps.pt", "mps")
        half = rr.Net(f"{rr.JDDS['rr-jdd'][0]}.mps.pt", "mps", half=True)
        for level in NOISE_LEVELS:
            noisy, tile = mosaic("bayer", level)
            for size in TILES:
                x = rr.six_channels(centre_crop(noisy, size), tile, rr.SONY_BLACK, False)
                rows.append({"model": model, "device": "mps", "level": level, "tile": size, "mode": "autocast",
                             **compare(full(x), half(x))})
                print(rows[-1], flush=True)
    elif model == "starfish":
        from run_models import Starfish
        sf = Starfish()
        for cfa_name in SOURCES:
            for level, (a, b) in NOISE_LEVELS.items():
                noisy, tile = mosaic(cfa_name, level)
                for size in TILES:
                    size = size // tile.shape[0] * tile.shape[0]  # X-Trans windows: 252, 510, 768
                    m = centre_crop(noisy, size)
                    ref = sf(m, tile, GAINS[cfa_name], [a] * 3, [b] * 3)
                    out = sf(m, tile, GAINS[cfa_name], [a] * 3, [b] * 3, half=True)
                    rows.append({"model": model, "cfa": cfa_name, "device": "mps", "level": level, "tile": size,
                                 "mode": "autocast", **compare(ref, out)})
                    print(rows[-1], flush=True)
    elif model == "buades":
        from run_models import Buades
        bu = Buades()
        for level, (a, b) in NOISE_LEVELS.items():
            noisy, tile = mosaic("bayer", level)
            for size in TILES:
                m = centre_crop(noisy, size)
                ref = bu(m, tile, [a] * 3, [b] * 3)
                bu.net.half()
                try:
                    result = compare(ref, BuadesHalf(bu)(m, tile, [a] * 3, [b] * 3))
                except RuntimeError as error:
                    result = {"error": str(error).splitlines()[0]}
                bu.net.float()
                rows.append({"model": model, "device": "cpu", "level": level, "tile": size, "mode": "half", **result})
                print(rows[-1], flush=True)
    for r in rows:
        r["load"] = started
    write_rows(f"fp16-{model}", rows)


class BuadesHalf:
    """Buades 2026 with its network and input in float16 (on the CPU: its sampling kernel has no Metal version)."""

    def __init__(self, buades):
        self.b = buades

    def __call__(self, raw, tile, a, b):
        import torch
        from run_models import BAYER, rggb_offset
        oy, ox = rggb_offset(tile)
        pad = 8
        m = np.pad(raw, pad, mode="reflect")[oy:, ox:]
        h, w = (m.shape[0] // 8) * 8, (m.shape[1] // 8) * 8
        m = np.clip(m[:h, :w], 0, 1)
        index = np.tile(BAYER, (h // 2, w // 2))
        sigma = np.sqrt(np.maximum(np.array(a, np.float32)[index] * m + np.array(b, np.float32)[index], 0))
        pack = lambda z: np.stack([z[0::2, 0::2], z[0::2, 1::2], z[1::2, 1::2], z[1::2, 0::2]])
        x = np.concatenate([pack(m), pack(sigma)])[None].astype(np.float16)
        with torch.no_grad():
            y = self.b.net(torch.from_numpy(x)).float().clamp(0, 1)[0].numpy()
        out = np.zeros((h, w), np.float32)
        out[0::2, 0::2], out[0::2, 1::2], out[1::2, 1::2], out[1::2, 0::2] = y
        return out[pad - oy:pad - oy + raw.shape[0], pad - ox:pad - ox + raw.shape[1]]


# ----------------------------------------------------------------- a 24 MP photo


class MPSPeak:
    def __init__(self):
        import torch
        self.torch, self.peak = torch, 0

    def sample(self):
        if self.torch.backends.mps.is_available():
            self.peak = max(self.peak, self.torch.mps.driver_allocated_memory())


def tiled_mosaic(fn, raw, size, overlap, period):
    """fn on overlapping size x size windows of a mosaic, blended linearly; window corners keep the CFA phase."""
    h, w = raw.shape
    step = (size - overlap) // period * period
    starts = lambda n: sorted(set(list(range(0, max(n - size, 0) + 1, step)) + [max(n - size, 0) // period * period]))
    ramp = np.minimum(np.minimum(np.arange(size) + 1, size - np.arange(size)), overlap).astype(np.float32)
    out, weight = None, np.zeros((h, w), np.float32)
    for y in starts(h):
        for x in starts(w):
            o = fn(raw[y:y + size, x:x + size], y, x)
            win = np.outer(ramp[:o.shape[0]], ramp[:o.shape[1]])
            if out is None:
                out = np.zeros((h, w) + o.shape[2:], np.float32)
            out[y:y + o.shape[0], x:x + o.shape[1]] += o * (win[..., None] if o.ndim == 3 else win)
            weight[y:y + o.shape[0], x:x + o.shape[1]] += win
    return out / (weight[..., None] if out.ndim == 3 else weight)


def time_model(model, level="iso12800", dtype=None):
    import torch
    a, b = NOISE_LEVELS[level]
    cfa_name = "bayer"
    noisy, tile = mosaic(cfa_name, level)
    noisy = noisy[:noisy.shape[0] // 6 * 6, :noisy.shape[1] // 6 * 6]
    peak = MPSPeak()
    rows = []
    before = load_avg()
    started = time.perf_counter()
    if model == "autoshade":
        import autoshade_raw as asr
        net = asr.load_model(MODELS / "autoshade", "mps")
        asr.denoise(noisy[:1024, :1024], tile, net, "mps", [a] * 3, [b] * 3, dtype=dtype)  # warm-up
        started = time.perf_counter()
        out = asr.denoise(noisy, tile, net, "mps", [a] * 3, [b] * 3, dtype=dtype)
        peak.sample()
    elif model == "jdd":
        import run_rawrefinery as rr
        size = 768 if dtype is None else 512
        net = rr.Net(f"{rr.JDDS['rr-jdd'][0]}.mps.pt", "mps", half=dtype is not None)
        net(rr.six_channels(noisy[:size, :size], tile, rr.SONY_BLACK, False))
        started = time.perf_counter()

        def window(m, y, x):
            o = net(rr.six_channels(m, tile, rr.SONY_BLACK, False))
            peak.sample()
            return (o - rr.SONY_BLACK).transpose(1, 2, 0)
        out = tiled_mosaic(window, noisy, size, size // 4, 2)
    elif model == "starfish":
        from run_models import Starfish
        sf = Starfish()
        sf(noisy[:1056, :1056], tile, GAINS[cfa_name], [a] * 3, [b] * 3)
        started = time.perf_counter()

        def window(m, y, x):
            o = sf(m, tile, GAINS[cfa_name], [a] * 3, [b] * 3, half=dtype is not None)
            peak.sample()
            return o
        out = tiled_mosaic(window, noisy, 1056, 96, 6)
    elif model == "buades":
        from run_models import Buades
        bu = Buades()
        torch.set_num_threads(os.cpu_count())
        started = time.perf_counter()
        out = tiled_mosaic(lambda m, y, x: bu(m, tile, [a] * 3, [b] * 3), noisy, 1024, 64, 2)
    seconds = time.perf_counter() - started
    rows.append({"model": model, "dtype": dtype or "float32", "level": level, "megapixels": noisy.size / 1e6,
                 "seconds": seconds, "peak_rss_gb": peak_rss_gb(), "peak_mps_driver_gb": peak.peak / 1e9,
                 "finite": bool(np.isfinite(out).all()), "load_before": before, "load_after": load_avg()})
    print(rows[-1], flush=True)
    return rows


def timing(model):
    rows = time_model(model)
    if model in ("autoshade", "jdd", "starfish"):
        rows += time_model(model, dtype="half" if model == "autoshade" else "autocast")
    path = FOLDER / f"time-{model}.json"
    previous = json.loads(path.read_text()) if path.exists() else []
    write_rows(f"time-{model}", previous + rows)


# ----------------------------------------------------------------- Core ML (build/coreml-venv)


def coreml(model):
    import coremltools as ct
    import torch
    rows = []
    started = load_avg()
    if model != "autoshade":
        raise SystemExit("Core ML: autoshade only")
    import autoshade_raw as asr
    net = asr.load_model(MODELS / "autoshade", "cpu")
    for size in TILES:
        example = torch.from_numpy(np.load(FOLDER / f"autoshade-input-iso12800-{size}.npy"))
        traced = torch.jit.trace(net, example)
        for precision, units in ((ct.precision.FLOAT16, ct.ComputeUnit.CPU_AND_NE), (ct.precision.FLOAT16, ct.ComputeUnit.CPU_AND_GPU),
                                 (ct.precision.FLOAT32, ct.ComputeUnit.CPU_ONLY)):
            t0 = time.perf_counter()
            ml = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=example.shape)], convert_to="mlprogram",
                            compute_precision=precision, compute_units=units, minimum_deployment_target=ct.target.macOS14)
            convert = time.perf_counter() - t0
            for level in NOISE_LEVELS:
                x = np.load(FOLDER / f"autoshade-input-{level}-{size}.npy")
                with torch.no_grad():
                    ref = net(torch.from_numpy(x)).numpy()
                key = list(ml.get_spec().description.output)[0].name
                out = ml.predict({"x": x})[key]
                runs = []
                for _ in range(3):
                    t0 = time.perf_counter()
                    ml.predict({"x": x})
                    runs.append(time.perf_counter() - t0)
                rows.append({"model": model, "tile": size, "level": level, "precision": str(precision).split(".")[-1],
                             "units": str(units).split(".")[-1], "convert_s": convert, "predict_s": float(np.median(runs)),
                             **compare(ref, np.asarray(out, np.float32))})
                print(rows[-1], flush=True)
    for r in rows:
        r["load"] = started
    write_rows(f"coreml-{model}", rows)


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "prepare":
        prepare()
    elif command == "fp16":
        fp16(sys.argv[2])
    elif command == "time":
        timing(sys.argv[2])
    elif command == "coreml":
        coreml(sys.argv[2])
