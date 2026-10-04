# redlamp.app

The project's website: Next.js (App Router), React and Tailwind CSS, with marked for the blog's Markdown, Vercel Web Analytics for page views, and no other runtime dependencies.

```bash
mise run site            # dev server on http://localhost:3000
mise run site -- build   # production build
```

## Where the content comes from

- **Roadmap and "Everything that works today"** are read from the repository's `README.md` at build time (`lib/readme.ts`), so the site follows the README. Each roadmap item's state and each phase's tracked-work counts come from the tracker rows the item names in `docs/research/research-tracker.md` (`lib/tracker.ts`).
- **The Compare page** (`/compare`) is read from `docs/lightroom-comparison.md` (`lib/comparison.ts`). Each tracker ID links to its GitHub issue, looked up hourly (`trackerIssues` in `lib/github.ts`); a `GITHUB_TOKEN` in the deployment's environment lifts GitHub's limit for anonymous requests, and without an answer from GitHub the links search for the ID instead. `scripts/roadmap-sync.py` keeps the comparison and the roadmap in step with the tracker.
- **The Cameras page** (`/cameras`) is read from `docs/cameras.md` (`lib/cameras.ts`), whose camera lists `scripts/camera-list.py` generates from the decode tests, the CC0 sample downloads and LibRaw's own camera list.
- **Screenshots, film icons, sample sheets and logos** are copied from `docs/` into `public/synced` by `scripts/sync-assets.mjs`, which runs before every `dev` and `build`. Regenerate them with `mise run screenshots` and `redlamp recipe film --all --install --readme`.
- **The download button** links to the latest GitHub release's zip, and the status pill at the top shows that release's version (`lib/github.ts`, refreshed hourly). The button stays hidden until the first release.
- **Features, film descriptions and principles** are curated in `content/`.
- **The explainer video** appears once `public/video/redlamp-explainer.mp4` and its poster exist; render them from `video/`.
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
