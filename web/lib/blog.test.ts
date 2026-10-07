import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { formatDate, parsePost, readPosts, renderMarkdown } from "./blog.ts";

const source = `---
title: Why I'm building Redlamp
summary: Redlamp: a raw editor for the Mac.
date: 2026-10-01
---

Hello.
`;

test("parsePost reads the front matter and keeps the body", () => {
  const post = parsePost("intro", source);
  assert.equal(post.slug, "intro");
  assert.equal(post.title, "Why I'm building Redlamp");
  assert.equal(post.summary, "Redlamp: a raw editor for the Mac.");
  assert.equal(post.date, "2026-10-01");
  assert.equal(post.draft, false);
  assert.equal(post.body.trim(), "Hello.");
});

test("parsePost strips quotes around a value", () => {
  assert.equal(parsePost("intro", source.replace("title: Why I'm building Redlamp", 'title: "Quoted"')).title, "Quoted");
});

test("parsePost names the post and the field when one is missing", () => {
  assert.throws(() => parsePost("intro", source.replace(/^title: .*\n/m, "")), /intro.*title/);
});

test("parsePost rejects a date that isn't YYYY-MM-DD", () => {
  assert.throws(() => parsePost("intro", source.replace("2026-10-01", "1 October 2026")), /intro.*date/);
});

test("parsePost rejects a post without front matter", () => {
  assert.throws(() => parsePost("intro", "Hello."), /intro.*front matter/);
});

test("parsePost reads the optional cover and draft, resolving a relative cover to the post's folder", () => {
  const post = parsePost("intro", source.replace("date:", "cover: hero.png\ncoverAlt: The editor\ndraft: true\ndate:"));
  assert.equal(post.cover, "/synced/blog/intro/hero.png");
  assert.equal(post.coverAlt, "The editor");
  assert.equal(post.draft, true);
  assert.equal(parsePost("intro", source.replace("date:", "cover: /synced/images/hero.png\ndate:")).cover, "/synced/images/hero.png");
});

test("parsePost reads pixelArt, off unless the front matter says true", () => {
  assert.equal(parsePost("intro", source).pixelArt, false);
  assert.equal(parsePost("intro", source.replace("date:", "pixelArt: true\ndate:")).pixelArt, true);
});

test("renderMarkdown shows an animated GIF's poster to readers who ask for reduced motion", () => {
  const markdown = '![The layers](stack.gif "One frame")';
  const html = renderMarkdown("intro", markdown, ["index.md", "stack.gif", "stack-poster.png"]);
  assert.match(
    html,
    /^<figure><picture><source srcset="\/synced\/blog\/intro\/stack-poster\.png" media="\(prefers-reduced-motion: reduce\)"><img src="\/synced\/blog\/intro\/stack\.gif"/,
  );
  assert.match(html, /<\/picture><figcaption>One frame<\/figcaption><\/figure>/);
  assert.doesNotMatch(renderMarkdown("intro", markdown, ["index.md", "stack.gif"]), /<picture>/);
  assert.doesNotMatch(renderMarkdown("intro", "![A still](stack-poster.png)", ["stack-poster.png"]), /<picture>/);
});

test("renderMarkdown turns an image on its own line into a lazily loaded figure with its title as the caption", () => {
  const html = renderMarkdown("intro", '![The masks panel](masks.png "Masks, on your Mac")');
  assert.match(html, /^<figure><img src="\/synced\/blog\/intro\/masks\.png" alt="The masks panel" loading="lazy"/);
  assert.match(html, /<figcaption>Masks, on your Mac<\/figcaption><\/figure>/);
  assert.doesNotMatch(html, /<p>/);
});

test("renderMarkdown leaves a figure without a title uncaptioned and keeps absolute paths", () => {
  const html = renderMarkdown("intro", "![The editor](/synced/images/hero.png)");
  assert.match(html, /<figure><img src="\/synced\/images\/hero\.png" alt="The editor"/);
  assert.doesNotMatch(html, /figcaption/);
});

test("renderMarkdown keeps an image inside a sentence inline, with its path resolved", () => {
  const html = renderMarkdown("intro", "An icon ![lamp](lamp.png) in a line.");
  assert.match(html, /^<p>An icon <img src="\/synced\/blog\/intro\/lamp\.png" alt="lamp"/);
  assert.doesNotMatch(html, /<figure>/);
});

test("renderMarkdown escapes quotes in alt text", () => {
  assert.match(renderMarkdown("intro", '![A "quoted" alt](a.png)'), /alt="A &quot;quoted&quot; alt"/);
});

test("renderMarkdown gives headings an id from their text", () => {
  assert.match(renderMarkdown("intro", "## What's next"), /<h2 id="whats-next">What(&#39;|')s next<\/h2>/);
  assert.match(renderMarkdown("intro", "### The `redlamp` CLI"), /<h3 id="the-redlamp-cli">The <code>redlamp<\/code> CLI<\/h3>/);
});

test("renderMarkdown passes raw HTML through", () => {
  const video = '<video src="/video/redlamp-explainer.mp4" controls></video>';
  assert.match(renderMarkdown("intro", `Watch:\n\n${video}\n`), /<video src="\/video\/redlamp-explainer\.mp4" controls><\/video>/);
});

test("renderMarkdown escapes an ampersand in alt text and captions once", () => {
  const html = renderMarkdown("intro", '![Tom & Jerry](a.png "Before & after")');
  assert.match(html, /alt="Tom &amp; Jerry"/);
  assert.match(html, /<figcaption>Before &amp; after<\/figcaption>/);
});

test("parsePost rejects a folder name that can't be a URL", () => {
  assert.throws(() => parsePost("Why I'm here", source), /Why I'm here.*lowercase/);
});

function folder(posts: Record<string, string>): string {
  const dir = mkdtempSync(path.join(tmpdir(), "blog-"));
  for (const [slug, front] of Object.entries(posts)) {
    mkdirSync(path.join(dir, slug));
    writeFileSync(path.join(dir, slug, "index.md"), `---\n${front}\n---\n\nBody.\n`);
  }
  mkdirSync(path.join(dir, "no-post-here"));
  writeFileSync(path.join(dir, "notes.txt"), "not a post");
  return dir;
}

test("readPosts reads each folder's index.md, newest first", () => {
  const dir = folder({
    older: "title: Older\nsummary: First.\ndate: 2026-10-01",
    newer: "title: Newer\nsummary: Second.\ndate: 2026-11-05",
  });
  assert.deepEqual(readPosts(dir).map((post) => post.slug), ["newer", "older"]);
});

test("readPosts leaves drafts out unless asked for them", () => {
  const dir = folder({
    live: "title: Live\nsummary: Out.\ndate: 2026-10-01",
    wip: "title: Draft\nsummary: Not yet.\ndate: 2026-10-02\ndraft: true",
  });
  assert.deepEqual(readPosts(dir).map((post) => post.slug), ["live"]);
  assert.deepEqual(readPosts(dir, { drafts: true }).map((post) => post.slug), ["wip", "live"]);
});

test("readPosts lists the files beside each post's index.md", () => {
  const dir = folder({ live: "title: Live\nsummary: Out.\ndate: 2026-10-01" });
  writeFileSync(path.join(dir, "live", "stack.gif"), "");
  assert.deepEqual(readPosts(dir)[0].files.sort(), ["index.md", "stack.gif"]);
});

test("readPosts finds nothing in a folder that doesn't exist", () => {
  assert.deepEqual(readPosts(path.join(tmpdir(), "no-such-blog")), []);
});

test("formatDate writes the date as the site does", () => {
  assert.equal(formatDate("2026-10-01"), "1 October 2026");
});
