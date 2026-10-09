import { postImage } from "@/components/og/post-image";
import { articles, findArticle } from "@/lib/articles";
import { formatDate } from "@/lib/blog";

export const alt = "A technical article on redlamp.app";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export function generateStaticParams() {
  return articles().map((article) => ({ slug: article.slug }));
}

export default async function ArticleImage({ params }: { params: Promise<{ slug: string }> }) {
  const article = findArticle((await params).slug);
  return postImage(
    article?.title ?? "Redlamp articles",
    article ? `${formatDate(article.date)} · redlamp.app/articles` : "redlamp.app/articles",
  );
}
