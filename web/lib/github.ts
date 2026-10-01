import { site } from "@/lib/site";

/** The repository's star count, refreshed hourly; null if GitHub can't be reached. */
export async function starCount(): Promise<number | null> {
  try {
    const response = await fetch(`https://api.github.com/repos/${site.githubRepo}`, {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 3600 },
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) return null;
    const body = (await response.json()) as { stargazers_count?: number };
    return body.stargazers_count ?? null;
  } catch {
    return null;
  }
}

export function formatCount(count: number): string {
  return count >= 1000 ? `${(count / 1000).toFixed(count >= 10000 ? 0 : 1)}k` : String(count);
}
