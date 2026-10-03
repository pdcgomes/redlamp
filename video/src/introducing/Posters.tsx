import type { FC } from "react";
import { Freeze } from "remotion";
import { cuts } from "./Introducing";
import { End } from "./scenes/End";
import { Safelight } from "./scenes/Safelight";

/** A scene's length in the 9:16 cut, which the Stories stills are framed like. */
const lengthOf = (id: string) => cuts.short.find(([scene]) => scene === id)?.[1] ?? 0;

const title = lengthOf("safelight");
const end = lengthOf("end");

/**
 * Stills to post as Stories ahead of the film, each frozen where its scene comes to rest. They're
 * compositions as long as their scenes because Remotion clamps a frame to its composition's
 * length: a one-frame Still would only ever show frame 0.
 */
export const stories: { id: string; component: FC; durationInFrames: number }[] = [
  { id: "IntroducingStoryTitle", component: StoryTitle, durationInFrames: title },
  { id: "IntroducingStoryEnd", component: StoryEnd, durationInFrames: end },
];

/** The opening title once it has settled. */
function StoryTitle() {
  return (
    <Freeze frame={title - 1}>
      <Safelight length={title} />
    </Freeze>
  );
}

/**
 * The closing address before the fade. Without the small print: on a Story the reply bar covers
 * it, and nothing in the still names another maker's product.
 */
function StoryEnd() {
  return (
    <Freeze frame={end - 40}>
      <End length={end} notice={false} />
    </Freeze>
  );
}
