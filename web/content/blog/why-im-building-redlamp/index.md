---
title: Why I'm building Redlamp
summary: A native, open-source raw editor for the Mac that works like Lightroom. It's early, and I'd love your help testing it.
date: 2026-10-01
cover: /synced/images/hero.png
coverAlt: Redlamp editing a raw photo of a dancer in a street parade, with Lightroom-style panels on the right
---

I shoot raw on a Sony A7R V, and like most people who shoot raw, I edit the way Lightroom taught us to: the same panels, the same sliders, the same shortcuts. Lightroom works, but it has never felt at home on the Mac, and it comes with a subscription and a cloud I don't need. I wanted that way of working in an app that belongs on macOS, so I started building one.

That's Redlamp. It's a raw photo editor for the Mac, written from scratch in Swift and Metal for Apple Silicon, and it's free and open source.

## What it is

If you know Lightroom's Develop module, you already know your way around. The panels are in the same order, the sliders have the same names and ranges, and Lightroom Classic's shortcuts work. Underneath, it's a native app that renders on the GPU, so it keeps up while you drag a slider.

It's an editor, not a catalog. You open a folder, and your edits are saved in a small file next to each photo, so the originals are never touched. There's no import step and no library to manage, and your photos never leave your Mac.

## What works today

- **The Develop panels:** Basic (with Texture, Clarity and Dehaze), Tone Curve, Color Mixer, Color Grading, Detail and Effects.
- **Masks:** gradients, a brush, color and luminance ranges, and AI masks that run on your Mac: subject, sky, background and people, down to face skin, eyes and teeth.
- **36 film looks**, built from the manufacturers' datasheets, each with its stock's own curves and grain, plus halation and bloom. There are Fujifilm-style recipes too.
- **Recipes**, Redlamp's name for presets, profiles and LUTs in one. Hover to preview, click to apply, and bring in your own `.cube` files.
- **Export** to JPEG, HEIC, TIFF and PNG.

![Redlamp's Masks panel, with a radial gradient over a tree shown in red](/synced/images/masking.png "Masks combine as Lightroom's do, by adding, subtracting and intersecting, and each has its own sliders.")

![The Film Looks window, previewing film stocks on the same photo](/synced/images/film-catalog.png "The Film Looks window previews every stock on your photo.")

## What it isn't yet

It's pre-alpha. It needs an Apple Silicon Mac on macOS 26 or later, and there's no crop, healing or lens corrections yet; those are next. Fujifilm's X-Trans files open, but their demosaic is a first version. And this first release can't update itself, so Homebrew is the easiest way to stay current.

## Try it

```
brew tap pdcgomes/redlamp https://github.com/pdcgomes/redlamp
brew install --cask redlamp
```

Or download the app from the [latest release](https://github.com/pdcgomes/redlamp/releases/latest); it's signed and notarized. When a new version comes out, `brew upgrade --cask redlamp` gets it.

## How you can help

What I need most is people opening their own raws and telling me what breaks or looks wrong. Only a handful of cameras have been properly checked so far, so whatever you shoot is useful.

Please file anything you find as a [GitHub issue](https://github.com/pdcgomes/redlamp/issues). The camera model, your macOS version and, if you can share it, the raw file make a big difference. Feature requests are welcome too.

If you can share sample files under CC0, [raw.pixls.us](https://raw.pixls.us) collects them, and samples there are how cameras get added to Redlamp's test suite.

## What's next

The next release, 0.2.0, will update itself. It also brings two things that already work in the development version: a full Export dialog, and ⌘K, a command palette that reaches every control from the keyboard. After that come crop, healing and lens corrections.

I'll also write here about how Redlamp is built, starting with how the film looks come from datasheets and what it took to keep a slider drag smooth. There's an [RSS feed](/blog/feed.xml) if you'd like to follow along.

If you'd rather watch than read, here's Redlamp in 24 seconds:

<figure>
<video src="/video/redlamp-explainer.mp4" poster="/video/redlamp-explainer-poster.jpg" controls playsinline preload="none"></video>
</figure>

Thanks for reading,\
Pedro
