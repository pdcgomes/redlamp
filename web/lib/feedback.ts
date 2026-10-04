import { type AppCredentials, github, installationToken } from "./github-app.ts";

/**
 * The relay behind Redlamp's Report a Bug or Send Feedback: it files a report as a GitHub issue
 * as the Redlamp Feedback bot, so nobody needs a GitHub account, with its screenshots and
 * diagnostics.json in a public attachments repo. The app writes the issue; this checks it, stores
 * the files and puts their addresses in.
 */
export interface FeedbackConfig extends AppCredentials {
  /** Where issues go: pdcgomes/redlamp in production, pdcgomes/redlamp-feedback on Preview. */
  repo: string;
  /** Where attachments go. */
  assetsRepo: string;
}

export type Kind = "bug" | "idea" | "question";

export interface Attachment {
  name: string;
  type: string;
  data: Buffer;
}

export interface Submission {
  report: string;
  kind: Kind;
  area: string | null;
  title: string;
  body: string;
  labels: string[];
  attachments: Attachment[];
  dryRun: boolean;
}

export const limits = {
  title: 256,
  body: 62_000,
  screenshots: 3,
  screenshotBytes: 1_500_000,
  diagnosticsBytes: 2_000_000,
  totalBytes: 4_200_000,
};

const KIND_LABELS: Record<Kind, string> = { bug: "bug", idea: "enhancement", question: "question" };
const REPO = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/;

/** The relay's settings, or `null` when it's switched off or not set up (the route answers 503). */
export function feedbackConfig(env: Record<string, string | undefined>): FeedbackConfig | null {
  if (env.FEEDBACK_ENABLED !== "1") return null;
  const config = {
    appId: env.FEEDBACK_GITHUB_APP_ID ?? "",
    installationId: env.FEEDBACK_GITHUB_INSTALLATION_ID ?? "",
    privateKey: env.FEEDBACK_GITHUB_APP_PRIVATE_KEY ?? "",
    repo: env.FEEDBACK_REPO ?? "",
    assetsRepo: env.FEEDBACK_ASSETS_REPO ?? "",
  };
  if (!/^\d+$/.test(config.appId) || !/^\d+$/.test(config.installationId) || !config.privateKey) return null;
  if (!REPO.test(config.repo) || !REPO.test(config.assetsRepo)) return null;
  return config;
}

export class Rejection extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function string(value: unknown, name: string, max: number): string {
  if (typeof value !== "string" || !value.trim()) throw new Rejection(400, `${name} is missing`);
  if (value.length > max) throw new Rejection(413, `${name} is longer than ${max} characters`);
  return value;
}

/** Checks a report as the app sends it, and decodes its attachments. */
export function validate(payload: unknown): Submission {
  if (typeof payload !== "object" || payload === null) throw new Rejection(400, "The report isn't JSON");
  const input = payload as Record<string, unknown>;
  const report = string(input.report, "report", 64);
  if (!/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/.test(report)) {
    throw new Rejection(400, "report isn't a UUID");
  }
  const kind = input.kind;
  if (kind !== "bug" && kind !== "idea" && kind !== "question") throw new Rejection(400, "kind isn't bug, idea or question");
  let area: string | null = null;
  if (input.area !== undefined && input.area !== null) {
    area = string(input.area, "area", 80);
    if (!/^[a-z-]+\.[a-z0-9-]+$/.test(area)) throw new Rejection(400, "area isn't a feature ID");
  }
  const title = string(input.title, "title", limits.title);
  const body = string(input.body, "body", limits.body);

  const allowed = new Set(["in-app", KIND_LABELS[kind], ...(area ? [`component:${area.split(".")[0]}`] : [])]);
  if (!Array.isArray(input.labels) || input.labels.some((label) => typeof label !== "string" || !allowed.has(label))) {
    throw new Rejection(400, "labels must be in-app, the kind's label and the area's component label");
  }

  if (!Array.isArray(input.attachments)) throw new Rejection(400, "attachments is missing");
  if (input.attachments.length > limits.screenshots + 1) throw new Rejection(413, "too many attachments");
  let total = 0;
  const names = new Set<string>();
  const attachments = input.attachments.map((value): Attachment => {
    const item = (value ?? {}) as Record<string, unknown>;
    const name = string(item.name, "an attachment's name", 64);
    if (names.has(name)) throw new Rejection(400, `${name} is attached twice`);
    names.add(name);
    const data = Buffer.from(string(item.data, `${name}'s data`, 8_000_000), "base64");
    total += data.length;
    if (/^screenshot-[1-3]\.jpg$/.test(name)) {
      if (item.type !== "image/jpeg" || data[0] !== 0xff || data[1] !== 0xd8 || data[2] !== 0xff) {
        throw new Rejection(400, `${name} isn't a JPEG`);
      }
      if (data.length > limits.screenshotBytes) throw new Rejection(413, `${name} is too large`);
    } else if (name === "diagnostics.json") {
      if (item.type !== "application/json" || data.length > limits.diagnosticsBytes) {
        throw new Rejection(413, "diagnostics.json is too large or not JSON");
      }
      try {
        if (typeof JSON.parse(data.toString("utf8")) !== "object") throw new Error();
      } catch {
        throw new Rejection(400, "diagnostics.json isn't a JSON object");
      }
    } else {
      throw new Rejection(400, `${name} isn't an attachment a report can have`);
    }
    return { name, type: item.type as string, data };
  });
  if (total > limits.totalBytes) throw new Rejection(413, "The attachments are too large together");

  return {
    report,
    kind,
    area,
    title: neutralized(title),
    body: neutralized(body),
    labels: input.labels as string[],
    attachments,
    dryRun: input.dryRun === true,
  };
}

/**
 * HTML comments that could pass for the tracker's own markers (`scripts/tracker-issues.py` adopts an
 * issue carrying `<!-- tracker-id: … -->`). Only the report's own `redlamp-feedback` marker stays.
 */
export function neutralized(text: string): string {
  return text.replace(/<!--(?!\s*redlamp-feedback v\d+ \{)/g, "&lt;!--");
}

/** Where an attachment is stored: one folder per report, by month. */
export function assetPath(report: string, name: string, date = new Date()): string {
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `reports/${date.getUTCFullYear()}/${month}/${report.toLowerCase()}/${name}`;
}

/** The body with each `attachment:<name>` link pointing at its file; links to files not stored say so. */
export function withAttachments(body: string, links: Record<string, string>): string {
  return body.replace(/\]\(attachment:([A-Za-z0-9._-]+)\)/g, (_, name: string) =>
    links[name] ? `](${links[name]})` : "](#not-attached)",
  );
}

// MARK: - Filing

export interface Filed {
  number: number;
  url: string;
}

async function upload(token: string, config: FeedbackConfig, submission: Submission, attachment: Attachment) {
  const path = assetPath(submission.report, attachment.name);
  const target = `/repos/${config.assetsRepo}/contents/${path}`;
  let response = await github(token, target, {
    method: "PUT",
    body: { message: `Report ${submission.report}: ${attachment.name}`, content: attachment.data.toString("base64") },
  });
  // A retry of the same report finds its file already there.
  if (response.status === 422) response = await github(token, target);
  if (!response.ok) throw new Error(`GitHub didn't store ${attachment.name} (${response.status})`);
  const stored = (await response.json()) as {
    content?: { download_url: string; html_url: string };
    download_url?: string;
    html_url?: string;
  };
  const file = stored.content ?? stored;
  // Images show from their raw address; diagnostics.json reads better on GitHub's page.
  const url = attachment.type === "image/jpeg" ? file.download_url : file.html_url;
  if (!url) throw new Error(`GitHub stored ${attachment.name} without an address`);
  return url;
}

let knownLabels: { repo: string; names: Set<string>; fetched: number } | undefined;

/** Labels that exist in the repo, so a report never creates one (scripts/feedback-labels.py makes them). */
async function existingLabels(token: string, repo: string): Promise<Set<string>> {
  if (knownLabels && knownLabels.repo === repo && Date.now() - knownLabels.fetched < 10 * 60_000) return knownLabels.names;
  const names = new Set<string>();
  for (let page = 1; page <= 5; page++) {
    const response = await github(token, `/repos/${repo}/labels?per_page=100&page=${page}`);
    if (!response.ok) break;
    const labels = (await response.json()) as { name: string }[];
    labels.forEach((label) => names.add(label.name));
    if (labels.length < 100) break;
  }
  knownLabels = { repo, names, fetched: Date.now() };
  return names;
}

/** Stores the attachments, then files the issue. */
export async function fileReport(config: FeedbackConfig, submission: Submission): Promise<Filed> {
  const token = await installationToken(config);
  const links: Record<string, string> = {};
  for (const attachment of submission.attachments) {
    links[attachment.name] = await upload(token, config, submission, attachment);
  }
  const labels = await existingLabels(token, config.repo);
  const response = await github(token, `/repos/${config.repo}/issues`, {
    method: "POST",
    body: {
      title: submission.title,
      body: withAttachments(submission.body, links),
      labels: submission.labels.filter((label) => labels.has(label)),
    },
  });
  if (!response.ok) throw new Error(`GitHub didn't file the issue (${response.status})`);
  const issue = (await response.json()) as { number: number; html_url: string };
  return { number: issue.number, url: issue.html_url };
}

// MARK: - Status, for Your Reports

export interface IssueStatus {
  number: number;
  state: "open" | "closed" | "missing";
  stateReason: string | null;
  title: string | null;
  comments: number;
  updatedAt: string | null;
  milestone: string | null;
  url: string | null;
}

/** "12,15,20" as issue numbers: at most 50, each a positive integer. */
export function parseNumbers(query: string | null): number[] {
  const parts = (query ?? "").split(",").filter(Boolean);
  if (parts.length === 0 || parts.length > 50) throw new Rejection(400, "numbers must list 1 to 50 issues");
  return parts.map((part) => {
    if (!/^\d{1,7}$/.test(part)) throw new Rejection(400, `${part} isn't an issue number`);
    return Number(part);
  });
}

export async function statuses(config: FeedbackConfig, numbers: number[]): Promise<IssueStatus[]> {
  const token = await installationToken(config);
  return Promise.all(
    numbers.map(async (number): Promise<IssueStatus> => {
      const response = await github(token, `/repos/${config.repo}/issues/${number}`);
      if (!response.ok) {
        return { number, state: "missing", stateReason: null, title: null, comments: 0, updatedAt: null, milestone: null, url: null };
      }
      const issue = (await response.json()) as {
        state: "open" | "closed";
        state_reason: string | null;
        title: string;
        comments: number;
        updated_at: string;
        milestone: { title: string } | null;
        html_url: string;
      };
      return {
        number,
        state: issue.state,
        stateReason: issue.state_reason,
        title: issue.title,
        comments: issue.comments,
        updatedAt: issue.updated_at,
        milestone: issue.milestone?.title ?? null,
        url: issue.html_url,
      };
    }),
  );
}
