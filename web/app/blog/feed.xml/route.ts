import { author, posts } from "@/lib/blog";
import { site } from "@/lib/site";

export const dynamic = "force-static";

export function GET() {
  const blog = `${site.origin}/blog`;
  const items = posts().map((post) => {
    const url = `${blog}/${post.slug}`;
    return [
      "<item>",
      `<title>${xml(post.title)}</title>`,
      `<link>${url}</link>`,
      `<guid isPermaLink="true">${url}</guid>`,
      `<pubDate>${new Date(`${post.date}T00:00:00Z`).toUTCString()}</pubDate>`,
      `<dc:creator>${xml(author)}</dc:creator>`,
      `<description>${xml(post.summary)}</description>`,
      "</item>",
    ].join("");
  });
  const feed = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/">',
    "<channel>",
    `<title>${site.name} blog</title>`,
    `<link>${blog}</link>`,
    `<atom:link href="${blog}/feed.xml" rel="self" type="application/rss+xml"/>`,
    "<description>Notes on building Redlamp, a native, open-source RAW photo editor for the Mac.</description>",
    "<language>en-gb</language>",
    ...items,
    "</channel>",
    "</rss>",
  ].join("\n");
  return new Response(feed, { headers: { "Content-Type": "application/rss+xml; charset=utf-8" } });
}

function xml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
