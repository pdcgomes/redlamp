import { useLayoutEffect, useRef } from "react";
import { useCurrentFrame, useVideoConfig } from "remotion";
import { random } from "./random";

const SIZE = 256;
let tile: HTMLCanvasElement | null = null;

/** A tile of grey noise, made once per tab from a seeded random source. */
function noise(): HTMLCanvasElement {
  if (tile) return tile;
  tile = document.createElement("canvas");
  tile.width = SIZE;
  tile.height = SIZE;
  const ctx = tile.getContext("2d");
  if (ctx) {
    const image = ctx.createImageData(SIZE, SIZE);
    const r = random("grain");
    for (let i = 0; i < SIZE * SIZE; i += 1) {
      const v = Math.floor(r.next() * 256);
      image.data[i * 4] = v;
      image.data[i * 4 + 1] = v;
      image.data[i * 4 + 2] = v;
      image.data[i * 4 + 3] = 255;
    }
    ctx.putImageData(image, 0, 0);
  }
  return tile;
}

/**
 * Film grain that moves every two frames, laid over the frame: one tile of noise, shifted. It does
 * what `Grain` in components/Stage.tsx does without a full-frame SVG turbulence filter, which is slow
 * to rasterise in software at 1080 × 1920.
 */
export function FilmGrain({ opacity = 0.05 }: { opacity?: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  useLayoutEffect(() => {
    const ctx = ref.current?.getContext("2d", { willReadFrequently: true });
    const pattern = ctx?.createPattern(noise(), "repeat");
    if (!ctx || !pattern) return;
    const r = random(`grain:${Math.floor(frame / 2)}`);
    ctx.setTransform(1, 0, 0, 1, -Math.floor(r.next() * SIZE), -Math.floor(r.next() * SIZE));
    ctx.fillStyle = pattern;
    ctx.fillRect(0, 0, width + SIZE, height + SIZE);
  });
  return <canvas ref={ref} width={width} height={height} style={{ position: "absolute", inset: 0, pointerEvents: "none", mixBlendMode: "overlay", opacity }} />;
}
