import type { ReactNode } from "react";
import { AbsoluteFill, Img, useCurrentFrame } from "remotion";
import { render, size, stageLabel, useManifest } from "../assets";
import { DocumentIcon, PhotoIcon } from "../components/Icons";
import { Room } from "../components/Room";
import { Camera, facing } from "../components/Space";
import { Develop, Title } from "../components/Type";
import { ease, font, ink, mix, neutral, ramp, type as typeScale, useShape } from "../style";

/**
 * The finished photo, as the last scene left it. The edit lifts off it as a sheet of glass and
 * becomes what it is, a few lines in a small file; underneath, the original raw, untouched.
 */
export function Originals({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape } = useShape();
  const hero = useManifest().hero;
  const wide = shape === "wide";
  const s = typeScale[shape];
  if (!hero) return <Room />;

  const height = wide ? 580 : shape === "tall" ? 800 : 620;
  const width = (height * 2) / 3;
  // After the dissolve from the folded History stack, which is the same photo in the same place.
  const lift = ramp(frame, 24, 84, ease.inOut);
  const card = ramp(frame, 60, 50, ease.out);
  const view = {
    rx: 6 * lift,
    ry: -16 * lift + 3 * ramp(frame, 120, length - 120, (t) => t),
    x: wide ? 120 * lift : 0,
    y: wide ? 0 : (shape === "tall" ? 120 : 40) * lift,
  };
  const plate = {
    x: (wide ? 470 : 250) * lift,
    y: wide ? -10 * lift : (shape === "tall" ? -520 : -260) * lift,
    z: 230 * lift,
    width: mix(width, wide ? 420 : 470, card),
    height: mix(height, wide ? 470 : 470, card),
  };
  const steps = hero.stages.filter((st) => st.step !== "import").map(stageLabel);
  const final = hero.stages[hero.stages.length - 1];
  const caption = (title: string, detail: string, icon: ReactNode, at: number) => (
    <Develop at={at} duration={30}>
      <div style={{ display: "flex", alignItems: "center", gap: s.label * 0.5, fontFamily: font.family, whiteSpace: "nowrap" }}>
        <span style={{ display: "flex", color: neutral.label }}>{icon}</span>
        <span style={{ ...font.text, fontWeight: 560, fontSize: s.label, color: "rgba(255,255,255,0.9)" }}>{title}</span>
      </div>
      <div style={{ ...font.text, fontSize: s.label * 0.92, color: ink.sub, marginTop: 6, marginLeft: s.label * 1.6, whiteSpace: "nowrap" }}>
        {detail}
      </div>
    </Develop>
  );
  const text = wide ? { left: 120, top: 380 } : { left: 90, top: shape === "tall" ? 1450 : 1040 };
  return (
    <Room>
      <Camera view={view} perspective={2400}>
        {/* The original: the raw as it opened, untouched. */}
        <div style={{ position: "absolute", left: -width / 2, top: -height / 2, width, height, transformStyle: "preserve-3d" }}>
          <Img src={render(hero.stages[0].file)} style={{ width, height, borderRadius: 6, display: "block", boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.14)" }} />
          <div style={{ position: "absolute", left: 0, top: height + 26, transform: `translateZ(1px) ${facing(view)}`, transformOrigin: "0 0" }}>
            {caption(hero.name, `${size(hero.bytes)} · Your original, never touched`, <PhotoIcon size={s.label * 1.1} />, 112)}
          </div>
        </div>
        {/* The edit, lifting off it. */}
        <div
          style={{
            position: "absolute",
            left: plate.x - plate.width / 2,
            top: plate.y - plate.height / 2,
            width: plate.width,
            height: plate.height,
            transformStyle: "preserve-3d",
            transform: `translateZ(${plate.z}px)`,
          }}
        >
          <div
            style={{
              position: "absolute",
              inset: 0,
              borderRadius: mix(6, 22, card),
              overflow: "hidden",
              background: `rgba(30,30,33,${0.72 * card})`,
              boxShadow: `inset 0 0 0 1px rgba(255,255,255,${0.14 + 0.08 * card}), 0 40px 90px rgba(0,0,0,${0.5 * card})`,
            }}
          >
            <Img
              src={render(final.file)}
              style={{ position: "absolute", left: 0, top: 0, width, height, opacity: 1 - ramp(frame, 40, 46, ease.inOut), display: "block" }}
            />
            <div style={{ position: "absolute", inset: 0, padding: s.label * 1.3, opacity: card, fontFamily: font.family }}>
              <div style={{ display: "flex", alignItems: "center", gap: s.label * 0.5, color: neutral.label }}>
                <DocumentIcon size={s.label * 1.2} />
                <span style={{ ...font.text, fontWeight: 600, fontSize: s.label, color: "rgba(255,255,255,0.92)" }}>{hero.name}.redlamp</span>
              </div>
              <div style={{ height: 1, background: neutral.hairline, margin: `${s.label * 0.9}px 0 ${s.label * 0.5}px` }} />
              {steps.map((step, i) => (
                <div
                  key={step.name}
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    padding: `${s.label * 0.42}px 0`,
                    fontSize: s.label,
                    opacity: ramp(frame, 78 + i * 6, 20),
                  }}
                >
                  <span style={{ ...font.text, color: neutral.label }}>{step.name}</span>
                  <span style={{ ...font.text, color: "rgba(255,255,255,0.9)", fontVariantNumeric: "tabular-nums" }}>{step.after}</span>
                </div>
              ))}
            </div>
          </div>
          <div style={{ position: "absolute", left: 0, top: plate.height + 26, transform: `translateZ(1px) ${facing(view)}`, transformOrigin: "0 0" }}>
            {caption(`${hero.name}.redlamp`, `${size(hero.editBytes)} · Your edit, beside it`, <DocumentIcon size={s.label * 1.1} />, 128)}
          </div>
        </div>
      </Camera>
      <AbsoluteFill>
        <div style={{ position: "absolute", ...text }}>
          <Title title={"Your originals,\nnever touched."} sub={"Each edit lives in a small file\nnext to its photo."} at={70} width={wide ? 640 : 900} />
        </div>
      </AbsoluteFill>
    </Room>
  );
}
