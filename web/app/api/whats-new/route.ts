import { feed, whatsNew } from "@/lib/whats-new";

export const dynamic = "force-static";

/**
 * Each release's highlights, for the app's What's New window; no page links here. The whole feed
 * is sent, and the app picks what its version has.
 */
export function GET(): Response {
  return Response.json(feed(whatsNew()));
}
