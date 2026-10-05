---
name: redlamp-site
description: Map of redlamp.app, the Next.js website in web/: its stack and commands, its pages, the home page's sections with their anchors, components and content sources, the brand's Tailwind tokens and classes, how to add a section or page, how to check and screenshot it, and how to work alongside other sessions. Use when changing the website or its copy, adding a section or page to it, or answering how the site is built.
---

# redlamp.app (`web/`)

The website presents the README. Much of it is read from the repository when it builds; the rest is curated in `web/content/`. Start from this map rather than re-reading the site. `web/README.md` covers deployment and the relays the app posts to, and `.cursor/rules/landing-page.mdc` (attached when you touch `web/`) says what to update when the README changes.

## Stack and commands

- Next.js 16 (App Router), React 19, Tailwind CSS 4 and TypeScript, with `marked` for the blog and Vercel Web Analytics. Add no dependencies: the npm registry is unreachable from the sandbox, so only `npm install --offline` works.
- Server components by default. `"use client"` only where there's interaction: `MobileMenu`, `Lightbox`, `HeroShots`, `Gallery`, `YouTubeFilm`, `Comparison`, `CameraList`, `FilmTable`, `StarNudge`.
- `mise run site` serves it on http://localhost:3000 (running `npm ci` first if `node_modules` is missing); `mise run site -- build` builds it.
- Before every `dev` and `build`, `scripts/sync-assets.mjs` copies `docs/images`, `docs/images/film` and `docs/brand`, and the blog posts' images, into `public/synced/` (gitignored).
- Check with `cd web && npm test && npm run typecheck && npm run build`. Tests are `lib/*.test.ts` under `node --test`. Add `scripts/roadmap-sync.py --check` and `scripts/camera-list.py --check` when the README, tracker, comparison or cameras change.
- Commits for site work are titled `Site: …`, or after the page (`Cameras page: …`), naming a tracker row and its issue when there is one.

## Pages (`web/app/`)

| Route | Content |
| --- | --- |
| `/` (`page.tsx`) | The home page's sections, in the order below |
| `/compare` | `docs/lightroom-comparison.md` through `lib/comparison.ts`; tracker IDs link to their issues (`trackerIssues`) |
| `/cameras` | `docs/cameras.md` through `lib/cameras.ts` |
| `/cameras/test` | How to run the camera bench: steps and screenshots in `content/camera-bench.ts`, counts from `lib/cameras.ts` |
| `/performance` | `docs/performance/metrics.json` and `history.jsonl` through `lib/performance.ts`, drawn by `components/charts/` |
| `/blog`, `/blog/<slug>`, `/blog/feed.xml` | `content/blog/<slug>/index.md` through `lib/blog.ts`; `web/README.md` has the front matter |
| `/api/…` | The relays the app posts to, such as `/api/feedback` (`lib/feedback.ts`, `lib/github-app.ts`), described in `web/README.md` |
| `/api/whats-new` | The app's What's New feed, linked from no page: `content/whats-new/<id>/index.md` through `lib/whats-new.ts`; `web/README.md` has the front matter |

Each page exports `metadata` (title, description, canonical, Open Graph and Twitter; `cameras/page.tsx` is a compact example), and most have an `opengraph-image.tsx` drawn with `next/og` (see `compare/`). `layout.tsx` holds the header, the footer, the lamp glow, Inter with its optical-size axis and the default metadata (`en-GB`). `sitemap.ts` lists the pages; `next.config.ts` has the security headers and the `/appcast.xml` redirect.

## The home page, top to bottom

Components are in `components/sections/`. Content without a file named is an export of `content/features.ts`.

| Section | Anchor | Component | Content |
| --- | --- | --- | --- |
| Hero: status pill, buttons, badges, shots, and the star nudge | | `Hero.tsx`, `HeroShots.tsx`, `site/StarNudge.tsx` | `heroShots`; the release from `lib/github.ts` |
| Why Redlamp | `#why` | `Story.tsx` (`Story`) | Written in the component |
| Principles | `#principles` | `Story.tsx` (`Principles`) | `principles` |
| Command palette | `#command-palette` | `CommandPalette.tsx` | `commandPalette`, `paletteSteps` |
| Features, a row each | `#features`, and each feature's `id` | `Features.tsx` (`Features`) | `features`, `focusStacking` |
| Performance strip | | `Features.tsx` (`Performance`) | `docs/performance/` |
| Everything that works today | `#everything` | `Features.tsx` (`EverythingToday`) | The README's What works today (`lib/readme.ts`) |
| Film looks | `#film` | `Films.tsx`, `FilmTable.tsx` | `content/films.ts` |
| Gallery | `#gallery` | `Gallery.tsx` | `gallery` |
| Roadmap, and the comparison summary | `#roadmap` | `Roadmap.tsx`, `ComparisonSummary.tsx` | The README's roadmap, the tracker and the comparison |
| Introducing Redlamp, the film | `#watch` | `WatchFilm.tsx` | `film` in `lib/site.ts` |
| AI disclosure | `#ai` | `AIDisclosure.tsx` | `aiDisclosure` in `content/ai.ts` |
| Open source, build from source, Homebrew, Product Hunt | `#open-source` | `OpenSource.tsx` | `lib/site.ts` |

The header (`components/site/SiteHeader.tsx`) shows its `links` from the `sm` breakpoint up, and `MobileMenu.tsx` shows the same links below it. They're absolute (`/#roadmap`) so they work from every page. The bar is full, so a new home-page section is linked from the footer's Project list (`SiteFooter.tsx`) instead.

## Where things live

- `lib/site.ts`: every external string and link (`site.github`, `readme`, `license`, `film`, `productHunt`, `homebrew`, `buildFromSource`), and `repoLink`, which turns a README-relative link into a GitHub one.
- `lib/repo.ts`: reads repository files from `..` at build time. Each path is spelled out so the build traces it, so a new file needs its own `RepoFile` case. `sourceCommit()` gives the commit for the "Read at commit …" lines.
- `lib/readme.ts`, `tracker.ts`, `comparison.ts`, `cameras.ts`, `performance.ts` and `blog.ts` parse those files, each with tests. Files the tests load use relative imports only.
- `lib/github.ts`: the star count, the latest release and the tracker's issues, refreshed hourly. Each falls back (no count, the releases page, no issue links) when GitHub doesn't answer, so builds work offline. In the agent sandbox, build with `NODE_USE_ENV_PROXY=1` for the build to reach GitHub through the proxy.
- `components/site/StarNudge.tsx`: once per browser tab, and never with Reduce Motion, energy gathers behind the hero's lamp while it trembles, shoots in an arc into the header's GitHub button, and a sign drops from under the button on a rope. The elements it moves carry `data-star-nudge` in `Hero.tsx` and `SiteHeader.tsx`; the sign's physics is `lib/hanging-sign.ts`. Open the home page in a new tab to see it again. `docs/brand/star-nudge.md` documents it, how to reuse it and its known issues, and [capture-nudge.py](capture-nudge.py) regenerates that page's images and checks the sign at both widths.
- `components/ui/`: `SectionHeading` (eyebrow, `h2` and intro), `LinkButton` (one `primary` per page, the rest `secondary`), `Badge`, the glyphs in `Buttons.tsx`, `Inline`, `Lightbox`, `StatusMark`, `YouTubeFilm` and `ProductHuntCard`.
- `Inline` renders the README's inline Markdown: bold, italics, code and links. Links go through `repoLink`, so `docs/x.md` becomes a GitHub link and a site path such as `/compare` breaks; write those in JSX.
- `components/brand/Logo.tsx`: `Lockup`, `Mark` and `AppIcon`.

## Look and voice

- Tailwind 4 `@theme` tokens in `app/globals.css`. Colours: `wall`, `wall-raised`, `bakelite`, `bakelite-hi`, `steel`, `safelight`, `safelight-deep`, `filament`, `ring`, `paper`, `ink`, `mute`, `dim`, `hairline`, `hairline-strong`. Radii: `card`, `pill`. Animations: `warm-up`, `rise`, `breathe`, `fade-in`.
- Classes: `.font-display` (headings), `.eyebrow`, `.surface` (cards), `.glass` (the header), `.shot` (screenshots), `.button-primary` and `.button-secondary`, `.post` (the blog's Markdown) and `.lamp-glow`.
- Text is `text-paper` for headings and emphasis, `text-mute` for body and `text-dim` for footnotes and sources. Inline links: `text-paper underline decoration-hairline-strong underline-offset-3`.
- Red is light, once per view (`docs/brand/README.md`): the lamp glow, the mark and the one primary button. Never a flat red fill.
- Copy is in the brand voice: calm, plain and precise, with no exclamation marks or superlatives, and only claims the README makes. Spelling is British (colour; licence for the noun), but product names such as Color Mixer stay as they are. In JSX text, write `&apos;`.
- Write for a reader who has none of the context: not the chats, the tracker or the other sessions. Every term (a sidecar, plan mode, the tracker, a DEC row, a branch, another session's feature) is explained where it first appears, or left out.

## Adding a home-page section

1. Put its copy in `content/<name>.ts` if it's more than a heading and a paragraph. Inline Markdown renders through `Inline`.
2. Write `components/sections/<Name>.tsx` in the shape of `AIDisclosure.tsx`:

   ```tsx
   <section id="name" className="scroll-mt-24 px-6 py-24">
     <div className="mx-auto max-w-6xl">
       <SectionHeading eyebrow="…" title="…">Intro.</SectionHeading>
       <div className="mt-10 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
         <div className="surface p-6">
           <h3 className="font-display text-[18px] text-paper">…</h3>
           <p className="mt-2 text-[14px] leading-relaxed text-mute">…</p>
         </div>
       </div>
     </div>
   </section>
   ```

   A section that starts a new topic takes `py-24`; one that continues the section above takes `pb-24`. `scroll-mt-24` keeps its anchor clear of the sticky header.
3. Place it in `app/page.tsx`, and link it from the footer as `/#name`.
4. A new page also needs its `metadata`, an `opengraph-image.tsx`, a line in `sitemap.ts` and a link in the footer, or in the header if there's room.

## Seeing it

After `npm run build`, serve the site with `npx next start --port 3123` (in the background), then capture an element at a desktop width (1440 px) and a phone width (390 px):

```bash
python3 -m venv /tmp/rl-site-shot && /tmp/rl-site-shot/bin/pip install --quiet playwright
/tmp/rl-site-shot/bin/python .cursor/skills/redlamp-site/capture.py http://localhost:3123/ '#ai' /tmp/rl-site-shot/ai
```

[capture.py](capture.py) drives the installed Google Chrome with the flags the agent sandbox needs, so Playwright downloads no browser, and it reports any horizontal overflow. In the capture of a tall element, the sticky header can appear partway down: that's how the screenshot is stitched, not the layout.

## Alongside other sessions

During an agent wave, `AGENTS.md` keeps `web/` off limits, and other sessions often have site work in flight. Before a larger change, look for it in the other worktrees:

```bash
for wt in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
  git -C "$wt" status --short -- web; git -C "$wt" log --oneline main..HEAD -- web
done
```
