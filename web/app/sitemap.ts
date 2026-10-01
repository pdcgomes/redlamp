import type { MetadataRoute } from "next";
import { posts } from "@/lib/blog";
import { site } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const all = posts();
  return [
    { url: site.origin, changeFrequency: "weekly", priority: 1 },
    { url: `${site.origin}/blog`, lastModified: all[0]?.date, changeFrequency: "weekly", priority: 0.7 },
    ...all.map((post) => ({ url: `${site.origin}/blog/${post.slug}`, lastModified: post.date, priority: 0.6 })),
  ];
}
