import type { ReactNode } from "react";

type Tone = "plain" | "accent" | "caution";
type Props = { label: string; value: ReactNode; href?: string; tone?: Tone };

const toneClass: Record<Tone, string> = {
  plain: "bg-bakelite-hi text-paper",
  accent: "bg-paper text-ink",
  caution: "bg-filament text-ink",
};

/** A two-part badge in the shields.io shape, drawn in the brand's steel and paper. */
export function Badge({ label, value, href, tone = "plain" }: Props) {
  const body = (
    <span className="inline-flex overflow-hidden rounded-md border border-hairline text-[12px] leading-none font-medium">
      <span className="bg-steel/45 px-2 py-1.5 text-ring">{label}</span>
      <span className={`px-2 py-1.5 ${toneClass[tone]}`}>{value}</span>
    </span>
  );
  if (!href) return body;
  return (
    <a href={href} className="transition-opacity hover:opacity-85">
      {body}
    </a>
  );
}
