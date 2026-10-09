import type { ComponentType } from "react";
import { Combinations } from "./linear-vs-scene-referred/Combinations";
import { Encoding } from "./linear-vs-scene-referred/Encoding";
import { ExposurePlayground } from "./linear-vs-scene-referred/ExposurePlayground";
import { GreyScale } from "./linear-vs-scene-referred/GreyScale";
import { InShort } from "./linear-vs-scene-referred/InShort";
import { LevelsAndMixing } from "./linear-vs-scene-referred/LevelsAndMixing";
import { RenderOrder } from "./linear-vs-scene-referred/RenderOrder";

/** Each article's figures, by its slug, under the names its Markdown places them with: `<div data-figure="name"></div>`. */
export const figures: Record<string, Record<string, ComponentType>> = {
  "linear-vs-scene-referred": {
    "in-short": InShort,
    combinations: Combinations,
    encoding: Encoding,
    "levels-and-mixing": LevelsAndMixing,
    "exposure-playground": ExposurePlayground,
    "render-order": RenderOrder,
    "grey-scale": GreyScale,
  },
};
