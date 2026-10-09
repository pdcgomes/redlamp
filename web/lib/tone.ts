/**
 * The tone and colour maths the articles' figures draw with: Redlamp's scene-to-display tone curve,
 * with the constants `packages/RedlampKernels/Sources/Shaders/Develop.metal` had on 9 October 2026,
 * each built-in look's contrast as `research/tone-reproduction/greyscale.py` models it, the sRGB
 * transfer curve (IEC 61966-2-1) and CIE 1976 L*. Relative imports only, so `node --test` can load it.
 */

export const MIDDLE_GREY = 0.18;

const SHOULDER_START = 0.54358851;
const SHOULDER_START_Y = 0.8;
const SHOULDER_WIDTH_EV = 2.40548194;
const SHOULDER_POWER = 3.25537943;
const FILMIC_AT_ONE = 0.80379747;

/** The scene value the tone curve renders as white, four stops over middle grey. */
export const CURVE_WHITE = SHOULDER_START * 2 ** SHOULDER_WIDTH_EV;

export const LOOK_CONTRAST = { neutral: 0.72, color: 1 } as const;
export type Look = keyof typeof LOOK_CONTRAST;

export function clamp(x: number, lo: number, hi: number): number {
  return Math.min(Math.max(x, lo), hi);
}

/** Stops from middle grey. */
export function stopsFromGrey(scene: number): number {
  return Math.log2(scene / MIDDLE_GREY);
}

function filmic(x: number): number {
  return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
}

/** Scene light to display light: a filmic curve, then a shoulder that reaches white at `CURVE_WHITE`. */
export function toneCurve(scene: number): number {
  if (scene <= 0) return 0;
  if (scene <= SHOULDER_START) return filmic(scene) / FILMIC_AT_ONE;
  const u = Math.min(Math.log2(scene / SHOULDER_START) / SHOULDER_WIDTH_EV, 1);
  return 1 - (1 - SHOULDER_START_Y) * (1 - u) ** SHOULDER_POWER;
}

/** The tone curve after a look's contrast, which scales each value's stops around middle grey. */
export function lookCurve(scene: number, look: Look): number {
  const contrast = (LOOK_CONTRAST[look] - 1) * 0.6;
  return toneCurve(MIDDLE_GREY * 2 ** (stopsFromGrey(Math.max(scene, 1e-9)) * (1 + contrast)));
}

export function srgbEncode(linear: number): number {
  const v = clamp(linear, 0, 1);
  return v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055;
}

export function srgbDecode(encoded: number): number {
  return encoded <= 0.04045 ? encoded / 12.92 : ((encoded + 0.055) / 1.055) ** 2.4;
}

/** CIE L* of a relative luminance. */
export function lstar(y: number): number {
  const v = Math.max(y, 0);
  return v > 216 / 24389 ? 116 * Math.cbrt(v) - 16 : (24389 / 27) * v;
}

/** The relative luminance of an L*. */
export function luminanceOf(l: number): number {
  const f = (l + 16) / 116;
  return f ** 3 > 216 / 24389 ? f ** 3 : (27 * l) / 24389;
}

/** The log encoding film looks read their tables with: −10 to +6.5 stops around middle grey, as 0 to 1. */
export function sceneLog(scene: number): number {
  return clamp((stopsFromGrey(Math.max(scene, 1e-9)) + 10) / 16.5, 0, 1);
}

/** The 8-bit level that writes a display light with the sRGB curve. */
export function level8(linear: number): number {
  return Math.round(255 * srgbEncode(linear));
}

/** A CSS grey that shows a display light. */
export function greyCss(linear: number): string {
  const level = level8(linear);
  return `rgb(${level} ${level} ${level})`;
}

/**
 * The Exposure, in stops, that renders a patch of the given reference L* at that L* through a look,
 * with the patch's scene value at its reflectance times 2^Exposure.
 */
export function anchorExposure(reference: number, look: Look): number {
  const reflectance = luminanceOf(reference);
  let lo = -6;
  let hi = 6;
  for (let i = 0; i < 50; i++) {
    const mid = (lo + hi) / 2;
    if (lstar(lookCurve(reflectance * 2 ** mid, look)) < reference) lo = mid;
    else hi = mid;
  }
  return (lo + hi) / 2;
}
