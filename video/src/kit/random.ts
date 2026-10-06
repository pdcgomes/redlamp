/**
 * A seeded random source. Remotion renders frames in parallel and in any order, so nothing on
 * screen may use Math.random: the same seed gives the same numbers in every tab, every time.
 */
export type Random = {
  /** In [0, 1). */
  next: () => number;
  /** In [low, high). */
  range: (low: number, high: number) => number;
  /** In [-1, 1). */
  signed: () => number;
};

export function random(seed: number | string): Random {
  // mulberry32, seeded from a 32-bit FNV-1a hash of the seed.
  let state = typeof seed === "number" ? seed >>> 0 : hash(seed);
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { next, range: (low, high) => low + (high - low) * next(), signed: () => next() * 2 - 1 };
}

function hash(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}
