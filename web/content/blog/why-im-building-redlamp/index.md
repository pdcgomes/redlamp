---
title: Why I'm building Redlamp
summary: A native, open-source raw editor for the Mac that works like Lightroom. It's early, and I'd love your help testing it.
date: 2026-10-01
cover: /synced/images/hero.png
coverAlt: Redlamp editing a raw photo of a dancer in a street parade, with Lightroom-style panels on the right
---

I'm a software engineer and a hobbyist photographer. I'm originally from Portugal, I've lived in London for the past fourteen years, and I've been writing software professionally since 2003. Photography has been a fairly constant interest, and I enjoy editing as much as taking the photos.

Like many people, I started with Photoshop and eventually moved to Lightroom. It was more focused and suited the way I wanted to work. I bought a licence and paid for upgrades when they felt worthwhile.

The move to a subscription wasn't something I was particularly happy about. Over time, the product also became harder to follow: Lightroom Classic, Lightroom, mobile and web versions, different capabilities, and different approaches to local and cloud storage. I adapted, but I've wanted a credible alternative for a long time.

I have a lot of respect for what Adobe has built. I've also worked in very large companies, and I understand that decisions which seem obvious from outside can be difficult to make from within. Still, as a user, I'd like more choice.

## Why attempt it now?

AI has changed how much software I can build on my own. With enough iteration, I can explore ideas that I would previously have dismissed because of the time and people they'd require.

That has made me spend more time thinking about products I've always wanted to exist. A Lightroom alternative is fairly high on that list. It also raises a question I find interesting: how far can one person get with the tools we have now?

Building the interface is relatively straightforward. A model can produce an application with familiar panels and sliders, and it can look convincing quite quickly. But there's a substantial amount of work behind a photo editor that you don't see in the interface: colour science, camera behaviour, lens corrections, film characteristics, and the research and measurements that make those things reliable.

I don't have much background in those areas. Before this project, I'd done very little with the algorithms used in raw processing, and I know little about colour science or chemistry. AI helps me investigate and implement things I couldn't have tackled alone, but I still need ways to establish whether the results are correct.

That's part of what makes this project interesting to me. I can get much further with the implementation than I could before, while also having to learn how to evaluate work in areas where I'm not an expert.

Today, 1 October, I've released the first pre-alpha of Redlamp, two days after starting it. It already has a fairly capable raw editing workflow, including some features that are far from trivial to implement.

I'm surprised by how quickly it has come together. I'm also conscious that getting to a working pre-alpha says very little about how long it will take to build an editor people can depend on. Camera compatibility, rendering quality and the details of everyday use need much more testing.

I'd like people who shoot raw to try it on their own photos, and people who understand these areas better than I do to tell me where it's wrong.

## What Redlamp does today

The editing interface should feel familiar if you use Lightroom Classic. The Develop panels are in the same order, the sliders use the same names and ranges, and Lightroom Classic's keyboard shortcuts work. It's a native macOS app with GPU rendering, so adjustments update as you drag a slider.

In this first release, you open a folder and start editing. Edits are stored in sidecar files beside the photos, leaving the originals untouched. There's no import step or catalog to manage, and your photos stay on your Mac.

The current feature set includes:

- The Basic, Tone Curve, Color Mixer, Color Grading, Detail and Effects panels, including Texture, Clarity and Dehaze.
- Gradient, brush, colour range and luminance range masks. Local AI masks can select subjects, sky, background and people, including face skin, eyes and teeth.
- Thirty-six film looks built from manufacturers' datasheets, with stock-specific curves and grain, plus halation and bloom. There are also Fujifilm-style recipes.
- Recipes that bring presets, profiles and LUTs together. You can preview them by hovering, apply them with a click, and import your own `.cube` files.
- Export to JPEG, HEIC, TIFF and PNG.

![Redlamp's Masks panel, with a radial gradient over a tree shown in red](/synced/images/masking.png "Masks support adding, subtracting and intersecting selections, with a separate set of adjustments for each mask.")

![The Film Looks window, previewing film stocks on the same photo](/synced/images/film-catalog.png "The Film Looks window lets you compare the stocks using your own photo.")

## What's still missing

This is a pre-alpha. It requires an Apple Silicon Mac running macOS 26 or later, and it doesn't yet have crop, healing or lens corrections. Those are next on the list.

Fujifilm X-Trans files open, but the demosaicing implementation is an initial version. Only a handful of cameras have been properly tested so far, so there's plenty of room for problems I haven't seen on my own files.

The first release also has no automatic updater. For now, Homebrew is the easiest way to stay current.

## Installing it

```
brew tap pdcgomes/redlamp https://github.com/pdcgomes/redlamp
brew install --cask redlamp
```

You can also download the signed and notarised app from the [latest release on GitHub](https://github.com/pdcgomes/redlamp/releases/latest).

With Homebrew, updating is:

```
brew upgrade --cask redlamp
```

## Feedback that would help

The most useful thing you can do is open your own raw files, edit them as you normally would, and tell me what breaks or looks wrong. Camera coverage is still limited, so testing files from whatever you shoot is helpful.

Please report problems through [GitHub issues](https://github.com/pdcgomes/redlamp/issues). Include your camera model and macOS version, and, if you're able to share it, the raw file. For rendering problems, a screenshot alongside the camera's JPEG or Lightroom's rendering makes it much easier to understand the difference.

If you have experience with colour science, film or raw processing, I'd especially welcome feedback on those parts. The [code is open](https://github.com/pdcgomes/redlamp#contributing) if you want to inspect the implementation or contribute. Feature requests are welcome too.

Sample raws shared under CC0 through [raw.pixls.us](https://raw.pixls.us) can be added to Redlamp's test suite, so they help beyond a single bug report.

## What I'm working on next

The next release, 0.2.0, will add automatic updates. It will also include the full Export dialog and a command palette, opened with ⌘K, which already work in the development version. Crop, healing and lens corrections follow after that.

I'll use this blog to write about the work as it develops, including how the film looks are derived from datasheets and what was involved in keeping slider adjustments responsive. You can follow it through the [RSS feed](/blog/feed.xml).

There's also a 24-second video of Redlamp if you'd like to see it running:

<figure>
<video src="/video/redlamp-explainer.mp4" poster="/video/redlamp-explainer-poster.jpg" controls playsinline preload="none"></video>
</figure>

Thanks for reading,\
Pedro
