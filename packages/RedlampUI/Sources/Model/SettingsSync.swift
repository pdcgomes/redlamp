import Foundation
import Observation
import RedlampDocument
import RedlampEngineAPI

/// Changes photos that aren't open, one at a time in the background: Sync Settings, Paste onto a
/// selection, Update AI Masks across it (`docs/plans/2026-10-02-copy-paste-sync-design.md`).
///
/// For each photo it reads the sidecar, pastes, recomputes the AI masks the paste brought (and an
/// Auto white balance) in an engine of its own, so the open photo is never disturbed, and saves
/// with a history step. A photo whose sidecar a newer Redlamp wrote, or this version can't read,
/// is left alone. Undo puts back what the last batch changed, on every photo not edited since.
@MainActor
@Observable
public final class SettingsSync {
    public enum Change {
        /// `selection` of `source`, pasted.
        case paste(EditRecipe, SettingsSelection)
        /// Every AI mask computed again with today's models.
        case updateAIMasks
        /// Each photo's sensor dust (found across the selection) healed, a source found for each speck.
        case healDust([URL: [DetectedSpot]])
    }

    public struct Progress: Equatable, Sendable {
        public var title: String
        public var done: Int
        public var total: Int
    }

    public private(set) var progress: Progress?
    /// Auto Sync: each step on the open photo repeats on the rest of the selection.
    public var isAutoSyncing = false
    /// How the last batch went, when there is something to say ("1 photo was left alone…").
    public private(set) var report: String?
    public var canUndo: Bool {
        !written.isEmpty && progress == nil
    }

    /// An engine for photos that aren't open; nil leaves AI masks and Auto white balance as pasted.
    @ObservationIgnored var makeEngine: () -> (any EditingEngine)?
    @ObservationIgnored let store: SidecarStore
    /// The editor's saves: a photo just left may still be on its way to disk.
    @ObservationIgnored var saves: SaveQueue?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last batch: each photo's edit before (nil: it had no sidecar) and after.
    @ObservationIgnored private var before: [URL: EditRecipe?] = [:]
    @ObservationIgnored private var written: [URL: Sidecar] = [:]
    @ObservationIgnored private var title = ""
    /// Batches that came while one ran, in order; Auto Sync's steps are gathered into one.
    @ObservationIgnored private var queue: [Job] = []

    private struct Job {
        var change: Change
        var photos: [URL]
        var title: String
        var isAutoSync = false
        var inEditor: (URL) async -> Bool
        var done: (URL, EditRecipe) -> Void
    }

    init(store: SidecarStore = SidecarStore(), makeEngine: @escaping () -> (any EditingEngine)?) {
        self.store = store
        self.makeEngine = makeEngine
    }

    /// Starts `change` on `photos`, recorded in each one's history as `title`, or queues it after
    /// the batch running; `done` is told of each photo written. `inEditor` is asked about each
    /// photo as the batch reaches it: true when it is open in the editor, which made the change
    /// itself, so the batch leaves it.
    func run(
        _ change: Change, on photos: [URL], title: String,
        inEditor: @escaping (URL) async -> Bool = { _ in false },
        done: @escaping (URL, EditRecipe) -> Void,
    ) {
        enqueue(Job(change: change, photos: photos, title: title, inEditor: inEditor, done: done))
    }

    public func cancel() {
        queue = []
        task?.cancel()
    }

    /// One Auto Sync step: what it changed of `source`, onto `photos`; gathered with the steps
    /// queued just before it.
    func autoSync(
        _ source: EditRecipe, _ changes: SettingsSelection, on photos: [URL], done: @escaping (URL, EditRecipe) -> Void,
    ) {
        guard !changes.isEmpty, !photos.isEmpty else { return }
        if progress != nil, let last = queue.last, last.isAutoSync, case let .paste(_, gathered) = last.change {
            queue[queue.count - 1].change = .paste(source, gathered.union(changes))
            queue[queue.count - 1].photos = photos
            return
        }
        enqueue(Job(
            change: .paste(source, changes), photos: photos, title: "Auto Sync", isAutoSync: true,
            inEditor: { _ in false }, done: done,
        ))
    }

    private func enqueue(_ job: Job) {
        guard !job.photos.isEmpty else { return }
        if progress == nil {
            start(job)
        } else {
            queue.append(job)
        }
    }

    private func start(_ job: Job) {
        progress = Progress(title: job.title, done: 0, total: job.photos.count)
        title = job.title
        report = nil
        before = [:]
        written = [:]
        task = Task { [weak self] in
            await self?.process(job.change, job.photos, title: job.title, inEditor: job.inEditor, done: job.done)
        }
    }

    /// Waits for the batch running, if any.
    func idle() async {
        await task?.value
    }

    /// Puts back every photo of the last batch not edited since.
    func undo(done: @escaping (URL, EditRecipe) -> Void) {
        guard canUndo else { return }
        for (url, after) in written {
            guard let current = store.load(for: url), current.recipe == after.recipe,
                  let previous = before[url] else { continue }
            if let previous {
                record(previous, from: after.recipe, for: url, title: "Undo \(title)", action: .paste)
                done(url, previous)
            } else if current.hasSameContent(as: after) {
                store.delete(for: url)
                done(url, EditRecipe())
            } else {
                // Rated, say, since the sync made it: only the edit goes back.
                var reverted = current
                reverted.recipe = EditRecipe()
                reverted.modified = Date()
                reverted.session = HistorySession(steps: [
                    HistoryStep(action: .open, title: "Opened", recipe: after.recipe),
                    HistoryStep(action: .paste, title: "Undo \(title)", recipe: reverted.recipe),
                ])
                try? store.saveOrRemove(reverted, for: url)
                done(url, EditRecipe())
            }
        }
        written = [:]
        before = [:]
        report = nil
    }

    private func process(
        _ change: Change, _ photos: [URL], title: String, inEditor: (URL) async -> Bool,
        done: @escaping (URL, EditRecipe) -> Void,
    ) async {
        var engine: (any EditingEngine)?
        var skipped = 0
        var failedMasks = 0
        for url in photos {
            guard !Task.isCancelled else { break }
            defer { progress?.done += 1 }
            guard await !inEditor(url) else { continue }
            await saves?.wait(for: url)
            guard store.protection(for: url) == nil else {
                skipped += 1
                continue
            }
            let existing = store.load(for: url)
            let original = existing?.recipe ?? EditRecipe()
            var next = original
            var masks: Set<UUID>?
            var autoWhiteBalance = false
            switch change {
            case let .paste(source, selection):
                let pasted = original.pasting(source, selection)
                    .reusingAIMasks(from: original, in: EditRecipe.pastedMasks(from: source, selection))
                next = pasted.recipe
                masks = pasted.recompute
                if selection.items.contains("whiteBalance") {
                    // As Shot is the photo's own, read when it opens; Auto is measured for it.
                    if next.whiteBalanceMode == .asShot {
                        next.reset([.temperature, .tint])
                    }
                    autoWhiteBalance = next.whiteBalanceMode == .auto
                }
            case .updateAIMasks:
                masks = nil
            case let .healDust(found):
                masks = []
                let specks = found[url] ?? []
                guard !specks.isEmpty else { continue }
                engine = engine ?? makeEngine()
                var opened = false
                if let engine {
                    opened = await (try? engine.open(url)) != nil
                }
                for speck in specks {
                    var spot = RetouchSpot(center: speck.center, source: speck.center, radius: speck.radius)
                    let found = opened ? await engine?.retouchSource(for: spot, recipe: original) : nil
                    spot.source = found ?? ImagePoint(x: min(speck.center.x + speck.radius * 2.5, 1), y: speck.center.y)
                    next.spots.append(spot)
                }
            }
            let needsMasks = next.masks.contains { layer in
                (masks?.contains(layer.id) ?? true) && layer.components.contains { $0.shape.isAIRaster }
            }
            if needsMasks || autoWhiteBalance {
                engine = engine ?? makeEngine()
                if let engine, await (try? engine.open(url)) != nil {
                    if autoWhiteBalance, let wb = await engine.autoWhiteBalance() {
                        next[.temperature] = wb.temperature
                        next[.tint] = wb.tint
                    }
                    if needsMasks {
                        let (recomputed, failed) = await EditorModel.recomputingAIMasks(next, in: masks, engine: engine)
                        next = recomputed
                        failedMasks += failed
                    }
                }
            }
            guard next != original else { continue }
            var sidecar = existing ?? Sidecar(recipe: next)
            sidecar.recipe = next
            sidecar.modified = Date()
            sidecar.session = HistorySession(steps: [
                HistoryStep(action: .open, title: existing == nil ? "Import" : "Opened", recipe: original),
                HistoryStep(action: change.action, title: title, recipe: next),
            ])
            guard (try? store.save(sidecar, for: url)) != nil else { continue }
            // updateValue: a photo without a sidecar keeps its nil (a subscript would drop the key).
            before.updateValue(existing?.recipe, forKey: url)
            // As read back, so Undo can tell the photo hasn't been edited since (dates round).
            written[url] = store.load(for: url) ?? sidecar
            done(url, next)
        }
        report = Self.report(skipped: skipped, failedMasks: failedMasks, cancelled: Task.isCancelled)
        progress = nil
        if !queue.isEmpty {
            start(queue.removeFirst())
            await task?.value
        }
    }

    /// A history session for a change made without opening the photo.
    private func record(
        _ recipe: EditRecipe,
        from current: EditRecipe,
        for url: URL,
        title: String,
        action: HistoryAction,
    ) {
        guard var sidecar = store.load(for: url) else { return }
        sidecar.recipe = recipe
        sidecar.modified = Date()
        sidecar.session = HistorySession(steps: [
            HistoryStep(action: .open, title: "Opened", recipe: current),
            HistoryStep(action: action, title: title, recipe: recipe),
        ])
        try? store.save(sidecar, for: url)
    }

    private static func report(skipped: Int, failedMasks: Int, cancelled: Bool) -> String? {
        var parts: [String] = []
        if cancelled {
            parts.append("Stopped before the end.")
        }
        if skipped > 0 {
            let photos = "\(skipped) photo\(skipped == 1 ? " was" : "s were")"
            parts.append("\(photos) left alone: edited by a newer Redlamp, or the edit can't be read.")
        }
        if failedMasks > 0 {
            parts.append("\(failedMasks) AI mask\(failedMasks == 1 ? "" : "s") couldn't be computed for its photo.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private extension SettingsSync.Change {
    var action: HistoryAction {
        switch self {
        case .paste: .paste
        case .updateAIMasks: .mask(nil)
        case .healDust: .retouch
        }
    }
}

extension MaskShape {
    /// A bitmap an AI model computed for one photo (Depth Range's depth map too).
    var isAIRaster: Bool {
        switch self {
        case .ai, .depthRange: true
        default: false
        }
    }
}
