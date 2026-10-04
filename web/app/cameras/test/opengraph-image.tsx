import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageResponse } from "next/og";
import { cameras } from "@/lib/repo";

export const alt = "Test your camera with Redlamp: the camera bench checks your raw files on your Mac and sends only the measurements";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function OpenGraphImage() {
  const icon = await readFile(path.join(process.cwd(), "public", "synced", "brand/images/app-icon.png"));
  const { verified, bench, makes } = cameras();
  const stats = [
    { value: new Set(verified.map((camera) => camera.camera)).size, label: "verified" },
    { value: bench.length, label: "camera modes tested" },
    { value: makes.reduce((sum, make) => sum + make.models.length, 0).toLocaleString("en-GB"), label: "read by LibRaw" },
  ];
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          gap: 40,
          padding: "0 96px",
          background:
            "radial-gradient(70% 80% at 20% 30%, rgba(224,64,46,0.28), rgba(224,64,46,0.05) 55%, rgba(10,7,7,0) 80%), #0a0707",
          color: "#f3eee8",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 28 }}>
          <img src={`data:image/png;base64,${icon.toString("base64")}`} width={120} height={120} alt="" />
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <div style={{ display: "flex", fontSize: 56, fontWeight: 600, letterSpacing: -1.2 }}>Test your camera</div>
            <div style={{ display: "flex", fontSize: 30, color: "rgba(243,238,232,0.62)" }}>
              your photos stay on your Mac; only measurements are sent
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 48, fontSize: 26 }}>
          {stats.map((stat) => (
            <div key={stat.label} style={{ display: "flex", gap: 12 }}>
              <span style={{ fontWeight: 600 }}>{stat.value}</span>
              <span style={{ color: "rgba(243,238,232,0.6)" }}>{stat.label}</span>
            </div>
          ))}
        </div>
        <div style={{ display: "flex", fontSize: 24, color: "rgba(243,238,232,0.45)" }}>redlamp.app/cameras/test</div>
      </div>
    ),
    size,
  );
}
