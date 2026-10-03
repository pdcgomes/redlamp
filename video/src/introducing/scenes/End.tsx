import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Lens } from "../../components/Lens";
import { Room } from "../components/Room";
import { Develop } from "../components/Type";
import { BEAT, ease, font, ink, ramp, type as typeScale, useShape } from "../style";

/**
 * The closing line: its phrases land on these beats of the scene as the music drops away
 * (scripts/score.py cues the same beats), then the line under it, then the app icon.
 */
export const closing = {
  phrases: [
    { text: "Everything you know.", beat: 0 },
    { text: "Nothing you don't need.", beat: 2 },
  ],
  support: { text: "Free and open source, with no subscription.", beat: 3.5 },
  icon: 6,
};

export function End({ length, notice = true }: { length: number; notice?: boolean }) {
  const frame = useCurrentFrame();
  const { shape, height } = useShape();
  const s = typeScale[shape];
  // The scene's first bar line is its frame 12.
  const beat = (b: number) => 12 + b * BEAT;
  const card = beat(closing.icon);
  const icon = ramp(frame, card, 40, ease.out);
  const out = interpolate(frame, [length - 36, length - 4], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const iconSize = shape === "wide" ? 170 : 210;
  // Short phrases sit in a row on a wide frame; anything longer, or a narrow frame, stacks them.
  const inline = shape === "wide" && closing.phrases.every((p) => p.text.length <= 12);
  // Narrow frames keep clear of the edges, where feeds lay their own buttons over the video.
  const phrase = { ...font.display, fontSize: s.headline * (inline ? 1.05 : shape === "wide" ? 0.96 : 0.8), lineHeight: 1.12, color: ink.headline };
  return (
    <Room tone="safelight" glow={(0.45 + 0.55 * icon) * ramp(frame, 0, 60) * out} glowY={0.36}>
      <AbsoluteFill style={{ opacity: out, fontFamily: font.family, alignItems: "center" }}>
        <div style={{ position: "absolute", top: height * (inline ? 0.4 : 0.34), left: 0, right: 0, textAlign: "center" }}>
          <div style={{ display: "flex", flexDirection: inline ? "row" : "column", justifyContent: "center", alignItems: "center", gap: inline ? s.headline * 0.38 : 0 }}>
            {closing.phrases.map((p) => (
              <Develop key={p.text} at={beat(p.beat) - 4} until={card - 18} duration={30}>
                <div style={phrase}>{p.text}</div>
              </Develop>
            ))}
          </div>
          <Develop at={beat(closing.support.beat) - 2} until={card - 14} duration={34}>
            <div style={{ ...font.text, fontSize: s.sub, color: ink.sub, marginTop: s.headline * 0.42, whiteSpace: "pre-line" }}>
              {shape === "wide" ? closing.support.text : closing.support.text.replace(", ", ",\n")}
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
              {shape === "wide" ? "Pre-alpha for Apple Silicon Macs on macOS 26 or later." : "Pre-alpha for Apple Silicon Macs\non macOS 26 or later."}
            </div>
          </Develop>
        </div>
        {notice ? (
          <div style={{ position: "absolute", bottom: s.small * 2.4, left: 0, right: 0, textAlign: "center" }}>
            <Develop at={card + 40} duration={30}>
              <div style={{ ...font.text, fontSize: s.small, color: ink.small, whiteSpace: "pre-line", lineHeight: 1.45 }}>
                {shape === "wide"
                  ? "Lightroom is a trademark of Adobe Inc., and the film names are their makers' trademarks. Redlamp isn't affiliated with any of them."
                  : "Lightroom is a trademark of Adobe Inc., and the film names\nare their makers' trademarks. Redlamp isn't affiliated\nwith any of them."}
              </div>
            </Develop>
          </div>
        ) : null}
      </AbsoluteFill>
    </Room>
  );
}
