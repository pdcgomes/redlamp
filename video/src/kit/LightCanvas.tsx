import { type CSSProperties, useLayoutEffect, useRef } from "react";
import { useCurrentFrame, useVideoConfig } from "remotion";
import { type Camera, canvasMatrix } from "./camera";

type Props = {
  camera: Camera;
  /** Draws the frame at `t` seconds, with the context already in world space. */
  draw: (ctx: CanvasRenderingContext2D, t: number) => void;
  style?: CSSProperties;
};

/**
 * A canvas the size of the frame, redrawn for every frame through the camera, in a layout effect
 * so the frame is complete before Remotion captures it. Headless Chrome can capture a frame before
 * a GPU canvas reaches the screen, most often the first frame a tab renders, so the canvas is kept
 * in software (`willReadFrequently`), which paints with the rest of the page.
 */
export function LightCanvas({ camera, draw, style }: Props) {
  const ref = useRef<HTMLCanvasElement>(null);
  const frame = useCurrentFrame();
  const { width, height, fps } = useVideoConfig();
  useLayoutEffect(() => {
    const ctx = ref.current?.getContext("2d", { willReadFrequently: true });
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, width, height);
    ctx.setTransform(...canvasMatrix(camera, width, height));
    draw(ctx, frame / fps);
  });
  return <canvas ref={ref} width={width} height={height} style={{ position: "absolute", inset: 0, pointerEvents: "none", ...style }} />;
}
