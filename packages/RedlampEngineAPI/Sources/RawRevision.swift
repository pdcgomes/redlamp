/// How the raw stages, from normalisation to the demosaic, develop a photo (`docs/raw-pipeline.md`).
///
/// A photo's pyramid is built when it opens, from the decoded file alone, before any edit is known.
/// So a raw-stage change that would render an existing edit differently adds a revision, the
/// process version it ships in maps to it, and an older edit renders from the photo built again at
/// its own revision.
public enum RawRevision: Int, Sendable, Hashable, Comparable {
    /// Processes 1 to 14.
    case first = 1
    /// Process 15 on: clipped highlights keep the colour of what's around them (CAM-31).
    case second

    public init(processVersion: Int) {
        self = processVersion >= 15 ? .second : .first
    }

    /// New edits'.
    public static let current = RawRevision(processVersion: EditRecipe.currentProcessVersion)

    public static func < (lhs: RawRevision, rhs: RawRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension EditRecipe {
    /// The raw revision the edit renders with.
    var rawRevision: RawRevision {
        RawRevision(processVersion: processVersion)
    }
}
