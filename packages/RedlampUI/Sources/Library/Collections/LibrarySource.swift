import Foundation
import RedlampLibrary

/// A source the left panel's Library and Collections sections show in the grid and the filmstrip (LIB-23):
/// one of the Library section's entries, as Lightroom Classic's Catalog panel has them, one of Library
/// Health's checks (LIB-40), or a place in the collection list.
public enum LibrarySource: Sendable, Hashable {
    case allPhotographs
    /// The photos of the newest import that's over (`PreviousImport`).
    case previousImport
    /// The quick collection.
    case marked
    case rejected
    /// A check of Library Health; pairs under the rule the Library panel keeps.
    case health(HealthCheck.Kind)
    /// The photos whose read failed (LIB-40), which every other list leaves out.
    case unreadable
    /// The findings the user kept anyway, any check's.
    case keptAnyway
    /// A collection, a set (the photos of every collection inside it) or a smart collection.
    case collection(CollectionPath)

    /// The Library section's entries, in its order.
    static let library: [LibrarySource] = [.allPhotographs, .previousImport, .marked, .rejected]

    /// Library Health's entries, in its order.
    static let healthChecks: [LibrarySource] = HealthCheck.Kind.allCases.map(LibrarySource.health)
        + [.unreadable, .keptAnyway]

    public var title: String {
        switch self {
        case .allPhotographs: "All Photographs"
        case .previousImport: "Previous Import"
        case .marked: "Marked"
        case .rejected: "Rejected"
        case .health(.duplicates): "Exact Duplicates"
        case .health(.pairs): "Raw and JPEG Pairs"
        case .health(.damaged): "Damaged Files"
        case .health(.extensions): "Wrong Extensions"
        case .unreadable: "Unreadable Files"
        case .keptAnyway: "Kept Anyway"
        case let .collection(path): path.name
        }
    }

    var symbol: String {
        switch self {
        case .allPhotographs: "photo.on.rectangle"
        case .previousImport: "square.and.arrow.down"
        case .marked: "circle.inset.filled"
        case .rejected: "xmark.circle"
        case .health(.duplicates): "plus.square.on.square"
        case .health(.pairs): "square.on.square"
        case .health(.damaged): "exclamationmark.triangle"
        case .health(.extensions): "textformat"
        case .unreadable: "eye.slash"
        case .keptAnyway: "checkmark.seal"
        case .collection: "rectangle.stack"
        }
    }

    /// What it holds, for its row's help.
    var help: String {
        switch self {
        case .allPhotographs: "Every photo in the library"
        case .previousImport: "The photos the last import copied"
        case .marked: "The photos marked with B: Redlamp's quick collection"
        case .rejected: "The photos flagged as rejects"
        case .health(.duplicates): "Copies of a photo, byte for byte, found from their full SHA-256"
        case .health(.pairs): "The halves of raw and JPEG pairs the rule chosen for pairs would drop"
        case .health(.damaged): "Files that can't be read, are empty or end early"
        case .health(.extensions): "Files whose extension names another format than the one they hold"
        case .unreadable: "Files whose read failed: every other list leaves them out"
        case .keptAnyway: "The photos Library Health's checks found that were kept anyway"
        case let .collection(path): path.displayName
        }
    }

    var isHealth: Bool {
        switch self {
        case .health, .unreadable, .keptAnyway: true
        default: false
        }
    }

    /// Its photos as the library lists them; nil for Previous Import, whose photos come from the imports'
    /// journal.
    func photoSource(pairs rule: PairRule) -> PhotoSource? {
        switch self {
        case .allPhotographs: .allPhotographs
        case .previousImport: nil
        case .marked: .query(.filter(LibraryQuery.Filter(.marked, .equal, [.bool(true)])))
        case .rejected: .rejected
        case .health(.duplicates): .health(.duplicates)
        case .health(.pairs): .health(.pairs(rule))
        case .health(.damaged): .health(.damaged)
        case .health(.extensions): .health(.extensions)
        case .unreadable: .query(.filter(LibraryQuery.Filter(.unreadable, .equal, [.bool(true)])))
        case .keptAnyway: .keptAnyway
        case let .collection(path): .collection(path)
        }
    }
}
