import type { ComponentType } from "react";
import { Hero } from "./images/01-hero";
import { Familiar } from "./images/02-familiar";
import { Masks } from "./images/03-masks";
import { Film } from "./images/04-film";
import { Fujifilm } from "./images/05-fujifilm";
import { Stacking } from "./images/06-stacking";
import { Keyboard } from "./images/07-keyboard";
import { Originals } from "./images/08-originals";
import { TryIt } from "./images/09-try-it";

/**
 * The Reddit set, in order (docs/plans/2026-10-01-reddit-screenshots-design.md). Ids name the rendered
 * files; `held-` ones wait for captures that don't exist yet and only render when named.
 */
export const stills: { id: string; component: ComponentType }[] = [
  { id: "still-01-hero", component: Hero },
  { id: "still-02-familiar", component: Familiar },
  { id: "still-03-masks", component: Masks },
  { id: "still-04-film", component: Film },
  { id: "still-05-fujifilm", component: Fujifilm },
  { id: "held-06-stacking", component: Stacking },
  { id: "still-07-keyboard", component: Keyboard },
  { id: "still-08-originals", component: Originals },
  { id: "still-09-try-it", component: TryIt },
];
