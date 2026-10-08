import Foundation
import RedlampLibrary
import Synchronization

extension ImportWindowModel {
    /// Why Import can't start now, as a sentence; nil when it can.
    var importBlocker: String? {
        if !interrupted.isEmpty {
            return "An import that was interrupted has to be resumed first."
        }
        if phase == .planning || phase == .copying {
            return "An import is running."
        }
        if let folderError {
            return "The folder template has an error: \(folderError)"
        }
        if let namesError {
            return "The name template has an error: \(namesError)"
        }
        let destination = LibraryService.path(settings.destination)
        if let backup = settings.backup.map(LibraryService.path), backup == destination {
            return "The backup has to be somewhere other than the destination."
        }
        if let source = sources.first(where: { source in
            source.isIncluded && Self.isWithin(destination, LibraryService.path(source.source.url))
        }) {
            return "The destination is on \(source.source.name), which is being imported from."
        }
        if chosen.photos == 0 {
            return sources.isEmpty ? "Insert a card, or add a folder." : "No photos are chosen."
        }
        return nil
    }

    private static func isWithin(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// Import: the chosen photos of every source included, planned together and copied, as the type says.
    func startImport() {
        guard importBlocker == nil else { return }
        let included = sources.filter { $0.isIncluded && $0.problem == nil }
        let settings = settings
        let destinationFileSystem = destinationFileSystem
        failure = nil
        outcome = nil
        progress = nil
        for index in sources.indices {
            sources[index].progress = nil
            sources[index].outcome = nil
        }
        phase = .planning
        notify(.status)
        notify(.sources)
        let together = ImportSession(
            sources: included.map(\.source), library: library, fileSystem: fileSystem, volumes: volumes,
            makesPreviews: false,
        )
        together.add(included.flatMap(\.session.photos).filter { !copied.contains($0.id) })
        let importer = importer
        importing = Task { [weak self] in
            do {
                let planned = await self?.withPreset(settings) ?? settings
                let plan = try await together.plan(planned, destinationFileSystem: destinationFileSystem)
                try Task.checkCancellation()
                guard let self else { return }
                self.plan = plan
                guard !plan.items.isEmpty else {
                    phase = .finished
                    failure = "Nothing was copied: every photo chosen is in the library or at the destination already."
                    notify(.status)
                    return
                }
                phase = .copying
                notify(.status)
                let latest = ImportLatest<ImportProgress>()
                let interval = Self.progressInterval
                let outcome = try await importer.run(plan) { progress in
                    guard latest.set(progress) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: interval)
                        if let progress = latest.take() {
                            self?.progressed(progress)
                        }
                    }
                }
                if let last = latest.take() {
                    progressed(last)
                }
                await finished(outcome, plan: plan)
            } catch {
                guard let self else { return }
                phase = .finished
                failure = error is CancellationError ? "The import was cancelled before anything was copied."
                    : "The import couldn't start: \(String(describing: error))"
                notify(.status)
            }
            self?.importing = nil
        }
    }

    /// Cancel: stops the import once the photos being copied are in place; nothing is left half copied.
    func cancel() {
        importing?.cancel()
    }

    /// Returns once the import running is over.
    func imported() async {
        await importing?.value
    }

    func progressed(_ progress: ImportProgress) {
        guard phase == .copying else { return }
        self.progress = progress
        for index in sources.indices {
            sources[index].progress = progress.sources[sources[index].id]
        }
        notify(.status)
        notify(.sources)
    }

    private func finished(_ outcome: ImportOutcome, plan: ImportPlan) async {
        self.outcome = outcome
        phase = .finished
        preferences.update { $0.counters = plan.counters }
        for index in sources.indices {
            sources[index].progress = nil
            sources[index].outcome = outcome.sources.first { $0.id == sources[index].id }
        }
        let failed = Set(outcome.failures.map(\.photo))
        let destinationFileSystem = destinationFileSystem
        let placed = await Task.detached(priority: .userInitiated) {
            plan.items.filter { !failed.contains($0.photo) }.compactMap { item -> (String, URL)? in
                guard let copy = item.photos.first, let target = plan.targets(of: copy).first,
                      destinationFileSystem.exists(target)
                else { return nil }
                return (item.photo, target)
            }
        }.value
        copied.formUnion(placed.map(\.0))
        failure = outcome.state == .stopped
            ? "The import was cancelled: the photos copied so far are in place, the others are still where they were."
            : nil
        notify(.status)
        notify(.sources)
        notify(.photos(ids: nil))
        if !placed.isEmpty {
            showInLibrary(placed.map(\.1))
        }
        if preferences.ejectsAfterImport {
            for source in sources where source.isCard && source.outcome?.isSafeToErase == true {
                await eject(source.id)
            }
        }
    }

    /// Resume: finishes the imports a forced quit cut short, copying the rest from their sources, which
    /// have to be there.
    func resume() {
        guard !interrupted.isEmpty, importing == nil else { return }
        phase = .copying
        failure = nil
        notify(.status)
        let importer = importer
        importing = Task { [weak self] in
            guard let self else { return }
            let latest = ImportLatest<ImportProgress>()
            let interval = Self.progressInterval
            do {
                let outcomes = try await importer.recover { [weak self] progress in
                    guard latest.set(progress) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: interval)
                        if let progress = latest.take() {
                            self?.progressed(progress)
                        }
                    }
                }
                outcome = outcomes.last
                interrupted = await (try? importer.unfinishedEntries()) ?? []
                phase = .finished
                let verified = outcomes.reduce(0) { $0 + $1.verified }
                let photos = outcomes.reduce(0) { $0 + $1.photos }
                failure = verified == photos ? nil
                    : "\(photos - verified) of the interrupted import's photos weren't copied: their card or folder "
                    + "wasn't there, or changed."
            } catch {
                phase = .finished
                failure = "The interrupted import couldn't be resumed: \(String(describing: error))"
            }
            notify(.status)
            importing = nil
        }
    }

    /// Ejects the card, once its photos are copied or it's left out.
    func eject(_ id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }), sources[index].isCard,
              sources[index].source.medium.isEjectable, phase != .copying
        else { return }
        let card = sources[index].source
        do {
            try await ejector(card)
            if let index = sources.firstIndex(where: { $0.id == id }) {
                sources[index].isEjected = true
                sources[index].isIncluded = false
            }
        } catch {
            failure = "\(card.name) couldn't be ejected: \(error.localizedDescription)"
        }
        notify(.sources)
        notify(.status)
    }

    /// Each destination's line while copying and after: the destination and the backup get every
    /// photo at once, and a photo counts once it's verified at both.
    var destinationLines: [String] {
        let roots = [settings.destination] + (settings.backup.map { [$0] } ?? [])
        let verified = progress?.done ?? outcome?.verified
        let total = progress?.photos ?? outcome?.photos
        guard let verified, let total, phase == .copying || phase == .finished else { return [] }
        return roots.map { "\($0.lastPathComponent): \(verified) of \(Self.count(total, "photo")) verified" }
    }
}

/// The latest of something told often from other threads, taken on the main thread now and then.
final class ImportLatest<Value: Sendable>: Sendable {
    private let state = Mutex<(value: Value?, waiting: Bool)>((nil, false))

    /// Keeps `value`; true when nothing waits to take it yet, so it's to be taken.
    func set(_ value: Value) -> Bool {
        state.withLock { state in
            state.value = value
            defer { state.waiting = true }
            return !state.waiting
        }
    }

    func take() -> Value? {
        state.withLock { state in
            defer { state = (nil, false) }
            return state.value
        }
    }
}
