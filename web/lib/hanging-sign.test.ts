import assert from "node:assert/strict";
import { test } from "node:test";
import { HangingSign, type Point, type Shape } from "./hanging-sign.ts";

const shape: Shape = { anchor: { x: 400, y: 50 }, ropeLength: 56, width: 150, height: 44, eyelet: 9 };
/** Where the sign's centre hangs at rest: the rope's length below the anchor, then the eyelet's depth. */
const rest = { x: 400, y: 50 + 56 + 44 / 2 - 9 };
const frame = 1 / 60;

function run(sign: HangingSign, seconds: number, each?: (time: number) => void) {
  for (let time = 0; time < seconds; time += frame) {
    each?.(time);
    sign.step(frame);
  }
}

function eyeletDistance(sign: HangingSign): number {
  const eyelet = sign.rope.at(-1) as Point;
  return Math.hypot(eyelet.x - shape.anchor.x, eyelet.y - shape.anchor.y);
}

function near(actual: number, expected: number, within: number, what: string) {
  assert.ok(Math.abs(actual - expected) <= within, `${what}: ${actual.toFixed(2)}, expected ${expected} ± ${within}`);
}

test("a dropped sign swings, then comes to rest hanging straight below its anchor", () => {
  const sign = new HangingSign(shape, { eyelet: { x: 380, y: 30 }, angle: 0.25, velocity: { x: 90, y: 0 } });
  let widest = 0;
  run(sign, 12, () => {
    widest = Math.max(widest, Math.abs(sign.pose.x - rest.x));
  });
  assert.ok(widest > 10, `it should swing, but moved at most ${widest.toFixed(1)} px sideways`);
  near(sign.pose.x, rest.x, 0.5, "x");
  near(sign.pose.y, rest.y, 0.5, "y");
  near(sign.pose.angle, 0, 0.01, "angle");
  assert.ok(sign.resting);
});

test("the rope never stretches past its length, however hard the sign is pulled", () => {
  const sign = new HangingSign(shape, { eyelet: { x: 380, y: 30 }, angle: 0.25, velocity: { x: 90, y: 0 } });
  let longest = 0;
  run(sign, 2, () => {
    longest = Math.max(longest, eyeletDistance(sign));
  });
  sign.grab(sign.pose);
  const pulls = [{ x: 2000, y: 50 }, { x: 400, y: 3000 }, { x: -1500, y: -900 }];
  for (const pull of pulls) {
    run(sign, 0.5, () => {
      sign.drag(pull);
      longest = Math.max(longest, eyeletDistance(sign));
    });
  }
  sign.release();
  run(sign, 2, () => {
    longest = Math.max(longest, eyeletDistance(sign));
  });
  assert.ok(longest <= shape.ropeLength * 1.001, `the eyelet reached ${longest.toFixed(2)} px from the anchor`);
});

test("a held sign follows the pointer, as far as the rope reaches", () => {
  const sign = new HangingSign(shape);
  run(sign, 0.5);
  sign.grab(rest);
  const target = { x: rest.x + 30, y: rest.y - 20 };
  run(sign, 0.5, (time) => {
    const along = Math.min(time / 0.3, 1);
    sign.drag({ x: rest.x + (target.x - rest.x) * along, y: rest.y + (target.y - rest.y) * along });
  });
  near(sign.pose.x, target.x, 1, "x");
  near(sign.pose.y, target.y, 1, "y");

  run(sign, 1.5, () => sign.drag({ x: 1400, y: shape.anchor.y }));
  const reach = shape.ropeLength + (shape.height / 2 - shape.eyelet);
  near(Math.hypot(sign.pose.x - shape.anchor.x, sign.pose.y - shape.anchor.y), reach, 1.5, "distance from the anchor");
  near(sign.pose.y, shape.anchor.y, 3, "height, level with the anchor");
  assert.ok(sign.held);
});

test("a thrown sign keeps its speed and swings past where it rests", () => {
  const sign = new HangingSign(shape);
  run(sign, 0.5);
  sign.grab(rest);
  // Up and to the right at 500 px/s, within the rope's reach.
  run(sign, 0.1, (time) => sign.drag({ x: rest.x + 400 * (time + frame), y: rest.y - 300 * (time + frame) }));
  sign.release();
  const before = sign.pose;
  sign.step(frame);
  const along = (sign.pose.x - before.x) * 0.8 - (sign.pose.y - before.y) * 0.6;
  assert.ok(along > 4, `it should carry on the way it was thrown, but moved ${along.toFixed(2)} px that way`);
  let leftmost = Infinity;
  run(sign, 1.5, () => {
    leftmost = Math.min(leftmost, sign.pose.x);
  });
  assert.ok(leftmost < rest.x - 5, `it should swing back past its resting place, but reached ${leftmost.toFixed(1)}`);
  assert.ok(!sign.resting);
});

test("a sign lifted by a corner turns to hang from it", () => {
  const sign = new HangingSign(shape);
  run(sign, 0.5);
  const corner = { x: rest.x - shape.width / 2, y: rest.y - shape.height / 2 };
  sign.grab(corner);
  run(sign, 2, (time) => sign.drag({ x: corner.x, y: corner.y - 40 * Math.min(time / 0.3, 1) }));
  assert.ok(sign.pose.angle > 0.3, `it turned only ${sign.pose.angle.toFixed(3)} rad`);
});

test("no drag, however wild, makes it blow up", () => {
  const sign = new HangingSign(shape, { eyelet: { x: 380, y: 30 } });
  let seed = 7;
  const random = () => {
    seed = (seed * 16807) % 2147483647;
    return seed / 2147483647;
  };
  sign.grab(sign.pose);
  run(sign, 5, () => sign.drag({ x: (random() - 0.5) * 10000, y: (random() - 0.5) * 10000 }));
  sign.release();
  for (const point of [...sign.rope, sign.pose]) assert.ok(Number.isFinite(point.x) && Number.isFinite(point.y));
  run(sign, 20);
  near(sign.pose.x, rest.x, 0.5, "x");
  near(sign.pose.y, rest.y, 0.5, "y");
  assert.ok(sign.resting);
});

test("shortening the rope draws the sign up to its anchor, and a moved anchor takes the sign with it", () => {
  const sign = new HangingSign(shape);
  sign.setRopeLength(8);
  run(sign, 3);
  near(sign.pose.y, shape.anchor.y + 8 + shape.height / 2 - shape.eyelet, 0.5, "y on the short rope");
  sign.setRopeLength(shape.ropeLength);
  sign.moveAnchor({ x: 520, y: 50 });
  run(sign, 15);
  near(sign.pose.x, 520, 0.5, "x under the moved anchor");
  near(sign.pose.y, rest.y, 0.5, "y");
});
