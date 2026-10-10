"""Auto's Basic values (ImageAnalysis.autoTone) from balanced camera RGB, as the engine computes them
from its analysis copy (the pyramid's level with a long edge near 1024)."""
import numpy as np

import cam08

LUMA = np.array([0.2627, 0.6780, 0.0593])


def analysis(rgb: np.ndarray, full_long_edge: int) -> np.ndarray:
    """The pyramid level SessionBuilder reads: 2^level box filtering of full resolution."""
    levels = int(np.log2(full_long_edge)) + 1
    level = max(0, levels - 1 - int(np.log2(1024)))
    # `rgb` is already binned by the mosaic block; box-filter the rest of the way.
    return rgb, level


def auto_tone(m: cam08.Mosaic, rgb: np.ndarray, block_factor: int) -> dict:
    full = max(m.raw.shape)
    levels = int(np.log2(full)) + 1
    level = max(0, levels - 1 - int(np.log2(1024)))
    step = max(1, (1 << level) // block_factor)
    h, w = (rgb.shape[0] // step) * step, (rgb.shape[1] // step) * step
    small = rgb[:h, :w].reshape(h // step, step, w // step, step, 3).mean(axis=(1, 3)).reshape(-1, 3)
    scene = np.maximum(small @ (cam08.SRGB_TO_REC2020 @ m.rgb_cam).T, 0)
    luminances = np.maximum(scene @ LUMA, 1e-5)
    peaks = scene.max(axis=1)
    values = np.sort(luminances)
    peaks = np.sort(peaks)

    def percentile(sorted_values, p):
        return float(sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * p))])

    log_average = float(np.exp(np.mean(np.log(values))))
    midtones = min(max(np.log2(0.16 / log_average) * 0.8, -3), 3)
    held, reach = 1.0, 1.0
    brightest = percentile(peaks, 0.99)
    exposure = min(midtones, max(np.log2(held / brightest) + reach, midtones - 1, 0))
    scale = 2 ** exposure
    pulled = min(max(np.log2(brightest * scale / held), 0), reach)
    bright = brightest * scale / 2 ** pulled
    dark = percentile(values, 0.02) * scale
    highlights = -pulled / 1.25 * 100
    shadows = min((0.01 - dark) * 3000, 45) if dark < 0.01 else 0
    whites = min((0.7 - bright) * 60, 30) if bright < 0.7 else -min(max(bright - 1.2, 0) * 20, 20)
    blacks = -min((dark - 0.03) * 400, 25) if dark > 0.03 else 0
    return {"basic.exposure": round(exposure, 2), "basic.contrast": 8, "basic.highlights": round(highlights),
            "basic.shadows": round(shadows), "basic.whites": round(whites), "basic.blacks": round(blacks),
            "basic.vibrance": 10}
