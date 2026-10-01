/**
 * A tiny colour grade applied to the illustration's flat palette, so edits, masks and film
 * looks all change the same drawing the way they would change a photo.
 */
export type Grade = {
  /** Stops. */
  exposure?: number;
  contrast?: number;
  saturation?: number;
  /** Positive is warmer. */
  warmth?: number;
  /** Positive is more magenta. */
  tint?: number;
  /** Recovers bright tones, 0 to 1. */
  highlights?: number;
  /** Opens dark tones, 0 to 1. */
  shadows?: number;
  /** Raises the black point, 0 to 1. */
  fade?: number;
  /** Teal shadows and orange highlights, 0 to 1. */
  split?: number;
  /** Cross-processing, 0 to 1. */
  cross?: number;
  /** Red glow around bright light, 0 to 1. */
  halation?: number;
  mono?: number;
};

const keys = [
  "exposure",
  "contrast",
  "saturation",
  "warmth",
  "tint",
  "highlights",
  "shadows",
  "fade",
  "split",
  "cross",
  "halation",
  "mono",
] as const;

export function combine(...grades: Grade[]): Grade {
  const out: Grade = {};
  for (const g of grades) for (const k of keys) if (g[k] !== undefined) out[k] = (out[k] ?? 0) + (g[k] as number);
  return out;
}

export function scale(g: Grade, t: number): Grade {
  const out: Grade = {};
  for (const k of keys) if (g[k] !== undefined) out[k] = (g[k] as number) * t;
  return out;
}

export function mix(a: Grade, b: Grade, t: number): Grade {
  return combine(scale(a, 1 - t), scale(b, t));
}

const clamp = (x: number) => Math.min(1, Math.max(0, x));
const luma = (r: number, g: number, b: number) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

export function apply(hex: string, grade: Grade = {}): string {
  let r = parseInt(hex.slice(1, 3), 16) / 255;
  let g = parseInt(hex.slice(3, 5), 16) / 255;
  let b = parseInt(hex.slice(5, 7), 16) / 255;
  const e = 2 ** (grade.exposure ?? 0);
  r *= e;
  g *= e;
  b *= e;
  const w = grade.warmth ?? 0;
  r *= 1 + 0.14 * w;
  b *= 1 - 0.16 * w;
  g *= 1 - 0.07 * (grade.tint ?? 0);
  const tone = (x: number) => {
    let y = x;
    y += (grade.shadows ?? 0) * 0.3 * (1 - y) ** 3;
    y -= (grade.highlights ?? 0) * 0.3 * y ** 3;
    y = 0.5 + (y - 0.5) * (1 + (grade.contrast ?? 0));
    return y;
  };
  r = tone(r);
  g = tone(g);
  b = tone(b);
  const split = grade.split ?? 0;
  if (split) {
    const l = clamp(luma(r, g, b));
    r += split * 0.16 * (l - 0.45);
    b -= split * 0.14 * (l - 0.45);
    g += split * 0.03 * (0.5 - l);
  }
  const cross = grade.cross ?? 0;
  if (cross) {
    r = r + cross * 0.18 * (r - 0.25);
    g = g * (1 + 0.08 * cross) + 0.02 * cross;
    b = b * (1 - 0.3 * cross) + 0.1 * cross;
  }
  const l = luma(r, g, b);
  const s = 1 + (grade.saturation ?? 0);
  r = l + (r - l) * s;
  g = l + (g - l) * s;
  b = l + (b - l) * s;
  const mono = grade.mono ?? 0;
  if (mono) {
    const m = 0.36 * r + 0.56 * g + 0.08 * b;
    r += (m - r) * mono;
    g += (m - g) * mono;
    b += (m - b) * mono;
  }
  const fade = grade.fade ?? 0;
  const out = [r, g, b].map((x) => {
    const y = clamp(fade * 0.16 + clamp(x) * (1 - fade * 0.16));
    return Math.round(y * 255)
      .toString(16)
      .padStart(2, "0");
  });
  return `#${out.join("")}`;
}

/** Film looks as grades, named and described as in the README. */
export const looks = {
  "portra-400": { name: "Portra 400", kind: "Colour negative", grade: { warmth: 0.25, saturation: -0.12, contrast: -0.1, shadows: 0.35, fade: 0.25 } },
  "ektar-100": { name: "Ektar 100", kind: "Colour negative", grade: { saturation: 0.4, contrast: 0.14, warmth: 0.08 } },
  "cinestill-800t": { name: "CineStill 800T", kind: "Tungsten negative", grade: { warmth: -1, tint: -0.25, exposure: -0.2, contrast: 0.1, halation: 1 } },
  "vision3-500t-2383": { name: "Vision3 500T · 2383", kind: "Cinema print", grade: { split: 1, contrast: 0.22, saturation: -0.08, exposure: -0.1 } },
  "vision3-2383-bleach-bypass": { name: "2383 Bleach Bypass", kind: "Cinema print", grade: { saturation: -0.6, contrast: 0.4, split: 0.4 } },
  "velvia-50": { name: "Velvia 50", kind: "Slide", grade: { saturation: 0.65, contrast: 0.22, exposure: -0.15 } },
  "velvia-50-cross": { name: "Velvia 50 · Cross", kind: "Cross-processed slide", grade: { cross: 1, saturation: 0.3, contrast: 0.25 } },
  "tri-x-400": { name: "Tri-X 400", kind: "Black and white", grade: { mono: 1, contrast: 0.32 } },
} satisfies Record<string, { name: string; kind: string; grade: Grade }>;

export type LookId = keyof typeof looks;
