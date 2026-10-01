import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { noise2D } from "@remotion/noise";
import { Caption } from "../components/Caption";
import { glass, Photo } from "../components/Media";
import { Stage } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, font } from "../theme";

const SNAP = 84;

/** A photo hangs from a cloud and a subscription tag. The strings snap, and it lands in a Mac window. */
export function Untether({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = useLayout();
  const fall = Math.max(0, frame - SNAP);
  const gravity = (fall * fall) / 9;
  const settle = spring({ frame: frame - (SNAP + 30), fps, config: { damping: 18, stiffness: 90 } });
  const window = spring({ frame: frame - (SNAP + 18), fps, config: { damping: 20, stiffness: 110 } });
  const driftX = noise2D("card-x", frame / 70, 0) * 10 * (1 - settle);
  const driftY = noise2D("card-y", 0, frame / 70) * 10 * (1 - settle);
  const cardW = layout.wide ? 620 : 640;
  const cardH = cardW * 0.667;
  const cx = layout.wide ? 1180 : layout.width / 2;
  const cy = layout.wide ? 600 : layout.height * (layout.tall ? 0.6 : 0.6);
  const snapped = frame >= SNAP;

  return (
    <Stage glowX={layout.wide ? 0.62 : 0.5} glowY={0.2}>
      <svg width={layout.width} height={layout.height} style={{ position: "absolute", inset: 0 }}>
        {/* The cloud, drifting away once the tether snaps. */}
        <g
          transform={`translate(${cx} ${cy - cardH / 2 - 260 - (snapped ? gravity * 0.15 : 0)})`}
          opacity={1 - appear(frame, SNAP + 4, 40)}
        >
          <path
            d="M -90 30 C -130 30 -140 -20 -100 -32 C -96 -78 -30 -88 -10 -52 C 10 -90 80 -80 84 -32 C 130 -28 128 30 86 30 Z"
            fill="none"
            stroke={color.mute}
            strokeWidth="5"
            strokeLinejoin="round"
          />
        </g>
        {/* The tether: one line until the snap, then two halves falling apart. */}
        {!snapped ? (
          <line
            x1={cx + driftX}
            y1={cy - cardH / 2 + driftY}
            x2={cx}
            y2={cy - cardH / 2 - 228}
            stroke={color.mute}
            strokeWidth="3"
            strokeDasharray="10 10"
            strokeDashoffset={-frame * 2}
          />
        ) : (
          <g opacity={1 - appear(frame, SNAP, 30)}>
            <line x1={cx} y1={cy - cardH / 2 - 228} x2={cx - 20} y2={cy - cardH / 2 - 130 - gravity * 0.3} stroke={color.mute} strokeWidth="3" strokeDasharray="10 10" />
            <line x1={cx} y1={cy - cardH / 2 + gravity} x2={cx + 24} y2={cy - cardH / 2 - 90 + gravity} stroke={color.mute} strokeWidth="3" strokeDasharray="10 10" />
          </g>
        )}
      </svg>
      {/* The Mac window that catches the photo. */}
      <div
        style={{
          position: "absolute",
          left: cx - cardW / 2 - 28,
          top: cy - cardH / 2 - 62,
          width: cardW + 56,
          height: cardH + 90,
          ...glass,
          opacity: window,
          transform: `scale(${0.9 + 0.1 * window})`,
        }}
      >
        <div style={{ display: "flex", gap: 10, padding: "18px 20px" }}>
          {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
            <span key={c} style={{ width: 13, height: 13, borderRadius: 7, background: c }} />
          ))}
        </div>
      </div>
      {/* The photo. */}
      <div
        style={{
          position: "absolute",
          left: cx - cardW / 2 + driftX,
          top: cy - cardH / 2 + driftY,
          width: cardW,
          height: cardH,
          borderRadius: 12,
          overflow: "hidden",
          boxShadow: "0 30px 70px rgba(0,0,0,0.6)",
          transform: `rotate(${(1 - settle) * -2.5}deg)`,
        }}
      >
        <Photo />
      </div>
      {/* The subscription tag, swinging, then falling. */}
      <div
        style={{
          position: "absolute",
          left: cx + cardW / 2 - 40,
          top: cy - cardH / 2 - 10 + (snapped ? gravity * 1.2 : 0),
          transformOrigin: "0 0",
          transform: `rotate(${snapped ? 28 + fall * 2 : 12 + Math.sin(frame / 14) * 6}deg)`,
          opacity: 1 - appear(frame, SNAP + 10, 26),
        }}
      >
        <div style={{ width: 2, height: 70, background: color.mute, marginLeft: 14 }} />
        <div
          style={{
            fontFamily: font.family,
            fontSize: 26,
            fontWeight: 600,
            color: color.wall,
            background: color.ring,
            padding: "10px 18px",
            borderRadius: 10,
            whiteSpace: "nowrap",
          }}
        >
          $ / month
        </div>
      </div>
      <AbsoluteFill
        style={{
          padding: layout.wide ? "0 120px" : "150px 80px",
          justifyContent: layout.wide ? "center" : "flex-start",
          alignItems: layout.wide ? "flex-start" : "center",
        }}
      >
        <div style={{ maxWidth: layout.wide ? 600 : 900 }}>
          <Caption
            title="Lightroom's workflow, without the strings."
            sub="No subscription, no cloud. Native to your Mac."
            start={18}
            end={dur - 16}
            align={layout.wide ? "left" : "center"}
            size={layout.wide ? 62 : 66}
          />
        </div>
      </AbsoluteFill>
    </Stage>
  );
}
