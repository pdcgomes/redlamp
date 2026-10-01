import Image from "next/image";
import { AppIcon } from "@/components/brand/Logo";
import { Badge } from "@/components/ui/Badge";
import { DownloadGlyph, GitHubGlyph, LinkButton } from "@/components/ui/Buttons";
import { heroShot } from "@/content/features";
import { latestRelease } from "@/lib/github";
import { site } from "@/lib/site";

export async function Hero() {
  const release = await latestRelease();
  // The pill already names the stage, so the version drops its -prealpha suffix.
  const version = release?.version?.split("-")[0];
  const status = `${site.status.stage}${version ? ` ${version}` : ""} · ${site.status.platform}`;
  return (
    <section className="px-6 pt-16 pb-10 sm:pt-24">
      <div className="mx-auto flex max-w-5xl flex-col items-center text-center">
        <div className="animate-rise relative">
          <div aria-hidden className="animate-breathe absolute -inset-10 rounded-full bg-safelight/25 blur-3xl" />
          <AppIcon size={112} className="relative" />
        </div>
        <p className="animate-rise mt-8 inline-flex items-center gap-2 rounded-pill border border-hairline bg-paper/5 px-3 py-1 text-[12px] font-medium text-mute [animation-delay:120ms]">
          <span className="size-1.5 rounded-full bg-filament" />
          {status}
        </p>
        <h1 className="font-display animate-rise mt-6 text-[clamp(2.3rem,6vw,4.25rem)] leading-[1.04] text-balance [animation-delay:200ms]">
          Lightroom&apos;s workflow.
          <br />
          <span className="text-mute">Native to your Mac. Open source.</span>
        </h1>
        <p className="animate-rise mt-6 max-w-2xl text-[18px] leading-relaxed text-mute [animation-delay:280ms]">
          Redlamp is a RAW photo editor built from scratch in Swift and Metal for Apple Silicon. It keeps the panels,
          sliders and shortcuts you already know, renders every change within a frame, and never touches your
          originals.
        </p>
        <div className="animate-rise mt-9 flex flex-wrap items-center justify-center gap-3 [animation-delay:360ms]">
          {release ? (
            <LinkButton href={release.url} variant="primary">
              <DownloadGlyph />
              Download for Mac
            </LinkButton>
          ) : null}
          <LinkButton href={site.github} variant={release ? "secondary" : "primary"}>
            <GitHubGlyph />
            View on GitHub
          </LinkButton>
          <LinkButton href="#open-source">Build from source</LinkButton>
        </div>
        <div className="animate-rise mt-8 flex flex-wrap items-center justify-center gap-2 [animation-delay:440ms]">
          <Badge label="status" value={site.stage} href={`${site.github}#where-we-are`} tone="caution" />
          <Badge label="license" value={site.license.name} href={site.license.url} tone="accent" />
          <Badge label="open source" value="yes" href={site.github} />
          <Badge label="price" value="free, no subscription" />
          <Badge label="AI" value="on-device" />
          <Badge label="runs on" value="macOS 26 · Apple Silicon" />
          <Badge label="built with" value="Swift · Metal" />
          <Badge label="support" value="Ko-fi" href={site.support} />
        </div>
      </div>
      <figure className="animate-rise mx-auto mt-16 max-w-6xl [animation-delay:520ms]">
        <Image
          src={heroShot.src}
          alt={heroShot.alt}
          width={heroShot.width}
          height={heroShot.height}
          priority
          sizes="(min-width: 1200px) 1152px, 96vw"
          className="shot h-auto w-full"
        />
        <figcaption className="mt-4 text-center text-[13px] text-dim">{heroShot.caption}</figcaption>
      </figure>
    </section>
  );
}
