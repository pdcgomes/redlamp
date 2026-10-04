import { formatEntry, type Metric, type Point } from "@/lib/performance";

const WIDTH = 320;
const HEIGHT = 132;
const PAD = { top: 10, right: 10, bottom: 22, left: 46 };

function shortDate(date: string): string {
  return new Date(date).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
}

function longDate(date: string): string {
  return new Date(date).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}

function tick(value: number, unit: string): string {
  const rounded = value >= 100 ? Math.round(value) : value >= 10 ? Math.round(value * 10) / 10 : Math.round(value * 100) / 100;
  return `${rounded.toLocaleString("en-GB")}${unit === "%" ? "%" : unit === "/s" ? "" : ` ${unit}`}`;
}

/**
 * One metric over time. README figures are hollow, harness runs filled; points measured under load
 * are faint and dashed. A range the README gave is drawn as a vertical bar through its midpoint.
 */
export function LineChart({ metric, points }: { metric: Metric; points: Point[] }) {
  const times = points.map((point) => Date.parse(point.date));
  const first = Math.min(...times);
  const last = Math.max(...times);
  const top = Math.max(...points.map((point) => point.entry.high ?? point.entry.value)) * 1.15 || 1;
  const x = (time: number) =>
    last === first ? (PAD.left + WIDTH - PAD.right) / 2 : PAD.left + ((time - first) / (last - first)) * (WIDTH - PAD.left - PAD.right);
  const y = (value: number) => HEIGHT - PAD.bottom - (value / top) * (HEIGHT - PAD.top - PAD.bottom);
  const sources = [...new Set(points.map((point) => point.source))];
  return (
    <svg
      viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
      role="img"
      aria-label={`${metric.label} over time, in ${metric.unit === "/s" ? "thumbnails a second" : metric.unit}`}
      className="h-auto w-full"
    >
      {[0, 0.5, 1].map((share) => (
        <g key={share}>
          <line x1={PAD.left} x2={WIDTH - PAD.right} y1={y(top * share)} y2={y(top * share)} stroke="rgb(243 238 232 / 0.08)" />
          <text x={PAD.left - 6} y={y(top * share) + 3} textAnchor="end" fontSize="9" fill="#6f6561">
            {tick(top * share, metric.unit)}
          </text>
        </g>
      ))}
      <text x={PAD.left} y={HEIGHT - 6} fontSize="9" fill="#6f6561">
        {shortDate(points[0].date)}
      </text>
      {last !== first ? (
        <text x={WIDTH - PAD.right} y={HEIGHT - 6} textAnchor="end" fontSize="9" fill="#6f6561">
          {shortDate(points[points.length - 1].date)}
        </text>
      ) : null}
      {sources.map((source) => {
        const line = points.filter((point) => point.source === source && !point.noisy);
        return line.length > 1 ? (
          <polyline
            key={source}
            points={line.map((point) => `${x(Date.parse(point.date))},${y(point.entry.value)}`).join(" ")}
            fill="none"
            stroke={source === "readme" ? "rgb(217 208 203 / 0.45)" : "rgb(243 238 232 / 0.75)"}
            strokeWidth="1.5"
          />
        ) : null;
      })}
      {points.map((point, index) => {
        const cx = x(Date.parse(point.date));
        const hollow = point.source === "readme";
        const opacity = point.noisy ? 0.4 : 1;
        return (
          <g key={`${point.commit}-${index}`} opacity={opacity}>
            <title>
              {`${formatEntry(point.entry, metric.unit)} · ${longDate(point.date)} · ${point.commit}${point.subject ? ` ${point.subject}` : ""} · ${
                hollow ? "as recorded in the README" : "harness run"
              }${point.noisy ? ", measured under load" : ""}`}
            </title>
            {point.entry.low !== undefined && point.entry.high !== undefined ? (
              <line x1={cx} x2={cx} y1={y(point.entry.low)} y2={y(point.entry.high)} stroke="#a89d98" strokeWidth="1.5" strokeLinecap="round" />
            ) : null}
            <circle
              cx={cx}
              cy={y(point.entry.value)}
              r="3.5"
              fill={hollow ? "#120d0c" : "#f3eee8"}
              stroke={hollow ? "#d9d0cb" : "#f3eee8"}
              strokeWidth="1.5"
              strokeDasharray={point.noisy ? "2 1.5" : undefined}
            />
          </g>
        );
      })}
    </svg>
  );
}
