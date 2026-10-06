import { AbsoluteFill, Easing, getStaticFiles, Html5Audio, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { Words } from "../components/Kinetic";
import { Grain } from "../components/Stage";
import { type Camera, cssTransform, type Framing, framing, shake } from "../kit/camera";
import { Cursor } from "../kit/Cursor";
import { badgeParts, badgeSize, GitHubBadge } from "../kit/GitHubBadge";
import { type CueSheet, grid } from "../kit/grid";
import { glowScale, type Knock, Lamp, lampPose } from "../kit/Lamp";
import { LightCanvas } from "../kit/LightCanvas";
import {
  arc,
  aura,
  backlight,
  beam,
  burst,
  type Charge,
  chargeLevel,
  clamp01,
  keyframes,
  motes,
  type Point,
  pool,
  ripple,
  type Shot,
  type Spark,
  shotSparks,
  sparks,
  strike,
} from "../kit/light";
import { random } from "../kit/random";
import { SafeZones } from "../kit/SafeZones";
import { Sign, signSize } from "../kit/Sign";
import { fallTime, performSign, type SignFrame } from "../kit/rope";
import { color } from "../theme";
import { copy, type Hook, hooks } from "./copy";
import cueSheet from "./cues.json";

const sheet = cueSheet as unknown as CueSheet & { knocks: [number, number, number][] };
const g = grid(sheet);
const at = (name: string) => g.seconds(sheet.cues[name]);

export const STAR_PROMO_FRAMES = g.frames;

export type StarPromoProps = {
  hook: Hook;
  /** The repository's star count, or null for the star alone. */
  stars: number | null;
  /** The score in public/ (scripts/star-score.py writes star/score.wav). Silent while it's missing. */
  musicSrc: string | null;
  /** Draw the apps' safe zones over the frame, for review. */
  guides: boolean;
};

/** Seconds from the start, from the cue sheet. */
const T = {
  full: at("squash"),
  fire: at("fire"),
  hit: at("hit"),
  catch: at("catch"),
  cursor: at("cursor"),
  hover: at("hover"),
  click: at("click"),
  end: at("end"),
  stop: at("stop"),
  again: at("recharge"),
};

// ---------------------------------------------------------------- layout

type ShapeName = "square" | "tall";

type Layout = {
  lens: Point;
  /** The lamp's tile, in world units (the frame's pixels at zoom 1). */
  size: number;
  /** How far the lamp turns towards the badge as it takes aim, in radians clockwise. */
  aim: number;
  badge: Point;
  badgeHeight: number;
  /** World units per website pixel for the sign and its rope. */
  signScale: number;
  /** Where the cursor comes from, relative to the badge's star. */
  cursorFrom: Point;
  cameras: Record<"hook" | "push" | "wide" | "badge" | "end" | "drift", Framing>;
  /**
   * Screen pixels: the words' top line and size during the build, and the end card's. The reason
   * to star sits under the address, or at `reasonTop` where the scene leaves no room under it.
   */
  text: { top: number; size: number; endTop: number; endSize: number; reasonTop: number | null; margin: number };
};

const layouts: Record<ShapeName, Layout> = {
  square: {
    lens: { x: 270, y: 740 },
    size: 230,
    aim: 0.14,
    badge: { x: 690, y: 360 },
    badgeHeight: 84,
    signScale: 2.2,
    cursorFrom: { x: 300, y: 420 },
    cameras: {
      hook: { x: 270, y: 712, zoom: 1.9 },
      push: { x: 270, y: 722, zoom: 2.25 },
      wide: { x: 530, y: 540, zoom: 1 },
      badge: { x: 734, y: 500, zoom: 1.6 },
      end: { x: 560, y: 560, zoom: 1.16 },
      drift: { x: 560, y: 565, zoom: 1.19 },
    },
    text: { top: 96, size: 88, endTop: 64, endSize: 70, reasonTop: 975, margin: 50 },
  },
  tall: {
    lens: { x: 390, y: 1330 },
    size: 260,
    aim: 0.08,
    badge: { x: 540, y: 760 },
    badgeHeight: 96,
    signScale: 2.5,
    cursorFrom: { x: 300, y: 560 },
    cameras: {
      hook: { x: 390, y: 1241, zoom: 1.9 },
      push: { x: 390, y: 1254, zoom: 2.25 },
      wide: { x: 540, y: 1040, zoom: 1 },
      badge: { x: 600, y: 920, zoom: 1.5 },
      end: { x: 540, y: 1040, zoom: 1.12 },
      drift: { x: 540, y: 1045, zoom: 1.15 },
    },
    text: { top: 300, size: 100, endTop: 290, endSize: 80, reasonTop: null, margin: 70 },
  },
};

// ---------------------------------------------------------------- the badge's motion

/** The website's spring between keyframes, and the star's settle (StarNudge's strike). */
const spring = Easing.bezier(0.33, 1, 0.68, 1);
const settle = Easing.bezier(0.22, 1, 0.36, 1);
const linear = (k: number) => k;
const HIT = 1.7;

type BadgeMotion = { scale: number; halo: number; lit: number; star: { rotate: number; scale: number; lit: number }; roll: number };

/**
 * How the badge moves: the website's swell and spring as the shot lands, a bump on every kick of
 * the groove, a pop and a second spin of the star at the click, and the count rolling on.
 */
function badgeMotion(t: number): BadgeMotion {
  let scale = 1;
  let halo = 0;
  let lit = 0;
  const star = { rotate: 0, scale: 1, lit: 0 };
  if (t >= T.hit) {
    const since = t - T.hit;
    const off = (o: number) => o * HIT;
    scale = keyframes(since, [[0, 1], [off(0.07), 1.15], [off(0.2), 0.96], [off(0.34), 1.04], [off(0.48), 0.995], [off(0.62), 1]], spring);
    halo = keyframes(since, [[0, 0], [off(0.07), 1], [off(0.62), 0.5], [HIT, 0]], linear);
    lit = keyframes(since, [[0, 0], [off(0.07), 1], [off(0.62), 0.55], [HIT, 0]], linear);
    spin(star, since - 0.08, 0);
  }
  scale += 0.03 * kick(t);
  if (t >= T.click) {
    const since = t - T.click;
    scale += keyframes(since, [[0, 0], [0.06, 0.1], [0.2, -0.025], [0.34, 0.012], [0.5, 0]], spring);
    halo = Math.max(halo, 0.7 * Math.exp(-since / 0.25));
    lit = Math.max(lit, 0.8 * Math.exp(-since / 0.3));
    spin(star, since, 360);
    star.lit = Math.max(star.lit, clamp01(since / 0.12));
  }
  const roll = t < T.click + 0.06 ? 0 : keyframes(t - T.click - 0.06, [[0, 0], [0.32, 1]], settle);
  return { scale, halo, lit, star, roll };
}

/** The star's spin: it grows to 1.9 times and turns filament as it turns once. */
function spin(star: BadgeMotion["star"], since: number, from: number) {
  if (since < 0) return;
  const p = settle(clamp01(since / 1.2));
  star.scale = keyframes(p, [[0, 1], [0.35, 1.9], [0.75, 1], [1, 1]], linear);
  star.rotate = from + keyframes(p, [[0, 0], [0.35, 200], [0.75, 360], [1, 360]], linear);
  star.lit = keyframes(p, [[0, 0], [0.35, 1], [0.75, 1], [1, 0]], linear);
}

/** 1 on each kick of the groove, from the beat after the hit to the stop, dying away in 80 ms. */
function kick(t: number): number {
  const beat = g.seconds(1);
  const last = Math.floor(t / beat) * beat;
  if (last < T.hit + beat - 1e-6 || last >= T.stop - 1e-6) return 0;
  return Math.exp(-(t - last) / 0.08);
}

// ---------------------------------------------------------------- the scene, worked out once per shape

type Scene = {
  layout: Layout;
  unit: number;
  charge: Charge;
  /** The charge starting over in the last bar, so a loop runs on into the first frame. */
  again: Charge;
  shot: Shot;
  sparks: Spark[];
  knocks: Knock[];
  badgeWidth: number;
  star: Point;
  anchor: Point;
  sign: (SignFrame | null)[];
};

const scenes = new Map<string, Scene>();

function sceneFor(shape: ShapeName, stars: number | null, fps: number): Scene {
  const key = `${shape}:${stars}`;
  const cached = scenes.get(key);
  if (cached) return cached;
  const layout = layouts[shape];
  const { lens, size, badge, badgeHeight, signScale } = layout;
  const unit = size / 112;
  const charge: Charge = { from: -1.4, full: T.full, fire: T.fire, lens, size, unit, seed: "star" };
  const again: Charge = { ...charge, from: T.again, full: T.again + (T.full - charge.from), fire: T.again + (T.fire - charge.from), seed: "star:again" };
  // The shot leaves from behind the tile's top edge, on the side nearer the badge.
  const start = { x: lens.x + Math.sign(badge.x - lens.x) * size * 0.12, y: lens.y - size * 0.47 + size * 0.1 };
  const shot: Shot = { path: arc(start, badge), fire: T.fire, hit: T.hit, unit };
  const parts = badgeParts(badgeHeight, stars);
  const star = { x: badge.x + parts.star.x, y: badge.y + parts.star.y };
  const anchor = { x: badge.x + parts.anchor.x, y: badge.y + parts.anchor.y };
  const list = shotSparks(shot, "star");
  burst(list, random("star:click"), T.click, star, -Math.PI / 2, 26, Math.PI * 2, [120, 380], [0.35, 0.75], 900, unit * 0.9);

  // Each knock of the roll in the score shakes the lamp, harder as it charges.
  const knocks: Knock[] = [];
  for (const [from, to, step] of sheet.knocks) {
    for (let b = from; b < to - 1e-9; b += step) {
      const t = g.seconds(b);
      knocks.push({ at: t, strength: 0.2 + 0.8 * chargeLevel(charge, t) ** 1.2 });
    }
  }

  const shapeOfSign = { ...signSize(copy.sign), ropeLength: 56 };
  const begin = { eyelet: { x: -56 * 0.5, y: -shapeOfSign.height * 0.45 }, angle: 0.2, velocity: { x: 160, y: 0 } };
  const drop = T.catch - fallTime({ shape: shapeOfSign, start: begin });
  const sign = performSign(
    {
      fps,
      frames: g.frames,
      shape: shapeOfSign,
      drop,
      start: begin,
      // The rope is tied under the star count, so it rides the badge's bumps and pops.
      anchor: (t) => {
        const grow = badgeMotion(t).scale - 1;
        return { x: (parts.anchor.x * grow) / signScale, y: (parts.anchor.y * grow) / signScale };
      },
      // At the click the sign jumps: a quick yank up, off-centre so it turns, then let go.
      holds: [
        {
          at: T.click + 0.04,
          until: T.click + 0.12,
          grab: { x: shapeOfSign.width * 0.18, y: shapeOfSign.height * 0.2 },
          to: (t, grabbed) => {
            const k = clamp01((t - T.click - 0.04) / 0.08);
            return { x: grabbed.x - 4 * k, y: grabbed.y - 24 * k };
          },
        },
      ],
    },
    key,
  );
  const scene = { layout, unit, charge, again, shot, sparks: list, knocks, badgeWidth: badgeSize(badgeHeight, stars).width, star, anchor, sign };
  scenes.set(key, scene);
  return scene;
}

function cameraAt(layout: Layout, frame: number): Camera {
  const c = layout.cameras;
  const f = (beat: number) => g.at(beat);
  const creep = (k: number) => k;
  const base = framing(frame, [
    [0, c.hook],
    [f(10.5), c.push, creep],
    [f(11.45), c.wide],
    [f(13), c.wide],
    [f(15), c.badge],
    [f(23), c.badge],
    [f(25), c.end],
    [f(32), c.drift, creep],
  ]);
  const hit = f(12);
  const punch = frame >= hit ? 0.05 * Math.exp(-(frame - hit) / 6) : 0;
  const click = f(22);
  const pop = frame >= click ? 0.02 * Math.exp(-(frame - click) / 5) : 0;
  const jolt = [shake(frame, hit, 16, 16, "hit"), shake(frame, f(16), 4, 8, "catch"), shake(frame, click, 6, 9, "click")];
  return {
    ...base,
    zoom: base.zoom * (1 + punch + pop),
    shakeX: jolt.reduce((sum, j) => sum + j.x, 0),
    shakeY: jolt.reduce((sum, j) => sum + j.y, 0),
  };
}

/** The cursor: in from below at `cursor`, on the star by `hover`, a click, then a drift away as the end card comes up. */
function cursorAt(scene: Scene, t: number): { tip: Point; press: number; opacity: number } | null {
  if (t < T.cursor) return null;
  const target = scene.star;
  const from = { x: target.x + scene.layout.cursorFrom.x, y: target.y + scene.layout.cursorFrom.y };
  const k = settle(clamp01((t - T.cursor) / (T.hover - T.cursor)));
  const bend = { x: from.x - 60, y: target.y + scene.layout.cursorFrom.y * 0.15 };
  let tip = {
    x: (1 - k) ** 2 * from.x + 2 * (1 - k) * k * bend.x + k * k * target.x,
    y: (1 - k) ** 2 * from.y + 2 * (1 - k) * k * bend.y + k * k * target.y,
  };
  const away = settle(clamp01((t - T.click - 0.2) / 0.7));
  tip = { x: tip.x + 36 * away, y: tip.y + 44 * away };
  const down = t >= T.click - 0.03 && t < T.click + 0.07;
  const press = down ? 0.84 : t >= T.click + 0.07 ? keyframes(t - T.click - 0.07, [[0, 0.84], [0.09, 1.06], [0.2, 1]], spring) : 1;
  const opacity = clamp01((t - T.cursor) / 0.12) * (1 - clamp01((t - T.end) / 0.35));
  return { tip, press, opacity };
}

// ---------------------------------------------------------------- drawing

/** The light on the wall and behind the lamp: drawn under everything. */
function drawBehind(ctx: CanvasRenderingContext2D, scene: Scene, t: number) {
  const { layout, charge } = scene;
  const p = chargeLevel(charge, t);
  const spent = clamp01((t - T.fire) / 1.0);
  pool(ctx, layout.lens, layout.size * 1.6 * glowScale(charge, t), (0.26 + 0.14 * p) * (1 - 0.6 * spent));
  if (t >= T.hit) {
    const since = t - T.hit;
    const flare = t >= T.click ? 0.22 * Math.exp(-(t - T.click) / 0.5) : 0;
    pool(ctx, layout.badge, scene.badgeWidth * 1.05, 0.34 * Math.exp(-since / 0.6) + 0.15 * clamp01(since / 0.4) + flare);
  }
  backlight(ctx, charge, t);
  motes(ctx, charge, t);
  if (t >= T.again) {
    backlight(ctx, scene.again, t);
    motes(ctx, scene.again, t);
  }
}

/** The shot, its sparks and where it lands: drawn over the lamp and the badge. */
function drawFront(ctx: CanvasRenderingContext2D, scene: Scene, t: number, badge: BadgeMotion, tip: Point | null) {
  const { layout, unit } = scene;
  beam(ctx, scene.shot, t);
  sparks(ctx, scene.sparks, t);
  const pill = { x: layout.badge.x, y: layout.badge.y, width: scene.badgeWidth * badge.scale, height: layout.badgeHeight * badge.scale };
  strike(ctx, pill, t - T.hit, unit);
  if (t >= T.click) {
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    aura(ctx, pill, t - T.click, (t - T.click) / 1.2, unit);
    ctx.restore();
    if (tip) ripple(ctx, tip, t - T.click, 34 * unit, unit);
  }
}

// ---------------------------------------------------------------- the film

export function StarPromo({ hook, stars, musicSrc, guides }: StarPromoProps) {
  const frame = useCurrentFrame();
  const { width, height, fps, durationInFrames } = useVideoConfig();
  const t = frame / fps;
  const shape: ShapeName = height > width * 1.3 ? "tall" : "square";
  const scene = sceneFor(shape, stars, fps);
  const { layout } = scene;
  const camera = cameraAt(layout, frame);
  const world = { transform: cssTransform(camera, width, height), transformOrigin: "0 0" };
  const badge = badgeMotion(t);
  const pose = lampPose(scene.charge, scene.knocks, t, 1.4, layout.aim);
  const cursor = cursorAt(scene, t);
  const clickTip = cursorAt(scene, T.click)?.tip ?? null;
  const music = musicSrc && getStaticFiles().some((file) => file.name === musicSrc) ? musicSrc : null;
  const b = (beat: number) => Math.round(g.at(beat));
  const { text } = layout;
  const lines = { position: "absolute" as const, left: text.margin, right: text.margin };
  const [hookFirst, hookSecond] = hooks[hook];
  const end = text.endSize;
  return (
    <AbsoluteFill style={{ background: color.wall, overflow: "hidden" }}>
      <LightCanvas camera={camera} draw={(ctx, time) => drawBehind(ctx, scene, time)} />
      <AbsoluteFill style={world}>
        <Sign frame={scene.sign[frame] ?? null} origin={scene.anchor} scale={layout.signScale} text={copy.sign} />
        <Lamp lens={layout.lens} size={layout.size} pose={pose} />
        <div style={{ opacity: clamp01((frame - g.at(10.25)) / 6) }}>
          <GitHubBadge centre={layout.badge} height={layout.badgeHeight} count={stars} {...badge} />
        </div>
      </AbsoluteFill>
      <LightCanvas camera={camera} draw={(ctx, time) => drawFront(ctx, scene, time, badge, clickTip)} />
      <AbsoluteFill style={world}>{cursor ? <Cursor tip={cursor.tip} size={layout.badgeHeight * 0.62} press={cursor.press} opacity={cursor.opacity} /> : null}</AbsoluteFill>

      <div style={{ ...lines, top: text.top }}>
        <Words text={hookFirst} start={-6} size={text.size} stagger={3} mode="pop" out={b(4) - 9} />
        <Words text={hookSecond} start={b(2)} size={text.size} stagger={3} mode="pop" out={b(4) - 8} />
      </div>
      <div style={{ ...lines, top: text.top }}>
        <Words text={copy.build[0]} start={b(4)} size={text.size * 0.86} stagger={3} mode="pop" out={b(8) - 9} />
        <Words text={copy.build[1]} start={b(5.5)} size={text.size * 0.86} stagger={3} mode="pop" out={b(8) - 8} />
      </div>
      <div style={{ ...lines, top: text.top }}>
        <Words text={copy.rush[0]} start={b(8)} size={text.size * 0.92} stagger={3} mode="pop" out={b(10.5) - 4} />
        <Words text={copy.rush[1]} start={b(9)} size={text.size * 0.92} stagger={3} mode="pop" out={b(10.5) - 3} />
      </div>
      <div style={{ ...lines, top: text.endTop }}>
        <Words text={copy.end.title} start={b(24)} size={end} stagger={3} mode="pop" />
        <Words text={copy.end.address} start={b(25)} size={end * 0.6} mode="pop" weight={500} style={{ marginTop: end * 0.3 }} />
        {text.reasonTop === null ? (
          <Words text={copy.end.reason} start={b(26)} size={end * 0.44} stagger={2} mode="pop" tone="mute" weight={500} style={{ marginTop: end * 0.4 }} />
        ) : null}
      </div>
      {text.reasonTop !== null ? (
        <div style={{ ...lines, top: text.reasonTop }}>
          <Words text={copy.end.reason} start={b(26)} size={end * 0.46} stagger={2} mode="pop" tone="mute" weight={500} />
        </div>
      ) : null}

      <AbsoluteFill style={{ background: "radial-gradient(120% 95% at 50% 45%, transparent 55%, rgba(0,0,0,0.55))", pointerEvents: "none" }} />
      <Grain opacity={0.05} />
      {guides ? <SafeZones /> : null}
      {music ? (
        <Html5Audio
          src={staticFile(music)}
          volume={(f) => interpolate(f, [durationInFrames - 3, durationInFrames], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
        />
      ) : null}
    </AbsoluteFill>
  );
}
