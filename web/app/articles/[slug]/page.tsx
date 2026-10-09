import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { figures } from "@/components/articles/figures";
import { articles, findArticle } from "@/lib/articles";
import { author, formatDate, renderMarkdown, splitFigures } from "@/lib/blog";
import { site } from "@/lib/site";

type Props = { params: Promise<{ slug: string }> };

// Every article is rendered when the site builds; any other slug is a 404.
export const dynamicParams = false;

export function generateStaticParams() {
  return articles().map((article) => ({ slug: article.slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const article = findArticle((await params).slug);
  if (!article) return {};
  const url = `/articles/${article.slug}`;
  return {
    title: article.title,
    description: article.summary,
    authors: [{ name: author }],
    alternates: { canonical: url },
    openGraph: {
      type: "article",
      siteName: site.name,
      title: article.title,
      description: article.summary,
      url,
      publishedTime: article.date,
      authors: [author],
      locale: "en_GB",
    },
    twitter: { card: "summary_large_image", title: article.title, description: article.summary },
  };
}

export default async function ArticlePage({ params }: Props) {
  const article = findArticle((await params).slug);
  if (!article) notFound();
  const own = figures[article.slug] ?? {};
  const parts = splitFigures(renderMarkdown(article.slug, article.body, article.files, "articles"));
  return (
    <article className="px-6 pt-14 pb-24">
      <header className="mx-auto max-w-2xl">
        <a href="/articles" className="eyebrow transition-colors hover:text-paper">
          Articles
        </a>
        <h1 className="font-display mt-4 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">{article.title}</h1>
        <p className="mt-5 text-[19px] leading-relaxed text-mute">{article.summary}</p>
        <p className="mt-6 text-[14px] text-dim">
          <time dateTime={article.date}>{formatDate(article.date)}</time> · {author}
        </p>
      </header>
      {article.cover ? (
        <figure className="mx-auto mt-12 max-w-5xl">
          {/* Articles' images have no known size, so they're plain images rather than next/image. */}
          <img src={article.cover} alt={article.coverAlt ?? ""} className="shot w-full rounded-2xl border border-hairline" />
        </figure>
      ) : null}
      <div className="mt-12">
        {parts.map((part, index) => {
          if ("html" in part) return <div key={index} className="post" dangerouslySetInnerHTML={{ __html: part.html }} />;
          const Figure = own[part.figure];
          if (!Figure) {
            throw new Error(`Article "${article.slug}" places a figure, "${part.figure}", that components/articles/figures.ts doesn't list for it`);
          }
          return (
            <div key={index} className="mx-auto my-12 max-w-5xl">
              <Figure />
            </div>
          );
        })}
      </div>
      <footer className="mx-auto mt-16 flex max-w-2xl flex-wrap items-center justify-between gap-4 border-t border-hairline pt-6 text-[14px]">
        <a href="/articles" className="text-mute transition-colors hover:text-paper">
          ← All articles
        </a>
        <a href="/blog" className="text-mute transition-colors hover:text-paper">
          The blog
        </a>
      </footer>
    </article>
  );
}
