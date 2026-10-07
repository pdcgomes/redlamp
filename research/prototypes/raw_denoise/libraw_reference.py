"""LibRaw's own Markesteijn X-Trans demosaic (1 and 3 passes) on the test set's X-Trans mosaics.

LibRaw runs it from `dcraw_process`: quality 2 is one pass, 3 and above three (rawpy's PPG and AHD).
Each mosaic is written into the sensor data of the CC0 Fujifilm X-T3 raw at an offset that keeps the
CFA phase (the raw's visible tile is the test set's), processed with the test set's white balance,
no colour conversion and linear output, cropped back, and scaled to the truth's exposure by one gain
per channel. The outputs sit beside Redlamp's renders (`libraw-1pass.f32`, `libraw-3pass.f32`, and
`clean-libraw-*.f32` for the noise-free mosaics), so score.py scores them.
"""

import numpy as np
import rawpy

from common import AS_SHOT, OUT, ROOT, SIZE, TESTSET, XTRANS, load_rgb, read_json, save_f32

RAF = ROOT / "tests/fixtures/raw/AFXT2720.RAF"
OFFSET = 600  # a multiple of 6
PASSES = {"libraw-1pass": rawpy.DemosaicAlgorithm.PPG, "libraw-3pass": rawpy.DemosaicAlgorithm.AHD}


def demosaic(mosaic, algorithm):
    raw = rawpy.imread(str(RAF))
    assert np.array_equal(raw.raw_pattern, XTRANS)
    black = float(raw.black_level_per_channel[0])
    white = float(raw.white_level)
    visible = raw.raw_image_visible
    visible[OFFSET:OFFSET + SIZE, OFFSET:OFFSET + SIZE] = np.clip(
        np.round(black + mosaic * (white - black)), 0, 65535).astype(np.uint16)
    out = raw.postprocess(
        demosaic_algorithm=algorithm, output_color=rawpy.ColorSpace.raw, gamma=(1, 1), no_auto_bright=True,
        use_camera_wb=False, user_wb=[AS_SHOT[0], AS_SHOT[1], AS_SHOT[2], AS_SHOT[1]], output_bps=16,
        user_flip=0, highlight_mode=rawpy.HighlightMode.Clip,
    )
    return out[OFFSET:OFFSET + SIZE, OFFSET:OFFSET + SIZE].astype(np.float32) / 65535


def main():
    manifest = read_json(TESTSET / "manifest.json")
    for scene in manifest["scenes"]:
        truth = load_rgb(TESTSET / scene / "truth.f32", SIZE, SIZE)
        clean = np.fromfile(TESTSET / scene / "xtrans-clean.f32", "<f4").reshape(SIZE, SIZE)
        renders = OUT / "renders" / scene / "xtrans"
        for name, algorithm in PASSES.items():
            # One gain per channel, from the noise-free mosaic, so every level is scaled alike.
            reference = demosaic(clean, algorithm)
            inner = (slice(16, -16), slice(16, -16))
            gains = np.array([np.sum(truth[inner][..., c] * reference[inner][..., c])
                              / np.sum(reference[inner][..., c] ** 2) for c in range(3)], np.float32)
            save_f32(renders / f"clean-{name}.f32", reference * gains)
            for level in manifest["levels"]:
                noisy = np.fromfile(TESTSET / scene / f"xtrans-{level}.f32", "<f4").reshape(SIZE, SIZE)
                save_f32(renders / level / f"{name}.f32", demosaic(noisy, algorithm) * gains)
        print(scene, flush=True)


if __name__ == "__main__":
    main()
