import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { author, findPost, formatDate, posts, renderMarkdown } from "@/lib/blog";
import { site } from "@/lib/site";

type Props = { params: Promise<{ slug: string }> };

// Every post is rendered when the site builds; any other slug is a 404.
export const dynamicParams = false;

export function generateStaticParams() {
  return posts().map((post) => ({ slug: post.slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const post = findPost((await params).slug);
  if (!post) return {};
  const url = `/blog/${post.slug}`;
  return {
    title: post.title,
    description: post.summary,
    authors: [{ name: author }],
    alternates: { canonical: url, types: { "application/rss+xml": "/blog/feed.xml" } },
    openGraph: {
      type: "article",
      siteName: site.name,
      title: post.title,
      description: post.summary,
      url,
      publishedTime: post.date,
      authors: [author],
      locale: "en_GB",
    },
    twitter: { card: "summary_large_image", title: post.title, description: post.summary },
  };
}

export default async function PostPage({ params }: Props) {
  const post = findPost((await params).slug);
  if (!post) notFound();
  return (
    <article className="px-6 pt-14 pb-24">
      <header className="mx-auto max-w-2xl">
        <a href="/blog" className="eyebrow transition-colors hover:text-paper">
          Blog
        </a>
        <h1 className="font-display mt-4 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">{post.title}</h1>
        <p className="mt-5 text-[19px] leading-relaxed text-mute">{post.summary}</p>
        <p className="mt-6 text-[14px] text-dim">
          <time dateTime={post.date}>{formatDate(post.date)}</time> · {author}
        </p>
      </header>
      {post.cover ? (
        <figure className="mx-auto mt-12 max-w-5xl">
          {/* Posts' images have no known size, so they're plain images rather than next/image. */}
          <img
            src={post.cover}
            alt={post.coverAlt ?? ""}
            className={`shot w-full rounded-2xl border border-hairline${post.pixelArt ? " [image-rendering:pixelated]" : ""}`}
          />
        </figure>
      ) : null}
      <div
        className={post.pixelArt ? "post post-pixel mt-12" : "post mt-12"}
        dangerouslySetInnerHTML={{ __html: renderMarkdown(post.slug, post.body, post.files) }}
      />
      <footer className="mx-auto mt-16 flex max-w-2xl flex-wrap items-center justify-between gap-4 border-t border-hairline pt-6 text-[14px]">
        <a href="/blog" className="text-mute transition-colors hover:text-paper">
          ← All posts
        </a>
        <a href="/blog/feed.xml" className="text-mute transition-colors hover:text-paper">
          RSS feed
        </a>
      </footer>
    </article>
  );
}
