import { postImage } from "@/components/og/post-image";
import { findPost, formatDate, posts } from "@/lib/blog";

export const alt = "A post on Redlamp's blog";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export function generateStaticParams() {
  return posts().map((post) => ({ slug: post.slug }));
}

export default async function PostImage({ params }: { params: Promise<{ slug: string }> }) {
  const post = findPost((await params).slug);
  return postImage(post?.title ?? "Redlamp blog", post ? `${formatDate(post.date)} · redlamp.app/blog` : "redlamp.app/blog");
}
