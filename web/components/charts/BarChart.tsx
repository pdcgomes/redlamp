export type Bar = { label: string; value: number; note?: string };

/**
 * Times against a display's frame: each bar is a time in milliseconds, with markers at one frame at
 * 120 Hz (8.3 ms) and at 60 Hz (16.7 ms).
 */
export function BarChart({ bars }: { bars: Bar[] }) {
  const top = Math.max(16.7, ...bars.map((bar) => bar.value)) * 1.1;
  const at = (value: number) => `${(value / top) * 100}%`;
  return (
    <figure className="flex flex-col gap-3">
      <div className="flex flex-col gap-2.5">
        {bars.map((bar) => (
          <div key={bar.label} className="grid grid-cols-[minmax(0,13rem)_1fr_4.5rem] items-center gap-3 text-[13px]">
            <span className="text-mute">{bar.label}</span>
            <span className="relative h-3 rounded-full bg-paper/6">
              <span
                className={`absolute inset-y-0 left-0 rounded-full ${bar.value > 8.3 ? "bg-filament/80" : "bg-ring"}`}
                style={{ width: at(bar.value) }}
              />
              {[8.3, 16.7].map((frame) => (
                <span key={frame} aria-hidden className="absolute -inset-y-1 w-px bg-paper/30" style={{ left: at(frame) }} />
              ))}
            </span>
            <span className="text-right font-mono text-[12.5px] text-paper tabular-nums">
              {bar.value.toLocaleString("en-GB", { maximumFractionDigits: bar.value >= 10 ? 0 : 1 })} ms
            </span>
          </div>
        ))}
      </div>
      <figcaption className="text-[12px] text-dim">
        The lines mark one display frame at 120 Hz (8.3 ms) and at 60 Hz (16.7 ms); bars past the first are warm-coloured.
      </figcaption>
    </figure>
  );
}
