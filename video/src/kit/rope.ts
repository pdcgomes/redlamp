import { HangingSign, type Point, type Pose, type Shape, type Start } from "../../../web/lib/hanging-sign";

/**
 * The website's hanging sign (web/lib/hanging-sign.ts), driven by a script instead of a pointer.
 * Its physics is stateful, so a frame can't be worked out on its own: the whole performance is
 * simulated once, from the drop to the last frame, and every frame looks its pose up. Units are
 * the website's pixels about the anchor's resting point, as the physics was tuned in them;
 * `Sign` scales them into the scene.
 */
export type SignScript = {
  fps: number;
  frames: number;
  shape: Omit<Shape, "anchor">;
  /** Seconds: when the sign starts to fall. */
  drop: number;
  /** Where the eyelet starts, relative to the anchor, its turn and its velocity. */
  start: Start;
  /** Where the anchor is at a moment, relative to its resting point: it moves as what it hangs from bounces. */
  anchor: (t: number) => Point;
  /** Hands on the sign: from `at` to `until` seconds, the point grabbed (relative to the sign's centre as it is at `at`) follows `to(t)`. */
  holds?: { at: number; until: number; grab: Point; to: (t: number, grabbed: Point) => Point }[];
};

export type SignFrame = { pose: Pose; rope: Point[] };

/** Steps per frame: the anchor and any hold move this often. */
const STEPS = 8;
const cache = new Map<string, (SignFrame | null)[]>();

export function performSign(script: SignScript, key: string): (SignFrame | null)[] {
  const cached = cache.get(key);
  if (cached) return cached;
  const frames: (SignFrame | null)[] = [];
  let sign: HangingSign | null = null;
  let held: { index: number; grabbed: Point } | null = null;
  const dt = 1 / script.fps / STEPS;
  for (let f = 0; f < script.frames; f += 1) {
    for (let s = 0; s < STEPS; s += 1) {
      const t = (f + s / STEPS) / script.fps;
      if (t < script.drop) continue;
      const anchor = script.anchor(t);
      if (!sign) {
        sign = new HangingSign(
          { ...script.shape, anchor },
          { ...script.start, eyelet: { x: anchor.x + script.start.eyelet.x, y: anchor.y + script.start.eyelet.y } },
        );
      }
      sign.moveAnchor(anchor);
      const holds = script.holds ?? [];
      if (held && t >= holds[held.index].until) {
        sign.release();
        held = null;
      }
      if (!held) {
        const index = holds.findIndex((h) => t >= h.at && t < h.until);
        if (index >= 0) {
          const pose = sign.pose;
          const grabbed = local(pose, holds[index].grab);
          sign.grab(grabbed);
          held = { index, grabbed };
        }
      }
      if (held) sign.drag(holds[held.index].to(t, held.grabbed));
      sign.step(dt);
    }
    frames.push(sign ? { pose: sign.pose, rope: sign.rope } : null);
  }
  cache.set(key, frames);
  return frames;
}

/**
 * Seconds from the drop until the rope first pulls taut, for a sign started as `script` starts it:
 * a drop can then be timed so the catch lands on a beat.
 */
export function fallTime(script: Pick<SignScript, "shape" | "start">): number {
  const anchor = { x: 0, y: 0 };
  const sign = new HangingSign(
    { ...script.shape, anchor },
    { ...script.start, eyelet: { x: script.start.eyelet.x, y: script.start.eyelet.y } },
  );
  const dt = 1 / 480;
  for (let t = 0; t < 3; t += dt) {
    sign.step(dt);
    const rope = sign.rope;
    const eyelet = rope[rope.length - 1];
    if (Math.hypot(eyelet.x - anchor.x, eyelet.y - anchor.y) >= script.shape.ropeLength * 0.985) return t;
  }
  return 0;
}

/** A point given relative to the sign's centre, unturned, placed on the sign as it is now. */
function local(pose: Pose, offset: Point): Point {
  const cos = Math.cos(pose.angle);
  const sin = Math.sin(pose.angle);
  return { x: pose.x + offset.x * cos - offset.y * sin, y: pose.y + offset.x * sin + offset.y * cos };
}
