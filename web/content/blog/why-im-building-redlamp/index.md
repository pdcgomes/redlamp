---
title: Why I'm building Redlamp
summary: A native, open-source raw editor for the Mac that works like Lightroom. It's early, and I'd love your help testing it.
date: 2026-10-01
cover: /synced/images/hero.png
coverAlt: Redlamp editing a raw photo of a dancer in a street parade, with Lightroom-style panels on the right
---

Hello, I'm Pedro. I'm originally from Portugal, and London has been my home for the past 14 years. I've worked as a software engineer since 2003, and I've been fascinated by computers since around 1987.

I'm also a hobbyist photographer, on and off, and have been for a great many years. I love both the shooting and the editing.

Like so many others, I started out editing my photos in Photoshop and eventually moved to Lightroom. It was a simpler, more focused tool. It felt less powerful, and it was, but it was the better tool **for me**.

Adobe is a very large company. I've worked for very large companies myself, so I understand how poor product decisions come about, and how hard it can be to do the right thing, even when it's obvious. I'm not here to criticise Adobe: it has a very successful business and has essentially defined the gold standard in several industries, and I'm not out to change that.

I was happy buying their software and using it. I owned it, and I could pay to upgrade to a new version when I saw value in one. Then things got confusing: Lightroom Classic, Lightroom, Lightroom Mobile, a web version, different feature sets, cloud and no cloud. I adapted, but I wasn't happy.

Enter the new era of software engineering, in which we can do almost anything, given enough tokens, persistence and patience. I've spent this past year adapting to it. I've always been productive, and able to move between product thinking and fast execution, but execution, and how much of it you can do, no longer sets anyone apart: everyone is, or can be, an absolute machine. So I've doubled down on product thinking. There are many itches I've yet to scratch, and many I've been scratching this past year.

Building a legitimate alternative to Lightroom is near the top of that list. It isn't easy, and I have no illusions: a great deal of what makes Lightroom good can't simply be handed to a bunch of agents. Behind it is real research, and access to specialist equipment and people: cameras, scanners, film stock, lenses and experts. All of that is Adobe's IP, and arguably where much of its value lies, even if most of us only ever see "Lightroom".

So the challenge is: how close can we really get? At the time of writing, getting any decent model to write the shell of a Lightroom-like application, one that looks good, feels good, responds quickly and offers the same interface, isn't a problem at all. But that isn't where the real value is.

To be completely honest, I know almost nothing about color science and little about chemistry. I may have heard of a few of the algorithms that tools like Lightroom and Photoshop use, but beyond a flood fill (which has plenty of other uses), I'd never really dabbled in any of it. This is all new territory for me, and that's the beauty of the era we live in: any fool, like me, can wield great power and pretend to be an expert in many, many domains.

Here's the hard truth: it takes a village, always or almost always. The successful, or moderately successful, products I've worked on all had people with different skills, strengths and weaknesses making all sorts of decisions I wasn't involved in, or had at best *some* influence over. It's rare for one person to keep wearing many hats and be equally productive in all of them. Even if you could, there's the small matter of biology: sleep, food, energy, mood, family, friends, responsibilities and days off all compete for your time, and there's only so much you can achieve.

Of all the itches I wanted to scratch, it never even crossed my mind to try building something like this. It was simply too much for one person. It turns out it isn't anymore, within reason.

So here we are. It's the 1st of October, and the first pre-alpha of Redlamp is out. What still astonishes me is that it took *two days* to get here. Think about that: in two days, one person can produce a competent photo editor, with a lot of the advanced, non-trivial functionality we now take for granted. I'm not suggesting everyone should go and build their own version of everything, but it does mean it's now possible to compete with much larger players and offer people legitimate alternatives. There will always be trade-offs, but probably fewer than you might think. Just two years ago, getting this far would have taken a substantial team of engineers and researchers, significant funding and at least a few years of work.

Two. Days.

Here it is: Redlamp.

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
