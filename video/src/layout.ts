import { interpolate, useVideoConfig } from "remotion";
import { easeOut } from "./theme";

export type Layout = { width: number; height: number; wide: boolean; tall: boolean; square: boolean };

/** Every scene is drawn once and laid out for 16:9, 9:16 or 1:1 from the composition's size. */
export function useLayout(): Layout {
  const { width, height } = useVideoConfig();
  return { width, height, wide: width > height, tall: height > width, square: width === height };
}

/** 0 → 1 over `duration` frames from `start`, with the brand's soft ease. */
export function appear(frame: number, start: number, duration = 24): number {
  return interpolate(frame, [start, start + duration], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: easeOut,
  });
}

/** 1 → 0 over the last `duration` frames of a scene lasting `dur` frames. */
export function leave(frame: number, dur: number, duration = 14): number {
  return interpolate(frame, [dur - duration, dur], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
}
