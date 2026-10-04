import { site } from "@/lib/site";

/**
 * The home page's AI disclosure (#ai): how Redlamp is built with AI agents, and where the app itself uses AI.
 * Inline Markdown, as `Inline` renders it, so repository paths link to GitHub. It states what the repository
 * shows (the commits' trailers, AGENTS.md, the tracker, the wave plans, CI and the README) and, for his own
 * part and the models, what Pedro says.
 */
export const aiDisclosure = {
  eyebrow: "AI disclosure",
  title: "Redlamp is built with AI agents.",
  intro: `Agents in Cursor, an AI code editor, write Redlamp's code, tests and documentation, with models from several providers. Nearly every commit in [its history](${site.github}/commits/main) is co-authored by Cursor's agent. Pedro, who started the project, directs the work. This is how it's divided and checked.`,
  items: [
    {
      title: "What the agents do",
      body: "They write the code, from the image pipeline to the interface, and the tests that check it. They also write the README, the research notes and this website. Some work runs in waves: several agents at once, each in its own copy of the repository and its own part of the code, with an orchestrating agent merging their work.",
    },
    {
      title: "What Pedro does",
      body: "He sets Redlamp's vision and direction, its design and its standards, makes the high-level architecture decisions and drives the research. Work is planned in the project's [tracker](docs/research/research-tracker.md), where new items wait until he accepts them and each decision is recorded with its reasons. He tries changes in the app, on his own photos, and reviews some of them; the tests check the rest.",
    },
    {
      title: "How changes are checked",
      body: "Agents run the tests as they work: each package's own, decode tests on CC0 samples from real cameras, and renders compared with recorded references, under Metal's validation layer. A change to how photos render goes into a new process version, as in Lightroom, so existing edits keep their look. CI builds and tests every push to `main`.",
    },
    {
      title: "The rules agents follow",
      body: `[AGENTS.md](AGENTS.md) and the project's [Cursor rules](${site.github}/tree/main/.cursor/rules) set out how to build and test, which files each agent may change, and which decisions are Pedro's. Agents follow the clean-room policy every contributor does: algorithms come from published papers and specifications, no GPL or LGPL code or data is used, and Adobe's files are never shipped or converted.`,
    },
    {
      title: "The agent recipe studio",
      body: "In the [agent recipe studio](docs/recipes/agent-studio.md), curator, colourist and critic agents develop looks to briefs drawn from public-domain references. People approve each brief and choose what ships, and the critics are relied on only after they agree with people's picks on pairs they haven't seen.",
    },
    {
      title: "AI in the app",
      body: "Separately, some features use AI models, and they run on your Mac: the Subject, Sky, Background, People, Objects, Depth Range and Landscape masks use Apple Vision's built-in models, Segment Anything and Depth Anything, and the Remove tool, in progress, finds things by name with OWLv2. Photos are never uploaded. Settings › Models lists the models that need a download, with their size and licence.",
    },
  ],
  footnote:
    "Screenshots on this site are captured from the app. The films, the app icon and the logo were made with agents too, in code: the films are animated with Remotion, the score for Introducing Redlamp is synthesised by a script, and the icon and logo are vector drawings.",
};
