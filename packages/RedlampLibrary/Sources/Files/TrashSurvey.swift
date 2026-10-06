import Foundation
import RedlampDocument

/// Where what the journal's batches moved to the Trash is now (LIB-26), for Recently Trashed, Put
/// Back and keeping the journal: each batch's Trash steps, the newest batch first, every item looked
/// for at the place the Trash gave it.
///
/// - **Still there:** the file at its place is the one the batch moved, with the file identifier,
///   size and date the journal recorded.
/// - **Gone:** another file is there, or none: emptied from the Trash, put back by Finder or replaced.
/// - **Offline:** its Trash folder isn't there, so its volume is away.
///
/// A place a newer batch's item holds is that batch's: the same file, moved to the Trash again.
///
/// It blocks on the file system: use it off the caller.
struct TrashSurvey {
    enum Presence: Sendable, Hashable {
        case inTrash
        case gone
        case offline
    }

    /// A Trash step a batch did, and where its items are.
    struct Step {
        var index: Int
        var step: FileStep
        /// Each item's place in the Trash; nil for one the step didn't move there.
        var places: [String?]
        var presence: [Presence]

        /// A folder that went to the Trash whole, with the photos in it.
        var isFolder: Bool {
            step.items.first?.role == .folder
        }

        /// Its photo's file among its items.
        var photoItem: Int? {
            step.items.firstIndex { $0.role == .photo } ?? (step.items.isEmpty ? nil : 0)
        }

        /// Whether its photo or its folder is still in the Trash, or may be, its volume away.
        var holds: Bool {
            step.items.indices.contains { step.items[$0].isRequired && presence[$0] != .gone }
        }
    }

    struct Batch {
        var entry: FileJournal.Entry
        var steps: [Step]
    }

    let fileSystem: any LibraryFileSystem
    /// Newest first.
    private(set) var batches: [Batch] = []
    /// Batches whose journal this build can't read: damaged, or a newer Redlamp's.
    private(set) var unreadable: Set<UUID> = []
    private var claimed = Set<String>()
    private var trashFolders: [String: Bool] = [:]

    /// The journal's batches as `entries` (oldest first, all of them unless given) list them.
    init(journal: FileJournal, entries: [FileJournal.Entry]? = nil, fileSystem: any LibraryFileSystem) throws {
        self.fileSystem = fileSystem
        for entry in try (entries ?? journal.entries()).reversed() where Self.mayHoldTrash(entry) {
            guard let (batch, logged) = try? journal.load(entry.id) else {
                unreadable.insert(entry.id)
                continue
            }
            var steps: [Step] = []
            for (index, step) in batch.steps.enumerated() where step.kind == .trash && logged.done.contains(index) {
                let places = FileOperations.places(logged.trashed[index], count: step.items.count)
                var presence: [Presence] = []
                for (item, place) in zip(step.items, places) {
                    if let place {
                        presence.append(look(for: item, at: place))
                    } else {
                        presence.append(.gone)
                    }
                }
                steps.append(Step(index: index, step: step, places: places, presence: presence))
            }
            if !steps.isEmpty {
                batches.append(Batch(entry: entry, steps: steps))
            }
        }
    }

    /// Batches whose Trash steps may have left something there: over, and not rolled back. An undone
    /// one may have left out what its Trash couldn't be reached for.
    private static func mayHoldTrash(_ entry: FileJournal.Entry) -> Bool {
        [.trash, .undo].contains(entry.kind) && [.finished, .stopped, .undone].contains(entry.state)
    }

    /// Whether batch `id` keeps a photo or a folder in the Trash, or may, or can't be read.
    func holds(_ id: UUID) -> Bool {
        unreadable.contains(id) || batches.contains { $0.entry.id == id && $0.steps.contains(where: \.holds) }
    }

    // MARK: - Where items are

    /// Whether `item` is still at `place`, unless a newer batch's item is there.
    private mutating func look(for item: FileItem, at place: String) -> Presence {
        let key = NamingJob.fold(place)
        guard !claimed.contains(key) else { return .gone }
        guard let entry = try? fileSystem.attributes(of: URL(fileURLWithPath: place)) else {
            let folder = FilePlanner.split(place).folder
            if trashFolders[folder] == nil {
                trashFolders[folder] = (try? fileSystem.attributes(of: URL(fileURLWithPath: folder)))?.isDirectory
                    == true
            }
            return trashFolders[folder] == true ? .gone : .offline
        }
        guard FileRunner.matches(entry, item) else { return .gone }
        claimed.insert(key)
        return .inTrash
    }

    /// Where each of `step`'s items is, `places` saying where it went in the Trash: as `TrashSurvey`
    /// looks, for the step alone.
    static func presence(of step: FileStep, places: [String?], fileSystem: any LibraryFileSystem) -> [Presence] {
        var survey = TrashSurvey(fileSystem: fileSystem)
        return zip(step.items, places).map { item, place in
            place.map { survey.look(for: item, at: $0) } ?? .gone
        }
    }

    private init(fileSystem: any LibraryFileSystem) {
        self.fileSystem = fileSystem
    }

    // MARK: - Recently Trashed

    /// The photos still in the Trash, the newest batch's first and each batch's in its order, with
    /// their files still there and their pairs.
    func photos() -> [TrashedPhoto] {
        var found: [TrashedPhoto] = []
        for batch in batches {
            for step in batch.steps {
                if step.isFolder {
                    found += photos(inFolder: step, of: batch.entry)
                } else if let photo = photo(of: step, in: batch.entry) {
                    found.append(photo)
                }
            }
        }
        var byStem: [String: [Int]] = [:]
        for (index, photo) in found.enumerated() {
            let (folder, name) = FilePlanner.split(photo.original)
            byStem[NamingJob.fold(folder + "/" + NamingJob.split(name).base), default: []].append(index)
        }
        for members in byStem.values where members.count > 1 {
            for member in members {
                found[member].pair = members.filter { $0 != member }.map { found[$0].id }
            }
        }
        return found
    }

    private func photo(of step: Step, in entry: FileJournal.Entry) -> TrashedPhoto? {
        guard let number = step.photoItem, step.presence[number] == .inTrash, let place = step.places[number],
              let removed = step.step.removed.first
        else { return nil }
        let files = step.step.items.enumerated().compactMap { index, item -> TrashedPhoto.File? in
            guard index != number, step.presence[index] == .inTrash, let place = step.places[index] else { return nil }
            return TrashedPhoto.File(role: item.role, original: item.source, place: place)
        }
        return TrashedPhoto(
            id: TrashedPhoto.ID(batch: entry.id, step: step.index, photo: removed.photo.id), photo: removed,
            original: step.step.items[number].source, place: place, title: entry.title, trashed: entry.created,
            files: files, trash: FilePlanner.split(place).folder,
        )
    }

    /// The photos of a folder that went to the Trash whole that are still in it, each the file its
    /// row was of.
    private func photos(inFolder step: Step, of entry: FileJournal.Entry) -> [TrashedPhoto] {
        guard step.presence.first == .inTrash, let place = step.places.first ?? nil,
              let folder = step.step.items.first?.source
        else { return [] }
        return step.step.removed.compactMap { removed in
            let original = removed.folder + "/" + removed.photo.name
            guard NamingJob.fold(original).hasPrefix(NamingJob.fold(folder) + "/") else { return nil }
            let inside = place + original.dropFirst(folder.count)
            let recorded = FileItem(
                role: .photo, source: original, destination: nil, fileID: removed.photo.fileID,
                size: removed.photo.size, modified: Date(timeIntervalSince1970: removed.photo.modified),
            )
            guard let file = try? fileSystem.attributes(of: URL(fileURLWithPath: inside)),
                  FileRunner.matches(file, recorded)
            else { return nil }
            return TrashedPhoto(
                id: TrashedPhoto.ID(batch: entry.id, step: step.index, photo: removed.photo.id), photo: removed,
                original: original, place: inside, title: entry.title, trashed: entry.created, files: [],
                folder: folder, trash: FilePlanner.split(place).folder,
            )
        }
    }
}

extension FileStep {
    /// The step that puts what this Trash step moved back where it was, from each item's place in the
    /// Trash: those `presence` finds there, the others left out, by where they were, in `gone`. Nil
    /// when neither its photos nor its folder are there.
    func puttingBack(places: [String?], presence: [TrashSurvey.Presence], gone: inout [String]) -> FileStep? {
        let there = zip(places, presence).map { place, presence in presence == .inTrash ? place : nil }
        for (item, place) in zip(items, there) where place == nil {
            gone.append(item.source)
        }
        let step = inverse(trashed: there)
        return step.items.contains(where: \.isRequired) ? step : nil
    }
}
