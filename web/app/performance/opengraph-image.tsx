import { readFile } from "node:fs/promises";
import path from "node:path";
import { ImageResponse } from "next/og";
import { formatEntry, histories } from "@/lib/performance";
import { performance } from "@/lib/repo";

export const alt = "How fast Redlamp is, measured: opening, rendering and exporting raw files on an Apple M1 Ultra";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const SHOWN = ["render-fit", "render-full", "export-full", "open"];

export default async function OpenGraphImage() {
  const icon = await readFile(path.join(process.cwd(), "public", "synced", "brand/images/app-icon.png"));
  const { metrics, records } = performance();
  const byId = new Map(histories(metrics, records).map((history) => [history.metric.id, history]));
  const shown = SHOWN.map((id) => byId.get(id)).filter((history) => history !== undefined);
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          gap: 44,
          padding: "0 96px",
          background:
            "radial-gradient(70% 80% at 20% 30%, rgba(224,64,46,0.28), rgba(224,64,46,0.05) 55%, rgba(10,7,7,0) 80%), #0a0707",
          color: "#f3eee8",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 28 }}>
          <img src={`data:image/png;base64,${icon.toString("base64")}`} width={120} height={120} alt="" />
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <div style={{ display: "flex", fontSize: 56, fontWeight: 600, letterSpacing: -1.2 }}>Redlamp, measured</div>
            <div style={{ display: "flex", fontSize: 30, color: "rgba(243,238,232,0.62)" }}>on an Apple M1 Ultra</div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 56 }}>
          {shown.map((history) => (
            <div key={history.metric.id} style={{ display: "flex", flexDirection: "column", gap: 10, maxWidth: 230 }}>
              <div style={{ display: "flex", fontSize: 46, fontWeight: 600 }}>{formatEntry(history.current.entry, history.metric.unit)}</div>
              <div style={{ display: "flex", fontSize: 22, color: "rgba(243,238,232,0.6)" }}>{history.metric.label}</div>
            </div>
          ))}
        </div>
        <div style={{ display: "flex", fontSize: 24, color: "rgba(243,238,232,0.45)" }}>redlamp.app/performance</div>
      </div>
    ),
    size,
  );
}
