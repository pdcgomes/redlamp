import { AppIcon } from "@/components/brand/Logo";
import { LinkButton, ProductHuntGlyph } from "@/components/ui/Buttons";
import { site } from "@/lib/site";

/** Product Hunt's embed for Redlamp, drawn in the brand's materials rather than Product Hunt's white and orange. */
export function ProductHuntCard({ className = "" }: { className?: string }) {
  return (
    <div className={`rounded-xl border border-hairline bg-wall/80 p-4 ${className}`}>
      <div className="flex items-center gap-3">
        <AppIcon size={56} className="shrink-0" />
        <div>
          <p className="font-display text-[17px] leading-snug text-paper">{site.name}</p>
          <p className="mt-0.5 text-[13px] leading-snug text-mute">{site.productHunt.tagline}</p>
        </div>
      </div>
      <LinkButton href={site.productHunt.url} className="mt-4">
        <ProductHuntGlyph />
        View on Product Hunt
      </LinkButton>
    </div>
  );
}
