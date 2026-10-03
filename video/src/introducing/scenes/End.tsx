import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Lens } from "../../components/Lens";
import { Room } from "../components/Room";
import { Develop } from "../components/Type";
import { ease, font, ink, ramp, type as typeScale, useShape } from "../style";

/** The brand's line, then the app icon lit, the address, and the small print. */
export function End({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape, height } = useShape();
  const s = typeScale[shape];
  const card = 112;
  const icon = ramp(frame, card, 40, ease.out);
  const out = interpolate(frame, [length - 36, length - 4], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const iconSize = shape === "wide" ? 170 : 210;
  return (
    <Room tone="safelight" glow={(0.55 + 0.45 * icon) * ramp(frame, 0, 60) * out} glowY={0.36}>
      <AbsoluteFill style={{ opacity: out, fontFamily: font.family, alignItems: "center" }}>
        <div style={{ position: "absolute", top: height * 0.42, left: 0, right: 0, textAlign: "center" }}>
          <Develop at={16} until={card - 22} duration={44}>
            <div style={{ ...font.display, fontSize: s.headline * 0.8, color: ink.headline, whiteSpace: "pre-line", lineHeight: 1.12 }}>
              {"Work by the light\nthat never fogs the paper."}
            </div>
          </Develop>
        </div>
        <div style={{ position: "absolute", top: height * 0.2, left: 0, right: 0, display: "flex", justifyContent: "center" }}>
          <div style={{ opacity: icon, transform: `scale(${0.92 + 0.08 * icon})` }}>
            <Lens size={iconSize} tile glow={icon} />
          </div>
        </div>
        <div style={{ position: "absolute", top: height * 0.2 + iconSize + s.headline * 0.55, left: 0, right: 0, textAlign: "center" }}>
          <Develop at={card + 14} duration={36}>
            <div style={{ ...font.display, fontSize: s.headline * 0.92, color: ink.headline }}>redlamp.app</div>
          </Develop>
          <Develop at={card + 28} duration={36}>
            <div style={{ ...font.text, fontSize: s.sub * 0.9, color: ink.sub, marginTop: s.sub * 0.7, whiteSpace: "pre-line" }}>
              {shape === "wide"
                ? "Free and open source. Pre-alpha for Apple Silicon Macs on macOS 26 or later."
                : "Free and open source.\nPre-alpha for Apple Silicon Macs\non macOS 26 or later."}
            </div>
          </Develop>
        </div>
        <div style={{ position: "absolute", bottom: s.small * 2.4, left: 0, right: 0, textAlign: "center" }}>
          <Develop at={card + 40} duration={30}>
            <div style={{ ...font.text, fontSize: s.small, color: ink.small, whiteSpace: "pre-line", lineHeight: 1.45 }}>
              {shape === "wide"
                ? "Lightroom is a trademark of Adobe Inc., and the film names are their makers' trademarks. Redlamp isn't affiliated with any of them."
                : "Lightroom is a trademark of Adobe Inc., and the film names\nare their makers' trademarks. Redlamp isn't affiliated\nwith any of them."}
            </div>
          </Develop>
        </div>
      </AbsoluteFill>
    </Room>
  );
}
