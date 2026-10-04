import { feedbackConfig, fileReport, limits, Rejection, validate, withAttachments } from "@/lib/feedback";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

function reply(status: number, body: object): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

/** Files a report from Redlamp as a GitHub issue (see lib/feedback.ts). */
export async function POST(request: Request): Promise<Response> {
  const config = feedbackConfig(process.env);
  if (!config) return reply(503, { error: "Reports can't be filed right now. Please try again later." });
  if (Number(request.headers.get("content-length") ?? 0) > limits.totalBytes * 1.4 + limits.body * 2) {
    return reply(413, { error: "The report is too large" });
  }
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return reply(400, { error: "The report isn't JSON" });
  }
  try {
    const submission = validate(payload);
    if (submission.dryRun) {
      const names = Object.fromEntries(submission.attachments.map((file) => [file.name, `attachment:${file.name}`]));
      return reply(200, {
        dryRun: true,
        title: submission.title,
        body: withAttachments(submission.body, names),
        labels: submission.labels,
      });
    }
    const filed = await fileReport(config, submission);
    return reply(201, filed);
  } catch (error) {
    if (error instanceof Rejection) return reply(error.status, { error: error.message });
    console.error("[feedback]", error instanceof Error ? error.message : error);
    return reply(502, { error: "GitHub didn't accept the report. Please try again in a few minutes." });
  }
}
