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
  "Help Redlamp support your camera: the camera bench checks your own raw files on your Mac, against the JPEG your camera saved, and sends only the measurements.";

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
  const problems = bench.filter((camera) => camera.problems).length;
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
            LibRaw reads the raw files of {read.toLocaleString("en-GB")} cameras, and Redlamp&apos;s own tests check{" "}
            {verifiedCameras} of them, on CC0 samples. Every other camera depends on people who own one. The camera bench
            in Redlamp checks how your camera&apos;s raw files open, on your Mac, against the JPEG your camera saved
            inside each one, and sends only the measurements, so the{" "}
            <a href="/cameras" className={link}>
              cameras page
            </a>{" "}
            can say which cameras work and what to fix.
          </p>
          <p className="mt-4 text-[17px] leading-relaxed text-mute">
            It takes a few minutes, with photos you already have.
            {hasBench(release?.version)
              ? ""
              : " The camera bench is new: it comes with Redlamp's next release, and builds from source have it today."}
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
              They&apos;re kept privately and combined into evidence for each camera mode, which the{" "}
              <a href="/cameras" className={link}>
                cameras page
              </a>{" "}
              shows. A mode is reported working once a photo opens with nothing failing, and tested by photographers
              once three people have sent ten photos covering the conditions in step 2, with nothing failing. A failure
              two people see is reported as a problem, and goes on Redlamp&apos;s tracker.
            </p>
          </div>
          <div className="surface p-6">
            <h2 className="font-display text-[18px] text-paper">Make your camera verified</h2>
            <p className="mt-2 text-[14px] leading-relaxed text-mute">
              A camera is verified once a CC0 sample of it is in Redlamp&apos;s decode tests, which check it on every
              change. If you&apos;re willing to give one photo to the public domain, upload it to{" "}
              <a href={site.rawPixls} className={link}>
                raw.pixls.us
              </a>{" "}
              and{" "}
              <a href={`${site.github}/issues/new`} className={link}>
                open an issue
              </a>{" "}
              naming it.
            </p>
          </div>
          <div className="surface p-6">
            <h2 className="font-display text-[18px] text-paper">From the command line</h2>
            <p className="mt-2 text-[14px] leading-relaxed text-mute">
              Built from source, <code className="whitespace-nowrap text-paper">redlamp camera-bench</code> runs the same checks on files
              or folders, and writes the report (<code className="whitespace-nowrap text-paper">-o</code>) and the side-by-side pairs (
              <code className="whitespace-nowrap text-paper">--pairs</code>).
            </p>
          </div>
        </div>

        <p className="mt-10 max-w-3xl text-[13px] leading-relaxed text-dim">
          The first evidence is the bench&apos;s own run over raw.pixls.us&apos;s CC0 files: {bench.length} camera modes,{" "}
          {problems} of them with a problem found. The screenshots show the Camera Bench on Redlamp&apos;s CC0 test
          samples.
        </p>
      </div>
    </section>
  );
}
