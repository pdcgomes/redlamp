import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { noise2D } from "@remotion/noise";
import { Caption } from "../components/Caption";
import { Lens } from "../components/Lens";
import { Photo } from "../components/Media";
import { Grain } from "../components/Stage";
import { appear, useLayout } from "../layout";
import { color, easeInOut } from "../theme";

/**
 * A darkroom at night: the safelight on the wall, its light falling on the bench, and a
 * print coming up in the developer tray.
 */
export function Darkroom({ dur }: { dur: number }) {
  const frame = useCurrentFrame();
  const layout = useLayout();
  const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
  const develop = interpolate(frame, [30, 200], [0, 1], { ...clamp, easing: easeInOut });
  const flicker = 0.93 + 0.07 * noise2D("lamp", frame / 18, 0);
  const push = interpolate(frame, [0, dur], [1, 1.06], { easing: easeInOut });
  // The room is drawn on a 1920 × 1080 set, scaled to cover 16:9 and to fit the width elsewhere.
  const scale = layout.wide ? Math.max(layout.width / 1920, layout.height / 1080) : layout.width / 1180;
  const setTop = layout.wide ? 0 : layout.tall ? 420 : 140;

  return (
    <AbsoluteFill style={{ background: color.wall, overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(70% 60% at 50% ${layout.wide ? 14 : layout.tall ? 30 : 22}%, rgba(110,26,18,${0.95 * flicker}), rgba(30,14,12,0.9) 45%, #060404 80%)`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: setTop,
          width: 1920,
          height: 1080,
          transformOrigin: "50% 0",
          transform: `translateX(-50%) scale(${scale * push})`,
        }}
      >
        {/* Light falling from the lamp to the bench. */}
        <div
          style={{
            position: "absolute",
            left: 460,
            top: 220,
            width: 1000,
            height: 560,
            clipPath: "polygon(43% 0, 57% 0, 100% 100%, 0 100%)",
            background: `linear-gradient(180deg, rgba(224,64,46,${0.34 * flicker}), rgba(224,64,46,0))`,
            filter: "blur(22px)",
          }}
        />
        {/* The safelight: the app icon's lens, on a steel bracket. */}
        <div style={{ position: "absolute", left: 960 - 6, top: 0, width: 12, height: 70, background: "#2c2421" }} />
        <div style={{ position: "absolute", left: 960 - 130, top: 50 }}>
          <Lens size={260} glow={flicker} />
        </div>
        {/* The bench. */}
        <div
          style={{
            position: "absolute",
            left: -200,
            top: 760,
            width: 2320,
            height: 520,
            background: "linear-gradient(180deg, #2a1c1a, #0a0606 60%)",
            borderTop: "2px solid rgba(224,64,46,0.35)",
          }}
        />
        {/* The developer tray, in perspective, with the print coming up under the liquid. */}
        <div style={{ position: "absolute", left: 960 - 420, top: 690, width: 840, height: 560, perspective: 1200 }}>
          <div
            style={{
              width: "100%",
              height: "100%",
              transform: "rotateX(64deg)",
              transformOrigin: "50% 0",
              borderRadius: 26,
              background: "#0b0707",
              border: "6px solid #4a403d",
              boxShadow: "0 40px 80px rgba(0,0,0,0.7)",
              padding: 34,
            }}
          >
            <div
              style={{
                position: "relative",
                width: "100%",
                height: "100%",
                borderRadius: 14,
                overflow: "hidden",
                background: "#2a0c09",
              }}
            >
              <div style={{ position: "absolute", left: 60, top: 50, right: 60, bottom: 50, background: "#eadbd3", padding: 18 }}>
                <div style={{ width: "100%", height: "100%", overflow: "hidden", opacity: develop }}>
                  <Photo style={{ filter: `grayscale(1) contrast(${1.1 + develop * 0.3}) brightness(${1.25 - develop * 0.3})` }} />
                </div>
              </div>
              {/* Red light over everything, and the liquid's slow ripples. */}
              <AbsoluteFill style={{ background: "rgba(200,40,28,0.55)", mixBlendMode: "multiply" }} />
              <AbsoluteFill
                style={{
                  background: `repeating-linear-gradient(180deg, rgba(255,176,138,0) 0px, rgba(255,176,138,0.08) ${18 + Math.sin(frame / 14) * 3}px, rgba(255,176,138,0) 40px)`,
                  transform: `translateY(${(frame * 0.6) % 40}px)`,
                }}
              />
              <div
                style={{
                  position: "absolute",
                  left: "35%",
                  top: "6%",
                  width: "30%",
                  height: "26%",
                  borderRadius: "50%",
                  background: `rgba(255,176,138,${0.32 * flicker})`,
                  filter: "blur(30px)",
                }}
              />
            </div>
          </div>
        </div>
      </div>
      <AbsoluteFill
        style={{
          padding: layout.wide ? "0 110px" : "140px 70px",
          justifyContent: layout.wide ? "center" : "flex-start",
          alignItems: layout.wide ? "flex-start" : "center",
        }}
      >
        <div style={{ maxWidth: layout.wide ? 520 : 900, marginTop: layout.wide ? -300 : 0, opacity: appear(frame, 4, 16) }}>
          <Caption
            title="A red lamp is the darkroom safelight."
            sub="The one light you can work by without fogging the paper."
            start={12}
            end={dur - 16}
            align={layout.wide ? "left" : "center"}
            size={layout.wide ? 58 : 64}
          />
        </div>
      </AbsoluteFill>
      <Grain />
    </AbsoluteFill>
  );
}
