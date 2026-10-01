import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { noise2D } from "@remotion/noise";
import { Caption } from "../components/Caption";
import { Photo } from "../components/Media";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, font } from "../theme";

const COLS = 30;
const ROWS = 20;
const stages = ["Raw data", "Demosaic", "One fused kernel", "Screen"];

/** The sensor's Bayer mosaic resolves into a photo on the GPU, inside a sliver of the 16 ms frame budget. */
export function Speed({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const layout = useLayout();
  const photoW = layout.wide ? 820 : 900;
  const photoH = photoW * (layout.tall ? 1.1 : 0.667);
  const cellW = photoW / COLS;
  const cellH = photoH / ROWS;
  const sweep = interpolate(frame, [40, 110], [-0.15, 1.15], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const active = Math.min(stages.length - 1, Math.floor(interpolate(frame, [20, 140], [0, stages.length], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })));
  const ms = 0.6 + 2.4 * (0.5 + 0.5 * noise2D("ms", frame / 6, 0));
  const meterIn = appear(frame, 96, 26);

  const cells = [];
  for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      const tint = r % 2 === 0 ? (c % 2 === 0 ? "#ff2a1a" : "#22c94a") : c % 2 === 0 ? "#22c94a" : "#2a6bff";
      const local = interpolate(sweep, [c / COLS - 0.12, c / COLS + 0.04], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
      cells.push(
        <rect key={`${r}-${c}`} x={c * cellW} y={r * cellH} width={cellW - 1} height={cellH - 1} fill={tint} opacity={0.78 * local} />,
      );
    }
  }

  const photo = (
    <div style={{ position: "relative", width: photoW, height: photoH, borderRadius: 14, overflow: "hidden", boxShadow: "0 30px 70px rgba(0,0,0,0.6)" }}>
      <Photo style={{ filter: `grayscale(${interpolate(sweep, [0, 1], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })})` }} />
      <svg width={photoW} height={photoH} style={{ position: "absolute", inset: 0, mixBlendMode: "multiply" }}>
        {cells}
      </svg>
    </div>
  );

  const meter = (
    <div style={{ fontFamily: font.family, width: layout.wide ? 600 : 900, opacity: meterIn, transform: `translateY(${(1 - meterIn) * 16}px)` }}>
      <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 34, justifyContent: layout.wide ? "flex-start" : "center" }}>
        {stages.map((stage, i) => (
          <span
            key={stage}
            style={{
              fontSize: 19,
              padding: "8px 14px",
              borderRadius: 999,
              border: `1px solid ${i <= active ? "rgba(243,238,232,0.4)" : color.hairline}`,
              color: i <= active ? color.paper : color.dim,
              background: i === active ? "rgba(243,238,232,0.08)" : "transparent",
            }}
          >
            {stage}
          </span>
        ))}
      </div>
      <div style={{ ...font.display, fontSize: 110, lineHeight: 1, color: color.paper, fontVariantNumeric: "tabular-nums" }}>
        {ms.toFixed(1)}
        <span style={{ fontSize: 46, color: color.mute, marginLeft: 12 }}>ms</span>
      </div>
      <div style={{ marginTop: 28, height: 10, borderRadius: 5, background: "rgba(243,238,232,0.1)", position: "relative" }}>
        <div style={{ width: `${(ms / 16) * 100}%`, height: "100%", borderRadius: 5, background: color.ring }} />
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 12, fontSize: 18, color: color.dim }}>
        <span>Render at Fit</span>
        <span>One frame: 16 ms</span>
      </div>
    </div>
  );

  return (
    <Stage glowX={0.5} glowY={0.1}>
      <AbsoluteFill
        style={{
          flexDirection: layout.wide ? "row" : "column",
          alignItems: "center",
          justifyContent: "center",
          gap: layout.wide ? 90 : 60,
          padding: layout.wide ? "120px 110px 0" : "140px 60px 80px",
        }}
      >
        {layout.wide ? null : (
          <Caption title="Every change, within a frame." sub="One fused Metal kernel on Apple Silicon." start={6} end={dur - 16} align="center" size={64} />
        )}
        {photo}
        <div style={{ display: "flex", flexDirection: "column", gap: 50 }}>
          {layout.wide ? (
            <Caption title="Every change, within a frame." sub="One fused Metal kernel on Apple Silicon." start={6} end={dur - 16} size={60} />
          ) : null}
          {meter}
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
