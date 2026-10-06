import type { CalculateMetadataFunction } from "remotion";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { color, font } from "../theme";

/**
 * A promo's storyboard sheet, for review and for its design doc: a frame at every cue, labelled
 * with the cue, its beat and its time, over the score's level with every cue marked on it, so the
 * pictures and the sound can be checked against each other on one page. scripts/storyboard.mjs
 * renders the frames into public/review/ and then this sheet.
 */
export type StoryboardProps = {
  title: string;
  /** The frames, as files in public/, with what each is. */
  shots: { src: string; cue: string; beat: number; seconds: number }[];
  /** The promo's width over its height. */
  aspect: number;
  columns: number;
  /** The score's level at every video frame, 0 to 1 (score.json beside the score), and the promo's length in frames. */
  level: number[];
  frames: number;
  fps: number;
};

const WIDTH = 2400;
const PAD = 48;
const GAP = 20;
const LABEL = 76;
const HEADER = 120;
const WAVE = 300;

function cell(props: StoryboardProps) {
  const width = (WIDTH - PAD * 2 - GAP * (props.columns - 1)) / props.columns;
  return { width, height: width / props.aspect };
}

export const storyboardSize: CalculateMetadataFunction<StoryboardProps> = ({ props }) => {
  const rows = Math.ceil(props.shots.length / props.columns);
  const { height } = cell(props);
  return { width: WIDTH, height: Math.round(HEADER + rows * (height + LABEL + GAP) + WAVE + PAD) };
};

export function Storyboard(props: StoryboardProps) {
  const { title, shots, columns, level, frames, fps } = props;
  const size = cell(props);
  const waveWidth = WIDTH - PAD * 2;
  const bars = level.length > 0 ? level : [];
  const top = HEADER + Math.ceil(shots.length / columns) * (size.height + LABEL + GAP);
  return (
    <AbsoluteFill style={{ background: color.wall, fontFamily: font.family, color: color.paper }}>
      <div style={{ position: "absolute", left: PAD, top: 40, ...font.display, fontSize: 44 }}>{title}</div>
      <div style={{ position: "absolute", right: PAD, top: 52, fontSize: 24, color: color.mute }}>
        {`${(frames / fps).toFixed(1)} s · ${frames} frames · ${shots.length} cues`}
      </div>
      {shots.map((shot, i) => {
        const x = PAD + (i % columns) * (size.width + GAP);
        const y = HEADER + Math.floor(i / columns) * (size.height + LABEL + GAP);
        return (
          <div key={shot.src} style={{ position: "absolute", left: x, top: y, width: size.width }}>
            <Img src={staticFile(shot.src)} style={{ width: size.width, height: size.height, display: "block", borderRadius: 10, outline: `1px solid ${color.hairline}` }} />
            <div style={{ marginTop: 10, fontSize: 22, lineHeight: 1.25 }}>
              <div style={{ fontWeight: 600 }}>{shot.cue}</div>
              <div style={{ color: color.mute }}>{`beat ${shot.beat} · ${shot.seconds.toFixed(2)} s`}</div>
            </div>
          </div>
        );
      })}
      <div style={{ position: "absolute", left: PAD, top: top + 10, width: waveWidth, height: WAVE - 70 }}>
        <svg width={waveWidth} height={WAVE - 70} style={{ display: "block" }}>
          {bars.map((v, i) => {
            const h = Math.max(1, v * (WAVE - 110));
            return <rect key={`${i}`} x={(i / frames) * waveWidth} y={(WAVE - 110 - h) / 2 + 20} width={Math.max(1, waveWidth / frames - 0.5)} height={h} fill={color.filament} opacity={0.75} />;
          })}
          {shots.map((shot, i) => {
            const x = (shot.seconds * fps * waveWidth) / frames;
            // Labels alternate between two rows, so cues a beat apart don't overwrite each other.
            return (
              <g key={`cue-${shot.cue}`}>
                <line x1={x} x2={x} y1={i % 2 ? 18 : 0} y2={WAVE - 90} stroke={color.paper} strokeOpacity={0.35} strokeDasharray="4 4" />
                <text x={x + 4} y={i % 2 ? 30 : 12} fontSize={15} fill={color.mute}>
                  {shot.cue}
                </text>
              </g>
            );
          })}
        </svg>
        <div style={{ fontSize: 20, color: color.dim, marginTop: 6 }}>The score's level at every frame, with each cue marked</div>
      </div>
    </AbsoluteFill>
  );
}
