import type { Metadata } from "next";
import Image from "next/image";
import { DownloadGlyph, LinkButton } from "@/components/ui/Buttons";
import { LightboxGroup, ShotButton } from "@/components/ui/Lightbox";
import { benchSteps } from "@/content/camera-bench";
import { latestRelease } from "@/lib/github";
import { cameras } from "@/lib/repo";
import { site } from "@/lib/site";

const title = "Test your camera with Redlamp";
const description =
  "Help Redlamp support your camera. The camera bench checks your raw files on your Mac, compares them with the JPEGs your camera saved, and sends only the measurements.";

export const metadata: Metadata = {
  title: "Test your camera",
  description,
  alternates: { canonical: "/cameras/test" },
  openGraph: { type: "website", siteName: site.name, title, description, url: "/cameras/test", locale: "en_GB" },
  twitter: { card: "summary_large_image", title, description },
};

const link = "text-paper underline decoration-hairline-strong underline-offset-3 hover:decoration-paper";
const shots = benchSteps.flatMap((step) => (step.shot ? [step.shot] : []));
/** The last release without the camera bench. */
const before = [0, 2, 3];

function hasBench(version: string | null | undefined): boolean {
  if (!version) return false;
  const parts = version.split("-")[0].split(".").map(Number);
  for (let index = 0; index < before.length; index += 1) {
    if ((parts[index] ?? 0) !== before[index]) return (parts[index] ?? 0) > before[index];
  }
  return false;
}

export default async function TestYourCameraPage() {
  const { verified, bench, makes } = cameras();
  const read = makes.reduce((sum, make) => sum + make.models.length, 0);
  const verifiedCameras = new Set(verified.map((camera) => camera.camera)).size;
  const benchCameras = new Set(bench.map((camera) => camera.camera)).size;
  const withProblems = new Set(bench.filter((camera) => camera.problems).map((camera) => camera.camera)).size;
  const release = await latestRelease();
  return (
    <section className="px-6 pt-16 pb-24">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-3xl">
          <p className="eyebrow">
            <a href="/cameras" className="hover:text-paper">
              Cameras
            </a>
          </p>
          <h1 className="font-display mt-3 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">{title}</h1>
          <p className="mt-5 text-[17px] leading-relaxed text-mute">
            LibRaw can read the raw files of {read.toLocaleString("en-GB")} cameras, but Redlamp&apos;s own decode
            tests cover {verifiedCameras} of them, using CC0 sample photos. For every other camera, Redlamp relies on
            the people who own one. The camera bench, built into Redlamp, opens your raw files on your Mac and compares
            each one with the JPEG your camera saved inside it. Only the measurements are sent. Combined with everyone
            else&apos;s, they let the{" "}
            <a href="/cameras" className={link}>
              cameras page
            </a>{" "}
            show which cameras work and what needs fixing.
          </p>
          <p className="mt-4 text-[17px] leading-relaxed text-mute">
            It takes a few minutes and works with photos you already have.
            {hasBench(release?.version)
              ? ""
              : " The camera bench comes with Redlamp's next release; if you build Redlamp from source, it's in your build now."}
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <LinkButton href={release?.url ?? `${site.github}/releases/latest`} variant="primary">
              <DownloadGlyph />
              Download for Mac
            </LinkButton>
            <LinkButton href={`${site.github}/blob/main/docs/camera-bench.md`}>How the bench works</LinkButton>
          </div>
        </div>

        <LightboxGroup shots={shots}>
          <ol className="mt-16 flex flex-col gap-20">
            {benchSteps.map((step, index) => (
              <li
                key={step.title}
                className={`grid gap-8 ${step.shot ? "lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:items-start" : ""}`}
              >
                <div className="max-w-3xl">
                  <p className="eyebrow">Step {index + 1}</p>
                  <h2 className="font-display mt-2 text-[26px] leading-snug text-paper">{step.title}</h2>
                  {step.body.map((paragraph) => (
                    <p key={paragraph} className="mt-3 text-[15.5px] leading-relaxed text-mute">
                      {paragraph}
                    </p>
                  ))}
                  {step.list ? (
                    <ul className="mt-3 flex list-disc flex-col gap-1.5 pl-5 text-[15px] leading-relaxed text-mute">
                      {step.list.map((item) => (
                        <li key={item}>{item}</li>
                      ))}
                    </ul>
                  ) : null}
                </div>
                {step.shot ? (
                  <figure>
                    <ShotButton index={shots.indexOf(step.shot)} label={step.shot.alt}>
                      <Image
                        src={step.shot.src}
                        alt={step.shot.alt}
                        width={step.shot.width}
                        height={step.shot.height}
                        sizes="(min-width: 1024px) 680px, 94vw"
                        className="shot h-auto w-full"
                      />
                    </ShotButton>
                    <figcaption className="mt-3 text-[13px] text-dim">{step.shot.caption}</figcaption>
                  </figure>
                ) : null}
              </li>
            ))}
          </ol>
        </LightboxGroup>

        <div className="mt-24 grid gap-4 md:grid-cols-3">
          <div className="surface p-6">
            <h2 className="font-display text-[18px] text-paper">What happens to your results</h2>
            <p className="mt-2 text-[14px] leading-relaxed text-mute">
              Your results are stored privately and combined with everyone else&apos;s for the same camera and raw
              mode, and the{" "}
              <a href="/cameras" className={link}>
                cameras page
              </a>{" "}
              shows where each stands. A mode is reported working once one photo opens with no check failing. It counts
              as tested by photographers when three people have sent ten photos between them that cover base and high
              ISO, portrait orientation, clipped highlights and warm light. No more than one photo in ten may fail a
              check, and two people must answer that the photos look the same. A failure seen by two people, or an
              answer that the photos differ, marks it as a problem.
            </p>
          </div>
          <div className="surface p-6">
            <h2 className="font-display text-[18px] text-paper">Get your camera verified</h2>
            <p className="mt-2 text-[14px] leading-relaxed text-mute">
              A camera counts as verified once a CC0 sample photo from it is part of Redlamp&apos;s decode tests, which
              run on every change. If you&apos;re happy to release one photo into the public domain, upload it to{" "}
              <a href={site.rawPixls} className={link}>
                raw.pixls.us
              </a>{" "}
              and{" "}
              <a href={`${site.github}/issues/new`} className={link}>
                open an issue
              </a>{" "}
              with a link to it.
            </p>
          </div>
          <div className="surface p-6">
            <h2 className="font-display text-[18px] text-paper">From the command line</h2>
            <p className="mt-2 text-[14px] leading-relaxed text-mute">
              If you build Redlamp from source,{" "}
              <code className="whitespace-nowrap text-paper">redlamp camera-bench</code> runs the same checks on files
              or folders. Add <code className="whitespace-nowrap text-paper">-o</code> to
              save the report and <code className="whitespace-nowrap text-paper">--pairs</code> to save the
              side-by-side images.
            </p>
          </div>
        </div>

        <p className="mt-10 max-w-3xl text-[13px] leading-relaxed text-dim">
          The first results come from running the bench on the CC0 files at raw.pixls.us: {benchCameras} cameras, with a
          problem found in {withProblems} of them. The screenshots show the Camera Bench on Redlamp&apos;s own CC0 test
          photos.
        </p>
      </div>
    </section>
  );
}
