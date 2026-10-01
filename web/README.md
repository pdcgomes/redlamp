# redlamp.app

The project's website: Next.js (App Router), React and Tailwind CSS, with marked for the blog's Markdown and no other runtime dependencies.

```bash
mise run site            # dev server on http://localhost:3000
mise run site -- build   # production build
```

## Where the content comes from

- **Roadmap and "Everything that works today"** are read from the repository's `README.md` at build time (`lib/readme.ts`), so the site follows the README.
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
