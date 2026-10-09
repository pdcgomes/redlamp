---
title: Linear vs scene-referred
summary: Two words that often get used as if they meant the same thing, explained with figures you can try and Redlamp's own tone curve.
date: 2026-10-09
draft: true
---

Redlamp is a free, open-source raw photo editor for the Mac that works like Lightroom. Some feedback I got recently pointed out two things: Redlamp has no scene-referred mode, and in its exports, the L* of a grey scale's patches isn't linear against the chart's own values. Exports of metered shots of a target also came out slightly dark.

Answering that properly meant untangling two words that often get used as if they meant the same thing. They don't. *Linear* and *scene-referred* answer different questions about a pixel's numbers, so they aren't opposites: a pixel can be linear and scene-referred, either one, or neither.

This article works through both, with figures you can try. The curves in them are Redlamp's own, as its code has them on 9 October 2026.

<div data-figure="in-short"></div>

## Two questions, four combinations

Follow a grey card, at 0.18 in scene light, and a sunlit cloud, at 2.0, into each corner. The same two lights get different numbers in each.

<div data-figure="combinations"></div>

**Across a row**, the light stays the same and only its numbers change: re-encoding is arithmetic, exact in both directions. **Down a column**, the light itself changes: the tone curve decides how the scene's range fits between black and the screen's white, and whatever it presses into white can't be told apart afterwards. The cloud's 2.00 has nowhere to go on a screen but 0.999.

## Linear: how the numbers are written

Light adds up: two lamps give twice the light of one. Linear numbers keep that proportion, so the arithmetic of light works on them directly: a stop of Exposure is ×2, and a blur averages light. Eyes don't see light that way: the step from 1% to 2% of white looks about as big as the step from 50% to 100%. So files and screens write light with a curve that gives the darks more numbers. Converting between the two is a formula, exact both ways: it changes the numbers, not the picture.

<div data-figure="encoding"></div>

<div data-figure="levels-and-mixing"></div>

> **Linear is a property of the numbers, not of the light.** The same light can be written linearly, with the sRGB curve, with gamma 1.8 or on a log scale, and a colour-managed reader gets the same light back from each. So whether a file is linear says nothing about whose light it holds. That's the second question.

## Scene-referred: whose light the numbers describe

A scene-referred number describes the light that was in front of the camera, relative to the rest of the scene: if a grey card is 0.18, a sunlit cloud is about 2 and a street lamp about 20. There's no ceiling, because scenes have none. A display-referred number describes the light a screen should give off, and 1.0 is the screen's white.

Getting from one to the other means deciding how the scene's range fits between the screen's black and white. That decision is the tone curve: a choice, not arithmetic, and different curves make different pictures of the same scene.

<div data-figure="exposure-playground"></div>

## Where Redlamp does each

One render passes through all four corners of the grid, in this order. Every change of encoding on the way is exact. The one change of reference is stage 2, the tone curve, which a scene-referred mode would replace with scene light copied straight up to white.

<div data-figure="render-order"></div>

The colour controls sit after the curve on purpose. There, Saturation and Vibrance know how close each colour already is to the edge of what the output can show, so they hold hue and clip nothing. [How Redlamp handles raw files](https://github.com/pdcgomes/redlamp/blob/main/docs/raw-pipeline.md) describes everything before the develop stage, from the file on disk to the camera colour it starts from.

## What the feedback asked for

The feedback measured a grey scale: plotted against each patch's reference L*, the L* in Redlamp's export bends away from a straight line. Two meanings of "linear" meet in that sentence.

### Linear numbers

Values proportional to light, as in Redlamp's working space. They say nothing about the tone curve: today's render saved as a TIFF with linear numbers would fail the same check as the sRGB export, because those numbers hold screen light, curve and all.

### Linear response

Screen light proportional to scene light up to white, with no curve bending it. Then every patch's L* lands on its reference, a straight line with a slope of 1, whatever curve the file is written with, because L* is measured after decoding. This is what the feedback is asking for.

<div data-figure="grey-scale"></div>

## What would fix it

Two changes, and neither is a change of encoding.

**A scene-referred mode fixes the shape.** It's a rendering with no tone curve and no look: screen light equals scene light up to white. In the figure above, the curve becomes the diagonal, and once exposure is anchored, a metered 18% grey reads L* 49.5. Its exports can keep an ordinary curve, sRGB or a reference space for archive masters: their numbers aren't linear, but the light they describe is the scene's.

**Tying exposure to each camera's metering fixes the position.** Redlamp scales each sensor's clip point to 1.0, and cameras put a metered 18% grey roughly 3.3 to 3.7 stops below clip, depending on how each maker calibrates ISO. Redlamp only adds a baseline exposure for DNG files, which carry one; other raws get none. So Exposure 0 means a different grey on each camera, which would explain exports coming out slightly dark. Anchoring slides the line along; it doesn't straighten it.

Neither exists in Redlamp yet.

## In one line

Linear is how the numbers are written; scene-referred is whose light they describe. Redlamp edits scene-linear, renders through the tone curve and writes display-encoded files. The feedback asks for files that still describe the scene: that's a change of rendering and of how exposure is anchored, not of encoding.

The tone curve, its constants and the render order are [Develop.metal](https://github.com/pdcgomes/redlamp/blob/main/packages/RedlampKernels/Sources/Shaders/Develop.metal)'s. The grey-scale model is [greyscale.py](https://github.com/pdcgomes/redlamp/blob/main/research/tone-reproduction/greyscale.py)'s, which also measures Redlamp's renders of chart raws. The sRGB curve is IEC 61966-2-1's, and the lightness scale is CIE 1976 L*.
