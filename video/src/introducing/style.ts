import { Easing, interpolate, useVideoConfig } from "remotion";

/** The film runs at 30 fps on a 72 BPM grid: a beat every 25 frames, a bar every 100. */
export const BEAT = 25;
export const BAR = 100;

/**
 * The room the photos are shown in: the app's Neutral greys (`PaletteTokens.standard` in
 * RedlampDesign), taken darker so the captures sit in it. The safelight's red is kept for the
 * opening and the end, so nothing tints a photo while it's on screen.
 */
export const neutral = {
  deep: "#050506",
  room: "#0c0c0d",
  lift: "#161618",
  panel: "#1d1d1d",
  hairline: "rgba(255,255,255,0.10)",
  label: "rgba(255,255,255,0.72)",
  secondary: "rgba(255,255,255,0.48)",
  tertiary: "rgba(255,255,255,0.28)",
};

/** Headlines in the brand's paper; sublines and small print in neutral greys. */
export const ink = {
  headline: "#f3eee8",
  sub: "#a2a2a7",
  small: "#6c6c71",
};

export const ease = {
  /** Arrivals: quick to start, then a long, soft settle. */
  out: Easing.bezier(0.16, 1, 0.3, 1),
  /** Camera moves and anything that travels: slow away, slow in. */
  move: Easing.bezier(0.45, 0, 0.15, 1),
  inOut: Easing.bezier(0.65, 0, 0.35, 1),
};

/** 0 → 1 over `duration` frames from `start`. */
export function ramp(frame: number, start: number, duration: number, easing: (t: number) => number = ease.move): number {
  return interpolate(frame, [start, start + Math.max(1, duration)], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing,
  });
}

export const mix = (a: number, b: number, t: number) => a + (b - a) * t;

/** Keyframes for one value: `track(frame, [[0, 10], [60, 20]])` eases between them. */
export function track(frame: number, keys: [number, number][], easing: (t: number) => number = ease.move): number {
  if (frame <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [f0, v0] = keys[i - 1];
    const [f1, v1] = keys[i];
    if (frame <= f1) return mix(v0, v1, easing((frame - f0) / Math.max(1, f1 - f0)));
  }
  return keys[keys.length - 1][1];
}

export type Shape = "wide" | "tall" | "feed";

/** 16:9 is wide, 9:16 tall, and 4:5 (or square) the feed shape. Sizes are in 1080p pixels. */
export function useShape(): { shape: Shape; width: number; height: number } {
  const { width, height } = useVideoConfig();
  const ratio = width / height;
  return { shape: ratio > 1.2 ? "wide" : ratio < 0.7 ? "tall" : "feed", width, height };
}

export const font = {
  family: "Inter, -apple-system, 'Helvetica Neue', sans-serif",
  display: { fontVariationSettings: '"opsz" 32', fontWeight: 600, letterSpacing: "-0.024em" } as const,
  text: { fontVariationSettings: '"opsz" 18', fontWeight: 450, letterSpacing: "-0.008em" } as const,
};

/** Type sizes per shape: a headline, its subline, labels on sheets, and small print. */
export const type: Record<Shape, { headline: number; sub: number; label: number; small: number }> = {
  wide: { headline: 76, sub: 33, label: 22, small: 17 },
  tall: { headline: 84, sub: 38, label: 26, small: 22 },
  feed: { headline: 72, sub: 33, label: 24, small: 19 },
};
