/**
 * The blog: one Markdown file per post, `content/blog/<slug>/index.md`, with its images beside it,
 * rendered into static pages when the site builds. Articles (`lib/articles.ts`) are read and rendered
 * the same way from `content/articles/`. Relative imports only, so `node --test` can load it.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { Marked, type Tokens } from "marked";
import { readFrontMatter } from "./front-matter.ts";

/** Where a post lives: its folder under `content/`, and its images' under `public/synced/`. */
export type Section = "blog" | "articles";

const noun: Record<Section, string> = { blog: "Blog post", articles: "Article" };

export type Post = {
  slug: string;
  title: string;
  /** One line, for the index, the feed and link previews. */
  summary: string;
  /** YYYY-MM-DD. */
  date: string;
  cover?: string;
  coverAlt?: string;
  /** Its images are pixel art, scaled without smoothing so each pixel stays square. */
  pixelArt: boolean;
  /** Shown in development, left out of production builds. */
  draft: boolean;
  /** The files beside its index.md. */
  files: string[];
  /** The Markdown after the front matter. */
  body: string;
};

/** Where a post's own file is served from once `scripts/sync-assets.mjs` has copied it; absolute paths stay. */
export function assetPath(slug: string, src: string, section: Section = "blog"): string {
  return /^([a-z][a-z0-9+.-]*:|\/|#)/i.test(src) ? src : `/synced/${section}/${slug}/${src.replace(/^\.\//, "")}`;
}

/** Reads a post's front matter (`lib/front-matter.ts`); `files` are the ones beside its index.md. */
export function parsePost(slug: string, source: string, files: string[] = [], section: Section = "blog"): Post {
  const name = noun[section];
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
    throw new Error(`${name} folder "${slug}" is its URL, so name it in lowercase letters, digits and hyphens`);
  }
  const front = readFrontMatter(source);
  if (!front) throw new Error(`${name} "${slug}" has no front matter`);
  const { fields } = front;
  const required = (key: string) => {
    const value = fields.get(key);
    if (!value) throw new Error(`${name} "${slug}" needs a ${key} in its front matter`);
    return value;
  };
  const date = required("date");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    throw new Error(`${name} "${slug}" has a date that isn't YYYY-MM-DD: ${date}`);
  }
  const cover = fields.get("cover");
  return {
    slug,
    title: required("title"),
    summary: required("summary"),
    date,
    cover: cover ? assetPath(slug, cover, section) : undefined,
    coverAlt: fields.get("coverAlt"),
    pixelArt: fields.get("pixelArt") === "true",
    draft: fields.get("draft") === "true",
    files,
    body: front.body,
  };
}

/**
 * A post's HTML. An image on its own line becomes a figure, captioned with its title; image paths
 * resolve to the post's folder; an animated GIF with a NAME-poster.png among the post's `files`
 * shows the poster instead to readers who ask for reduced motion; headings get ids from their text;
 * raw HTML passes through, since posts are the project's own writing.
 */
export function renderMarkdown(slug: string, markdown: string, files: readonly string[] = [], section: Section = "blog"): string {
  const image = ({ href, title, text }: Tokens.Image, inFigure = false) => {
    const img =
      `<img src="${escape(assetPath(slug, href, section))}" alt="${escape(text)}" loading="lazy" decoding="async"` +
      `${title && !inFigure ? ` title="${escape(title)}"` : ""}>`;
    const gif = href.replace(/^\.\//, "").match(/^(.+)\.gif$/i);
    const poster = gif ? `${gif[1]}-poster.png` : undefined;
    return poster && files.includes(poster)
      ? `<picture><source srcset="${escape(assetPath(slug, poster, section))}" media="(prefers-reduced-motion: reduce)">${img}</picture>`
      : img;
  };
  const marked = new Marked({
    gfm: true,
    renderer: {
      heading({ tokens, depth, text }) {
        return `<h${depth} id="${headingId(text)}">${this.parser.parseInline(tokens)}</h${depth}>\n`;
      },
      image(token) {
        return image(token);
      },
      paragraph({ tokens }) {
        const [only] = tokens;
        if (tokens.length === 1 && only.type === "image") {
          const figure = only as Tokens.Image;
          const caption = figure.title ? `<figcaption>${escape(figure.title)}</figcaption>` : "";
          return `<figure>${image(figure, true)}${caption}</figure>\n`;
        }
        return `<p>${this.parser.parseInline(tokens)}</p>\n`;
      },
    },
  });
  return marked.parse(markdown, { async: false });
}

export type Part = { html: string } | { figure: string };

/**
 * A post's HTML cut at its figure lines, `<div data-figure="name"></div>` on a line of their own in
 * the Markdown, so the page can put an interactive figure in each one's place. HTML that is only
 * whitespace is dropped.
 */
export function splitFigures(html: string): Part[] {
  const parts: Part[] = [];
  let last = 0;
  for (const match of html.matchAll(/<div data-figure="([a-z0-9]+(?:-[a-z0-9]+)*)"><\/div>/g)) {
    const start = match.index ?? 0;
    const before = html.slice(last, start);
    if (before.trim()) parts.push({ html: before });
    parts.push({ figure: match[1] });
    last = start + match[0].length;
  }
  const rest = html.slice(last);
  if (rest.trim()) parts.push({ html: rest });
  return parts;
}

function headingId(text: string): string {
  return text
    .replace(/<[^>]*>|[`*_~]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .trim()
    .replace(/\s+/g, "-");
}

function escape(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Every post in `dir` (one folder each, holding an `index.md`), newest first. */
export function readPosts(dir: string, { drafts = false, section = "blog" }: { drafts?: boolean; section?: Section } = {}): Post[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(path.join(dir, entry.name, "index.md")))
    .map((entry) => {
      const folder = path.join(dir, entry.name);
      return parsePost(entry.name, readFileSync(path.join(folder, "index.md"), "utf8"), readdirSync(folder), section);
    })
    .filter((post) => drafts || !post.draft)
    .sort((a, b) => b.date.localeCompare(a.date) || a.slug.localeCompare(b.slug));
}

export const author = "Pedro";

/** The site's posts, newest first; drafts only in development. */
export function posts(): Post[] {
  return readPosts(path.join(process.cwd(), "content", "blog"), { drafts: process.env.NODE_ENV !== "production" });
}

export function findPost(slug: string): Post | undefined {
  return posts().find((post) => post.slug === slug);
}

/** "1 October 2026". */
export function formatDate(date: string): string {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
}
