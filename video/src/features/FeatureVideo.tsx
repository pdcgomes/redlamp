import { AbsoluteFill, type CalculateMetadataFunction, getStaticFiles, Html5Audio, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { type CueSheet, grid } from "../kit/grid";
import { SafeZones } from "../kit/SafeZones";
import cueSheet from "./cues.json";

/**
 * The feature videos (docs/plans/2026-10-10-feature-videos.md): 19.2 seconds each, one Redlamp feature
 * shown in a pixel-art editor and then on the owner's real photo, every picture drawn by pixelkit.
 * scripts/features-frames.py draws an episode's frames into public/features/<episode>/frames/ and
 * lists each frame's file in frames.json: the 216 × 384 canvas, shown five times the size with
 * nearest-neighbour scaling, or the whole 1080 × 1920 frame while a real photo is on screen.
 * scripts/features-score.py writes the episode's score beside them.
 */
const g = grid(cueSheet as unknown as CueSheet);

export const FEATURE_VIDEO_FRAMES = g.frames;

export type FeatureHook = "a" | "b";

/** What scripts/features-frames.py wrote: each hook's file for every frame. */
export type FeatureFrames = {
  episode: string;
  fps: number;
  frames: Partial<Record<FeatureHook, string[]>>;
  /** The real result is a stand-in edit until the owner's own is saved beside the raw. */
  standIn?: boolean;
};

export type FeatureVideoProps = {
  /** An episode in docs/social/posts.json, such as e01. */
  episode: string;
  hook: FeatureHook;
  /** The apps' safe zones over the frame, for review in Studio; never in a cut. */
  guides: boolean;
  /** Read from public/features/<episode>/frames.json by withFrames. */
  manifest: FeatureFrames | null;
};

export const withFrames: CalculateMetadataFunction<FeatureVideoProps> = async ({ props }) => {
  try {
    const response = await fetch(staticFile(`features/${props.episode}/frames.json`));
    return { props: { ...props, manifest: response.ok ? ((await response.json()) as FeatureFrames) : null } };
  } catch {
    return { props: { ...props, manifest: null } };
  }
};

export function FeatureVideo({ episode, hook, guides, manifest }: FeatureVideoProps) {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const file = manifest?.frames[hook]?.[frame];
  const score = `features/${episode}/score.wav`;
  const music = getStaticFiles().some((f) => f.name === score);
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      {file ? (
        <Img
          src={staticFile(`features/${episode}/frames/${file}`)}
          style={{ width: "100%", height: "100%", imageRendering: file.startsWith("px-") ? "pixelated" : "auto" }}
        />
      ) : (
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", color: "#7c7c7c", font: "500 30px Inter, sans-serif" }}>
          {`No frames for ${episode}, hook ${hook}: python3 scripts/features-frames.py --episode ${episode}`}
        </AbsoluteFill>
      )}
      {music ? (
        <Html5Audio
          src={staticFile(score)}
          volume={(f) => interpolate(f, [durationInFrames - 3, durationInFrames], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
        />
      ) : null}
      {guides ? <SafeZones /> : null}
    </AbsoluteFill>
  );
}
