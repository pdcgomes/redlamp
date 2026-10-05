"use client";

import { useEffect, useRef, useState } from "react";
import { StarGlyph } from "@/components/ui/Buttons";
import { HangingSign, type Point } from "@/lib/hanging-sign";
import { site } from "@/lib/site";

const playedKey = "redlamp.star-nudge";

// The sequence, in seconds from its start.
const charge = 2.4;
const fire = charge + 0.12;
const hit = fire + 0.62;
const drop = hit + 1.15;
const settled = hit + 1.45;

/** The eyelet's centre is this far below the sign's top edge, as the sign's markup draws it. */
const eyelet = 9;

type Colour = readonly [number, number, number];
const safelight: Colour = [224, 64, 46];
const deep: Colour = [154, 28, 20];
const filament: Colour = [255, 176, 138];
const hot: Colour = [255, 240, 230];

/** What the nudge moves and lights, marked with data-star-nudge in Hero.tsx and SiteHeader.tsx. */
type Parts = {
  lamp: HTMLElement;
  icon: HTMLImageElement;
  glow: HTMLElement | null;
  button: HTMLElement;
  star: HTMLElement | null;
  header: HTMLElement | null;
};

type Overlay = { canvas: HTMLCanvasElement; layer: HTMLDivElement; sign: HTMLAnchorElement; rope: SVGPathElement };

/**
 * Points visitors at the GitHub star, once per tab: energy gathers behind the hero's lamp while it
 * trembles harder and harder, shoots in an arc into the header's GitHub button, which glows and
 * settles, and a sign drops from under the button on a rope, to be dragged and thrown.
 */
export function StarNudge() {
  const [playing, setPlaying] = useState(false);
  const canvas = useRef<HTMLCanvasElement>(null);
  const layer = useRef<HTMLDivElement>(null);
  const sign = useRef<HTMLAnchorElement>(null);
  const rope = useRef<SVGPathElement>(null);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || played()) return;
    let timer: number | undefined;
    const schedule = () => {
      if (document.visibilityState !== "visible" || timer !== undefined) return;
      timer = window.setTimeout(() => {
        const parts = findParts();
        if (!parts || !inView(parts)) return;
        remember();
        setPlaying(true);
      }, 1500);
    };
    schedule();
    document.addEventListener("visibilitychange", schedule);
    return () => {
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", schedule);
    };
  }, []);

  useEffect(() => {
    if (!playing) return;
    const parts = findParts();
    if (!parts || !canvas.current || !layer.current || !sign.current || !rope.current) return;
    const overlay = { canvas: canvas.current, layer: layer.current, sign: sign.current, rope: rope.current };
    const end = () => setPlaying(false);
    const stops: (() => void)[] = [];
    stops.push(play(overlay.canvas, parts, () => stops.push(hang(overlay, parts, end)), end));
    return () => {
      for (const stop of stops) stop();
    };
  }, [playing]);

  if (!playing) return null;
  return (
    <>
      <div ref={layer} className="pointer-events-none fixed inset-0 z-30 overflow-hidden">
        <a
          ref={sign}
          href={site.github}
          draggable={false}
          style={{ visibility: "hidden" }}
          className="pointer-events-auto absolute top-0 left-0 flex cursor-grab touch-none items-center gap-1.5 rounded-lg bg-linear-to-br from-paper to-ring px-3.5 pt-[17px] pb-2 text-[14px] leading-5 font-semibold whitespace-nowrap text-ink shadow-[0_14px_30px_rgb(0_0_0/0.45)] select-none [-webkit-touch-callout:none]"
        >
          <span
            aria-hidden
            className="absolute top-[5px] left-1/2 size-2 -translate-x-1/2 rounded-full bg-wall ring-1 ring-steel"
          />
          <StarGlyph />
          Please star us!
        </a>
        <svg aria-hidden className="absolute inset-0 size-full">
          <path ref={rope} className="fill-none stroke-ring/70" strokeWidth={1.5} strokeLinecap="round" />
        </svg>
      </div>
      <canvas ref={canvas} aria-hidden className="pointer-events-none fixed inset-0 z-50 size-full" />
    </>
  );
}

function played(): boolean {
  try {
    return sessionStorage.getItem(playedKey) !== null;
  } catch {
    return true;
  }
}

function remember() {
  try {
    sessionStorage.setItem(playedKey, "1");
  } catch {
    // played() treats storage it can't read as already played.
  }
}

function findParts(): Parts | null {
  const lamp = document.querySelector<HTMLElement>('[data-star-nudge="lamp"]');
  const icon = lamp?.querySelector("img");
  const button = document.querySelector<HTMLElement>('[data-star-nudge="button"]');
  if (!lamp || !icon?.complete || !icon.naturalWidth || !button?.offsetWidth) return null;
  return {
    lamp,
    icon,
    glow: lamp.querySelector<HTMLElement>('[data-star-nudge="glow"]'),
    button,
    star: button.querySelector<HTMLElement>('[data-star-nudge="star"]'),
    header: button.closest("header"),
  };
}

/** The whole lamp is on screen, below the header. */
function inView(parts: Parts): boolean {
  const lamp = parts.lamp.getBoundingClientRect();
  return lamp.top >= (parts.header?.getBoundingClientRect().bottom ?? 0) && lamp.bottom <= window.innerHeight;
}

// ---------------------------------------------------------------- the charge, the shot and the aura

type Mote = { radius: number; start: number; angle: number; spin: number; pull: number; age: number; width: number; colour: Colour };
type Spark = { x: number; y: number; vx: number; vy: number; age: number; life: number; width: number; fall: number };
type Ray = { angle: number; rate: number; phase: number; spread: number };
type Path = { length: number; at: (along: number) => Point & { angle: number } };
type Lights = Record<"safelight" | "filament" | "hot", HTMLCanvasElement>;

/**
 * Runs the sequence on a canvas over the page. Calls `onDrop` when the sign is due, or `onEnd`
 * instead if the lamp has been scrolled out of view by the time it would fire.
 */
function play(canvas: HTMLCanvasElement, parts: Parts, onDrop: () => void, onEnd: () => void): () => void {
  const context = canvas.getContext("2d");
  if (!context) {
    onEnd();
    return () => {};
  }
  const ctx = context;
  const lights: Lights = { safelight: spot(safelight), filament: spot(filament), hot: spot(hot) };
  const rays: Ray[] = Array.from({ length: 18 }, (_, i) => ({
    angle: (i / 18) * Math.PI * 2 + Math.random() * 0.3,
    rate: 2 + Math.random() * 4,
    phase: Math.random() * Math.PI * 2,
    spread: 0.035 + Math.random() * 0.045,
  }));
  const motes: Mote[] = [];
  const sparks: Spark[] = [];
  const animations: Animation[] = [];
  let width = 0;
  let height = 0;
  let density = 1;
  let time = 0;
  let last = 0;
  let frame = 0;
  let owed = 0;
  let phase = 0;
  let path: Path | null = null;
  let struck = false;
  let dropped = false;

  const fit = () => {
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    if (canvas.clientWidth === width && canvas.clientHeight === height && scale === density) return;
    width = canvas.clientWidth;
    height = canvas.clientHeight;
    density = scale;
    canvas.width = Math.round(width * density);
    canvas.height = Math.round(height * density);
  };

  const restore = () => {
    parts.icon.style.transform = "";
    parts.icon.style.filter = "";
    if (parts.glow) parts.glow.style.transform = "";
  };

  const finish = () => {
    cancelAnimationFrame(frame);
    frame = 0;
    restore();
    canvas.style.display = "none";
  };

  /** Motes of light spiral in from around the lamp, faster and thicker as it charges. */
  const gather = (lens: Point, size: number, dt: number) => {
    const p = clamp01(time / charge);
    if (time < charge) {
      owed += (30 + 220 * p * p) * dt;
      for (; owed >= 1; owed -= 1) {
        const start = size * (0.75 + 0.85 * Math.random());
        motes.push({
          radius: start,
          start,
          angle: Math.random() * Math.PI * 2,
          spin: 1.2 + Math.random() * 1.6,
          pull: size * (0.35 + 0.5 * Math.random()),
          age: 0,
          width: 0.8 + Math.random() * 1.4,
          colour: Math.random() < 0.55 ? filament : safelight,
        });
      }
    }
    const urgency = (1 + 4 * p * p) * (time > charge ? 5 : 1);
    ctx.lineCap = "round";
    for (let i = motes.length - 1; i >= 0; i -= 1) {
      const mote = motes[i];
      const was = around(lens, mote.radius, mote.angle);
      mote.age += dt;
      mote.radius -= mote.pull * urgency * (1 + 2.2 * (1 - mote.radius / mote.start)) * dt;
      mote.angle += mote.spin * (1 + 2 * p) * dt;
      if (mote.radius < size * 0.3) {
        motes.splice(i, 1);
        continue;
      }
      const now = around(lens, mote.radius, mote.angle);
      ctx.strokeStyle = rgba(mote.colour, Math.min(1, mote.age / 0.2) * (0.35 + 0.65 * p));
      ctx.lineWidth = mote.width;
      ctx.beginPath();
      ctx.moveTo(was.x, was.y);
      ctx.lineTo(2 * now.x - was.x, 2 * now.y - was.y);
      ctx.stroke();
    }
  };

  const strike = (at: Point, heading: number) => {
    burst(sparks, at, heading, 34, 2.4, [160, 560], [0.4, 0.9], 900);
    burst(sparks, at, 0, 18, Math.PI * 2, [120, 360], [0.35, 0.7], 900);
    const halo = (a: number) =>
      `0 0 0 1px rgb(255 176 138 / ${0.85 * a}), 0 0 18px 3px rgb(224 64 46 / ${0.7 * a}), 0 0 46px 12px rgb(224 64 46 / ${0.35 * a})`;
    const spring = "cubic-bezier(0.33, 1, 0.68, 1)";
    animations.push(
      parts.button.animate(
        [
          { transform: "scale(1)", boxShadow: halo(0), borderColor: "rgb(243 238 232 / 0.16)", easing: spring },
          { transform: "scale(1.15)", boxShadow: halo(1), borderColor: "rgb(255 176 138 / 0.95)", offset: 0.07, easing: spring },
          { transform: "scale(0.96)", offset: 0.2, easing: spring },
          { transform: "scale(1.04)", offset: 0.34, easing: spring },
          { transform: "scale(0.995)", offset: 0.48, easing: spring },
          { transform: "scale(1)", boxShadow: halo(0.5), borderColor: "rgb(255 176 138 / 0.55)", offset: 0.62 },
          { transform: "scale(1)", boxShadow: halo(0), borderColor: "rgb(243 238 232 / 0.16)" },
        ],
        { duration: 1700 },
      ),
    );
    const glyph = parts.star?.querySelector("svg");
    if (glyph) {
      animations.push(
        glyph.animate(
          [
            { transform: "scale(1) rotate(0deg)" },
            {
              transform: "scale(1.9) rotate(200deg)",
              color: "#ffb08a",
              filter: "drop-shadow(0 0 6px rgb(255 176 138 / 0.9))",
              offset: 0.35,
            },
            { transform: "scale(1) rotate(360deg)", color: "#ffb08a", offset: 0.75 },
            { transform: "scale(1) rotate(360deg)" },
          ],
          { duration: 1200, delay: 80, easing: "cubic-bezier(0.22, 1, 0.36, 1)" },
        ),
      );
    }
  };

  const tick = (now: number) => {
    const dt = last ? Math.min((now - last) / 1000, 1 / 20) : 0;
    last = now;
    time += dt;
    fit();
    ctx.setTransform(density, 0, 0, density, 0, 0);
    ctx.clearRect(0, 0, width, height);
    const box = parts.lamp.getBoundingClientRect();
    const size = box.width;
    const lens = { x: box.left + box.width / 2, y: box.top + box.height / 2 };

    if (time >= fire && !path) {
      if (!inView(parts)) {
        finish();
        onEnd();
        return;
      }
      // The shot leaves from behind the tile's top edge, so it never crosses the lens.
      const target = centre(parts.button.getBoundingClientRect());
      const start = { x: lens.x + Math.sign(target.x - lens.x) * size * 0.12, y: box.top + size * 0.1 };
      path = arc(start, target);
      burst(sparks, start, path.at(0.03).angle, 24, 2.4, [180, 520], [0.3, 0.6], 700);
    }

    phase += Math.PI * 2 * (6 + 20 * clamp01(time / charge)) * dt;
    const pose = lampPose(time, phase);
    if (pose) {
      parts.icon.style.transform = `translate(${pose.x}px, ${pose.y}px) rotate(${pose.angle}rad) scale(${pose.scale})`;
      parts.icon.style.filter = `brightness(${pose.bright})`;
    } else if (parts.icon.style.transform) {
      restore();
    }
    if (parts.glow && time < fire + 0.9) {
      const grown = keyframes(time, [[0, 1], [charge, 1.45], [fire, 1.3], [fire + 0.12, 1.8], [fire + 0.9, 1]]);
      parts.glow.style.transform = `scale(${Math.min(grown, (window.innerWidth - 8) / parts.glow.offsetWidth)})`;
    } else if (parts.glow?.style.transform) {
      parts.glow.style.transform = "";
    }

    // Behind the lamp: everything drawn here is cut away wherever the icon is, and kept off the header.
    if (time < fire + 0.5) {
      ctx.save();
      const top = parts.header?.getBoundingClientRect().bottom ?? 0;
      ctx.beginPath();
      ctx.rect(0, top, width, height - top);
      ctx.clip();
      ctx.globalCompositeOperation = "lighter";
      backlight(ctx, rays, lens, size, time);
      gather(lens, size, dt);
      const since = time - fire;
      if (since >= 0 && since < 0.5) {
        const k = since / 0.5;
        ctx.beginPath();
        ctx.arc(lens.x, lens.y, size * (0.5 + 1.2 * (1 - (1 - k) ** 3)), 0, Math.PI * 2);
        ctx.strokeStyle = rgba(filament, 0.55 * (1 - k) ** 2);
        ctx.lineWidth = 0.5 + 3 * (1 - k);
        ctx.stroke();
        glow(ctx, lights.filament, lens, size * 1.1, 0.8 * clamp01(1 - since / 0.3) ** 2);
      }
      ctx.globalCompositeOperation = "destination-out";
      ctx.translate(lens.x + (pose?.x ?? 0), lens.y + (pose?.y ?? 0));
      ctx.rotate(pose?.angle ?? 0);
      ctx.scale(pose?.scale ?? 1, pose?.scale ?? 1);
      ctx.drawImage(parts.icon, -size / 2, -size / 2, size, size);
      ctx.restore();
    }

    ctx.globalCompositeOperation = "lighter";
    if (path) {
      const since = time - fire;
      const head = clamp01(since / (hit - fire)) ** 1.35;
      const drain = clamp01((time - hit) / 0.3);
      const tail = time < hit ? Math.max(0, head - 0.55) : 0.45 + 0.55 * drain * drain;
      if (tail < 1) beam(ctx, lights, path, tail, head, time);
      if (time < hit) {
        const point = path.at(head);
        const appear = clamp01(since / 0.06);
        glow(ctx, lights.safelight, point, 46, 0.35 * appear);
        glow(ctx, lights.filament, point, 20, 0.85 * appear);
        glow(ctx, lights.hot, point, 8, appear);
        burst(sparks, point, point.angle + Math.PI, Math.round(260 * dt + Math.random()), 2.2, [60, 220], [0.25, 0.55], 500);
      } else if (!struck) {
        struck = true;
        strike(path.at(1), path.at(0.98).angle);
      }
    }

    if (struck) {
      const since = time - hit;
      const button = parts.button.getBoundingClientRect();
      const middle = centre(button);
      if (since < 0.35) {
        const k = since / 0.35;
        glow(ctx, lights.filament, middle, 70 + 30 * k, 0.85 * (1 - k) ** 2);
        glow(ctx, lights.hot, middle, 26, (1 - k) ** 3);
      }
      if (since < 0.55) {
        const k = since / 0.55;
        pill(ctx, button, 24 * (1 - (1 - k) ** 2));
        ctx.strokeStyle = rgba(filament, 0.7 * (1 - k) ** 2);
        ctx.lineWidth = 0.5 + 2 * (1 - k);
        ctx.stroke();
      }
      if (since < 1.45) aura(ctx, button, since);
    }

    fly(ctx, sparks, dt);

    if (!dropped && time >= drop) {
      dropped = true;
      onDrop();
    }
    if (dropped && time >= settled && sparks.length === 0) {
      finish();
      return;
    }
    frame = requestAnimationFrame(tick);
  };

  frame = requestAnimationFrame(tick);
  return () => {
    cancelAnimationFrame(frame);
    for (const animation of animations) animation.cancel();
    restore();
  };
}

type LampPose = { x: number; y: number; angle: number; scale: number; bright: number };

/** The lamp trembles harder and faster as it charges, squashes, then recoils from the shot. */
function lampPose(time: number, phase: number): LampPose | null {
  if (time < fire) {
    const p = clamp01(time / charge);
    const squash = clamp01((time - charge) / (fire - charge));
    const shake = p ** 2.2 * (1 - squash);
    return {
      x: 3.4 * shake * (0.62 * Math.sin(phase) + 0.38 * Math.sin(phase * 2.37 + 1.3)),
      y: 3.4 * shake * (0.62 * Math.sin(phase * 1.13 + 2.1) + 0.38 * Math.sin(phase * 2.71 + 0.4)),
      angle: 0.045 * shake * Math.sin(phase * 0.91 + 0.7),
      scale: 1 + 0.035 * p * p - 0.095 * squash * (2 - squash),
      bright: 1 + 0.3 * p * p + 0.3 * squash,
    };
  }
  const since = time - fire;
  if (since >= 0.8) return null;
  return {
    x: 0,
    y: 0,
    angle: 0,
    scale: keyframes(since, [[0, 0.94], [0.13, 1.1], [0.36, 0.97], [0.56, 1.01], [0.8, 1]]),
    bright: keyframes(since, [[0, 1.6], [0.13, 1.45], [0.36, 1.15], [0.8, 1]]),
  };
}

/**
 * Light leaking round the lamp's tile from behind it: a glow and rays that grow as it charges, draw
 * in as it focuses, and flare once as it fires. The lens itself is never given a bright centre.
 */
function backlight(ctx: CanvasRenderingContext2D, rays: Ray[], lens: Point, size: number, time: number) {
  const p = clamp01(time / charge);
  const focus = smoothstep(0.72, 1, p);
  const squash = clamp01((time - charge) / (fire - charge));
  const after = clamp01((time - fire) / 0.45);
  const flicker = 0.88 + 0.12 * Math.sin(time * 53) * Math.sin(time * 31);
  const strength = (0.15 + 0.85 * p * p) * (1 + 0.4 * squash) * (1 - after) ** 2 * flicker;
  const reach = size * (0.72 + 0.6 * p * p - 0.25 * focus - 0.15 * squash + 0.6 * after);
  const corona = ctx.createRadialGradient(lens.x, lens.y, size * 0.3, lens.x, lens.y, reach);
  corona.addColorStop(0, rgba(filament, 0.95 * strength));
  corona.addColorStop(0.35, rgba(safelight, 0.7 * strength));
  corona.addColorStop(0.7, rgba(deep, 0.22 * strength));
  corona.addColorStop(1, rgba(deep, 0));
  ctx.fillStyle = corona;
  ctx.fillRect(lens.x - reach, lens.y - reach, reach * 2, reach * 2);

  const shine = smoothstep(0.05, 0.5, p) * (1 - 0.55 * focus) * (1 - squash);
  if (shine <= 0) return;
  for (const ray of rays) {
    const flick = 0.5 + 0.5 * Math.sin(time * ray.rate + ray.phase);
    const length = size * (0.5 + (0.35 + 0.6 * flick) * p * p * (1 - 0.4 * focus));
    const angle = ray.angle + time * 0.22;
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

/** The shot between `from` and `to`, fractions of the arc's length: brightest and widest at its head. */
function beam(ctx: CanvasRenderingContext2D, lights: Lights, path: Path, from: number, to: number, time: number) {
  const span = to - from;
  if (span <= 0) return;
  const count = Math.max(2, Math.ceil((path.length * span) / 3.5));
  for (let i = 0; i <= count; i += 1) {
    const f = i / count;
    const point = path.at(from + span * f);
    glow(ctx, lights.safelight, point, 9 + 16 * f, 0.13 * f ** 1.2);
    glow(ctx, lights.filament, point, 3 + 6 * f, 0.32 * f ** 1.2);
  }
  ctx.lineCap = "butt";
  const pieces = 8;
  for (let j = 0; j < pieces; j += 1) {
    ctx.beginPath();
    for (let i = 0; i <= 6; i += 1) {
      const f = (j + i / 6) / pieces;
      const point = path.at(from + span * f);
      const crackle = (Math.sin(f * 41 + time * 47) + 0.5 * Math.sin(f * 97 - time * 71)) * 1.1 * f;
      const x = point.x - Math.sin(point.angle) * crackle;
      const y = point.y + Math.cos(point.angle) * crackle;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    const f = (j + 1) / pieces;
    ctx.strokeStyle = rgba(hot, 0.85 * f ** 1.4);
    ctx.lineWidth = 0.8 + 1.4 * f;
    ctx.stroke();
  }
}

/** Light running round the GitHub button after the hit, fading as the button settles. */
function aura(ctx: CanvasRenderingContext2D, button: DOMRect, since: number) {
  const k = since / 1.45;
  const strength = k < 0.06 ? k / 0.06 : 1 - smoothstep(0.4, 1, k);
  const middle = centre(button);
  // Two lights chase each other clockwise, each with its tail behind it.
  const chase = ctx.createConicGradient(since * Math.PI * 2 * 1.15, middle.x, middle.y);
  chase.addColorStop(0, rgba(hot, 1));
  chase.addColorStop(0.03, rgba(filament, 0));
  chase.addColorStop(0.3, rgba(safelight, 0));
  chase.addColorStop(0.5, rgba(filament, 0.9));
  chase.addColorStop(0.53, rgba(filament, 0));
  chase.addColorStop(0.8, rgba(safelight, 0));
  chase.addColorStop(1, rgba(hot, 1));
  pill(ctx, button, 3);
  ctx.strokeStyle = chase;
  ctx.globalAlpha = strength;
  ctx.lineWidth = 2;
  ctx.stroke();
  ctx.globalAlpha = strength * 0.35;
  ctx.lineWidth = 7;
  ctx.stroke();
  ctx.globalAlpha = 1;
}

/** An arc from the lamp, up and over, down into the button, measured along its length. */
function arc(from: Point, to: Point): Path {
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

function burst(
  sparks: Spark[],
  at: Point,
  heading: number,
  count: number,
  spread: number,
  speed: [number, number],
  life: [number, number],
  fall: number,
) {
  for (let i = 0; i < count; i += 1) {
    const angle = heading + (Math.random() - 0.5) * spread;
    const velocity = speed[0] + Math.random() * (speed[1] - speed[0]);
    sparks.push({
      x: at.x,
      y: at.y,
      vx: Math.cos(angle) * velocity,
      vy: Math.sin(angle) * velocity,
      age: 0,
      life: life[0] + Math.random() * (life[1] - life[0]),
      width: 1 + Math.random() * 1.3,
      fall,
    });
  }
}

/** Moves and draws the sparks, which cool from white to filament to red as they fade. */
function fly(ctx: CanvasRenderingContext2D, sparks: Spark[], dt: number) {
  ctx.lineCap = "round";
  const keep = Math.exp(-2.6 * dt);
  for (let i = sparks.length - 1; i >= 0; i -= 1) {
    const spark = sparks[i];
    spark.age += dt;
    if (spark.age >= spark.life) {
      sparks.splice(i, 1);
      continue;
    }
    spark.vx *= keep;
    spark.vy = spark.vy * keep + spark.fall * dt;
    spark.x += spark.vx * dt;
    spark.y += spark.vy * dt;
    const k = spark.age / spark.life;
    ctx.strokeStyle = rgba(k < 0.3 ? hot : k < 0.65 ? filament : safelight, 0.95 * (1 - k));
    ctx.lineWidth = spark.width * (1 - 0.5 * k);
    ctx.beginPath();
    ctx.moveTo(spark.x - spark.vx * 0.022, spark.y - spark.vy * 0.022);
    ctx.lineTo(spark.x, spark.y);
    ctx.stroke();
  }
}

/** A soft round light, drawn once and stamped wherever the effects need one. */
function spot(colour: Colour): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = 128;
  canvas.height = 128;
  const ctx = canvas.getContext("2d");
  if (ctx) {
    const fall = ctx.createRadialGradient(64, 64, 0, 64, 64, 64);
    fall.addColorStop(0, rgba(colour, 1));
    fall.addColorStop(0.25, rgba(colour, 0.55));
    fall.addColorStop(0.6, rgba(colour, 0.14));
    fall.addColorStop(1, rgba(colour, 0));
    ctx.fillStyle = fall;
    ctx.fillRect(0, 0, 128, 128);
  }
  return canvas;
}

function glow(ctx: CanvasRenderingContext2D, image: HTMLCanvasElement, at: Point, radius: number, alpha: number) {
  if (alpha <= 0 || radius <= 0) return;
  ctx.globalAlpha = Math.min(alpha, 1);
  ctx.drawImage(image, at.x - radius, at.y - radius, radius * 2, radius * 2);
  ctx.globalAlpha = 1;
}

/** Starts a path round the button's pill, `pad` pixels outside it. */
function pill(ctx: CanvasRenderingContext2D, rect: DOMRect, pad: number) {
  const height = rect.height + pad * 2;
  ctx.beginPath();
  ctx.roundRect(rect.left - pad, rect.top - pad, rect.width + pad * 2, height, height / 2);
}

// ---------------------------------------------------------------- the sign

/** The sign drops from under the GitHub button, can be dragged and thrown, and is drawn back up once the visitor scrolls on. */
function hang({ layer, sign, rope }: Overlay, parts: Parts, onGone: () => void): () => void {
  const width = sign.offsetWidth;
  const height = sign.offsetHeight;
  const anchor = anchorFor(parts, width);
  const length = ropeFor(parts, anchor, width, height);
  const physics = new HangingSign(
    { anchor, ropeLength: length, width, height, eyelet },
    // Tucked behind the header, a little to the left, so it falls out from under it and swings.
    { eyelet: { x: anchor.x - length * 0.5, y: anchor.y - height * 0.45 }, angle: 0.2, velocity: { x: 160, y: 0 } },
  );
  let frame = 0;
  let last = 0;
  let reeling = 0;
  let pointer: number | null = null;
  let pressed: Point = { x: 0, y: 0 };
  let travelled = 0;

  const draw = () => {
    const pose = physics.pose;
    sign.style.transform = `translate3d(${pose.x - width / 2}px, ${pose.y - height / 2}px, 0) rotate(${pose.angle}rad)`;
    rope.setAttribute("d", ropePath(physics.rope));
  };

  const tick = (now: number) => {
    const dt = last ? Math.min((now - last) / 1000, 0.05) : 1 / 60;
    last = now;
    if (reeling) {
      const k = clamp01((now - reeling) / 450);
      physics.setRopeLength(length * (1 - k * k));
      layer.style.opacity = String(1 - k);
      if (k >= 1) {
        frame = 0;
        onGone();
        return;
      }
    }
    physics.step(dt);
    draw();
    if (physics.resting && !reeling) {
      frame = 0;
      last = 0;
      return;
    }
    frame = requestAnimationFrame(tick);
  };

  const wake = () => {
    if (!frame) frame = requestAnimationFrame(tick);
  };

  const onDown = (event: PointerEvent) => {
    if (pointer !== null || reeling || (event.pointerType === "mouse" && event.button !== 0)) return;
    pointer = event.pointerId;
    sign.setPointerCapture(event.pointerId);
    pressed = { x: event.clientX, y: event.clientY };
    travelled = 0;
    physics.grab(pressed);
    physics.drag(pressed);
    sign.style.cursor = "grabbing";
    wake();
  };
  const onMove = (event: PointerEvent) => {
    if (event.pointerId !== pointer) return;
    const at = { x: event.clientX, y: event.clientY };
    travelled = Math.max(travelled, Math.hypot(at.x - pressed.x, at.y - pressed.y));
    physics.drag(at);
    wake();
  };
  const onUp = (event: PointerEvent) => {
    if (event.pointerId !== pointer) return;
    pointer = null;
    physics.release();
    sign.style.cursor = "";
    wake();
  };
  // A drag that ends on the sign would otherwise follow its link.
  const onClick = (event: MouseEvent) => {
    if (travelled > 4) event.preventDefault();
    travelled = 0;
  };
  const onScroll = () => {
    if (reeling || physics.held || window.scrollY < window.innerHeight * 0.4) return;
    reeling = performance.now();
    wake();
  };
  const onResize = () => {
    physics.moveAnchor(anchorFor(parts, width));
    wake();
  };

  sign.addEventListener("pointerdown", onDown);
  sign.addEventListener("pointermove", onMove);
  sign.addEventListener("pointerup", onUp);
  sign.addEventListener("pointercancel", onUp);
  sign.addEventListener("lostpointercapture", onUp);
  sign.addEventListener("click", onClick);
  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onResize);
  draw();
  sign.style.visibility = "visible";
  wake();
  onScroll();

  return () => {
    cancelAnimationFrame(frame);
    sign.removeEventListener("pointerdown", onDown);
    sign.removeEventListener("pointermove", onMove);
    sign.removeEventListener("pointerup", onUp);
    sign.removeEventListener("pointercancel", onUp);
    sign.removeEventListener("lostpointercapture", onUp);
    sign.removeEventListener("click", onClick);
    window.removeEventListener("scroll", onScroll);
    window.removeEventListener("resize", onResize);
  };
}

/** Under the star count, at the button's foot, kept far enough from the window's edge for the sign to fit. */
function anchorFor(parts: Parts, width: number): Point {
  const button = parts.button.getBoundingClientRect();
  const star = parts.star?.getBoundingClientRect();
  const under = star ? star.left + star.width / 2 : button.left + button.width / 2;
  const margin = width / 2 + 8;
  return {
    x: Math.max(margin, Math.min(Math.max(button.left + 8, Math.min(under, button.right - 8)), window.innerWidth - margin)),
    y: button.bottom - 3,
  };
}

/** A shorter rope where a long one would let the sign hang over the lamp, as on phones. */
function ropeFor(parts: Parts, anchor: Point, width: number, height: number): number {
  const lamp = parts.lamp.getBoundingClientRect();
  const over = anchor.x + width / 2 > lamp.left - 12 && anchor.x - width / 2 < lamp.right + 12;
  const room = lamp.top - 12 - anchor.y - (height - eyelet);
  return over ? Math.max(30, Math.min(56, room)) : 56;
}

/** A smooth curve through the rope's points, from the anchor to the eyelet. */
function ropePath(points: Point[]): string {
  const at = (point: Point) => `${point.x.toFixed(1)} ${point.y.toFixed(1)}`;
  let d = `M${at(points[0])}`;
  for (let i = 1; i < points.length - 1; i += 1) {
    d += ` Q${at(points[i])} ${at({ x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2 })}`;
  }
  return `${d} L${at(points[points.length - 1])}`;
}

// ---------------------------------------------------------------- helpers

function rgba([r, g, b]: Colour, alpha: number): string {
  return `rgba(${r},${g},${b},${clamp01(alpha)})`;
}

function around(origin: Point, radius: number, angle: number): Point {
  return { x: origin.x + Math.cos(angle) * radius, y: origin.y + Math.sin(angle) * radius };
}

function centre(rect: DOMRect): Point {
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
}

function clamp01(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}

function smoothstep(edge0: number, edge1: number, value: number): number {
  const k = clamp01((value - edge0) / (edge1 - edge0));
  return k * k * (3 - 2 * k);
}

/** Eases between [time, value] stops, coming to rest at each. */
function keyframes(time: number, stops: [number, number][]): number {
  if (time <= stops[0][0]) return stops[0][1];
  for (let i = 1; i < stops.length; i += 1) {
    const [end, to] = stops[i];
    if (time <= end) {
      const [start, from] = stops[i - 1];
      return from + (to - from) * smoothstep(start, end, time);
    }
  }
  return stops[stops.length - 1][1];
}
