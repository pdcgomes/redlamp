import CryptoKit
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
        }
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
        try fileSystem.copyItem(at: source, to: staging)
        do {
            try verify(source, staging)
            try fileSystem.moveItem(at: staging, to: destination)
        } catch {
            try? fileSystem.removeItem(at: staging)
            throw error
        }
        try fileSystem.removeItem(at: source)
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

    /// Throws unless `copy` holds the same files as `source`, of the same sizes and SHA-256.
    func verify(_ source: URL, _ copy: URL) throws {
        guard try fingerprint(source) == fingerprint(copy) else {
            throw FileOperationError.failed(
                path: source.path, message: "the copy at \(copy.path) isn't the same as the original",
            )
        }
    }

    /// Each file's size and SHA-256 by its path inside `url`, "" for `url` itself.
    private func fingerprint(_ url: URL) throws -> [String: Data] {
        let entry = try fileSystem.attributes(of: url)
        guard entry.isDirectory else { return try ["": digest(url, size: entry.size)] }
        var found: [String: Data] = [:]
        var folders = [(url, "")]
        while let (folder, relative) = folders.popLast() {
            for child in try fileSystem.contentsOfDirectory(at: folder) {
                let path = relative.isEmpty ? child.name : relative + "/" + child.name
                let url = folder.appending(path: child.name)
                if child.isDirectory {
                    folders.append((url, path))
                    found[path + "/"] = Data()
                } else {
                    found[path] = try digest(url, size: child.size)
                }
            }
        }
        return found
    }

    private func digest(_ url: URL, size _: Int64) throws -> Data {
        var hash = SHA256()
        let chunk = 4 << 20
        var offset = 0
        while true {
            let data = try fileSystem.read(url, range: offset ..< offset + chunk)
            hash.update(data: data)
            offset += data.count
            if data.count < chunk {
                break
            }
        }
        var size = Int64(offset).littleEndian
        hash.update(data: Data(bytes: &size, count: 8))
        return Data(hash.finalize())
    }

    /// Removes the folder if nothing is in it but what Finder keeps there; whether it's gone.
    private func removeIfEmpty(_ folder: URL) -> Bool {
        guard let entries = try? fileSystem.contentsOfDirectory(at: folder) else { return true }
        guard entries.isEmpty else { return false }
        return (try? fileSystem.removeItem(at: folder)) != nil
    }

    // MARK: - Original names

    /// Records each photo's name before the batch as its original name, unless it has one; or takes
    /// it out of the sidecar if it's the name the photo goes back to. The sidecars are written a few
    /// at a time, each on its own.
    private func changeOriginalNames(of photos: [PhotoMove], recording: Bool) {
        let tally = Mutex((recorded: 0, skipped: [String]()))
        let store = store
        let width = min(Self.sidecarWriters, photos.count)
        DispatchQueue.concurrentPerform(iterations: width) { worker in
            for photo in stride(from: worker, to: photos.count, by: width).map({ photos[$0] }) {
                let original = (photo.from as NSString).lastPathComponent
                let result = Self.changeOriginalName(of: photo, in: store) { name in
                    guard recording ? name == nil : name == original else { return false }
                    name = recording ? original : nil
                    return true
                }
                tally.withLock { tally in
                    switch result {
                    case .changed where recording: tally.recorded += 1
                    case .skipped: tally.skipped.append(photo.to)
                    case .changed, .unchanged: break
                    }
                }
            }
        }
        let (recorded, skipped) = tally.withLock { ($0.recorded, $0.skipped) }
        outcome.originalNamesRecorded += recorded
        outcome.originalNamesSkipped += skipped.sorted()
    }

    private enum NameChange {
        case changed, unchanged, skipped
    }

    /// Sidecars written at once: enough to wait on several, few enough for a spinning disk.
    static let sidecarWriters = 8

    /// Removes what the batch's sidecar writes left when a forced quit cut them short: hidden copies
    /// of the sidecars it wrote, named as `SidecarStore` names one while it builds or removes it,
    /// `.IMG_1234.ARW.redlamp.<UUID>`, beside the photos and on this Mac.
    func removeInterruptedSaves(locator: SidecarLocator) {
        var names: [String: Set<String>] = [:]
        for step in batch.steps where Self.writesNames(step) {
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

    /// Changes the original name in the photo's sidecar, making one if there's none and removing it
    /// if nothing else is left in it; a sidecar this build can't write is left as it is.
    private static func changeOriginalName(
        of photo: PhotoMove, in store: SidecarStore, _ change: (inout String?) -> Bool,
    ) -> NameChange {
        let image = URL(fileURLWithPath: photo.to)
        var sidecar = store.load(for: image) ?? Sidecar(recipe: EditRecipe())
        var metadata = sidecar.metadata ?? PhotoMetadata()
        guard change(&metadata.originalName) else { return .unchanged }
        sidecar.metadata = metadata.isEmpty ? nil : metadata
        sidecar.modified = Date()
        do {
            try store.saveOrRemove(sidecar, for: image)
            return .changed
        } catch {
            return .skipped
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
                   Self.matches(source, item) {
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
            default:
                return state(of: item)
            }
        }
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
            let moves = span.filter { !Self.writesNames(steps[$0]) }
            if moves.count > 1, let last = moves.last, progress(of: last).isDone {
                names += span.filter { Self.writesNames(steps[$0]) }
                index = end + 1
                continue
            }
            for step in span {
                if Self.writesNames(steps[step]) {
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

    static func writesNames(_ step: FileStep) -> Bool {
        step.kind == .recordOriginalNames || step.kind == .clearOriginalNames
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
        case .recordOriginalNames, .clearOriginalNames:
            return ([], false, true)
        case .move, .putBack, .trash:
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
        let atSource = (try? fileSystem.attributes(of: from)).map { Self.matches($0, item) } ?? false
        let atDestination = (try? fileSystem.attributes(of: to)).map { Self.matches($0, item) } ?? false
        switch (atSource, atDestination) {
        case (true, false): return .atSource
        case (false, true): return .atDestination
        case (true, true): return item.copies ? .both : .atSource
        case (false, false): return .neither
        }
    }

    /// Whether `entry` is the file `item` was when the batch was planned: the same file on its
    /// volume, or, copied to another or on a volume without file identifiers, of the same size and
    /// date.
    static func matches(_ entry: FileEntry, _ item: FileItem) -> Bool {
        if let recorded = item.fileID, let found = entry.fileIdentifier {
            if recorded == found {
                return true
            }
            if !item.copies {
                return false
            }
        }
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
