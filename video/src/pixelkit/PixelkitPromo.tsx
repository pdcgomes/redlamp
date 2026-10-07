import { AbsoluteFill, getStaticFiles, Html5Audio, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { type CueSheet, grid } from "../kit/grid";
import copy from "./copy.json";
import cueSheet from "./cues.json";

/**
 * The pixelkit promo: 30 seconds for X about github.com/pdcgomes/pixelartvisuals, every picture
 * drawn by the kit itself. scripts/pixelkit-frames.py draws each frame at the kit's 320×180 canvas
 * into public/pixelkit/frames/; this shows them six times the size with nearest-neighbour scaling,
 * so each pixel is a 6×6 block at 1920×1080, and plays scripts/pixelkit-score.py's score with them.
 * Design: docs/plans/2026-10-07-pixelkit-promo.md.
 */
const g = grid(cueSheet as unknown as CueSheet);

export const PIXELKIT_PROMO_FRAMES = g.frames;

export type PixelkitHook = keyof typeof copy.hooks;

/** The hook the main frames are drawn with; the others have their opening in frames-<hook>/. */
export const DEFAULT_HOOK = Object.keys(copy.hooks)[0] as PixelkitHook;

/** Frames that differ between hooks: everything before the BBS answers. */
const OPENING = Math.round(g.cue("bbs"));

export type PixelkitPromoProps = {
  hook: PixelkitHook;
  /** The score in public/ (scripts/pixelkit-score.py writes pixelkit/score.wav). Silent while it's missing. */
  musicSrc: string | null;
};

const frameFile = (hook: PixelkitHook, frame: number) => {
  const folder = hook !== DEFAULT_HOOK && frame < OPENING ? `pixelkit/frames-${hook}` : "pixelkit/frames";
  return `${folder}/${String(frame).padStart(4, "0")}.png`;
};

export function PixelkitPromo({ hook, musicSrc }: PixelkitPromoProps) {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const files = getStaticFiles();
  const file = frameFile(hook, frame);
  const drawn = files.some((f) => f.name === file);
  const music = musicSrc && files.some((f) => f.name === musicSrc) ? musicSrc : null;
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      {drawn ? <Img src={staticFile(file)} style={{ width: "100%", height: "100%", imageRendering: "pixelated" }} /> : null}
      {music ? (
        <Html5Audio
          src={staticFile(music)}
          volume={(f) => interpolate(f, [durationInFrames - 3, durationInFrames], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
        />
      ) : null}
    </AbsoluteFill>
  );
}
