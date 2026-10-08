import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// A change the Library's panels make (LIB-21, LIB-22), as one of the library's batches.
enum PanelChange: Sendable, Hashable {
    case keywords(KeywordChange)
    case metadata(MetadataChange)
    case captureTime(CaptureTimeChange)
    /// The Collections section's changes (LIB-23), batches of the metadata journal.
    case collections(CollectionChange)
    /// Stacks made, taken apart or given another top (LIB-28), batches of the metadata journal.
    case stacks(StackChange)

    var isKeywords: Bool {
        if case .keywords = self {
            return true
        }
        return false
    }

    var isStacks: Bool {
        if case .stacks = self {
            return true
        }
        return false
    }
}

/// What a batch the panels asked for made: its ID in the journal, for its Undo, or why it wasn't made.
struct PanelOutcome: Sendable {
    /// Nil when there was nothing to change, or it failed.
    var batch: UUID?
    var title = ""
    /// The photos whose sidecars it couldn't write, by path, and why.
    var reasons: [String: String] = [:]
    var error: String?
}

/// The zone a photo's camera was in (LIB-22), in seconds east of UTC: as the library shows it, and as its file
/// records it; nil where there's none.
struct PanelCaptureZone: Sendable, Equatable {
    var shown: Int?
    var file: Int?
}

/// The keyword list as the panels show it, read off the main thread.
struct PanelKeywords: Sendable {
    var list: KeywordList
    var completion: KeywordCompletion
    var sets: [KeywordSet]
    var active: KeywordSet
}

extension LibraryService {
    /// The library's keywords, its batches journaled with the culling and metadata batches' turn
    /// (`LibraryCore.change`), its lists told of each change.
    private nonisolated static func keywords(_ core: LibraryCore) -> LibraryKeywords {
        LibraryKeywords(index: core.index, paths: core.paths, live: core.live)
    }

    private nonisolated static func metadata(_ core: LibraryCore) -> LibraryMetadata {
        LibraryMetadata(index: core.index, paths: core.paths, live: core.live)
    }

    /// The library's stacks as its index has them now, which a stack's change is planned against.
    private nonisolated static func stacks(_ core: LibraryCore) async throws -> Stacks {
        if !core.engine.isLoaded {
            try await core.engine.load()
        }
        return try await StackFinder.find(in: core.index, store: core.engine.store ?? ColumnStore())
    }

    /// Makes `change` as one batch, off the main thread in the library's changes' turn, `progress` hearing how
    /// many sidecars are written of how many; its photos' lists hear of it as the index holds it. A keyword
    /// batch a forced quit left unfinished is finished first.
    func run(_ change: PanelChange, progress: @escaping @Sendable (Int, Int) -> Void) async -> PanelOutcome {
        guard let core else { return PanelOutcome(error: "the library isn't open") }
        return await core.change {
            let outcome = await Self.run(core, progress: progress) { keywords, metadata in
                switch change {
                case let .keywords(change): try await .keywords(keywords.plan(change))
                case let .metadata(change): try await .metadata(metadata.plan(change))
                case let .captureTime(change): try await .metadata(metadata.plan(change))
                case let .collections(change): try await .metadata(metadata.collections.plan(change))
                case let .stacks(change): try await .metadata(metadata.plan(change, in: Self.stacks(core)))
                }
            }
            Self.collectionsChanged(by: change, in: core)
            return outcome
        }
    }

    /// A collection made, renamed, moved or deleted, or a smart collection's query, reaches the open lists, as
    /// `LibraryCollections.apply` has it reach them: the definitions aren't in the index.
    private nonisolated static func collectionsChanged(by change: PanelChange, in core: LibraryCore) {
        if case .collections = change {
            core.live.namesChanged()
        }
    }

    /// Takes back `batch`, which made `change`, as a batch of its own.
    func undo(_ change: PanelChange, batch: UUID) async -> PanelOutcome {
        guard let core else { return PanelOutcome(error: "the library isn't open") }
        return await core.change {
            let outcome = await Self.run(core, progress: { _, _ in }) { keywords, metadata in
                if change.isKeywords {
                    return try await .keywords(keywords.planUndo(batch))
                }
                return try await .metadata(metadata.planUndo(batch))
            }
            Self.collectionsChanged(by: change, in: core)
            return outcome
        }
    }

    /// Makes `change` again after its Undo `undo` took it back: as the Undo of that Undo where the journal still
    /// has it, for fields; as the change made afresh otherwise, and always for keywords.
    func redo(_ change: PanelChange, undo: UUID?) async -> PanelOutcome {
        guard let core else { return PanelOutcome(error: "the library isn't open") }
        return await core.change {
            let outcome = await Self.run(core, progress: { _, _ in }) { keywords, metadata in
                switch change {
                case let .keywords(change): return try await .keywords(keywords.plan(change))
                case let .metadata(change):
                    if let undo, let plan = try? await metadata.planRedo(undo) {
                        return .metadata(plan)
                    }
                    return try await .metadata(metadata.plan(change))
                case let .captureTime(change):
                    if let undo, let plan = try? await metadata.planRedo(undo) {
                        return .metadata(plan)
                    }
                    return try await .metadata(metadata.plan(change))
                case let .collections(change):
                    if let undo, let plan = try? await metadata.planRedo(undo) {
                        return .metadata(plan)
                    }
                    return try await .metadata(metadata.collections.plan(change))
                case let .stacks(change):
                    if let undo, let plan = try? await metadata.planRedo(undo) {
                        return .metadata(plan)
                    }
                    return try await .metadata(metadata.plan(change, in: Self.stacks(core)))
                }
            }
            Self.collectionsChanged(by: change, in: core)
            return outcome
        }
    }

    private enum Plan: Sendable {
        case keywords(KeywordPlan)
        case metadata(MetadataPlan)
    }

    private nonisolated static func run(
        _ core: LibraryCore, progress: @escaping @Sendable (Int, Int) -> Void,
        plan: @Sendable (LibraryKeywords, LibraryMetadata) async throws -> Plan,
    ) async -> PanelOutcome {
        let keywords = keywords(core)
        let metadata = metadata(core)
        do {
            if try await !keywords.unfinishedEntries().isEmpty {
                try await keywords.recover()
            }
            switch try await plan(keywords, metadata) {
            case let .keywords(plan):
                guard !plan.isEmpty else { return PanelOutcome(title: plan.title) }
                let outcome = try await keywords.run(plan, progress: progress)
                core.changed(plan.photos.map(\.id))
                var reasons: [String: String] = [:]
                for path in outcome.skipped {
                    reasons[path] = "its sidecar can't be written here"
                }
                return PanelOutcome(batch: outcome.batch, title: outcome.title, reasons: reasons)
            case let .metadata(plan):
                guard !plan.isEmpty else { return PanelOutcome(title: plan.title) }
                let outcome = try await metadata.run(plan, progress: progress)
                core.changed(plan.photos.map(\.id))
                return PanelOutcome(batch: outcome.batch, title: outcome.title, reasons: outcome.reasons)
            }
        } catch {
            return PanelOutcome(error: String(describing: error))
        }
    }

    /// Keeps the keyword sets and the one ⌥1 to ⌥9 apply, off the main thread in the library's changes' turn.
    func setKeywordSets(_ sets: [KeywordSet]?, active: String?) async -> PanelOutcome {
        await run(.keywords(.sets(sets, active: active))) { _, _ in }
    }

    /// The keyword list with its counts, completion over it, and the keyword sets, once the changes asked for
    /// before are made; nil while the library isn't open.
    func panelKeywords() async -> PanelKeywords? {
        guard let core else { return nil }
        return await core.change {
            let keywords = Self.keywords(core)
            guard let list = try? await keywords.list(), let sets = try? await keywords.sets(),
                  let active = try? await keywords.activeSet()
            else { return nil }
            return PanelKeywords(list: list, completion: KeywordCompletion(list), sets: sets, active: active)
        }
    }

    // MARK: - Keyword files

    /// Writes the keyword list to `url` as Lightroom Classic's keyword-list file: how many keywords it holds,
    /// and those Lightroom can't take in.
    func exportKeywords(to url: URL) async -> Result<LightroomKeywordFile.Export, any Error> {
        guard let core else { return .failure(KeywordError.unreadableDefinitions) }
        return await core.change {
            do {
                let list = try await Self.keywords(core).list()
                let export = LightroomKeywordFile.write(list.ordered.map(LightroomKeywordFile.Keyword.init))
                try Data(export.text.utf8).write(to: url, options: .atomic)
                return .success(export)
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: - Metadata presets

    func metadataPresets() async -> [MetadataPreset] {
        guard let core else { return [] }
        return await (try? Self.metadata(core).presets().presets) ?? []
    }

    /// Keeps `preset` in place of the one named `replacing` (or its own name); false when it couldn't be kept.
    func save(_ preset: MetadataPreset, replacing name: String? = nil) async -> Bool {
        guard let core else { return false }
        let metadata = Self.metadata(core)
        do {
            if let name, name != preset.name {
                try await metadata.removePreset(named: name)
            }
            try await metadata.save(preset)
            return true
        } catch {
            return false
        }
    }

    func removePreset(named name: String) async -> Bool {
        guard let core else { return false }
        return await (try? Self.metadata(core).removePreset(named: name)) != nil
    }

    // MARK: - Code replacements

    /// The library's code replacements file as it's written; empty when there's none or the library isn't open.
    func codeReplacementsText() async -> String {
        guard let core else { return "" }
        return await (try? Self.metadata(core).codeReplacementsText()) ?? ""
    }

    /// Keeps `text` as the library's code replacements file; false when it couldn't be kept.
    func saveCodeReplacements(_ text: String) async -> Bool {
        guard let core else { return false }
        return await (try? Self.metadata(core).saveCodeReplacements(text)) != nil
    }

    // MARK: - Capture times

    /// The zone photo `id`'s camera was in, as the index shows it and as its file records it; nil when the index
    /// doesn't have it.
    func captureZone(ofPhoto id: Int64) async -> PanelCaptureZone? {
        guard let core else { return nil }
        let row = try? await core.index.read { try $0.photo(id: id) }
        return row.map { PanelCaptureZone(shown: $0.capturedOffset, file: $0.cameraZone) }
    }

    // MARK: - The photos shown

    /// The library's lists and the query engine hold every change made so far.
    @_spi(Harness) public func settled() async {
        await core?.live.settle()
    }
}

/// The index's IDs of the photos the Library shows, by their IDs in its list (`FolderLibrary.photoIDs`), kept as
/// they're found, with each folder read's names: a selection of thousands is looked up within a frame once its
/// folders have been read. A photo's ID in the list is never given to another while it's shown.
final class PanelPhotoIDs: Sendable {
    private struct Found {
        var byList: [Int64: Int64] = [:]
        /// Each folder read, by its path: its photos' IDs by their names, composed.
        var folders: [String: [String: Int64]] = [:]
    }

    private let found = Mutex(Found())

    /// The index's IDs of `photos` (their IDs in the list and their URLs), by their IDs in the list, for those
    /// the index has; the folders of those not known yet are read, a folder at a time.
    func ids(of photos: [(list: Int64, url: URL)], in index: LibraryIndex) async -> [Int64: Int64] {
        var known: [Int64: Int64] = [:]
        var missing: [(list: Int64, folder: String, name: String)] = []
        found.withLock { found in
            for photo in photos {
                if let id = found.byList[photo.list] {
                    known[photo.list] = id
                    continue
                }
                let folder = LibraryService.path(photo.url.deletingLastPathComponent())
                let name = photo.url.lastPathComponent.precomposedStringWithCanonicalMapping
                if let names = found.folders[folder] {
                    if let id = names[name] {
                        known[photo.list] = id
                        found.byList[photo.list] = id
                    }
                } else {
                    missing.append((photo.list, folder, name))
                }
            }
        }
        guard !missing.isEmpty else { return known }
        let folders = Set(missing.map(\.folder))
        let read = await (try? index.read { reader -> [String: [String: Int64]] in
            var read: [String: [String: Int64]] = [:]
            let statement = try reader.database.cached("SELECT id, name FROM photos WHERE folder = ?")
            for path in folders {
                guard let folder = try LibraryService.folder(at: path, in: reader) else { continue }
                try statement.bind(folder.id, at: 1)
                var named: [String: Int64] = [:]
                try statement.forEachRow { row in
                    if let name = row.string(at: 1) {
                        named[name.precomposedStringWithCanonicalMapping] = row.int64(at: 0)
                    }
                }
                read[path] = named
            }
            return read
        }) ?? [:]
        found.withLock { found in
            found.folders.merge(read) { _, new in new }
            for photo in missing {
                if let id = read[photo.folder]?[photo.name] {
                    known[photo.list] = id
                    found.byList[photo.list] = id
                }
            }
        }
        return known
    }

    /// The list was made afresh, or photos came or went: folders are read again.
    func forget() {
        found.withLock { $0 = Found() }
    }
}
