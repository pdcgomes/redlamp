import { Lockup } from "@/components/brand/Logo";
import { MobileMenu } from "@/components/site/MobileMenu";
import { GitHubGlyph, StarGlyph } from "@/components/ui/Buttons";
import { formatCount, starCount } from "@/lib/github";
import { site } from "@/lib/site";

// Absolute, so they also work from the blog.
const links = [
  { href: "/#features", label: "Features" },
  { href: "/#film", label: "Film" },
  { href: "/#roadmap", label: "Roadmap" },
  { href: "/compare", label: "Compare" },
  { href: "/cameras", label: "Cameras" },
  { href: "/performance", label: "Performance" },
  { href: "/blog", label: "Blog" },
];

export async function SiteHeader() {
  const stars = await starCount();
  return (
    <header className="sticky top-0 z-40 px-4 pt-4">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[calc(100%+12px)] bg-linear-to-b from-wall via-wall/70 to-transparent"
      />
      <div className="glass mx-auto flex max-w-6xl items-center justify-between rounded-pill py-2 pr-2 pl-4">
        <a href="/#main" aria-label="Redlamp home">
          <Lockup className="h-6 w-auto" />
        </a>
        <nav className="flex items-center gap-1 text-[13px]">
          {links.map((link) => (
            <a
              key={link.href}
              href={link.href}
              className="hidden rounded-pill px-3 py-1.5 text-mute transition-colors hover:text-paper sm:block"
            >
              {link.label}
            </a>
          ))}
          <a
            href={site.github}
            className="button-secondary ml-1 inline-flex items-center gap-2 rounded-pill px-3 py-1.5 font-semibold"
          >
            <GitHubGlyph />
            GitHub
            {stars !== null ? (
              <span className="inline-flex items-center gap-1 border-l border-hairline-strong pl-2 font-medium text-mute">
                <StarGlyph />
                {formatCount(stars)}
              </span>
            ) : null}
          </a>
          <MobileMenu links={links} />
        </nav>
      </div>
    </header>
  );
}
