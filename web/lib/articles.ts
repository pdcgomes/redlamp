/**
 * Technical articles: longer pieces on how Redlamp works, often with interactive figures. One Markdown
 * file each, `content/articles/<slug>/index.md`, with the blog's front matter and Markdown rules
 * (`lib/blog.ts`). Relative imports only, so `node --test` can load it.
 */

import path from "node:path";
import { readPosts, type Post } from "./blog.ts";

export type Article = Post;

/** The site's articles, newest first; drafts only in development. */
export function articles(): Article[] {
  return readPosts(path.join(process.cwd(), "content", "articles"), {
    drafts: process.env.NODE_ENV !== "production",
    section: "articles",
  });
}

export function findArticle(slug: string): Article | undefined {
  return articles().find((article) => article.slug === slug);
}
