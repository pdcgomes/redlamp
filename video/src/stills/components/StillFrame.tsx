import type { CSSProperties, ReactNode } from "react";
import { AbsoluteFill } from "remotion";
import { Grain, Stage } from "../../components/Stage";
import { font } from "../../theme";
import { glowFor } from "../canvas";
import { Footer } from "./Footer";

type Props = {
  /** The image's place in the set, from 0, which decides where its light falls. */
  index: number;
  children: ReactNode;
  glow?: { x?: number; y?: number; strength?: number };
  /** Moves the footer, or `false` to leave it out. */
  footer?: CSSProperties | false;
};

/** The room every still is set in: the video's Stage, its one light placed for this image, and the footer. */
export function StillFrame({ index, children, glow, footer }: Props) {
  const light = { ...glowFor(index), ...glow };
  return (
    <Stage glowX={light.x} glowY={light.y} glow={glow?.strength ?? 1} grain={false}>
      {/* Under the captures only: it dithers the glow, which Reddit's recompression would band. */}
      <Grain opacity={0.07} />
      <AbsoluteFill style={{ fontFamily: font.family }}>{children}</AbsoluteFill>
      {footer === false ? null : <Footer style={footer} />}
    </Stage>
  );
}
