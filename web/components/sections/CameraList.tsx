"use client";

import { useState } from "react";
import type { CameraMake } from "@/lib/cameras";

const markLabel = {
  verified: "Verified",
  tested: "Tested by photographers",
  problem: "Problem reported",
  working: "Reported working",
  unconfirmed: "Problem found once",
  evaluation: "In an evaluation set",
} as const;

/** Every camera LibRaw reads, by make, with a search that matches the make or the model. */
export function CameraList({ makes }: { makes: CameraMake[] }) {
  const [query, setQuery] = useState("");
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const visible = makes
    .map((make) => ({
      make: make.make,
      models: make.models.filter((model) => words.every((word) => `${make.make} ${model.name}`.toLowerCase().includes(word))),
    }))
    .filter((make) => make.models.length > 0);
  const count = visible.reduce((sum, make) => sum + make.models.length, 0);

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center gap-4">
        <input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search for your camera, such as Z 6 or A7R"
          aria-label="Search cameras"
          className="w-full max-w-sm rounded-pill border border-hairline-strong bg-paper/5 px-4 py-2 text-[14px] text-paper placeholder:text-dim focus:outline-none focus-visible:border-ring"
        />
        <p aria-live="polite" className="text-[13px] text-dim">
          {count.toLocaleString("en-GB")} {count === 1 ? "camera" : "cameras"}
        </p>
      </div>
      {visible.length === 0 ? (
        <p className="text-[15px] text-mute">
          Not in LibRaw&apos;s list. Bodies released after this LibRaw version need an update; a camera that writes DNG
          may still open through LibRaw&apos;s DNG support.
        </p>
      ) : (
        <div className="columns-1 gap-8 sm:columns-2 lg:columns-3">
          {visible.map((make) => (
            <section key={make.make} className="mb-7 break-inside-avoid">
              <h3 className="font-display text-[16px] text-paper">
                {make.make} <span className="text-[12.5px] font-normal text-dim">{make.models.length}</span>
              </h3>
              <ul className="mt-2 flex flex-col gap-1 text-[13.5px] leading-snug text-mute">
                {make.models.map((model) => (
                  <li key={model.name} className="flex flex-wrap items-baseline gap-x-2">
                    <span className={model.mark ? "text-paper" : undefined}>{model.name}</span>
                    {model.mark ? (
                      <span
                        className={`text-[11.5px] font-medium ${
                          model.mark === "verified" || model.mark === "tested" ? "text-filament" : "text-ring"
                        }`}
                      >
                        {markLabel[model.mark]}
                      </span>
                    ) : null}
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
