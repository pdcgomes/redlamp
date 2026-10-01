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
  status: "Pre-alpha · macOS 26",
  stage: "early alpha preview",
  github,
  githubRepo: "pdcgomes/redlamp",
  readme: `${github}#readme`,
  contributing: `${github}#contributing`,
  support: "https://ko-fi.com/pdcgomes",
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
