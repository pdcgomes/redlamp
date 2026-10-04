import { summary } from "@/lib/bench";
import { cameraBenchEvidence } from "@/lib/repo";

export const dynamic = "force-static";

/**
 * What each camera mode still needs, for the app's Camera Bench: docs/camera-bench.json cut down.
 * The whole list is sent, so the site never learns which cameras someone has.
 */
export function GET(): Response {
  return Response.json(summary(cameraBenchEvidence()));
}
