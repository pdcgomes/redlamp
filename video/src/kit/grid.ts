/**
 * The music grid a promo is cut to. A promo's cue sheet (its `cues.json`) holds every timing in
 * beats, and its score is written from the same file, so the pictures and the sound meet on the
 * same frames. Beats count from 0 at the first frame; a beat can be fractional (10.5 is the "and"
 * of beat 10).
 */
export type CueSheet = {
  bpm: number;
  fps: number;
  beatsPerBar: number;
  bars: number;
  /** [chord, first beat, beats]: for the score, and for anything that changes with the harmony. */
  chords: [string, number, number][];
  cues: Record<string, number>;
};

export type Grid = {
  sheet: CueSheet;
  /** Frames in one beat: 15 at 120 BPM and 30 fps. */
  beat: number;
  bar: number;
  /** The promo's length in frames. */
  frames: number;
  /** The frame a beat falls on (fractional frames are fine for interpolation). */
  at: (beat: number) => number;
  /** The frame a named cue falls on. */
  cue: (name: string) => number;
  /** Seconds from the start to a beat. */
  seconds: (beat: number) => number;
};

export function grid(sheet: CueSheet): Grid {
  const beat = (60 / sheet.bpm) * sheet.fps;
  const cue = (name: string) => {
    const value = sheet.cues[name];
    if (value === undefined) throw new Error(`No cue named ${name}`);
    return value * beat;
  };
  return {
    sheet,
    beat,
    bar: beat * sheet.beatsPerBar,
    frames: Math.round(sheet.bars * sheet.beatsPerBar * beat),
    at: (b) => b * beat,
    cue,
    seconds: (b) => (b * 60) / sheet.bpm,
  };
}

/**
 * A flare on each of `beats` (frames), decaying over `decay` frames: 1 on the beat itself. For
 * anything that should bump with the kick.
 */
export function onBeats(frame: number, beats: number[], decay: number): number {
  let last = -Infinity;
  for (const b of beats) if (b <= frame && b > last) last = b;
  return last === -Infinity ? 0 : Math.exp(-(frame - last) / decay);
}

/** Every beat's frame from `from` up to, but not including, `to` (in beats), every `step` beats. */
export function beatsBetween(g: Grid, from: number, to: number, step = 1): number[] {
  const out: number[] = [];
  for (let b = from; b < to - 1e-9; b += step) out.push(g.at(b));
  return out;
}
