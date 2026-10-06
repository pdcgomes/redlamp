import Foundation
import RedlampDocument

public extension FileOperations {
    /// Undoes the batch `id`, or the newest that can be undone, by running a batch of its own: the
    /// photos taken from where they are now back where they were, with whatever sidecars they have by
    /// then; the folders it made removed and those it removed made again; what it moved to the
    /// Trash put back, while it's still there; and the original names it recorded taken out. What
    /// isn't where the batch left it any more is left out (`FileOutcome.gone`).
    @discardableResult
    func undo(_ id: UUID? = nil, progress: (@Sendable (FileProgress) -> Void)? = nil) async throws -> FileOutcome {
        let target: UUID
        if let id {
            target = id
        } else if let last = try await lastUndoable() {
            target = last.id
        } else {
            throw FileOperationError.nothingToUndo
        }
        return try await run(planUndo(target), progress: progress)
    }

    /// The batch that undoes `id`, planned from where its photos are now.
    func planUndo(_ id: UUID) async throws -> FileBatch {
        let journal = journal
        let (batch, logged) = try await LibraryIndex.offCaller { try journal.load(id) }
        guard batch.kind != .undo, logged.state == .finished || logged.state == .stopped else {
            throw FileOperationError.nothingToUndo
        }
        let done = batch.steps.indices.filter { logged.done.contains($0) }.map { ($0, batch.steps[$0]) }
        var first: [Int64: String] = [:]
        var last: [Int64: String] = [:]
        var order: [Int64] = []
        var clearing: [FileStep] = []
        var making: [FileStep] = []
        var folders: [FileStep] = []
        var files: [FileStep] = []
        var removing: [FileStep] = []
        var puttingBack: [FileStep] = []
        for (index, step) in done {
            switch step.kind {
            case .move:
                if !step.folders.isEmpty || step.items.contains(where: { $0.role == .folder }) {
                    folders.insert(step.inverse(trashed: []), at: 0)
                    continue
                }
                if step.photos.isEmpty {
                    files.insert(step.inverse(trashed: []), at: 0)
                    continue
                }
                for photo in step.photos {
                    if first[photo.id] == nil {
                        first[photo.id] = photo.from
                        order.append(photo.id)
                    }
                    last[photo.id] = photo.to
                }
            case .createFolder:
                removing.insert(step.inverse(trashed: []), at: 0)
            case .removeFolder:
                making.insert(step.inverse(trashed: []), at: 0)
            case .trash:
                let places = Self.places(logged.trashed[index], count: step.items.count)
                puttingBack.insert(step.inverse(trashed: places), at: 0)
            case .recordOriginalNames:
                clearing.insert(step.inverse(trashed: []), at: 0)
            case .clearOriginalNames, .putBack:
                break
            }
        }
        let moves = order.compactMap { id -> PhotoMove? in
            guard let from = last[id], let to = first[id], from != to else { return nil }
            return PhotoMove(id: id, from: from, to: to)
        }
        let locator = try await locator()
        let fileSystem = fileSystem
        let (planned, gone) = try await LibraryIndex.offCaller { [
            clearing,
            making,
            folders,
            files,
            removing,
            puttingBack,
        ] in
            let planner = FilePlanner(fileSystem: fileSystem, locator: locator)
            var gone: [String] = []
            let present = moves.filter { move in
                guard planner.entry(move.from) != nil else {
                    gone.append(move.from)
                    return false
                }
                return true
            }
            let back = puttingBack.compactMap { step -> FileStep? in
                var step = step
                step.items = step.items.filter { item in
                    guard planner.entry(item.source) != nil else {
                        gone.append(item.destination ?? item.source)
                        return false
                    }
                    return true
                }
                return step.items.contains(where: \.isRequired) ? step : nil
            }
            let moved = planner.moveSteps(present)
            return (clearing + making + folders + moved + files + removing + back, gone)
        }
        guard !planned.isEmpty else {
            // Nothing it did is where it left it: the batch stays as it is, for when it is.
            if gone.isEmpty {
                throw FileOperationError.nothingToUndo
            }
            throw FileOperationError.conflicts(gone.map { FileConflict(path: $0, reason: .gone) })
        }
        var undo = FileBatch(kind: .undo, title: "Undo " + batch.title, steps: planned, undoes: id)
        undo.gone = gone
        return undo
    }
}
