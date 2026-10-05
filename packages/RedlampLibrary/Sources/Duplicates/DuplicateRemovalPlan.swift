import Foundation

/// The copies the user chose to remove from a review (LIB-39), each with what goes with it: its
/// `.redlamp` sidecar, what that holds, and its other app's `.xmp` where that's the photo's alone.
/// It holds only confirmed copies of a group, never all of them, and only what the user chose.
///
/// Nothing here moves a file. File operations (LIB-26) carry the plan out: to the Trash through
/// their journal, with Undo, each copy only once they find it and the copy kept in its place as
/// the plan says (their sizes and modification dates).
public struct DuplicateRemovalPlan: Sendable, Hashable, Codable {
    /// A copy that stays: the one its removal leaves.
    public struct Kept: Sendable, Hashable, Codable {
        public var photo: Int64
        public var file: URL
        public var size: Int64
        public var modified: Date
    }

    public struct Removal: Sendable, Hashable, Codable {
        public var photo: Int64
        public var file: URL
        public var size: Int64
        public var modified: Date
        /// The full SHA-256 it shares with `kept`.
        public var sha256: Data
        /// Its `.redlamp` sidecar, and what that holds: nil when it has none, and the contents nil too
        /// for one that couldn't be read.
        public var sidecar: URL?
        public var sidecarContents: DuplicateReview.SidecarContents?
        /// Its other app's `.xmp`. One named after a name the photo shares with another of its
        /// folder's (a raw and its JPEG) is theirs too, and stays.
        public var otherXMP: URL?
        public var kept: Kept
    }

    public enum Refusal: Error, Sendable, Hashable {
        /// The review's copies weren't checked on their disks.
        case unchecked
        /// The photo isn't a confirmed copy in the review.
        case notADuplicate(photo: Int64)
        /// Every copy of the group with this full SHA-256 was chosen.
        case everyCopy(sha256: Data)
    }

    public private(set) var removals: [Removal]

    /// The bytes it frees.
    public var bytes: Int64 {
        removals.reduce(0) { $0 + $1.size }
    }

    /// The plan to remove `photos`, each a confirmed copy in `review`, leaving at least one copy of
    /// each group: its proposed keeper, or else the copy that would have been proposed of those
    /// left. Refused, with nothing planned, for any other photo, for every copy of a group, or for
    /// a review whose copies weren't checked on their disks.
    public init(_ review: DuplicateReview, removing photos: some Sequence<Int64>) throws(Refusal) {
        guard review.checkedFiles else { throw .unchecked }
        let chosen = Set(photos)
        var groupOf: [Int64: DuplicateReview.Group] = [:]
        for group in review.groups {
            for copy in group.copies {
                groupOf[copy.photo] = group
            }
        }
        if let stray = chosen.sorted().first(where: { groupOf[$0] == nil }) {
            throw .notADuplicate(photo: stray)
        }
        var removals: [Removal] = []
        for group in review.groups {
            let removed = group.copies.filter { chosen.contains($0.photo) }
            guard !removed.isEmpty else { continue }
            let left = group.copies.filter { !chosen.contains($0.photo) }
            guard !left.isEmpty else { throw .everyCopy(sha256: group.sha256) }
            let keeper = left.contains { $0.photo == group.keeper.photo }
                ? group.keeper.photo : DuplicateReview.keeper(of: left).photo
            let kept = left.first { $0.photo == keeper } ?? left[0]
            for copy in removed {
                removals.append(Removal(
                    photo: copy.photo, file: copy.url, size: copy.size, modified: copy.modified, sha256: group.sha256,
                    sidecar: copy.sidecarURL, sidecarContents: copy.sidecar,
                    otherXMP: copy.sharesOtherXMP ? nil : copy.otherXMP,
                    kept: Kept(photo: kept.photo, file: kept.url, size: kept.size, modified: kept.modified),
                ))
            }
        }
        self.removals = removals
    }
}
