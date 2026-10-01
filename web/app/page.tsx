import { EverythingToday, Features, Performance } from "@/components/sections/Features";
import { Films } from "@/components/sections/Films";
import { Gallery } from "@/components/sections/Gallery";
import { Hero } from "@/components/sections/Hero";
import { ExplainerVideo, OpenSource } from "@/components/sections/OpenSource";
import { Roadmap } from "@/components/sections/Roadmap";
import { Principles, Story } from "@/components/sections/Story";
import { gallery } from "@/content/features";

export default function HomePage() {
  return (
    <>
      <Hero />
      <Story />
      <Principles />
      <Features />
      <Performance />
      <EverythingToday />
      <Films />
      <Gallery shots={gallery} />
      <Roadmap />
      <ExplainerVideo />
      <OpenSource />
    </>
  );
}
