import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { compareVersions, feed, imageSize, parseItem, readItems } from "./whats-new.ts";

/** The first 24 bytes of a PNG: its signature and the IHDR chunk's width and height. */
function png(width: number, height: number): Buffer {
  const bytes = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12, "ascii");
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

/** A JPEG's start, an APP0 segment, then a baseline start of frame. */
function jpeg(width: number, height: number): Buffer {
  const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x04, 0x00, 0x00]);
  const frame = Buffer.alloc(19);
  frame.writeUInt16BE(0xffc0, 0);
  frame.writeUInt16BE(17, 2);
  frame[4] = 8;
  frame.writeUInt16BE(height, 5);
  frame.writeUInt16BE(width, 7);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, frame]);
}

const source = `---
version: 0.2.4-prealpha
date: 2026-10-06
symbol: camera.badge.ellipsis
title: Test your camera
summary: See how Redlamp reads your camera's raw files.
image: results.png
imageAlt: The Camera Bench's results
action: testCamera
actionTitle: Test Your Camera…
---

Help › Test Your Camera… checks **your** raw files.

It sends only the measurements.
`;

const files = (name: string) => (name === "results.png" ? png(2080, 1504) : undefined);

test("parseItem reads a highlight, its image's size and its action", () => {
  const item = parseItem("camera-bench", source, files);
  assert.equal(item.version, "0.2.4-prealpha");
  assert.equal(item.symbol, "camera.badge.ellipsis");
  assert.equal(item.body, "Help › Test Your Camera… checks **your** raw files.\n\nIt sends only the measurements.");
  assert.deepEqual(item.image, {
    url: "/synced/whats-new/camera-bench/results.png",
    alt: "The Camera Bench's results",
    width: 2080,
    height: 1504,
  });
  assert.deepEqual(item.action, { app: "testCamera", title: "Test Your Camera…" });
  assert.equal(item.draft, false);
});

test("parseItem takes a link instead of an action, and neither", () => {
  const linked = source.replace("action: testCamera", "link: https://redlamp.app/cameras/test");
  assert.deepEqual(parseItem("camera-bench", linked, files).action, {
    link: "https://redlamp.app/cameras/test",
    title: "Test Your Camera…",
  });
  const plain = source.replace(/^action: .*\n^actionTitle: .*\n/m, "");
  assert.equal(parseItem("camera-bench", plain, files).action, undefined);
});

const rejections: [string, string, RegExp][] = [
  ["a missing field", source.replace(/^title: .*\n/m, ""), /camera-bench.*title/],
  ["a version Version.xcconfig wouldn't write", source.replace("0.2.4-prealpha", "0.2.4-rc1"), /version/],
  ["a date that isn't YYYY-MM-DD", source.replace("2026-10-06", "6 October"), /date/],
  ["a symbol that isn't an SF Symbol name", source.replace("camera.badge.ellipsis", "Camera Badge"), /symbol/],
  ["a title that's too long", source.replace("Test your camera", "x".repeat(41)), /title longer than 40/],
  ["a summary that's too long", source.replace(/^summary: .*$/m, `summary: ${"x".repeat(91)}`), /summary longer/],
  ["too much text", source.replace("It sends only the measurements.", "x".repeat(601)), /more than 600/],
  ["a heading in the text", source.replace("It sends", "## It sends"), /inline Markdown/],
  ["an image in the text", source.replace("It sends", "![shot](a.png) It sends"), /inline Markdown/],
  ["raw HTML in the text", source.replace("It sends", "<b>It</b> sends"), /inline Markdown/],
  ["an image that isn't there", source.replace("image: results.png", "image: missing.png"), /isn't there/],
  ["an image outside its folder", source.replace("image: results.png", "image: ../hero.png"), /beside its index\.md/],
  ["an action the app doesn't offer", source.replace("action: testCamera", "action: resetAll"), /resetAll/],
  ["a link that isn't https", source.replace("action: testCamera", "link: http://example.com"), /https/],
  ["both an action and a link", source.replace("action: testCamera", "action: testCamera\nlink: https://a.b"), /one button/],
  ["an action without a title", source.replace(/^actionTitle: .*\n/m, ""), /actionTitle/],
  ["no front matter", "Hello.", /front matter/],
];

for (const [problem, text, message] of rejections) {
  test(`parseItem rejects ${problem}, naming the item`, () => {
    assert.throws(() => parseItem("camera-bench", text, files), (error: Error) => {
      assert.match(error.message, /What's New item "camera-bench"/);
      assert.match(error.message, message);
      return true;
    });
  });
}

test("parseItem rejects a folder name that isn't lowercase with hyphens", () => {
  assert.throws(() => parseItem("Camera Bench", source, files), /lowercase/);
});

test("parseItem checks the image's size and shape", () => {
  const withImage = (bytes: Buffer) => () => parseItem("camera-bench", source, () => bytes);
  assert.throws(withImage(png(800, 500)), /narrower than 1040/);
  assert.throws(withImage(png(2000, 800)), /4:3 to 16:9/);
  assert.throws(withImage(png(1040, 1040)), /4:3 to 16:9/);
  assert.throws(withImage(Buffer.from("GIF89a")), /isn't a PNG or JPEG/);
  assert.equal(withImage(png(1920, 1080))().image.width, 1920);
  assert.equal(withImage(png(1600, 1200))().image.height, 1200);
});

test("imageSize reads PNG and JPEG headers", () => {
  assert.deepEqual(imageSize(png(2080, 1504)), { width: 2080, height: 1504 });
  assert.deepEqual(imageSize(jpeg(1600, 1000)), { width: 1600, height: 1000 });
  assert.equal(imageSize(Buffer.from("not an image")), null);
});

test("compareVersions orders numbers numerically and stages before the release", () => {
  const sorted = ["0.3.0", "0.2.10-prealpha", "0.3.0-beta", "0.2.4-prealpha", "0.3.0-alpha", "0.3.0-prealpha"].sort(
    compareVersions,
  );
  assert.deepEqual(sorted, ["0.2.4-prealpha", "0.2.10-prealpha", "0.3.0-prealpha", "0.3.0-alpha", "0.3.0-beta", "0.3.0"]);
});

function folder(items: Record<string, string>): string {
  const dir = mkdtempSync(path.join(tmpdir(), "whats-new-"));
  for (const [id, front] of Object.entries(items)) {
    mkdirSync(path.join(dir, id));
    writeFileSync(path.join(dir, id, "index.md"), front);
    writeFileSync(path.join(dir, id, "results.png"), png(2080, 1504));
  }
  mkdirSync(path.join(dir, "no-item-here"));
  return dir;
}

const at = (version: string, date: string, extra = "") =>
  source.replace("0.2.4-prealpha", version).replace("2026-10-06", date).replace("---\n\n", `${extra}---\n\n`);

test("readItems lists the newest release first, then the newest date", () => {
  const dir = folder({
    bench: at("0.2.4-prealpha", "2026-10-06"),
    menu: at("0.2.4-prealpha", "2026-10-07"),
    later: at("0.2.10-prealpha", "2026-11-01"),
  });
  assert.deepEqual(readItems(dir).map((item) => item.id), ["later", "menu", "bench"]);
});

test("readItems leaves drafts out unless asked for them", () => {
  const dir = folder({ live: at("0.2.4-prealpha", "2026-10-06"), wip: at("0.2.4-prealpha", "2026-10-07", "draft: true\n") });
  assert.deepEqual(readItems(dir).map((item) => item.id), ["live"]);
  assert.deepEqual(readItems(dir, { drafts: true }).map((item) => item.id), ["wip", "live"]);
});

test("readItems keeps a release to four highlights", () => {
  const dir = folder(Object.fromEntries(["a", "b", "c", "d", "e"].map((id) => [id, at("0.2.4-prealpha", "2026-10-06")])));
  assert.throws(() => readItems(dir), /5 items for 0\.2\.4-prealpha/);
});

test("readItems finds nothing in a folder that doesn't exist", () => {
  assert.deepEqual(readItems(path.join(tmpdir(), "no-such-whats-new")), []);
});

test("feed is the format and the items, without the draft flag", () => {
  const result = feed([parseItem("camera-bench", source, files)]);
  assert.equal(result.format, 1);
  assert.equal(result.items[0].id, "camera-bench");
  assert.equal("draft" in result.items[0], false);
});
