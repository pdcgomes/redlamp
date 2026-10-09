import type { MetadataRoute } from "next";
import { articles } from "@/lib/articles";
import { posts } from "@/lib/blog";
import { site } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const all = posts();
  const technical = articles();
  return [
    { url: site.origin, changeFrequency: "weekly", priority: 1 },
    { url: `${site.origin}/compare`, changeFrequency: "weekly", priority: 0.8 },
    { url: `${site.origin}/cameras`, changeFrequency: "weekly", priority: 0.8 },
    { url: `${site.origin}/cameras/test`, changeFrequency: "monthly", priority: 0.7 },
    { url: `${site.origin}/performance`, changeFrequency: "weekly", priority: 0.8 },
    { url: `${site.origin}/blog`, lastModified: all[0]?.date, changeFrequency: "weekly", priority: 0.7 },
    ...all.map((post) => ({ url: `${site.origin}/blog/${post.slug}`, lastModified: post.date, priority: 0.6 })),
    { url: `${site.origin}/articles`, lastModified: technical[0]?.date, changeFrequency: "weekly", priority: 0.7 },
    ...technical.map((article) => ({ url: `${site.origin}/articles/${article.slug}`, lastModified: article.date, priority: 0.6 })),
  ];
}
