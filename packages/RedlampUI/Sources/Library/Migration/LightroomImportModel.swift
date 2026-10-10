import AppKit
import RedlampLibrary
import Synchronization

/// What File › Import from Lightroom Classic… does (LIB-29): a catalog chosen and read off the main thread, its
/// report against the library as it is, its root folders located where they moved, and then the import: the root
/// folders the library doesn't have added to Folders and waited for while they're indexed, then the photos'
/// fields, keywords and collections as the library's batches, in parts with progress and Stop. Undo Import takes
/// the import back. One catalog at a time.
@MainActor
final class LightroomImportModel {
    enum Phase: Equatable {
        case choosing, reading, reported
        /// The root folders the library didn't have are being added and indexed.
        case adding
        case importing, stopping, imported, undoing, undone
    }

    private weak var editor: EditorModel?
    private(set) var phase = Phase.choosing
    private(set) var catalogURL: URL?
    private(set) var catalog: LightroomCatalog?
    private(set) var plan: LightroomPlan?
    /// Where the user said the catalog's moved root folders are, by the paths the catalog gives them.
    private(set) var moved: [String: URL] = [:]
    private(set) var progress: LightroomImport.Progress?
    /// While the folders are added: photos the index has in them, of those the catalog has there.
    private(set) var indexed: (done: Int, total: Int)?
    private(set) var outcome: LightroomImport.Outcome?
    /// What went wrong last, in words.
    private(set) var problem: String?
    /// The newest import not taken back, which Undo Import takes back.
    private(set) var lastImport: LightroomImportRecord?
    var onChange: (@MainActor () -> Void)?
    private let stopping = LightroomStop()
    private var work: Task<Void, Never>?

    init(editor: EditorModel) {
        self.editor = editor
        Task { await readLastImport() }
    }

    var report: LightroomReport? {
        plan?.report
    }

    private var core: LibraryCore? {
        editor?.library.service?.core
    }

    /// Whether a catalog is read, the import is running or taken back: the window's buttons wait.
    var isBusy: Bool {
        [.reading, .adding, .importing, .stopping, .undoing].contains(phase)
    }

    var canImport: Bool {
        guard let report, !isBusy, core != nil else { return false }
        return !report.isEmpty || plan?.foldersToAdd.isEmpty == false
    }

    var canUndo: Bool {
        !isBusy && lastImport != nil && core != nil
    }

    private func changed() {
        onChange?()
    }

    // MARK: - Reading

    /// Reads the catalog at `url` and works out what it would bring, nothing written.
    func choose(_ url: URL) {
        guard !isBusy else { return }
        catalogURL = url
        moved = [:]
        outcome = nil
        replan()
    }

    /// Looks for the root folder the catalog calls `path` at `url`, and works the report out again.
    func locate(_ path: String, at url: URL) {
        guard !isBusy else { return }
        moved[path] = url
        replan()
    }

    private func replan() {
        guard let url = catalogURL else { return }
        guard let core else {
            problem = "The library isn't open yet"
            changed()
            return
        }
        phase = .reading
        problem = nil
        changed()
        let moved = moved
        let known = catalog?.url == url ? catalog : nil
        work = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<
                (LightroomCatalog, LightroomPlan), any Error,
            > in
                do {
                    let catalog = try known ?? LightroomCatalog.read(url)
                    let plan = try await LightroomPlan.make(catalog, index: core.index, paths: core.paths, moved: moved)
                    return .success((catalog, plan))
                } catch {
                    return .failure(error)
                }
            }.value
            self?.read(result)
        }
    }

    private func read(_ result: Result<(LightroomCatalog, LightroomPlan), any Error>) {
        switch result {
        case let .success((catalog, plan)):
            self.catalog = catalog
            self.plan = plan
            phase = .reported
        case let .failure(error):
            catalog = nil
            plan = nil
            problem = String(describing: error)
            phase = .choosing
        }
        changed()
    }

    // MARK: - Importing

    /// Adds the root folders the library doesn't have to Folders and waits for them to be indexed, then
    /// imports.
    func startImport() {
        guard canImport, let editor, let core, let plan else { return }
        stopping.set(false)
        problem = nil
        outcome = nil
        let folders = plan.foldersToAdd
        editor.activity.record(.action, "Import from Lightroom Classic: “\(plan.name)”")
        work = Task { [weak self] in
            guard let self else { return }
            if !folders.isEmpty {
                phase = .adding
                changed()
                editor.library.add(folders)
                guard await waitForIndexing(folders), !isStopping else {
                    finish(stoppedBeforeImport: true)
                    return
                }
                await replanForImport()
            }
            guard let plan = self.plan else { return }
            phase = .importing
            progress = LightroomImport.Progress(done: 0, total: plan.photoCount, part: 0, parts: 1)
            changed()
            let importer = Self.importer(core)
            let shown = Mutex<ContinuousClock.Instant?>(nil)
            let result = await Task.detached(priority: .userInitiated) { [stopping] () -> Result<
                LightroomImport.Outcome, any Error,
            > in
                do {
                    return try await .success(importer.run(plan, progress: { progress in
                        let due = shown.withLock { last in
                            let now = ContinuousClock.now
                            guard progress.done == progress.total || last.map({ now - $0 > .milliseconds(100) })
                                ?? true
                            else { return false }
                            last = now
                            return true
                        }
                        if due {
                            Task { @MainActor [weak self] in self?.progressed(progress) }
                        }
                    }, stop: { stopping.isSet }))
                } catch {
                    return .failure(error)
                }
            }.value
            imported(result)
        }
    }

    /// The library's import, each of its batches in the library's turn for changes, the photos it changes
    /// followed by other apps' metadata.
    static func importer(_ core: LibraryCore) -> LightroomImport {
        LightroomImport(
            index: core.index, paths: core.paths, live: core.live,
            turn: { body in await core.change { await body() } },
            changed: { ids in core.changed(ids) },
        )
    }

    /// Stop: the import ends once the part it's writing is done; adding folders ends at once.
    func stop() {
        guard phase == .adding || phase == .importing else { return }
        stopping.set(true)
        phase = phase == .importing ? .stopping : phase
        changed()
    }

    private var isStopping: Bool {
        stopping.isSet
    }

    /// Whether every one of `folders` is indexed and current, which the library says once following them has
    /// run to its end; false when stopped first.
    private func waitForIndexing(_ folders: [URL]) async -> Bool {
        guard let service = editor?.library.service, let core else { return false }
        let total = plan?.report.waiting ?? 0
        while !isStopping {
            var ready = true
            for folder in folders where await !service.canShow(folder, includingSubfolders: true) {
                ready = false
                break
            }
            let paths = folders.map(\.path)
            let done = await (try? core.index.read { reader in
                try paths.reduce(0) { count, path in
                    guard let folder = try reader.folder(path: path) else { return count }
                    return try count + reader.photoIDs(inSubtreeOf: folder.id).count
                }
            }) ?? 0
            indexed = (min(done, total), total)
            changed()
            if ready {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// The plan again, the folders added now in the library and their photos in the index.
    private func replanForImport() async {
        guard let catalog, let core else { return }
        let moved = moved
        if let plan = try? await Task.detached(priority: .userInitiated, operation: {
            try await LightroomPlan.make(catalog, index: core.index, paths: core.paths, moved: moved)
        }).value {
            self.plan = plan
        }
        indexed = nil
    }

    private func progressed(_ progress: LightroomImport.Progress) {
        guard phase == .importing || phase == .stopping else { return }
        self.progress = progress
        changed()
    }

    private func imported(_ result: Result<LightroomImport.Outcome, any Error>) {
        switch result {
        case let .success(outcome):
            self.outcome = outcome
            editor?.activity.record(
                .action,
                "Imported \(outcome.record.photos) photos from Lightroom Classic"
                    + (outcome.record.stopped ? ", stopped before the end" : ""),
            )
            if !outcome.skipped.isEmpty {
                let why = Set(outcome.skipped.values).sorted().joined(separator: "; ")
                editor?.activity.record(
                    .error,
                    "Lightroom Classic's fields weren't saved to "
                        + "\(outcome.skipped.count) photos: \(why)",
                )
            }
        case let .failure(error):
            problem = "The import stopped: \(error)"
            editor?.activity.record(.error, problem ?? "")
        }
        finish(stoppedBeforeImport: false)
    }

    private func finish(stoppedBeforeImport: Bool) {
        phase = stoppedBeforeImport ? .reported : .imported
        progress = nil
        indexed = nil
        editor?.libraryPanels.refreshKeywords()
        editor?.libraryPanels.refresh()
        Task {
            await readLastImport()
            if !stoppedBeforeImport, catalogURL != nil {
                replan()
            }
        }
        changed()
    }

    // MARK: - Undo

    /// Takes back the newest import not taken back: every batch it made, each keeping what changed since.
    func undo() {
        guard canUndo, let core else { return }
        phase = .undoing
        problem = nil
        changed()
        let importer = Self.importer(core)
        work = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<
                LightroomImportRecord,
                any Error,
            > in
                do {
                    return try await .success(importer.undo())
                } catch {
                    return .failure(error)
                }
            }.value
            self?.undone(result)
        }
    }

    private func undone(_ result: Result<LightroomImportRecord, any Error>) {
        switch result {
        case let .success(record):
            editor?.activity.record(.action, "Undo the import from Lightroom Classic of \(record.photos) photos")
        case let .failure(error):
            problem = "The import wasn't all taken back: \(error)"
            editor?.activity.record(.error, problem ?? "")
        }
        phase = .undone
        outcome = nil
        editor?.libraryPanels.refreshKeywords()
        editor?.libraryPanels.refresh()
        Task {
            await readLastImport()
            if catalogURL != nil {
                replan()
            }
        }
        changed()
    }

    private func readLastImport() async {
        guard let core else { return }
        let importer = Self.importer(core)
        lastImport = await Task.detached { try? importer.lastImport() }.value
        changed()
    }

    // MARK: - Words

    /// What the window says under the report: how the import is going, or what it did.
    var status: String {
        if let problem {
            return problem
        }
        switch phase {
        case .choosing: return "Choose a Lightroom Classic catalog, or a copy of one: it's read, never changed."
        case .reading: return "Reading the catalog…"
        case .reported:
            guard let report else { return "" }
            if report.isEmpty, plan?.foldersToAdd.isEmpty != false {
                return "Nothing in the catalog would change the library."
            }
            let adding = plan?.foldersToAdd.count ?? 0
            return "Importing changes \(Self.count(report.changing, "photo")) in the library"
                + (adding > 0 ? ", adding \(Self.count(adding, "folder")) to Folders first" : "")
                + ". Lightroom’s value replaces the library’s where Lightroom has one."
        case .adding:
            guard let indexed else { return "Adding the catalog’s folders to Folders…" }
            return "Adding the catalog’s folders: \(Self.number(indexed.done)) of \(Self.number(indexed.total)) photos "
                + "indexed…"
        case .importing, .stopping:
            guard let progress else { return "Importing…" }
            return (phase == .stopping ? "Stopping after this part: " : "Importing: ")
                + "\(Self.number(progress.done)) of \(Self.number(progress.total)) photos"
                + (progress.parts > 1 ? ", part \(progress.part + 1) of \(progress.parts)" : "")
        case .imported:
            guard let outcome else { return "Imported." }
            return "Imported \(Self.count(outcome.record.photos, "photo"))"
                + (outcome.record.stopped ? ", stopped before the end" : "")
                +
                (outcome.skipped
                    .isEmpty ? "" : "; \(Self.count(outcome.skipped.count, "sidecar")) couldn’t be written")
                + ". Undo Import takes it back."
        case .undoing: return "Taking the import back…"
        case .undone: return "The import is taken back."
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(number(value)) \(noun)s"
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

/// Stop, asked for on the main thread and read by the import between its parts.
final class LightroomStop: Sendable {
    private let flag = Mutex(false)

    func set(_ value: Bool) {
        flag.withLock { $0 = value }
    }

    var isSet: Bool {
        flag.withLock { $0 }
    }
}
