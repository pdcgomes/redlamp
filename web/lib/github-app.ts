import { createPrivateKey, sign } from "node:crypto";

/** The Redlamp Feedback GitHub App, which files in-app reports as its bot. */
export interface AppCredentials {
  appId: string;
  installationId: string;
  privateKey: string;
}

const API = "https://api.github.com";

function base64url(data: Buffer | string): string {
  return Buffer.from(data).toString("base64url");
}

/**
 * The key as Vercel holds it: a PEM, a PEM whose newlines were pasted as `\n`, or the PEM in base64.
 */
export function normalizeKey(raw: string): string {
  const text = raw.trim();
  if (text.includes("-----BEGIN")) return text.replace(/\\n/g, "\n");
  return Buffer.from(text, "base64").toString("utf8").trim();
}

/** A JSON Web Token the app signs to ask for an installation token; GitHub accepts 10 minutes at most. */
export function appJWT(appId: string, privateKey: string, now = Date.now()): string {
  const seconds = Math.floor(now / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  // Backdated a minute for clock drift.
  const payload = base64url(JSON.stringify({ iat: seconds - 60, exp: seconds + 540, iss: appId }));
  const signature = sign("sha256", Buffer.from(`${header}.${payload}`), createPrivateKey(normalizeKey(privateKey)));
  return `${header}.${payload}.${base64url(signature)}`;
}

let cached: { token: string; expires: number; installationId: string } | undefined;

/** An installation token (valid for an hour), reused until five minutes before it expires. */
export async function installationToken(credentials: AppCredentials, now = Date.now()): Promise<string> {
  if (cached && cached.installationId === credentials.installationId && cached.expires - 5 * 60_000 > now) {
    return cached.token;
  }
  const response = await fetch(`${API}/app/installations/${credentials.installationId}/access_tokens`, {
    method: "POST",
    headers: headers(appJWT(credentials.appId, credentials.privateKey, now)),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`GitHub refused an installation token (${response.status})`);
  const body = (await response.json()) as { token: string; expires_at: string };
  cached = { token: body.token, expires: Date.parse(body.expires_at), installationId: credentials.installationId };
  return body.token;
}

function headers(bearer: string): Record<string, string> {
  return {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${bearer}`,
    "User-Agent": "redlamp-feedback-relay",
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

/** A GitHub REST call as the installation. */
export function github(token: string, path: string, init: { method?: string; body?: unknown } = {}): Promise<Response> {
  return fetch(`${API}${path}`, {
    method: init.method ?? "GET",
    headers: { ...headers(token), ...(init.body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    cache: "no-store",
    signal: AbortSignal.timeout(20_000),
  });
}
