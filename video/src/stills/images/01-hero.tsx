import { Lockup } from "../../components/Media";
import { canvas, margin, type } from "../canvas";
import { Headline } from "../components/Headline";
import { Shot } from "../components/Shot";
import { StillFrame } from "../components/StillFrame";

const windowWidth = 1180;

/** What Redlamp is at a glance: the whole editor on a strong photo, under the name. */
export function Hero() {
  return (
    <StillFrame index={0} glow={{ x: 0.5, y: 0.02, strength: 1.1 }} footer={false}>
      <div style={{ position: "absolute", top: 54, left: 0, right: 0, display: "flex", justifyContent: "center" }}>
        <Lockup width={236} />
      </div>
      <Headline
        title="The raw editor you already know."
        sub={"Lightroom's panels, sliders and shortcuts, native on the Mac.\nFree and open source."}
        size={76}
        subSize={type.text}
        align="center"
        style={{ position: "absolute", top: 146, left: margin, right: margin }}
      />
      <div
        style={{
          position: "absolute",
          top: 388,
          left: (canvas.width - windowWidth) / 2,
          filter: "drop-shadow(0 40px 70px rgba(0,0,0,0.7))",
        }}
      >
        <Shot name="hero" standIn="synced/images/hero.png" width={windowWidth} />
      </div>
    </StillFrame>
  );
}
