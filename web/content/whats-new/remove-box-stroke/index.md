---
version: 0.3.5-alpha
date: 2026-10-31
symbol: bandage
title: Remove by drawing a box or brushing
summary: Drag a box around something or brush over it to remove it, and add what a pick left out.
image: picks.jpg
imageAlt: Develop's Healing tool with Click picks on Object and Drag on Rectangle, over a garden in which a box dragged around a toy windmill has picked its blades and vane, outlined where Remove fills them with the hedge and flowers behind
---

In the Healing tool, set Click picks to Object and choose Rectangle or Brush under Drag. Drag a box around something, or brush over it, and Segment Anything 2.1 finds its shape on your Mac; Remove fills it, as it fills a click's pick. Drag is shared with the Objects mask, which picks the same way.

A stroke over the selected pick, or along its edge, adds what it brushes to that pick, such as a handle a click left out. A stroke anywhere else picks something new.
