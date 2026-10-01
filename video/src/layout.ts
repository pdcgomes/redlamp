import { interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { easeOut } from "./theme";

export type Layout = { width: number; height: number; wide: boolean; tall: boolean; square: boolean };

/** Every scene is drawn once and laid out for 16:9, 9:16 or 1:1 from the composition's size. */
export function useLayout(): Layout {
  const { width, height } = useVideoConfig();
  return { width, height, wide: width > height, tall: height > width, square: width === height };
}

/**
 * The film's three springs. Everything that arrives pops and overshoots; everything that
 * leaves or travels snaps; slider thumbs drag with a little settle.
 */
export const springs = {
  pop: { damping: 11, stiffness: 240, mass: 0.7 },
  snap: { damping: 26, stiffness: 340, mass: 0.6 },
  drag: { damping: 15, stiffness: 260, mass: 0.6 },
} as const;

export type SpringName = keyof typeof springs;

/** `s(start)` is a spring that starts at frame `start` of the current sequence. */
export function useSprings() {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (start: number, name: SpringName = "pop") => spring({ frame: frame - start, fps, config: springs[name] });
}

/** 0 → 1 over `duration` frames from `start`, with the brand's soft ease. */
export function appear(frame: number, start: number, duration = 10): number {
  return interpolate(frame, [start, start + duration], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: easeOut,
  });
}

/** The music grid: 120 BPM at 30 fps is a beat every 15 frames. */
export const BEAT = 15;
