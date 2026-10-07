"""Shared definitions for the DN-11 raw denoise study: CFA patterns, noise levels, file layout."""

import json
import os
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT / "build/proto-data/raw-denoise"
OUT = ROOT / "build/proto-out/raw-denoise"
TESTSET = DATA / "testset"

# Row-major CFA tiles, 0 red, 1 green, 2 blue. The X-Trans tile is Redlamp's test pattern
# (DetailStageTests.makeSession), invariant under a (3, 3) shift.
BAYER = np.array([[0, 1], [1, 2]])
XTRANS = np.array([
    [1, 1, 0, 1, 1, 2],
    [1, 1, 2, 1, 1, 0],
    [2, 0, 1, 0, 2, 1],
    [1, 1, 2, 1, 1, 0],
    [1, 1, 0, 1, 1, 2],
    [0, 2, 1, 2, 0, 1],
])
CFAS = {"bayer": BAYER, "xtrans": XTRANS}

# Poisson-Gaussian noise in normalised raw units (0 black, 1 white), the same for every channel
# before white balance: variance = a * value + b. a is about 1 / full-well electrons at the ISO
# (the DNG specification's reference is S = 2e-5 at ISO 100); b is read noise squared.
NOISE_LEVELS = {
    "iso3200": (6.4e-4, 1.0e-6),
    "iso12800": (2.56e-3, 1.6e-5),
    "iso51200": (1.02e-2, 1.5e-4),
}

# A typical daylight white balance (red and blue gains over green), so the raw is green-heavy.
AS_SHOT = (2.2, 1.0, 1.75)

SIZE = 768  # a multiple of 6, for X-Trans


def cfa_index(cfa: np.ndarray, height: int, width: int) -> np.ndarray:
    """The colour of every photosite."""
    th, tw = cfa.shape
    return np.tile(cfa, (height // th + 1, width // tw + 1))[:height, :width]


def mosaic(rgb: np.ndarray, cfa: np.ndarray) -> np.ndarray:
    """Samples a balanced camera RGB image through `cfa` and removes the white balance."""
    h, w, _ = rgb.shape
    index = cfa_index(cfa, h, w)
    raw = np.take_along_axis(rgb, index[..., None], axis=2)[..., 0]
    gains = np.array(AS_SHOT, dtype=np.float32)
    return (raw / gains[index]).astype(np.float32)


def add_noise(raw: np.ndarray, a: float, b: float, seed: int) -> np.ndarray:
    """Exact Poisson-Gaussian noise: Poisson counts at gain a, plus Gaussian read noise."""
    rng = np.random.default_rng(seed)
    counts = rng.poisson(np.maximum(raw, 0) / a)
    return (counts * a + rng.normal(0, np.sqrt(b), raw.shape)).astype(np.float32)


def balance(raw: np.ndarray, cfa: np.ndarray) -> np.ndarray:
    """Applies the white balance to a mosaic (still one value per photosite)."""
    index = cfa_index(cfa, *raw.shape)
    return raw * np.array(AS_SHOT, dtype=np.float32)[index]


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1))


def read_json(path: Path):
    return json.loads(Path(path).read_text())


def save_f32(path: Path, array: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    np.ascontiguousarray(array, dtype="<f4").tofile(path)


def load_rgb(path: Path, height: int, width: int) -> np.ndarray:
    return np.fromfile(path, dtype="<f4").reshape(height, width, 3)


os.makedirs(DATA, exist_ok=True)
