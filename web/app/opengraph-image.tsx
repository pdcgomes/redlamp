import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageResponse } from "next/og";
import { site } from "@/lib/site";

export const alt = "Redlamp: a native, open-source RAW photo editor for the Mac";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

async function dataUri(file: string, mime: string) {
  const bytes = await readFile(path.join(process.cwd(), "public", "synced", file));
  return `data:${mime};base64,${bytes.toString("base64")}`;
}

export default async function OpenGraphImage() {
  const [icon, lockup] = await Promise.all([
    dataUri("brand/images/app-icon.png", "image/png"),
    dataUri("brand/logo/redlamp-lockup.svg", "image/svg+xml"),
  ]);
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          gap: 56,
          padding: "0 96px",
          background:
            "radial-gradient(70% 80% at 30% 50%, rgba(224,64,46,0.32), rgba(224,64,46,0.06) 55%, rgba(10,7,7,0) 80%), #0a0707",
        }}
      >
        <img src={icon} width={300} height={300} alt="" />
        <div style={{ display: "flex", flexDirection: "column", gap: 28 }}>
          <img src={lockup} width={480} height={120} alt="" />
          <div style={{ display: "flex", fontSize: 34, lineHeight: 1.3, color: "rgba(243,238,232,0.78)", maxWidth: 640 }}>
            {site.tagline}
          </div>
          <div style={{ display: "flex", fontSize: 24, color: "rgba(243,238,232,0.5)" }}>
            Open source · MPL-2.0 · redlamp.app
          </div>
        </div>
      </div>
    ),
    size,
  );
}
