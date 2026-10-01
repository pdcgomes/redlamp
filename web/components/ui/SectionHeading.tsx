import type { ReactNode } from "react";

type Props = { eyebrow: string; title: ReactNode; children?: ReactNode; align?: "left" | "center" };

export function SectionHeading({ eyebrow, title, children, align = "left" }: Props) {
  const centered = align === "center";
  return (
    <div className={centered ? "mx-auto max-w-2xl text-center" : "max-w-2xl"}>
      <p className="eyebrow">{eyebrow}</p>
      <h2 className="font-display mt-3 text-[clamp(1.9rem,4vw,2.9rem)] leading-[1.08] text-paper">{title}</h2>
      {children ? <div className="mt-5 text-[17px] leading-relaxed text-mute">{children}</div> : null}
    </div>
  );
}
