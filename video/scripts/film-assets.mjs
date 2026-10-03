#!/usr/bin/env node
// Renders the engine output the film's sheets are made of, with the redlamp CLI, into
// public/film/renders/ (never committed), and lists it in public/film/renders/manifest.json:
//
//   npm run film-assets -- ~/Pictures/redlamp-promo
//
// The folder is the one scripts/capture-promo.sh captures. Its promo.txt names the photos:
//   hero, hero.edit   the History sheets: the raw before any edit, then after each command
//   night             the night scene, before and after CineStill 800T
//   cutout            a subject to lift off its background (the Subject and Background masks)
//   stocks            a colourful frame for the deck of film stocks
// The CLI comes from the Debug build (`SCHEME=redlamp mise run build`); REDLAMP_CLI overrides it.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "public/film/renders");
const cli = process.env.REDLAMP_CLI ?? path.resolve(root, "../build/DerivedData/Build/Products/Debug/redlamp");

/**
 * The stocks in the deck, front first. The film shows as many as fit, so the first five are as
 * unlike each other as the catalogue goes: a negative, two slides, a cinema print, black and white.
 */
const stocks = [
  "portra-400",
  "kodachrome-64",
  "velvia-50",
  "vision3-2383-bleach-bypass",
  "tri-x-400",
  "gold-200",
  "ektar-100",
  "cinestill-50d",
  "vision3-250d-2383",
  "provia-100f",
  "hp5-plus",
];

const [folder] = process.argv.slice(2);
if (!folder || !existsSync(path.join(folder, "promo.txt"))) {
  console.error("usage: npm run film-assets -- <photo folder with a promo.txt>");
  process.exit(1);
}
if (!existsSync(cli)) {
  console.error(`error: no redlamp CLI at ${cli}; build it (SCHEME=redlamp mise run build) or set REDLAMP_CLI`);
  process.exit(1);
}

const roles = Object.fromEntries(
  readFileSync(path.join(folder, "promo.txt"), "utf8")
    .split("\n")
    .map((line) => line.replace(/#.*/, "").trim())
    .filter(Boolean)
    .map((line) => {
      const at = line.indexOf("=");
      return [line.slice(0, at).trim(), line.slice(at + 1).trim()];
    }),
);
const photo = (role) => {
  const name = roles[role];
  if (!name) return null;
  const file = path.join(folder, name);
  if (!existsSync(file)) throw new Error(`${role} = ${name}, which isn't in ${folder}`);
  return file;
};

const run = (...args) => execFileSync(cli, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const show = (recipe) => JSON.parse(run("recipe", "show", recipe));

/** `local/<id>` is one of your own recipes; anything else is a bundled one. */
function recipeFile(id) {
  if (!id.startsWith("local/")) return id;
  return path.join(os.homedir(), "Library/Application Support/Redlamp/Recipes", `${id.slice("local/".length)}.redrecipe`);
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const manifest = {};

const hero = photo("hero");
const heroEdit = path.join(root, "public/film/captures/hero.redlamp");
if (hero && !existsSync(heroEdit)) {
  console.error(`warning: no ${heroEdit}; capture the hero shot first (scripts/capture-promo.sh), which keeps its edit`);
} else if (hero) {
  // hero.edit is the capture script's edit, a comma-separated list of `key=value` commands. The
  // sheets are the photo as it opens, then the app's saved edit with each later command's
  // setting taken out again, so every sheet renders as the app rendered that step.
  const commands = (roles["hero.edit"] ?? "").split(",").filter(Boolean).map((c) => c.split("="));
  // A sidecar is a package (edit.json and its history) or, from older builds, the edit alone.
  const packaged = statSync(heroEdit).isDirectory();
  const sidecar = JSON.parse(readFileSync(packaged ? path.join(heroEdit, "edit.json") : heroEdit, "utf8"));
  const stages = [];
  for (let i = 0; i <= commands.length; i++) {
    const file = `hero-${i}.jpg`;
    const args = [];
    if (i > 0) {
      const recipe = structuredClone(sidecar.recipe);
      for (const [key] of commands.slice(i).filter(([key]) => key !== "recipe")) {
        // Commands name a setting as the app's scripts do, `exposure` for `basic.exposure`.
        for (const id of Object.keys(recipe.values ?? {})) {
          if (id === key || id.endsWith(`.${key}`)) delete recipe.values[id];
        }
      }
      const edit = path.join(out, `hero-${i}.redlamp`);
      writeFileSync(edit, JSON.stringify({ recipe }));
      args.push("--recipe", edit);
    }
    run("render", hero, "-o", path.join(out, file), "--size", "2400", ...args);
    rmSync(path.join(out, `hero-${i}.redlamp`), { force: true });
    const [key, value] = commands[i - 1] ?? [];
    stages.push(
      key === undefined
        ? { file, step: "import" }
        : key === "recipe"
          ? { file, step: "recipe", name: show(recipeFile(value)).name }
          : { file, step: "setting", key, value: Number(value) },
    );
    console.log(`==> ${file}`);
  }
  const files = packaged ? readdirSync(heroEdit, { recursive: true }).map((f) => path.join(heroEdit, f)) : [heroEdit];
  manifest.hero = {
    name: path.basename(hero),
    bytes: statSync(hero).size,
    editBytes: files.filter((f) => statSync(f).isFile()).reduce((sum, f) => sum + statSync(f).size, 0),
    stages,
  };
}

const night = photo("night");
if (night) {
  run("render", night, "-o", path.join(out, "night.jpg"), "--size", "2048");
  run("recipe", "render", night, "--recipe", "redlamp/stock/cinestill-800t", "-o", path.join(out, "night-cinestill-800t.jpg"), "--size", "2048");
  manifest.night = { name: path.basename(night), before: "night.jpg", after: "night-cinestill-800t.jpg", look: show("redlamp/stock/cinestill-800t").name };
  console.log("==> night.jpg, night-cinestill-800t.jpg");
}

const cutout = photo("cutout");
if (cutout) {
  // Subject and Background, which the engine solves as one matte and its inverse.
  run("render", cutout, "-o", path.join(out, "cutout.jpg"), "--size", "2048");
  run("mask", cutout, "--kind", "subject", "-o", path.join(out, "cutout-subject.png"));
  run("mask", cutout, "--kind", "background", "-o", path.join(out, "cutout-background.png"));
  manifest.cutout = { name: path.basename(cutout), photo: "cutout.jpg", subject: "cutout-subject.png", background: "cutout-background.png" };
  console.log("==> cutout.jpg, cutout-subject.png, cutout-background.png");
}

const frame = photo("stocks");
if (frame) {
  run("render", frame, "-o", path.join(out, "stocks-original.jpg"), "--size", "1600");
  manifest.stocks = {
    name: path.basename(frame),
    original: "stocks-original.jpg",
    looks: stocks.map((id) => {
      const file = `stock-${id}.jpg`;
      run("recipe", "render", frame, "--recipe", `redlamp/stock/${id}`, "-o", path.join(out, file), "--size", "1600");
      const recipe = show(`redlamp/stock/${id}`);
      console.log(`==> ${file}`);
      return { id, file, name: recipe.name, summary: recipe.summary };
    }),
  };
}

writeFileSync(path.join(out, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`==> ${path.join(out, "manifest.json")}`);
