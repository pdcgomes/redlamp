import { AbsoluteFill, useCurrentFrame } from "remotion";
import { render, stageLabel, useManifest } from "../assets";
import { History } from "../components/History";
import { ImportIcon, RecipeIcon, SliderIcon } from "../components/Icons";
import { Room } from "../components/Room";
import { Sheet } from "../components/Sheet";
import { Camera, project } from "../components/Space";
import { Title } from "../components/Type";
import { BEAT, ease, neutral, ramp, track, type as typeScale, useShape } from "../style";

const PERSPECTIVE = 2400;

/**
 * The photo develops one History step at a time: the raw as it opened, then each step laid on
 * the front as a new sheet, rendered by the engine as the app rendered it, while the stack turns
 * to show its depth. A History panel in the app's style lists the steps, newest at the top, each
 * row drawn to its sheet. Then the sheets close up into the finished photo.
 */
export function Steps({ length }: { length: number }) {
  const frame = useCurrentFrame();
  const { shape, width: frameWidth, height: frameHeight } = useShape();
  const stages = useManifest().hero?.stages ?? [];
  const wide = shape === "wide";
  const last = stages.length - 1;

  const height = wide ? 580 : shape === "tall" ? 800 : 620;
  const width = (height * 2) / 3;
  // Each step lands on a beat: the scene's frame 12 is its first bar line.
  const every = BEAT;
  const arrive = (i: number) => (i === 0 ? -40 : 12 + i * every);
  const settled = arrive(last) + 30;
  const fold = [length - 78, length - 28] as const;

  // How many steps have been laid down, smoothly; each pushes the earlier ones back.
  const laid = stages.reduce((sum, _, i) => sum + ramp(frame, arrive(i), 26, ease.out), 0);
  const close = 1 - ramp(frame, fold[0], fold[1] - fold[0]);
  const gap = (wide ? 100 : 96) * close;
  const fan = (wide ? 28 : 24) * close;

  const turn = ramp(frame, 20, settled + 20, ease.move) * close;
  const view = {
    rx: 7 * turn,
    ry: (wide ? 28 : 26) * turn - 4 * ramp(frame, settled, fold[0] - settled, ease.inOut) * close,
    x: wide ? track(frame, [[0, 440], [fold[0], 440], [fold[1], 0]]) : 30 * turn,
    y: wide ? 50 * close : shape === "tall" ? track(frame, [[0, 180], [fold[0], 180], [fold[1], 0]]) : 70 * close,
  };

  const size = typeScale[shape].label;
  const rowHeight = size * 2.2;
  const panel = wide
    ? { left: 120, top: 436, width: 480 }
    : { left: (frameWidth - 760) / 2, top: shape === "tall" ? 1290 : 905, width: 760 };
  const rowY = (row: number) => panel.top + size * 0.5 + rowHeight * 0.9 + rowHeight * (row + 0.5);
  const panelShown = ramp(frame, 18, 30, ease.out) * (1 - ramp(frame, fold[0] - 10, 34));

  const sheets = stages.map((stage, i) => {
    const depth = Math.max(0, laid - 1 - i);
    const here = ramp(frame, arrive(i), 26, ease.out);
    return { stage, i, here, z: -depth * gap + (1 - here) * 70, x: -depth * fan, anchorY: height * (0.16 + 0.135 * (last - i)) };
  });

  const rows = [...stages].reverse().map((stage, row) => {
    const i = last - row;
    const label = stageLabel(stage);
    const Icon = stage.step === "import" ? ImportIcon : stage.step === "recipe" ? RecipeIcon : SliderIcon;
    return { icon: <Icon size={size * 1.05} />, name: label.name, before: label.before, after: label.after, shown: ramp(frame, arrive(i) + 6, 22, ease.out) };
  });
  const current = rows.findIndex((r) => r.shown > 0.5);

  const text = wide ? { left: 120, top: 150 } : { left: 90, top: shape === "tall" ? 150 : 80 };
  return (
    <Room>
      <Camera view={view} perspective={PERSPECTIVE}>
        {sheets.map(({ stage, i, here, z, x }) => (
          <Sheet
            key={stage.file}
            src={render(stage.file)}
            width={width}
            height={height}
            x={x}
            z={z + i * 0.4}
            opacity={here * (i === last || close > 0.02 ? 1 : 0) * (i === last ? 1 : 0.93)}
            shade={Math.max(0, laid - 1 - i) * 0.05 * close}
          />
        ))}
      </Camera>
      {wide ? (
        <svg width={frameWidth} height={frameHeight} style={{ position: "absolute", inset: 0 }}>
          {sheets.map(({ stage, i, z, x, anchorY }) => {
            const row = last - i;
            const end = project(view, PERSPECTIVE, { width: frameWidth, height: frameHeight }, [x - width / 2, -height / 2 + anchorY, z]);
            const startX = panel.left + panel.width + 14;
            const y = rowY(row);
            const shown = rows[row].shown * panelShown;
            return (
              <g key={stage.file} opacity={shown}>
                <path
                  d={`M ${startX} ${y} C ${startX + 60} ${y}, ${end.x - 60} ${end.y}, ${end.x} ${end.y}`}
                  fill="none"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth={1.2}
                />
                <circle cx={startX} cy={y} r={2.6} fill="rgba(255,255,255,0.45)" />
                <circle cx={end.x} cy={end.y} r={3.4} fill={neutral.label} />
              </g>
            );
          })}
        </svg>
      ) : null}
      <div style={{ position: "absolute", left: panel.left, top: panel.top, opacity: panelShown }}>
        <History rows={rows} width={panel.width} rowHeight={rowHeight} size={size} current={current} />
      </div>
      <AbsoluteFill>
        <div style={{ position: "absolute", ...text }}>
          <Title
            title={"Every step, kept."}
            sub={"History shows what each step changed,\nand any of them can be undone."}
            at={50}
            until={fold[0] - 14}
            width={wide ? 760 : 900}
          />
        </div>
      </AbsoluteFill>
    </Room>
  );
}
