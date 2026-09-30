"""Shared paths, image I/O, colour conversions and degradations for the restoration bake-off."""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np

REPO = Path(__file__).resolve().parents[3]
DATA = REPO / "build/proto-data/restoration"
OUT = REPO / "build/proto-out/restoration"
WEIGHTS = DATA / "weights"
TESTSET = DATA / "testset"


def read_rgb(path: Path) -> np.ndarray:
    """Float32 RGB in [0, 1] from an 8- or 16-bit file."""
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None:
        raise FileNotFoundError(path)
    scale = 65535.0 if image.dtype == np.uint16 else 255.0
    image = image[..., :3][..., ::-1].astype(np.float32) / scale
    return np.ascontiguousarray(image)


def write_rgb(path: Path, image: np.ndarray, bits: int = 16) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image = np.clip(image, 0, 1)[..., ::-1]
    if bits == 16:
        cv2.imwrite(str(path), (image * 65535 + 0.5).astype(np.uint16))
    else:
        cv2.imwrite(str(path), (image * 255 + 0.5).astype(np.uint8))


def srgb_to_linear(x: np.ndarray) -> np.ndarray:
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


# --- Point spread functions -------------------------------------------------------------------


def disc_psf(radius: float) -> np.ndarray:
    """Uniform disc (defocus), anti-aliased by 8x supersampling."""
    size = int(np.ceil(radius)) * 2 + 1
    ss = 8
    grid = (np.arange(size * ss) + 0.5) / ss - size / 2
    yy, xx = np.meshgrid(grid, grid, indexing="ij")
    fine = (xx**2 + yy**2 <= radius**2).astype(np.float64)
    kernel = fine.reshape(size, ss, size, ss).mean(axis=(1, 3))
    return (kernel / kernel.sum()).astype(np.float32)


def gaussian_psf(sigma: float) -> np.ndarray:
    size = int(np.ceil(sigma * 3)) * 2 + 1
    g = cv2.getGaussianKernel(size, sigma)
    kernel = g @ g.T
    return (kernel / kernel.sum()).astype(np.float32)


def linear_motion_psf(length: int, angle_deg: float) -> np.ndarray:
    size = length + 2 if length % 2 else length + 3
    kernel = np.zeros((size * 8, size * 8), np.float32)
    c = size * 4
    dx, dy = np.cos(np.radians(angle_deg)), np.sin(np.radians(angle_deg))
    for t in np.linspace(-length * 4, length * 4, length * 64):
        kernel[int(round(c + t * dy)), int(round(c + t * dx))] = 1
    kernel = cv2.resize(kernel, (size, size), interpolation=cv2.INTER_AREA)
    return kernel / kernel.sum()


def trajectory_motion_psf(size: int = 21, seed: int = 7) -> np.ndarray:
    """Camera-shake trajectory: a smoothed random walk with momentum (Boracchi and Foi 2012 style)."""
    rng = np.random.default_rng(seed)
    steps = 2000
    velocity = rng.normal(size=2)
    velocity /= np.linalg.norm(velocity)
    position = np.zeros(2)
    points = []
    for _ in range(steps):
        velocity = 0.97 * velocity + 0.2 * rng.normal(size=2) - 0.002 * position
        velocity /= max(np.linalg.norm(velocity), 1e-6)
        position = position + velocity * 0.02
        points.append(position.copy())
    points = np.array(points)
    points -= points.mean(axis=0)
    points *= (size * 0.4) / np.abs(points).max()
    ss = 8
    kernel = np.zeros((size * ss, size * ss), np.float32)
    for x, y in points:
        kernel[int((y + size / 2) * ss), int((x + size / 2) * ss)] += 1
    kernel = cv2.resize(kernel, (size, size), interpolation=cv2.INTER_AREA)
    return kernel / kernel.sum()


def convolve_linear(srgb: np.ndarray, psf: np.ndarray) -> np.ndarray:
    """Blur in linear light, as a lens or camera shake does, with reflected borders."""
    linear = srgb_to_linear(srgb)
    blurred = cv2.filter2D(linear, -1, psf, borderType=cv2.BORDER_REFLECT)
    return linear_to_srgb(blurred)


def poisson_gaussian_noise(srgb: np.ndarray, a: float, b: float, seed: int) -> np.ndarray:
    """Signal-dependent sensor-like noise in linear light: variance = a * x + b."""
    rng = np.random.default_rng(seed)
    linear = srgb_to_linear(srgb)
    noisy = linear + rng.normal(size=linear.shape).astype(np.float32) * np.sqrt(a * np.clip(linear, 0, None) + b)
    return linear_to_srgb(noisy)


def downscale(srgb: np.ndarray, factor: int) -> np.ndarray:
    """Anti-aliased bicubic downscale in sRGB, the convention most SR models were trained on."""
    from PIL import Image

    h, w = srgb.shape[:2]
    channels = []
    for c in range(3):
        plane = Image.fromarray(srgb[..., c].astype(np.float32), mode="F")
        channels.append(np.asarray(plane.resize((w // factor, h // factor), Image.BICUBIC)))
    return np.clip(np.stack(channels, axis=-1), 0, 1)


def jpeg(srgb: np.ndarray, quality: int) -> np.ndarray:
    ok, buffer = cv2.imencode(".jpg", (np.clip(srgb, 0, 1)[..., ::-1] * 255 + 0.5).astype(np.uint8),
                              [cv2.IMWRITE_JPEG_QUALITY, quality])
    assert ok
    return cv2.imdecode(buffer, cv2.IMREAD_COLOR)[..., ::-1].astype(np.float32) / 255


def load_manifest() -> dict:
    return json.loads((TESTSET / "manifest.json").read_text())
