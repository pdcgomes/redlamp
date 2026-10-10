import Foundation
import RedlampDocument

/// A check of Library Health (LIB-40): a list of the photos needing a decision, from the index, the
/// column store and the indexer's one read of each file. A check with no findings isn't offered, and
/// nothing is done to a photo but as one batch the user confirms.
public enum HealthCheck: Sendable, Hashable {
    /// Copies of one file, by content key and size, confirmed by full SHA-256 hashes (LIB-39).
    case duplicates
    /// Raw and JPEG pairs (LIB-28), under the rule the user picked: none until it isn't to keep both.
    case pairs(PairRule)
    /// Files that can't be read, are empty or end early.
    case damaged
    /// Photos whose files went from their folders outside Redlamp (DEC-59), the one list that shows them: found again
    /// with Locate…, or taken out of the library with Remove.
    case missing
    /// Files whose first bytes hold another family's format than their extension says.
    case extensions

    /// What it checks, without a pair rule: as Keep Anyway's file and the command line name it.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        case duplicates, pairs, damaged, missing, extensions
    }

    public var kind: Kind {
        switch self {
        case .duplicates: .duplicates
        case .pairs: .pairs
        case .damaged: .damaged
        case .missing: .missing
        case .extensions: .extensions
        }
    }

    /// The checks in the order Library Health lists them, with pairs under `rule`.
    public static func all(pairs rule: PairRule = .keepBoth) -> [HealthCheck] {
        [.duplicates, .pairs(rule), .damaged, .missing, .extensions]
    }

    /// Its name, as Library Health lists it.
    public var title: String {
        switch self {
        case .duplicates: "Exact duplicates"
        case .pairs: "Raw and JPEG pairs"
        case .damaged: "Damaged files"
        case .missing: "Missing photos"
        case .extensions: "Wrong extensions"
        }
    }

    /// Whether its photos include those that can't be read, which other lists leave out.
    var findsUnreadable: Bool {
        self == .damaged || self == .missing
    }
}

/// What to do with raw and JPEG pairs (LIB-40): keep both halves, the default, or drop one of them.
public enum PairRule: String, Sendable, Hashable, CaseIterable, Codable {
    case keepBoth = "both"
    case keepRaw = "raw"
    /// Keep the JPEG, or the HEIC where there's no JPEG.
    case keepJPEG = "jpeg"
}

/// A photo a check found, with why in words and what it proposes. A proposal is the check's, drawn
/// apart from the user's own flags and never written as one.
public struct HealthFinding: Sendable, Hashable, Identifiable {
    public var photo: Int64
    public var check: HealthCheck.Kind
    public var reason: HealthReason
    /// Nil where the check proposes nothing for it: one listed apart.
    public var proposal: HealthProposal?
    /// Why it's listed apart and left out of the check's batch unless chosen.
    public var apart: HealthApart?
    /// The photos it's found with: a duplicate's group, by its full SHA-256, or a pair, by the
    /// half kept.
    public var group: HealthGroup?

    public init(
        photo: Int64, check: HealthCheck.Kind, reason: HealthReason, proposal: HealthProposal? = nil,
        apart: HealthApart? = nil, group: HealthGroup? = nil,
    ) {
        self.photo = photo
        self.check = check
        self.reason = reason
        self.proposal = proposal
        self.apart = apart
        self.group = group
    }

    public var id: Int64 {
        photo
    }

    /// Whether the check's batch acts on it: it has a proposal to act on and isn't listed apart.
    public var isProposed: Bool {
        apart == nil && (proposal == .trash || proposal?.renamed != nil)
    }
}

/// What a check proposes for a photo.
public enum HealthProposal: Sendable, Hashable, CustomStringConvertible {
    /// To the Trash.
    case trash
    /// Kept: the copy a duplicate group keeps.
    case keep
    /// Renamed to `name`, in its folder.
    case rename(to: String)

    public var renamed: String? {
        guard case let .rename(name) = self else { return nil }
        return name
    }

    public var description: String {
        switch self {
        case .trash: "move to the Trash"
        case .keep: "keep"
        case let .rename(name): "rename to \(name)"
        }
    }
}

/// The photos a finding is found with.
public enum HealthGroup: Sendable, Hashable {
    /// A duplicate group, by the full SHA-256 its copies share.
    case duplicates(sha256: Data)
    /// A pair, by the half the rule keeps.
    case pair(kept: Int64)
}

/// Why a check found a photo, in words.
public enum HealthReason: Sendable, Hashable, CustomStringConvertible {
    /// A copy of the one kept, byte for byte, at `path`.
    case duplicate(of: String)
    /// The copy its group keeps, and why.
    case keeper(DuplicateReview.Keeper)
    /// The half of a pair the rule drops, beside `kept`, the name of the half it keeps.
    case pairHalf(PhotoRecord.Kind, beside: String)
    case damage(PhotoHealth.Damage)
    /// Gone from `folder`, where it was, since change tracking found its file gone at `since` (DEC-59).
    case missing(from: String, since: Date?)
    /// Named with `ext`, holding `format`, which takes another extension.
    case wrongExtension(named: String, holds: PhotoFormat)

    /// "byte-identical to /Photos/A/IMG_1.JPG", "the JPEG beside IMG_1.ARW", "can't be read:
    /// Input/output error", "gone from /Photos/A since 2026-10-10 11:08", "named .JPG, holds HEIC".
    public var description: String {
        switch self {
        case let .duplicate(path): "byte-identical to \(path)"
        case let .keeper(keeper): "the copy kept: \(keeper)"
        case let .pairHalf(kind, kept): "the \(Self.name(of: kind)) beside \(kept)"
        case let .damage(damage): damage.description
        case let .missing(folder, since):
            "gone from \(folder)" + (since.map { " since " + Self.time($0) } ?? "")
        case let .wrongExtension(ext, format): "named .\(ext), holds \(format.title)"
        }
    }

    /// `2026-10-10 11:08`, in this Mac's zone.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func name(of kind: PhotoRecord.Kind) -> String {
        switch kind {
        case .raw: "raw"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .png: "PNG"
        case .other: "file"
        }
    }
}

/// Why a finding is listed apart from its check's proposals, and left out of its batch unless the
/// user chooses it.
public enum HealthApart: Sendable, Hashable, CustomStringConvertible {
    /// It holds decisions of its own the photo kept doesn't: a pair's half with its own edit,
    /// keywords, title, caption, rating, flag or label.
    case own([OwnDecision])
    /// The user rated, flagged or labelled it: a proposal never acts on it.
    case decided

    public enum OwnDecision: String, Sendable, Hashable, CaseIterable {
        case edit, keywords, title, caption, rating, flag, label
    }

    /// "has its own edit and keywords", "rated, flagged or labelled".
    public var description: String {
        switch self {
        case let .own(decisions):
            let names = decisions.map(\.rawValue)
            let listed = names.count > 1
                ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : names.first ?? ""
            return "has its own \(listed)"
        case .decided:
            return "rated, flagged or labelled"
        }
    }
}

/// What a check found among the library's photos.
public struct HealthFindings: Sendable, Hashable {
    public var check: HealthCheck
    /// In the check's order: by group, then by path.
    public var findings: [HealthFinding]
    /// Photos the check would have found but for Keep Anyway.
    public var keptAnyway: Int
    /// Duplicate candidates no recorded hash confirms yet: reading them whole would say.
    public var unconfirmed: Int

    public init(check: HealthCheck, findings: [HealthFinding] = [], keptAnyway: Int = 0, unconfirmed: Int = 0) {
        self.check = check
        self.findings = findings
        self.keptAnyway = keptAnyway
        self.unconfirmed = unconfirmed
    }

    /// The photos it lists: the check's source.
    public var photos: [Int64] {
        findings.map(\.photo)
    }

    /// The photos its batch acts on unless the user chooses others.
    public var proposed: [Int64] {
        findings.filter(\.isProposed).map(\.photo)
    }

    /// Whether it's offered: it found something.
    public var isEmpty: Bool {
        findings.isEmpty
    }

    public func finding(for photo: Int64) -> HealthFinding? {
        findings.first { $0.photo == photo }
    }
}
