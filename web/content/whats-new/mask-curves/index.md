---
version: 0.2.5-prealpha
date: 2026-10-06
symbol: point.topleft.down.to.point.bottomright.curvepath
title: Curves inside masks
summary: Shape the tones of only what a mask covers, in every channel or in red, green or blue.
image: curves.jpg
imageAlt: A sky mask's curve, darkening the sky over a brick house while the house stays as it was
---

Each mask now has a Curve, below its Color swatch: an RGB curve, and one each for red, green and blue. It works as the Tone Curve does, but only as far as the mask reaches, so a sky can be darkened without touching the house beneath it.
