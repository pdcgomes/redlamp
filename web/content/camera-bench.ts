import type { Shot } from "./features.ts";

/**
 * The Test your camera page (/cameras/test): how to run the app's camera bench (docs/camera-bench.md)
 * on your own photos. The screenshots are the Camera Bench window on the CC0 development samples,
 * captured with `--camera-bench` in a development build, and synced from docs/images.
 */

const benchShot = (file: string, alt: string, caption: string): Shot => ({
  src: `/synced/images/${file}`,
  alt,
  caption,
  width: 2080,
  height: 1504,
});

export type BenchStep = { title: string; body: string[]; list?: string[]; shot?: Shot };

export const benchSteps: BenchStep[] = [
  {
    title: "Open the Camera Bench",
    body: [
      "In Redlamp, choose Help › Test Your Camera…, or press ⌘K and type camera. The bench opens in a window of its own, so the photo in the editor stays as it is.",
    ],
    shot: benchShot(
      "camera-bench-start.png",
      "The Camera Bench window before any photos are chosen, with its two buttons",
      "The Camera Bench before any photos are chosen, with what helps most.",
    ),
  },
  {
    title: "Choose photos from your camera",
    body: [
      "Choose a folder of raw files straight from your camera, or a few of them. The bench reads each file to find its camera and raw mode, since one body's compressed and uncompressed raws can behave differently, and picks up to eight photos of each mode. You don't pick the camera or the lens: they come from the files.",
      "Photos you already have are enough. These help the most:",
    ],
    list: [
      "One at base ISO, 200 or lower, and one at ISO 3200 or higher.",
      "One held upright, in portrait orientation.",
      "One with a bright sky, the sun or a lamp in it, so some highlights clip.",
      "One indoors under warm light.",
      "One in each raw mode your camera offers: compressed, lossless, uncompressed, or a crop mode.",
    ],
  },
  {
    title: "Read what it found",
    body: [
      "For each camera mode, the bench lists its checks: how the files decode (the black and white levels, the colour matrix, the edges of the frame) and how Redlamp's rendering compares with the JPEG your camera saved inside each file (orientation, framing, detail, exposure, neutrals and highlights). Below them, Redlamp's rendering sits beside your camera's for each photo.",
      "Then answer one question: apart from your camera's picture style, do they look like the same photos?",
    ],
    shot: benchShot(
      "camera-bench-results.png",
      "The Camera Bench's results for a Fujifilm X-T3: every check passed, and Redlamp's rendering beside the camera's JPEG",
      "Each camera mode on the left; its checks, the side-by-side pairs and the question on the right.",
    ),
  },
  {
    title: "See what's sent, then send it",
    body: [
      "What's Sent shows the report exactly as it will be sent. It holds measurements only: the camera, lens and capture settings, the decode's levels and colour matrix, each check's numbers, your answers and Redlamp's version. It never holds your photos or any of their pixels, and no file names, folders, GPS, serial numbers, owner or copyright fields, or capture times.",
      "A random ID, kept on your Mac and reset with a button, counts how many people tested each camera. Add a name if you'd like to be credited. Then choose Send Results.",
    ],
    shot: benchShot(
      "camera-bench-sent.png",
      "What's Sent: the report as JSON, measurements only, with Reset Contributor ID and Done",
      "What's Sent, before anything leaves your Mac.",
    ),
  },
  {
    title: "If something looks wrong",
    body: [
      "Report This Problem opens Report a Bug or Send Feedback with what the bench found already written in, so you only need to add what you saw. A screenshot is up to you.",
    ],
  },
];
