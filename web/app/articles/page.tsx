import type { Metadata } from "next";
import { articles } from "@/lib/articles";
import { formatDate } from "@/lib/blog";
import { site } from "@/lib/site";

const description = "Technical articles on how Redlamp works and the ideas behind it, with figures you can try.";

export const metadata: Metadata = {
  title: "Articles",
  description,
  alternates: { canonical: "/articles" },
  openGraph: { type: "website", siteName: site.name, title: `Articles · ${site.name}`, description, url: "/articles", locale: "en_GB" },
  twitter: { card: "summary_large_image", title: `Articles · ${site.name}`, description },
};

export default function ArticlesPage() {
  const all = articles();
  return (
    <section className="px-6 pt-16 pb-24">
      <div className="mx-auto max-w-3xl">
        <p className="eyebrow">Articles</p>
        <h1 className="font-display mt-3 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">Technical articles</h1>
        <p className="mt-5 text-[17px] leading-relaxed text-mute">
          How Redlamp works and the ideas behind it, explained at length, with figures you can try. News and notes on building it are on the{" "}
          <a className="text-paper underline decoration-hairline-strong underline-offset-3 hover:decoration-paper" href="/blog">
            blog
          </a>
          .
        </p>
        {all.length === 0 ? (
          <p className="mt-14 text-[15px] text-dim">The first article is on its way.</p>
        ) : (
          <ol className="mt-14 border-t border-hairline">
            {all.map((article) => (
              <li key={article.slug} className="border-b border-hairline">
                <a href={`/articles/${article.slug}`} className="group block py-8">
                  <time dateTime={article.date} className="text-[13px] text-dim">
                    {formatDate(article.date)}
                  </time>
                  <h2 className="font-display mt-2 text-[clamp(1.4rem,2.6vw,1.75rem)] leading-tight text-paper transition-colors group-hover:text-filament">
                    {article.title}
                  </h2>
                  <p className="mt-2 text-[16px] leading-relaxed text-mute">{article.summary}</p>
                </a>
              </li>
            ))}
          </ol>
        )}
      </div>
    </section>
  );
}
