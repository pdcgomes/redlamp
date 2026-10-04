import type { FC, ReactNode } from "react";
import { AbsoluteFill, getStaticFiles, Html5Audio, interpolate, Sequence, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { type Manifest, ManifestContext } from "./assets";
import cutBars from "./cuts.json";
import { End } from "./scenes/End";
import { Familiar } from "./scenes/Familiar";
import { Film } from "./scenes/Film";
import { Keyboard } from "./scenes/Keyboard";
import { Masks } from "./scenes/Masks";
import { Native } from "./scenes/Native";
import { Originals } from "./scenes/Originals";
import { Reveal } from "./scenes/Reveal";
import { Safelight } from "./scenes/Safelight";
import { Steps } from "./scenes/Steps";
import { BAR, font, ink, neutral } from "./style";

export type SceneProps = { length: number };

const scenes: Record<string, FC<SceneProps>> = {
  safelight: Safelight,
  reveal: Reveal,
  familiar: Familiar,
  steps: Steps,
  originals: Originals,
  masks: Masks,
  film: Film,
  keyboard: Keyboard,
  native: Native,
  end: End,
};

export type Cut = keyof typeof cutBars;

/**
 * Each cut's scenes and their lengths in frames, from cuts.json (in bars), which the score
 * (scripts/score.py) is written from too. Scenes start on the 72 BPM grid's bar lines, or its
 * half bars, and crossfade across them, `OVERLAP` frames either side.
 */
export const cuts = Object.fromEntries(
  Object.entries(cutBars).map(([cut, scenes]) => [cut, scenes.map(([id, bars]) => [String(id), Number(bars) * BAR] as [string, number])]),
) as Record<Cut, [string, number][]>;

export const OVERLAP = 12;

export function durationOf(cut: Cut): number {
  return cuts[cut].reduce((sum, [, length]) => sum + length, 0);
}

export type IntroducingProps = {
  cut: Cut;
  /** A file in public/: the score scripts/score.py writes, or a licensed track. Silent while it's missing. */
  musicSrc: string | null;
  /** Filled in by calculateMetadata from public/film/renders/manifest.json. */
  manifest: Manifest;
};

export const Introducing: FC<IntroducingProps> = ({ cut, musicSrc, manifest }) => {
  const { durationInFrames } = useVideoConfig();
  const music = musicSrc && getStaticFiles().some((file) => file.name === musicSrc) ? musicSrc : null;
  let start = 0;
  const sequences = cuts[cut].map(([id, length], i) => {
    const Scene = scenes[id] ?? slate(id);
    const first = i === 0;
    const last = i === cuts[cut].length - 1;
    const from = first ? 0 : start - OVERLAP;
    const duration = length + (first ? 0 : OVERLAP) + (last ? 0 : OVERLAP);
    start += length;
    return (
      <Sequence key={`${id}-${i}`} from={from} durationInFrames={duration} name={id}>
        <Fade duration={duration} fadeIn={!first} fadeOut={!last}>
          <Scene length={duration} />
        </Fade>
      </Sequence>
    );
  });
  return (
    <ManifestContext.Provider value={manifest}>
      <AbsoluteFill style={{ background: neutral.deep }}>
        {sequences}
        {music ? (
          <Html5Audio
            src={staticFile(music)}
            volume={(f) =>
              interpolate(f, [0, 10, durationInFrames - 45, durationInFrames], [0, 1, 1, 0], {
                extrapolateLeft: "clamp",
                extrapolateRight: "clamp",
              })
            }
          />
        ) : null}
      </AbsoluteFill>
    </ManifestContext.Provider>
  );
};

/** Each scene dissolves in and out across its cuts. */
function Fade({ duration, fadeIn, fadeOut, children }: { duration: number; fadeIn: boolean; fadeOut: boolean; children: ReactNode }) {
  const frame = useCurrentFrame();
  const inOpacity = fadeIn ? interpolate(frame, [0, OVERLAP * 2], [0, 1], { extrapolateRight: "clamp" }) : 1;
  const outOpacity = fadeOut ? interpolate(frame, [duration - OVERLAP * 2, duration], [1, 0], { extrapolateLeft: "clamp" }) : 1;
  return <AbsoluteFill style={{ opacity: Math.min(inOpacity, outOpacity) }}>{children}</AbsoluteFill>;
}

/** Stands in for a scene that isn't built yet. */
function slate(id: string): FC<SceneProps> {
  return function Slate() {
    return (
      <AbsoluteFill
        style={{ alignItems: "center", justifyContent: "center", background: neutral.room, fontFamily: font.family, fontSize: 48, color: ink.small }}
      >
        {id}
      </AbsoluteFill>
    );
  };
}
