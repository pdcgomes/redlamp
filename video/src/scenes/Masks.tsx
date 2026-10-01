import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Caption } from "../components/Caption";
import { Photo } from "../components/Media";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, easeInOut } from "../theme";

/**
 * A linear gradient is drawn down over the sky under the red overlay, then applied; a radial
 * gradient blooms over the big tree and warms it. The overlay is the app's own mask view.
 */
export function Masks({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const layout = useLayout();
  const w = layout.wide ? 1180 : 960;
  const h = w * (layout.tall ? 1.25 : 0.667);
  // The big tree sits further left once the landscape is cropped to 4:5.
  const cx = layout.tall ? 30 : 38;
  const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
  const linearDraw = interpolate(frame, [24, 70], [0, 1], { ...clamp, easing: easeInOut });
  const linearOverlay = interpolate(frame, [24, 40, 82, 100], [0, 1, 1, 0], clamp);
  const linearApply = appear(frame, 84, 30);
  const radialDraw = interpolate(frame, [116, 156], [0, 1], { ...clamp, easing: easeInOut });
  const radialOverlay = interpolate(frame, [116, 130, 168, 186], [0, 1, 1, 0], clamp);
  const radialApply = appear(frame, 170, 30);
  const edge = 18 + linearDraw * 34;
  const linearMask = `linear-gradient(180deg, black 0%, black ${edge - 14}%, transparent ${edge + 10}%)`;
  const radialMask = `radial-gradient(${18 + radialDraw * 16}% ${22 + radialDraw * 20}% at ${cx}% 42%, black 45%, transparent 100%)`;

  return (
    <Stage glowX={0.5} glowY={0.05}>
      <AbsoluteFill
        style={{
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: layout.wide ? 48 : 60,
          padding: layout.wide ? "40px 100px 0" : "140px 60px 80px",
        }}
      >
        <Caption
          title="Masks, built in from day one."
          sub="Add, subtract and intersect, evaluated per pixel on the GPU."
          start={4}
          end={dur - 16}
          align="center"
          size={layout.wide ? 56 : 64}
        />
        <div style={{ position: "relative", width: w, height: h, borderRadius: 16, overflow: "hidden", boxShadow: "0 30px 80px rgba(0,0,0,0.6)" }}>
          <Photo />
          {/* Applied: a darker, cooler sky. */}
          <AbsoluteFill style={{ opacity: linearApply, maskImage: linearMask, WebkitMaskImage: linearMask }}>
            <Photo style={{ filter: "brightness(0.62) saturate(1.45) hue-rotate(-10deg) contrast(1.15)" }} />
          </AbsoluteFill>
          {/* Applied: the tree lifted and warmed. */}
          <AbsoluteFill style={{ opacity: radialApply, maskImage: radialMask, WebkitMaskImage: radialMask }}>
            <Photo style={{ filter: "brightness(1.32) saturate(1.2) sepia(0.28)" }} />
          </AbsoluteFill>
          {/* The red overlays while each mask is drawn. */}
          <AbsoluteFill style={{ background: "rgba(224,64,46,0.5)", opacity: linearOverlay, maskImage: linearMask, WebkitMaskImage: linearMask }} />
          <AbsoluteFill style={{ background: "rgba(224,64,46,0.5)", opacity: radialOverlay, maskImage: radialMask, WebkitMaskImage: radialMask }} />
          <svg width={w} height={h} style={{ position: "absolute", inset: 0 }}>
            <g opacity={linearOverlay}>
              {[-12, 0, 12].map((d, i) => (
                <line
                  key={d}
                  x1={0}
                  x2={w}
                  y1={(h * (edge + d * 0.8)) / 100}
                  y2={(h * (edge + d * 0.8)) / 100}
                  stroke={color.paper}
                  strokeOpacity={i === 1 ? 0.9 : 0.45}
                  strokeWidth={i === 1 ? 2.5 : 1.5}
                  strokeDasharray={i === 1 ? undefined : "8 8"}
                />
              ))}
              <circle cx={w / 2} cy={(h * edge) / 100} r="9" fill={color.paper} />
            </g>
            <g opacity={radialOverlay}>
              <ellipse
                cx={(w * cx) / 100}
                cy={h * 0.42}
                rx={(w * (18 + radialDraw * 16)) / 100}
                ry={(h * (22 + radialDraw * 20)) / 100}
                fill="none"
                stroke={color.paper}
                strokeOpacity="0.85"
                strokeWidth="2.5"
              />
              <circle cx={(w * cx) / 100} cy={h * 0.42} r="9" fill={color.paper} />
            </g>
          </svg>
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
