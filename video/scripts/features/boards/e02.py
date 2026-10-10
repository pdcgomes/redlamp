"""
E02, Sky mask: the sky selected in one click by an AI mask that runs on the Mac, then darkened without
changing the trees. The editor opens a landscape with bare trees against the sky; the pointer clicks
SKY in the Masks panel, the red overlay fills the sky, the mask's Exposure goes to -0.80 and the sky
darkens; side by side and closer, the branches are as they were; then the real photo and the end card.

The photo stands in until the owner's arrives: the Panasonic FZ28 render in MSK-17's sky bake-off
(docs/images/masking-sky-edges.jpg, third row), with the Sky mask Redlamp made for it beside it (third
column). The after applies the mask's Exposure -0.80 to the render through that mask, as a Sky mask's
edit reaches only the sky's share of each pixel, standing in for Redlamp's own render of the edit.
"""

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e02")
FEATURE = "SKY MASK"
SOURCE = "docs/images/masking-sky-edges.jpg"
PHOTO = ("THE PANASONIC FZ28 RENDER AND REDLAMP'S SKY MASK FOR IT, DOCS/IMAGES/MASKING-SKY-EDGES.JPG (MSK-17). "
         "THE AFTER APPLIES THE MASK'S EXPOSURE -0.80 THROUGH THAT MASK, STANDING IN FOR REDLAMP'S RENDER")
BEFORE = w.crop(SOURCE, (2, 697, 510, 1036))
MASK = w.crop(SOURCE, (1039, 697, 1547, 1036)).convert("L")
ASPECT = BEFORE.width / BEFORE.height
PANEL = 58

AI_MASKS = ["SUBJECT", "SKY", "BACKGROUND", "PEOPLE"]
# The mask's Exposure, and the slider's reach either side of zero (ParameterSpec's localExposure).
EXPOSURE, REACH = -0.80, 4
# The branches seen closer in bar 5, in the photo's own pixels: one pane of the side-by-side view.
CLOSER = (160, 30, 260, 165)


def darken(img, mask, ev):
    """`img` with `ev` stops of exposure applied through `mask`, in linear light."""
    a = np.asarray(img, dtype=np.float64) / 255
    m = np.asarray(mask.resize(img.size, Image.BILINEAR), dtype=np.float64)[..., None] / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4) * 2 ** (ev * m)
    v = np.clip(lin, 0, 1)
    v = np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)
    return Image.fromarray(np.rint(v * 255).astype(np.uint8))


AFTER = darken(BEFORE, MASK, EXPOSURE)

# A ramp of daylight sky blues beside the shared palette, so the sky keeps its own blue before and after
# the edit instead of turning to the kit's saturated blues, then its lavender greys once darkened.
SKY = ["#22324a", "#3a5677", "#55779f", "#7193bf", "#8db0db", "#a9c9ef", "#c9def5"]
PALETTE = list(dict.fromkeys(w.PHOTO_PALETTE + [w.THEME.rgb(s) for s in SKY]))

_cache = {}


def pixel(img, size, box=None):
    """`img` (or its `box`) as a pixel photo at `size`, as world.pixel_photo makes one, on PALETTE."""
    key = (id(img), size, box)
    if key not in _cache:
        src = w.fit(img.crop(box) if box else img, *size, Image.BOX)
        _cache[key] = w.lock(src, PALETTE, dither=0.45).convert("RGB")
    return _cache[key]


def sky(size):
    """The mask at the photo's size, as the overlay shows it: set where the pixel is mostly sky."""
    return np.asarray(w.fit(MASK, *size, Image.BOX)) >= 128


def edit(c, photo, *, pressed=False, chosen=False, exposure=None, active=False, press=None):
    """The editor with `photo` (BEFORE or AFTER) and the Masks panel: the AI masks, SKY pressed or
    chosen, and the mask's Exposure once the mask exists. Returns the editor."""
    w.header(c, FEATURE)
    size = w.layout(aspect=ASPECT, panel=PANEL).photo[2:]
    ed = w.editor(c, pixel(photo, size), file="PANASONIC_DMC-FZ28.RW2", aspect=ASPECT, panel=PANEL)
    p = ed.panel
    y = w.panel_title(c, p.x, p.y, p.w, "MASKS", right="AI MASKS")
    x, at = p.x, {}
    for label in AI_MASKS:
        r = w.button(c, x, y, label, pressed=pressed and label == "SKY", selected=chosen and label == "SKY")
        at[label] = r
        x = r.x2 + 3
    if exposure is not None:
        value = "0.00" if exposure == 0 else f"{exposure:+.2f}"
        at["EXPOSURE"] = w.slider(c, p.x, y + 18, p.w, "EXPOSURE", value, 0.5 + exposure / (2 * REACH),
                                  active=active)
    if press == "SKY":
        r = at["SKY"]
        w.pointer(c, r.x2 - 1, r.y2 - 1, pressed=True)
    elif press:
        w.pointer(c, *at[press], pressed=True)
    return ed


def hook(c):
    edit(c, BEFORE)
    w.caption(c, EPISODE["hooks"]["a"])


def click(c):
    edit(c, BEFORE, pressed=True, press="SKY")
    w.caption(c, "CLICK SKY")


def selected(c):
    ed = edit(c, BEFORE, chosen=True, exposure=0)
    w.mask_overlay(c, ed.photo, sky(ed.photo[2:]))
    w.caption(c, ["THE SKY IS", "SELECTED"])


def darker(c):
    edit(c, AFTER, chosen=True, exposure=EXPOSURE, active=True, press="EXPOSURE")
    w.caption(c, "DARKEN IT")


def closer(c):
    """Redlamp's side-by-side view, closer on the branches: before at the left, after at the right."""
    ed = edit(c, BEFORE, chosen=True, exposure=EXPOSURE)
    ph = ed.photo
    pane = w.Rect(ph.x, ph.y, (ph.w - 1) // 2, ph.h)
    c.rect(*ph, w.GREY["canvas"])
    for i, (img, mark) in enumerate(((BEFORE, "BEFORE"), (AFTER, "AFTER"))):
        r = w.Rect(pane.x + i * (pane.w + 1), pane.y, pane.w, pane.h)
        c.img.paste(pixel(img, (r.w, r.h), CLOSER), (r.x, r.y))
        w.tag(c, r, mark)
    w.caption(c, ["THE TREES STAY", "AS THEY WERE"])


def result(c, progress=1.0):
    ed = edit(c, AFTER, chosen=True, exposure=EXPOSURE)
    return w.result_frame(c, ed, AFTER, mark="AFTER", progress=progress)


def end_line(c):
    w.cta_card(c, EPISODE["endLine"])


def held(c):
    w.cta_card(c, EPISODE["endLine"])
    w.fade(c, 0.35)


PANELS = [
    w.Panel(1, 0.0, hook, " / ".join(EPISODE["hooks"]["a"]), "A soft chord and a gentle hit on frame 0."),
    w.Panel(2, 2.4, click, "CLICK SKY", "The motif starts; a click on the beat."),
    w.Panel(3, 4.8, selected, "THE SKY IS / SELECTED", "A soft rising blip as the overlay fills."),
    w.Panel(4, 7.2, darker, "DARKEN IT", "Slider ticks on the beats of the drag; the drums come in."),
    w.Panel(5, 9.6, closer, "THE TREES STAY / AS THEY WERE", "The motif's answer."),
    w.Panel(6, 12.0, result, " / ".join(w.REAL_PHOTO),
            "The develop sting: the motif's head over struck glass; a tick on the flip to after at 13.2 s."),
    w.Panel(7, 14.4, end_line, " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD) + " at 15.6 s",
            "The theme's last phrase."),
    w.Panel(8, 16.8, held, " / ".join(w.END_CARD), "The last chord dies away as the picture fades from 17.4 s."),
]
