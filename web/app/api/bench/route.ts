import { benchConfig, keep, limits, Rejection, validate } from "@/lib/bench";
import { cameraBenchSchema } from "@/lib/repo";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 30;

function reply(status: number, body: object): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

/**
 * Keeps a camera bench report from Redlamp in the private submissions repository (see
 * lib/bench.ts). `X-Redlamp-Dry-Run: 1` checks it and keeps nothing, as Debug builds send.
 */
export async function POST(request: Request): Promise<Response> {
  const dryRun = request.headers.get("x-redlamp-dry-run") === "1";
  const config = benchConfig(process.env);
  if (!config && !dryRun) return reply(503, { error: "Results can't be received right now. Please try again later." });
  if (Number(request.headers.get("content-length") ?? 0) > limits.bytes) {
    return reply(413, { error: "The report is too large" });
  }
  let payload: unknown;
  try {
    const text = await request.text();
    if (text.length > limits.bytes) return reply(413, { error: "The report is too large" });
    payload = JSON.parse(text);
  } catch {
    return reply(400, { error: "The report isn't JSON" });
  }
  try {
    const report = validate(payload, cameraBenchSchema());
    if (dryRun || !config) return reply(200, { id: "dry-run", dryRun: true });
    return reply(201, await keep(config, report, request.headers.get("x-redlamp-client")));
  } catch (error) {
    if (error instanceof Rejection) return reply(error.status, { error: error.message });
    console.error("[bench]", error instanceof Error ? error.message : error);
    return reply(502, { error: "The results couldn't be kept. Please try again in a few minutes." });
  }
}
