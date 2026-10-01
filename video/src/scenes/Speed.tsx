import { AbsoluteFill } from "remotion";
import { Words } from "../components/Kinetic";
import { Stage } from "../components/Stage";
import { Chip } from "../components/UI";
import { useLayout, useSprings } from "../layout";
import { color, font } from "../theme";

/** The 16 ms frame budget draws across the screen; Redlamp's render pops into a sliver of it. */
export function Speed() {
  const s = useSprings();
  const layout = useLayout();
  const barW = layout.wide ? 1300 : 900;
  const bar = s(12, "snap");
  const chunk = s(26, "pop");
  const label = s(30, "pop");
  const text = layout.wide ? 22 : 26;
  return (
    <Stage glowY={0.3} pulses={[26]}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: layout.wide ? 90 : 110, fontFamily: font.family }}>
        <Words text={"Every change lands\nwithin a frame."} size={layout.wide ? 120 : layout.tall ? 108 : 92} stagger={2} />
        <div style={{ width: barW }}>
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: text, color: color.mute, marginBottom: 16, opacity: bar }}>
            <span>One frame on screen</span>
            <span style={{ fontVariantNumeric: "tabular-nums" }}>16 ms</span>
          </div>
          <div style={{ position: "relative", height: 36, borderRadius: 18, background: "rgba(243,238,232,0.08)", border: `1px solid ${color.hairline}` }}>
            <div style={{ position: "absolute", inset: 0, borderRadius: 18, background: "rgba(243,238,232,0.08)", transformOrigin: "0 50%", transform: `scaleX(${bar})` }} />
            <div
              style={{
                position: "absolute",
                left: 0,
                top: 0,
                height: 36,
                width: (barW * 3) / 16,
                borderRadius: 18,
                background: color.paper,
                transformOrigin: "0 50%",
                transform: `scaleX(${chunk})`,
                boxShadow: "0 0 40px rgba(255,176,138,0.45)",
              }}
            />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 18, marginTop: 26, transform: `translateY(${(1 - label) * 30}px)`, opacity: Math.min(1, label * 2) }}>
            <span style={{ ...font.display, fontSize: layout.wide ? 64 : 60, color: color.paper, fontVariantNumeric: "tabular-nums" }}>0.6–3 ms</span>
            <span style={{ fontSize: text, color: color.mute }}>per interactive render on Apple Silicon</span>
          </div>
        </div>
        <div style={{ display: "flex", gap: 14, opacity: s(38, "snap"), transform: `translateY(${(1 - s(38, "pop")) * 30}px)` }}>
          <Chip size={text}>One fused Metal kernel</Chip>
          <Chip size={text}>Native Swift</Chip>
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
