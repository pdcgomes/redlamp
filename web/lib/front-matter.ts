/**
 * Front matter as the site's Markdown files write it: `key: value` lines between two `---` lines,
 * with quotes around a value stripped. Relative imports only, so `node --test` can load it.
 */
export function readFrontMatter(source: string): { fields: Map<string, string>; body: string } | null {
  const match = source.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return null;
  const fields = new Map<string, string>();
  for (const line of match[1].split(/\r?\n/)) {
    const field = line.match(/^(\w+):\s*(.*?)\s*$/);
    if (field) fields.set(field[1], field[2].replace(/^(["'])(.*)\1$/, "$2"));
  }
  return { fields, body: match[2] };
}
