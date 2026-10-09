import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageResponse } from "next/og";

/** A blog post's or article's share card: the lockup, its title, and a line with its date and where it lives. */
export async function postImage(title: string, line: string): Promise<ImageResponse> {
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
        <div style={{ display: "flex", fontSize: 68, lineHeight: 1.1, color: "#f3eee8", maxWidth: 1000 }}>{title}</div>
        <div style={{ display: "flex", fontSize: 26, color: "rgba(243,238,232,0.55)" }}>{line}</div>
      </div>
    ),
    { width: 1200, height: 630 },
  );
}
