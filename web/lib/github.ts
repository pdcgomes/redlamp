import { site } from "@/lib/site";
import { type Issue, issueNumbers } from "@/lib/tracker";

/** A read-only token, if the deployment has one, lifts GitHub's limit for anonymous requests; none is needed. */
function fetchRepo(path = ""): Promise<Response> {
  const token = process.env.GITHUB_TOKEN;
  return fetch(`https://api.github.com/repos/${site.githubRepo}${path}`, {
    headers: { Accept: "application/vnd.github+json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    next: { revalidate: 3600 },
    signal: AbortSignal.timeout(4000),
  });
}

/** The repository's star count, refreshed hourly; null if GitHub can't be reached. */
export async function starCount(): Promise<number | null> {
  try {
    const response = await fetchRepo();
    if (!response.ok) return null;
    const body = (await response.json()) as { stargazers_count?: number };
    return body.stargazers_count ?? null;
  } catch {
    return null;
  }
}

export type Release = { version: string | null; url: string };

/**
 * The latest release's disk image, or its zip for a release without one, refreshed hourly; null
 * before the first release. If GitHub can't be reached, the latest release's page with no
 * version, so the download button stays.
 */
export async function latestRelease(): Promise<Release | null> {
  const fallback = { version: null, url: `${site.github}/releases/latest` };
  try {
    const response = await fetchRepo("/releases/latest");
    if (response.status === 404) return null;
    if (!response.ok) return fallback;
    const body = (await response.json()) as {
      tag_name?: string;
      assets?: { name: string; browser_download_url: string }[];
    };
    const named = (pattern: RegExp) => body.assets?.find((asset) => pattern.test(asset.name));
    const download = named(/^Redlamp-.+\.dmg$/) ?? named(/^Redlamp-.+\.zip$/);
    if (!body.tag_name || !download) return fallback;
    return { version: body.tag_name.replace(/^v/, ""), url: download.browser_download_url };
  } catch {
    return fallback;
  }
}

/**
 * Tracker IDs to their issue numbers (the issues scripts/tracker-issues.py files), refreshed hourly.
 * Whatever GitHub doesn't answer is left out, and those rows link to a search instead.
 */
export async function trackerIssues(): Promise<Map<string, number>> {
  const issues: Issue[] = [];
  try {
    for (let page = 1; page <= 10; page += 1) {
      const response = await fetchRepo(`/issues?state=all&labels=tracker&per_page=100&page=${page}`);
      if (!response.ok) break;
      const batch = (await response.json()) as Issue[];
      issues.push(...batch);
      if (batch.length < 100) break;
    }
  } catch {
    // Keep what arrived.
  }
  return issueNumbers(issues);
}

export function formatCount(count: number): string {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10000 ? 0 : 1)}k` : String(count);
}
