# redlamp.app

The project's website: Next.js (App Router), React and Tailwind CSS, with marked for the blog's Markdown, Vercel Web Analytics for page views, and no other runtime dependencies.

```bash
mise run site            # dev server on http://localhost:3000
mise run site -- build   # production build
```

## Where the content comes from

- **Roadmap and "Everything that works today"** are read from the repository's `README.md` at build time (`lib/readme.ts`), so the site follows the README. Each roadmap item's state and each phase's tracked-work counts come from the tracker rows the item names in `docs/research/research-tracker.md` (`lib/tracker.ts`).
- **The Compare page** (`/compare`) is read from `docs/lightroom-comparison.md` (`lib/comparison.ts`). Each tracker ID links to its GitHub issue, looked up hourly (`trackerIssues` in `lib/github.ts`); a `GITHUB_TOKEN` in the deployment's environment lifts GitHub's limit for anonymous requests, and without an answer from GitHub the links search for the ID instead. `scripts/roadmap-sync.py` keeps the comparison and the roadmap in step with the tracker.
- **The Performance page** (`/performance`) and the home page's performance strip are read from `docs/performance/metrics.json` and `docs/performance/history.jsonl` (`lib/performance.ts`), which `scripts/perf-record.sh` and `scripts/perf-backfill.py` write; the charts are drawn in SVG by `components/charts/`.
- **The Cameras page** (`/cameras`) is read from `docs/cameras.md` (`lib/cameras.ts`), whose camera lists `scripts/camera-list.py` generates from the decode tests, the CC0 sample downloads and LibRaw's own camera list.
- **Screenshots, film icons, sample sheets and logos** are copied from `docs/` into `public/synced` by `scripts/sync-assets.mjs`, which runs before every `dev` and `build`. Regenerate them with `mise run screenshots` and `redlamp recipe film --all --install --readme`, and the hero shots (`heroShots` in `content/features.ts`) with `scripts/capture-hero.sh <photo folder>`.
- **The lightbox:** every screenshot on the home page opens full size in `components/ui/Lightbox.tsx`, with ← → (or a swipe) through its own section's shots. The hero shows one shot at a time, chosen from the thumbnails beneath it (`components/sections/HeroShots.tsx`).
- **The download button** links to the latest GitHub release's zip, and the status pill at the top shows that release's version (`lib/github.ts`, refreshed hourly). The button stays hidden until the first release.
- **Features, film descriptions and principles** are curated in `content/`.
- **The film**, Introducing Redlamp, plays from YouTube (`film` in `lib/site.ts`), in its privacy-enhanced mode and only once the visitor presses play: until then the page shows the film's own poster (`public/video/introducing-redlamp-poster.jpg`, from `video/out/introducing`) and makes no request to YouTube. The 24-second explainer in `public/video` is the first blog post's.
- **The Product Hunt card** at the foot of the home page is Product Hunt's embed for Redlamp, drawn in the brand's materials (`components/ui/ProductHuntCard.tsx`). Its link and the listing's tagline are `productHunt` in `lib/site.ts`, to update when the listing changes. It shows the site's own app icon, so the page makes no request to Product Hunt.
- **Blog posts** are Markdown files in `content/blog/`; see below.

## The blog

Each post is `content/blog/<slug>/index.md`. When the site builds, posts become static pages at `/blog/<slug>`, listed at `/blog`, in the RSS feed at `/blog/feed.xml` and in the sitemap, each with its own share card. The folder name is the URL, in lowercase letters, digits and hyphens.

```markdown
---
title: Why I'm building Redlamp
summary: One line, for the index, the feed and link previews.
date: 2026-10-01
cover: hero.png          # optional, shown wide above the text
coverAlt: What the cover shows
draft: true              # optional: shown by `mise run site`, left out of production builds
---
```

- Put a post's images beside its `index.md` and use them by name, as in `![alt](masks.png "Caption")`; `sync-assets` copies them into `public/synced/blog/<slug>/`. Absolute paths such as `/synced/images/hero.png` work too.
- An image on its own line becomes a figure, wider than the text, with its title as the caption.
- Headings get ids from their text, so `#whats-next` links to "What's next". Start at `##`: the title is the page's heading.
- Raw HTML passes through, for embeds such as the explainer video in the first post.
- A post without a title, summary or date stops the build, naming the post.
- `npm test` covers the front matter and Markdown rules in `lib/blog.ts`.

## Deploying on Vercel

- Framework preset: Next.js.
- Root directory: `web`.
- Enable **Include files outside the root directory in the Build Step**, so the build can read `README.md` and `docs/`.
- Domain: `redlamp.app`.
- Enable **Web Analytics** in the project's Analytics tab. `<Analytics />` in `app/layout.tsx` reports page views from deployments on Vercel; under `mise run site` it only logs them to the browser console.

## The feedback relay

Redlamp's Report a Bug or Send Feedback (`packages/RedlampUI/Sources/Feedback`) posts each report to `POST /api/feedback`, which files it as a GitHub issue as the Redlamp Feedback GitHub App, so people need no GitHub account. The app writes the issue; the relay checks it (kind, labels, sizes, that screenshots are JPEGs and diagnostics are JSON), stores the attachments in a public attachments repo, links them into the body, and files the issue with only the labels that already exist. `GET /api/feedback/status?numbers=12,15` gives the state of the reports a Mac has sent, for its Your Reports list. The logic is in `lib/feedback.ts` and `lib/github-app.ts`, tested by `lib/feedback.test.ts`.

Its settings, for Production and Preview (Preview files into the attachments repo, so tests never reach the real issues):

| Variable | Value |
| --- | --- |
| `FEEDBACK_ENABLED` | `1` to accept reports; anything else switches the relay off (it answers 503) |
| `FEEDBACK_GITHUB_APP_ID` | The app's ID, on its General page |
| `FEEDBACK_GITHUB_INSTALLATION_ID` | Its installation on `pdcgomes` |
| `FEEDBACK_GITHUB_APP_PRIVATE_KEY` | The app's private key (sensitive): the PEM, or the PEM in base64 |
| `FEEDBACK_REPO` | `pdcgomes/redlamp` in Production, `pdcgomes/redlamp-feedback` in Preview |
| `FEEDBACK_ASSETS_REPO` | `pdcgomes/redlamp-feedback` |

The app needs Issues and Contents (read and write) on both repos. `scripts/feedback-labels.py --apply` makes the `in-app` and `component:` labels from `docs/feedback/areas.json`; run it after the areas change. Anything in the attachments repo is public, and a file removed from it stays in its history until the history is rewritten.

To try the relay locally, run it with the settings above and point a Debug build of Redlamp at it:

```bash
FEEDBACK_ENABLED=1 FEEDBACK_REPO=pdcgomes/redlamp-feedback … npx next dev --port 3123
defaults write app.redlamp.mac FeedbackEndpoint http://localhost:3123/api/feedback
defaults write app.redlamp.mac FeedbackSendsLive -bool YES   # Debug builds send dry runs otherwise
```

## The camera bench relay

Redlamp's Camera Bench (`packages/RedlampUI/Sources/CameraBench`, [docs/camera-bench.md](../docs/camera-bench.md)) posts each report to `POST /api/bench`. The relay checks it against `docs/camera-bench.schema.json`, whose objects are closed so nothing but measurements gets through, and keeps it in a private repository as one file per submission (`submissions/<yyyy>/<mm>/<id>.json`, with the day it arrived and the app's version; no IP address or other request detail). A request with `X-Redlamp-Dry-Run: 1`, as Debug builds send, is checked and nothing is kept. `GET /api/bench/summary` serves what each camera mode still needs, cut down from `docs/camera-bench.json`, which `scripts/camera-bench.py` writes; the app downloads the whole list, so the site never learns which cameras someone has. The logic is in `lib/bench.ts`, tested by `lib/bench.test.ts`.

It uses the Redlamp Feedback app's `FEEDBACK_GITHUB_*` settings, and these:

| Variable | Value |
| --- | --- |
| `BENCH_ENABLED` | `1` to keep reports; anything else switches it off (it answers 503, and dry runs still work) |
| `BENCH_REPO` | `pdcgomes/redlamp-bench`, a private repository the app is installed on with Contents (read and write) |
| `BENCH_PREFIX` | Optional: a folder for every path; Preview deployments use `preview/` unless it's set |

To try it locally with a Debug build:

```bash
BENCH_ENABLED=1 BENCH_REPO=pdcgomes/redlamp-bench … npx next dev --port 3123
defaults write app.redlamp.mac CameraBenchEndpoint http://localhost:3123/api/bench
defaults write app.redlamp.mac CameraBenchSendsLive -bool YES   # Debug builds send dry runs otherwise
```
