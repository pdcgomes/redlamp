/** A row of a Markdown table: its cells by column name, the `##` section it sits under, and its line (from 1). */
export type TableRow = { section: string; line: number; cells: Record<string, string> };

/**
 * Every body row of the tables in `markdown` whose first column is named `first`. Cells are trimmed; a
 * table ends at the first line that isn't a table line.
 */
export function tableRows(markdown: string, first: string): TableRow[] {
  const rows: TableRow[] = [];
  let section = "";
  let header: string[] | null = null;
  markdown.split("\n").forEach((line, index) => {
    if (line.startsWith("## ")) section = line.slice(3).trim();
    if (!line.startsWith("|")) {
      header = null;
      return;
    }
    const cells = line.trim().replace(/^\||\|$/g, "").split("|").map((cell) => cell.trim());
    if (cells[0] === first) {
      header = cells;
    } else if (header && !/^[-:\s]+$/.test(cells[0])) {
      const columns = header;
      rows.push({ section, line: index + 1, cells: Object.fromEntries(columns.map((name, i) => [name, cells[i] ?? ""])) });
    }
  });
  return rows;
}
