const github = "https://github.com/pdcgomes/redlamp";

/** Every externally visible string and link, in one place. */
export const site = {
  name: "Redlamp",
  origin: "https://redlamp.app",
  tagline: "Work by the light that never fogs the paper.",
  positioning:
    "A native, open-source RAW photo editor for the Mac that anyone who knows Lightroom will find familiar.",
  description:
    "Redlamp is a native, open-source RAW photo editor for Apple Silicon, built from scratch in Swift and Metal. Lightroom's workflow, with no subscription and no cloud.",
  status: { stage: "Pre-alpha", platform: "macOS 26" },
  stage: "pre-alpha",
  github,
  githubRepo: "pdcgomes/redlamp",
  readme: `${github}#readme`,
  contributing: `${github}#contributing`,
  support: "https://ko-fi.com/pdcgomes",
  /** Redlamp on Product Hunt: the link as Product Hunt's embed gives it, and the tagline the listing shows. */
  productHunt: {
    url: "https://www.producthunt.com/products/redlamp?embed=true&utm_source=embed&utm_medium=post_embed",
    tagline: "Native, open-source RAW Lightroom alternative editor for Mac",
  },
  /** The film, published on YouTube. Its poster is the film's own (video/out/introducing). */
  film: {
    title: "Introducing Redlamp",
    youtube: "lvdLOtdbUX4",
    url: "https://www.youtube.com/watch?v=lvdLOtdbUX4",
    duration: "1:42",
    poster: "/video/introducing-redlamp-poster.jpg",
  },
  license: { name: "MPL-2.0", long: "Mozilla Public License 2.0", url: `${github}/blob/main/LICENSE` },
  rawPixls: "https://raw.pixls.us",
  buildFromSource: [
    "git clone https://github.com/pdcgomes/redlamp.git && cd redlamp",
    "mise install",
    "mise run generate",
    "mise run run",
  ],
  homebrew: ["brew tap pdcgomes/redlamp https://github.com/pdcgomes/redlamp", "brew install --cask redlamp"],
} as const;

/** Turns a README-relative link into one that works from the website. */
export function repoLink(href: string): string {
  if (/^https?:\/\//.test(href)) return href;
  if (href.startsWith("#")) return `${github}${href}`;
  return `${github}/blob/main/${href.replace(/^\.\//, "")}`;
}
