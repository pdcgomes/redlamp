import Foundation

// What `redlamp library duplicates --trash` prints of a removal plan: every file its batch moves to
// the Trash, each copy with the files that go with it, before anything moves; then what became of it.

public extension DuplicateRemovalPlan {
    /// What became of the plan's batch.
    enum Outcome: Sendable, Hashable {
        /// Not run: it wasn't confirmed, or it was a dry run. `stopping` says what would stop it.
        case shown(dryRun: Bool, stopping: [String])
        /// Nothing moved, for these reasons.
        case stopped([String])
        /// It ran, in `seconds`.
        case moved(FileOutcome, seconds: Double)

        /// Something stopped it, or would have.
        public var isStopped: Bool {
            switch self {
            case let .shown(_, stopping): !stopping.isEmpty
            case .stopped: true
            case .moved: false
            }
        }
    }

    /// Every file `batch`, the plan's, moves to the Trash: each copy, with the files that go with it
    /// below it.
    func lines(_ batch: FileBatch) -> [String] {
        guard !batch.steps.isEmpty else { return ["No copies to move to the Trash"] }
        let files = batch.steps.reduce(0) { $0 + $1.items.count }
        var lines = ["\(batch.title), \(Self.count(files, "file")), \(DuplicateReview.bytes(bytes)):"]
        for step in batch.steps {
            for (index, item) in step.items.enumerated() {
                lines.append((index == 0 ? "  " : "    ") + item.source)
            }
        }
        return lines
    }

    /// What became of the batch.
    static func lines(_ outcome: Outcome) -> [String] {
        switch outcome {
        case let .shown(_, stopping) where !stopping.isEmpty:
            ["Nothing was moved, and it couldn't start, since:"] + stopping.map { "  " + $0 }
        case .shown(dryRun: true, _):
            ["Nothing was moved: a dry run."]
        case .shown:
            ["Nothing was moved: --confirm moves them to the Trash, and redlamp library undo puts them back."]
        case let .stopped(reasons):
            ["Nothing was moved, since:"] + reasons.map { "  " + $0 }
        case let .moved(outcome, seconds):
            [
                "\(outcome.title): \(outcome.state == .finished ? "done" : "stopped partway"), "
                    + "\(count(outcome.photos, "photo")) in " + String(format: "%.1f s", seconds)
                    + ". redlamp library undo puts them back.",
            ]
        }
    }

    /// The batch and what became of it, as the review's JSON has them (`DuplicateReview.json`).
    internal func json(_ batch: FileBatch, outcome: Outcome) -> DuplicateTrashJSON {
        var json = DuplicateTrashJSON(
            title: batch.title, photos: removals.count, bytes: bytes,
            files: batch.steps.flatMap { step in
                step.items.map { .init(photo: step.removed.first?.photo.id, path: $0.source, role: $0.role) }
            },
        )
        switch outcome {
        case let .shown(dryRun, stopping):
            json.dryRun = dryRun
            json.stopped = stopping
        case let .stopped(reasons):
            json.stopped = reasons
        case let .moved(outcome, seconds):
            json.moved = true
            json.batch = outcome.batch.uuidString
            json.state = outcome.state.rawValue
            json.seconds = seconds
        }
        return json
    }

    /// `1 file`, `3 files`.
    private static func count(_ value: Int, _ noun: String) -> String {
        "\(BenchResult.grouped(value)) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// A plan's batch in the review's JSON: every file it moves to the Trash, by photo, and what became
/// of it.
struct DuplicateTrashJSON: Encodable {
    struct File: Encodable {
        let photo: Int64?
        let path: String
        let role: FileItem.Role
    }

    let title: String
    let photos: Int
    let bytes: Int64
    let files: [File]
    var moved = false
    var dryRun = false
    /// Why it didn't start, or wouldn't.
    var stopped: [String] = []
    /// Once it ran: the batch, which Undo takes back, its state and how long it took.
    var batch: String?
    var state: String?
    var seconds: Double?
}
