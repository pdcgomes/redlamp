#!/usr/bin/env python3
"""Colour uniformity (TON-29, TON-30): Capture One's Skin Tone uniformity, prototyped in OKLCh.

Per pixel, as Capture One describes its Uniformity sliders and as Lightroom's Point Color Variance
appears to work: colours inside a range around a reference colour move towards it, separately in
hue, chroma and lightness, by the range's weight. Spatial: the same pull, low-passed under the mask,
so regions larger than the blur even out and finer colour detail stays.

The reference stands in for a click on even skin: the median of the face's skin-coloured pixels.
Scores are over the face's skin (inside the person mask, range weight above 0.5), in OKLCh: the
spread of hue from the reference and of chroma, lightness above 12 px (shading and blotches) and
below 2 px (texture), and the a and b channels below 2 px (colour detail).

    research/prototypes/masking/.venv/bin/python research/prototypes/colour/uniformity.py

Portrait: build/edge-cases/DSC02005.jpg with DSC02005-people.png (from `redlamp mask --kind people`),
the masking edge-case set; neither is committed. Figures go to build/proto-out/uniformity/.
"""

import pathlib

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORK = ROOT / "build/edge-cases"
OUT = ROOT / "build/proto-out/uniformity"
NAME = "DSC02005"
FACE = (440, 700, 1080, 1520)  # x0, y0, x1, y1 at 1366 × 2048: the face, scored and shown
CHEEK = (720, 900, 1060, 1360)  # the nose and cheek, shown at full size

# OKLab (B. Ottosson, "A perceptual color space for image processing", 2020), from linear sRGB.
M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])


def to_oklab(srgb):
    linear = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    return np.cbrt(linear @ M1.T) @ M2.T


def from_oklab(lab):
    linear = np.clip(((lab @ np.linalg.inv(M2).T) ** 3) @ np.linalg.inv(M1).T, 0, 1)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def wrap(degrees):
    return (degrees + 180) % 360 - 180


class Photo:
    def __init__(self, image, person):
        self.lab = to_oklab(image)
        self.person = person
        L, a, b = self.lab[..., 0], self.lab[..., 1], self.lab[..., 2]
        self.C = np.hypot(a, b)
        self.h = np.degrees(np.arctan2(b, a)) % 360
        x0, y0, x1, y1 = FACE
        self.face = np.zeros_like(L, bool)
        self.face[y0:y1, x0:x1] = True
        skin = self.face & (person > 0.5) & (self.C > 0.04) & (L > 0.3) & (L < 0.85) & (self.h > 30) & (self.h < 90)
        self.ref_L, self.ref_C = np.median(L[skin]), np.median(self.C[skin])
        radians = np.radians(self.h[skin])
        self.ref_h = np.degrees(np.arctan2(np.median(np.sin(radians)), np.median(np.cos(radians)))) % 360
        # The range, its falloff standing for Smoothness: hue fully within 20 degrees, none past 45;
        # no near-neutrals (grey hair), no deep shadows or speculars.
        self.dh = wrap(self.h - self.ref_h)
        self.weight = ((1 - smoothstep(20, 45, np.abs(self.dh)))
                       * smoothstep(0.02, 0.05, self.C) * (1 - smoothstep(0.22, 0.30, self.C))
                       * smoothstep(0.12, 0.22, L) * (1 - smoothstep(0.90, 0.97, L)))

    def uniform(self, hue=0.0, chroma=0.0, lightness=0.0, masked=True, spatial=0.0):
        """Pulled towards the reference by each amount (0 to 1). With `spatial` (a Gaussian sigma in
        pixels) the pull is low-passed under the mask."""
        L, a, b = self.lab[..., 0], self.lab[..., 1], self.lab[..., 2]
        mask = self.person if masked else np.ones_like(L)
        w = self.weight * mask
        new_h = np.radians(self.h - hue * w * self.dh)
        new_C = self.C * np.exp(chroma * w * np.log(self.ref_C / np.maximum(self.C, 1e-4)))
        new_L = L + lightness * w * (self.ref_L - L)
        delta = np.stack([new_L - L, new_C * np.cos(new_h) - a, new_C * np.sin(new_h) - b], -1)
        if spatial:
            total = np.maximum(ndimage.gaussian_filter(mask, spatial), 1e-6)
            delta = np.stack([ndimage.gaussian_filter(delta[..., i] * mask, spatial) / total for i in range(3)], -1)
            delta *= (mask > 0)[..., None]
        return self.lab + delta

    def scores(self, lab):
        region = self.face & (self.person > 0.5) & (self.weight > 0.5)
        L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
        hue = wrap(np.degrees(np.arctan2(b, a)) - self.ref_h)
        detail = np.hypot(a - ndimage.gaussian_filter(a, 2), b - ndimage.gaussian_filter(b, 2))
        return {
            "hue spread (deg)": np.std(hue[region]),
            "chroma spread": np.std(np.hypot(a, b)[region]),
            "lightness above 12 px": np.std(ndimage.gaussian_filter(L, 12)[region]),
            "lightness below 2 px": np.std((L - ndimage.gaussian_filter(L, 2))[region]),
            "colour detail below 2 px": np.sqrt(np.mean(detail[region] ** 2)),
        }


def rgb(lab):
    return (from_oklab(lab) * 255 + 0.5).astype(np.uint8)


def sheet(photo, variants, crop, path, deviation=False):
    """The crop of each variant, labelled; with `deviation`, each one's hue away from the reference
    under it (blue towards red and magenta, orange towards yellow, full at 12 degrees)."""
    x0, y0, x1, y1 = crop
    width, height, label = x1 - x0, y1 - y0, 24
    rows = 2 if deviation else 1
    out = Image.new("RGB", (len(variants) * (width + 8) - 8, rows * (height + label)), (24, 24, 24))
    draw = ImageDraw.Draw(out)
    for index, (name, lab) in enumerate(variants):
        left = index * (width + 8)
        out.paste(Image.fromarray(rgb(lab)[y0:y1, x0:x1]), (left, label))
        draw.text((left + 6, 6), name, fill=(235, 235, 235))
        if deviation:
            away = np.clip(wrap(np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) - photo.ref_h) / 12, -1, 1)[y0:y1, x0:x1]
            selected = (photo.weight * photo.person)[y0:y1, x0:x1, None]
            colour = np.where(away[..., None] < 0, [40, 110, 255], [255, 150, 20]) * np.abs(away)[..., None]
            colour = colour + 235 * (1 - np.abs(away))[..., None]
            colour = colour * selected + 70 * (1 - selected)
            out.paste(Image.fromarray(colour.astype(np.uint8)), (left, 2 * label + height))
            draw.text((left + 6, label + height + 6), "hue away from the reference", fill=(235, 235, 235))
    out.save(path, quality=90)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    image = np.asarray(Image.open(WORK / f"{NAME}.jpg").convert("RGB"), np.float64) / 255
    height, width, _ = image.shape
    person = Image.open(WORK / f"{NAME}-people.png").convert("L").resize((width, height), Image.BILINEAR)
    photo = Photo(image, np.asarray(person, np.float64) / 255)
    print(f"reference OKLCh: L {photo.ref_L:.3f}, C {photo.ref_C:.3f}, h {photo.ref_h:.1f}")

    variants = [
        ("Before", photo.lab),
        ("Per pixel: Hue 60, Saturation 40", photo.uniform(0.6, 0.4)),
        ("Per pixel: Hue 60, Saturation 40, Lightness 50", photo.uniform(0.6, 0.4, 0.5)),
        ("Spatial: Hue 80, Saturation 60", photo.uniform(0.8, 0.6, spatial=6)),
    ]
    before = photo.scores(photo.lab)
    print(f"{'':50}" + "".join(f"{key:>27}" for key in before))
    for name, lab in variants:
        scores = photo.scores(lab)
        print(f"{name:50}" + "".join(f"{value:14.4f} ({value / before[key]:6.1%})" for key, value in scores.items()))

    sheet(photo, variants, FACE, OUT / "face.jpg")
    sheet(photo, [variants[0], variants[1], variants[3], variants[2]], CHEEK, OUT / "cheek.jpg", deviation=True)
    # Visualize Range without a mask: everything the range selects, in red.
    selected = photo.weight[..., None] * 0.65
    overlay = image * (1 - selected) + np.array([1.0, 0.15, 0.1]) * selected
    Image.fromarray((overlay * 255 + 0.5).astype(np.uint8)).resize((width // 2, height // 2)).save(OUT / "range.jpg", quality=90)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
