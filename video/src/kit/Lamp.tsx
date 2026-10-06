import { Lens } from "../components/Lens";
import { type Charge, chargeLevel, keyframes, smoothstep, squashLevel } from "./light";
import { random } from "./random";

/** The lamp's pose at a moment: its offset in world units, its turn in radians, its scale and its brightness. */
export type LampPose = { x: number; y: number; angle: number; scale: number; bright: number };

/** A knock that shakes the lamp, as each hit of a drum roll does: when, in seconds, and how hard, 0 to 1. */
export type Knock = { at: number; strength: number };

/**
 * The lamp trembles as it charges, squashes as it holds its breath, then recoils from the shot
 * (docs/brand/star-nudge.md). The tremble is the knocks: each one jolts the lamp in its own
 * direction and dies away in about a tenth of a second, so as knocks come faster the lamp blurs
 * into a shake. `amount` scales the website's 3.4 px and 0.045 rad. With `aim` (radians,
 * clockwise), the lamp also turns towards its target as it squashes, and swings back past
 * upright as it fires.
 */
export function lampPose(c: Charge, knocks: Knock[], t: number, amount = 1, aim = 0): LampPose {
  const p = chargeLevel(c, t);
  const squash = squashLevel(c, t);
  if (t < c.fire) {
    let x = 0;
    let y = 0;
    let angle = 0;
    let thump = 0;
    for (const knock of knocks) {
      const since = t - knock.at;
      if (since < 0 || since > 0.25) continue;
      const r = random(`knock:${knock.at.toFixed(4)}`);
      const direction = r.next() * Math.PI * 2;
      const fade = Math.exp(-since / 0.055) * knock.strength * (1 - squash);
      const swing = Math.sin(2 * Math.PI * 13 * since + Math.PI / 2);
      x += Math.cos(direction) * fade * swing;
      y += Math.sin(direction) * fade * swing;
      angle += r.signed() * fade * swing;
      thump += fade;
    }
    const reach = 3.4 * c.unit * amount;
    return {
      x: reach * x,
      y: reach * y,
      angle: 0.045 * amount * angle + aim * squash * (2 - squash),
      scale: 1 + 0.035 * p * p + 0.012 * Math.min(thump, 1.5) - 0.095 * squash * (2 - squash),
      bright: 1 + 0.3 * p * p + 0.3 * squash,
    };
  }
  const since = t - c.fire;
  return {
    x: 0,
    y: 0,
    angle: aim * keyframes(since, [[0, 1], [0.13, -0.35], [0.36, 0.12], [0.6, 0]]),
    scale: keyframes(since, [[0, 0.94], [0.13, 1.1], [0.36, 0.97], [0.56, 1.01], [0.8, 1]]),
    bright: keyframes(since, [[0, 1.6], [0.13, 1.45], [0.36, 1.15], [0.8, 1]]),
  };
}

/** How large the lamp's glow on the wall is, from 1 at rest: it grows as it charges and flares as it fires. */
export function glowScale(c: Charge, t: number): number {
  const p = chargeLevel(c, t);
  if (t < c.full) return 1 + 0.45 * smoothstep(0, 1, p);
  return keyframes(t, [[c.full, 1.45], [c.fire, 1.3], [c.fire + 0.12, 1.8], [c.fire + 0.9, 1]]);
}

type Props = { lens: { x: number; y: number }; size: number; pose: LampPose };

/** The app icon's lamp on its tile, centred on `lens` in world units, in its pose. */
export function Lamp({ lens, size, pose }: Props) {
  // The Lens draws its tile in a 100-unit box with the lens's centre at (50, 47).
  return (
    <div
      style={{
        position: "absolute",
        left: lens.x - size / 2,
        top: lens.y - size * 0.47,
        width: size,
        height: size,
        transform: `translate(${pose.x}px, ${pose.y}px) rotate(${pose.angle}rad) scale(${pose.scale})`,
        transformOrigin: "50% 47%",
        filter: `brightness(${pose.bright}) drop-shadow(0 ${size * 0.08}px ${size * 0.12}px rgba(0,0,0,0.55))`,
      }}
    >
      <Lens size={size} tile />
    </div>
  );
}
