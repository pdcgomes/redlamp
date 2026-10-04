import { type Status, statusStyle } from "@/lib/comparison";

/** The small dot that marks a feature's status in the comparison and its summaries. */
export function StatusMark({ status }: { status: Status }) {
  return <span aria-hidden className={`inline-block size-2 shrink-0 rounded-full ${statusStyle[status].dot}`} />;
}
