import { AbsoluteFill, type CalculateMetadataFunction, getStaticFiles, Html5Audio, Img, interpolate, Sequence, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { type CueSheet, grid } from "../kit/grid";
import { SafeZones } from "../kit/SafeZones";
import cueSheet from "./cues.json";

/**
 * The feature videos (docs/plans/2026-10-10-feature-videos.md): Redlamp's opener in pixel art, then
 * one Redlamp feature shown in a pixel-art editor and its result, every picture drawn by pixelkit.
 * scripts/features-frames.py draws an episode's frames, the opener's first, into
 * public/features/<episode>/frames/ and lists each frame's file in frames.json: the 216 × 384 canvas,
 * shown five times the size with nearest-neighbour scaling, or the whole 1080 × 1920 frame while a
 * real photo is on screen. scripts/features-score.py writes the episode's score beside them, and the
 * opener's sound, Introducing Redlamp's own with the score's lead-in over its end: opener.wav for
 * score.wav, opener-<arrangement>.wav for score-<arrangement>.wav.
 */
const sheet = cueSheet as unknown as CueSheet & { opener: { bpm: number; bars: number } };
const g = grid(sheet);

/** The opener's frames: its bars on Introducing Redlamp's grid, at the series' frame rate. */
export const OPENER = Math.round((sheet.opener.bars * sheet.beatsPerBar * 60 * sheet.fps) / sheet.opener.bpm);

/** An episode's frames, without the opener. */
export const EPISODE_FRAMES = g.frames;
export const FEATURE_VIDEO_FRAMES = OPENER + EPISODE_FRAMES;

export type FeatureHook = "a" | "b";

/** What scripts/features-frames.py wrote: each hook's file for every frame. */
export type FeatureFrames = {
  episode: string;
  fps: number;
  /** How many of each hook's frames are the opener's, before the episode's first. */
  opener: number;
  frames: Partial<Record<FeatureHook, string[]>>;
  /** The real result is a stand-in edit until the owner's own is saved beside the raw. */
  standIn?: boolean;
};

export type FeatureVideoProps = {
  /** An episode in docs/social/posts.json, such as e01. */
  episode: string;
  hook: FeatureHook;
  /**
   * The score in public/features/<episode>/ that plays, without .wav: score, the arrangement chosen for
   * the cut, or score-<arrangement> (score-drive, score-pulse) to compare them against the picture.
   */
  score: string;
  /** The opener before the episode; off to look at the episode alone, on its own cue sheet's frames. */
  opener: boolean;
  /** The apps' safe zones over the frame, for review in Studio; never in a cut. */
  guides: boolean;
  /** Read from public/features/<episode>/frames.json by withFrames. */
  manifest: FeatureFrames | null;
};

export const withFrames: CalculateMetadataFunction<FeatureVideoProps> = async ({ props }) => {
  const durationInFrames = (props.opener ? OPENER : 0) + EPISODE_FRAMES;
  try {
    const response = await fetch(staticFile(`features/${props.episode}/frames.json`));
    return { durationInFrames, props: { ...props, manifest: response.ok ? ((await response.json()) as FeatureFrames) : null } };
  } catch {
    return { durationInFrames, props: { ...props, manifest: null } };
  }
};

export function FeatureVideo({ episode, hook, score, opener, guides, manifest }: FeatureVideoProps) {
  const files = getStaticFiles();
  const has = (name: string) => files.some((f) => f.name === name);
  const start = opener ? OPENER : 0;
  const openerScore = `features/${episode}/${score.replace(/^score/, "opener")}.wav`;
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <Frames episode={episode} hook={hook} manifest={manifest} skip={opener ? 0 : (manifest?.opener ?? 0)} />
      {opener && has(openerScore) ? (
        <Sequence durationInFrames={OPENER} name="Opener">
          <Html5Audio
            src={staticFile(openerScore)}
            volume={(f) => interpolate(f, [0, 10], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
          />
        </Sequence>
      ) : null}
      <Sequence from={start} name={episode}>
        {has(`features/${episode}/${score}.wav`) ? (
          <Html5Audio
            src={staticFile(`features/${episode}/${score}.wav`)}
            volume={(f) =>
              interpolate(f, [0, 2, EPISODE_FRAMES - 3, EPISODE_FRAMES], [opener ? 1 : 0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
            }
          />
        ) : null}
      </Sequence>
      {guides ? <SafeZones /> : null}
    </AbsoluteFill>
  );
}

/** The frames the frames script drew, from the `skip`th: the opener's and the episode's. */
function Frames({ episode, hook, manifest, skip }: Pick<FeatureVideoProps, "episode" | "hook" | "manifest"> & { skip: number }) {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  const file = manifest?.frames[hook]?.[frame + skip];
  if (!file) {
    return (
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", color: "#7c7c7c", font: `500 ${Math.round(width / 36)}px Inter, sans-serif` }}>
        {`No frames for ${episode}, hook ${hook}: python3 scripts/features-frames.py --episode ${episode}`}
      </AbsoluteFill>
    );
  }
  return (
    <Img
      src={staticFile(`features/${episode}/frames/${file}`)}
      style={{ width: "100%", height: "100%", imageRendering: file.startsWith("px-") ? "pixelated" : "auto" }}
    />
  );
}
