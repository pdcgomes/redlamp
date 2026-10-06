import { Easing } from "remotion";
import { random } from "./random";

/**
 * A camera over a scene laid out in world units: `x` and `y` are the world point at the centre of
 * the frame, and `zoom` the screen pixels per world unit. DOM layers take `cssTransform`, canvases
 * `canvasMatrix`, so both move together.
 */
export type Framing = { x: number; y: number; zoom: number };
export type Camera = Framing & { shakeX: number; shakeY: number };

const travel = Easing.bezier(0.65, 0, 0.35, 1);

/**
 * Eases between framings keyed by frame, holding the first before it and the last after it. A key
 * can name the easing of the move that ends on it; moves ease in and out unless they say otherwise.
 */
export function framing(frame: number, keys: [number, Framing, ((t: number) => number)?][]): Framing {
  if (frame <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i += 1) {
    const [f1, b, easing = travel] = keys[i];
    if (frame <= f1) {
      const [f0, a] = keys[i - 1];
      const k = easing((frame - f0) / Math.max(1, f1 - f0));
      // Zoom eases in log space, so a push in and a pull back feel equally even.
      return { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, zoom: a.zoom * (b.zoom / a.zoom) ** k };
    }
  }
  return keys[keys.length - 1][1];
}

/**
 * A jolt from `at` (frames), in screen pixels, dying away over `frames`: for an impact. It shakes at
 * about 14 Hz in a direction that turns, the way a camera on a hand does when something lands.
 */
export function shake(frame: number, at: number, amplitude: number, frames: number, seed: string): { x: number; y: number } {
  const since = frame - at;
  if (since < 0 || since > frames) return { x: 0, y: 0 };
  const r = random(`${seed}:${at}`);
  const phase = r.next() * Math.PI * 2;
  const decay = (1 - since / frames) ** 2;
  return {
    x: amplitude * decay * Math.sin(since * 2.9 + phase),
    y: amplitude * decay * Math.cos(since * 2.3 + phase * 1.7),
  };
}

export function cssTransform(camera: Camera, width: number, height: number): string {
  const { x, y, zoom, shakeX, shakeY } = camera;
  return `translate(${width / 2 + shakeX - x * zoom}px, ${height / 2 + shakeY - y * zoom}px) scale(${zoom})`;
}

export function canvasMatrix(camera: Camera, width: number, height: number): [number, number, number, number, number, number] {
  const { x, y, zoom, shakeX, shakeY } = camera;
  return [zoom, 0, 0, zoom, width / 2 + shakeX - x * zoom, height / 2 + shakeY - y * zoom];
}

/** Where a world point lands on screen. */
export function toScreen(camera: Camera, width: number, height: number, point: { x: number; y: number }) {
  return {
    x: (point.x - camera.x) * camera.zoom + width / 2 + camera.shakeX,
    y: (point.y - camera.y) * camera.zoom + height / 2 + camera.shakeY,
  };
}
