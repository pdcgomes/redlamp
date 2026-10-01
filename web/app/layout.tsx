import type { Metadata, Viewport } from "next";
import { Inter } from "next/font/google";
import { SiteFooter } from "@/components/site/SiteFooter";
import { SiteHeader } from "@/components/site/SiteHeader";
import { site } from "@/lib/site";
import "./globals.css";

// The optical-size axis gives Inter Display for headings, the face the wordmark is drawn in.
const inter = Inter({ subsets: ["latin"], axes: ["opsz"], variable: "--font-inter", display: "swap" });

const title = `${site.name}: a native, open-source RAW editor for the Mac`;
const icon = "/synced/brand/images/app-icon.png";

export const metadata: Metadata = {
  metadataBase: new URL(site.origin),
  title: { default: title, template: `%s · ${site.name}` },
  description: site.description,
  applicationName: site.name,
  icons: { icon, apple: icon },
  openGraph: {
    type: "website",
    siteName: site.name,
    title,
    description: site.description,
    url: site.origin,
    locale: "en_GB",
  },
  twitter: { card: "summary_large_image", title, description: site.description },
};

export const viewport: Viewport = {
  themeColor: "#0a0707",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-GB" className={inter.variable}>
      <body className="min-h-dvh font-sans antialiased">
        <div aria-hidden className="lamp-glow animate-warm-up pointer-events-none absolute inset-x-0 top-0 -z-10 h-[1100px]" />
        <a
          href="#main"
          className="sr-only rounded-md bg-paper px-4 py-2 text-ink focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50"
        >
          Skip to content
        </a>
        <SiteHeader />
        <main id="main">{children}</main>
        <SiteFooter />
      </body>
    </html>
  );
}
