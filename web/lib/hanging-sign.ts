/**
 * A sign hanging from a rope, for the home page's star nudge (components/site/StarNudge.tsx). The rope
 * is a chain of light point masses that resists stretching but not bending; the sign is a rigid frame
 * of its four corners and the eyelet the rope is tied to, so it turns as it swings and as it's dragged.
 * Stepped with small-step position-based dynamics (Macklin et al., "Small Steps in Physics
 * Simulation", 2019), with long-range attachments (Kim, Chentanez and Müller, "Long Range
 * Attachments", 2012) so the rope never stretches past its length. Units are CSS pixels and seconds,
 * with y pointing down.
 */

export type Point = { x: number; y: number };

export type Shape = {
  /** Where the rope is tied. */
  anchor: Point;
  ropeLength: number;
  width: number;
  height: number;
  /** How far below the sign's top edge the rope is tied. */
  eyelet: number;
};

/** Where the sign starts: its eyelet, its rotation and its velocity. The rope runs straight to the eyelet. */
export type Start = { eyelet: Point; angle?: number; velocity?: Point };

/** The sign's centre, and its rotation in radians, clockwise on screen. */
export type Pose = { x: number; y: number; angle: number };

const gravity = 3200;
const substep = 1 / 720;
const iterations = 2;
const segments = 8;
const ropeMass = 0.02;
/** The sign's corners and its eyelet weigh this each. */
const signMass = 0.2;
/** Air resistance, per second: the rope settles before the sign does. */
const ropeDrag = 4;
const signDrag = 1.1;
/** At most this much time is caught up in one step, so a tab coming back from the background doesn't lurch. */
const catchUp = 0.05;

type Mass = { x: number; y: number; px: number; py: number; vx: number; vy: number; w: number; drag: number };
/** `rope` links go slack rather than push; the sign's links hold their length both ways. */
type Link = { a: number; b: number; rest: number; rope: boolean };
/** A drag: the held point's weights over the corners, how far from the anchor it can go, and the pointer's last two positions. */
type Grip = { weights: number[]; reach: number; from: Point; to: Point };

/** Masses: the anchor, the rope's points, then the eyelet and the corners from the top left, clockwise. */
const eyelet = segments;
const corners = [segments + 1, segments + 2, segments + 3, segments + 4];

export class HangingSign {
  private readonly shape: Shape;
  private readonly masses: Mass[] = [];
  private readonly links: Link[] = [];
  private segment: number;
  private grip: Grip | null = null;
  private pending = 0;
  private quiet = 0;

  constructor(shape: Shape, start: Start = { eyelet: { x: shape.anchor.x, y: shape.anchor.y + shape.ropeLength } }) {
    this.shape = shape;
    this.segment = shape.ropeLength / segments;
    const angle = start.angle ?? 0;
    const velocity = start.velocity ?? { x: 0, y: 0 };
    const frame = this.frame();
    const centre = minus(start.eyelet, rotate(frame[0], angle));
    this.masses.push(mass(shape.anchor, 0, 0, { x: 0, y: 0 }));
    for (let i = 1; i < segments; i += 1) {
      const along = i / segments;
      const at = { x: lerp(shape.anchor.x, start.eyelet.x, along), y: lerp(shape.anchor.y, start.eyelet.y, along) };
      this.masses.push(mass(at, 1 / ropeMass, ropeDrag, { x: velocity.x * along, y: velocity.y * along }));
    }
    for (const local of frame) this.masses.push(mass(plus(centre, rotate(local, angle)), 1 / signMass, signDrag, velocity));
    for (let i = 0; i < segments; i += 1) this.links.push({ a: i, b: i + 1, rest: this.segment, rope: true });
    const body = [eyelet, ...corners];
    for (let i = 0; i < body.length; i += 1) {
      for (let j = i + 1; j < body.length; j += 1) {
        this.links.push({ a: body[i], b: body[j], rest: distance(frame[i], frame[j]), rope: false });
      }
    }
  }

  /** Advances the simulation by `dt` seconds, in fixed steps. */
  step(dt: number): void {
    this.pending = Math.min(this.pending + dt, catchUp);
    const count = Math.floor(this.pending / substep);
    this.pending -= count * substep;
    const grip = this.grip;
    for (let k = 1; k <= count; k += 1) {
      // The pointer moves once a frame; spreading that over the frame's steps keeps the sign's speed even.
      this.advance(grip ? { x: lerp(grip.from.x, grip.to.x, k / count), y: lerp(grip.from.y, grip.to.y, k / count) } : null);
    }
    if (grip && count > 0) grip.from = grip.to;
    let fastest = 0;
    for (const m of this.masses) fastest = Math.max(fastest, m.vx * m.vx + m.vy * m.vy);
    this.quiet = !this.grip && fastest < 4 ? this.quiet + dt : 0;
  }

  /** Takes hold of the sign at a point on it, which then follows `drag` until `release`. */
  grab(point: Point): void {
    const pose = this.pose;
    const local = rotate(minus(point, pose), -pose.angle);
    const u = clamp(local.x / this.shape.width + 0.5);
    const v = clamp(local.y / this.shape.height + 0.5);
    const weights = [(1 - u) * (1 - v), u * (1 - v), u * v, (1 - u) * v];
    const held = { x: (u - 0.5) * this.shape.width, y: (v - 0.5) * this.shape.height };
    const at = { x: 0, y: 0 };
    corners.forEach((index, i) => {
      at.x += weights[i] * this.masses[index].x;
      at.y += weights[i] * this.masses[index].y;
    });
    this.grip = { weights, reach: this.segment * segments + distance(held, this.frame()[0]), from: at, to: at };
    this.quiet = 0;
  }

  /** Moves the held point towards `point`, as far as the rope reaches. */
  drag(point: Point): void {
    const grip = this.grip;
    if (!grip) return;
    const anchor = this.masses[0];
    const offset = minus(point, anchor);
    const length = Math.hypot(offset.x, offset.y);
    const most = grip.reach * 0.995;
    grip.to = length > most ? plus(anchor, { x: (offset.x * most) / length, y: (offset.y * most) / length }) : { ...point };
  }

  /** Lets go: the sign keeps the speed the drag gave it. */
  release(): void {
    this.grip = null;
    this.quiet = 0;
  }

  get held(): boolean {
    return this.grip !== null;
  }

  /** Moves the rope's anchor, as when the window is resized. */
  moveAnchor(anchor: Point): void {
    const m = this.masses[0];
    if (m.x === anchor.x && m.y === anchor.y) return;
    m.x = m.px = anchor.x;
    m.y = m.py = anchor.y;
    this.quiet = 0;
  }

  /** Lengthens or shortens the rope, drawing the sign up or letting it down. */
  setRopeLength(length: number): void {
    this.segment = Math.max(length, 0) / segments;
    for (const link of this.links) if (link.rope) link.rest = this.segment;
    this.quiet = 0;
  }

  get pose(): Pose {
    const [tl, tr, br, bl] = corners.map((index) => this.masses[index]);
    return {
      x: (tl.x + tr.x + br.x + bl.x) / 4,
      y: (tl.y + tr.y + br.y + bl.y) / 4,
      angle: Math.atan2(tr.y - tl.y + br.y - bl.y, tr.x - tl.x + br.x - bl.x),
    };
  }

  /** The rope from the anchor to the eyelet. */
  get rope(): Point[] {
    return this.masses.slice(0, eyelet + 1).map(({ x, y }) => ({ x, y }));
  }

  /** True once nothing has moved for half a second and no one is holding the sign. */
  get resting(): boolean {
    return this.quiet > 0.5;
  }

  /** The eyelet and the corners, from the top left and clockwise, about the sign's centre. */
  private frame(): Point[] {
    const { width: w, height: h } = this.shape;
    return [
      { x: 0, y: -h / 2 + this.shape.eyelet },
      { x: -w / 2, y: -h / 2 },
      { x: w / 2, y: -h / 2 },
      { x: w / 2, y: h / 2 },
      { x: -w / 2, y: h / 2 },
    ];
  }

  private advance(target: Point | null): void {
    for (const m of this.masses) {
      if (m.w === 0) continue;
      const keep = Math.exp(-m.drag * substep);
      m.vx *= keep;
      m.vy = m.vy * keep + gravity * substep;
      m.px = m.x;
      m.py = m.y;
      m.x += m.vx * substep;
      m.y += m.vy * substep;
    }
    for (let pass = 0; pass < iterations; pass += 1) {
      if (target) this.hold(target);
      const last = this.links.length - 1;
      for (let n = 0; n <= last; n += 1) this.solve(this.links[pass % 2 === 0 ? n : last - n]);
      this.attach();
    }
    for (const m of this.masses) {
      if (m.w === 0) continue;
      m.vx = (m.x - m.px) / substep;
      m.vy = (m.y - m.py) / substep;
    }
  }

  private solve(link: Link): void {
    const a = this.masses[link.a];
    const b = this.masses[link.b];
    const w = a.w + b.w;
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = Math.hypot(dx, dy);
    const stretch = length - link.rest;
    if (w === 0 || length < 1e-9 || (link.rope && stretch <= 0)) return;
    const k = stretch / (length * w);
    a.x += dx * k * a.w;
    a.y += dy * k * a.w;
    b.x -= dx * k * b.w;
    b.y -= dy * k * b.w;
  }

  /** Keeps each point of the rope, and the eyelet, within the rope's length of the anchor. */
  private attach(): void {
    const anchor = this.masses[0];
    for (let i = 1; i <= eyelet; i += 1) {
      const m = this.masses[i];
      const dx = m.x - anchor.x;
      const dy = m.y - anchor.y;
      const length = Math.hypot(dx, dy);
      const most = i * this.segment;
      if (length > most) {
        m.x = anchor.x + (dx * most) / length;
        m.y = anchor.y + (dy * most) / length;
      }
    }
  }

  /** Puts the held point on the pointer, moving each corner by how much of the point it carries. */
  private hold(target: Point): void {
    const weights = this.grip?.weights;
    if (!weights) return;
    let x = 0;
    let y = 0;
    let w = 0;
    corners.forEach((index, i) => {
      const m = this.masses[index];
      x += weights[i] * m.x;
      y += weights[i] * m.y;
      w += weights[i] * weights[i] * m.w;
    });
    const dx = target.x - x;
    const dy = target.y - y;
    corners.forEach((index, i) => {
      const m = this.masses[index];
      const k = (weights[i] * m.w) / w;
      m.x += dx * k;
      m.y += dy * k;
    });
  }
}

function mass(at: Point, w: number, drag: number, velocity: Point): Mass {
  return { x: at.x, y: at.y, px: at.x, py: at.y, vx: velocity.x, vy: velocity.y, w, drag };
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

function clamp(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}

function plus(a: Point, b: Point): Point {
  return { x: a.x + b.x, y: a.y + b.y };
}

function minus(a: Point, b: Point): Point {
  return { x: a.x - b.x, y: a.y - b.y };
}

function rotate(p: Point, angle: number): Point {
  const cos = Math.cos(angle);
  const sin = Math.sin(angle);
  return { x: p.x * cos - p.y * sin, y: p.x * sin + p.y * cos };
}

function distance(a: Point, b: Point): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}
