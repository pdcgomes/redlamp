---
title: Why I'm building Redlamp
summary: A native, open-source raw editor for the Mac that works like Lightroom. It's early, and I'd love your help testing it.
date: 2026-10-01
cover: /synced/images/hero.png
coverAlt: Redlamp editing a raw photo of a dancer in a street parade, with Lightroom-style panels on the right
---

Hello everyone,

My name is Pedro, I'm originally from Portugal but have called the UK (London) my home for the past 14 years. My career as a Software Engineer started in 2003 but my interest in computers and technology started probably back in 1987-1988.
I also happen to love photography and have been a hobbyist photographer, on and off, for a great many years now. I love shooting and the editing process. 

Like so many others I used to edit my photos in Adobe Photoshop and eventually moved on to Lightroom - it was a simpler, more focused tool. Felt less powerful (and it was), but it was arguably the better tool **for me**.

Adobe is a very large company (todo: add references here). I've worked for very large companies through my career, I understand how poor product decisions come to be, I understand how hard it is to do the right thing, even if it's obvious.
I'm not really here to criticise Adobe - they have a very successful business and have essentially defined the gold standard for various industries. I'm not here to change that.

I was happy with buying their software and using it. I owned it, I could upgrade to a new version (and pay for it), if I saw value in it. Then things got confusing.
Lightroom Classic, Lightroom, Lightroom Mobile, a web version, different feature sets, cloud, no cloud. I was happy with how things were, I did adapt, but I wasn't happy.

Enter the new era of Software Engineering - we can now essentially do anything (given enough tokens, persistency and some patience). This past year, I've been trying to adapt. I've always been productive and able to jump between product thinking and fast execution.
Execution and execution volume no longer matter. Everyone is, or can be, an absolute machine. So I doubled down on the former. There are many itches I've yet to scratch and many that I've been scratching this past year.

Building a legitimate Lightroom alternative is most certainly up there. It's certainly not easy, and I have no illusions that a great deal of what makes Lightroom good isn't something that can just be outsourced to a bunch of agents. There's real research, access to specialist hardware (cameras, scanners, film stock, lenses, experts, etc.). All of that is part of Adobe's IP and arguably where a lot of their value comes from, although most of us only really see and think of "Lightroom".
So the challenge - how close can we really get? At the time of writing getting any decent model to write the shell of a Lightroom-like application that looks good, feels good, is responsive, offers the same UI is not a problem at all. But the real value isn't there. 

I'll be really honest here - I know almost nothing about color science, little about chemistry, I may have heard of a few algorithms that tools like Lightroom and Photoshop may have used, but beyond a flood fill (which has many other uses), I've never really dabbled into any of that. This is all new territory for me, but that's undoubtedly the beauty of the era we live in.
Any fool (like me) can wield great power and pretend they are an expert in many many (many!) domains.

Here's the hard truth. It takes a village. Always (or almost always). Most products I've worked on in the past that have been successful or moderately successful had different people with different skillsets, strenghts and weekeness making all sorts of decisions I wasn't involved in, or I had, at best _some_ influence in. The reality is, it is rare for a single person to be able to continuously wear many hats and be equally productive across many domains. Even if you could do it, there's the small matter of biology. Sleep, food, energy, mood, family, friends, responsibilities, days off. All of that competes for your time, and there's only much you can achieve.

It never even crossed my mind to attempt to build something like this out of the all the itches I wanted to scratch. It's simply too much for a single person. Turns out, not anymore (well, within reason). 

So here we are. It's the 1st of October and the first pre-alpha version of Redlamp is out. What's absolutely crazy is that it took literally *two days* to get to this point. Think about it. In two days a single person can produce a competent photo editor with a lot of advanced and non-trivial functionality that we now take for granted. I'm not suggesting everyone should go out and build their own version of everything, but it does mean that it is now possible to genuinely compete with larger players and offer legitimate alternatives to consumers.
Yes, there will always be trade-offs, but probably not as many as you'd like to believe. Just two years ago this would have been impossible to achieve any of this with a substantial team of engineers and researches, significant funding and at least a few years of development.

Two. Days.

So here we have it. Redlamp. 

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
