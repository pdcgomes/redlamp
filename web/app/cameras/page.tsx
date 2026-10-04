import type { Metadata } from "next";
import { CameraList } from "@/components/sections/CameraList";
import { cameras, sourceCommit } from "@/lib/repo";
import { site } from "@/lib/site";

const title = "The cameras Redlamp reads";
const description =
  "Redlamp reads raw files with LibRaw. Every camera LibRaw supports, and the ones Redlamp's own tests verify on CC0 samples from raw.pixls.us.";

export const metadata: Metadata = {
  title: "Cameras",
  description,
  alternates: { canonical: "/cameras" },
  openGraph: { type: "website", siteName: site.name, title, description, url: "/cameras", locale: "en_GB" },
  twitter: { card: "summary_large_image", title, description },
};

const link = "text-paper underline decoration-hairline-strong underline-offset-3 hover:decoration-paper";

export default function CamerasPage() {
  const { libraw, verified, evaluated, makes } = cameras();
  const supported = makes.reduce((sum, make) => sum + make.models.length, 0);
  const commit = sourceCommit();
  // A camera verified in more than one format has a row for each.
  const verifiedCameras = new Set(verified.map((camera) => camera.camera)).size;
  const stats = [
    { value: verifiedCameras, label: "verified by Redlamp's decode tests" },
    { value: evaluated.length, label: "developed in Redlamp's evaluation sets" },
    { value: supported.toLocaleString("en-GB"), label: `read by LibRaw ${libraw}` },
  ];
  return (
    <section className="px-6 pt-16 pb-24">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-3xl">
          <p className="eyebrow">Cameras</p>
          <h1 className="font-display mt-3 text-[clamp(2.2rem,5vw,3.4rem)] leading-[1.05] text-paper">{title}</h1>
          <p className="mt-5 text-[17px] leading-relaxed text-mute">
            Redlamp opens raw files with{" "}
            <a href="https://www.libraw.org" className={link}>
              LibRaw
            </a>{" "}
            {libraw}, an open-source library that reads the formats of more than a thousand cameras, used under the
            CDDL-1.0. LibRaw only unpacks the sensor data and the file&apos;s metadata: black levels, white balance,
            demosaicing, highlight reconstruction, colour and everything after are Redlamp&apos;s own, on the GPU.
          </p>
          <p className="mt-4 text-[17px] leading-relaxed text-mute">
            LibRaw reading a camera&apos;s files isn&apos;t the same as Redlamp having checked them. Below, the cameras
            Redlamp&apos;s tests verify on CC0 samples from{" "}
            <a href={site.rawPixls} className={link}>
              raw.pixls.us
            </a>{" "}
            come first, then the ones its evaluation sets develop, then everything LibRaw reads.
          </p>
        </div>

        <dl className="surface mt-10 grid gap-6 p-6 sm:grid-cols-3 sm:p-8">
          {stats.map((stat) => (
            <div key={stat.label} className="flex flex-col-reverse">
              <dt className="mt-2 text-[14px] text-mute">{stat.label}</dt>
              <dd className="font-display text-[clamp(2rem,4vw,2.6rem)] leading-none text-paper">{stat.value}</dd>
            </div>
          ))}
        </dl>

        <div className="mt-16 max-w-3xl">
          <h2 className="font-display text-[24px] leading-snug">Verified</h2>
          <p className="mt-3 text-[15px] leading-relaxed text-mute">
            Each has a CC0 sample in Redlamp&apos;s decode tests, which check its layout, crop, black and white levels,
            white balance, colour matrix, orientation and sensor data on every test run. A colour reference means its
            default rendering is also compared with a recorded one (CIEDE2000).
          </p>
        </div>
        <div className="surface mt-6 overflow-hidden">
          <table className="w-full border-collapse text-left text-[14px]">
            <thead className="hidden text-[11px] tracking-[0.12em] text-dim uppercase md:table-header-group">
              <tr className="border-b border-hairline">
                <th className="py-3 pr-3 pl-5 font-semibold">Camera</th>
                <th className="px-3 py-3 font-semibold">Format</th>
                <th className="px-3 py-3 font-semibold">Sensor</th>
                <th className="px-3 py-3 font-semibold">Resolution</th>
                <th className="px-3 py-3 font-semibold">Colour reference</th>
                <th className="py-3 pr-5 pl-3 font-semibold">Sample</th>
              </tr>
            </thead>
            <tbody>
              {verified.map((camera) => (
                <tr key={`${camera.camera} ${camera.format}`} className="border-b border-hairline align-top last:border-b-0">
                  <td className="py-3.5 pr-3 pl-5">
                    <p className="font-medium text-paper">{camera.camera}</p>
                    <p className="mt-1 text-[13px] text-mute md:hidden">
                      {camera.format} · {camera.sensor}
                      {camera.resolution ? ` · ${camera.resolution}` : ""}
                      {camera.colourReference ? " · colour reference" : ""}
                    </p>
                    {camera.sample ? (
                      <a
                        href={camera.sample.href}
                        className="mt-1 block font-mono text-[12px] break-all text-mute underline decoration-hairline-strong underline-offset-3 md:hidden"
                      >
                        {camera.sample.name}
                      </a>
                    ) : null}
                  </td>
                  <td className="hidden px-3 py-3.5 font-mono text-[13px] text-mute md:table-cell">{camera.format}</td>
                  <td className="hidden px-3 py-3.5 whitespace-nowrap text-mute md:table-cell">{camera.sensor}</td>
                  <td className="hidden px-3 py-3.5 whitespace-nowrap text-mute md:table-cell">{camera.resolution}</td>
                  <td className="hidden px-3 py-3.5 text-mute md:table-cell">{camera.colourReference ? "Yes" : "No"}</td>
                  <td className="hidden py-3.5 pr-5 pl-3 md:table-cell">
                    {camera.sample ? (
                      <a href={camera.sample.href} className="font-mono text-[12.5px] text-mute underline decoration-hairline-strong underline-offset-3 hover:text-paper">
                        {camera.sample.name}
                      </a>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-16 max-w-3xl">
          <h2 className="font-display text-[24px] leading-snug">In an evaluation set</h2>
          <p className="mt-3 text-[15px] leading-relaxed text-mute">
            A CC0 sample from each is developed in Redlamp&apos;s look-development set or its dust evaluation, but its
            decoding isn&apos;t checked field by field.
          </p>
        </div>
        <ul className="mt-6 grid gap-x-8 gap-y-2.5 text-[14px] sm:grid-cols-2 lg:grid-cols-3">
          {evaluated.map((camera) => (
            <li key={camera.camera} className="flex flex-col">
              {camera.sample ? (
                <a href={camera.sample.href} className="text-paper hover:text-filament">
                  {camera.camera}
                </a>
              ) : (
                <span className="text-paper">{camera.camera}</span>
              )}
              <span className="text-[12.5px] text-dim">{camera.set}</span>
            </li>
          ))}
        </ul>

        <div className="mt-16 max-w-3xl">
          <h2 className="font-display text-[24px] leading-snug">Read by LibRaw {libraw}</h2>
          <p className="mt-3 text-[15px] leading-relaxed text-mute">
            LibRaw&apos;s own list, with the limits it notes beside a camera. Redlamp hasn&apos;t checked each one, and a
            camera without a sample may have quirks no test has caught, in its colour, crop or levels for example. Cameras
            released after LibRaw {libraw} need a LibRaw update.
          </p>
        </div>
        <div className="mt-8">
          <CameraList makes={makes} />
        </div>

        <div className="surface mt-14 flex flex-col gap-3 p-6 sm:p-8">
          <h2 className="font-display text-[20px] leading-snug">Is your camera missing from the verified list?</h2>
          <p className="max-w-3xl text-[15px] leading-relaxed text-mute">
            A CC0 sample is how a camera gets into the tests. Upload one to{" "}
            <a href={site.rawPixls} className={link}>
              raw.pixls.us
            </a>{" "}
            and{" "}
            <a href={`${site.github}/issues/new`} className={link}>
              open an issue
            </a>{" "}
            naming it.
          </p>
          <p className="text-[12.5px] text-dim">
            Read from{" "}
            <a href={`${site.github}/blob/main/docs/cameras.md`} className="underline decoration-hairline-strong underline-offset-3 hover:text-mute">
              docs/cameras.md
            </a>
            {commit ? ` at commit ${commit}` : ""}, which scripts/camera-list.py generates from the decode tests and
            LibRaw&apos;s camera list.
          </p>
        </div>
      </div>
    </section>
  );
}
