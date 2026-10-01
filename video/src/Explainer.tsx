import type { FC } from "react";
import { AbsoluteFill, Html5Audio, interpolate, staticFile, useVideoConfig } from "remotion";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { ColdOpen } from "./scenes/ColdOpen";
import { Darkroom } from "./scenes/Darkroom";
import { EndCard } from "./scenes/EndCard";
import { Familiar } from "./scenes/Familiar";
import { Film } from "./scenes/Film";
import { Masks } from "./scenes/Masks";
import { OpenSource } from "./scenes/OpenSource";
import { Original } from "./scenes/Original";
import { Speed } from "./scenes/Speed";
import { Untether } from "./scenes/Untether";
import { color } from "./theme";

const scenes: Record<string, FC<{ dur: number }>> = {
  cold: ColdOpen,
  darkroom: Darkroom,
  untether: Untether,
  familiar: Familiar,
  speed: Speed,
  original: Original,
  masks: Masks,
  film: Film,
  open: OpenSource,
  end: EndCard,
};

type SceneId = keyof typeof scenes;
export type Cut = "explainer" | "social";

/** Each cut is a list of scenes and their lengths in frames, at 30 fps. */
export const cuts: Record<Cut, [SceneId, number][]> = {
  explainer: [
    ["cold", 180],
    ["darkroom", 240],
    ["untether", 240],
    ["familiar", 240],
    ["speed", 240],
    ["original", 240],
    ["masks", 240],
    ["film", 300],
    ["open", 240],
    ["end", 150],
  ],
  social: [
    ["cold", 140],
    ["speed", 210],
    ["masks", 210],
    ["film", 250],
    ["end", 130],
  ],
};

const TRANSITION = 15;

export function durationOf(cut: Cut): number {
  const list = cuts[cut];
  return list.reduce((sum, [, frames]) => sum + frames, 0) - TRANSITION * (list.length - 1);
}

export type ExplainerProps = {
  cut: Cut;
  /** A file in public/, e.g. "audio/music.mp3". The film is silent until one is supplied. */
  musicSrc: string | null;
};

export const Explainer: FC<ExplainerProps> = ({ cut, musicSrc }) => {
  const { durationInFrames } = useVideoConfig();
  const list = cuts[cut];
  const children = list.flatMap(([id, frames], i) => {
    const Scene = scenes[id];
    const sequence = (
      <TransitionSeries.Sequence key={`${id}-${i}`} durationInFrames={frames}>
        <Scene dur={frames} />
      </TransitionSeries.Sequence>
    );
    if (i === list.length - 1) return [sequence];
    return [
      sequence,
      <TransitionSeries.Transition key={`t-${i}`} presentation={fade()} timing={linearTiming({ durationInFrames: TRANSITION })} />,
    ];
  });
  return (
    <AbsoluteFill style={{ background: color.wall }}>
      <TransitionSeries>{children}</TransitionSeries>
      {musicSrc ? (
        <Html5Audio
          src={staticFile(musicSrc)}
          volume={(f) =>
            interpolate(f, [0, 30, durationInFrames - 45, durationInFrames], [0, 0.8, 0.8, 0], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            })
          }
        />
      ) : null}
    </AbsoluteFill>
  );
};
