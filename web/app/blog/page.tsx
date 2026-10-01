import type { Metadata } from "next";
import { formatDate, posts } from "@/lib/blog";
import { site } from "@/lib/site";

const description = "Notes on building Redlamp, a native, open-source RAW photo editor for the Mac.";

export const metadata: Metadata = {
  title: "Blog",
  description,
  alternates: { canonical: "/blog", types: { "application/rss+xml": "/blog/feed.xml" } },
  openGraph: { type: "website", siteName: site.name, title: `Blog · ${site.name}`, description, url: "/blog", locale: "en_GB" },
  twitter: { card: "summary_large_image", title: `Blog · ${site.name}`, description },
};

export default function BlogPage() {
  const all = posts();
  return (
    <section className="px-6 pt-16 pb-24">
      <div className="mx-auto max-w-3xl">
        <p className="eyebrow">Blog</p>
        <h1 className="font-display mt-3 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">
          Notes from the darkroom
        </h1>
        <p className="mt-5 text-[17px] leading-relaxed text-mute">
          How Redlamp is built, what&apos;s new, and what&apos;s next.{" "}
          <a className="underline decoration-hairline-strong underline-offset-3 hover:decoration-paper" href="/blog/feed.xml">
            RSS feed
          </a>
          .
        </p>
        {all.length === 0 ? (
          <p className="mt-14 text-[15px] text-dim">The first post is on its way.</p>
        ) : (
          <ol className="mt-14 border-t border-hairline">
            {all.map((post) => (
              <li key={post.slug} className="border-b border-hairline">
                <a href={`/blog/${post.slug}`} className="group block py-8">
                  <time dateTime={post.date} className="text-[13px] text-dim">
                    {formatDate(post.date)}
                  </time>
                  <h2 className="font-display mt-2 text-[clamp(1.4rem,2.6vw,1.75rem)] leading-tight text-paper transition-colors group-hover:text-filament">
                    {post.title}
                  </h2>
                  <p className="mt-2 text-[16px] leading-relaxed text-mute">{post.summary}</p>
                </a>
              </li>
            ))}
          </ol>
        )}
      </div>
    </section>
  );
}
