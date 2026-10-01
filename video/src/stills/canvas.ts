/** Stills are laid out in points at 1440 × 900 and rendered at 2×: 2880 × 1800, a Mac App Store size. */
export const canvas = { width: 1440, height: 900, scale: 2 } as const;

/** The editor window every capture is taken at, in points. Captures are twice this in pixels. */
export const captureSize = { width: 1600, height: 1000 } as const;

/** Type sizes in canvas points. Nothing a reader needs is smaller than `text`, about 11 points on a phone. */
export const type = { headline: 88, sub: 44, text: 40, small: 22 } as const;

export const margin = 96;

/** Where image `index` of the set puts its one light: it drifts left to right through the set. */
export function glowFor(index: number, count = 9) {
  return { x: 0.12 + (0.76 * index) / (count - 1), y: 0.04 };
}
