import type { ComponentType } from "react";

/** Each article's figures, by its slug, under the names its Markdown places them with: `<div data-figure="name"></div>`. */
export const figures: Record<string, Record<string, ComponentType>> = {};
