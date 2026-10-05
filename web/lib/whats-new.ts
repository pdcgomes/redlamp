/**
 * What's New: each release's highlights, for the app's What's New window. One folder per highlight,
 * `content/whats-new/<id>/index.md`, with its screenshot beside it, served whole by `/api/whats-new`,
 * which no page links to. Relative imports only, so `node --test` can load it.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { readFrontMatter } from "./front-matter.ts";

/** The app actions a highlight's button can run: only ones that open something (`WhatsNewAction` in the app). */
export const appActions = ["testCamera", "sendFeedback", "filmLooks", "showShortcuts", "commandPalette"] as const;

/** Highlights stay short, and few: the window shows a page each, and lists them on one. */
export const limits = { title: 40, summary: 90, body: 600, actionTitle: 32, perVersion: 4, imageWidth: 1040 };

export type WhatsNewItem = {
  id: string;
  /** The release it's in, as `Version.xcconfig` writes it: `0.2.4-prealpha`. */
  version: string;
  /** YYYY-MM-DD. */
  date: string;
  /** An SF Symbol, for the window's list of highlights. */
  symbol: string;
  title: string;
  /** One line, for the window's list of highlights. */
  summary: string;
  /** A paragraph or two of inline Markdown, separated by a blank line. */
  body: string;
  /** Served from `public/synced/whats-new/<id>/`; the app resolves it against the feed's URL. */
  image: { url: string; alt: string; width: number; height: number };
  action?: { app: string; title: string } | { link: string; title: string };
  /** Left out of production builds. */
  draft: boolean;
};

export type Feed = { format: 1; items: Omit<WhatsNewItem, "draft">[] };

const stages = ["prealpha", "alpha", "beta"];

/** Orders versions as the app does: 0.2.4 before 0.2.10, and a release's stages before the release. */
export function compareVersions(a: string, b: string): number {
  const parse = (version: string) => {
    const [numbers, stage] = version.split("-");
    return [...numbers.split(".").map(Number), stage ? stages.indexOf(stage) : stages.length];
  };
  const [x, y] = [parse(a), parse(b)];
  for (let i = 0; i < x.length; i += 1) {
    if (x[i] !== y[i]) return x[i] - y[i];
  }
  return 0;
}

/** A PNG's or JPEG's size in pixels, from its header. */
export function imageSize(bytes: Buffer): { width: number; height: number } | null {
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) return null;
    const marker = bytes[offset + 1];
    const length = bytes.readUInt16BE(offset + 2);
    const startOfFrame = marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
    if (startOfFrame) return { width: bytes.readUInt16BE(offset + 7), height: bytes.readUInt16BE(offset + 5) };
    offset += 2 + length;
  }
  return null;
}

/**
 * Reads and checks a highlight. `file` gives the bytes of a file beside its `index.md`, or
 * undefined when there's none. A problem throws, naming the item, and stops the build.
 */
export function parseItem(id: string, source: string, file: (name: string) => Buffer | undefined): WhatsNewItem {
  const fail = (problem: string): never => {
    throw new Error(`What's New item "${id}" ${problem}`);
  };
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id)) fail("needs a folder name in lowercase letters, digits and hyphens");
  const front = readFrontMatter(source) ?? fail("has no front matter");
  const { fields } = front;
  const required = (key: string, limit?: number) => {
    const value = fields.get(key) ?? fail(`needs a ${key} in its front matter`);
    if (!value) fail(`needs a ${key} in its front matter`);
    if (limit && value.length > limit) fail(`has a ${key} longer than ${limit} characters`);
    return value;
  };

  const version = required("version");
  if (!/^\d+\.\d+\.\d+(?:-(?:prealpha|alpha|beta))?$/.test(version)) {
    fail(`has a version that isn't one Version.xcconfig would write, such as 0.2.4-prealpha: ${version}`);
  }
  const date = required("date");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) fail(`has a date that isn't YYYY-MM-DD: ${date}`);
  const symbol = required("symbol");
  if (!/^[a-z0-9]+(?:\.[a-z0-9]+)*$/.test(symbol)) fail(`has a symbol that isn't an SF Symbol name: ${symbol}`);

  const body = front.body.trim();
  if (!body) fail("has no text under its front matter");
  if (body.length > limits.body) fail(`has more than ${limits.body} characters of text`);
  if (/^\s*(?:#|[-*+] |\d+\. |>|```)/m.test(body) || /!\[|</.test(body)) {
    fail("uses more than inline Markdown: the window shows paragraphs with bold, italics, code and links");
  }

  const imageName = required("image");
  if (!/^[\w.-]+$/.test(imageName)) fail(`names an image that isn't a file beside its index.md: ${imageName}`);
  const bytes = file(imageName) ?? fail(`names an image that isn't there: ${imageName}`);
  const size = imageSize(bytes) ?? fail(`has an image that isn't a PNG or JPEG: ${imageName}`);
  if (size.width < limits.imageWidth) fail(`has an image narrower than ${limits.imageWidth} pixels: ${imageName}`);
  const aspect = size.width / size.height;
  if (aspect < 4 / 3 - 0.01 || aspect > 16 / 9 + 0.01) fail(`has an image outside 4:3 to 16:9: ${imageName}`);

  const app = fields.get("action");
  const link = fields.get("link");
  let action: WhatsNewItem["action"];
  if (app && link) fail("has both an action and a link; a page has one button");
  if (app || link) {
    const title = required("actionTitle", limits.actionTitle);
    if (app) {
      if (!(appActions as readonly string[]).includes(app)) fail(`has an action the app doesn't offer here: ${app}`);
      action = { app, title };
    } else if (link) {
      if (!/^https:\/\/\S+$/.test(link)) fail(`has a link that isn't https: ${link}`);
      action = { link, title };
    }
  }

  return {
    id,
    version,
    date,
    symbol,
    title: required("title", limits.title),
    summary: required("summary", limits.summary),
    body,
    image: { url: `/synced/whats-new/${id}/${imageName}`, alt: required("imageAlt"), ...size },
    action,
    draft: fields.get("draft") === "true",
  };
}

/** Every highlight in `dir` (one folder each, holding an `index.md`), newest release first. */
export function readItems(dir: string, { drafts = false } = {}): WhatsNewItem[] {
  if (!existsSync(dir)) return [];
  const items = readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(path.join(dir, entry.name, "index.md")))
    .map((entry) => {
      const folder = path.join(dir, entry.name);
      const file = (name: string) => (existsSync(path.join(folder, name)) ? readFileSync(path.join(folder, name)) : undefined);
      return parseItem(entry.name, readFileSync(path.join(folder, "index.md"), "utf8"), file);
    })
    .filter((item) => drafts || !item.draft)
    .sort((a, b) => compareVersions(b.version, a.version) || b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
  const counts = new Map<string, number>();
  for (const item of items) counts.set(item.version, (counts.get(item.version) ?? 0) + 1);
  for (const [version, count] of counts) {
    if (count > limits.perVersion) {
      throw new Error(`What's New has ${count} items for ${version}; keep it to the ${limits.perVersion} that matter most`);
    }
  }
  return items;
}

export function feed(items: WhatsNewItem[]): Feed {
  return { format: 1, items: items.map(({ draft: _, ...item }) => item) };
}

/** The site's highlights; drafts everywhere but production, so a preview deployment shows them in the app. */
export function whatsNew(): WhatsNewItem[] {
  return readItems(path.join(process.cwd(), "content", "whats-new"), { drafts: process.env.VERCEL_ENV !== "production" });
}
