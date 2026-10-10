import { type CalculateMetadataFunction, Composition, Folder, Still } from "remotion";
import { durationOf, Explainer, type ExplainerProps } from "./Explainer";
import { FEATURE_VIDEO_FRAMES, FeatureVideo, type FeatureVideoProps, withFrames } from "./features/FeatureVideo";
import { loadManifest } from "./introducing/assets";
import { durationOf as filmDuration, Introducing, type IntroducingProps } from "./introducing/Introducing";
import { stories } from "./introducing/Posters";
import { Welcome } from "./introducing/Welcome";
import { Storyboard, type StoryboardProps, storyboardSize } from "./kit/Storyboard";
import { DEFAULT_HOOK, PIXELKIT_PROMO_FRAMES, PixelkitPromo, type PixelkitPromoProps } from "./pixelkit/PixelkitPromo";
import { STAR_PROMO_FRAMES, StarPromo, type StarPromoProps } from "./star/StarPromo";
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
  const star: StarPromoProps = { hook: "charging", stars: 25, musicSrc: "star/score.wav", guides: false };
  const pixelkit: PixelkitPromoProps = { hook: DEFAULT_HOOK, musicSrc: "pixelkit/score.wav" };
  const feature: FeatureVideoProps = { episode: "e01", hook: "a", score: "score", opener: true, guides: false, manifest: null };
  // The episodes built so far, each listed under Features on its own so it opens in one click.
  const featureEpisodes = ["e01", "e02"];
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
        <Composition id="Welcome" component={Welcome} durationInFrames={filmDuration("welcome")} fps={FPS} width={1920} height={1080} />
      </Folder>
      <Folder name="Star">
        <Composition
          id="StarPromo9x16"
          component={StarPromo}
          durationInFrames={STAR_PROMO_FRAMES}
          fps={FPS}
          width={1080}
          height={1920}
          defaultProps={star}
        />
        <Composition
          id="StarPromo1x1"
          component={StarPromo}
          durationInFrames={STAR_PROMO_FRAMES}
          fps={FPS}
          width={1080}
          height={1080}
          defaultProps={star}
        />
      </Folder>
      <Folder name="Pixelkit">
        <Composition
          id="PixelkitPromo16x9"
          component={PixelkitPromo}
          durationInFrames={PIXELKIT_PROMO_FRAMES}
          fps={FPS}
          width={1920}
          height={1080}
          defaultProps={pixelkit}
        />
      </Folder>
      <Folder name="Features">
        <Composition
          id="FeatureVideo"
          component={FeatureVideo}
          durationInFrames={FEATURE_VIDEO_FRAMES}
          fps={FPS}
          width={1080}
          height={1920}
          defaultProps={feature}
          calculateMetadata={withFrames}
        />
        {featureEpisodes.map((episode) => (
          <Composition
            key={episode}
            id={episode.toUpperCase()}
            component={FeatureVideo}
            durationInFrames={FEATURE_VIDEO_FRAMES}
            fps={FPS}
            width={1080}
            height={1920}
            defaultProps={{ ...feature, episode }}
            calculateMetadata={withFrames}
          />
        ))}
      </Folder>
      <Folder name="Review">
        <Still
          id="Storyboard"
          component={Storyboard}
          width={2400}
          height={1600}
          defaultProps={{ title: "Storyboard", shots: [], aspect: 1, columns: 6, level: [], frames: 1, fps: FPS } satisfies StoryboardProps}
          calculateMetadata={storyboardSize}
        />
      </Folder>
      <Folder name="Stills">
        {stills.map(({ id, component }) => (
          <Still key={id} id={id} component={component} width={canvas.width} height={canvas.height} />
        ))}
      </Folder>
    </>
  );
}
