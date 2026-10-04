import { feedbackConfig, parseNumbers, Rejection, statuses } from "@/lib/feedback";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** The state of reports a Mac has sent, for its Your Reports list: `?numbers=12,15`. */
export async function GET(request: Request): Promise<Response> {
  const config = feedbackConfig(process.env);
  if (!config) return Response.json({ error: "Not available right now" }, { status: 503 });
  try {
    const numbers = parseNumbers(new URL(request.url).searchParams.get("numbers"));
    return Response.json(
      { issues: await statuses(config, numbers) },
      // Every Mac asks about public issues, so the answer is shared for a few minutes.
      { headers: { "Cache-Control": "public, s-maxage=300, stale-while-revalidate=600" } },
    );
  } catch (error) {
    if (error instanceof Rejection) return Response.json({ error: error.message }, { status: error.status });
    console.error("[feedback status]", error instanceof Error ? error.message : error);
    return Response.json({ error: "GitHub didn't answer" }, { status: 502 });
  }
}
