import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageResponse } from "next/og";
import { findPost, formatDate, posts } from "@/lib/blog";

export const alt = "A post on Redlamp's blog";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export function generateStaticParams() {
  return posts().map((post) => ({ slug: post.slug }));
}

export default async function PostImage({ params }: { params: Promise<{ slug: string }> }) {
  const post = findPost((await params).slug);
  const lockup = await readFile(path.join(process.cwd(), "public", "synced", "brand", "logo", "redlamp-lockup.svg"));
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "80px 96px",
          background:
            "radial-gradient(80% 90% at 50% 0%, rgba(224,64,46,0.3), rgba(224,64,46,0.06) 55%, rgba(10,7,7,0) 80%), #0a0707",
        }}
      >
        <img src={`data:image/svg+xml;base64,${lockup.toString("base64")}`} width={240} height={60} alt="" />
        <div style={{ display: "flex", fontSize: 68, lineHeight: 1.1, color: "#f3eee8", maxWidth: 1000 }}>
          {post?.title ?? "Redlamp blog"}
        </div>
        <div style={{ display: "flex", fontSize: 26, color: "rgba(243,238,232,0.55)" }}>
          {post ? `${formatDate(post.date)} · redlamp.app/blog` : "redlamp.app/blog"}
        </div>
      </div>
    ),
    size,
  );
}
