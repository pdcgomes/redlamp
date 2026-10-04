import { randomUUID } from "node:crypto";
import { type AppCredentials, github, installationToken } from "./github-app.ts";

/**
 * The relay behind the app's Camera Bench (CAM-16): it checks a report against
 * docs/camera-bench.schema.json, whose objects are closed so nothing but measurements gets through,
 * and keeps it in a private repository as the Redlamp Feedback app. The aggregator,
 * scripts/camera-bench.py, reads them from there (CAM-17).
 */
export interface BenchConfig extends AppCredentials {
  /** The private repository submissions are kept in, such as pdcgomes/redlamp-bench. */
  repo: string;
  /** Prepended to every path: preview/ on Preview deployments, so tests stay apart. */
  prefix: string;
}

export const limits = { bytes: 512 * 1024 };

const REPO = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/;

/** The relay's settings, or `null` when it's switched off or not set up (the route answers 503). */
export function benchConfig(env: Record<string, string | undefined>): BenchConfig | null {
  if (env.BENCH_ENABLED !== "1") return null;
  const config = {
    appId: env.FEEDBACK_GITHUB_APP_ID ?? "",
    installationId: env.FEEDBACK_GITHUB_INSTALLATION_ID ?? "",
    privateKey: env.FEEDBACK_GITHUB_APP_PRIVATE_KEY ?? "",
    repo: env.BENCH_REPO ?? "",
    prefix: env.BENCH_PREFIX ?? (env.VERCEL_ENV === "preview" ? "preview/" : ""),
  };
  if (!/^\d+$/.test(config.appId) || !/^\d+$/.test(config.installationId) || !config.privateKey) return null;
  if (!REPO.test(config.repo) || !/^([a-z0-9-]+\/)?$/.test(config.prefix)) return null;
  return config;
}

export class Rejection extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type Schema = Record<string, unknown>;

/**
 * Where `value` breaks `schema`, as "path: problem". The subset of JSON Schema 2020-12 that
 * docs/camera-bench.schema.json uses; a constraining keyword outside it is reported, so the schema
 * can't come to rely on one this ignores.
 */
export function schemaErrors(value: unknown, schema: Schema, root: Schema = schema, path = ""): string[] {
  const known = new Set([
    "$ref", "type", "enum", "const", "minimum", "maximum", "pattern", "maxLength", "properties",
    "additionalProperties", "required", "maxProperties", "items", "minItems", "maxItems",
    "$schema", "$id", "$defs", "title", "description",
  ]);
  const errors = Object.keys(schema).filter((key) => !known.has(key)).map((key) => `${path}: unsupported keyword ${key}`);
  if (typeof schema.$ref === "string") {
    const target = schema.$ref.slice(2).split("/").reduce<unknown>((node, key) => (node as Schema | undefined)?.[key], root);
    errors.push(...schemaErrors(value, (target ?? {}) as Schema, root, path));
  }
  const isObject = typeof value === "object" && value !== null && !Array.isArray(value);
  if (typeof schema.type === "string") {
    const ok = {
      object: isObject,
      array: Array.isArray(value),
      string: typeof value === "string",
      number: typeof value === "number" && Number.isFinite(value),
      integer: Number.isInteger(value),
    }[schema.type];
    if (!ok) return [...errors, `${path}: isn't of type ${schema.type}`];
  }
  if (Array.isArray(schema.enum) && !schema.enum.includes(value as never)) errors.push(`${path}: isn't one of its values`);
  if ("const" in schema && schema.const !== value) errors.push(`${path}: isn't ${String(schema.const)}`);
  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) errors.push(`${path}: is below ${schema.minimum}`);
    if (typeof schema.maximum === "number" && value > schema.maximum) errors.push(`${path}: is above ${schema.maximum}`);
  }
  if (typeof value === "string") {
    if (typeof schema.pattern === "string" && !new RegExp(schema.pattern, "u").test(value)) {
      errors.push(`${path}: doesn't match ${schema.pattern}`);
    }
    if (typeof schema.maxLength === "number" && [...value].length > schema.maxLength) {
      errors.push(`${path}: is longer than ${schema.maxLength}`);
    }
  }
  if (Array.isArray(value)) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems) errors.push(`${path}: has too few items`);
    if (typeof schema.maxItems === "number" && value.length > schema.maxItems) errors.push(`${path}: has too many items`);
    if (schema.items) value.forEach((item, index) => errors.push(...schemaErrors(item, schema.items as Schema, root, `${path}/${index}`)));
  }
  if (isObject) {
    const object = value as Record<string, unknown>;
    for (const key of (schema.required as string[] | undefined) ?? []) {
      if (!(key in object)) errors.push(`${path}: ${key} is missing`);
    }
    if (typeof schema.maxProperties === "number" && Object.keys(object).length > schema.maxProperties) {
      errors.push(`${path}: has too many keys`);
    }
    const properties = (schema.properties ?? {}) as Record<string, Schema>;
    for (const [key, child] of Object.entries(object)) {
      if (key in properties) errors.push(...schemaErrors(child, properties[key], root, `${path}/${key}`));
      else if (schema.additionalProperties === false) errors.push(`${path}/${key}: isn't allowed`);
      else if (typeof schema.additionalProperties === "object") {
        errors.push(...schemaErrors(child, schema.additionalProperties as Schema, root, `${path}/${key}`));
      }
    }
  }
  return errors;
}

/** Checks a report as the app sends it; throws a `Rejection` saying what's wrong. */
export function validate(payload: unknown, schema: Schema): Record<string, unknown> {
  const errors = schemaErrors(payload, schema);
  if (errors.length > 0) {
    throw new Rejection(400, `The report doesn't match the camera bench format: ${errors.slice(0, 3).join("; ")}`);
  }
  return payload as Record<string, unknown>;
}

/** Where a submission is kept: one file each, so concurrent submissions never collide. */
export function submissionPath(config: Pick<BenchConfig, "prefix">, id: string, date = new Date()): string {
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${config.prefix}submissions/${date.getUTCFullYear()}/${month}/${id}.json`;
}

export interface Kept {
  id: string;
  dryRun: boolean;
}

/**
 * Keeps a checked report with the day it arrived and the app's version. Neither the IP address
 * nor any other request detail is kept.
 */
export async function keep(config: BenchConfig, report: Record<string, unknown>, client: string | null, now = new Date()): Promise<Kept> {
  const id = randomUUID();
  const record = { received: now.toISOString().slice(0, 10), client: client?.slice(0, 80) ?? null, report };
  const token = await installationToken(config);
  const response = await github(token, `/repos/${config.repo}/contents/${submissionPath(config, id, now)}`, {
    method: "PUT",
    body: {
      message: `Camera bench submission ${id}`,
      content: Buffer.from(`${JSON.stringify(record, null, 1)}\n`).toString("base64"),
    },
  });
  if (!response.ok) throw new Error(`GitHub refused the submission (${response.status})`);
  return { id, dryRun: false };
}

/** What the app downloads to know what each camera mode still needs: docs/camera-bench.json, cut down. */
export function summary(evidence: unknown): { format: number; modes: Record<string, unknown>[] } {
  const modes = ((evidence as { modes?: unknown[] } | null)?.modes ?? []) as Record<string, unknown>[];
  return {
    format: 1,
    modes: modes.map((mode) => ({
      key: mode.key,
      camera: mode.camera,
      label: mode.label,
      tier: mode.tier,
      contributors: mode.contributors,
      photos: mode.photos,
      needs: mode.needs,
      verified: mode.verified,
    })),
  };
}
