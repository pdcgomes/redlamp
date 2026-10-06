import Foundation
import RedlampDocument
import RedlampEngineAPI

/// The duplicates, for the user to review (LIB-39): each group's copies with where they are, their
/// sizes and capture dates, what their sidecars hold, and the copy proposed to keep, with why; and
/// the candidates that turned out different or couldn't be compared. Nothing is chosen for removal:
/// the user chooses, and a `DuplicateRemovalPlan` holds what they chose.
public struct DuplicateReview: Sendable, Hashable {
    /// What a photo's `.redlamp` sidecar holds of what was decided about it.
    public struct SidecarContents: Sendable, Hashable, Codable {
        public var hasEdits: Bool
        public var rating: Int
        public var flag: PhotoFlag?
        public var label: ColorLabel?
        public var keywords: [String]

        public init(
            hasEdits: Bool = false, rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil,
            keywords: [String] = [],
        ) {
            self.hasEdits = hasEdits
            self.rating = rating
            self.flag = flag
            self.label = label
            self.keywords = keywords
        }

        /// What `SidecarStore` reads of it.
        public init(_ summary: SidecarSummary) {
            self.init(
                hasEdits: summary.hasEdits, rating: summary.metadata.rating, flag: summary.metadata.flag,
                label: summary.metadata.label, keywords: summary.metadata.keywords ?? [],
            )
        }

        public var isEmpty: Bool {
            !hasEdits && rating == 0 && flag == nil && label == nil && keywords.isEmpty
        }
    }

    /// A photo of a group, as the index has it and its disk says.
    public struct Copy: Sendable, Hashable, Identifiable {
        public var photo: Int64
        public var url: URL
        /// Its folder's path.
        public var folder: String
        public var size: Int64
        public var captured: Date?
        public var modified: Date
        /// Its rating in the index: its sidecar's merged with other apps' as `XMPMerge` merges them, so a
        /// sidecar without stars doesn't hide another app's rating.
        public var rating: Int
        /// What its `.redlamp` sidecar holds: nil when it has none, its disk couldn't be asked, or it
        /// couldn't be read (`sidecarURL` says where it is then).
        public var sidecar: SidecarContents?
        public var sidecarURL: URL?
        /// Another app's `.xmp` beside it.
        public var otherXMP: URL?
        /// `otherXMP` is named after the name it shares, but for its extension, with another photo of
        /// its folder (a raw and its JPEG), so it's theirs too.
        public var sharesOtherXMP: Bool
        public var status: DuplicateConfirmation.Status

        public var id: Int64 {
            photo
        }

        /// Edited, or rated in its sidecar or another app.
        public var isEditedOrRated: Bool {
            sidecar?.hasEdits == true || max(sidecar?.rating ?? 0, rating) > 0
        }
    }

    /// The copy proposed to keep, and why.
    public struct Keeper: Sendable, Hashable, Codable, CustomStringConvertible {
        public enum Reason: String, Sendable, Hashable, Codable {
            /// The only copy edited or rated.
            case onlyEditedOrRated
            /// Modified before the others, or before the other edited or rated copies.
            case oldest
            /// As old as another, with a shorter path; the first by path of those as short.
            case shortestPath
        }

        public var photo: Int64
        public var reason: Reason
        /// The group's copies that are edited or rated: when there are two or more, the keeper is
        /// one of them.
        public var editedOrRated: Int

        /// `the oldest of the 2 edited or rated copies`.
        public var description: String {
            let among = editedOrRated > 1 ? " of the \(editedOrRated) edited or rated copies" : ""
            return switch reason {
            case .onlyEditedOrRated: "the only copy edited or rated"
            case .oldest: "the oldest" + among
            case .shortestPath: "the shortest path of the oldest" + among
            }
        }
    }

    /// Copies of one file, confirmed by their full hashes.
    public struct Group: Sendable, Hashable, Identifiable {
        public var sha256: Data
        public var contentKey: ContentKey
        public var size: Int64
        /// By path.
        public var copies: [Copy]
        public var keeper: Keeper
        /// Their sidecars don't all hold the same, so removing a copy may remove what was decided there.
        public var sidecarsDiffer: Bool

        public var id: Data {
            sha256
        }

        /// What removing every copy but the keeper would free.
        public var reclaimable: Int64 {
            size * Int64(copies.count - 1)
        }

        public var kept: Copy? {
            copies.first { $0.photo == keeper.photo }
        }
    }

    /// The largest savings first.
    public var groups: [Group]
    /// Candidates whose full hashes agreed with no other's: not duplicates.
    public var different: [Copy]
    /// Candidates that couldn't be compared; their statuses say why.
    public var unconfirmed: [Copy]
    /// The copies were checked on their disks, rather than taken from the index's recorded hashes.
    public var checkedFiles: Bool

    /// What removing every copy but each group's keeper would free.
    public var reclaimable: Int64 {
        groups.reduce(0) { $0 + $1.reclaimable }
    }

    /// Every copy but each group's keeper, which `redlamp library duplicates --trash` removes.
    public var allButProposed: [Int64] {
        groups.flatMap { group in group.copies.map(\.photo).filter { $0 != group.keeper.photo } }
    }

    /// Modification dates this close count as the same: FAT and exFAT keep them to 2 seconds.
    static let sameAge: TimeInterval = 2

    /// The copy to keep: an edited or rated one before the others, then the oldest by modification
    /// date, then the one with the shortest path, then the first by path.
    static func keeper(of copies: [Copy]) -> Keeper {
        let organised = copies.filter(\.isEditedOrRated)
        if organised.count == 1 {
            return Keeper(photo: organised[0].photo, reason: .onlyEditedOrRated, editedOrRated: 1)
        }
        let pool = organised.isEmpty ? copies : organised
        let oldest = pool.map(\.modified).min() ?? .distantPast
        let first = pool.filter { $0.modified.timeIntervalSince(oldest) < sameAge }
        let chosen = first.min { lhs, rhs in
            let (left, right) = (lhs.url.path, rhs.url.path)
            return left.count != right.count ? left.count < right.count : left < right
        } ?? pool[0]
        return Keeper(
            photo: chosen.photo, reason: first.count == 1 ? .oldest : .shortestPath, editedOrRated: organised.count,
        )
    }
}
