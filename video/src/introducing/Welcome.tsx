import { AbsoluteFill, Freeze, getStaticFiles, Html5Audio, interpolate, staticFile, useVideoConfig } from "remotion";
import { cuts, OVERLAP } from "./Introducing";
import { type Rise, Safelight } from "./scenes/Safelight";

const SCORE = "film/score-welcome.wav";

/**
 * As long as the film gives its opening scene (its bars and the frames it overlaps the next), so
 * the opening moves exactly as the film's does, on the same beats as the welcome's score.
 */
const opening = cuts.welcome[0][1] + OVERLAP;

/**
 * Where the logo comes to rest, in the 1920 × 1080 frame: the app's welcome window
 * (packages/RedlampUI/Sources/Welcome/WelcomeView.swift) sets its pages beneath it.
 */
export const rise: Rise = { at: 335, duration: 45, width: 400, y: 192 };
const still = rise.at + rise.duration;

/**
 * The app's welcome window, at 2x its 960 × 540 points: the film's opening as it is, then the logo
 * rises to the top of the window, where the welcome's pages appear, and the picture holds while
 * the score dies away. Its score is the `welcome` cut in cuts.json: the opening, then a hold.
 */
export function Welcome() {
  const { durationInFrames } = useVideoConfig();
  const music = getStaticFiles().some((file) => file.name === SCORE) ? SCORE : null;
  return (
    <AbsoluteFill>
      <Freeze frame={still} active={(frame) => frame >= still}>
        <Safelight length={opening} rise={rise} />
      </Freeze>
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
  );
}
