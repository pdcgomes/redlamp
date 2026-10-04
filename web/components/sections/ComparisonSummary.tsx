import { StatusMark } from "@/components/ui/StatusMark";
import { type ComparisonGroup, statusCounts, statuses, statusStyle } from "@/lib/comparison";

/** Every feature in the comparison by status: one stacked bar and its counts. */
export function ComparisonSummary({ groups }: { groups: ComparisonGroup[] }) {
  const counts = statusCounts(groups);
  const total = Object.values(counts).reduce((sum, count) => sum + count, 0);
  return (
    <div className="flex flex-col gap-4">
      <div
        role="img"
        aria-label={statuses.map((status) => `${counts[status]} ${status.toLowerCase()}`).join(", ")}
        className="flex h-2.5 overflow-hidden rounded-full bg-paper/6"
      >
        {statuses.map((status) => (
          <span key={status} className={`h-full ${statusStyle[status].bar}`} style={{ width: `${(counts[status] / total) * 100}%` }} />
        ))}
      </div>
      <dl className="flex flex-wrap gap-x-7 gap-y-2 text-[13.5px]">
        {statuses.map((status) => (
          <div key={status} className="flex items-center gap-2">
            <StatusMark status={status} />
            <dt className="text-mute">{status}</dt>
            <dd className="font-semibold text-paper tabular-nums">{counts[status]}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}
