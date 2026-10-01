import { glass } from "../../components/Media";
import { Lens } from "../../components/Lens";
import { color, font } from "../../theme";
import { canvas, type } from "../canvas";
import { Headline } from "../components/Headline";
import { StillFrame } from "../components/StillFrame";

const install = ["brew tap pdcgomes/redlamp https://github.com/pdcgomes/redlamp", "brew install --cask redlamp"];

/** Where to get it, under the lamp: the one light in this image comes from the lens. */
export function TryIt() {
  return (
    <StillFrame index={8} glow={{ x: 0.5, y: 0.2, strength: 1.2 }}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          paddingTop: 92,
          fontFamily: font.family,
        }}
      >
        <Lens size={176} glow={1} />
        <Headline
          title="Try it."
          sub="Pre-alpha for Apple Silicon Macs on macOS 26 or later."
          align="center"
          style={{ marginTop: 34, width: canvas.width - 300 }}
        />
        <div style={{ ...font.display, marginTop: 38, fontSize: 64, color: color.paper }}>redlamp.app</div>
        <div
          style={{
            ...glass,
            marginTop: 34,
            padding: "18px 30px",
            fontFamily: font.mono,
            fontSize: 24,
            lineHeight: 1.6,
            color: color.ring,
          }}
        >
          {install.map((line) => (
            <div key={line}>
              <span style={{ color: color.dim }}>$ </span>
              {line}
            </div>
          ))}
        </div>
        <div style={{ marginTop: 22, fontSize: type.small + 4, color: color.mute }}>
          Free and open source (MPL-2.0) · github.com/pdcgomes/redlamp
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          right: 96,
          bottom: 36,
          fontFamily: font.family,
          fontSize: type.small,
          color: color.dim,
        }}
      >
        Lightroom is a trademark of Adobe Inc. Redlamp isn't affiliated with Adobe.
      </div>
    </StillFrame>
  );
}
