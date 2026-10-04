import type { Metadata } from "next";
import { CommandPalette } from "@/components/sections/CommandPalette";
import { EverythingToday, Features, Performance } from "@/components/sections/Features";
import { Films } from "@/components/sections/Films";
import { Gallery } from "@/components/sections/Gallery";
import { Hero } from "@/components/sections/Hero";
import { OpenSource } from "@/components/sections/OpenSource";
import { Roadmap } from "@/components/sections/Roadmap";
import { Principles, Story } from "@/components/sections/Story";
import { WatchFilm } from "@/components/sections/WatchFilm";
import { gallery } from "@/content/features";

// Here rather than in the layout, which every page shares; the blog's pages give their own.
export const metadata: Metadata = { alternates: { canonical: "/" } };

export default function HomePage() {
  return (
    <>
      <Hero />
      <Story />
      <Principles />
      <CommandPalette />
      <Features />
      <Performance />
      <EverythingToday />
      <Films />
      <Gallery shots={gallery} />
      <Roadmap />
      <WatchFilm />
      <OpenSource />
    </>
  );
}
