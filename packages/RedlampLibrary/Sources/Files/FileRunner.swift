import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

/// Runs a batch's steps on the file system, one at a time, logging each as it's done; and, for
/// recovery, says how far a step had got from where its files are. A step that fails partway puts
/// back what it had moved before it throws, so a batch is always between two steps when it stops.
///
/// It blocks on the file system: use it off the caller (`LibraryIndex.offCaller`).
final class FileRunner: @unchecked Sendable {
    let batch: FileBatch
    let log: FileJournal.Log
    let fileSystem: any LibraryFileSystem
    let store: SidecarStore
    let interruption: FileOperations.Interruption?
    /// Where items went in the Trash, by step and item.
    private(set) var trashed: [Int: [Int: String]]
    private(set) var outcome: FileOutcome
    /// The steps done in this run, in order.
    private(set) var performed: [Int] = []

    init(
        batch: FileBatch, log: FileJournal.Log, fileSystem: any LibraryFileSystem, store: SidecarStore,
        trashed: [Int: [Int: String]] = [:], outcome: FileOutcome, interruption: FileOperations.Interruption?,
    ) {
        self.batch = batch
        self.log = log
        self.fileSystem = fileSystem
        self.store = store
        self.trashed = trashed
        self.outcome = outcome
        self.interruption = interruption
    }

    // MARK: - Steps

    /// Does step `index`, from the start or from where `states` says its items are, and logs it.
    func perform(_ index: Int, from states: [ItemState]? = nil) throws {
        let step = batch.steps[index]
        switch step.kind {
        case .move, .putBack:
            try moveItems(of: step, index, from: states)
        case .trash:
            try trashItems(of: step, index, from: states)
        case .createFolder:
            if let folder = step.folder {
                do {
                    try fileSystem.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: false)
                } catch let error as POSIXError where error.code == .EEXIST {
                    guard (try? fileSystem.attributes(of: URL(fileURLWithPath: folder)))?.isDirectory == true
                    else { throw error }
                }
            }
        case .removeFolder:
            if let folder = step.folder, !removeIfEmpty(URL(fileURLWithPath: folder)) {
                outcome.foldersLeft.append(folder)
            }
        case .recordOriginalNames:
            changeOriginalNames(of: step.photos, recording: true)
        case .clearOriginalNames:
            changeOriginalNames(of: step.photos, recording: false)
        case .copy:
            try copyItems(of: step, index, from: states)
        case .detachCopies:
            detachCopies(step.photos)
        }
        try logDone(index)
    }

    /// Does sidecar step `index` (`writesSidecars`) for `photos` alone, those of its photos the steps before it have
    /// put where it finds them, and logs it: what a batch stopping between a sidecar step's photos does for those
    /// done, so it can stop after the photo in hand.
    func perform(_ index: Int, photos: [PhotoMove]) throws {
        switch batch.steps[index].kind {
        case .recordOriginalNames: changeOriginalNames(of: photos, recording: true)
        case .clearOriginalNames: changeOriginalNames(of: photos, recording: false)
        case .detachCopies: detachCopies(photos)
        case .move, .createFolder, .removeFolder, .trash, .putBack, .copy: return try perform(index)
        }
        try logDone(index)
    }

    private func logDone(_ index: Int) throws {
        if interruption == .beforeLogging(index) {
            throw FileOperations.ForcedQuit()
        }
        try log.done(index)
        performed.append(index)
        if interruption == .afterStep(index) {
            throw FileOperations.ForcedQuit()
        }
    }

    /// Logs step `index`, which its files say a forced quit left done.
    func markDone(_ index: Int) throws {
        try log.done(index)
        performed.append(index)
    }

    /// Puts back what step `index` did, its items as `states` says they are, and logs it. Folders it
    /// made are removed if nothing was put in them.
    func reverse(_ index: Int, from states: [ItemState]) throws {
        let step = batch.steps[index]
        switch step.kind {
        case .move, .putBack:
            for (item, state) in zip(step.items, states).reversed() {
                guard let destination = item.destination else { continue }
                try reverseMove(item, destination: destination, state: state)
            }
        case .trash:
            for (number, (item, state)) in zip(step.items, states).enumerated().reversed()
                where state == .atDestination {
                guard let place = trashed[index]?[number] else { continue }
                try putBack(item, from: place)
            }
        case .createFolder:
            if let folder = step.folder, !removeIfEmpty(URL(fileURLWithPath: folder)) {
                outcome.foldersLeft.append(folder)
            }
        case .removeFolder:
            if let folder = step.folder {
                try fileSystem.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
            }
        case .recordOriginalNames:
            changeOriginalNames(of: step.photos, recording: false)
        case .clearOriginalNames:
            changeOriginalNames(of: step.photos, recording: true)
        case .copy:
            for (item, state) in zip(step.items, states).reversed() {
                guard let destination = item.destination else { continue }
                try removeCopy(item, at: destination, state: state)
            }
        case .detachCopies:
            // The copies go next, the steps before it being reversed after it: with their sidecars, made here
            // for those that had none.
            for copy in step.photos {
                let url = URL(fileURLWithPath: copy.to)
                for sidecar in [SidecarLocator.besidePhoto(url), store.locator.onThisMac(url)].compactMap(\.self)
                    where fileSystem.exists(sidecar) {
                    try fileSystem.removeItem(at: sidecar)
                }
            }
        }
        try log.undone(index)
    }

    private func moveItems(of step: FileStep, _ index: Int, from states: [ItemState]?) throws {
        var moved: [(FileItem, String)] = []
        for (number, item) in step.items.enumerated() {
            guard let destination = item.destination else { continue }
            let state = states?[number] ?? .atSource
            do {
                switch state {
                case .atSource:
                    try move(item, from: item.source, to: destination, makingFolder: step.kind == .putBack)
                    moved.append((item, destination))
                case .both:
                    try finishCopy(item, destination: destination)
                case .atDestination, .neither:
                    break
                }
            } catch let error as POSIXError where error.code == .ENOENT && !item.isRequired {
                // A sidecar removed since the batch was checked: there's nothing to take along.
            } catch {
                if error is FileOperations.ForcedQuit {
                    throw error
                }
                try rewind(moved, after: error, at: item.source)
            }
            if case let .withinStep(stepNumber, items) = interruption, stepNumber == index, moved.count == items {
                throw FileOperations.ForcedQuit()
            }
        }
    }

    private func trashItems(of step: FileStep, _ index: Int, from states: [ItemState]?) throws {
        var trashedHere: [(FileItem, String)] = []
        for (number, item) in step.items.enumerated() {
            guard (states?[number] ?? .atSource) == .atSource else { continue }
            do {
                let place = try fileSystem.trashItem(at: URL(fileURLWithPath: item.source))
                trashed[index, default: [:]][number] = place.path
                try log.trashed(index, item: number, at: place)
                trashedHere.append((item, place.path))
            } catch {
                for (item, place) in trashedHere.reversed() {
                    do {
                        try putBack(item, from: place)
                    } catch {
                        throw FileOperationError.stuck(batch.id, path: place, message: Self.message(error))
                    }
                }
                throw FileOperationError.failed(path: item.source, message: Self.message(error))
            }
            if case let .withinStep(stepNumber, items) = interruption, stepNumber == index, trashedHere.count == items {
                throw FileOperations.ForcedQuit()
            }
        }
    }

    /// Copies each of the step's items still to copy; when one fails, removes the copies it had made, then throws.
    private func copyItems(of step: FileStep, _ index: Int, from states: [ItemState]?) throws {
        var made: [(FileItem, String)] = []
        for (number, item) in step.items.enumerated() {
            guard let destination = item.destination, (states?[number] ?? .atSource) == .atSource else { continue }
            do {
                try copy(item, to: destination)
                made.append((item, destination))
            } catch let error as POSIXError where error.code == .ENOENT && !item.isRequired {
                // A sidecar removed since the batch was checked: there's nothing to take along.
            } catch {
                if error is FileOperations.ForcedQuit {
                    throw error
                }
                for (item, destination) in made.reversed() {
                    do {
                        try removeCopy(item, at: destination, state: .atDestination)
                    } catch {
                        throw FileOperationError.stuck(batch.id, path: destination, message: Self.message(error))
                    }
                }
                if let error = error as? FileOperationError {
                    throw error
                }
                throw FileOperationError.failed(path: item.source, message: Self.message(error))
            }
            if case let .withinStep(stepNumber, items) = interruption, stepNumber == index, made.count == items {
                throw FileOperations.ForcedQuit()
            }
        }
    }

    /// Moves the items a failed step had moved back where they were, then throws the failure; or,
    /// when one can't be moved back, says the batch is stuck.
    private func rewind(_ moved: [(FileItem, String)], after error: any Error, at path: String) throws -> Never {
        for (item, destination) in moved.reversed() {
            do {
                try reverseMove(item, destination: destination, state: .atDestination)
            } catch {
                throw FileOperationError.stuck(batch.id, path: destination, message: Self.message(error))
            }
        }
        if let error = error as? FileOperationError {
            throw error
        }
        throw FileOperationError.failed(path: path, message: Self.message(error))
    }

    private func reverseMove(_ item: FileItem, destination: String, state: ItemState) throws {
        switch state {
        case .atDestination:
            try move(item, from: destination, to: item.source)
        case .both:
            let copy = URL(fileURLWithPath: destination)
            try verify(URL(fileURLWithPath: item.source), copy)
            try fileSystem.removeItem(at: copy)
        case .atSource, .neither:
            break
        }
    }
}

extension FileRunner {
    private func putBack(_ item: FileItem, from place: String) throws {
        let original = URL(fileURLWithPath: item.source)
        try? fileSystem.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try fileSystem.moveItem(at: URL(fileURLWithPath: place), to: original)
    }

    // MARK: - Files

    /// Renames on the volume, or copies, checks and only then removes the source across volumes.
    /// `.redlamp` sidecars move under file coordination, as `SidecarStore` reads and writes them.
    /// Sidecars kept on this Mac, and what's put back from the Trash, get the folders they go in.
    func move(_ item: FileItem, from source: String, to destination: String, makingFolder: Bool = false) throws {
        let (from, to) = (URL(fileURLWithPath: source), URL(fileURLWithPath: destination))
        if item.role == .sidecarOnThisMac || makingFolder {
            try fileSystem.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if item.copies {
            return try copyAcross(from, to: to)
        }
        guard item.role == .sidecar || item.role == .sidecarOnThisMac else {
            return try fileSystem.moveItem(at: from, to: to)
        }
        var result: Result<Void, any Error> = .success(())
        var coordination: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &coordination,
        ) { from, to in
            result = Result {
                try fileSystem.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let coordination {
            throw coordination
        }
        try result.get()
    }

    /// Copies `source` beside `destination` under a hidden name, checks every byte, puts the copy in
    /// place without replacing anything, and only then removes `source`.
    private func copyAcross(_ source: URL, to destination: URL) throws {
        let staging = Self.staging(for: destination)
        try? fileSystem.removeItem(at: staging)
        do {
            try copyChecked(source, to: staging)
            try fileSystem.moveItem(at: staging, to: destination)
        } catch {
            try? fileSystem.removeItem(at: staging)
            throw error
        }
        try fileSystem.removeItem(at: source)
    }

    /// Copies `item` beside `destination` under a hidden name and puts the copy in place without replacing anything;
    /// the original stays. On its volume the copy is a clone, which shares the original's blocks and is made whole
    /// or not at all; on another volume each byte is checked. A `.redlamp` sidecar is read under file coordination,
    /// as `SidecarStore` writes it, and one kept on this Mac gets the folders it goes in.
    private func copy(_ item: FileItem, to destination: String) throws {
        let (from, to) = (URL(fileURLWithPath: item.source), URL(fileURLWithPath: destination))
        if item.role == .sidecarOnThisMac {
            try fileSystem.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let staging = Self.staging(for: to)
        try? fileSystem.removeItem(at: staging)
        let place = { [fileSystem] (source: URL) throws in
            do {
                if try !self.clone(source, to: staging) {
                    try self.copyChecked(source, to: staging)
                }
                try fileSystem.moveItem(at: staging, to: to)
            } catch {
                try? fileSystem.removeItem(at: staging)
                throw error
            }
        }
        guard item.role == .sidecar || item.role == .sidecarOnThisMac else { return try place(from) }
        var result: Result<Void, any Error> = .success(())
        var coordination: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: from, options: [], error: &coordination) { from in
                result = Result { try place(from) }
            }
        if let coordination {
            throw coordination
        }
        try result.get()
    }

    /// Removes the copy a step made of `item` at `destination` when `state` finds it there (`copyState`), and what a
    /// copy cut short left beside it.
    private func removeCopy(_: FileItem, at destination: String, state: ItemState) throws {
        let copy = URL(fileURLWithPath: destination)
        try? fileSystem.removeItem(at: Self.staging(for: copy))
        guard state == .atDestination else { return }
        try fileSystem.removeItem(at: copy)
    }

    /// Makes each copy's sidecar its own, as one batch (`SidecarStore.change`): out of the collections and the
    /// stack its original is in, and, for a copy given another name, with its original's name as its original
    /// name unless it has one, made for that where it has none. A sidecar this build can't write is left as it
    /// is.
    private func detachCopies(_ copies: [PhotoMove]) {
        let failed = Mutex([String]())
        store.change(copies.map { URL(fileURLWithPath: $0.to) }) { number, sidecar in
            let (from, to) = (FilePlanner.split(copies[number].from).name, FilePlanner.split(copies[number].to).name)
            let renamed = NamingJob.fold(from) != NamingJob.fold(to)
            guard var sidecar = sidecar ?? (renamed ? Sidecar(recipe: EditRecipe()) : nil) else { return .keep }
            var metadata = sidecar.metadata ?? PhotoMetadata()
            var changed = false
            if !metadata.collections.isEmpty {
                metadata.collections = []
                changed = true
            }
            if metadata.stack != nil {
                metadata.stack = nil
                changed = true
            }
            if renamed, metadata.originalName == nil {
                metadata.originalName = from
                changed = true
            }
            guard changed else { return .keep }
            sidecar.metadata = metadata.isEmpty ? nil : metadata
            sidecar.modified = Date()
            return .saveOrRemove(sidecar)
        } done: { result in
            if case .failed = result.outcome {
                failed.withLock { $0.append(copies[result.index].to) }
            }
        }
        outcome.copiesNotDetached += failed.withLock { $0 }.sorted()
    }

    /// A copy a forced quit left in place with its source: checked again, then the source removed.
    private func finishCopy(_ item: FileItem, destination: String) throws {
        let source = URL(fileURLWithPath: item.source)
        try verify(source, URL(fileURLWithPath: destination))
        try fileSystem.removeItem(at: source)
    }

    /// Where a copy is made before it's checked.
    static func staging(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).redlamp-copy")
    }

    /// Clones `source` to `copy` on its volume (`LibraryFileSystem.cloneItem`): false, with nothing made, when
    /// `copy` is on another volume or the volume can't clone.
    private func clone(_ source: URL, to copy: URL) throws -> Bool {
        do {
            try fileSystem.cloneItem(at: source, to: copy)
            return true
        } catch let error as POSIXError where error.code == .EXDEV || error.code == .ENOTSUP {
            return false
        }
    }

    /// Copies `source` to `copy`, where nothing is, and checks every byte: a file is read once, hashed as it's
    /// copied, and the copy read back; a folder's files are each read on both sides.
    private func copyChecked(_ source: URL, to copy: URL) throws {
        guard try !fileSystem.attributes(of: source).isDirectory else {
            try fileSystem.copyItem(at: source, to: copy)
            return try verify(source, copy)
        }
        let read = try fileSystem.copyFile(at: source, to: copy)
        guard try FileDigest(of: copy, in: fileSystem) == read else {
            throw FileOperationError.failed(
                path: source.path, message: "the copy at \(copy.path) isn't the same as the original",
            )
        }
    }

    /// Throws unless `copy` holds the same files as `source`, of the same sizes and SHA-256.
    func verify(_ source: URL, _ copy: URL) throws {
        guard try fingerprint(source) == fingerprint(copy) else {
            throw FileOperationError.failed(
                path: source.path, message: "the copy at \(copy.path) isn't the same as the original",
            )
        }
    }

    /// Each file's size and SHA-256 by its path inside `url`, "" for `url` itself; each folder's path ends in a
    /// slash.
    private func fingerprint(_ url: URL) throws -> [String: FileDigest] {
        let entry = try fileSystem.attributes(of: url)
        guard entry.isDirectory else { return try ["": FileDigest(of: url, in: fileSystem)] }
        var found: [String: FileDigest] = [:]
        var folders = [(url, "")]
        while let (folder, relative) = folders.popLast() {
            for child in try fileSystem.contentsOfDirectory(at: folder) {
                let path = relative.isEmpty ? child.name : relative + "/" + child.name
                let url = folder.appending(path: child.name)
                if child.isDirectory {
                    folders.append((url, path))
                    found[path + "/"] = FileDigest(sha256: Data(), size: 0)
                } else {
                    found[path] = try FileDigest(of: url, in: fileSystem)
                }
            }
        }
        return found
    }

    /// Removes the folder if nothing is in it but what Finder keeps there; whether it's gone.
    private func removeIfEmpty(_ folder: URL) -> Bool {
        guard let entries = try? fileSystem.contentsOfDirectory(at: folder) else { return true }
        guard entries.isEmpty else { return false }
        return (try? fileSystem.removeItem(at: folder)) != nil
    }

    // MARK: - Original names

    /// Records each photo's name before the batch as its original name, unless it has one; or takes
    /// it out of the sidecar if it's the name the photo goes back to. The sidecars are written as one
    /// batch (`SidecarStore.change`), making one where there's none and removing one with nothing
    /// else left in it; a sidecar this build can't write is left as it is.
    private func changeOriginalNames(of photos: [PhotoMove], recording: Bool) {
        let clock = ContinuousClock()
        let started = clock.now
        let tally = Mutex((recorded: 0, skipped: [String]()))
        store.change(photos.map { URL(fileURLWithPath: $0.to) }) { number, sidecar in
            let original = (photos[number].from as NSString).lastPathComponent
            var sidecar = sidecar ?? Sidecar(recipe: EditRecipe())
            var metadata = sidecar.metadata ?? PhotoMetadata()
            guard recording ? metadata.originalName == nil : metadata.originalName == original else { return .keep }
            metadata.originalName = recording ? original : nil
            sidecar.metadata = metadata.isEmpty ? nil : metadata
            sidecar.modified = Date()
            return .saveOrRemove(sidecar)
        } done: { result in
            tally.withLock { tally in
                switch result.outcome {
                case .saved where recording: tally.recorded += 1
                case .failed: tally.skipped.append(photos[result.index].to)
                case .saved, .kept: break
                }
            }
        }
        let (recorded, skipped) = tally.withLock { ($0.recorded, $0.skipped) }
        outcome.originalNamesRecorded += recorded
        outcome.originalNamesSkipped += skipped.sorted()
        outcome.originalNamesTime += clock.now - started
    }

    /// Removes what the batch's sidecar writes left when a forced quit cut them short: hidden copies
    /// of the sidecars it wrote, named as `SidecarStore` names one while it builds, writes or removes
    /// it, `.IMG_1234.ARW.redlamp.<UUID>`, beside the photos and on this Mac.
    func removeInterruptedSaves(locator: SidecarLocator) {
        var names: [String: Set<String>] = [:]
        for step in batch.steps where Self.writesSidecars(step) {
            for photo in step.photos {
                for path in [photo.from, photo.to] {
                    let (folder, name) = FilePlanner.split(path)
                    names[folder, default: []].insert(name)
                    if let mac = locator.onThisMac(URL(fileURLWithPath: path)) {
                        names[mac.deletingLastPathComponent().path, default: []].insert(name)
                    }
                }
            }
        }
        for (folder, photos) in names {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                where entry.hasPrefix(".") {
                let hidden = entry.dropFirst()
                guard let dot = hidden.lastIndex(of: "."),
                      UUID(uuidString: String(hidden[hidden.index(after: dot)...])) != nil,
                      hidden[..<dot].hasSuffix(".redlamp"),
                      photos.contains(String(hidden[..<dot].dropLast(".redlamp".count)))
                else { continue }
                try? FileManager.default.removeItem(atPath: folder + "/" + entry)
            }
        }
    }

    // MARK: - Where a step had got to

    /// Where an item is.
    enum ItemState: Sendable, Hashable {
        case atSource
        case atDestination
        /// Copied to its destination, the original not removed yet.
        case both
        /// Nowhere the batch would put it.
        case neither
    }

    /// Where each of step `index`'s items is.
    func states(of index: Int) -> [ItemState] {
        let step = batch.steps[index]
        return step.items.enumerated().map { number, item in
            switch step.kind {
            case .trash:
                if let source = try? fileSystem.attributes(of: URL(fileURLWithPath: item.source)),
                   Self.isSameFile(source, item) {
                    return .atSource
                }
                if trashed[index]?[number] != nil {
                    return .atDestination
                } else if let place = findInTrash(item) {
                    trashed[index, default: [:]][number] = place
                    try? log.trashed(index, item: number, at: URL(fileURLWithPath: place))
                    return .atDestination
                }
                return .neither
            case .copy:
                return copyState(of: item)
            default:
                return state(of: item)
            }
        }
    }

    /// Where a copy is: at its destination once it's there, a file with its original's size and date, which a copy
    /// keeps; still to make while its original is there; neither when the original has gone.
    private func copyState(of item: FileItem) -> ItemState {
        guard let destination = item.destination else { return .neither }
        if let copy = try? fileSystem.attributes(of: URL(fileURLWithPath: destination)) {
            // A sidecar may have been made its own since (`detachCopies`).
            let isSidecar = item.isDirectory || item.role == .sidecar || item.role == .sidecarOnThisMac
            let sameSize = item.size.map { $0 == copy.size } ?? true
            let sameDate = item.modified.map { abs(copy.modified.timeIntervalSince($0)) < 1e-3 } ?? true
            if isSidecar || sameSize && sameDate {
                return .atDestination
            }
        }
        return fileSystem.exists(URL(fileURLWithPath: item.source)) ? .atSource : .neither
    }

    /// The first step after `lastLogged` that a forced quit left undone, and how far it had got, from
    /// where the files are; and the steps that write original names before it, which can't be told
    /// done and are run again. A cycle of renames is looked at from its last step first, since its
    /// names go round.
    func frontier(after lastLogged: Int) -> (index: Int, partial: [ItemState]?, names: [Int]) {
        let steps = batch.steps
        var names: [Int] = []
        var index = lastLogged + 1
        while index < steps.count {
            var end = index
            while end < steps.count - 1, !steps[end].isSafe {
                end += 1
            }
            let span = Array(index ... end)
            let moves = span.filter { !Self.writesSidecars(steps[$0]) }
            if moves.count > 1, let last = moves.last, progress(of: last).isDone {
                names += span.filter { Self.writesSidecars(steps[$0]) }
                index = end + 1
                continue
            }
            for step in span {
                if Self.writesSidecars(steps[step]) {
                    names.append(step)
                    continue
                }
                let found = progress(of: step)
                if !found.isDone {
                    return (step, found.isUntouched ? nil : found.states, names.filter { $0 < step })
                }
            }
            index = end + 1
        }
        return (steps.count, nil, names)
    }

    /// Where a batch asked to stop before step `index`, after one that isn't safe, can stop now: the sidecar step
    /// that would make it safe (`writesSidecars`), for those of its photos the steps since the last safe one have
    /// put where it finds them. Nil while a cycle of renames has a photo under a temporary name, or when the next
    /// safe step doesn't write sidecars.
    func stop(before index: Int) -> (step: Int, photos: [PhotoMove])? {
        let steps = batch.steps
        guard index > 0, index < steps.count, !steps[index - 1].isSafe,
              let next = steps[index...].firstIndex(where: \.isSafe), Self.writesSidecars(steps[next])
        else { return nil }
        let start = (steps[..<index].lastIndex(where: \.isSafe) ?? -1) + 1
        var placed: [Int64: String] = [:]
        for step in steps[start ..< index] where step.kind == .move || step.kind == .copy {
            for photo in step.photos {
                placed[photo.id] = photo.to
            }
        }
        guard !placed.values.contains(where: { FilePlanner.split($0).name.hasPrefix(FilePlanner.temporaryPrefix) })
        else { return nil }
        return (next, steps[next].photos.filter { placed[$0.id] == $0.to })
    }

    /// The steps that write photos' sidecars rather than move files, which can't be told done.
    static func writesSidecars(_ step: FileStep) -> Bool {
        step.kind == .recordOriginalNames || step.kind == .clearOriginalNames || step.kind == .detachCopies
    }

    /// Whether step `index` is done, not started, or partway, from where its files are.
    func progress(of index: Int) -> (states: [ItemState], isDone: Bool, isUntouched: Bool) {
        let step = batch.steps[index]
        switch step.kind {
        case .createFolder:
            let made = step.folder.map { fileSystem.exists(URL(fileURLWithPath: $0)) } ?? true
            return ([], made, !made)
        case .removeFolder:
            let gone = step.folder.map { !fileSystem.exists(URL(fileURLWithPath: $0)) } ?? true
            return ([], gone, !gone)
        case .recordOriginalNames, .clearOriginalNames, .detachCopies:
            return ([], false, true)
        case .move, .putBack, .trash, .copy:
            let states = states(of: index)
            let isDone = states.allSatisfy { $0 == .atDestination || $0 == .neither }
                && states.contains(.atDestination)
            let isUntouched = states.allSatisfy { $0 == .atSource || $0 == .neither }
            return (states, isDone, isUntouched && !isDone)
        }
    }

    private func state(of item: FileItem) -> ItemState {
        guard let destination = item.destination else { return .neither }
        let (from, to) = (URL(fileURLWithPath: item.source), URL(fileURLWithPath: destination))
        if NamingJob.fold(item.source) == NamingJob.fold(destination) {
            let names = (try? fileSystem.contentsOfDirectory(at: to.deletingLastPathComponent()))?.map(\.name) ?? []
            if names.contains(to.lastPathComponent) {
                return .atDestination
            }
            return names.contains(from.lastPathComponent) ? .atSource : .neither
        }
        let atSource = (try? fileSystem.attributes(of: from)).map { Self.isSameFile($0, item) } ?? false
        let atDestination = (try? fileSystem.attributes(of: to)).map { Self.isSameFile($0, item) } ?? false
        switch (atSource, atDestination) {
        case (true, false): return .atSource
        case (false, true): return .atDestination
        case (true, true): return item.copies ? .both : .atSource
        case (false, false): return .neither
        }
    }

    /// Whether `entry` is the file `item` was when the batch was planned, as it was then: the same
    /// file, and of the size and modification date it had, not written in place since.
    static func matches(_ entry: FileEntry, _ item: FileItem) -> Bool {
        isSameFile(entry, item) && isUnchanged(entry, item)
    }

    /// Whether `entry` is the file `item` was when the batch was planned, though it may have been
    /// written since: the same file on its volume, or, copied to another or on a volume without file
    /// identifiers, of the same size and date.
    static func isSameFile(_ entry: FileEntry, _ item: FileItem) -> Bool {
        if let recorded = item.fileID, let found = entry.fileIdentifier {
            if recorded == found {
                return true
            }
            if !item.copies {
                return false
            }
        }
        return isUnchanged(entry, item)
    }

    /// Whether `entry` has the size and modification date `item` recorded; a folder's aren't kept.
    private static func isUnchanged(_ entry: FileEntry, _ item: FileItem) -> Bool {
        if item.isDirectory || entry.isDirectory {
            return item.isDirectory == entry.isDirectory
        }
        guard let size = item.size, let modified = item.modified else { return true }
        return entry.size == size && abs(entry.modified.timeIntervalSince(modified)) < 1e-3
    }

    /// Where an item went in the Trash when a forced quit came before it was logged: the entry there
    /// that's the same file.
    private func findInTrash(_ item: FileItem) -> String? {
        let source = URL(fileURLWithPath: item.source)
        guard let trash = try? fileSystem.trashDirectory(for: source),
              let entries = try? fileSystem.contentsOfDirectory(at: trash)
        else { return nil }
        let stem = NamingJob.fold(NamingJob.split(source.lastPathComponent).base)
        return entries.first { entry in
            NamingJob.fold(entry.name).hasPrefix(stem) && entry.fileIdentifier != nil
                && entry.fileIdentifier == item.fileID
        }.map { trash.appending(path: $0.name).path }
    }

    static func message(_ error: any Error) -> String {
        if case let .failed(_, message) = error as? FileOperationError {
            return message
        }
        if let error = error as? POSIXError {
            return String(cString: strerror(error.code.rawValue))
        }
        return (error as NSError).localizedDescription
    }
}
