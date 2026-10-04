import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageResponse } from "next/og";
import { statusCounts, statuses } from "@/lib/comparison";
import { comparison } from "@/lib/repo";

export const alt = "Redlamp and Lightroom, feature by feature: what's done, in progress, planned and left out";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const barColour: Record<(typeof statuses)[number], string> = {
  Done: "#d9d0cb",
  "In progress": "rgba(255,176,138,0.85)",
  Planned: "rgba(217,208,203,0.32)",
  Later: "rgba(243,238,232,0.13)",
  Undecided: "rgba(243,238,232,0.09)",
  "Out of scope": "rgba(243,238,232,0.07)",
};

export default async function OpenGraphImage() {
  const icon = await readFile(path.join(process.cwd(), "public", "synced", "brand/images/app-icon.png"));
  const counts = statusCounts(comparison().groups);
  const total = Object.values(counts).reduce((sum, count) => sum + count, 0);
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
            <div style={{ display: "flex", fontSize: 56, fontWeight: 600, letterSpacing: -1.2 }}>Redlamp and Lightroom</div>
            <div style={{ display: "flex", fontSize: 30, color: "rgba(243,238,232,0.62)" }}>feature by feature</div>
          </div>
        </div>
        <div style={{ display: "flex", height: 22, borderRadius: 11, overflow: "hidden", background: "rgba(243,238,232,0.06)" }}>
          {statuses.map((status) => (
            <div key={status} style={{ display: "flex", width: `${(counts[status] / total) * 100}%`, background: barColour[status] }} />
          ))}
        </div>
        <div style={{ display: "flex", gap: 34, fontSize: 26 }}>
          {statuses.map((status) => (
            <div key={status} style={{ display: "flex", gap: 12 }}>
              <span style={{ color: "rgba(243,238,232,0.6)" }}>{status}</span>
              <span style={{ fontWeight: 600 }}>{counts[status]}</span>
            </div>
          ))}
        </div>
        <div style={{ display: "flex", fontSize: 24, color: "rgba(243,238,232,0.45)" }}>redlamp.app/compare</div>
      </div>
    ),
    size,
  );
}
