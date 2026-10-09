import Foundation

public enum FileOperationError: Error, Sendable, Hashable {
    /// Nothing moved: something is where a step would put a file, or a file a step moves has gone or
    /// been written since the batch was planned.
    case conflicts([FileConflict])
    /// A batch a forced quit interrupted waits to be finished or rolled back (`recover`).
    case unfinished(UUID)
    case noSuchBatch(UUID)
    /// The batch's file in the journal can't be read.
    case damagedJournal(UUID)
    /// The batch was written by a newer Redlamp.
    case newerJournal(UUID)
    /// No batch is left that can be undone.
    case nothingToUndo
    /// The path isn't in any of the library's folders.
    case notInLibrary(String)
    /// A folder can't go inside itself.
    case insideItself(String)
    /// A folder added to the library moves only by being added where it goes.
    case isRoot(String)
    /// A step failed, and what the batch had done was rolled back.
    case failed(path: String, message: String)
    /// A step failed and what it had done couldn't be put back: the batch stays in the journal for
    /// the next launch to finish or roll back.
    case stuck(UUID, path: String, message: String)
}

/// Why a batch can't start.
public struct FileConflict: Sendable, Hashable, CustomStringConvertible {
    public enum Reason: String, Sendable, Hashable, Codable {
        /// Something is already at the path a step would put a file.
        case taken
        /// The file isn't where the batch found it.
        case gone
        /// The file is there, but written since the batch was planned: another size or modification
        /// date.
        case changed
        /// The folder a file would go in isn't there.
        case noFolder
    }

    public var path: String
    public var reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }

    public var description: String {
        switch reason {
        case .taken: "\(path) is already there"
        case .gone: "\(path) isn't there any more"
        case .changed: "\(path) has changed since the batch was planned"
        case .noFolder: "\(path) has no folder to go in"
        }
    }
}

/// Where a batch has got to, as it runs.
public struct FileProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int
    /// Going back over what was done: after a failure, or when rolling back.
    public var isRollingBack: Bool

    public init(done: Int, total: Int, isRollingBack: Bool = false) {
        self.done = done
        self.total = total
        self.isRollingBack = isRollingBack
    }
}

/// What to do with a batch a forced quit interrupted.
public enum FileRecovery: String, Sendable, Hashable, CaseIterable {
    /// Carry on to the end, or, if that can't be done, roll back.
    case finish
    /// Put back everything it did.
    case rollBack
}

/// What a batch did.
public struct FileOutcome: Sendable, Hashable {
    public var batch: UUID
    public var kind: FileBatch.Kind
    public var title: String
    public var state: FileJournal.State
    public var steps: Int
    /// Steps done, once it's over: all of them when finished, none when rolled back.
    public var done: Int
    /// Photos renamed, moved, moved to the Trash or put back.
    public var photos: Int
    /// Original names written in sidecars.
    public var originalNamesRecorded = 0
    /// Photos whose sidecar this build can't write (`SidecarStore.protection(for:)`), so their original
    /// names weren't recorded or cleared, by path.
    public var originalNamesSkipped: [String] = []
    /// How long recording and clearing original names in sidecars took.
    public var originalNamesTime = Duration.zero
    /// Copies whose sidecar this build can't write, so they're still in their originals' collections and stack in
    /// it, by path; the index has them in none.
    public var copiesNotDetached: [String] = []
    /// The photos it did, by index ID, once it's over: renamed, moved, moved to the Trash or put back; for a copy,
    /// the photos it copied.
    public var photoIDs: [Int64] = []
    /// Folders left where they were because something was put in them meanwhile.
    public var foldersLeft: [String] = []
    /// What couldn't be undone because it wasn't where the batch put it any more: emptied from the
    /// Trash, say.
    public var gone: [String] = []
    /// The photos it was asked to move to the Trash that the index no longer had, left out
    /// (`FileBatch.notInIndex`).
    public var notInIndex: [Int64]
    /// For a batch that was rolled back: why.
    public var failure: String?
    /// Steps a forced quit had left done, for a batch that was recovered.
    public var recoveredFrom: Int?

    public init(batch: FileBatch, state: FileJournal.State) {
        self.batch = batch.id
        kind = batch.kind
        title = batch.title
        self.state = state
        steps = batch.steps.count
        done = 0
        photos = 0
        notInIndex = batch.notInIndex
    }
}
