import { existsSync } from "node:fs";
import path from "node:path";
import { AppIcon } from "@/components/brand/Logo";
import { Badge } from "@/components/ui/Badge";
import { GitHubGlyph, LinkButton } from "@/components/ui/Buttons";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { site } from "@/lib/site";

const video = { src: "/video/redlamp-explainer.mp4", poster: "/video/redlamp-explainer-poster.jpg" };

/** Shown once the explainer has been rendered into public/video (see video/). */
export function ExplainerVideo() {
  if (!existsSync(path.join(process.cwd(), "public", video.src))) return null;
  return (
    <section id="film-explainer" aria-label="Redlamp in 72 seconds" className="px-6 pb-24">
      <div className="mx-auto max-w-5xl">
        <p className="eyebrow text-center">Redlamp in 72 seconds</p>
        <video
          className="shot mt-6 aspect-video w-full rounded-2xl border border-hairline bg-bakelite"
          controls
          preload="none"
          playsInline
          poster={video.poster}
        >
          <source src={video.src} type="video/mp4" />
        </video>
      </div>
    </section>
  );
}

export function OpenSource() {
  return (
    <section id="open-source" className="scroll-mt-24 px-6 pb-28">
      <div className="surface relative mx-auto max-w-6xl overflow-hidden px-6 py-14 sm:px-12">
        <div
          aria-hidden
          className="absolute -top-40 left-1/2 h-80 w-[46rem] -translate-x-1/2 bg-[radial-gradient(closest-side,rgb(224_64_46/0.22),transparent)]"
        />
        <div className="relative grid gap-12 lg:grid-cols-[1.1fr_1fr]">
          <div>
            <AppIcon size={72} />
            <div className="mt-6">
              <SectionHeading eyebrow="Open source" title="Free, open and yours to build on.">
                Redlamp is licensed under the {site.license.long}, which is compatible with the App Store. Algorithms
                are implemented clean-room from papers and specifications, and contributions are welcome.
              </SectionHeading>
            </div>
            <div className="mt-6 flex flex-wrap gap-2">
              <Badge label="license" value={site.license.name} href={site.license.url} tone="accent" />
              <Badge label="status" value={site.stage} href={`${site.github}#where-we-are`} tone="caution" />
              <Badge label="cost" value="free forever" />
              <Badge label="cloud" value="none required" />
            </div>
            <div className="mt-8 flex flex-wrap gap-3">
              <LinkButton href={site.github} variant="primary">
                <GitHubGlyph />
                Star on GitHub
              </LinkButton>
              <LinkButton href={site.contributing}>How to contribute</LinkButton>
            </div>
          </div>
          <div className="flex flex-col gap-5">
            <div>
              <p className="text-[14px] font-semibold text-paper">Build from source</p>
              <p className="mt-1 text-[13px] text-mute">An Apple Silicon Mac with macOS 26, Xcode 26 and mise.</p>
              <pre className="mt-3 overflow-x-auto rounded-xl border border-hairline bg-wall/80 p-4 font-mono text-[12.5px] leading-relaxed text-ring">
                {site.buildFromSource.map((line) => `$ ${line}`).join("\n")}
              </pre>
            </div>
            <div>
              <p className="text-[14px] font-semibold text-paper">
                Homebrew <span className="font-normal text-mute">(with the first release)</span>
              </p>
              <pre className="mt-3 overflow-x-auto rounded-xl border border-hairline bg-wall/80 p-4 font-mono text-[12.5px] leading-relaxed text-ring">
                {site.homebrew.map((line) => `$ ${line}`).join("\n")}
              </pre>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
