import type { FC } from "react";
import { AbsoluteFill, Html5Audio, interpolate, staticFile, useVideoConfig } from "remotion";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { Editor } from "./scenes/Editor";
import { End } from "./scenes/End";
import { Essentials } from "./scenes/Essentials";
import { Film } from "./scenes/Film";
import { Hook } from "./scenes/Hook";
import { Masks } from "./scenes/Masks";
import { Originals } from "./scenes/Originals";
import { Speed } from "./scenes/Speed";
import { color } from "./theme";
import { transitionEase, whip, zoom } from "./transitions";

const scenes: Record<string, FC> = {
  hook: Hook,
  editor: Editor,
  speed: Speed,
  masks: Masks,
  film: Film,
  originals: Originals,
  essentials: Essentials,
  end: End,
};

type SceneId = keyof typeof scenes;
export type Cut = "explainer" | "social";
type Into = "zoom" | "whip";

/** Each cut is a list of scenes, their lengths in frames at 30 fps, and how each one arrives. */
export const cuts: Record<Cut, [SceneId, number, Into][]> = {
  explainer: [
    ["hook", 54, "zoom"],
    ["editor", 160, "zoom"],
    ["speed", 72, "whip"],
    ["masks", 112, "zoom"],
    ["film", 128, "whip"],
    ["originals", 72, "zoom"],
    ["essentials", 96, "whip"],
    ["end", 78, "zoom"],
  ],
  social: [
    ["hook", 54, "zoom"],
    ["editor", 160, "zoom"],
    ["masks", 112, "whip"],
    ["film", 128, "whip"],
    ["essentials", 96, "zoom"],
    ["end", 78, "zoom"],
  ],
};

const TRANSITION = 8;

export function durationOf(cut: Cut): number {
  const list = cuts[cut];
  return list.reduce((sum, [, frames]) => sum + frames, 0) - TRANSITION * (list.length - 1);
}

export type ExplainerProps = {
  cut: Cut;
  /** A file in public/, e.g. "audio/music.mp3". Cuts land on a 120 BPM grid. Silent until one is supplied. */
  musicSrc: string | null;
};

export const Explainer: FC<ExplainerProps> = ({ cut, musicSrc }) => {
  const { durationInFrames } = useVideoConfig();
  const list = cuts[cut];
  const children = list.flatMap(([id, frames, into], i) => {
    const Scene = scenes[id];
    const sequence = (
      <TransitionSeries.Sequence key={`${id}-${i}`} durationInFrames={frames}>
        <Scene />
      </TransitionSeries.Sequence>
    );
    if (i === 0) return [sequence];
    return [
      <TransitionSeries.Transition
        key={`t-${i}`}
        presentation={into === "zoom" ? zoom() : whip()}
        timing={linearTiming({ durationInFrames: TRANSITION, easing: transitionEase })}
      />,
      sequence,
    ];
  });
  return (
    <AbsoluteFill style={{ background: color.wall }}>
      <TransitionSeries>{children}</TransitionSeries>
      {musicSrc ? (
        <Html5Audio
          src={staticFile(musicSrc)}
          volume={(f) =>
            interpolate(f, [0, 4, durationInFrames - 20, durationInFrames], [0, 0.85, 0.85, 0], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            })
          }
        />
      ) : null}
    </AbsoluteFill>
  );
};
