# Linear vs scene-referred

The article: https://redlamp.app/articles/linear-vs-scene-referred, published on 9 October 2026.

The card is drawn in pixel art by `card.py`, with the pixel-graphics skill's kit instead of the blog room's card. `PYTHONPATH=~/.cursor/skills/pixel-graphics/scripts python3 docs/blog/social/linear-vs-scene-referred/card.py --downloads` renders `card.png`, `card.gif`, `card.mp4` and `thumb.jpg` here, which aren't committed, and copies the first three to `~/Downloads/redlamp-linear-vs-scene-referred.png`, `.gif` and `.mp4`; the copies there were made on 9 October.

## X

Not posted yet. It takes `card.gif` (0.1 MB), or `card.mp4`. 277 of 280 characters, with the link counted as 23:

```text
Redlamp is a free, open-source raw editor for the Mac that works like Lightroom.

A user's feedback pointed out it has no scene-referred mode, and that a grey scale's L* isn't linear against the chart.

New article: what linear and scene-referred mean.

https://redlamp.app/articles/linear-vs-scene-referred
```

The alternative, 251 characters:

```text
Redlamp is a free, open-source raw editor for the Mac that works like Lightroom.

Linear and scene-referred often get used as if they meant the same thing. I wrote up what each one means, with figures you can try.

New article:
https://redlamp.app/articles/linear-vs-scene-referred
```

## LinkedIn

Not posted yet. Attach `card.mp4` (LinkedIn plays it as a video) or `card.png`. 197 words:

```text
I've been building Redlamp, a free, open-source raw photo editor for the Mac that works like Lightroom.

Some feedback from a user recently pointed out two things: Redlamp has no scene-referred mode, and in its exports, a grey scale's L* isn't linear against the chart's own values.

Answering it properly meant untangling two words that often get used as if they meant the same thing. Linear is about how a pixel's numbers are written: twice the light gives twice the number. Scene-referred is about whose light they describe: the light in front of the camera, which has no ceiling, rather than the light a screen gives off, which stops at white. The tone curve turns scene light into screen light.

I wrote an article that works through both, with figures you can try, drawn with Redlamp's own tone curve. That curve renders a grey card at L* 64.3, where a straight copy of the scene's light would give 49.5. One figure runs a ColorChecker's grey row through it, and no setting of Exposure puts all six patches on the diagonal.

https://redlamp.app/articles/linear-vs-scene-referred

If you check your exports against a target, I'd love to hear how you do it.
```

## More images

None. The article's figures are interactive components in `web/components/articles/linear-vs-scene-referred/`, so there are no image files beside its `index.md`; one of them, such as the grey row, would need capturing first.

## Alt text

The card: Redlamp's card for the article Linear vs scene-referred, in pixel art. Below the title: Linear: how the numbers are written. Scene-referred: whose light they describe. Then a grey card at 0.18 in scene light: L* 64.3 through Redlamp's tone curve, in red, and L* 49.5 with no curve. Beside it, a chart of rendered L* against scene light from 0 to 1.0: Redlamp's tone curve is a red S that runs just under the dashed diagonal of no curve in the shadows and above it through the mid-tones, with the grey card marked on both. As it plays, the two lines draw in and the grey card's marker rises from the diagonal to the curve. The address is redlamp.app/articles.
