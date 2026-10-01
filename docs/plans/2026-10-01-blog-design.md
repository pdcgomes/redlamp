# Blog on redlamp.app: design

The owner's goal: a blog on the website, starting with an introduction post that asks people to try Redlamp and file feedback as GitHub issues, followed by posts about how it's built. No blog engine: posts are Markdown files that become pages when the site builds.

## Decisions

- **Markdown files, converted at build time.** Each post is `web/content/blog/<slug>/index.md`, with its images beside it. `next build` on Vercel renders every post into a static page; in development an edited file shows on the next refresh.
- **marked for the Markdown.** It has no dependencies of its own. MDX would allow components inside posts, but it is stricter to write by hand (a stray `{` or `<` breaks the build) and adds three build packages. Raw HTML in a post covers embeds such as the video.
- **No list to keep in step.** The index, the RSS feed, the sitemap and each post's metadata and share card all read the posts' front matter.
- **Byline:** Pedro.

## Posts

```markdown
---
title: Why I'm building Redlamp
summary: One line for the index, the feed and link previews.
date: 2026-10-01
cover: hero.png            # optional, shown wide above the text
coverAlt: Redlamp editing a street photo
draft: true                # optional: shown in development, left out of production builds
---
```

- A missing or malformed title, summary or date fails the build with the post's name.
- An image on its own line becomes a figure, wider than the text, with its title as the caption: `![alt](masks.png "Caption")`. Relative paths resolve to the post's folder, which `scripts/sync-assets.mjs` copies into `public/synced/blog/<slug>/`; absolute paths such as `/synced/images/hero.png` are left alone.
- Headings get ids from their text, so sections can be linked.
- Raw HTML passes through. Posts are written by the project, so nothing is sanitised.

## Routes and site changes

- `/blog` lists posts newest first: date, title and summary.
- `/blog/<slug>` shows the date and byline, the title, the summary, the cover, and the post in a reading column with the site's text styles.
- Each post's share card shows its title on the brand's dark, like the home page's card.
- `/blog/feed.xml` is an RSS feed, linked from the blog's pages and the footer.
- The sitemap lists the blog and its posts.
- The header gains a Blog link, and its links become `/#features` and so on, so they work from any page. The home page's canonical URL moves off the shared layout, so posts get their own.
- The header refreshes GitHub's star count hourly, so Vercel re-renders pages after deployment. `next.config.ts` includes the post files in the server's bundle for that.

## The first post

"Why I'm building Redlamp", about 700 words in the owner's voice: why, what it is, what works today (masks and Film Looks screenshots), what it isn't yet, how to try it, how to help (GitHub issues with the camera model, macOS version and a sample file), what's next, and the explainer video at the end. No Ko-fi ask, no AI recipe tools and no performance numbers, which get their own post.

## Testing

`lib/blog.ts` (front matter, Markdown rules, reading and sorting posts, drafts) is covered by `node --test`, which runs TypeScript directly. Pages are checked with a production build.

## Not now

Tags, pagination, comments, syntax highlighting, and a "latest post" teaser on the home page.
