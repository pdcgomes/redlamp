import type { ReactNode } from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { noise2D } from "@remotion/noise";
import { color } from "../theme";

type Props = {
  children: ReactNode;
  /** Where the one red light sits, in fractions of the frame. */
  glowX?: number;
  glowY?: number;
  glow?: number;
  /** Frames where the light flares and decays, on the beat. */
  pulses?: number[];
  /** Grain over everything. Stills turn it off and lay their own under the captures. */
  grain?: boolean;
};

/** The dark room every scene happens in: warm near-black, one red light, a breath of grain. */
export function Stage({ children, glowX = 0.5, glowY = 0.12, glow = 1, pulses = [], grain = true }: Props) {
  const frame = useCurrentFrame();
  const breathe = 0.92 + 0.08 * noise2D("stage", frame / 60, 0);
  const flare = pulses.reduce((sum, p) => (frame >= p ? sum + 0.7 * Math.exp(-(frame - p) / 5) : sum), 0);
  const strength = glow * breathe + flare;
  return (
    <AbsoluteFill style={{ background: color.wall, overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(60% 55% at ${glowX * 100}% ${glowY * 100}%, rgba(224,64,46,${0.3 * strength}), rgba(224,64,46,${0.07 * strength}) 45%, transparent 75%)`,
        }}
      />
      <AbsoluteFill style={{ background: "radial-gradient(120% 90% at 50% 50%, transparent 55%, rgba(0,0,0,0.55))" }} />
      {children}
      {grain ? <Grain /> : null}
    </AbsoluteFill>
  );
}

/** Film grain that changes every two frames, so the dark never looks digital and flat. */
export function Grain({ opacity = 0.06 }: { opacity?: number }) {
  const frame = useCurrentFrame();
  const seed = Math.floor(frame / 2) % 24;
  return (
    <AbsoluteFill style={{ pointerEvents: "none", mixBlendMode: "overlay", opacity }}>
      <svg width="100%" height="100%">
        <filter id={`grain-${seed}`}>
          <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed={seed} stitchTiles="stitch" />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect width="100%" height="100%" filter={`url(#grain-${seed})`} />
      </svg>
    </AbsoluteFill>
  );
}
