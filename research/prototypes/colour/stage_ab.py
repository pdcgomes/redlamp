#!/usr/bin/env python3
"""Where the colour controls sit (TON-31): after the tone curve, as today, or before it.

Redlamp's colour block (Vibrance, Saturation, the Color Mixer and Color Grading; a mask's Hue and
Saturation are the same arithmetic scaled by its coverage) runs in OKLCh on the tone curve's
display-referred output (`rl_develop` in `Develop.metal`). This runs the block there ("after"), as
the kernel does, and on the scene light just before the tone curve ("before"), in forms that don't
depend on exposure:

- chroma scaled at constant OKLab lightness and hue, approaching the edge of positive Rec.2020
  instead of the output gamut (the tone curve and the final gamut map take it to the display);
- hue rotated by the same angle;
- the Color Mixer's Luminance and Color Grading's luminance as exposure, sized so that middle grey
  moves as far on screen as it does after the curve;
- Color Grading's offsets in proportion to lightness, so a tint is the same at every exposure.

Both orders take their weights (which band, how colourful, skin, shadows to highlights) from the
pixel's displayed colour before the edit, so only where each change is applied differs.

    build/research-venv/bin/python research/prototypes/colour/stage_ab.py --validate
    build/research-venv/bin/python research/prototypes/colour/stage_ab.py

`--validate` renders a 16-bit chart through the `redlamp` CLI with each edit and compares it with
the "after" path here. The study decodes CC0 raws from build/look-dev (`mise run lookdev`) with
LibRaw (rawpy) to linear Rec.2020, scaled so the default render's median brightness matches the
CLI's; the portraits in build/edge-cases are JPEGs and go through the tone curve's inverse, as
Redlamp opens a JPEG (they aren't committed, and stay out of the figures). A synthetic wedge takes
saturated colours from 4 stops under middle grey to 7 over it. Results go to
build/proto-out/stage-ab/.
"""

import argparse
import json
import pathlib
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[3]
LOOK_DEV = ROOT / "build/look-dev"
PORTRAITS = ROOT / "build/edge-cases"
OUT = ROOT / "build/proto-out/stage-ab"
CLI = ROOT / "build/DerivedData/Build/Products/Release/redlamp"
LONG_EDGE = 1200

PHOTOS = {
    "sky": ["Canon_EOS-R50.CR3", "Sony_ILCE-6700.ARW", "Panasonic_DC-TZ200D.RW2", "Fujifilm_X-S20.RAF",
            "Google_Pixel-6-Pro.dng", "Samsung_Galaxy-S21-Ultra.dng"],
    "lights": ["Canon_EOS-Kiss-F.CR2", "Sony_ILME-FX3.ARW", "Panasonic_DC-S5.RW2"],
    "saturated": ["Sigma_fp.DNG", "Pentax_KF.PEF", "Sony_ILCE-9M3.ARW"],
}
FACES = {"DSC01584": "DSC01584-people.png", "DSC02005": "DSC02005-people.png",
         "DSC02424": "DSC02424-people-1.png", "DSC03301": "DSC03301-subject.png"}

EDITS = {
    "Saturation +50": {"basic.saturation": 50},
    "Saturation -50": {"basic.saturation": -50},
    "Vibrance +50": {"basic.vibrance": 50},
    "Blue saturation +60": {"mixer.saturation.blue": 60},
    "Blue luminance -40": {"mixer.luminance.blue": -40},
    "Orange saturation +40": {"mixer.saturation.orange": 40},
    "Orange hue -30": {"mixer.hue.orange": -30},
    "Highlights warm": {"grading.highlights.hue": 45, "grading.highlights.saturation": 50},
    "Shadows teal": {"grading.shadows.hue": 200, "grading.shadows.saturation": 50},
}
HUE_KEEPING = ("Saturation +50", "Saturation -50", "Vibrance +50", "Blue saturation +60", "Orange saturation +40")

# MARK: - Colour, as Develop.metal has it

TO_LMS = np.array([[0.6167557872, 0.3601983994, 0.0230458134],
                   [0.2651330640, 0.6358393641, 0.0990275718],
                   [0.1001026342, 0.2039065194, 0.6959908464]])
LMS_TO_LAB = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                       [1.9779984951, -2.4285922050, 0.4505937099],
                       [0.0259040371, 0.7827717662, -0.8086757660]])
LAB_TO_LMS = np.array([[1.0, 0.3963377774, 0.2158037573],
                       [1.0, -0.1055613458, -0.0638541728],
                       [1.0, -0.0894841775, -1.2914855480]])
LMS_TO_REC2020 = np.array([[2.1399067357, -1.2463895088, 0.1064827730],
                           [-0.8847358625, 2.1632309821, -0.2784951194],
                           [-0.0485737580, -0.4545031429, 1.5030769009]])
REC2020_TO_SRGB = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]])
SRGB_TO_REC2020 = np.linalg.inv(REC2020_TO_SRGB)
XYZ_TO_REC2020 = np.array([[1.7166512, -0.3556708, -0.2533663],
                           [-0.6666844, 1.6164812, 0.0157685],
                           [0.0176399, -0.0427706, 0.9421031]])
BAND_HUES = np.array([25.0, 55.0, 100.0, 140.0, 195.0, 255.0, 300.0, 340.0])
BANDS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
SHOULDER_START, SHOULDER_Y, SHOULDER_EV, SHOULDER_POWER = 0.54358851, 0.8, 2.40548194, 3.25537943
FILMIC_AT_ONE = 0.80379747
MIDDLE_GREY = 0.18


def oklab(rgb):
    return np.cbrt(rgb @ TO_LMS.T) @ LMS_TO_LAB.T


def from_oklab(lab):
    return ((lab @ LAB_TO_LMS.T) ** 3) @ LMS_TO_REC2020.T


def srgb_encode(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * x ** (1 / 2.4) - 0.055)


def srgb_decode(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def keep_order(x, y, f):
    """Each channel's position between the smallest and largest kept, as the curve and its inverse do."""
    lo, hi = x.min(-1, keepdims=True), x.max(-1, keepdims=True)
    y_lo, y_hi = f(lo), f(hi)
    span = hi - lo
    kept = y_lo + (y_hi - y_lo) * (x - lo) / np.where(span < 1e-7, 1, span)
    return np.where(span < 1e-7, y, kept)


def curve_channel(x):
    x = np.maximum(x, 0)
    low = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14) / FILMIC_AT_ONE
    u = np.minimum(np.log2(np.maximum(x, 1e-12) / SHOULDER_START) / SHOULDER_EV, 1)
    high = 1 - (1 - SHOULDER_Y) * np.maximum(1 - u, 0) ** SHOULDER_POWER
    return np.where(x <= SHOULDER_START, low, high)


def tone_curve(x):
    return keep_order(x, curve_channel(x), curve_channel)


def inverse_channel(y):
    y = np.clip(y, 0, 1)
    t = y * FILMIC_AT_ONE
    a, b, c = 2.43 * t - 2.51, 0.59 * t - 0.03, 0.14 * t
    low = np.maximum((-b - np.sqrt(np.maximum(b * b - 4 * a * c, 0))) / (2 * a), 0)
    u = 1 - np.maximum((1 - y) / (1 - SHOULDER_Y), 0) ** (1 / SHOULDER_POWER)
    return np.where(y <= SHOULDER_Y, low, SHOULDER_START * np.exp2(u * SHOULDER_EV))


def inverse_curve(y):
    return keep_order(y, inverse_channel(y), inverse_channel)


class Developed(np.ndarray):
    """Gamut-mapped linear sRGB, remembering which pixels the final gamut map had to move."""

    def __new__(cls, mapped, moved):
        out = np.asarray(mapped).view(cls)
        out.moved = moved
        return out

    def __array_finalize__(self, obj):
        self.moved = getattr(obj, "moved", None)


def gamut_map(rec2020):
    """Into sRGB: clipped, then each channel's position between the smallest and largest restored."""
    rgb = rec2020 @ REC2020_TO_SRGB.T
    clipped = np.clip(rgb, 0, 1)
    lo, hi = rgb.min(-1, keepdims=True), rgb.max(-1, keepdims=True)
    c_lo, c_hi = clipped.min(-1, keepdims=True), clipped.max(-1, keepdims=True)
    span = hi - lo
    mapped = c_lo + (c_hi - c_lo) * (rgb - lo) / np.where(span < 1e-7, 1, span)
    mapped = np.where(span < 1e-7, clipped, mapped)
    return Developed(mapped, np.any((rgb < -1e-3) | (rgb > 1.001), -1))


def max_chroma(lightness, hue_radians, scene):
    """The most chroma a lightness and hue can have: inside the output gamut (after the curve), or
    with no Rec.2020 channel below 0 (scene light, which has no upper bound)."""
    direction = np.stack([np.cos(hue_radians), np.sin(hue_radians)], -1)
    inside = np.zeros_like(lightness)
    outside = np.maximum(0.6 * lightness, 0.5) if scene else np.full_like(lightness, 0.5)
    for _ in range(14 if scene else 10):
        c = 0.5 * (inside + outside)
        rgb = from_oklab(np.concatenate([lightness[..., None], c[..., None] * direction], -1))
        if not scene:
            rgb = rgb @ REC2020_TO_SRGB.T
            fits = np.all(rgb >= -1e-4, -1) & np.all(rgb <= 1.0001, -1)
        else:
            fits = np.all(rgb >= -1e-4, -1)
        inside = np.where(fits, c, inside)
        outside = np.where(fits, outside, c)
    return inside


def boost_chroma(chroma, target, lightness, hue_radians, scene):
    """Gamut-relative saturation (TON-07): a boost approaches the limit instead of passing it."""
    headroom = max_chroma(lightness, hue_radians, scene) - chroma
    boosted = chroma + headroom * (1 - np.exp(-np.maximum(target - chroma, 0) / np.maximum(headroom, 1e-5)))
    boosted = np.where(headroom <= 1e-5, chroma, boosted)
    return np.where(target <= chroma, target, boosted)


def hue_distance(a, b):
    d = np.mod(np.abs(a - b), 360)
    return np.where(d > 180, 360 - d, d)


def hue_bump(hue, centre, width):
    d = hue_distance(hue, centre) / width
    return np.where(d >= 1, 0, 0.5 + 0.5 * np.cos(np.minimum(d, 1) * np.pi))


def band_values(hue, values):
    """The Color Mixer's partition of unity between the two nearest band centres."""
    out = np.zeros_like(hue)
    for i in range(8):
        j = (i + 1) % 8
        start, end = BAND_HUES[i], BAND_HUES[j] + (360 if j == 0 else 0)
        h = np.where(hue < start, hue + 360, hue)
        inside = (h >= start) & (h < end)
        t = smoothstep(0, 1, (h - start) / (end - start))
        out = np.where(inside, values[i] + (values[j] - values[i]) * t, out)
    return out


def wheel_direction(degrees):
    """OKLab.direction(forWheelHue:): the (a, b) direction of a fully saturated sRGB hue."""
    h = (degrees % 360) / 60
    x = 1 - abs(h % 2 - 1)
    rgb = [(1, x, 0), (x, 1, 0), (0, 1, x), (0, x, 1), (x, 0, 1), (1, 0, x)][int(h) % 6]
    lab = oklab(srgb_decode(np.array(rgb, float)) @ SRGB_TO_REC2020.T)
    return lab[1:] / np.hypot(lab[1], lab[2])


# MARK: - The colour block


class Edit:
    def __init__(self, values):
        get = lambda key: values.get(key, 0.0) / 100
        self.vibrance = get("basic.vibrance")
        self.saturation = 1 + get("basic.saturation")
        self.hue = np.array([get(f"mixer.hue.{band}") for band in BANDS])
        self.band_saturation = np.array([get(f"mixer.saturation.{band}") for band in BANDS])
        self.band_luminance = np.array([get(f"mixer.luminance.{band}") for band in BANDS])
        self.mixer = any(np.any(v != 0) for v in (self.hue, self.band_saturation, self.band_luminance))
        self.grades = {}
        for name, strength in (("shadows", 0.1), ("midtones", 0.08), ("highlights", 0.08), ("global", 0.06)):
            direction = wheel_direction(values.get(f"grading.{name}.hue", 0.0))
            offset = direction * get(f"grading.{name}.saturation") * strength
            self.grades[name] = np.array([offset[0], offset[1], get(f"grading.{name}.luminance") * 0.12])
        self.grading = any(np.any(g != 0) for g in self.grades.values())
        self.blending = values.get("grading.blending", 50) / 100
        self.balance = get("grading.balance")


def changes(display_lab, edit):
    """What the edit does to each pixel, from its displayed colour: a chroma factor, a hue rotation
    (degrees), a lightness change and Color Grading's (a, b, L) offset, all in display units."""
    L = display_lab[..., 0]
    chroma = np.hypot(display_lab[..., 1], display_lab[..., 2])
    hue = np.where(chroma > 0, np.degrees(np.arctan2(display_lab[..., 2], display_lab[..., 1])), 0) % 360
    skin = hue_bump(hue, 55, 30)
    low_chroma = 1 - smoothstep(0, 0.18, chroma)
    factor = edit.saturation * (1 + edit.vibrance * low_chroma * ((1 - 0.6 * skin) if edit.vibrance > 0 else 1))
    rotation = np.zeros_like(L)
    lightness = np.zeros_like(L)
    if edit.mixer:
        colourfulness = smoothstep(0, 0.04, chroma)
        rotation = band_values(hue, edit.hue) * 30 * colourfulness
        factor = factor * (1 + band_values(hue, edit.band_saturation))
        lightness = band_values(hue, edit.band_luminance) * 0.15 * colourfulness * smoothstep(0, 0.1, chroma)
    offset = np.zeros(L.shape + (3,))
    if edit.grading:
        pivot = 0.5 - edit.balance * 0.2
        width = 0.08 + 0.3 * edit.blending
        Lc = np.clip(L + lightness, 0, 1)
        shadows = 1 - smoothstep(pivot - 0.2 - width, pivot - 0.2 + width, Lc)
        highlights = smoothstep(pivot + 0.2 - width, pivot + 0.2 + width, Lc)
        midtones = np.maximum(0, 1 - shadows - highlights)
        offset = (shadows[..., None] * edit.grades["shadows"] + midtones[..., None] * edit.grades["midtones"]
                  + highlights[..., None] * edit.grades["highlights"] + edit.grades["global"])
    return factor, rotation, lightness, offset


def lightness_to_exposure():
    """Stops that move middle grey by one unit of displayed OKLab lightness (the slope at grey)."""
    grey = lambda ev: oklab(tone_curve(np.full(3, MIDDLE_GREY * 2 ** ev)))[0]
    return 0.02 / (grey(0.01) - grey(-0.01))


STOPS_PER_LIGHTNESS = lightness_to_exposure()


def apply_lch(lab, factor, rotation, scene):
    L = lab[..., 0]
    chroma = np.hypot(lab[..., 1], lab[..., 2])
    hue = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) + rotation
    radians = np.radians(hue)
    chroma = boost_chroma(chroma, chroma * np.maximum(factor, 0), L, radians, scene)
    return np.stack([L, chroma * np.cos(radians), chroma * np.sin(radians)], -1)


def develop(scene, edit, order):
    """Display-referred linear Rec.2020, gamut-mapped to sRGB, for scene light (white point 1)."""
    display = tone_curve(scene)
    display_lab = oklab(display)
    factor, rotation, lightness, offset = changes(display_lab, edit)
    if order == "after":
        lab = display_lab.copy()
        lab[..., 0] += lightness
        lab = apply_lch(lab, factor, rotation, scene=False)
        lab = lab + offset[..., [2, 0, 1]]
        out = np.maximum(from_oklab(lab), 0)
    else:
        stops = (lightness + offset[..., 2]) * STOPS_PER_LIGHTNESS
        lit = scene * np.exp2(stops)[..., None]
        lab = oklab(lit)
        lab = apply_lch(lab, factor, rotation, scene=True)
        ratio = lab[..., 0] / np.maximum(display_lab[..., 0], 1e-4)
        lab[..., 1:] += offset[..., :2] * ratio[..., None]
        out = tone_curve(np.maximum(from_oklab(lab), 0))
    return gamut_map(out)


def shown_lab(srgb_linear):
    return oklab(np.clip(srgb_linear, 0, 1) @ SRGB_TO_REC2020.T)


# MARK: - Inputs


def downscale(image, long_edge=LONG_EDGE):
    factor = max(1, int(np.ceil(max(image.shape[:2]) / long_edge)))
    h, w = (image.shape[0] // factor) * factor, (image.shape[1] // factor) * factor
    return image[:h, :w].reshape(h // factor, factor, w // factor, factor, -1).mean((1, 3)).squeeze()


def cli_render(path, out, values=None, size=LONG_EDGE):
    args = [str(CLI), "render", str(path), "-o", str(out), "--size", str(size), "--16bit"]
    for key, value in (values or {}).items():
        args += ["--set", f"{key}={value}"]
    subprocess.run(args, check=True, capture_output=True)
    import tifffile

    image = tifffile.imread(out)
    return image.astype(np.float64)[..., :3] / (65535 if image.dtype == np.uint16 else 255)


def raw_scene(path, work):
    """Linear Rec.2020 from LibRaw, scaled so the default render's median brightness is the CLI's."""
    import rawpy

    cache = OUT / "cache" / f"{path.name}.npz"
    if cache.exists():
        stored = np.load(cache)
        return stored["scene"], float(stored["ev"])
    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, gamma=(1, 1), output_bps=16,
                              output_color=rawpy.ColorSpace.XYZ, exp_shift=0.25, half_size=True)
    scene = downscale(rgb.astype(np.float64) / 65535 * 4) @ XYZ_TO_REC2020.T
    reference = cli_render(path, work / f"{path.stem}-default.tif")
    target = np.median(shown_lab(srgb_decode(reference))[..., 0])
    lo, hi = -6.0, 6.0
    for _ in range(30):
        ev = 0.5 * (lo + hi)
        shown = np.median(oklab(gamut_map(tone_curve(np.maximum(scene, 0) * 2 ** ev)) @ SRGB_TO_REC2020.T)[..., 0])
        lo, hi = (ev, hi) if shown < target else (lo, ev)
    ev = 0.5 * (lo + hi)
    scene = np.maximum(scene, 0) * 2 ** ev
    cache.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(cache, scene=scene.astype(np.float32), ev=ev)
    return scene, ev


def bitmap_scene(srgb):
    """How Redlamp opens a bitmap: linear, into Rec.2020, clamped, then the curve's inverse."""
    return inverse_curve(np.clip(srgb_decode(srgb) @ SRGB_TO_REC2020.T, 0, 1))


def wedge(beyond_srgb, hues=tuple(range(0, 360, 30)) + (55,), stops=np.arange(-4, 7.01, 0.05)):
    """Saturated colours from 4 stops under middle grey to 7 over, each row one hue, each column one
    exposure: at middle grey's lightness, 80% of the chroma sRGB holds there, or (`beyond_srgb`, as
    LEDs and lasers are) 80% of what positive Rec.2020 holds."""
    grey_l = oklab(np.full(3, MIDDLE_GREY))[0]
    rows = []
    for hue in hues:
        radians = np.radians(np.array([hue], float))
        c = 0.8 * max_chroma(np.array([grey_l]), radians, scene=beyond_srgb)[0]
        base = np.maximum(from_oklab(np.array([grey_l, c * np.cos(radians[0]), c * np.sin(radians[0])])), 0)
        base *= MIDDLE_GREY / (base @ np.array([0.2627, 0.6780, 0.0593]))
        rows.append(base[None, :] * (2 ** stops)[:, None])
    return np.stack(rows), list(hues), stops


# MARK: - Measures


def lch(lab):
    chroma = np.hypot(lab[..., 1], lab[..., 2])
    return lab[..., 0], chroma, np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


def photo_measures(base, edited):
    """Over the photo: hue moved where colour was (chroma-weighted mean and 95th percentile); the
    share of pixels newly clipped by the final gamut map (their gradation lost); the change in
    midtone chroma, and in bright pixels' chroma."""
    lb, cb, hb = lch(shown_lab(base))
    le, ce, he = lch(shown_lab(edited))
    coloured = (cb > 0.03) & (ce > 0.03)
    dh = hue_distance(he, hb)[coloured]
    weights = cb[coloured]
    mid = (lb > 0.3) & (lb < 0.7) & (cb > 0.03)
    bright = lb > 0.85
    return {
        "hue_mean": float(np.sum(dh * weights) / max(np.sum(weights), 1e-9)) if dh.size else 0.0,
        "hue_p95": float(np.percentile(dh, 95)) if dh.size else 0.0,
        "new_clipping": float(np.mean(edited.moved & ~base.moved)),
        "mid_chroma": float(np.mean(ce[mid] - cb[mid])) if mid.any() else 0.0,
        "bright_chroma": float(np.mean(ce[bright] - cb[bright])) if bright.any() else 0.0,
        "bright_share": float(np.mean(bright)),
    }


def wedge_measures(base, edited, stops):
    """Per hue along the wedge: the exposure where it reaches white (chroma under 0.02 after its
    peak); how far its hue strays from the unedited one at the same exposure; chroma rising again
    after its peak; the stops clipped by the final gamut map that weren't unedited; and the largest
    step between neighbouring exposures (OKLab distance; 0.05 stops apart), where an abrupt change
    shows."""
    out = []
    step = stops[1] - stops[0]
    for row in range(edited.shape[0]):
        lab = shown_lab(edited[row])
        L, C, H = lch(lab)
        _, Cb, Hb = lch(shown_lab(base[row]))
        coloured = (C > 0.03) & (Cb > 0.03)
        peak = int(np.argmax(C))
        faded = C[peak:] < 0.02
        white = stops[peak + int(np.argmax(faded))] if faded.any() else float("nan")
        rise = float(np.max(np.maximum.accumulate(-C[peak:]) + C[peak:])) if peak < len(C) - 1 else 0.0
        clipped = float(np.sum(edited.moved[row] & ~base.moved[row]) * step)
        jump = float(np.max(np.linalg.norm(np.diff(lab, axis=0), axis=-1)))
        out.append({"white_ev": float(white),
                    "hue_drift": float(np.max(hue_distance(H[coloured], Hb[coloured]))) if coloured.any() else 0.0,
                    "chroma_rise": rise, "clipped_stops": clipped, "largest_step": jump})
    return out


# MARK: - Figures


def to_image(srgb_linear):
    return Image.fromarray((srgb_encode(srgb_linear) * 255 + 0.5).astype(np.uint8))


def wedge_figure(panels, hues, stops, path):
    cell_w, cell_h, label = 3, 18, 18
    width = len(stops) * cell_w
    sheet = Image.new("RGB", (width, len(panels) * (len(hues) * cell_h + label)), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    for index, (name, image) in enumerate(panels):
        top = index * (len(hues) * cell_h + label)
        draw.text((4, top + 3), name, fill=(235, 235, 235))
        strip = to_image(np.repeat(np.repeat(image, cell_h, 0), cell_w, 1))
        sheet.paste(strip, (0, top + label))
    sheet.save(path)


def photo_figure(rows, path, width=520):
    images = [[to_image(image) for image in row[1]] for row in rows]
    scale = width / images[0][0].width
    height = int(images[0][0].height * scale)
    label = 18
    sheet = Image.new("RGB", (len(images[0]) * (width + 6) - 6, len(rows) * (height + label)), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    for r, (titles, _) in enumerate(rows):
        for c, image in enumerate(images[r]):
            left, top = c * (width + 6), r * (height + label)
            sheet.paste(image.resize((width, height), Image.LANCZOS), (left, top + label))
            draw.text((left + 4, top + 3), titles[c], fill=(235, 235, 235))
    sheet.save(path, quality=90)


# MARK: - Runs


def validate(work):
    """The "after" path against the CLI on a chart of patches (display-referred sRGB, 16-bit)."""
    hues = np.arange(0, 360, 20)
    patches = []
    for lightness in (0.35, 0.5, 0.65, 0.8, 0.92):
        for chroma in (0.03, 0.08, 0.14):
            for hue in hues:
                lab = np.array([lightness, chroma * np.cos(np.radians(hue)), chroma * np.sin(np.radians(hue))])
                patches.append(np.clip(from_oklab(lab) @ REC2020_TO_SRGB.T, 0, 1))
    columns = len(hues)
    grid = np.array(patches).reshape(-1, columns, 3)
    size = 24
    chart = srgb_encode(np.repeat(np.repeat(grid, size, 0), size, 1))
    chart_path = work / "chart.tif"
    _save_tiff16(chart, chart_path)
    centres = (np.arange(grid.shape[0]) * size + size // 2, np.arange(columns) * size + size // 2)
    pick = lambda image: image[np.ix_(centres[0], centres[1])]
    scene = bitmap_scene(pick(chart))
    report = {}
    for name, values in {"Default": {}, **EDITS}.items():
        rendered = pick(cli_render(chart_path, work / f"chart-{len(report)}.tif", values, size=chart.shape[1]))
        ours = srgb_encode(develop(scene, Edit(values), "after"))
        levels = np.abs(rendered - ours) * 255
        report[name] = {"mean_levels": float(levels.mean()), "max_levels": float(levels.max())}
        print(f"{name:24} mean {levels.mean():5.2f} levels, max {levels.max():5.2f}")
    return report


def _save_tiff16(srgb, path):
    """A 16-bit RGB TIFF (Pillow can't write 16-bit RGB)."""
    import tifffile

    tifffile.imwrite(path, (np.clip(srgb, 0, 1) * 65535 + 0.5).astype(np.uint16), photometric="rgb")


def study(work):
    results = {"photos": {}, "faces": {}, "wedge": {}}
    figures = {}
    for group, files in PHOTOS.items():
        for name in files:
            scene, ev = raw_scene(LOOK_DEV / name, work)
            base = develop(scene, Edit({}), "after")
            entry = {"group": group, "calibration_ev": ev, "edits": {}}
            for edit_name, values in EDITS.items():
                edit = Edit(values)
                entry["edits"][edit_name] = {}
                for order in ("after", "before"):
                    out = develop(scene, edit, order)
                    entry["edits"][edit_name][order] = photo_measures(base, out)
                    if edit_name in ("Saturation +50", "Blue saturation +60", "Highlights warm"):
                        figures.setdefault((group, name), {"base": base})[(edit_name, order)] = out
            results["photos"][name] = entry
            print(name, f"calibrated {ev:+.2f} EV")
    for name, mask_file in FACES.items():
        srgb = downscale(np.asarray(Image.open(PORTRAITS / f"{name}.jpg").convert("RGB"), np.float64) / 255, 1024)
        mask = np.asarray(Image.open(PORTRAITS / mask_file).convert("L").resize(srgb.shape[1::-1], Image.BILINEAR)) / 255
        scene = bitmap_scene(srgb)
        base = develop(scene, Edit({}), "after")
        lb, cb, hb = lch(shown_lab(base))
        skin = (mask > 0.5) & (hb > 30) & (hb < 90) & (cb > 0.03) & (cb < 0.25) & (lb > 0.3) & (lb < 0.85)
        entry = {}
        for edit_name in ("Saturation +50", "Vibrance +50", "Orange saturation +40", "Orange hue -30", "Highlights warm"):
            entry[edit_name] = {}
            for order in ("after", "before"):
                le, ce, he = lch(shown_lab(develop(scene, Edit(EDITS[edit_name]), order)))
                entry[edit_name][order] = {"chroma": float(np.mean(ce[skin] - cb[skin])),
                                           "hue": float(np.mean(((he - hb + 180) % 360 - 180)[skin])),
                                           "lightness": float(np.mean(le[skin] - lb[skin]))}
        results["faces"][name] = entry
        print(name, "skin pixels", int(skin.sum()))
    for kind, beyond in (("in sRGB", False), ("beyond sRGB", True)):
        colours, hues, stops = wedge(beyond)
        base = develop(colours, Edit({}), "after")
        panels = [("Unedited", base)]
        measured = {"Unedited": wedge_measures(base, base, stops)}
        for edit_name in ("Saturation +50", "Vibrance +50", "Highlights warm", "Saturation -50"):
            for order in ("after", "before"):
                out = develop(colours, Edit(EDITS[edit_name]), order)
                measured[f"{edit_name}, {order}"] = wedge_measures(base, out, stops)
                if edit_name in ("Saturation +50", "Highlights warm"):
                    panels.append((f"{edit_name}, {order} the tone curve", out))
        results["wedge"][kind] = measured
        wedge_figure(panels, hues, stops, OUT / f"wedge-{kind.replace(' ', '-').lower()}.png")
    results["wedge_hues"] = hues
    for (group, name), images in figures.items():
        if group == "saturated":
            continue
        rows = []
        for edit_name in ("Saturation +50", "Blue saturation +60" if group == "sky" else "Highlights warm"):
            rows.append(([f"{name}: unedited", f"{edit_name}, after", f"{edit_name}, before"],
                         [images["base"], images[(edit_name, "after")], images[(edit_name, "before")]]))
        photo_figure(rows, OUT / f"{pathlib.Path(name).stem}.jpg")
    return results


def summary(results):
    """Each edit's measures averaged over the photos of each group, after and before."""
    keys = ("hue_mean", "hue_p95", "new_clipping", "mid_chroma", "bright_chroma")
    for group in PHOTOS:
        print(f"\n{group}: " + ", ".join(keys))
        entries = [e for e in results["photos"].values() if e["group"] == group]
        for edit_name in EDITS:
            cells = []
            for order in ("after", "before"):
                values = [np.mean([e["edits"][edit_name][order][k] for e in entries]) for k in keys]
                cells.append(" ".join(f"{v:8.4f}" for v in values))
            print(f"  {edit_name:22} after {cells[0]} | before {cells[1]}")
    print("\nskin (mean over faces): chroma, hue, lightness")
    for edit_name in next(iter(results["faces"].values())):
        cells = []
        for order in ("after", "before"):
            values = [np.mean([f[edit_name][order][k] for f in results["faces"].values()])
                      for k in ("chroma", "hue", "lightness")]
            cells.append(" ".join(f"{v:8.4f}" for v in values))
        print(f"  {edit_name:22} after {cells[0]} | before {cells[1]}")
    keys = ("white_ev", "hue_drift", "chroma_rise", "clipped_stops", "largest_step")
    for kind, measured in results["wedge"].items():
        print(f"\nwedge {kind} (mean over hues, worst hue for the step): " + ", ".join(keys) + ", worst step")
        for name, rows in measured.items():
            values = [np.nanmean([r[k] for r in rows]) for k in keys] + [max(r["largest_step"] for r in rows)]
            print(f"  {name:32} " + " ".join(f"{v:8.3f}" for v in values))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--validate", action="store_true", help="compare the after path with the CLI")
    options = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as directory:
        work = pathlib.Path(directory)
        if options.validate:
            (OUT / "validation.json").write_text(json.dumps(validate(work), indent=1))
            return
        results = study(work)
    (OUT / "results.json").write_text(json.dumps(results, indent=1))
    summary(results)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
