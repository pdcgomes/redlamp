import { Mark } from "@/components/brand/Logo";
import { filmTrademarks } from "@/content/films";
import { site } from "@/lib/site";

export function SiteFooter() {
  return (
    <footer className="border-t border-hairline px-6 pt-14 pb-12">
      <div className="mx-auto grid max-w-6xl gap-10 md:grid-cols-[1.4fr_1fr_1fr]">
        <div className="flex flex-col gap-4">
          <div className="flex items-center gap-3">
            <Mark className="size-8" />
            <span className="font-display text-[18px]">Redlamp</span>
          </div>
          <p className="max-w-sm text-[14px] leading-relaxed text-mute">{site.tagline}</p>
        </div>
        <nav aria-label="Project" className="flex flex-col gap-2 text-[14px]">
          <p className="eyebrow mb-1">Project</p>
          <a className="text-mute hover:text-paper" href={site.github}>
            Source on GitHub
          </a>
          <a className="text-mute hover:text-paper" href={site.readme}>
            README and status
          </a>
          <a className="text-mute hover:text-paper" href={site.contributing}>
            Contributing
          </a>
        </nav>
        <div className="flex flex-col gap-2 text-[14px]">
          <p className="eyebrow mb-1">License</p>
          <a className="text-mute hover:text-paper" href={site.license.url}>
            {site.license.long}
          </a>
          <p className="text-dim">Free, with no subscription and no cloud.</p>
        </div>
      </div>
      <div className="mx-auto mt-12 flex max-w-6xl flex-col gap-3 border-t border-hairline pt-6 text-[12px] leading-relaxed text-dim">
        <p>
          Sample photos are CC0 files from{" "}
          <a className="underline underline-offset-2 hover:text-mute" href={site.rawPixls}>
            raw.pixls.us
          </a>
          . Screenshots are generated from the app itself.
        </p>
        <p>{filmTrademarks} Lightroom is a trademark of Adobe; Redlamp isn&apos;t affiliated with Adobe.</p>
        <p>© {new Date().getFullYear()} Redlamp contributors. MPL-2.0.</p>
      </div>
    </footer>
  );
}
