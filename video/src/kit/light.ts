import { type Random, random } from "./random";

/**
 * The brand's light in motion, drawn on a canvas: light gathering behind the lamp, the shot it
 * fires in an arc, the sparks it sheds, and the flash and the chasing lights where it lands. It is
 * the website's star nudge (web/components/site/StarNudge.tsx, specified in docs/brand/star-nudge.md)
 * redrawn for Remotion: every function draws the state at a time in seconds, from nothing but its
 * arguments and a seeded random source, so any frame can be drawn on its own and in any order.
 *
 * Lengths are world units (the scene's pixels before the camera); `unit` is world units per
 * website pixel and scales every absolute size, speed and gravity the website uses, so the light
 * looks as it does there at any scale. Draw with the context in world space.
 */

export type Point = { x: number; y: number };
export type Colour = readonly [number, number, number];

export const safelight: Colour = [224, 64, 46];
export const deep: Colour = [154, 28, 20];
export const filament: Colour = [255, 176, 138];
export const hot: Colour = [255, 240, 230];

type Lights = Record<"safelight" | "filament" | "hot", HTMLCanvasElement>;
let stamps: Lights | null = null;

/** Soft round lights, drawn once per tab and stamped wherever the light needs one. */
function lights(): Lights {
  stamps ??= { safelight: spot(safelight), filament: spot(filament), hot: spot(hot) };
  return stamps;
}

// ---------------------------------------------------------------- the charge

export type Charge = {
  /** Seconds: light starts gathering (before the first frame, to open mid-charge), is fully charged (the squash starts), and fires. */
  from: number;
  full: number;
  fire: number;
  /** The lens's centre and the lamp tile's width, in world units. */
  lens: Point;
  size: number;
  unit: number;
  seed: string;
};

/** How far the charge has come, 0 to 1. */
export function chargeLevel(c: Charge, t: number): number {
  return clamp01((t - c.from) / (c.full - c.from));
}

/** 0 until the charge is full, then 1 by the time it fires: the lamp holding its breath. */
export function squashLevel(c: Charge, t: number): number {
  return clamp01((t - c.full) / (c.fire - c.full));
}

type Ray = { angle: number; rate: number; phase: number; spread: number };

/**
 * Light leaking round the lamp's tile from behind it: a glow and rays that grow as it charges,
 * draw in as it focuses, and flare once as it fires. Draw it behind the lamp: the lens itself is
 * never given a bright centre.
 */
export function backlight(ctx: CanvasRenderingContext2D, c: Charge, t: number) {
  if (t >= c.fire + 0.45) return;
  const { lens, size } = c;
  const p = chargeLevel(c, t);
  const focus = smoothstep(0.72, 1, p);
  const squash = squashLevel(c, t);
  const after = clamp01((t - c.fire) / 0.45);
  const flicker = 0.88 + 0.12 * Math.sin(t * 53) * Math.sin(t * 31);
  const strength = (0.15 + 0.85 * p * p) * (1 + 0.4 * squash) * (1 - after) ** 2 * flicker;
  const reach = size * (0.72 + 0.6 * p * p - 0.25 * focus - 0.15 * squash + 0.6 * after);
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  const corona = ctx.createRadialGradient(lens.x, lens.y, size * 0.3, lens.x, lens.y, reach);
  corona.addColorStop(0, rgba(filament, 0.95 * strength));
  corona.addColorStop(0.35, rgba(safelight, 0.7 * strength));
  corona.addColorStop(0.7, rgba(deep, 0.22 * strength));
  corona.addColorStop(1, rgba(deep, 0));
  ctx.fillStyle = corona;
  ctx.fillRect(lens.x - reach, lens.y - reach, reach * 2, reach * 2);

  const shine = smoothstep(0.05, 0.5, p) * (1 - 0.55 * focus) * (1 - squash);
  if (shine > 0) {
    for (const ray of rays(c.seed)) {
      const flick = 0.5 + 0.5 * Math.sin(t * ray.rate + ray.phase);
      const length = size * (0.5 + (0.35 + 0.6 * flick) * p * p * (1 - 0.4 * focus));
      const angle = ray.angle + t * 0.22;
      const tip = around(lens, length, angle);
      const fade = ctx.createLinearGradient(lens.x, lens.y, tip.x, tip.y);
      fade.addColorStop(0.3, rgba(filament, 0.55 * shine * flick));
      fade.addColorStop(0.6, rgba(safelight, 0.25 * shine * flick));
      fade.addColorStop(1, rgba(safelight, 0));
      ctx.fillStyle = fade;
      const left = around(lens, length, angle - ray.spread);
      const right = around(lens, length, angle + ray.spread);
      ctx.beginPath();
      ctx.moveTo(lens.x, lens.y);
      ctx.lineTo(left.x, left.y);
      ctx.lineTo(right.x, right.y);
      ctx.closePath();
      ctx.fill();
    }
  }

  // As it fires, a ring spreads out from behind the tile and the light behind it flares.
  const since = t - c.fire;
  if (since >= 0 && since < 0.5) {
    const k = since / 0.5;
    ctx.beginPath();
    ctx.arc(lens.x, lens.y, size * (0.5 + 1.2 * (1 - (1 - k) ** 3)), 0, Math.PI * 2);
    ctx.strokeStyle = rgba(filament, 0.55 * (1 - k) ** 2);
    ctx.lineWidth = (0.5 + 3 * (1 - k)) * c.unit;
    ctx.stroke();
    glow(ctx, lights().filament, lens, size * 1.1, 0.8 * clamp01(1 - since / 0.3) ** 2);
  }
  ctx.restore();
}

const rayCache = new Map<string, Ray[]>();

function rays(seed: string): Ray[] {
  let out = rayCache.get(seed);
  if (!out) {
    const r = random(`${seed}:rays`);
    out = Array.from({ length: 18 }, (_, i) => ({
      angle: (i / 18) * Math.PI * 2 + r.next() * 0.3,
      rate: 2 + r.next() * 4,
      phase: r.next() * Math.PI * 2,
      spread: 0.035 + r.next() * 0.045,
    }));
    rayCache.set(seed, out);
  }
  return out;
}

/** A mote's path: its radius and angle about the lens every `MOTE_STEP` seconds from its birth. */
type Mote = { born: number; width: number; colour: Colour; track: Float32Array };

const MOTE_STEP = 1 / 240;
const moteCache = new Map<string, Mote[]>();

/**
 * Motes of light that spiral in from around the lamp, faster and thicker as it charges, and rush
 * in once it's full. Their paths are worked out once per charge, step by step as the website moves
 * them each frame, so each frame only looks them up.
 */
function motesOf(c: Charge): Mote[] {
  const key = JSON.stringify(c);
  const cached = moteCache.get(key);
  if (cached) return cached;
  const r = random(`${c.seed}:motes`);
  const out: Mote[] = [];
  let owed = 0;
  for (let born = c.from; born < c.full; born += MOTE_STEP) {
    const p = chargeLevel(c, born);
    owed += (30 + 220 * p * p) * MOTE_STEP;
    for (; owed >= 1; owed -= 1) {
      const start = c.size * (0.75 + 0.85 * r.next());
      let angle = r.next() * Math.PI * 2;
      const spin = 1.2 + r.next() * 1.6;
      const pull = c.size * (0.35 + 0.5 * r.next());
      const width = (0.8 + r.next() * 1.4) * c.unit;
      const colour = r.next() < 0.55 ? filament : safelight;
      const track: number[] = [];
      let radius = start;
      for (let at = born; radius >= c.size * 0.3 && at < c.fire + 0.5; at += MOTE_STEP) {
        track.push(radius, angle);
        const level = chargeLevel(c, at);
        const urgency = (1 + 4 * level * level) * (at > c.full ? 5 : 1);
        radius -= pull * urgency * (1 + 2.2 * (1 - radius / start)) * MOTE_STEP;
        angle += spin * (1 + 2 * level) * MOTE_STEP;
      }
      out.push({ born, width, colour, track: Float32Array.from(track) });
    }
  }
  moteCache.set(key, out);
  return out;
}

/** Draws the motes at `t`, each as a short stroke along its last sixtieth of a second, doubled ahead. */
export function motes(ctx: CanvasRenderingContext2D, c: Charge, t: number) {
  if (t >= c.fire + 0.5) return;
  const p = chargeLevel(c, t);
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  ctx.lineCap = "round";
  for (const mote of motesOf(c)) {
    const age = t - mote.born;
    const now = moteAt(mote, age, c.lens);
    const was = moteAt(mote, age - 1 / 60, c.lens);
    if (!now || !was) continue;
    ctx.strokeStyle = rgba(mote.colour, Math.min(1, age / 0.2) * (0.35 + 0.65 * p));
    ctx.lineWidth = mote.width;
    ctx.beginPath();
    ctx.moveTo(was.x, was.y);
    ctx.lineTo(2 * now.x - was.x, 2 * now.y - was.y);
    ctx.stroke();
  }
  ctx.restore();
}

function moteAt(mote: Mote, age: number, lens: Point): Point | null {
  if (age < 0) return null;
  const at = age / MOTE_STEP;
  const i = Math.floor(at);
  if (2 * (i + 1) + 1 >= mote.track.length) return null;
  const k = at - i;
  const radius = mote.track[2 * i] + (mote.track[2 * i + 2] - mote.track[2 * i]) * k;
  const angle = mote.track[2 * i + 1] + (mote.track[2 * i + 3] - mote.track[2 * i + 1]) * k;
  return around(lens, radius, angle);
}

// ---------------------------------------------------------------- the shot

export type Path = { length: number; at: (along: number) => Point & { angle: number } };

/**
 * An arc from `from`, up and over, down into `to`, measured along its length. The target is above
 * the source, as the website's header is above its hero.
 */
export function arc(from: Point, to: Point): Path {
  const rise = from.y - to.y;
  const across = to.x - from.x;
  const c1 = { x: from.x + across * 0.1, y: from.y - rise * 1.25 };
  const c2 = { x: to.x - across * 0.3, y: to.y - Math.max(50, rise * 0.4) };
  const samples = 96;
  const points: Point[] = [];
  const lengths: number[] = [];
  for (let i = 0; i <= samples; i += 1) {
    const u = i / samples;
    const v = 1 - u;
    const point = {
      x: v * v * v * from.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * to.x,
      y: v * v * v * from.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * to.y,
    };
    lengths.push(i === 0 ? 0 : lengths[i - 1] + Math.hypot(point.x - points[i - 1].x, point.y - points[i - 1].y));
    points.push(point);
  }
  const length = lengths[samples];
  return {
    length,
    at(along) {
      const target = clamp01(along) * length;
      let low = 0;
      let high = samples;
      while (high - low > 1) {
        const middle = (low + high) >> 1;
        if (lengths[middle] < target) low = middle;
        else high = middle;
      }
      const a = points[low];
      const b = points[high];
      const k = (target - lengths[low]) / (lengths[high] - lengths[low] || 1);
      return { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, angle: Math.atan2(b.y - a.y, b.x - a.x) };
    },
  };
}

export type Shot = {
  path: Path;
  /** Seconds: it leaves, and it lands. */
  fire: number;
  hit: number;
  unit: number;
};

/** How far along the arc the shot's head is: it gathers speed into the target. */
export function headAt(shot: Shot, t: number): number {
  return clamp01((t - shot.fire) / (shot.hit - shot.fire)) ** 1.35;
}

/** The shot in flight: a beam about half the arc long, brightest at its head, which drains into the target once it lands. */
export function beam(ctx: CanvasRenderingContext2D, shot: Shot, t: number) {
  if (t < shot.fire) return;
  const head = headAt(shot, t);
  const drain = clamp01((t - shot.hit) / 0.3);
  const tail = t < shot.hit ? Math.max(0, head - 0.55) : 0.45 + 0.55 * drain * drain;
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  if (tail < 1) trail(ctx, shot, tail, head, t);
  if (t < shot.hit) {
    const point = shot.path.at(head);
    const appear = clamp01((t - shot.fire) / 0.06);
    const u = shot.unit;
    glow(ctx, lights().safelight, point, 46 * u, 0.35 * appear);
    glow(ctx, lights().filament, point, 20 * u, 0.85 * appear);
    glow(ctx, lights().hot, point, 8 * u, appear);
  }
  ctx.restore();
}

function trail(ctx: CanvasRenderingContext2D, shot: Shot, from: number, to: number, t: number) {
  const { path, unit: u } = shot;
  const span = to - from;
  if (span <= 0) return;
  const count = Math.max(2, Math.ceil((path.length * span) / (3.5 * u)));
  for (let i = 0; i <= count; i += 1) {
    const f = i / count;
    const point = path.at(from + span * f);
    glow(ctx, lights().safelight, point, (9 + 16 * f) * u, 0.13 * f ** 1.2);
    glow(ctx, lights().filament, point, (3 + 6 * f) * u, 0.32 * f ** 1.2);
  }
  ctx.lineCap = "butt";
  const pieces = 8;
  for (let j = 0; j < pieces; j += 1) {
    ctx.beginPath();
    for (let i = 0; i <= 6; i += 1) {
      const f = (j + i / 6) / pieces;
      const point = path.at(from + span * f);
      const crackle = (Math.sin(f * 41 + t * 47) + 0.5 * Math.sin(f * 97 - t * 71)) * 1.1 * f * u;
      const x = point.x - Math.sin(point.angle) * crackle;
      const y = point.y + Math.cos(point.angle) * crackle;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    const f = (j + 1) / pieces;
    ctx.strokeStyle = rgba(hot, 0.85 * f ** 1.4);
    ctx.lineWidth = (0.8 + 1.4 * f) * u;
    ctx.stroke();
  }
}

// ---------------------------------------------------------------- sparks

export type Spark = { born: number; x: number; y: number; vx: number; vy: number; life: number; width: number; fall: number };

/** Air resistance on a spark, per second, as on the website. */
const DRAG = 2.6;

/**
 * Adds `count` sparks born at `born` seconds, heading `heading` give or take half of `spread`
 * radians, with speeds and lives in the ranges given (website pixels per second, and seconds).
 */
export function burst(
  out: Spark[],
  r: Random,
  born: number,
  at: Point,
  heading: number,
  count: number,
  spread: number,
  speed: [number, number],
  life: [number, number],
  fall: number,
  unit: number,
) {
  for (let i = 0; i < count; i += 1) {
    const angle = heading + (r.next() - 0.5) * spread;
    const velocity = (speed[0] + r.next() * (speed[1] - speed[0])) * unit;
    out.push({
      born,
      x: at.x,
      y: at.y,
      vx: Math.cos(angle) * velocity,
      vy: Math.sin(angle) * velocity,
      life: life[0] + r.next() * (life[1] - life[0]),
      width: (1 + r.next() * 1.3) * unit,
      fall: fall * unit,
    });
  }
}

/** The sparks a shot sheds: a burst as it leaves, a trail from its head in flight, and the burst where it lands. */
export function shotSparks(shot: Shot, seed: string): Spark[] {
  const out: Spark[] = [];
  const { path, fire, hit, unit } = shot;
  const r = random(`${seed}:shot`);
  burst(out, r, fire, path.at(0), path.at(0.03).angle, 24, 2.4, [180, 520], [0.3, 0.6], 700, unit);
  for (let born = fire; born < hit; born += 1 / 260) {
    const point = path.at(headAt(shot, born));
    burst(out, r, born, point, point.angle + Math.PI, 1, 2.2, [60, 220], [0.25, 0.55], 500, unit);
  }
  const end = path.at(1);
  burst(out, r, hit, end, path.at(0.98).angle, 34, 2.4, [160, 560], [0.4, 0.9], 900, unit);
  burst(out, r, hit, end, 0, 18, Math.PI * 2, [120, 360], [0.35, 0.7], 900, unit);
  return out;
}

/** Draws the sparks alive at `t`. They slow in the air and fall, cooling from white to filament to red as they fade. */
export function sparks(ctx: CanvasRenderingContext2D, list: Spark[], t: number) {
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  ctx.lineCap = "round";
  for (const spark of list) {
    const age = t - spark.born;
    if (age < 0 || age >= spark.life) continue;
    const decay = Math.exp(-DRAG * age);
    const settle = spark.fall / DRAG;
    const vx = spark.vx * decay;
    const vy = spark.vy * decay + settle * (1 - decay);
    const x = spark.x + (spark.vx * (1 - decay)) / DRAG;
    const y = spark.y + ((spark.vy - settle) * (1 - decay)) / DRAG + settle * age;
    const k = age / spark.life;
    ctx.strokeStyle = rgba(k < 0.3 ? hot : k < 0.65 ? filament : safelight, 0.95 * (1 - k));
    ctx.lineWidth = spark.width * (1 - 0.5 * k);
    ctx.beginPath();
    ctx.moveTo(x - vx * 0.022, y - vy * 0.022);
    ctx.lineTo(x, y);
    ctx.stroke();
  }
  ctx.restore();
}

// ---------------------------------------------------------------- where it lands

/** A pill, by its centre and size in world units, as the target is drawn at that moment. */
export type Pill = { x: number; y: number; width: number; height: number };

/**
 * Where the shot lands, `since` seconds after: a flash, a ring spreading off the pill, and two
 * lights chasing each other round its edge as it settles.
 */
export function strike(ctx: CanvasRenderingContext2D, pill: Pill, since: number, unit: number) {
  if (since < 0 || since >= 1.45) return;
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  const middle = { x: pill.x, y: pill.y };
  if (since < 0.35) {
    const k = since / 0.35;
    glow(ctx, lights().filament, middle, (70 + 30 * k) * unit, 0.85 * (1 - k) ** 2);
    glow(ctx, lights().hot, middle, 26 * unit, (1 - k) ** 3);
  }
  if (since < 0.55) {
    const k = since / 0.55;
    outline(ctx, pill, 24 * (1 - (1 - k) ** 2) * unit);
    ctx.strokeStyle = rgba(filament, 0.7 * (1 - k) ** 2);
    ctx.lineWidth = (0.5 + 2 * (1 - k)) * unit;
    ctx.stroke();
  }
  aura(ctx, pill, since, since / 1.45, unit);
  ctx.restore();
}

/**
 * Two lights chasing each other clockwise round a pill, each with its tail behind it, at 1.15
 * turns a second. `k` runs 0 to 1 over the aura's life: it comes up quickly and fades from 0.4.
 */
export function aura(ctx: CanvasRenderingContext2D, pill: Pill, since: number, k: number, unit: number) {
  const strength = k < 0.06 ? k / 0.06 : 1 - smoothstep(0.4, 1, k);
  if (strength <= 0) return;
  const chase = ctx.createConicGradient(since * Math.PI * 2 * 1.15, pill.x, pill.y);
  chase.addColorStop(0, rgba(hot, 1));
  chase.addColorStop(0.03, rgba(filament, 0));
  chase.addColorStop(0.3, rgba(safelight, 0));
  chase.addColorStop(0.5, rgba(filament, 0.9));
  chase.addColorStop(0.53, rgba(filament, 0));
  chase.addColorStop(0.8, rgba(safelight, 0));
  chase.addColorStop(1, rgba(hot, 1));
  outline(ctx, pill, 3 * unit);
  ctx.strokeStyle = chase;
  ctx.globalAlpha = strength;
  ctx.lineWidth = 2 * unit;
  ctx.stroke();
  ctx.globalAlpha = strength * 0.35;
  ctx.lineWidth = 7 * unit;
  ctx.stroke();
  ctx.globalAlpha = 1;
}

/** A ring of light spreading from a point, as where a click lands. */
export function ripple(ctx: CanvasRenderingContext2D, at: Point, since: number, radius: number, unit: number) {
  if (since < 0 || since >= 0.6) return;
  const k = since / 0.6;
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  ctx.beginPath();
  ctx.arc(at.x, at.y, radius * (0.2 + 0.8 * (1 - (1 - k) ** 3)), 0, Math.PI * 2);
  ctx.strokeStyle = rgba(filament, 0.8 * (1 - k) ** 2);
  ctx.lineWidth = (0.6 + 2.4 * (1 - k)) * unit;
  ctx.stroke();
  glow(ctx, lights().filament, at, radius * 0.9, 0.6 * (1 - k) ** 3);
  ctx.restore();
}

/** A soft light of `radius`, as the light falls on the wall round a source. */
export function pool(ctx: CanvasRenderingContext2D, at: Point, radius: number, alpha: number, colour: "safelight" | "filament" = "safelight") {
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  glow(ctx, lights()[colour], at, radius, alpha);
  ctx.restore();
}

// ---------------------------------------------------------------- helpers

function outline(ctx: CanvasRenderingContext2D, pill: Pill, pad: number) {
  const height = pill.height + pad * 2;
  ctx.beginPath();
  ctx.roundRect(pill.x - pill.width / 2 - pad, pill.y - pill.height / 2 - pad, pill.width + pad * 2, height, height / 2);
}

function spot(colour: Colour): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = 256;
  canvas.height = 256;
  const ctx = canvas.getContext("2d");
  if (ctx) {
    const fall = ctx.createRadialGradient(128, 128, 0, 128, 128, 128);
    fall.addColorStop(0, rgba(colour, 1));
    fall.addColorStop(0.25, rgba(colour, 0.55));
    fall.addColorStop(0.6, rgba(colour, 0.14));
    fall.addColorStop(1, rgba(colour, 0));
    ctx.fillStyle = fall;
    ctx.fillRect(0, 0, 256, 256);
  }
  return canvas;
}

function glow(ctx: CanvasRenderingContext2D, image: HTMLCanvasElement, at: Point, radius: number, alpha: number) {
  if (alpha <= 0 || radius <= 0) return;
  const before = ctx.globalAlpha;
  ctx.globalAlpha = Math.min(alpha, 1);
  ctx.drawImage(image, at.x - radius, at.y - radius, radius * 2, radius * 2);
  ctx.globalAlpha = before;
}

export function rgba([r, g, b]: Colour, alpha: number): string {
  return `rgba(${r},${g},${b},${clamp01(alpha)})`;
}

export function around(origin: Point, radius: number, angle: number): Point {
  return { x: origin.x + Math.cos(angle) * radius, y: origin.y + Math.sin(angle) * radius };
}

export function clamp01(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}

export function smoothstep(edge0: number, edge1: number, value: number): number {
  const k = clamp01((value - edge0) / (edge1 - edge0));
  return k * k * (3 - 2 * k);
}

/** Eases between [time, value] stops, coming to rest at each unless given another easing. */
export function keyframes(time: number, stops: [number, number][], easing?: (k: number) => number): number {
  if (time <= stops[0][0]) return stops[0][1];
  for (let i = 1; i < stops.length; i += 1) {
    const [end, to] = stops[i];
    if (time <= end) {
      const [start, from] = stops[i - 1];
      const k = easing ? easing(clamp01((time - start) / (end - start))) : smoothstep(start, end, time);
      return from + (to - from) * k;
    }
  }
  return stops[stops.length - 1][1];
}
