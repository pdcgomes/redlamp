import type { FC } from "react";
import { AbsoluteFill, Easing, interpolate } from "remotion";
import type { TransitionPresentation, TransitionPresentationComponentProps } from "@remotion/transitions";

type Props = Record<string, never>;

/** The camera pushes through the outgoing scene and the next one settles in from behind. */
const Zoom: FC<TransitionPresentationComponentProps<Props>> = ({ children, presentationDirection, presentationProgress }) => {
  const p = presentationProgress;
  const entering = presentationDirection === "entering";
  const scale = entering ? interpolate(p, [0, 1], [0.82, 1]) : interpolate(p, [0, 1], [1, 1.35]);
  const blur = entering ? (1 - p) * 14 : p * 18;
  const opacity = entering ? interpolate(p, [0, 0.5], [0, 1], { extrapolateRight: "clamp" }) : interpolate(p, [0.4, 1], [1, 0], { extrapolateLeft: "clamp" });
  return <AbsoluteFill style={{ transform: `scale(${scale})`, filter: `blur(${blur}px)`, opacity }}>{children}</AbsoluteFill>;
};

/** A fast pan with motion blur: out to the left, in from the right. */
const Whip: FC<TransitionPresentationComponentProps<Props>> = ({ children, presentationDirection, presentationProgress }) => {
  const p = presentationProgress;
  const entering = presentationDirection === "entering";
  const x = entering ? (1 - p) * 70 : -p * 70;
  const blur = Math.sin(p * Math.PI) * 22;
  return (
    <AbsoluteFill style={{ transform: `translateX(${x}%) skewX(${entering ? (1 - p) * -6 : p * 6}deg)`, filter: `blur(${blur}px)` }}>
      {children}
    </AbsoluteFill>
  );
};

export const zoom = (): TransitionPresentation<Props> => ({ component: Zoom, props: {} });
export const whip = (): TransitionPresentation<Props> => ({ component: Whip, props: {} });

/** Transitions accelerate hard and land hard, like a cut with momentum. */
export const transitionEase = Easing.bezier(0.8, 0, 0.2, 1);
