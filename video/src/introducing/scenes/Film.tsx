import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { render, useManifest } from "../assets";
import { Room } from "../components/Room";
import { Sheet, Tag } from "../components/Sheet";
import { Camera, project } from "../components/Space";
import { Title } from "../components/Type";
import { BEAT, ease, mix, ramp, type as typeScale, useShape } from "../style";

/**
 * The night scene develops into CineStill 800T behind a soft wipe, halation round the lamps. Then
 * one daylight frame through one stock after another: a deck of sheets in depth, the front one
 * lifting away about once a second to show the next.
 */
export function Film({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape, width: frameWidth, height: frameHeight } = useShape();
  const { night, stocks } = useManifest();
  const wide = shape === "wide";
  const s = typeScale[shape];
  // On the beat grid (the scene's frame 12 is a bar line): the deck turns every two beats.
  const swap = 12 + 6 * BEAT;

  const photoHeight = wide ? 820 : shape === "tall" ? 1020 : 760;
  const photoWidth = (photoHeight * 2) / 3;
  const wipe = ramp(frame, 40, 96, ease.inOut);
  const nightGone = ramp(frame, swap - 10, 44, ease.inOut);
  const nightAt = wide ? { x: frameWidth * 0.7, y: 540 } : { x: frameWidth / 2, y: shape === "tall" ? 1180 : 760 };

  const deckIn = ramp(frame, swap, 50, ease.out);
  const each = 2 * BEAT;
  const deckStart = swap + BEAT;
  const all = stocks?.looks ?? [];
  const looks = all.slice(0, Math.max(1, Math.min(all.length, Math.floor((length - deckStart - 24) / each) + 1)));
  const sheetHeight = wide ? 600 : shape === "tall" ? 820 : 600;
  const sheetWidth = (sheetHeight * 2) / 3;
  const gap = 78;
  // Which stock is at the front: each one lifts away over the first part of its turn, then holds.
  const raw = Math.max(0, (frame - deckStart) / each);
  const front = Math.min(looks.length - 1, Math.floor(raw) + ease.inOut(Math.min(1, (raw - Math.floor(raw)) / 0.6)));
  const view = {
    rx: 4,
    ry: -22 - 4 * ramp(frame, swap, length - swap, (t) => t),
    x: wide ? 400 : 0,
    y: wide ? 0 : shape === "tall" ? 330 : 170,
    z: (1 - deckIn) * -260,
  };
  const label = project(view, 2400, { width: frameWidth, height: frameHeight }, [0, sheetHeight / 2 + s.label * 1.9, 0]);
  const text = wide ? { left: 120, top: 330 } : { left: 90, top: shape === "tall" ? 150 : 80 };
  return (
    <Room>
      {night ? (
        <div
          style={{
            position: "absolute",
            left: nightAt.x - photoWidth / 2,
            top: nightAt.y - photoHeight / 2,
            width: photoWidth,
            height: photoHeight,
            opacity: 1 - nightGone,
            transform: `scale(${mix(1, 0.92, nightGone)})`,
            filter: nightGone > 0 ? `blur(${nightGone * 10}px)` : undefined,
          }}
        >
          <Img src={render(night.before)} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", borderRadius: 6 }} />
          <Img
            src={render(night.after)}
            style={{ position: "absolute", inset: 0, width: "100%", height: "100%", borderRadius: 6, clipPath: `inset(0 ${(1 - wipe) * 100}% 0 0)` }}
          />
          {wipe > 0 && wipe < 1 ? (
            <div
              style={{
                position: "absolute",
                top: 0,
                bottom: 0,
                left: `${wipe * 100}%`,
                width: 2,
                transform: "translateX(-1px)",
                background: "rgba(255,255,255,0.8)",
                boxShadow: "0 0 18px rgba(255,255,255,0.5)",
              }}
            />
          ) : null}
          <div style={{ position: "absolute", inset: 0, borderRadius: 6, boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.14)" }} />
          <div style={{ position: "absolute", left: "50%", bottom: s.label * 1.4, opacity: ramp(frame, 120, 24) }}>
            <Tag
              view={{}}
              x={0}
              y={0}
              anchor="center"
              icon={<Img src={staticFile("synced/film/icon-cinestill-800t.png")} style={{ width: s.label * 1.5, height: s.label * 1.5 }} />}
              title={night.look}
            />
          </div>
        </div>
      ) : null}
      {stocks ? (
        <AbsoluteFill style={{ opacity: deckIn }}>
          <Camera view={view} perspective={2400}>
            {looks.map((look, i) => {
              const depth = i - front;
              if (depth <= -1) return null;
              // The front sheet lifts towards the camera and fades, drifting only a little aside,
              // so it never crosses the words.
              const away = Math.max(0, -depth);
              return (
                <Sheet
                  key={look.id}
                  src={render(look.file)}
                  width={sheetWidth}
                  height={sheetHeight}
                  x={-away * sheetWidth * 0.22}
                  y={-away * 36}
                  z={depth >= 0 ? -depth * gap : away * 300}
                  opacity={depth >= 0 ? Math.max(0, Math.min(1, 7 - depth)) : (1 - away) ** 1.6}
                  shade={Math.max(0, depth) * 0.085}
                />
              );
            })}
          </Camera>
          {looks.map((look, i) => (
            <div
              key={look.id}
              style={{ position: "absolute", left: label.x, top: label.y, opacity: Math.max(0, 1 - Math.abs(i - front) * 2.4) }}
            >
              <Tag
                view={{}}
                x={0}
                y={0}
                anchor="center"
                icon={<Img src={staticFile(`synced/film/icon-${look.id}.png`)} style={{ width: s.label * 1.5, height: s.label * 1.5 }} />}
                title={look.name}
              />
            </div>
          ))}
        </AbsoluteFill>
      ) : null}
      <AbsoluteFill>
        <div style={{ position: "absolute", ...text }}>
          <Title
            title={"36 film looks, built\nfrom the datasheets."}
            sub={"Each stock's own curves and grain,\nwith halation and bloom."}
            at={30}
            width={wide ? 760 : 900}
          />
        </div>
      </AbsoluteFill>
    </Room>
  );
}
