import type { ReactNode } from "react";
import { repoLink } from "@/lib/site";

const TOKEN = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|\*[^*]+\*)/g;

/** Renders the inline Markdown the README uses: bold, italics, code and links. */
export function Inline({ md }: { md: string }) {
  return <>{render(md)}</>;
}

function render(md: string): ReactNode[] {
  return md.split(TOKEN).map((part, i) => {
    if (part.startsWith("**") && part.endsWith("**")) {
      return (
        <strong key={i} className="font-semibold text-paper">
          {render(part.slice(2, -2))}
        </strong>
      );
    }
    if (part.startsWith("`") && part.endsWith("`")) {
      return (
        <code key={i} className="rounded bg-paper/8 px-1 py-px font-mono text-[0.88em] text-ring">
          {part.slice(1, -1)}
        </code>
      );
    }
    const link = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (link) {
      return (
        <a key={i} href={repoLink(link[2])} className="underline decoration-hairline-strong underline-offset-3 hover:decoration-paper">
          {render(link[1])}
        </a>
      );
    }
    if (part.length > 2 && part.startsWith("*") && part.endsWith("*")) {
      return (
        <em key={i} className="text-mute">
          {render(part.slice(1, -1))}
        </em>
      );
    }
    return part;
  });
}
