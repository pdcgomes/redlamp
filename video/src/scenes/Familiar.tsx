import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { noise2D } from "@remotion/noise";
import { Caption } from "../components/Caption";
import { glass } from "../components/Media";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, font } from "../theme";

const sliders = [
  { name: "Temp", min: 3000, max: 9000, base: 0.42, gradient: "linear-gradient(90deg,#4f7fd1,#e8c25a)" },
  { name: "Tint", min: -150, max: 150, base: 0.48, gradient: "linear-gradient(90deg,#4fb06a,#c65bc9)" },
  { name: "Exposure", min: -5, max: 5, base: 0.545, decimals: 2 },
  { name: "Contrast", min: -100, max: 100, base: 0.56 },
  { name: "Highlights", min: -100, max: 100, base: 0.3 },
  { name: "Shadows", min: -100, max: 100, base: 0.68 },
  { name: "Whites", min: -100, max: 100, base: 0.52 },
  { name: "Blacks", min: -100, max: 100, base: 0.46 },
];

const keys = [
  { key: "D", label: "Develop" },
  { key: "W", label: "White balance" },
  { key: "\\", label: "Before / After" },
  { key: "O", label: "Mask overlay" },
  { key: "⌘F", label: "Find adjustment" },
];

function format(value: number, decimals = 0) {
  const fixed = value.toFixed(decimals);
  return value > 0 && decimals ? `+${fixed}` : fixed;
}

/** The Basic panel assembles itself in Lightroom's order; single-key shortcuts pop up beside it. */
export function Familiar({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = useLayout();
  const panelW = 560;

  const panel = (
    <div style={{ ...glass, width: panelW, padding: "26px 30px 30px", fontFamily: font.family }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 18 }}>
        <span style={{ fontSize: 22, fontWeight: 600, color: color.paper }}>Basic</span>
        <span style={{ fontSize: 15, color: color.dim }}>Treatment · Color</span>
      </div>
      {sliders.map((slider, i) => {
        const inT = spring({ frame: frame - 10 - i * 5, fps, config: { damping: 18, stiffness: 120 } });
        const wander = noise2D(slider.name, frame / 55, i) * 0.14 * appear(frame, 40 + i * 4, 30);
        const t = Math.min(0.98, Math.max(0.02, slider.base + wander));
        const value = slider.min + (slider.max - slider.min) * t;
        const shown = slider.name === "Temp" ? Math.round(value / 50) * 50 : value;
        return (
          <div
            key={slider.name}
            style={{
              display: "grid",
              gridTemplateColumns: "130px 1fr 80px",
              alignItems: "center",
              gap: 16,
              height: 50,
              opacity: inT,
              transform: `translateX(${(1 - inT) * 40}px)`,
            }}
          >
            <span style={{ fontSize: 19, color: color.mute }}>{slider.name}</span>
            <div style={{ position: "relative", height: 4, borderRadius: 2, background: slider.gradient ?? "rgba(243,238,232,0.16)" }}>
              <div
                style={{
                  position: "absolute",
                  left: `calc(${t * 100}% - 10px)`,
                  top: -8,
                  width: 20,
                  height: 20,
                  borderRadius: 10,
                  background: "#ece6e1",
                  boxShadow: "0 2px 6px rgba(0,0,0,0.5)",
                }}
              />
            </div>
            <span style={{ fontSize: 19, color: color.paper, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
              {format(shown, slider.decimals ?? 0)}
            </span>
          </div>
        );
      })}
    </div>
  );

  const keycaps = (
    <div style={{ display: "flex", flexDirection: layout.wide ? "column" : "row", flexWrap: "wrap", gap: 18, justifyContent: "center" }}>
      {keys.map((k, i) => {
        const pop = spring({ frame: frame - 70 - i * 12, fps, config: { damping: 11, stiffness: 160 } });
        return (
          <div key={k.key} style={{ display: "flex", alignItems: "center", gap: 16, opacity: Math.min(1, pop * 1.4), transform: `scale(${0.6 + 0.4 * pop})` }}>
            <div
              style={{
                minWidth: 72,
                height: 72,
                padding: "0 14px",
                borderRadius: 16,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                fontFamily: font.family,
                fontSize: 30,
                fontWeight: 600,
                color: color.paper,
                background: "linear-gradient(180deg,#3a3230,#211b19)",
                border: `1px solid ${color.hairline}`,
                boxShadow: "inset 0 1px 0 rgba(255,255,255,0.08), 0 6px 0 #120e0d, 0 14px 30px rgba(0,0,0,0.5)",
              }}
            >
              {k.key}
            </div>
            {layout.wide ? <span style={{ fontFamily: font.family, fontSize: 20, color: color.mute }}>{k.label}</span> : null}
          </div>
        );
      })}
    </div>
  );

  return (
    <Stage glowX={layout.wide ? 0.68 : 0.5} glowY={0.18}>
      <AbsoluteFill
        style={{
          flexDirection: layout.wide ? "row" : "column",
          alignItems: "center",
          justifyContent: "center",
          gap: layout.wide ? 80 : 56,
          padding: layout.wide ? "0 110px" : "140px 60px 100px",
        }}
      >
        <div style={{ flex: layout.wide ? 1 : undefined, maxWidth: layout.wide ? 520 : 900 }}>
          <Caption
            title="Everything where you expect it."
            sub="Lightroom's panels, slider names, ranges and shortcuts."
            start={6}
            end={dur - 16}
            align={layout.wide ? "left" : "center"}
            size={layout.wide ? 62 : 64}
          />
        </div>
        {layout.wide ? keycaps : null}
        {panel}
        {layout.wide ? null : keycaps}
      </AbsoluteFill>
    </Stage>
  );
}
