/**
 * Every word in the star promo, from its design (docs/plans/2026-10-06-star-promo.md). The hook
 * is the composition's `hook` prop, so each can be rendered as its own variant.
 */
export const hooks = {
  charging: ["Hold on.", "It's charging."],
  favour: ["This lamp has", "a favour to ask."],
  psst: ["Psst.", "Photographers."],
  wait: ["Wait", "for it."],
  day: ["One click would", "make its day."],
} as const;

export type Hook = keyof typeof hooks;

export const copy = {
  build: ["Redlamp is a free", "raw editor for the Mac."],
  rush: ["Open source,", "on GitHub."],
  sign: "Please star us!",
  end: {
    title: "Star Redlamp on GitHub",
    address: "github.com/pdcgomes/redlamp",
    reason: "Every star helps photographers find it.",
  },
};
