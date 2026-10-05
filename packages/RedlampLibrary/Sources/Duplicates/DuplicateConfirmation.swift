import Foundation

/// Copies of one file: two or more photos whose full SHA-256 agree (LIB-39).
public struct DuplicateGroup: Sendable, Hashable {
    public var sha256: Data
    public var contentKey: ContentKey
    public var size: Int64
    /// In ID order.
    public var photos: [Int64]
}

/// What confirming the candidates found (LIB-39): which are copies of one file by their full
/// SHA-256, which turned out to be different files, and which couldn't be compared, and why.
public struct DuplicateConfirmation: Sendable, Hashable {
    /// Why a candidate wasn't compared with the others.
    public enum Unconfirmed: String, Sendable, Hashable, Codable, CaseIterable {
        /// Its volume isn't connected, or doesn't answer.
        case offline
        /// It's gone from its folder.
        case missing
        /// Its file isn't as the index has it: changed since it was indexed, or while it was read.
        case changed
        case unreadable
        /// Confirming wasn't asked to read files, and no hash recorded for it stands.
        case notRead
        /// No other photo of its group could be compared with it.
        case alone
    }

    public enum Status: Sendable, Hashable {
        /// Its full SHA-256 agrees with another photo's of its group: they're copies of one file.
        case duplicate(sha256: Data)
        /// Its full SHA-256 agrees with none of the others read, though its content key and size do.
        case different(sha256: Data)
        case unconfirmed(Unconfirmed)

        public var sha256: Data? {
            switch self {
            case let .duplicate(sha256), let .different(sha256): sha256
            case .unconfirmed: nil
            }
        }
    }

    public struct Candidate: Sendable, Hashable {
        public var photo: Int64
        public var status: Status
    }

    /// A candidate group, each of its photos with what confirming found.
    public struct Group: Sendable, Hashable {
        public var contentKey: ContentKey
        public var size: Int64
        /// In ID order.
        public var candidates: [Candidate]
    }

    public var groups: [Group]
    /// The files compared on their disks: false when the index's recorded hashes were all it had.
    public var checkedFiles: Bool
    /// Files read and hashed, and those whose recorded hash stood.
    public var hashed: Int
    public var reused: Int
    public var bytesRead: Int64
    public var elapsed: Duration

    /// The copies of one file found, the largest files first.
    public var duplicates: [DuplicateGroup] {
        groups.flatMap { group in
            Dictionary(grouping: group.candidates.compactMap { candidate -> (Data, Int64)? in
                guard case let .duplicate(sha256) = candidate.status else { return nil }
                return (sha256, candidate.photo)
            }) { $0.0 }.map { sha256, photos in
                DuplicateGroup(
                    sha256: sha256, contentKey: group.contentKey, size: group.size, photos: photos.map(\.1).sorted(),
                )
            }
            .sorted { $0.photos[0] < $1.photos[0] }
        }
    }

    /// The candidates whose full hashes agreed with no other's.
    public var different: [Int64] {
        groups.flatMap { group in
            group.candidates.compactMap { candidate in
                if case .different = candidate.status {
                    candidate.photo
                } else {
                    nil
                }
            }
        }
    }

    /// The candidates that couldn't be compared, with why.
    public var unconfirmed: [Candidate] {
        groups.flatMap { $0.candidates.filter { $0.status.sha256 == nil } }
    }
}
