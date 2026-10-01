import { site } from "@/lib/site";

function fetchRepo(path = ""): Promise<Response> {
  return fetch(`https://api.github.com/repos/${site.githubRepo}${path}`, {
    headers: { Accept: "application/vnd.github+json" },
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
 * The latest release's zip, refreshed hourly; null before the first release. If GitHub can't
 * be reached, the latest release's page with no version, so the download button stays.
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
    const zip = body.assets?.find((asset) => /^Redlamp-.+\.zip$/.test(asset.name));
    if (!body.tag_name || !zip) return fallback;
    return { version: body.tag_name.replace(/^v/, ""), url: zip.browser_download_url };
  } catch {
    return fallback;
  }
}

export function formatCount(count: number): string {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10000 ? 0 : 1)}k` : String(count);
}
