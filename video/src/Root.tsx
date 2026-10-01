import { Composition, Folder, Still } from "remotion";
import { durationOf, Explainer, type ExplainerProps } from "./Explainer";
import { stills } from "./stills";
import { canvas } from "./stills/canvas";
import "./theme";

const FPS = 30;

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
      <Folder name="Stills">
        {stills.map(({ id, component }) => (
          <Still key={id} id={id} component={component} width={canvas.width} height={canvas.height} />
        ))}
      </Folder>
    </>
  );
}
