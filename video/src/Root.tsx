import { type CalculateMetadataFunction, Composition, Folder, Still } from "remotion";
import { durationOf, Explainer, type ExplainerProps } from "./Explainer";
import { loadManifest } from "./introducing/assets";
import { durationOf as filmDuration, Introducing, type IntroducingProps } from "./introducing/Introducing";
import { stories } from "./introducing/Posters";
import { stills } from "./stills";
import { canvas } from "./stills/canvas";
import "./theme";

const FPS = 30;

const withManifest: CalculateMetadataFunction<IntroducingProps> = async ({ props }) => ({
  props: { ...props, manifest: await loadManifest() },
});

export function RemotionRoot() {
  const explainer: ExplainerProps = { cut: "explainer", musicSrc: null };
  const social: ExplainerProps = { cut: "social", musicSrc: null };
  return (
    <>
      <Composition
        id="Explainer"
        component={Explainer}
        durationInFrames={durationOf("explainer")}
        fps={FPS}
        width={1920}
        height={1080}
        defaultProps={explainer}
      />
      <Composition
        id="Social9x16"
        component={Explainer}
        durationInFrames={durationOf("social")}
        fps={FPS}
        width={1080}
        height={1920}
        defaultProps={social}
      />
      <Composition
        id="Social1x1"
        component={Explainer}
        durationInFrames={durationOf("social")}
        fps={FPS}
        width={1080}
        height={1080}
        defaultProps={social}
      />
      <Folder name="Introducing">
        <Composition
          id="Introducing"
          component={Introducing}
          durationInFrames={filmDuration("film")}
          fps={FPS}
          width={1920}
          height={1080}
          defaultProps={{ cut: "film", musicSrc: "film/score-film.wav", manifest: {} } satisfies IntroducingProps}
          calculateMetadata={withManifest}
        />
        <Composition
          id="Introducing9x16"
          component={Introducing}
          durationInFrames={filmDuration("short")}
          fps={FPS}
          width={1080}
          height={1920}
          defaultProps={{ cut: "short", musicSrc: "film/score-short.wav", manifest: {} } satisfies IntroducingProps}
          calculateMetadata={withManifest}
        />
        <Composition
          id="Introducing4x5"
          component={Introducing}
          durationInFrames={filmDuration("short")}
          fps={FPS}
          width={1080}
          height={1350}
          defaultProps={{ cut: "short", musicSrc: "film/score-short.wav", manifest: {} } satisfies IntroducingProps}
          calculateMetadata={withManifest}
        />
        {stories.map(({ id, component, durationInFrames }) => (
          <Composition key={id} id={id} component={component} durationInFrames={durationInFrames} fps={FPS} width={1080} height={1920} />
        ))}
      </Folder>
      <Folder name="Stills">
        {stills.map(({ id, component }) => (
          <Still key={id} id={id} component={component} width={canvas.width} height={canvas.height} />
        ))}
      </Folder>
    </>
  );
}
