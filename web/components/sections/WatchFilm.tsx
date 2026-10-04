import { YouTubeFilm } from "@/components/ui/YouTubeFilm";
import { site } from "@/lib/site";

export function WatchFilm() {
  const { film } = site;
  return (
    <section id="watch" aria-label={film.title} className="scroll-mt-24 px-6 pb-24">
      <div className="mx-auto max-w-5xl">
        <p className="eyebrow text-center">{film.title}</p>
        {/* A box-shadow rather than .shot's filter, which a playing iframe shouldn't sit under. */}
        <div className="relative mt-6 aspect-video overflow-hidden rounded-2xl border border-hairline bg-bakelite shadow-[0_30px_60px_rgb(0_0_0/0.55),0_6px_14px_rgb(0_0_0/0.4)]">
          <YouTubeFilm id={film.youtube} title={film.title} duration={film.duration} poster={film.poster} url={film.url} />
        </div>
        <p className="mt-4 text-center text-[13px] text-dim">
          <a href={film.url} className="text-mute underline decoration-hairline-strong underline-offset-3 hover:text-paper">
            Watch on YouTube
          </a>
        </p>
      </div>
    </section>
  );
}
