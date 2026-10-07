# Redlamp's architecture, in six pictures

The post: https://redlamp.app/blog/redlamp-architecture, published on 7 October 2026.

The card's words are in `card.json`. `.cursor/skills/redlamp-blog/card/render.py docs/blog/social/redlamp-architecture` renders `card.png`, `card.gif` and `card.mp4` here; they aren't committed.

## X

Not posted yet. It takes `card.gif`, or one of the post's own animations instead (see More images). 265 of 280 characters, with the link counted as 23:

```text
Redlamp is a free, open-source raw editor for the Mac that works like Lightroom.

I drew its architecture as six pixel-art animations, from the layers down to the one Metal kernel that runs every slider.

New post: how it all fits together.

https://redlamp.app/blog/redlamp-architecture
```

The alternative, 279 characters:

```text
Redlamp is a free, open-source raw editor for the Mac that works like Lightroom.

Its UI and engine only meet through one small API, and every mask and slider runs in a single pass on the GPU.

New post: Redlamp's architecture, in six pixel-art pictures.

https://redlamp.app/blog/redlamp-architecture
```

## LinkedIn

Not posted yet. Attach `card.mp4` (LinkedIn plays it as a video) or `card.png`. 179 words:

```text
I've been building Redlamp, a free, open-source raw photo editor for the Mac that works like Lightroom, mostly with AI agents in Cursor.

Architecture is hard to explain without a wall of text, so I tried something different: six small pixel-art animations, drawn in code with a kit I've been building for this blog.

They go from the top of the app to the bottom. Five layers, where the UI and the engine only meet through a small API of plain values. Fourteen modules, and a build that fails if the engine imports UI code. A raw file's path to the screen, where one Metal kernel applies every mask and slider in a single pass. How a slider change reaches the screen within a frame. Edits saved next to your photos, which are never written to. And the AI models, which run on the Mac, so no photo is ever uploaded.

The kit is open source as well, with the scripts for all six.

https://redlamp.app/blog/redlamp-architecture

If you draw diagrams of your own systems, I'd love to know what you use.
```

## More images

The post's own pictures, beside its `index.md` in `web/content/blog/redlamp-architecture/`: `01_overview.gif` (the five layers, with an edit going down and the frame coming back up), `02_modules.gif`, `03_pipeline.gif` (a photo through the stages, then through the fused kernel's steps), `04_frame.gif`, `05_edits.gif` and `06_models.gif`, each with a still `NAME-poster.png`, and `poster.png`, all six in one tall image. X takes one GIF per post and won't mix a GIF with pictures, so a post's GIF goes instead of the card, not beside it: `01_overview.gif` or `03_pipeline.gif` work best.

## Alt text

The card: The Redlamp blog's card for Redlamp's architecture, in six pictures. Below the title: Redlamp is five layers and fourteen modules. This is how they fit together, drawn in pixel art. The address is redlamp.app/blog, on a dark wall lit red from the upper left.

`01_overview.gif`: Redlamp as a stack of five layers in pixel art: the apps, the UI, EngineAPI, the engine and Metal. An edit travels down from the UI through EngineAPI to the engine, and the frame travels back up.

`03_pipeline.gif`: The stages a photo goes through in Redlamp, in pixel art: the raw file, the sandboxed decoder, GPU preparation, demosaicing, the detail stage, the fused kernel and the canvas, with the kernel's steps in order and measured timings below. A photo moves through each stage in turn, and a cursor runs through the kernel's steps.
