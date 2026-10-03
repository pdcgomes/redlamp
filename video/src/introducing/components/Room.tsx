import type { ReactNode } from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { noise2D } from "@remotion/noise";
import { Grain } from "../../components/Stage";
import { color } from "../../theme";
import { font, neutral } from "../style";

type Props = {
  /** Neutral greys while photos are on screen; the brand's wall and safelight at either end. */
  tone?: "neutral" | "safelight";
  /** The soft light from above in the neutral room, 0 to 1. */
  light?: number;
  /** A pool of light behind a subject, as a studio lights a product (fractions of the frame). */
  spot?: { x: number; y: number; strength?: number };
  /** The safelight's glow on the wall, 0 to 1, and where it falls (fractions of the frame). */
  glow?: number;
  glowX?: number;
  glowY?: number;
  children?: ReactNode;
};

export function Room({ tone = "neutral", light = 1, spot, glow = 0, glowX = 0.5, glowY = 0.4, children }: Props) {
  const frame = useCurrentFrame();
  const breathe = 0.94 + 0.06 * noise2D("room", frame / 90, 0);
  return (
    <AbsoluteFill style={{ background: tone === "neutral" ? neutral.room : color.wall, overflow: "hidden", fontFamily: font.family }}>
      {tone === "neutral" ? (
        <AbsoluteFill
          style={{
            opacity: light,
            background: `radial-gradient(70% 60% at 50% -8%, rgba(255,255,255,0.075), rgba(255,255,255,0.02) 45%, transparent 75%)`,
          }}
        />
      ) : (
        <AbsoluteFill
          style={{
            background: `radial-gradient(48% 52% at ${glowX * 100}% ${glowY * 100}%, rgba(224,64,46,${0.34 * glow * breathe}), rgba(224,64,46,${0.08 * glow * breathe}) 42%, transparent 72%)`,
          }}
        />
      )}
      {tone === "neutral" && spot ? (
        <AbsoluteFill
          style={{
            background: `radial-gradient(34% 40% at ${spot.x * 100}% ${spot.y * 100}%, rgba(255,255,255,${0.07 * (spot.strength ?? 1)}), rgba(255,255,255,${0.025 * (spot.strength ?? 1)}) 50%, transparent 100%)`,
          }}
        />
      ) : null}
      <AbsoluteFill style={{ background: "radial-gradient(125% 95% at 50% 50%, transparent 55%, rgba(0,0,0,0.6))" }} />
      {children}
      <Grain opacity={0.055} />
    </AbsoluteFill>
  );
}
