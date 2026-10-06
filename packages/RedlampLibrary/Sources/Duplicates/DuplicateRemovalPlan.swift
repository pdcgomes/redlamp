import Foundation

/// The copies the user chose to remove from a review (LIB-39), each with what goes with it: its
/// `.redlamp` sidecar, what that holds, and its other app's `.xmp` where that's the photo's alone.
/// It holds only confirmed copies of a group, never all of them, and only what the user chose.
///
/// Nothing here moves a file. `DuplicateFinder.trash` carries the plan out as one batch of the file
/// operations (LIB-26): to the Trash through their journal, with Undo, once every copy and the copy
/// kept for it are found as the plan has them (their sizes, modification dates and full hashes),
/// and the batch moves nothing but the copies and their own files.
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
        /// The files, the index or the batch aren't as the plan has them: nothing was moved.
        case differs([Difference])
    }

    /// What stops the plan's batch before anything moves: a file that isn't as the plan has it, a
    /// copy kept that the plan removes too, or a file the batch would move that the plan doesn't name.
    public struct Difference: Sendable, Hashable, Codable, CustomStringConvertible {
        public enum Reason: String, Sendable, Hashable, Codable {
            /// It isn't there any more.
            case gone
            /// Its size, modification date or full SHA-256 isn't the plan's.
            case changed
            /// Its volume isn't connected, or doesn't answer.
            case offline
            case unreadable
            /// The index doesn't have the photo there any more.
            case notInLibrary
            /// Its `.redlamp` sidecar was made, removed or changed since the review.
            case sidecarChanged
            /// The plan keeps it for a copy it removes, and removes it too.
            case keptRemoved
            /// The batch would move it or take it out of the index, though it's neither one of the
            /// plan's copies nor theirs alone.
            case notInPlan
            /// The plan moves it, but the batch wouldn't.
            case notInBatch
        }

        public var path: String
        public var reason: Reason
        /// It's a copy the plan keeps, rather than one it removes or one of their files.
        public var isKept: Bool

        public init(path: String, reason: Reason, isKept: Bool = false) {
            self.path = path
            self.reason = reason
            self.isKept = isKept
        }

        /// `/Photos/B/X.JPG has changed since the review`.
        public var description: String {
            let file = isKept ? path + ", the copy kept," : path
            return switch reason {
            case .gone: "\(file) isn't there any more"
            case .changed: "\(file) has changed since the review"
            case .offline: "\(file) can't be checked: its volume isn't connected, or doesn't answer"
            case .unreadable: "\(file) couldn't be read"
            case .notInLibrary: "\(file) isn't in the library there any more"
            case .sidecarChanged: "\(path)'s sidecar has changed since the review"
            case .keptRemoved: "\(path) is kept for another copy, so it can't be removed too"
            case .notInPlan: "\(path) would go to the Trash, though the plan doesn't name it"
            case .notInBatch: "\(path) wouldn't go to the Trash, though the plan names it"
            }
        }
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
        let copies = Set(review.groups.flatMap { $0.copies.map(\.photo) })
        if let stray = chosen.sorted().first(where: { !copies.contains($0) }) {
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
