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
      "In Redlamp, choose Help › Test Your Camera…, or press ⌘K and type “camera”. The bench opens in its own window and leaves the photo you're editing as it is.",
    ],
    shot: benchShot(
      "camera-bench-start.png",
      "The Camera Bench's start page: what the bench checks, the photos that help most, and the buttons for choosing photos",
      "The start page, with the photos that help most.",
    ),
  },
  {
    title: "Choose photos from your camera",
    body: [
      "Choose a folder of raw files from your camera, or just a few files. You don't need to say which camera or lens took them: the bench reads that from the files. It also reads each file's raw mode, such as compressed or uncompressed, because one camera's raw modes can behave differently. It tests up to eight photos in each mode.",
      "Photos you already have will do. These help most:",
    ],
    list: [
      "One at base ISO (200 or lower) and one at ISO 3200 or higher.",
      "One taken in portrait orientation.",
      "One with clipped highlights, such as a bright sky, the sun or a lamp.",
      "One taken indoors under warm light.",
      "One in each raw mode your camera offers, such as compressed, lossless, uncompressed or a crop mode.",
    ],
  },
  {
    title: "Read what it found",
    body: [
      "On the left, the bench lists each camera and raw mode it found. For the one you select, it shows the checks it ran. Some check how the files decode: the black and white levels, the colour matrix and the edges of the frame. Others compare Redlamp's rendering with the JPEG your camera saved inside each file: orientation, framing, detail, exposure, neutral greys and highlights. Below the checks, Redlamp's rendering of each photo sits beside your camera's.",
      "Then answer the question beneath them: “Apart from your camera's picture style, do these look like the same photos?”",
    ],
    shot: benchShot(
      "camera-bench-results.png",
      "The Camera Bench's results for a Fujifilm X-T3: every check passed, and Redlamp's rendering beside the camera's JPEG",
      "Each camera and raw mode it found is on the left, with the checks, the photos and the question on the right.",
    ),
  },
  {
    title: "Review the report and send it",
    body: [
      "What's Sent shows the report exactly as it will be sent. It holds only what the bench read and measured: the camera, lens and capture settings, the black and white levels and colour matrix, the result of each check, your answers and Redlamp's version. It never contains your photos or any of their pixels, file names, folders, GPS locations, serial numbers, owner or copyright details, or capture times.",
      "A random ID stored on your Mac lets the results count how many different people tested each camera; Reset Contributor ID replaces it whenever you like. You can add a name to be credited. Then choose Send Results.",
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
      "Report This Problem opens Redlamp's feedback form with what the bench found already filled in, so you only need to describe what you saw. You can add screenshots if they help.",
    ],
  },
];
